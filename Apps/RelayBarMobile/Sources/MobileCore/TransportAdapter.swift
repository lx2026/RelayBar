import PreviewSupport
import Composition
import Foundation
import RelayTransport
import RelayWebRoutes

private struct DeviceSigner: SSHSigner {
  let signIn: SignIn
  let keys: any KeyProvider
  func signingKey() async throws -> SigningKey {
    switch try await signIn.signingKey(keys) {
    case .memory(let key): return SigningKey(key)
    case .enclave(let key): return SigningKey(key)
    }
  }
}

package struct TransportConnection: HostConnection {
  private let session: SSHSession
  package var routeOpener: (any RouteStreamOpener)? { session }
  private let signIn: SignIn
  private let host: String

  @MainActor package init(profile: Profile, signIn: SignIn, keys: any KeyProvider) {
    self.signIn = signIn
    host = profile.host
    var config = SessionConfiguration(host: host, port: profile.port, username: profile.account) {
      key in
      await signIn.verify(.init(algorithm: key.type, fingerprint: key.fingerprint))
    }
    if profile.method != .password { config.signer = DeviceSigner(signIn: signIn, keys: keys) }
    if profile.method != .key { config.password = { try await signIn.password() } }
    session = SSHSession(config)
  }

  package func run(_ publish: @escaping @MainActor @Sendable (ConnectionEvent) -> Void) async {
    async let connection: Void = connect()
    for await event in session.states {
      if Task.isCancelled { break }
      switch event {
      case .connecting: await publish(.connecting)
      case .ready: await publish(.ready)
      case .interrupted: await publish(.lost)
      case .failed(let error):
        if let reason = await signIn.failureReason {
          await publish(.failed(reason))
        } else if case .signInRefused = error {
          await publish(.failed(error.message(for: host), passwordRefused: true))
        } else {
          await publish(.failed(error.message(for: host)))
        }
      default: break
      }
    }
    await connection
  }

  package func files() async throws -> any RemoteFiles {
    do { _ = try await session.sftp() } catch let error as TransportError {
      throw CompositionError(error.message(for: host))
    }
    return RemoteAdapter(session: session)
  }

  private func connect() async { _ = try? await session.resume() }
  package func networkPathChanged() async { await session.networkPathChanged() }
  package func suspend() async { await session.suspend() }
}

extension FileAttributes {
  fileprivate var stamp: FileStamp {
    .init(
      size: size, modified: modificationTime,
      directory: permissions.map { $0 & 0o170000 == 0o040000 } ?? false)
  }
}

private actor Listing {
  var rows: [FileRow] = []
  func add(_ entry: DirectoryEntry, parent: String, client: SFTPClient) async throws {
    guard let name = String(data: entry.filename, encoding: .utf8), !name.isEmpty,
      ![".", ".."].contains(name),
      !name.contains("/"), name.rangeOfCharacter(from: .controlCharacters) == nil
    else { return }
    guard rows.count < PreviewLimits.entries else { throw CompositionError("This folder exceeds 10,000 entries.") }
    try await NameIndex.walker?.yieldToPages()
    var stamp = entry.attributes.stamp
    if let mode = entry.attributes.permissions, mode & 0o170000 == 0o120000 {
      var path = Data((parent.hasSuffix("/") ? parent : parent + "/").utf8)
      path.append(entry.filename)
      if let target = try? await client.stat(path) { stamp = target.stamp }
    }
    var row = FileRow(name: name, stamp: stamp)
    row.symbolicLink = entry.attributes.permissions.map { $0 & 0o170000 == 0o120000 } ?? false
    let path = (parent as NSString).appendingPathComponent(name)
    if let fingerprint = SFTPFileFingerprint(path: path, attributes: entry.attributes) {
      row.remove = { try await client.remove(path, matching: fingerprint) }
    }
    rows.append(row)
  }
}

private actor Bytes {
  var data = Data()
  func append(_ chunk: Data, limit: Int) throws {
    guard chunk.count <= limit - data.count else {
      throw CompositionError("File exceeds the reading limit.")
    }
    data.append(chunk)
  }
}

struct RemoteAdapter: RangeFiles {
  let session: SSHSession
  var restrict: @Sendable () async -> Bool = { false }
  func home() async throws -> String { try await session.sftp().home() }
  func resolve(_ path: String) async throws -> String { try await session.sftp().realpath(path) }
  func stat(_ path: String) async throws -> FileStamp {
    try await session.sftp().stat(Data(path.utf8)).stamp
  }
  func list(_ path: String) async throws -> [FileRow] {
    try await listing(path).rows
  }
  func listing(_ path: String) async throws -> FolderListing {
    let listing = Listing()
    let client = try await session.sftp()
    let result = try await client.list(Data(path.utf8), limit: PreviewLimits.entries) {
      try await listing.add($0, parent: path, client: client)
    }
    let rows = await listing.rows.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    return FolderListing(rows: rows, truncated: result.truncated)
  }
  func read(_ path: String, limit: Int) async throws -> Data {
    let data = try await bytes(path, range: 0..<UInt64(limit + 1), interactive: true)
    guard data.count <= limit else { throw CompositionError("File exceeds the reading limit.") }
    return data
  }
  func bytes(_ path: String, range: Range<UInt64>, interactive: Bool) async throws -> Data {
    let client = try await session.sftp()
    let file = try await client.open(Data(path.utf8))
    let bytes = Bytes()
    do {
      var offset = range.lowerBound
      while offset < range.upperBound {
        let length = await restrict() ? client.maximumReadLength : 2 << 20
        let end = min(range.upperBound, offset + UInt64(length))
        try await file.read(range: offset..<end, priority: interactive ? .interactive : .bulk) {
          try await bytes.append($0, limit: range.count)
        }
        if await bytes.data.count < Int(end - range.lowerBound) { break }
        offset = end
      }
      try await file.close()
    } catch {
      try? await file.close()
      throw error
    }
    return await bytes.data
  }
}

extension TransportError {
  func message(for host: String) -> String {
    switch self {
    case .unreachable: "Couldn't reach \(host). Check Tailscale is connected, then retry."
    case .hostKeyChanged: "The host key has changed. Connection blocked."
    case .hostKeyRefused: "The host key was not trusted."
    case .signInRefused: "The host refused sign-in."
    case .algorithmMismatch: "The host and this device could not agree on an SSH algorithm."
    case .sftpUnavailable: "The host does not provide SFTP."
    case .forwardingProhibited: "The host disallows forwarding."
    case .connectionRefused: "The service refused the connection."
    case .cancelled: "The connection was cancelled."
    case .invalidEndpoint: "The host address or port is invalid."
    case .disconnected: "The SSH connection ended."
    }
  }
}
