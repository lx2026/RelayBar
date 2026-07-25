import AppKit
import Darwin
import Foundation

@MainActor
final class TunnelStore: ObservableObject {
    static let shared = TunnelStore()

    @Published private(set) var tunnels: [Tunnel] {
        didSet { cachedGrouping = nil }
    }
    private var cachedGrouping: TunnelGrouping?
    @Published private(set) var phases: [UUID: TunnelPhase] = [:]
    @Published private(set) var runtimePorts: [UUID: [UUID: Int]] = [:]

    private let defaults: UserDefaults
    private let sshExecutableURL: URL
    private let maxRetryAttempts: Int
    private let retryDelayProvider: (Int) -> TimeInterval
    private let browserOpener: (URL) -> Void
    private let processEnvironment: [String: String]?
    private let controlOperationTimeout: TimeInterval
    private let storageKey = "savedTunnels.v2"
    private let legacyStorageKey = "savedTunnels.v1"
    private let controlOutputLimit = 64 * 1_024
    private let masterErrorOutputLimit = 16 * 1_024
    private let localSocketPathLimit = 103

    private var processes: [UUID: Process] = [:]
    private var errorPipes: [UUID: Pipe] = [:]
    private var errorBuffers: [UUID: Data] = [:]
    private var desiredTunnels: [UUID: Tunnel] = [:]
    private var retryAttempts: [UUID: Int] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var startupTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingBrowserURLs: [UUID: URL] = [:]
    private var startupFailureMessages: [UUID: String] = [:]
    private var controlDirectories: [UUID: URL] = [:]
    private var controlSocketURLs: [UUID: URL] = [:]
    private var ownedLocalSockets: [UUID: [OwnedSocket]] = [:]

    // Control operations are keyed by their own identifier and tagged with the
    // launch generation that owns them, so a superseded launch's teardown can
    // neither block nor complete the launch that replaced it.
    private var controlOperations: [UUID: ControlOperation] = [:]
    private var launchGenerations: [UUID: UUID] = [:]

    init(
        defaults: UserDefaults = .standard,
        sshExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        maxRetryAttempts: Int = 10,
        retryDelayProvider: @escaping (Int) -> TimeInterval = TunnelStore.retryDelay(for:),
        browserOpener: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
        processEnvironment: [String: String]? = nil,
        controlOperationTimeout: TimeInterval = 10
    ) {
        self.defaults = defaults
        self.sshExecutableURL = sshExecutableURL
        self.maxRetryAttempts = max(0, maxRetryAttempts)
        self.retryDelayProvider = retryDelayProvider
        self.browserOpener = browserOpener
        self.processEnvironment = processEnvironment
        self.controlOperationTimeout = max(0.1, controlOperationTimeout)

        if
            let data = defaults.data(forKey: storageKey),
            let saved = try? JSONDecoder().decode([Tunnel].self, from: data)
        {
            tunnels = saved
        } else if
            let data = defaults.data(forKey: legacyStorageKey),
            let migrated = try? JSONDecoder().decode([Tunnel].self, from: data),
            let encoded = try? JSONEncoder().encode(migrated)
        {
            tunnels = migrated
            defaults.set(encoded, forKey: storageKey)
        } else {
            tunnels = []
        }
    }

    var runningCount: Int {
        phases.values.count {
            switch $0 {
            case .starting, .retrying, .running:
                true
            case .stopped, .failed:
                false
            }
        }
    }

    /// Rebuilt only when `tunnels` changes. Views evaluate their bodies on every
    /// phase publish, so deriving sections per evaluation would repeat the
    /// bucketing and localized sort on every retry tick.
    var grouping: TunnelGrouping {
        if let cachedGrouping { return cachedGrouping }
        let grouping = TunnelGrouping(tunnels: tunnels)
        cachedGrouping = grouping
        return grouping
    }

    var groupNames: [String] {
        grouping.groupNames
    }

    func phase(for tunnel: Tunnel) -> TunnelPhase {
        phases[tunnel.id] ?? .stopped
    }

    func runtimePorts(for tunnel: Tunnel) -> [UUID: Int] {
        runtimePorts[tunnel.id] ?? [:]
    }

    func add(_ tunnel: Tunnel) {
        guard let tunnel = resolvingGroupTag(in: tunnel) else { return }
        tunnels.append(tunnel)
        save()
    }

    func update(_ tunnel: Tunnel) {
        guard
            let index = tunnels.firstIndex(where: { $0.id == tunnel.id }),
            let tunnel = resolvingGroupTag(in: tunnel)
        else {
            return
        }
        let previous = tunnels[index]
        if previous.hasSameNonTagFields(as: tunnel) {
            applyGroupTag(tunnel.groupTag, at: index)
            return
        }

        let wasActive = desiredTunnels[tunnel.id] != nil
        if wasActive { stop(tunnel) }
        tunnels[index] = tunnel
        phases[tunnel.id] = .stopped
        save()
    }

    func move(_ tunnel: Tunnel, toGroup rawGroup: String?) {
        guard let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) else {
            return
        }
        let groupTag: String?
        if let rawGroup {
            guard
                case .valid(let resolved) = TunnelGroupTag.resolve(
                    rawGroup,
                    existingNames: groupNames
                )
            else {
                return
            }
            groupTag = resolved
        } else {
            groupTag = nil
        }
        applyGroupTag(groupTag, at: index)
    }

    func renameGroup(_ groupName: String, to rawGroup: String) {
        let sourceKey = TunnelGroupTag.canonicalKey(groupName)
        guard
            case .valid(let resolved) = TunnelGroupTag.resolve(
                rawGroup,
                existingNames: groupNames
            )
        else {
            return
        }

        var changed = false
        for index in tunnels.indices where tunnels[index].groupTag.map(
            TunnelGroupTag.canonicalKey
        ) == sourceKey {
            guard tunnels[index].groupTag != resolved else { continue }
            tunnels[index].groupTag = resolved
            if desiredTunnels[tunnels[index].id] != nil {
                desiredTunnels[tunnels[index].id]?.groupTag = resolved
            }
            changed = true
        }
        if changed { save() }
    }

    func ungroup(_ groupName: String) {
        let key = TunnelGroupTag.canonicalKey(groupName)
        var changed = false
        for index in tunnels.indices where tunnels[index].groupTag.map(
            TunnelGroupTag.canonicalKey
        ) == key {
            tunnels[index].groupTag = nil
            if desiredTunnels[tunnels[index].id] != nil {
                desiredTunnels[tunnels[index].id]?.groupTag = nil
            }
            changed = true
        }
        if changed { save() }
    }

    func delete(_ tunnel: Tunnel) {
        stop(tunnel)
        tunnels.removeAll { $0.id == tunnel.id }
        phases[tunnel.id] = nil
        runtimePorts[tunnel.id] = nil
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
            phases[tunnel.id] = .failed(
                "This profile contains an invalid endpoint, conflicting listener, or blocked SSH option."
            )
            return
        }
        if let preflightError = preflightLocalSockets(for: tunnel) {
            phases[tunnel.id] = .failed(preflightError)
            return
        }

        cancelRetry(for: tunnel.id)
        desiredTunnels[tunnel.id] = tunnel
        retryAttempts[tunnel.id] = 0
        runtimePorts[tunnel.id] = nil
        launchTunnel(id: tunnel.id)
    }

    func openInBrowser(_ tunnel: Tunnel) {
        guard let rule = tunnel.rules.first, tunnel.rules.count == 1 else {
            phases[tunnel.id] = .failed(
                "Only a profile with one local TCP forward can open as an HTTP URL."
            )
            return
        }
        openInBrowser(tunnel, ruleID: rule.id)
    }

    func openInBrowser(_ tunnel: Tunnel, ruleID: UUID) {
        guard
            tunnel.isSafeToRun,
            let browserURL = tunnel.rules.first(where: { $0.id == ruleID })?.localBrowserURL
        else {
            phases[tunnel.id] = .failed(
                "This forwarding rule does not provide a local HTTP endpoint."
            )
            return
        }

        pendingBrowserURLs[tunnel.id] = browserURL
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
            .union(startupTasks.keys)
            .union(controlOperations.values.map(\.tunnelID))
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

        let generation = UUID()
        launchGenerations[id] = generation
        runtimePorts[id] = nil
        startupFailureMessages[id] = nil
        cleanupControlDirectory(for: id)
        cleanupOwnedLocalSockets(for: id)

        let controlLocations: (directory: URL, socket: URL)
        do {
            controlLocations = try makeControlLocations(for: id)
        } catch {
            scheduleRetry(for: id, message: error.localizedDescription)
            return
        }

        controlDirectories[id] = controlLocations.directory
        controlSocketURLs[id] = controlLocations.socket
        errorBuffers[id] = Data()
        phases[id] = .starting

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = sshExecutableURL
        process.arguments = masterArguments(
            tunnel: tunnel,
            controlSocket: controlLocations.socket
        )
        process.environment = mergedEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        let store = self
        let tunnelID = tunnel.id

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                store.appendMasterError(data, for: tunnelID)
            }
        }

        process.terminationHandler = { finishedProcess in
            let status = finishedProcess.terminationStatus
            DispatchQueue.main.async {
                store.processDidExit(
                    id: tunnelID,
                    status: status,
                    process: finishedProcess
                )
            }
        }

        processes[id] = process
        errorPipes[id] = errorPipe

        do {
            try process.run()
            waitForControlSocket(
                id: id,
                generation: generation,
                process: process,
                socketURL: controlLocations.socket
            )
        } catch {
            cleanupRuntime(for: id, process: process)
            scheduleRetry(for: id, message: error.localizedDescription)
        }
    }

    private func masterArguments(tunnel: Tunnel, controlSocket: URL) -> [String] {
        var arguments = [
            "-N",
            "-T",
            "-M",
            "-S", controlSocket.path,
            "-o", "ControlPersist=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StreamLocalBindMask=\(tunnel.streamLocalSettings.bindMaskArgument)",
            // RelayBar removes only sockets whose inode it recorded after creation.
            "-o", "StreamLocalBindUnlink=no"
        ]

        if tunnel.hasReverseSOCKS, let policy = tunnel.reverseSOCKSPolicy {
            arguments.append(contentsOf: ["-o", "PermitRemoteOpen=\(policy.sshValue)"])
        }

        arguments.append(contentsOf: tunnel.additionalArguments)
        arguments.append(tunnel.sshHost)
        return arguments
    }

    private func waitForControlSocket(
        id: UUID,
        generation: UUID,
        process: Process,
        socketURL: URL
    ) {
        startupTasks[id]?.cancel()
        startupTasks[id] = Task { @MainActor [weak self, weak process] in
            guard let self, let process else { return }
            for _ in 0..<240 {
                guard
                    !Task.isCancelled,
                    self.desiredTunnels[id] != nil,
                    self.processes[id] === process,
                    process.isRunning
                else {
                    return
                }

                if FileManager.default.fileExists(atPath: socketURL.path) {
                    await self.installRules(
                        id: id,
                        generation: generation,
                        process: process
                    )
                    return
                }

                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
            }

            guard self.processes[id] === process, process.isRunning else { return }
            self.failStartup(
                id: id,
                process: process,
                message: "SSH connected but its private control socket did not become ready."
            )
        }
    }

    private func installRules(id: UUID, generation: UUID, process: Process) async {
        guard
            let tunnel = desiredTunnels[id],
            let socketURL = controlSocketURLs[id],
            processes[id] === process
        else {
            return
        }

        var allocations: [UUID: Int] = [:]
        for rule in tunnel.rules {
            guard
                !Task.isCancelled,
                desiredTunnels[id] != nil,
                processes[id] === process,
                process.isRunning
            else {
                return
            }

            if let socketError = preflightCreatedSocket(
                for: rule,
                tunnel: tunnel,
                tunnelID: id
            ) {
                failStartup(id: id, process: process, message: socketError)
                return
            }

            let result = await runControlForward(
                tunnelID: id,
                generation: generation,
                tunnel: tunnel,
                rule: rule,
                socketURL: socketURL
            )

            guard
                !Task.isCancelled,
                desiredTunnels[id] != nil,
                processes[id] === process
            else {
                return
            }

            guard result.status == 0 else {
                failStartup(
                    id: id,
                    process: process,
                    message: result.actionableMessage
                )
                return
            }

            if rule.kind.listensRemotely, rule.listen.tcp?.port == 0 {
                guard let allocatedPort = parseAllocatedPort(result.output) else {
                    failStartup(
                        id: id,
                        process: process,
                        message: "OpenSSH did not report the allocated remote port for \(rule.kind.label)."
                    )
                    return
                }
                allocations[rule.id] = allocatedPort
            }

            recordOwnedSocketCreated(by: rule, tunnelID: id)
        }

        guard
            desiredTunnels[id] != nil,
            processes[id] === process,
            process.isRunning
        else {
            return
        }

        startupTasks[id] = nil
        runtimePorts[id] = allocations.isEmpty ? nil : allocations
        retryAttempts[id] = 0
        phases[id] = .running
        openPendingBrowserURL(for: id)
    }

    private func runControlForward(
        tunnelID: UUID,
        generation: UUID,
        tunnel: Tunnel,
        rule: ForwardingRule,
        socketURL: URL
    ) async -> ControlResult {
        let operationID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard launchGenerations[tunnelID] == generation else {
                    continuation.resume(
                        returning: ControlResult(
                            status: -1,
                            output: "",
                            error: "This SSH launch was replaced before the rule was installed."
                        )
                    )
                    return
                }
                guard !controlOperations.values.contains(
                    where: { $0.generation == generation }
                ) else {
                    continuation.resume(
                        returning: ControlResult(
                            status: -1,
                            output: "",
                            error: "Another SSH control operation is still running."
                        )
                    )
                    return
                }

                let process = Process()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                controlOperations[operationID] = ControlOperation(
                    tunnelID: tunnelID,
                    generation: generation,
                    process: process,
                    outputPipe: outputPipe,
                    errorPipe: errorPipe,
                    continuation: continuation
                )

                process.executableURL = sshExecutableURL
                process.arguments = [
                    "-F", "none",
                    "-S", socketURL.path,
                    "-O", "forward"
                ] + rule.sshArguments + [tunnel.sshHost]
                process.environment = mergedEnvironment
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                outputPipe.fileHandleForReading.readabilityHandler =
                    controlOutputHandler(operationID: operationID, isError: false)
                errorPipe.fileHandleForReading.readabilityHandler =
                    controlOutputHandler(operationID: operationID, isError: true)

                process.terminationHandler = { finishedProcess in
                    let status = finishedProcess.terminationStatus
                    DispatchQueue.main.async {
                        self.finishControlOperation(
                            operationID: operationID,
                            process: finishedProcess,
                            status: status
                        )
                    }
                }

                do {
                    try process.run()
                    scheduleControlTimeout(operationID: operationID, process: process)
                } catch {
                    finishControlOperation(
                        operationID: operationID,
                        process: process,
                        status: -1,
                        launchError: error.localizedDescription
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let process = self?.controlOperations[operationID]?.process else {
                    return
                }
                if process.isRunning { process.terminate() }
            }
        }
    }

    private func controlOutputHandler(
        operationID: UUID,
        isError: Bool
    ) -> @Sendable (FileHandle) -> Void {
        // Stays on the main queue rather than hopping through a Task so that
        // appends keep FIFO order with the termination handler's dispatch.
        { [self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self.appendControlOutput(
                    data,
                    operationID: operationID,
                    isError: isError
                )
            }
        }
    }

    private func finishControlOperation(
        operationID: UUID,
        process: Process,
        status: Int32,
        launchError: String? = nil
    ) {
        guard let operation = controlOperations[operationID],
              operation.process === process
        else {
            return
        }

        // Detach the readability handlers before reading the same descriptors
        // synchronously, so one reader owns each pipe. Removing the operation
        // first also makes any handler block still in flight inert.
        operation.clearPipeHandlers()
        controlOperations.removeValue(forKey: operationID)
        operation.timeoutTask?.cancel()

        var buffers = operation.buffers
        // Only a launched process closes the write ends these reads wait on. If
        // the launch itself failed, no child ever held them, there is nothing to
        // drain, and reading to end of file would block the main queue forever.
        if launchError == nil {
            buffers.append(
                operation.outputPipe.fileHandleForReading.readDataToEndOfFile(),
                isError: false,
                limit: controlOutputLimit
            )
            buffers.append(
                operation.errorPipe.fileHandleForReading.readDataToEndOfFile(),
                isError: true,
                limit: controlOutputLimit
            )
        }

        operation.continuation.resume(
            returning: ControlResult(
                status: status,
                output: buffers.text(isError: false),
                error: launchError ?? buffers.text(isError: true)
            )
        )
    }

    private func scheduleControlTimeout(operationID: UUID, process: Process) {
        controlOperations[operationID]?.timeoutTask?.cancel()
        controlOperations[operationID]?.timeoutTask = Task {
            @MainActor [weak self, weak process] in
            guard let self, let process else { return }
            do {
                try await Task.sleep(for: .seconds(controlOperationTimeout))
            } catch {
                return
            }
            guard
                controlOperations[operationID]?.process === process,
                process.isRunning
            else {
                return
            }
            appendControlOutput(
                Data("SSH control operation timed out.\n".utf8),
                operationID: operationID,
                isError: true
            )
            process.terminate()
        }
    }

    private func appendControlOutput(
        _ data: Data,
        operationID: UUID,
        isError: Bool
    ) {
        controlOperations[operationID]?.buffers.append(
            data,
            isError: isError,
            limit: controlOutputLimit
        )
    }

    private func parseAllocatedPort(_ output: String) -> Int? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.allSatisfy(\.isNumber),
            let port = Int(trimmed),
            (1...65_535).contains(port)
        else {
            return nil
        }
        return port
    }

    private func failStartup(id: UUID, process: Process, message: String) {
        guard processes[id] === process else { return }
        startupFailureMessages[id] = message
        startupTasks[id]?.cancel()
        startupTasks[id] = nil
        if process.isRunning {
            process.terminate()
        } else {
            processDidExit(id: id, status: process.terminationStatus, process: process)
        }
    }

    private func stop(id: UUID) {
        desiredTunnels[id] = nil
        retryAttempts[id] = nil
        pendingBrowserURLs[id] = nil
        runtimePorts[id] = nil
        startupFailureMessages[id] = nil
        cancelRetry(for: id)
        startupTasks[id]?.cancel()
        startupTasks[id] = nil
        phases[id] = .stopped

        launchGenerations[id] = nil
        for operation in controlOperations.values where operation.tunnelID == id {
            if operation.process.isRunning { operation.process.terminate() }
        }

        if let process = processes[id] {
            if process.isRunning { process.terminate() }
            cleanupRuntime(for: id, process: process)
        } else {
            cleanupOwnedLocalSockets(for: id)
            cleanupControlDirectory(for: id)
        }
    }

    private func appendMasterError(_ data: Data, for id: UUID) {
        errorBuffers[id] = appendingBounded(
            data,
            to: errorBuffers[id] ?? Data(),
            limit: masterErrorOutputLimit
        )
    }

    private func processDidExit(id: UUID, status: Int32, process: Process) {
        guard processes[id] === process else { return }
        let startupMessage = startupFailureMessages.removeValue(forKey: id)
        let message = startupMessage ?? errorMessage(for: id)
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
        guard
            let data = errorBuffers[id],
            let output = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return output
            .split(whereSeparator: \Character.isNewline)
            .suffix(2)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleRetry(for id: UUID, message: String) {
        runtimePorts[id] = nil
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
            else {
                return
            }

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
        launchGenerations[id] = nil
        startupTasks[id]?.cancel()
        startupTasks[id] = nil
        errorPipes[id]?.fileHandleForReading.readabilityHandler = nil
        errorPipes[id] = nil
        errorBuffers[id] = nil
        processes[id] = nil
        runtimePorts[id] = nil
        cleanupOwnedLocalSockets(for: id)
        cleanupControlDirectory(for: id)
    }

    private func makeControlLocations(
        for id: UUID
    ) throws -> (directory: URL, socket: URL) {
        let profile = id.uuidString.replacingOccurrences(of: "-", with: "").prefix(6)
        let launch = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayBar-SSH-\(profile)\(launch)", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let socket = directory.appendingPathComponent("control")
        guard socket.path.utf8.count <= localSocketPathLimit else {
            try? FileManager.default.removeItem(at: directory)
            throw TunnelStoreError.controlPathTooLong
        }
        return (directory, socket)
    }

    private func cleanupControlDirectory(for id: UUID) {
        controlSocketURLs[id] = nil
        guard let directory = controlDirectories.removeValue(forKey: id) else { return }
        guard directory.lastPathComponent.hasPrefix("RelayBar-SSH-") else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func preflightLocalSockets(for tunnel: Tunnel) -> String? {
        for path in tunnel.createdLocalSocketPaths {
            guard path.utf8.count <= localSocketPathLimit else {
                return "The local Unix socket path is too long for macOS: \(path)"
            }
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: parent.path,
                    isDirectory: &isDirectory
                ),
                isDirectory.boolValue,
                FileManager.default.isWritableFile(atPath: parent.path)
            else {
                return "The local Unix socket folder is missing or not writable: \(parent.path)"
            }
            if let identity = fileIdentity(at: path) {
                if
                    tunnel.streamLocalSettings.unlinkStaleSocket,
                    isOwnedSocket(path: path, identity: identity, tunnelID: tunnel.id)
                {
                    cleanupOwnedLocalSockets(for: tunnel.id, matching: path)
                    if fileIdentity(at: path) == nil {
                        continue
                    }
                }
                return "RelayBar will not replace an existing filesystem item at \(path)."
            }
        }
        return nil
    }

    private func preflightCreatedSocket(
        for rule: ForwardingRule,
        tunnel: Tunnel,
        tunnelID: UUID
    ) -> String? {
        guard let path = rule.createdLocalSocketPath else { return nil }
        guard let identity = fileIdentity(at: path) else { return nil }
        guard isOwnedSocket(path: path, identity: identity, tunnelID: tunnelID) else {
            return "RelayBar will not replace an existing filesystem item at \(path)."
        }
        guard tunnel.streamLocalSettings.unlinkStaleSocket else {
            return "A RelayBar-owned socket remains at \(path). Enable stale-socket cleanup to retry safely."
        }
        cleanupOwnedLocalSockets(for: tunnelID, matching: path)
        return fileIdentity(at: path) == nil
            ? nil
            : "The previous RelayBar-owned socket could not be removed: \(path)"
    }

    private func isOwnedSocket(
        path: String,
        identity: (device: UInt64, inode: UInt64, isSocket: Bool),
        tunnelID: UUID
    ) -> Bool {
        identity.isSocket && ownedLocalSockets[tunnelID]?.contains {
            $0.path == path
                && $0.device == identity.device
                && $0.inode == identity.inode
        } == true
    }

    private func recordOwnedSocketCreated(by rule: ForwardingRule, tunnelID: UUID) {
        guard
            let path = rule.createdLocalSocketPath,
            let identity = fileIdentity(at: path),
            identity.isSocket
        else {
            return
        }
        var sockets = ownedLocalSockets[tunnelID] ?? []
        sockets.removeAll { $0.path == path }
        sockets.append(
            OwnedSocket(
                path: path,
                device: identity.device,
                inode: identity.inode
            )
        )
        ownedLocalSockets[tunnelID] = sockets
    }

    private func cleanupOwnedLocalSockets(for id: UUID, matching path: String? = nil) {
        guard var sockets = ownedLocalSockets[id] else { return }
        var retained: [OwnedSocket] = []
        for socket in sockets {
            if let path, socket.path != path {
                retained.append(socket)
                continue
            }
            guard
                let identity = fileIdentity(at: socket.path),
                identity.isSocket,
                identity.device == socket.device,
                identity.inode == socket.inode
            else {
                continue
            }
            do {
                try FileManager.default.removeItem(atPath: socket.path)
            } catch {
                retained.append(socket)
            }
        }
        sockets = retained
        ownedLocalSockets[id] = sockets.isEmpty ? nil : sockets
    }

    private func fileIdentity(
        at path: String
    ) -> (device: UInt64, inode: UInt64, isSocket: Bool)? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            isSocket: (info.st_mode & S_IFMT) == S_IFSOCK
        )
    }

    private var mergedEnvironment: [String: String] {
        guard let processEnvironment else { return ProcessInfo.processInfo.environment }
        return ProcessInfo.processInfo.environment.merging(processEnvironment) { _, override in
            override
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tunnels) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func resolvingGroupTag(in tunnel: Tunnel) -> Tunnel? {
        var resolvedTunnel = tunnel
        guard let groupTag = tunnel.groupTag else { return resolvedTunnel }
        guard
            case .valid(let resolved) = TunnelGroupTag.resolve(
                groupTag,
                existingNames: groupNames
            )
        else {
            return nil
        }
        resolvedTunnel.groupTag = resolved
        return resolvedTunnel
    }

    private func applyGroupTag(_ groupTag: String?, at index: Int) {
        guard tunnels[index].groupTag != groupTag else { return }
        tunnels[index].groupTag = groupTag
        let id = tunnels[index].id
        if desiredTunnels[id] != nil {
            desiredTunnels[id]?.groupTag = groupTag
        }
        save()
    }
}

private struct OwnedSocket {
    let path: String
    let device: UInt64
    let inode: UInt64
}

/// Appends `data` and keeps only the trailing `limit` bytes. Every bounded
/// process-output buffer in this file trims through here.
private func appendingBounded(_ data: Data, to buffer: Data, limit: Int) -> Data {
    guard !data.isEmpty else { return buffer }
    var result = buffer
    result.append(data)
    return result.count > limit ? result.suffix(limit) : result
}

private struct ControlOutputBuffers {
    private var output = Data()
    private var error = Data()

    mutating func append(_ data: Data, isError: Bool, limit: Int) {
        if isError {
            error = appendingBounded(data, to: error, limit: limit)
        } else {
            output = appendingBounded(data, to: output, limit: limit)
        }
    }

    func text(isError: Bool) -> String {
        String(data: isError ? error : output, encoding: .utf8) ?? ""
    }
}

/// One `ssh -O forward` invocation. `generation` names the `launchTunnel` call
/// that owns it so state from a replaced launch stays inert.
private struct ControlOperation {
    let tunnelID: UUID
    let generation: UUID
    let process: Process
    let outputPipe: Pipe
    let errorPipe: Pipe
    let continuation: CheckedContinuation<ControlResult, Never>
    var timeoutTask: Task<Void, Never>?
    var buffers = ControlOutputBuffers()

    func clearPipeHandlers() {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
    }
}

private struct ControlResult {
    let status: Int32
    let output: String
    let error: String

    var actionableMessage: String {
        let lines = error
            .split(whereSeparator: \Character.isNewline)
            .suffix(2)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !lines.isEmpty { return lines }
        return status == 0
            ? "The SSH forwarding request ended without a result."
            : "SSH could not install a forwarding rule (status \(status))."
    }
}

private enum TunnelStoreError: LocalizedError {
    case controlPathTooLong

    var errorDescription: String? {
        switch self {
        case .controlPathTooLong:
            "The private SSH control path is too long for macOS."
        }
    }
}
