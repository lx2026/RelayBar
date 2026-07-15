import AppKit
import Foundation

@MainActor
final class TunnelStore: ObservableObject {
    static let shared = TunnelStore()

    @Published private(set) var tunnels: [Tunnel]
    @Published private(set) var phases: [UUID: TunnelPhase] = [:]

    private let defaults: UserDefaults
    private let storageKey = "savedTunnels.v1"
    private var processes: [UUID: Process] = [:]
    private var errorPipes: [UUID: Pipe] = [:]
    private var errorBuffers: [UUID: Data] = [:]
    private var scopedIdentityURLs: [UUID: URL] = [:]
    private var intentionalStops: Set<UUID> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if
            let data = defaults.data(forKey: storageKey),
            let saved = try? JSONDecoder().decode([Tunnel].self, from: data)
        {
            tunnels = saved
        } else {
            tunnels = []
        }
    }

    var runningCount: Int {
        phases.values.filter { $0 == .running || $0 == .starting }.count
    }

    func phase(for tunnel: Tunnel) -> TunnelPhase {
        phases[tunnel.id] ?? .stopped
    }

    func add(_ tunnel: Tunnel) {
        tunnels.append(tunnel)
        save()
    }

    func update(_ tunnel: Tunnel) {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else { return }
        let wasActive = processes[tunnel.id] != nil
        if wasActive { stop(tunnel) }
        tunnels[index] = tunnel
        phases[tunnel.id] = .stopped
        save()
    }

    func delete(_ tunnel: Tunnel) {
        stop(tunnel)
        tunnels.removeAll { $0.id == tunnel.id }
        phases[tunnel.id] = nil
        save()
    }

    func toggle(_ tunnel: Tunnel) {
        if processes[tunnel.id] == nil {
            start(tunnel)
        } else {
            stop(tunnel)
        }
    }

    func start(_ tunnel: Tunnel) {
        guard processes[tunnel.id] == nil else { return }
        guard tunnel.isSafeToRun else {
            phases[tunnel.id] = .failed("This tunnel contains an invalid host or blocked SSH option.")
            return
        }

        intentionalStops.remove(tunnel.id)
        errorBuffers[tunnel.id] = Data()
        phases[tunnel.id] = .starting

        let managedArguments: [String]
        do {
            managedArguments = try managedSSHArguments(for: tunnel)
        } catch {
            cleanupRuntime(for: tunnel.id)
            phases[tunnel.id] = .failed(error.localizedDescription)
            return
        }

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-N",
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-L", tunnel.forwardSpec
        ] + managedArguments + tunnel.additionalArguments + [tunnel.sshHost]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        let store = self
        let tunnelID = tunnel.id

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                store.appendError(data, for: tunnelID)
            }
        }

        process.terminationHandler = { finishedProcess in
            let status = finishedProcess.terminationStatus
            DispatchQueue.main.async {
                store.processDidExit(id: tunnelID, status: status)
            }
        }

        processes[tunnel.id] = process
        errorPipes[tunnel.id] = errorPipe

        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self, weak process] in
                guard let self, let process, self.processes[tunnel.id] === process, process.isRunning else { return }
                self.phases[tunnel.id] = .running
            }
        } catch {
            cleanupRuntime(for: tunnel.id)
            phases[tunnel.id] = .failed(error.localizedDescription)
        }
    }

    func stop(_ tunnel: Tunnel) {
        guard let process = processes[tunnel.id] else {
            phases[tunnel.id] = .stopped
            return
        }
        intentionalStops.insert(tunnel.id)
        phases[tunnel.id] = .stopped
        if process.isRunning { process.terminate() }
    }

    func stopAll() {
        for tunnel in tunnels where processes[tunnel.id] != nil {
            stop(tunnel)
        }
    }

    func quit() {
        stopAll()
        NSApplication.shared.terminate(nil)
    }

    private func appendError(_ data: Data, for id: UUID) {
        var buffer = errorBuffers[id] ?? Data()
        buffer.append(data)
        if buffer.count > 16_384 {
            buffer = buffer.suffix(16_384)
        }
        errorBuffers[id] = buffer
    }

    private func processDidExit(id: UUID, status: Int32) {
        let wasIntentional = intentionalStops.remove(id) != nil
        let message = errorMessage(for: id)
        cleanupRuntime(for: id)

        guard tunnels.contains(where: { $0.id == id }) else { return }
        if wasIntentional || status == 0 {
            phases[id] = .stopped
        } else {
            phases[id] = .failed(message.isEmpty ? "SSH exited with status \(status)." : message)
        }
    }

    private func errorMessage(for id: UUID) -> String {
        guard let data = errorBuffers[id], let output = String(data: data, encoding: .utf8) else { return "" }
        return output
            .split(whereSeparator: \Character.isNewline)
            .suffix(2)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanupRuntime(for id: UUID) {
        errorPipes[id]?.fileHandleForReading.readabilityHandler = nil
        errorPipes[id] = nil
        errorBuffers[id] = nil
        processes[id] = nil
        scopedIdentityURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
    }

    private func managedSSHArguments(for tunnel: Tunnel) throws -> [String] {
        var arguments: [String] = []

        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            let directory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RelayBar", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let knownHosts = directory.appendingPathComponent("known_hosts")
            if !FileManager.default.fileExists(atPath: knownHosts.path) {
                guard FileManager.default.createFile(
                    atPath: knownHosts.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw TunnelLaunchError.knownHostsUnavailable
                }
            }
            arguments += [
                "-F", "/dev/null",
                "-o", "UserKnownHostsFile=\(knownHosts.path)",
                "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "StrictHostKeyChecking=accept-new"
            ]

            guard tunnel.identityBookmark != nil else {
                throw TunnelLaunchError.identityRequired
            }
        }

        if let bookmark = tunnel.identityBookmark {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard !isStale, url.startAccessingSecurityScopedResource() else {
                throw TunnelLaunchError.identityAccessExpired
            }
            scopedIdentityURLs[tunnel.id] = url
            arguments += ["-i", url.path, "-o", "IdentitiesOnly=yes"]
        }

        return arguments
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tunnels) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

private enum TunnelLaunchError: LocalizedError {
    case knownHostsUnavailable
    case identityRequired
    case identityAccessExpired

    var errorDescription: String? {
        switch self {
        case .knownHostsUnavailable:
            return "RelayBar could not prepare its private known-hosts file."
        case .identityRequired:
            return "Choose an identity key before starting this tunnel."
        case .identityAccessExpired:
            return "Access to the selected identity key expired. Edit the tunnel and choose the key again."
        }
    }
}
