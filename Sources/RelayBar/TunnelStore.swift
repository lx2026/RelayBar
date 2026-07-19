import AppKit
import Foundation

@MainActor
final class TunnelStore: ObservableObject {
    static let shared = TunnelStore()

    @Published private(set) var tunnels: [Tunnel]
    @Published private(set) var phases: [UUID: TunnelPhase] = [:]

    private let defaults: UserDefaults
    private let sshExecutableURL: URL
    private let maxRetryAttempts: Int
    private let retryDelayProvider: (Int) -> TimeInterval
    private let browserOpener: (URL) -> Void
    private let storageKey = "savedTunnels.v1"
    private var processes: [UUID: Process] = [:]
    private var errorPipes: [UUID: Pipe] = [:]
    private var errorBuffers: [UUID: Data] = [:]
    private var desiredTunnels: [UUID: Tunnel] = [:]
    private var retryAttempts: [UUID: Int] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingBrowserURLs: [UUID: URL] = [:]

    init(
        defaults: UserDefaults = .standard,
        sshExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        maxRetryAttempts: Int = 10,
        retryDelayProvider: @escaping (Int) -> TimeInterval = TunnelStore.retryDelay(for:),
        browserOpener: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    ) {
        self.defaults = defaults
        self.sshExecutableURL = sshExecutableURL
        self.maxRetryAttempts = max(0, maxRetryAttempts)
        self.retryDelayProvider = retryDelayProvider
        self.browserOpener = browserOpener
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
        phases.values.filter {
            switch $0 {
            case .starting, .retrying, .running:
                return true
            case .stopped, .failed:
                return false
            }
        }.count
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
        let wasActive = desiredTunnels[tunnel.id] != nil
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
        if desiredTunnels[tunnel.id] != nil {
            stop(tunnel)
        } else {
            start(tunnel)
        }
    }

    func start(_ tunnel: Tunnel) {
        guard desiredTunnels[tunnel.id] == nil, processes[tunnel.id] == nil else { return }
        guard tunnel.isSafeToRun else {
            phases[tunnel.id] = .failed("This tunnel contains an invalid host or blocked SSH option.")
            return
        }

        cancelRetry(for: tunnel.id)
        desiredTunnels[tunnel.id] = tunnel
        retryAttempts[tunnel.id] = 0
        launchTunnel(id: tunnel.id)
    }

    func openInBrowser(_ tunnel: Tunnel) {
        guard tunnel.isSafeToRun else {
            phases[tunnel.id] = .failed("This tunnel contains an invalid host or blocked SSH option.")
            return
        }

        pendingBrowserURLs[tunnel.id] = tunnel.browserURL
        if phase(for: tunnel) == .running, processes[tunnel.id]?.isRunning == true {
            openPendingBrowserURL(for: tunnel.id)
        } else if desiredTunnels[tunnel.id] == nil {
            start(tunnel)
        }
    }

    func stop(_ tunnel: Tunnel) {
        stop(id: tunnel.id)
    }

    func stopAll() {
        let activeIDs = Set(desiredTunnels.keys)
            .union(processes.keys)
            .union(retryTasks.keys)
        for id in activeIDs {
            stop(id: id)
        }
    }

    func quit() {
        stopAll()
        NSApplication.shared.terminate(nil)
    }

    nonisolated static func retryDelay(for attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 6)
        return min(pow(2, Double(exponent)), 60)
    }

    private func launchTunnel(id: UUID) {
        guard let tunnel = desiredTunnels[id], processes[id] == nil else { return }

        errorBuffers[tunnel.id] = Data()
        phases[tunnel.id] = .starting

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = sshExecutableURL
        process.arguments = [
            "-N",
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-L", tunnel.forwardSpec
        ] + tunnel.additionalArguments + [tunnel.sshHost]
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
                store.processDidExit(id: tunnelID, status: status, process: finishedProcess)
            }
        }

        processes[tunnel.id] = process
        errorPipes[tunnel.id] = errorPipe

        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self, weak process] in
                guard
                    let self,
                    let process,
                    self.desiredTunnels[tunnel.id] != nil,
                    self.processes[tunnel.id] === process,
                    process.isRunning
                else { return }
                self.retryAttempts[tunnel.id] = 0
                self.phases[tunnel.id] = .running
                self.openPendingBrowserURL(for: tunnel.id)
            }
        } catch {
            cleanupRuntime(for: tunnel.id, process: process)
            scheduleRetry(for: tunnel.id, message: error.localizedDescription)
        }
    }

    private func stop(id: UUID) {
        desiredTunnels[id] = nil
        retryAttempts[id] = nil
        pendingBrowserURLs[id] = nil
        cancelRetry(for: id)
        phases[id] = .stopped

        guard let process = processes[id] else {
            return
        }
        if process.isRunning { process.terminate() }
    }

    private func appendError(_ data: Data, for id: UUID) {
        var buffer = errorBuffers[id] ?? Data()
        buffer.append(data)
        if buffer.count > 16_384 {
            buffer = buffer.suffix(16_384)
        }
        errorBuffers[id] = buffer
    }

    private func processDidExit(id: UUID, status: Int32, process: Process) {
        guard processes[id] === process else { return }
        let message = errorMessage(for: id)
        cleanupRuntime(for: id, process: process)

        guard desiredTunnels[id] != nil else {
            phases[id] = tunnels.contains(where: { $0.id == id }) ? .stopped : nil
            return
        }

        if message.isEmpty {
            let fallback = status == 0
                ? "SSH connection closed."
                : "SSH exited with status \(status)."
            scheduleRetry(for: id, message: fallback)
        } else {
            scheduleRetry(for: id, message: message)
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

    private func scheduleRetry(for id: UUID, message: String) {
        guard desiredTunnels[id] != nil else {
            phases[id] = .stopped
            return
        }

        let attempt = (retryAttempts[id] ?? 0) + 1
        guard attempt <= maxRetryAttempts else {
            desiredTunnels[id] = nil
            retryAttempts[id] = nil
            pendingBrowserURLs[id] = nil
            phases[id] = .failed(
                "\(message) Automatic retry stopped after \(maxRetryAttempts) attempts."
            )
            return
        }

        cancelRetry(for: id)
        retryAttempts[id] = attempt
        let delay = max(0, retryDelayProvider(attempt))
        phases[id] = .retrying(
            attempt: attempt,
            maxAttempts: maxRetryAttempts,
            delay: delay,
            message: message
        )

        retryTasks[id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }

            guard
                !Task.isCancelled,
                let self,
                self.desiredTunnels[id] != nil
            else { return }

            self.retryTasks[id] = nil
            self.launchTunnel(id: id)
        }
    }

    private func cancelRetry(for id: UUID) {
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
    }

    private func openPendingBrowserURL(for id: UUID) {
        guard let url = pendingBrowserURLs.removeValue(forKey: id) else { return }
        browserOpener(url)
    }

    private func cleanupRuntime(for id: UUID, process: Process? = nil) {
        if let process, processes[id] !== process {
            return
        }
        errorPipes[id]?.fileHandleForReading.readabilityHandler = nil
        errorPipes[id] = nil
        errorBuffers[id] = nil
        processes[id] = nil
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tunnels) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
