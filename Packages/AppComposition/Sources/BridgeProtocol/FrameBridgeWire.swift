import Foundation
import Darwin
import Security

public struct BridgeSource: Codable, Hashable, Identifiable, Sendable {
  public init(id: String, name: String) { self.id = id; self.name = name }
  public let id: String
  public let name: String
}
public struct BridgeLocation: Codable, Hashable, Identifiable, Sendable {
  public init(id: String, source: BridgeSource, path: String) { self.id = id; self.source = source; self.path = path }
  public let id: String
  public let source: BridgeSource
  public let path: String
}
public struct BridgeEntry: Codable, Hashable, Sendable {
  public init(name: String, path: String, directory: Bool, size: Int64, modified: String, fingerprint: String? = nil) { self.name = name; self.path = path; self.directory = directory; self.size = size; self.modified = modified; self.fingerprint = fingerprint }
  public let name: String
  public let path: String
  public let directory: Bool
  public let size: Int64
  public let modified: String
  public var fingerprint: String? = nil
}
public struct BridgeHandoff: Codable, Sendable {
  public init(source: BridgeSource, path: String, focus: [String]) { self.source = source; self.path = path; self.focus = focus }
  public let source: BridgeSource
  public let path: String
  public let focus: [String]
}
public struct BridgeRequest: Codable, Sendable {
  public var version = FrameBridgeEnvironment.protocolVersion
  public var operation: String
  public var sourceID: String?
  public var path: String?
  public var listingID: UUID?
  public var name: String?
  public var jobID: UUID?
  public var nonce: UUID?
  public var root: String?
  public var recordID: UUID?
  public var pixels: Int?
  public var fingerprint: String?
  public var targets: [BridgeDeleteTarget]?
  public var paths: [String]?
  public init(_ operation: String) { self.operation = operation }
}
public struct BridgeDeleteTarget: Codable, Sendable {
  public init(listingID: UUID, path: String, recordID: UUID? = nil) { self.listingID = listingID; self.path = path; self.recordID = recordID }
  public var listingID: UUID
  public var path: String
  public var recordID: UUID?
}
public struct BridgeDeleteOutcome: Codable, Sendable {
  public init(path: String, error: String? = nil) { self.path = path; self.error = error }
  public var path: String
  public var error: String?
}
public enum BridgeSessionFailure: String, Codable, Sendable {
  case unavailable, unauthorized, incompatible
}
public struct BridgeResponse: Codable, Sendable {
  public var version = FrameBridgeEnvironment.protocolVersion
  public var error: String?
  public var sessionFailure: BridgeSessionFailure?
  /// A verified directory to retry when an explicitly opened library path contains a symlink.
  public var resolvedFolder: String?
  public var status = "ready"
  public var sources: [BridgeSource]?
  public var locations: [BridgeLocation]?
  public var entries: [BridgeEntry]?
  public var listingID: UUID?
  public var jobID: UUID?
  public var cacheRelativePath: String?
  public var completedBytes: Int64?
  public var totalBytes: Int64?
  public var handoff: BridgeHandoff?
  public var asset: BridgeAssetResult?
  public init(error: String? = nil, sessionFailure: BridgeSessionFailure? = nil) {
    self.error = error; self.sessionFailure = sessionFailure
  }
  /// A response from another protocol version ends the session as incompatible. Otherwise an error
  /// ends the session only when RelayBar says so; a file or helper error leaves it usable.
  public func checked() throws -> BridgeResponse {
    guard version == FrameBridgeEnvironment.protocolVersion else {
      throw BridgeError("Update Frame and RelayBar to compatible versions.", sessionFailure: .incompatible)
    }
    if let error { throw BridgeError(error, sessionFailure: sessionFailure, resolvedFolder: resolvedFolder) }
    return self
  }
}
public struct BridgeStoredAsset: Codable, Sendable {
  public init(id: UUID, members: [BridgeEntry], originals: [String]) { self.id = id; self.members = members; self.originals = originals }
  public var id: UUID
  public var members: [BridgeEntry]
  public var originals: [String]
}
public struct BridgeAssetInput: Codable, Sendable {
  public var action: String
  public var root: String
  public var members: [BridgeEntry] = []
  public var recordID: UUID?
  public var pixels: Int?
  public var fingerprint: String?
  public var batch: [BridgeAssetInput]?
  public var paths: [String]?
  public init(action: String, root: String) { self.action = action; self.root = root }
}
public struct BridgeAssetResult: Codable, Sendable {
  public var companions: [BridgeCompanionText]?
  public var entries: [BridgeEntry]?
  public var fingerprint: String?
  public var unchanged: Bool?
  public var image: Data?
  public var metadata: [String: String]?
  public var text: [String: String]?
  public var sidecar: String?
  public var records: [BridgeStoredAsset]?
  public var recordID: UUID?
  public var error: String?
  public var resolvedFolder: String?
  public var outcomes: [BridgeDeleteOutcome]?
  public init() {}
}
public struct BridgeError: LocalizedError, Sendable {
  public let message: String
  public let sessionFailure: BridgeSessionFailure?
  public let resolvedFolder: String?
  public init(_ message: String, sessionFailure: BridgeSessionFailure? = nil, resolvedFolder: String? = nil) {
    self.message = message; self.sessionFailure = sessionFailure; self.resolvedFolder = resolvedFolder
  }
  public var errorDescription: String? { message }
}

public struct BridgeCompanionText: Codable, Hashable, Sendable {
  public var name: String
  public var text: String
  public init(name: String, text: String) { self.name = name; self.text = text }
}

public enum FrameBridgeEnvironment {
  // v7 keeps one authenticated connection per session: requests are multiplexed by id, a job's
  // status request is answered when the job changes, and the end of the connection ends the session.
  public static let protocolVersion = 7
  public static let maximumBatchAssets = 500
  public static let team = "39HYFR5Z65"
  public static let group = "39HYFR5Z65.FrameRelay"
  public static let frameBundle = "com.lx2026.Frame"
  public static let relayBundle = "com.lx2026.RelayBar"
  public static func root() throws -> URL {
    guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
      throw BridgeError("Install compatible signed versions of Frame and RelayBar to use remote folders.")
    }
    return root
  }
  public static func socketURL() throws -> URL { try root().appendingPathComponent("viewer.sock") }
  // Slashes are found byte by byte: a slash followed by a combining mark is one Character, and the file system
  // still splits the path there.
  public static func validPath(_ value: String) -> Bool {
    value.hasPrefix("/") && value.utf8.count <= 16_384
      && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
      && !value.utf8.split(separator: UInt8(ascii: "/")).contains(where: { $0.elementsEqual(".".utf8) || $0.elementsEqual("..".utf8) })
  }
  public static func validName(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && !value.utf8.contains(UInt8(ascii: "/")) && value.utf8.count <= 4_096
      && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
  public static func validSource(_ source: BridgeSource) -> Bool {
    source.id.count == 64 && source.id.allSatisfy { "0123456789abcdef".contains($0) }
      && !source.name.isEmpty && source.name.utf8.count <= 4_096
  }
  public static func verifyApplication(_ url: URL, bundleID: String) throws {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    let expression = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
          SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
          let requirement, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
      throw BridgeError("Install a trusted, compatible signed app to continue.")
    }
  }
  public static func verifyPeer(_ descriptor: Int32, bundleID: String) throws {
    var token = audit_token_t()
    var size = socklen_t(MemoryLayout.size(ofValue: token))
    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else {
      throw BridgeError("Cannot verify the other app's identity.")
    }
    let data = withUnsafeBytes(of: &token) { Data($0) }
    var code: SecCode?
    let attributes = [kSecGuestAttributeAudit: data, kSecGuestAttributeDynamicCode: true] as CFDictionary
    let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
    guard status == errSecSuccess, let code else {
      throw BridgeError("The other app is not a verified running application (\(status)).")
    }
    var requirement: SecRequirement?
    let expression = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
    guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
          let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
      throw BridgeError("The other app's signature is not trusted. Install compatible signed builds.")
    }
  }
}

/// One request on a session's connection. Replies carry the same id.
public struct BridgeCall: Codable, Sendable {
  public var id: UInt64
  public var request: BridgeRequest
  public init(id: UInt64, request: BridgeRequest) { self.id = id; self.request = request }
}

/// A reply to a call. Id 0 is a notice from RelayBar that the session is over, with the reason.
public struct BridgeReply: Codable, Sendable {
  public var id: UInt64
  public var response: BridgeResponse
  public init(id: UInt64, response: BridgeResponse) { self.id = id; self.response = response }
}

public enum BridgeSocket {
  static let maximumMessage = 8 * 1_024 * 1_024
  static let incompatible = "Update Frame and RelayBar to compatible versions."
  static func address(_ url: URL) throws -> sockaddr_un {
    let bytes = Array(url.path.utf8CString)
    var value = sockaddr_un()
    guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw BridgeError("The shared-container path is too long for the local bridge.") }
    value.sun_family = sa_family_t(AF_UNIX)
    value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &value.sun_path) { buffer in
      for (index, byte) in bytes.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
    }
    return value
  }
  /// A session's connection idles between requests, so reads never time out; writes still do.
  /// Returns false when the peer has already gone: macOS then refuses the options, and a write would raise SIGPIPE.
  @discardableResult
  static func configure(_ fd: Int32) -> Bool {
    var one: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0 else { return false }
    var time = timeval(tv_sec: 5, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout.size(ofValue: time)))
    return true
  }
  static func connect(_ url: URL) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw BridgeError("Could not create the local bridge connection.") }
    configure(fd)
    do {
      var address = try address(url)
      let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
      }
      guard result == 0 else { throw BridgeError("RelayBar isn't running or needs an update. Open RelayBar, then retry.") }
      return fd
    } catch { Darwin.close(fd); throw error }
  }
  static func receiveFrame(fd: Int32) throws -> Data {
    let header = try readExactly(4, fd: fd)
    let length = header.reduce(0) { ($0 << 8) | Int($1) }
    guard length > 0, length <= maximumMessage else { throw BridgeError("Invalid bridge message length.") }
    return try readExactly(length, fd: fd)
  }
  static func receive<T: Decodable>(_ type: T.Type, fd: Int32) throws -> T {
    try JSONDecoder().decode(type, from: receiveFrame(fd: fd))
  }
  static func readExactly(_ count: Int, fd: Int32) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < count {
        let amount = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
        if amount < 0 && errno == EINTR { continue }
        guard amount > 0 else { throw BridgeError("RelayBar is unavailable or the local connection ended. Retry when RelayBar is running.") }
        offset += amount
      }
    }
    return data
  }
  static func send<T: Encodable>(_ value: T, fd: Int32) throws {
    let body = try JSONEncoder().encode(value)
    guard body.count <= maximumMessage else { throw BridgeError("Bridge response is too large.") }
    var length = UInt32(body.count).bigEndian
    var data = withUnsafeBytes(of: &length) { Data($0) }; data.append(body)
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < data.count {
        let amount = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
        if amount < 0 && errno == EINTR { continue }
        guard amount > 0 else { throw BridgeError("The local bridge connection ended.") }
        offset += amount
      }
    }
  }
}

/// Frame's end of a session: one connection, authenticated once, carrying every request.
/// When the connection ends for any reason other than `close()`, `onClose` is told once.
public final class BridgeChannel: @unchecked Sendable {
  private let lock = NSLock()
  private let socketURL: URL?
  private let verifyPeer: @Sendable (Int32) throws -> Void
  private let onClose: @Sendable (BridgeError) -> Void
  private let writes = DispatchQueue(label: "FrameBridge.channel.write")
  /// The open connection, or -1. `end` interrupts it under the lock; only the reader closes it, on
  /// `writes` after every write queued before it, clearing this under the lock first. Writes read it
  /// on `writes`, so none can touch the number once it is released.
  private var fd: Int32 = -1
  private var opening: Task<Void, Error>?
  private var ended: BridgeError?
  private var closedByOwner = false
  private var nextID: UInt64 = 0
  private var waiting: [UInt64: CheckedContinuation<BridgeResponse, Error>] = [:]

  public init(socketURL: URL? = nil,
              verifyPeer: @escaping @Sendable (Int32) throws -> Void = {
                try FrameBridgeEnvironment.verifyPeer($0, bundleID: FrameBridgeEnvironment.relayBundle)
              }, onClose: @escaping @Sendable (BridgeError) -> Void = { _ in }) {
    self.socketURL = socketURL; self.verifyPeer = verifyPeer; self.onClose = onClose
  }

  /// Sends one request and waits for its reply. A cancelled caller stops waiting; if RelayBar had
  /// already accepted work for it, the late receipt is released.
  public func exchange(_ request: BridgeRequest) async throws -> BridgeResponse {
    try Task.checkCancellation()
    do { try await open() }
    catch {
      try Task.checkCancellation()
      throw BridgeError(error.localizedDescription, sessionFailure: (error as? BridgeError)?.sessionFailure ?? .unavailable)
    }
    let id = lock.withLock { nextID += 1; return nextID }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in self.send(id, request, continuation) }
    } onCancel: {
      lock.withLock { waiting.removeValue(forKey: id) }?.resume(throwing: CancellationError())
    }
  }

  private func send(_ id: UInt64, _ request: BridgeRequest, _ continuation: CheckedContinuation<BridgeResponse, Error>) {
    lock.lock()
    if let ended { lock.unlock(); continuation.resume(throwing: ended); return }
    waiting[id] = continuation
    lock.unlock()
    writes.async { [self] in
      do { try write(BridgeCall(id: id, request: request)) }
      catch { end(BridgeError(error.localizedDescription, sessionFailure: .unavailable)) }
    }
  }

  /// Runs on `writes`, where the reader also closes the connection.
  private func write(_ call: BridgeCall) throws {
    let fd = lock.withLock { self.fd }
    guard fd >= 0 else { throw BridgeError("The local bridge connection ended.") }
    try BridgeSocket.send(call, fd: fd)
  }

  /// Ends the session from this side. `onClose` is not called.
  public func close() {
    lock.lock(); closedByOwner = true; lock.unlock()
    end(BridgeError("The remote connection was closed.", sessionFailure: .unavailable))
  }

  private func open() async throws {
    let task = try lock.withLock { () throws -> Task<Void, Error> in
      if let ended { throw ended }
      if let opening { return opening }
      let task = Task.detached(priority: .userInitiated) { [self] in try connect() }
      opening = task
      return task
    }
    do { try await task.value }
    catch {
      // A failed attempt ends this channel; the owner makes a new one to try again.
      end(BridgeError(error.localizedDescription, sessionFailure: (error as? BridgeError)?.sessionFailure ?? .unavailable), notify: false)
      throw error
    }
  }

  /// Connects and verifies the peer once for the life of the session, then starts the reader.
  private func connect() throws {
    let url = try socketURL ?? FrameBridgeEnvironment.socketURL()
    let descriptor = try BridgeSocket.connect(url)
    do { try verifyPeer(descriptor) } catch { Darwin.close(descriptor); throw error }
    lock.lock()
    if ended != nil { lock.unlock(); Darwin.close(descriptor); throw CancellationError() }
    fd = descriptor
    lock.unlock()
    Thread.detachNewThread { [self] in read(descriptor) }
  }

  private func read(_ descriptor: Int32) {
    while true {
      let frame: Data
      do { frame = try BridgeSocket.receiveFrame(fd: descriptor) }
      catch { end(BridgeError(error.localizedDescription, sessionFailure: .unavailable)); break }
      guard let reply = try? JSONDecoder().decode(BridgeReply.self, from: frame) else {
        // A peer that does not speak this protocol answers with a bare response.
        end(BridgeError(BridgeSocket.incompatible, sessionFailure: .incompatible)); break
      }
      if reply.id == 0 {
        end(BridgeError(reply.response.error ?? "RelayBar ended the remote session.",
                        sessionFailure: reply.response.sessionFailure ?? .unavailable))
        break
      }
      lock.lock(); let continuation = waiting.removeValue(forKey: reply.id); lock.unlock()
      if let continuation { continuation.resume(returning: reply.response) }
      else if let job = reply.response.jobID, reply.response.version == FrameBridgeEnvironment.protocolVersion {
        // Nobody is waiting any more: give the accepted work back.
        lock.lock(); nextID += 1; let id = nextID; lock.unlock()
        var release = BridgeRequest("release"); release.jobID = job
        writes.async { [self] in try? write(BridgeCall(id: id, request: release)) }
      }
    }
    // Writes queued before this run first; one queued later finds the descriptor cleared.
    writes.async { [self] in
      lock.withLock { fd = -1 }
      Darwin.close(descriptor)
    }
  }

  private func end(_ error: BridgeError, notify: Bool = true) {
    lock.lock()
    guard ended == nil else { lock.unlock(); return }
    ended = error
    let pending = waiting; waiting.removeAll()
    let silent = closedByOwner
    // Under the lock, so the reader cannot release the number first.
    if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
    lock.unlock()
    for continuation in pending.values { continuation.resume(throwing: error) }
    if notify, !silent { onClose(error) }
  }
}

/// RelayBar's end: accepts Frame's connections, verifies each peer once, and serves its calls
/// until the connection ends. `onDisconnect` reports each connection that has gone away.
public final class BridgeSocketServer: @unchecked Sendable {
  public typealias Handler = @Sendable (BridgeRequest, UUID) async -> BridgeResponse
  private let descriptor: Int32
  private let url: URL
  private let connections: BridgeServerConnections
  private let source: DispatchSourceRead
  private let handler: Handler
  private let onDisconnect: @Sendable (UUID) -> Void
  private let verifyPeer: @Sendable (Int32) throws -> Void
  public init(url: URL,
              verifyPeer: @escaping @Sendable (Int32) throws -> Void = {
                try FrameBridgeEnvironment.verifyPeer($0, bundleID: FrameBridgeEnvironment.frameBundle)
              }, onDisconnect: @escaping @Sendable (UUID) -> Void = { _ in }, handler: @escaping Handler) throws {
    self.url = url; self.handler = handler; self.verifyPeer = verifyPeer; self.onDisconnect = onDisconnect
    // Caller owns this exact socket name; never remove an arbitrary file or symlink.
    if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
      guard attributes[.type] as? FileAttributeType == .typeSocket else { throw BridgeError("The bridge socket path is occupied.") }
      // Refuse a live endpoint (e.g. a second RelayBar instance).
      let probe = socket(AF_UNIX, SOCK_STREAM, 0)
      guard probe >= 0 else { throw BridgeError("Cannot inspect the bridge endpoint.") }
      var addr = try BridgeSocket.address(url)
      let connected = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
      }
      Darwin.close(probe)
      guard connected != 0 else { throw BridgeError("Another RelayBar bridge is already running.") }
      try FileManager.default.removeItem(at: url)
    }
    var address = try BridgeSocket.address(url)
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    descriptor = listener
    guard listener >= 0 else { throw BridgeError("Cannot create the bridge endpoint.") }
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, listen(descriptor, 8) == 0 else { Darwin.close(descriptor); throw BridgeError("Cannot start the bridge endpoint.") }
    chmod(url.path, 0o600)
    _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
    connections = BridgeServerConnections()
    source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "FrameBridge.accept"))
    source.setEventHandler { [weak self] in self?.acceptClient() }
    let fd = descriptor, connections = connections
    source.setCancelHandler { Darwin.close(fd); connections.listenerClosed() }
    source.resume()
  }
  deinit { connections.stop(); source.cancel() }

  public func stop() { connections.stop(); source.cancel() }
  public func close() async {
    stop()
    await withCheckedContinuation { continuation in
      connections.whenDrained { continuation.resume() }
    }
  }

  /// Tells every connected peer why its session is over, then ends those connections. New ones are still accepted.
  public func disconnectAll(_ notice: BridgeResponse) { connections.disconnectAll(BridgeReply(id: 0, response: notice)) }

  private func acceptClient() {
    let fd = accept(descriptor, nil, nil)
    guard fd >= 0 else { return }
    // Before anything can write to it. A peer that has already hung up is dropped unanswered.
    guard BridgeSocket.configure(fd) else { Darwin.close(fd); return }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
    guard let id = connections.register(fd) else { Darwin.close(fd); return }
    let connections = connections, handler = handler, verifyPeer = verifyPeer, onDisconnect = onDisconnect
    Thread.detachNewThread {
      defer { onDisconnect(id); connections.finished(id) }
      do { try verifyPeer(fd) }
      catch {
        connections.write(id, BridgeReply(id: 0, response: BridgeResponse(error: error.localizedDescription, sessionFailure: .unavailable)))
        return
      }
      while let frame = try? BridgeSocket.receiveFrame(fd: fd) {
        guard let call = try? JSONDecoder().decode(BridgeCall.self, from: frame), call.id != 0 else {
          // An older peer sends a bare request; answer in the shape it understands and end.
          connections.write(id, BridgeResponse(error: BridgeSocket.incompatible, sessionFailure: .incompatible))
          return
        }
        // Each call runs by itself, so one that waits on a job never delays another.
        connections.serve(id) {
          let response = await handler(call.request, id)
          connections.write(id, BridgeReply(id: call.id, response: response))
        }
      }
    }
  }
}

/// Closing a descriptor and interrupting its I/O share one lock, preventing reuse races.
private final class BridgeServerConnections: @unchecked Sendable {
  private struct Client { let fd: Int32; let writes = NSLock(); var tasks: [UUID: Task<Void, Never>] = [:] }
  private let lock = NSLock()
  private let group = DispatchGroup()
  private var clients: [UUID: Client] = [:]
  private var stopping = false
  init() { group.enter() } // The dispatch source owns the listener until its cancel handler runs.
  func listenerClosed() { group.leave() }
  func register(_ fd: Int32) -> UUID? {
    lock.lock(); defer { lock.unlock() }
    guard !stopping, clients.count < 8 else { return nil }
    let id = UUID(); clients[id] = Client(fd: fd); group.enter(); return id
  }
  /// Runs one call's handler, tracked so that closing waits for it and a lost connection cancels it.
  func serve(_ id: UUID, _ work: @escaping @Sendable () async -> Void) {
    lock.lock()
    guard clients[id] != nil else { lock.unlock(); return }
    let token = UUID()
    group.enter()
    let task = Task.detached { [self] in
      await work()
      lock.withLock { clients[id]?.tasks[token] = nil }
      group.leave()
    }
    clients[id]?.tasks[token] = task
    let cancel = stopping
    lock.unlock()
    if cancel { task.cancel() }
  }
  func write<T: Encodable>(_ id: UUID, _ value: T) {
    lock.lock(); let client = clients[id]; lock.unlock()
    guard let client else { return }
    client.writes.lock(); defer { client.writes.unlock() }
    // `finished` closes the descriptor under this lock after removing the client, so look again.
    guard lock.withLock({ clients[id] != nil }) else { return }
    try? BridgeSocket.send(value, fd: client.fd)
  }
  /// The reader has ended. Its calls are cancelled; the descriptor closes once they have returned.
  func finished(_ id: UUID) {
    lock.lock()
    guard let client = clients.removeValue(forKey: id) else { lock.unlock(); return }
    let tasks = Array(client.tasks.values)
    lock.unlock()
    _ = Darwin.shutdown(client.fd, SHUT_RDWR)
    for task in tasks { task.cancel() }
    Task.detached { [group] in
      for task in tasks { await task.value }
      // A write that found the client before it was removed finishes first.
      client.writes.withLock { _ = Darwin.close(client.fd) }
      group.leave()
    }
  }
  func disconnectAll(_ notice: BridgeReply) {
    lock.lock(); let current = Array(clients.keys); lock.unlock()
    for id in current {
      write(id, notice)
      // Only while it is registered: after `finished` its number may belong to another connection.
      lock.withLock { if let client = clients[id] { _ = Darwin.shutdown(client.fd, SHUT_RDWR) } }
    }
  }
  func stop() {
    lock.lock()
    stopping = true
    let tasks = clients.values.flatMap { $0.tasks.values }
    for client in clients.values { _ = Darwin.shutdown(client.fd, SHUT_RDWR) }
    lock.unlock()
    for task in tasks { task.cancel() }
  }
  func whenDrained(_ completion: @escaping @Sendable () -> Void) {
    group.notify(queue: .global(qos: .userInitiated), execute: completion)
  }
}
