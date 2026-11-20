#if os(macOS)
  import CryptoKit
  import Darwin
  import Foundation
  import Testing
  @testable import MobileCore

  private enum FixtureError: Error { case setup(String) }

  private func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
  }

  func loopbackPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw FixtureError.setup("socket") }
    defer { Darwin.close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(address.sin_len)
    let result = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
        guard bind(fd, pointer, length) == 0 else { return Int32(-1) }
        return getsockname(fd, pointer, &length)
      }
    }
    guard result == 0 else { throw FixtureError.setup("bind") }
    return UInt16(bigEndian: address.sin_port)
  }

  final class OpenSSHFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let port: UInt16
    let signingKey = P256.Signing.PrivateKey()
    private var daemon: Process?
    private let didExit = DispatchSemaphore(value: 0)

    init() throws {
      port = try loopbackPort()
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      do {
        let key = folder.appendingPathComponent("host").path
        let (status, message) = try run(
          "/usr/bin/ssh-keygen", ["-q", "-N", "", "-t", "ed25519", "-f", key])
        guard status == 0 else { throw FixtureError.setup(message) }
        let authorized = DeviceKey.memory(signingKey).authorizedKey
        try Data((authorized + "\n").utf8).write(
          to: folder.appendingPathComponent("authorized_keys"))
        let config = """
          Port \(port)
          ListenAddress 127.0.0.1
          PidFile "\(folder.path)/pid"
          HostKey "\(key)"
          AuthorizedKeysFile "\(folder.path)/authorized_keys"
          UsePAM no
          StrictModes no
          PasswordAuthentication no
          KbdInteractiveAuthentication no
          PermitUserRC no
          ForceCommand internal-sftp
          AllowTcpForwarding no
          AllowAgentForwarding no
          PermitTTY no
          Subsystem sftp internal-sftp
          """
        try Data(config.utf8).write(to: folder.appendingPathComponent("config"))
      } catch {
        try? FileManager.default.removeItem(at: folder)
        throw error
      }
    }

    func start() async throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
      process.arguments = [
        "-D", "-E", folder.appendingPathComponent("log").path,
        "-f", folder.appendingPathComponent("config").path,
      ]
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      let pidFile = folder.appendingPathComponent("pid")
      try? FileManager.default.removeItem(at: pidFile)
      let exit = didExit
      process.terminationHandler = { _ in exit.signal() }
      try process.run()
      daemon = process
      for _ in 0..<200 {
        guard process.isRunning else {
          throw FixtureError.setup("sshd exited with status \(process.terminationStatus)")
        }
        if FileManager.default.fileExists(atPath: pidFile.path) { return }
        try await Task.sleep(for: .milliseconds(10))
      }
      throw FixtureError.setup("sshd startup timed out")
    }

    func stop() {
      guard let daemon, daemon.isRunning else { return }
      // OpenSSH keeps established sessions alive after its listening process exits.
      // Stop this fixture's own session descendants while their parent still exists.
      func terminateChildren(_ pid: Int32) {
        guard let (_, children) = try? run("/usr/bin/pgrep", ["-P", String(pid)]) else { return }
        for child in children.split(whereSeparator: \.isWhitespace).compactMap({ Int32($0) }) {
          terminateChildren(child)
          kill(child, SIGTERM)
        }
      }
      terminateChildren(daemon.processIdentifier)
      daemon.terminate()
      if didExit.wait(timeout: .now() + 3) == .timedOut,
        kill(daemon.processIdentifier, 0) == 0, daemon.isRunning
      {
        kill(daemon.processIdentifier, SIGKILL)
        if didExit.wait(timeout: .now() + 2) == .timedOut, kill(daemon.processIdentifier, 0) == 0 {
          Issue.record("The test server did not exit.")
        }
      }
      self.daemon = nil
    }

    func cleanup() {
      stop()
      do { try FileManager.default.removeItem(at: folder) } catch {
        Issue.record("Could not remove the sshd fixture")
      }
    }

  }
#endif
