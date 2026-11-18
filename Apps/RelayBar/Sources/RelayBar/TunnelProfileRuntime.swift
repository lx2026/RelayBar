import AppKit
import Composition
import Darwin
import Foundation

/// One profile owns its launch generations, retries, controls and retiring children.
@MainActor
final class TunnelProfileRuntime {
    let id: UUID
    var didChange: (() -> Void)?
    private(set) var phase: TunnelPhase = .stopped { didSet { didChange?() } }
    private(set) var runtimePorts: [UUID: Int] = [:] { didSet { didChange?() } }
    private(set) var terminatingSSHProcessCount = 0 { didSet { didChange?() } }
    private(set) var maxRetryAttempts: Int
    private(set) var isClosed = false
    var isRequested: Bool { desiredTunnel != nil }
    var hasManagedResources: Bool {
        masterProcess != nil || retryTask != nil || startupTask != nil || !controlOperations.isEmpty
            || terminatingSSHProcessCount > 0 || work.count > 0 || reapers.count > 0
    }

    private let sshExecutableURL: URL
    private let retryDelayProvider: (Int) -> TimeInterval
    private let monotonicNow: () -> TimeInterval
    private let browserOpener: (URL) -> Void
    private var authorized: Bool { !isClosed }
    private let processEnvironment: [String: String]?
    private let controlOperationTimeout: TimeInterval
    private let processTerminationGracePeriod: TimeInterval
    private let controlOutputLimit = 64 * 1_024
    private let masterErrorOutputLimit = 16 * 1_024
    private let localSocketPathLimit = 103
    private let work = EffectScope()
    // Reaping stays admitted until every cancelled child has actually exited.
    private let reapers = EffectScope()

    private var masterProcess: Process?
    private var terminatingSSHProcesses: Set<ObjectIdentifier> = []
    private var forceTerminationTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var errorPipe: Pipe?
    private var errorBuffer: Data?
    private var desiredTunnel: Tunnel?
    private var retryAttempt = 0
    private var runningSince: TimeInterval?
    private var retryTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var pendingBrowserURL: URL?
    private var startupFailureMessage: String?
    private var controlDirectory: URL?
    private var controlSocketURL: URL?
    private var ownedLocalSockets: [OwnedSocket] = []
    private var controlOperations: [UUID: ControlOperation] = [:]
    private var launchGeneration: UUID?

    init(id: UUID, sshExecutableURL: URL, maxRetryAttempts: Int,
         retryDelayProvider: @escaping (Int) -> TimeInterval,
         monotonicNow: @escaping () -> TimeInterval,
         browserOpener: @escaping (URL) -> Void,
         processEnvironment: [String: String]?, controlOperationTimeout: TimeInterval,
         processTerminationGracePeriod: TimeInterval) {
        self.id = id; self.sshExecutableURL = sshExecutableURL
        self.maxRetryAttempts = maxRetryAttempts; self.retryDelayProvider = retryDelayProvider
        self.monotonicNow = monotonicNow; self.browserOpener = browserOpener
        self.processEnvironment = processEnvironment
        self.controlOperationTimeout = controlOperationTimeout
        self.processTerminationGracePeriod = processTerminationGracePeriod
    }

    func invalidate() {
        isClosed = true
        stop(id: id)
        work.invalidate()
    }

    func shutdown() async {
        invalidate()
        await work.dispose()
        // Startup cancellation may still be waiting for a stubborn ssh -O child.
        while terminatingSSHProcessCount > 0 || !controlOperations.isEmpty {
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { await Task.yield() }
        }
        await reapers.dispose()
    }

    func start(_ tunnel: Tunnel) {
        guard !isClosed, tunnel.id == id else { return }
        guard desiredTunnel == nil, masterProcess == nil else { return }
        guard tunnel.isSafeToRun else {
            phase = .failed(
                "This profile contains an invalid endpoint, conflicting listener, or blocked SSH option."
            )
            return
        }
        if let preflightError = preflightLocalSockets(for: tunnel) {
            phase = .failed(preflightError)
            return
        }

        cancelRetry(for: tunnel.id)
        desiredTunnel = tunnel
        retryAttempt = 0
        runtimePorts = [:]
        launchTunnel(id: tunnel.id)
    }

    func openInBrowser(_ tunnel: Tunnel) {
        guard !isClosed, tunnel.id == id else { return }
        guard let rule = tunnel.rules.first, tunnel.rules.count == 1 else {
            phase = .failed(
                "Only a profile with one local TCP forward can open as an HTTP URL."
            )
            return
        }
        openInBrowser(tunnel, ruleID: rule.id)
    }

    func openInBrowser(_ tunnel: Tunnel, ruleID: UUID) {
        guard !isClosed, tunnel.id == id else { return }
        guard
            tunnel.isSafeToRun,
            let browserURL = tunnel.rules.first(where: { $0.id == ruleID })?.localBrowserURL
        else {
            phase = .failed(
                "This forwarding rule does not provide a local HTTP endpoint."
            )
            return
        }

        pendingBrowserURL = browserURL
        if phase == .running, masterProcess?.isRunning == true {
            openPendingBrowserURL(for: tunnel.id)
        } else if desiredTunnel == nil {
            start(tunnel)
        }
    }

    func stop() { stop(id: id) }

    func setMaxRetryAttempts(_ limit: Int) {
        maxRetryAttempts = min(max(0, limit), TunnelStore.retryLimitRange.upperBound)

        if retryTask != nil {
            guard case .retrying(let attempt, _, let delay, let message) = phase else {
                return
            }
            if attempt > maxRetryAttempts {
                finishAutomaticRetries(for: id, message: message)
            } else {
                // Keep the existing deadline; changing the limit must not
                // shorten backoff or restart the current wait.
                phase = .retrying(
                    attempt: attempt, maxAttempts: maxRetryAttempts,
                    delay: delay, message: message
                )
            }
        }
    }

    /// Makes a scheduled retry now instead of at the end of its backoff, as the same attempt and under
    /// the same checks as the waiting task. Does nothing when no retry is scheduled.
    func retryNow() {
        guard retryTask != nil, case .retrying(let attempt, _, _, _) = phase else { return }
        guard authorized, desiredTunnel != nil else { return }
        cancelRetry(for: id)
        retryAttempt = attempt
        launchTunnel(id: id)
    }

    private func launchTunnel(id: UUID) {
        guard !isClosed, let tunnel = desiredTunnel, masterProcess == nil else { return }

        let generation = UUID()
        launchGeneration = generation
        runtimePorts = [:]
        startupFailureMessage = nil
        cleanupControlDirectory(for: id)
        cleanupOwnedLocalSockets(for: id)

        let controlLocations: (directory: URL, socket: URL)
        do {
            controlLocations = try makeControlLocations(for: id)
        } catch {
            scheduleRetry(for: id, message: error.localizedDescription)
            return
        }

        controlDirectory = controlLocations.directory
        controlSocketURL = controlLocations.socket
        errorBuffer = Data()
        phase = .starting

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
                store.appendMasterError(data, generation: generation)
            }
        }

        process.terminationHandler = { finishedProcess in
            let status = finishedProcess.terminationStatus
            DispatchQueue.main.async {
                store.recordSSHProcessTermination(finishedProcess)
                store.processDidExit(
                    id: tunnelID,
                    status: status,
                    process: finishedProcess
                )
            }
        }

        masterProcess = process
        self.errorPipe = errorPipe

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
        startupTask?.cancel()
        startupTask = try? work.task { @MainActor [weak self, weak process] in
            guard let self, let process else { return }
            for _ in 0..<240 {
                guard
                    !Task.isCancelled,
                    self.authorized,
                    self.desiredTunnel != nil,
                    self.masterProcess === process,
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

            guard self.authorized, self.masterProcess === process, process.isRunning else { return }
            self.failStartup(
                id: id,
                process: process,
                message: "SSH connected but its private control socket did not become ready."
            )
        }
    }

    private func installRules(id: UUID, generation: UUID, process: Process) async {
        guard
            authorized,
            let tunnel = desiredTunnel,
            let socketURL = controlSocketURL,
            masterProcess === process
        else {
            return
        }

        var allocations: [UUID: Int] = [:]
        for rule in tunnel.rules {
            guard
                !Task.isCancelled,
                authorized,
                desiredTunnel != nil,
                masterProcess === process,
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
                authorized,
                desiredTunnel != nil,
                masterProcess === process
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
            authorized,
            desiredTunnel != nil,
            masterProcess === process,
            process.isRunning
        else {
            return
        }

        startupTask = nil
        runtimePorts = allocations
        runningSince = monotonicNow()
        phase = .running
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
                guard authorized, launchGeneration == generation else {
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
                        self.recordSSHProcessTermination(finishedProcess)
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
                self?.stopManagedSSHProcess(process)
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
        controlOperations[operationID]?.timeoutTask = try? work.task {
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
            stopManagedSSHProcess(process)
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
        guard masterProcess === process else { return }
        startupFailureMessage = message
        startupTask?.cancel()
        startupTask = nil
        if process.isRunning {
            stopManagedSSHProcess(process)
        } else {
            processDidExit(id: id, status: process.terminationStatus, process: process)
        }
    }

    private func stop(id: UUID) {
        desiredTunnel = nil
        retryAttempt = 0
        pendingBrowserURL = nil
        runtimePorts = [:]
        startupFailureMessage = nil
        cancelRetry(for: id)
        startupTask?.cancel()
        startupTask = nil
        phase = .stopped

        launchGeneration = nil
        for operation in controlOperations.values where operation.tunnelID == id {
            stopManagedSSHProcess(operation.process)
        }

        if let process = masterProcess {
            stopManagedSSHProcess(process)
            cleanupRuntime(for: id, process: process)
        } else {
            cleanupOwnedLocalSockets(for: id)
            cleanupControlDirectory(for: id)
        }
    }

    private func stopManagedSSHProcess(_ process: Process) {
        guard process.isRunning else { return }
        let identifier = ObjectIdentifier(process)
        let processIdentifier = process.processIdentifier
        guard terminatingSSHProcesses.insert(identifier).inserted else { return }
        terminatingSSHProcessCount = terminatingSSHProcesses.count
        forceTerminationTasks[identifier] = try? reapers.task {
            @MainActor [weak self, weak process] in
            guard let self, let process else { return }
            do {
                try await Task.sleep(for: .seconds(processTerminationGracePeriod))
            } catch {
                return
            }
            guard
                terminatingSSHProcesses.contains(identifier),
                process.isRunning,
                process.processIdentifier == processIdentifier
            else {
                return
            }
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
        process.terminate()
    }

    private func recordSSHProcessTermination(_ process: Process) {
        let identifier = ObjectIdentifier(process)
        forceTerminationTasks.removeValue(forKey: identifier)?.cancel()
        guard terminatingSSHProcesses.remove(identifier) != nil else { return }
        terminatingSSHProcessCount = terminatingSSHProcesses.count
    }

    private func appendMasterError(_ data: Data, generation: UUID) {
        guard authorized, launchGeneration == generation else { return }
        errorBuffer = appendingBounded(
            data,
            to: errorBuffer ?? Data(),
            limit: masterErrorOutputLimit
        )
    }

    private func processDidExit(id: UUID, status: Int32, process: Process) {
        guard masterProcess === process else { return }
        let startupMessage = startupFailureMessage
        startupFailureMessage = nil
        let message = startupMessage ?? errorMessage(for: id)
        // A brief successful reconnect must not replenish the retry budget.
        if let started = runningSince, monotonicNow() - started >= 60 {
            retryAttempt = 0
        }
        cleanupRuntime(for: id, process: process)

        guard desiredTunnel != nil else {
            phase = .stopped
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
            let data = errorBuffer,
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
        runtimePorts = [:]
        guard !isClosed, desiredTunnel != nil else {
            phase = .stopped
            return
        }

        let attempt = retryAttempt + 1
        guard attempt <= maxRetryAttempts else {
            finishAutomaticRetries(for: id, message: message)
            return
        }

        cancelRetry(for: id)
        let delay = max(0, retryDelayProvider(attempt))
        phase = .retrying(
            attempt: attempt,
            maxAttempts: maxRetryAttempts,
            delay: delay,
            message: message
        )

        retryTask = try? work.task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }

            guard
                !Task.isCancelled,
                let self,
                self.authorized,
                self.desiredTunnel != nil
            else {
                return
            }

            self.retryTask = nil
            self.retryAttempt = attempt
            self.launchTunnel(id: id)
        }
    }

    private func finishAutomaticRetries(for id: UUID, message: String) {
        let attempts = retryAttempt
        let reason = maxRetryAttempts == 0
            ? "Automatic retries are disabled."
            : "Automatic retry stopped after \(attempts) \(attempts == 1 ? "attempt" : "attempts")."
        cancelRetry(for: id)
        desiredTunnel = nil
        retryAttempt = 0
        pendingBrowserURL = nil
        phase = .failed("\(message) \(reason)")
    }

    private func cancelRetry(for id: UUID) {
        retryTask?.cancel()
        retryTask = nil
    }

    private func openPendingBrowserURL(for id: UUID) {
        guard authorized, let url = pendingBrowserURL else { return }
        pendingBrowserURL = nil
        browserOpener(url)
    }

    private func cleanupRuntime(for id: UUID, process: Process? = nil) {
        if let process, masterProcess !== process {
            return
        }
        launchGeneration = nil
        startupTask?.cancel()
        startupTask = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe = nil
        errorBuffer = nil
        masterProcess = nil
        runningSince = nil
        runtimePorts = [:]
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
        controlSocketURL = nil
        guard let directory = controlDirectory else { return }
        controlDirectory = nil
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
        identity.isSocket && ownedLocalSockets.contains {
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
        var sockets = ownedLocalSockets
        sockets.removeAll { $0.path == path }
        sockets.append(
            OwnedSocket(
                path: path,
                device: identity.device,
                inode: identity.inode
            )
        )
        ownedLocalSockets = sockets
    }

    private func cleanupOwnedLocalSockets(for id: UUID, matching path: String? = nil) {
        var sockets = ownedLocalSockets
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
        ownedLocalSockets = sockets
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
