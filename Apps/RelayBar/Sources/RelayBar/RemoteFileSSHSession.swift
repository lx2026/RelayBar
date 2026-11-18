import Darwin
import Foundation

/// Owns one foreground OpenSSH multiplexing master for a Remote Files window.
/// SFTP operations remain independent children; this object only removes their
/// repeated connection and authentication setup.
final class RemoteFileSSHSession: @unchecked Sendable {
    private final class FileManagerBox: @unchecked Sendable {
        let value: FileManager

        init(_ value: FileManager) {
            self.value = value
        }
    }

    private final class ErrorBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var data = Data()

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ newData: Data) {
            guard !newData.isEmpty else { return }
            lock.lock()
            data.append(newData)
            if data.count > limit {
                data = data.suffix(limit)
            }
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private final class Master: @unchecked Sendable {
        let id = UUID()
        let identity: RemoteServer.ConnectionIdentity
        let process: Process
        let directory: URL
        let socket: URL
        let errorPipe: Pipe
        let errorBuffer: ErrorBuffer
        let children: DispatchGroup
        var isReady = false

        private let cleanupLock = NSLock()
        private var didCleanUp = false

        init(
            identity: RemoteServer.ConnectionIdentity,
            process: Process,
            directory: URL,
            socket: URL,
            errorPipe: Pipe,
            errorBuffer: ErrorBuffer,
            children: DispatchGroup
        ) {
            self.identity = identity
            self.process = process
            self.directory = directory
            self.socket = socket
            self.errorPipe = errorPipe
            self.errorBuffer = errorBuffer
            self.children = children
            children.enter()
        }

        func stop(
            forceAfter delay: TimeInterval,
            signalProcess: @escaping @Sendable (pid_t, Int32) -> Int32
        ) {
            guard process.isRunning else { return }
            let processIdentifier = process.processIdentifier
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + delay
            ) { [weak process] in
                guard
                    let process,
                    process.isRunning,
                    process.processIdentifier == processIdentifier
                else {
                    return
                }
                _ = signalProcess(processIdentifier, SIGKILL)
            }
        }

        func cleanupAfterExit(fileManager: FileManager) -> String {
            cleanupLock.lock()
            guard !didCleanUp else {
                cleanupLock.unlock()
                return errorBuffer.text
            }
            didCleanUp = true
            cleanupLock.unlock()

            process.terminationHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            errorBuffer.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            try? errorPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForWriting.close()
            if directory.lastPathComponent.hasPrefix(
                RemoteFileSSHSession.privateDirectoryPrefix
            ) {
                try? fileManager.removeItem(at: directory)
            }
            children.leave()
            return errorBuffer.text
        }

        func cleanupAfterLaunchFailure(fileManager: FileManager) {
            cleanupLock.lock()
            guard !didCleanUp else {
                cleanupLock.unlock()
                return
            }
            didCleanUp = true
            cleanupLock.unlock()

            process.terminationHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? errorPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForWriting.close()
            if directory.lastPathComponent.hasPrefix(
                RemoteFileSSHSession.privateDirectoryPrefix
            ) {
                try? fileManager.removeItem(at: directory)
            }
            children.leave()
        }
    }

    private final class WaiterRequest: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private struct Waiter {
        let request: WaiterRequest
        let continuation: CheckedContinuation<URL, Error>
    }

    private let queue = DispatchQueue(label: "RelayBar.RemoteFileSSHSession")
    private let fileManager: FileManager
    private let executableURL: URL
    private let temporaryDirectory: URL
    private let processEnvironment: [String: String]?
    private let startupPollCount: Int
    private let startupPollInterval: TimeInterval
    private let forceStopDelay: TimeInterval
    private let signalProcess: @Sendable (pid_t, Int32) -> Int32
    private let errorOutputLimit: Int

    static let privateDirectoryPrefix = "RelayBar-SSH."
    static let controlSocketName = "s"
    static let openSSHBindTemporarySuffixByteCount = 17
    static let unixSocketPathByteCapacity = MemoryLayout.size(
        ofValue: sockaddr_un().sun_path
    )
    static let maximumControlSocketPathByteCount =
        unixSocketPathByteCapacity
        - 1 // NUL terminator
        - openSSHBindTemporarySuffixByteCount

    private var master: Master?
    private let children = DispatchGroup()
    private var waiters: [Waiter] = []

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        processEnvironment: [String: String]? = nil,
        startupPollCount: Int = 2_400,
        startupPollInterval: TimeInterval = 0.05,
        forceStopDelay: TimeInterval = 2,
        errorOutputLimit: Int = 16 * 1_024,
        signalProcess: @escaping @Sendable (pid_t, Int32) -> Int32 = {
            Darwin.kill($0, $1)
        }
    ) {
        self.executableURL = executableURL
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        self.processEnvironment = processEnvironment
        self.startupPollCount = startupPollCount
        self.startupPollInterval = startupPollInterval
        self.forceStopDelay = forceStopDelay
        self.errorOutputLimit = errorOutputLimit
        self.signalProcess = signalProcess
    }

    deinit {
        if let master {
            master.stop(forceAfter: forceStopDelay, signalProcess: signalProcess)
        }
    }

    func controlSocket(for server: RemoteServer) async throws -> URL {
        let request = WaiterRequest()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let socket = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<URL, Error>) in
                queue.async { [self] in
                    enqueue(
                        server: server,
                        request: request,
                        continuation: continuation
                    )
                }
            }
            try Task.checkCancellation()
            return socket
        } onCancel: { [self, request] in
            request.cancel()
            queue.async { [self, request] in
                cancelWaiter(request)
            }
        }
    }

    /// Signals synchronously so closing the window cannot leave a master
    /// accepting new channels. Reaping and directory cleanup finish from the
    /// process termination callback without blocking the main actor.
    func shutdown() {
        queue.sync { [self] in
            retireCurrentMaster(error: CancellationError())
        }
    }

    func shutdownAndWait() async {
        shutdown()
        await withCheckedContinuation { continuation in
            children.notify(queue: .global(qos: .utility)) { continuation.resume() }
        }
    }

    static func masterArguments(
        for server: RemoteServer,
        controlSocket: URL
    ) throws -> [String] {
        guard
            SSHArgumentPolicy.isValidHostTarget(server.sshHost),
            SSHArgumentPolicy.areAdditionalArgumentsSafe(server.additionalArguments)
        else {
            throw RemoteFileError.invalidConnection
        }

        var arguments = [
            "-N",
            "-T",
            "-M",
            "-S", controlSocket.path,
            "-a",
            "-x",
            "-o", "ControlPersist=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3"
        ]
        arguments.append(contentsOf: server.additionalArguments)
        arguments.append(server.sshHost)
        return arguments
    }

    private func enqueue(
        server: RemoteServer,
        request: WaiterRequest,
        continuation: CheckedContinuation<URL, Error>
    ) {
        if request.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        let identity = server.connectionIdentity
        if let master, master.identity == identity {
            if
                master.isReady,
                master.process.isRunning,
                fileManager.fileExists(atPath: master.socket.path)
            {
                continuation.resume(returning: master.socket)
                return
            }
            if master.isReady {
                // A ready master whose process or socket disappeared is stale.
                // The user action that discovered that state owns the restart;
                // termination itself never creates a reconnect loop.
                self.master = nil
                master.stop(
                    forceAfter: forceStopDelay,
                    signalProcess: signalProcess
                )
                waiters.append(
                    Waiter(request: request, continuation: continuation)
                )
                startMaster(for: server)
                return
            }
            waiters.append(
                Waiter(request: request, continuation: continuation)
            )
            return
        }

        if master != nil {
            retireCurrentMaster(error: CancellationError())
        }
        waiters.append(
            Waiter(request: request, continuation: continuation)
        )
        startMaster(for: server)
    }

    private func cancelWaiter(_ request: WaiterRequest) {
        guard let index = waiters.firstIndex(where: {
            $0.request.id == request.id
        }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func startMaster(for server: RemoteServer) {
        do {
            let locations = try makeControlLocations()
            let arguments = try Self.masterArguments(
                for: server,
                controlSocket: locations.socket
            )
            let process = Process()
            let errorPipe = Pipe()
            let errorBuffer = ErrorBuffer(limit: errorOutputLimit)
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = mergedEnvironment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    errorBuffer.append(data)
                }
            }

            let master = Master(
                identity: server.connectionIdentity,
                process: process,
                directory: locations.directory,
                socket: locations.socket,
                errorPipe: errorPipe,
                errorBuffer: errorBuffer,
                children: children
            )
            let cleanupFileManager = FileManagerBox(fileManager)
            process.terminationHandler = {
                [weak self, master, cleanupFileManager] process in
                guard let self else {
                    _ = master.cleanupAfterExit(
                        fileManager: cleanupFileManager.value
                    )
                    return
                }
                self.queue.async {
                    [weak self, master, cleanupFileManager] in
                    guard let self else {
                        _ = master.cleanupAfterExit(
                            fileManager: cleanupFileManager.value
                        )
                        return
                    }
                    self.masterDidExit(
                        master,
                        status: process.terminationStatus
                    )
                }
            }
            self.master = master

            do {
                try process.run()
            } catch {
                self.master = nil
                master.cleanupAfterLaunchFailure(fileManager: fileManager)
                resumeWaiters(throwing: error)
                return
            }
            pollForReadiness(master: master, attempt: 0)
        } catch {
            resumeWaiters(throwing: error)
        }
    }

    private func pollForReadiness(master: Master, attempt: Int) {
        guard self.master === master else { return }
        if
            master.process.isRunning,
            fileManager.fileExists(atPath: master.socket.path)
        {
            master.isReady = true
            resumeWaiters(returning: master.socket)
            return
        }
        if !master.process.isRunning {
            masterDidExit(master, status: master.process.terminationStatus)
            return
        }
        guard attempt < startupPollCount else {
            self.master = nil
            resumeWaiters(throwing: RemoteFileError.connectionSessionUnavailable)
            master.stop(forceAfter: forceStopDelay, signalProcess: signalProcess)
            return
        }
        queue.asyncAfter(deadline: .now() + startupPollInterval) { [self, master] in
            pollForReadiness(master: master, attempt: attempt + 1)
        }
    }

    private func masterDidExit(_ master: Master, status: Int32) {
        let errorOutput = master.cleanupAfterExit(fileManager: fileManager)
        guard self.master === master else { return }
        self.master = nil
        guard !master.isReady || !waiters.isEmpty else { return }
        let message = SFTPRemoteFileService.friendlyMessage(from: errorOutput)
        resumeWaiters(
            throwing: RemoteFileError.commandFailed(
                status == 0 && message == "The remote operation failed."
                    ? "The SSH connection closed before Remote Files was ready."
                    : message
            )
        )
    }

    private func retireCurrentMaster(error: Error) {
        guard let master else {
            resumeWaiters(throwing: error)
            return
        }
        self.master = nil
        resumeWaiters(throwing: error)
        master.stop(forceAfter: forceStopDelay, signalProcess: signalProcess)
    }

    private func resumeWaiters(returning socket: URL) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(returning: socket)
        }
    }

    private func resumeWaiters(throwing error: Error) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(throwing: error)
        }
    }

    private func makeControlLocations() throws -> (directory: URL, socket: URL) {
        let templateURL = temporaryDirectory.appendingPathComponent(
            "\(Self.privateDirectoryPrefix)XXXXXXXX",
            isDirectory: true
        )
        var template = Array(templateURL.path.utf8CString)
        let didCreateDirectory = template.withUnsafeMutableBufferPointer {
            buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            return Darwin.mkdtemp(baseAddress) != nil
        }
        guard didCreateDirectory else {
            throw RemoteFileError.connectionSessionUnavailable
        }
        let directoryPath = template.withUnsafeBufferPointer { buffer in
            String(cString: buffer.baseAddress!)
        }
        let directory = URL(
            fileURLWithPath: directoryPath,
            isDirectory: true
        )
        let socket = directory.appendingPathComponent(Self.controlSocketName)

        // OpenSSH's mux listener first binds a sibling path using the
        // `.XXXXXXXXXXXXXXXX` suffix from mux.c, then renames it to the final
        // ControlPath. Both that suffix and the terminating NUL must fit
        // within Darwin's sockaddr_un.sun_path.
        guard
            socket.path.utf8.count
                <= Self.maximumControlSocketPathByteCount
        else {
            try? fileManager.removeItem(at: directory)
            throw RemoteFileError.connectionSessionUnavailable
        }
        return (directory, socket)
    }

    private var mergedEnvironment: [String: String] {
        guard let processEnvironment else {
            return ProcessInfo.processInfo.environment
        }
        return ProcessInfo.processInfo.environment.merging(processEnvironment) {
            _, override in override
        }
    }
}
