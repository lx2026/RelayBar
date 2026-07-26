import Darwin
import Foundation

protocol RemoteFileServing: AnyObject, Sendable {
    func list(server: RemoteServer, path: String) async throws -> [RemoteFileEntry]
    func download(
        server: RemoteServer,
        entry: RemoteFileEntry,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws
    func preparePreview(server: RemoteServer, entry: RemoteFileEntry) async throws -> URL
}

/// Configuration is immutable after initialization. Each command owns separate
/// process state, and the small boxes shared with callbacks synchronize access.
final class SFTPRemoteFileService: RemoteFileServing, @unchecked Sendable {
    private struct CommandResult {
        let status: Int32
        let output: String
        let error: String
        let exceededOutputLimit: Bool
    }

    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private let forceStopDelay: TimeInterval
        private let signalProcess: @Sendable (pid_t, Int32) -> Int32
        private var processIdentifier: pid_t?
        private var exitSource: DispatchSourceProcess?
        private var exitHandler: (@Sendable (Int32) -> Void)?
        private var cancellationRequested = false
        private var forceStopScheduled = false
        private var terminationSignalSent = false

        init(
            forceStopDelay: TimeInterval,
            signalProcess: @escaping @Sendable (pid_t, Int32) -> Int32
        ) {
            self.forceStopDelay = forceStopDelay
            self.signalProcess = signalProcess
        }

        var shouldStart: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !cancellationRequested
        }

        func beginWaiting(
            for processIdentifier: pid_t,
            onExit: @escaping @Sendable (Int32) -> Void
        ) {
            lock.lock()
            self.processIdentifier = processIdentifier
            exitHandler = onExit
            let exitSource = DispatchSource.makeProcessSource(
                identifier: processIdentifier,
                eventMask: .exit,
                queue: DispatchQueue.global(qos: .utility)
            )
            self.exitSource = exitSource
            exitSource.setEventHandler { [weak self] in
                self?.processDidExit()
            }
            exitSource.resume()
            lock.unlock()
        }

        func cancel() {
            var shouldScheduleForceStop = false
            lock.lock()
            cancellationRequested = true
            if let processIdentifier {
                if !terminationSignalSent {
                    terminationSignalSent = true
                    _ = signalProcess(processIdentifier, SIGTERM)
                }
                if !forceStopScheduled {
                    forceStopScheduled = true
                    shouldScheduleForceStop = true
                }
            }
            lock.unlock()

            if shouldScheduleForceStop {
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + forceStopDelay
                ) {
                    [weak self] in
                    self?.forceStop()
                }
            }
        }

        @discardableResult
        func stopIfCancellationRequested() -> Bool {
            lock.lock()
            let wasRequested = cancellationRequested
            lock.unlock()
            if wasRequested {
                cancel()
            }
            return wasRequested
        }

        private func processDidExit() {
            lock.lock()
            let completion = reapExitedProcessLocked()
            let shouldRetry = processIdentifier != nil
            lock.unlock()
            complete(completion)
            if shouldRetry {
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + .milliseconds(10)
                ) { [weak self] in
                    self?.processDidExit()
                }
            }
        }

        private func forceStop() {
            lock.lock()
            let completion = reapExitedProcessLocked()
            if completion == nil, let processIdentifier {
                // Reaping and signalling share this lock. If the child exits
                // after the nonblocking wait, it remains an unreaped zombie
                // until this signal attempt finishes, so its PID cannot be
                // recycled and the signal cannot reach an unrelated process.
                _ = signalProcess(processIdentifier, SIGKILL)
            }
            lock.unlock()
            complete(completion)
        }

        private func reapExitedProcessLocked() -> (
            handler: @Sendable (Int32) -> Void,
            status: Int32
        )? {
            guard let processIdentifier else { return nil }
            var waitStatus: Int32 = 0
            let result = waitpid(processIdentifier, &waitStatus, WNOHANG)
            if result == processIdentifier {
                return finishLocked(status: Self.terminationStatus(from: waitStatus))
            }
            if result == -1, errno != EINTR {
                return finishLocked(status: -1)
            }
            return nil
        }

        private func finishLocked(status: Int32) -> (
            handler: @Sendable (Int32) -> Void,
            status: Int32
        )? {
            processIdentifier = nil
            exitSource?.cancel()
            exitSource = nil
            guard let exitHandler else { return nil }
            self.exitHandler = nil
            return (exitHandler, status)
        }

        private func complete(
            _ completion: (
                handler: @Sendable (Int32) -> Void,
                status: Int32
            )?
        ) {
            if let completion {
                completion.handler(completion.status)
            }
        }

        private static func terminationStatus(from waitStatus: Int32) -> Int32 {
            let signal = waitStatus & 0x7F
            if signal == 0 {
                return (waitStatus >> 8) & 0xFF
            }
            return signal
        }
    }

    private final class OutputLimitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var exceeded = false

        func markExceeded() {
            lock.lock()
            exceeded = true
            lock.unlock()
        }

        var hasExceeded: Bool {
            lock.lock()
            defer { lock.unlock() }
            return exceeded
        }
    }

    private let executableURL: URL
    private let fileManager: FileManager
    private let previewSizeLimit: Int64
    private let markdownPreviewSizeLimit: Int64
    private let standardOutputLimit: Int64
    private let standardErrorLimit: Int64
    private let forceStopDelay: TimeInterval
    private let signalProcess: @Sendable (pid_t, Int32) -> Int32

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/sftp"),
        fileManager: FileManager = .default,
        previewSizeLimit: Int64 = 100 * 1_024 * 1_024,
        markdownPreviewSizeLimit: Int64 = Int64(RemoteMarkdownDecoder.maximumByteCount),
        standardOutputLimit: Int64 = 32 * 1_024 * 1_024,
        standardErrorLimit: Int64 = 1 * 1_024 * 1_024,
        forceStopDelay: TimeInterval = 2,
        signalProcess: @escaping @Sendable (pid_t, Int32) -> Int32 = {
            Darwin.kill($0, $1)
        }
    ) {
        self.executableURL = executableURL
        self.fileManager = fileManager
        self.previewSizeLimit = previewSizeLimit
        self.markdownPreviewSizeLimit = markdownPreviewSizeLimit
        self.standardOutputLimit = standardOutputLimit
        self.standardErrorLimit = standardErrorLimit
        self.forceStopDelay = forceStopDelay
        self.signalProcess = signalProcess
    }

    func list(server: RemoteServer, path: String) async throws -> [RemoteFileEntry] {
        guard RemotePath.validationMessage(for: path) == nil else {
            throw RemoteFileError.invalidPath
        }
        let normalizedPath = RemotePath.normalized(path)
        let result = try await run(
            server: server,
            batchInput: SFTPCommandBuilder.listCommand(path: normalizedPath)
        )
        try validate(result)
        return try SFTPListingParser.parse(result.output, parentPath: normalizedPath)
    }

    func download(
        server: RemoteServer,
        entry: RemoteFileEntry,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try await download(
            server: server,
            entry: entry,
            to: destination,
            maximumBytes: nil,
            progress: progress
        )
    }

    private func download(
        server: RemoteServer,
        entry: RemoteFileEntry,
        to destination: URL,
        maximumBytes: Int64?,
        limitError: RemoteFileError = .previewTooLarge,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let stagingDirectory = parent.appendingPathComponent(
            ".relaybar-\(UUID().uuidString).partial",
            isDirectory: true
        )
        let partial = stagingDirectory.appendingPathComponent(
            "payload",
            isDirectory: entry.isDirectory
        )
        var ownsStagingDirectory = false

        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            ownsStagingDirectory = true
            let command = try SFTPCommandBuilder.downloadCommand(
                remotePath: entry.path,
                localPath: partial.path,
                recursively: entry.isDirectory
            )
            try await runTransfer(
                server: server,
                batchInput: command,
                partialURL: partial,
                maximumBytes: maximumBytes,
                limitError: limitError,
                progress: progress
            )
            try Task.checkCancellation()
            if let maximumBytes, localSize(of: partial) > maximumBytes {
                throw limitError
            }
            guard fileManager.fileExists(atPath: partial.path) else {
                throw RemoteFileError.missingDownload
            }

            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: partial,
                    backupItemName: nil
                )
            } else {
                try fileManager.moveItem(at: partial, to: destination)
            }
            try? fileManager.removeItem(at: stagingDirectory)
        } catch {
            if ownsStagingDirectory {
                try? fileManager.removeItem(at: stagingDirectory)
            }
            throw error
        }
    }

    func preparePreview(server: RemoteServer, entry: RemoteFileEntry) async throws -> URL {
        let maximumBytes = entry.isPreviewableMarkdown
            ? markdownPreviewSizeLimit
            : previewSizeLimit
        let limitError: RemoteFileError = entry.isPreviewableMarkdown
            ? .markdownTooLarge
            : .previewTooLarge
        if let size = entry.size, size > maximumBytes {
            throw limitError
        }

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("RelayBarPreview-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = directory.appendingPathComponent(entry.name)

        do {
            try await download(
                server: server,
                entry: entry,
                to: destination,
                maximumBytes: maximumBytes,
                limitError: limitError
            ) { _ in }
            return destination
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private func runTransfer(
        server: RemoteServer,
        batchInput: String,
        partialURL: URL,
        maximumBytes: Int64?,
        limitError: RemoteFileError,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            let isDirectory = partialURL.hasDirectoryPath
            group.addTask { [self] in
                let result = try await run(server: server, batchInput: batchInput)
                try validate(result)
                return true
            }
            group.addTask { [self] in
                var pollingInterval = Self.progressPollingInterval(
                    forEntryCount: 0,
                    isDirectory: isDirectory
                )
                while !Task.isCancelled {
                    securePartialPermissions(at: partialURL)
                    let measurement = measureLocal(partialURL)
                    progress(measurement.bytes)
                    if let maximumBytes, measurement.bytes > maximumBytes {
                        throw limitError
                    }
                    // Each poll re-walks the tree, so widen the gap as the tree
                    // grows instead of paying an O(entries) walk every second.
                    pollingInterval = Self.progressPollingInterval(
                        forEntryCount: measurement.entries,
                        isDirectory: isDirectory
                    )
                    try await Task.sleep(for: pollingInterval)
                }
                return false
            }

            while let commandFinished = try await group.next() {
                if commandFinished {
                    progress(localSize(of: partialURL))
                    group.cancelAll()
                    return
                }
            }
        }
    }

    private func run(server: RemoteServer, batchInput: String) async throws -> CommandResult {
        let arguments = try SFTPCommandBuilder.processArguments(for: server)
        let processBox = ProcessBox(
            forceStopDelay: forceStopDelay,
            signalProcess: signalProcess
        )
        let outputLimitBox = OutputLimitBox()
        let outputLimit = standardOutputLimit
        let errorLimit = standardErrorLimit

        return try await withTaskCancellationHandler {
            let result = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<CommandResult, Error>) in
                let temporaryDirectory = fileManager.temporaryDirectory
                    .appendingPathComponent("RelayBarSFTP-\(UUID().uuidString)", isDirectory: true)

                do {
                    try fileManager.createDirectory(
                        at: temporaryDirectory,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    let outputURL = temporaryDirectory.appendingPathComponent("stdout")
                    let errorURL = temporaryDirectory.appendingPathComponent("stderr")
                    fileManager.createFile(
                        atPath: outputURL.path,
                        contents: nil,
                        attributes: [.posixPermissions: 0o600]
                    )
                    fileManager.createFile(
                        atPath: errorURL.path,
                        contents: nil,
                        attributes: [.posixPermissions: 0o600]
                    )

                    let inputPipe = Pipe()
                    try Self.suppressSIGPIPE(
                        on: inputPipe.fileHandleForWriting.fileDescriptor
                    )
                    let outputMonitor = DispatchSource.makeTimerSource(
                        queue: DispatchQueue(label: "RelayBar.SFTPOutputLimit")
                    )

                    outputMonitor.schedule(
                        deadline: .now() + .milliseconds(250),
                        repeating: .milliseconds(250)
                    )
                    outputMonitor.setEventHandler {
                        let outputSize = Self.fileSize(at: outputURL)
                        let errorSize = Self.fileSize(at: errorURL)
                        guard
                            outputSize > outputLimit
                                || errorSize > errorLimit
                        else { return }
                        outputLimitBox.markExceeded()
                        processBox.cancel()
                    }

                    let finish: @Sendable (Int32) -> Void = { status in
                        outputMonitor.cancel()
                        if
                            Self.fileSize(at: outputURL) > outputLimit
                                || Self.fileSize(at: errorURL) > errorLimit
                        {
                            outputLimitBox.markExceeded()
                        }
                        let output = Self.readString(
                            at: outputURL,
                            maximumBytes: outputLimit
                        )
                        let error = Self.readString(
                            at: errorURL,
                            maximumBytes: errorLimit
                        )
                        try? FileManager.default.removeItem(at: temporaryDirectory)
                        continuation.resume(
                            returning: CommandResult(
                                status: status,
                                output: output,
                                error: error,
                                exceededOutputLimit: outputLimitBox.hasExceeded
                            )
                        )
                    }

                    do {
                        outputMonitor.resume()
                        guard processBox.shouldStart else {
                            throw CancellationError()
                        }
                        let processIdentifier = try Self.spawnProcess(
                            executableURL: executableURL,
                            arguments: arguments,
                            inputPipe: inputPipe,
                            outputURL: outputURL,
                            errorURL: errorURL
                        )
                        inputPipe.fileHandleForReading.closeFile()
                        processBox.beginWaiting(
                            for: processIdentifier,
                            onExit: finish
                        )
                    } catch {
                        outputMonitor.cancel()
                        inputPipe.fileHandleForReading.closeFile()
                        inputPipe.fileHandleForWriting.closeFile()
                        try? fileManager.removeItem(at: temporaryDirectory)
                        continuation.resume(throwing: error)
                        return
                    }

                    if processBox.stopIfCancellationRequested() {
                        inputPipe.fileHandleForWriting.closeFile()
                        return
                    }

                    do {
                        try inputPipe.fileHandleForWriting.write(contentsOf: Data(batchInput.utf8))
                    } catch {
                        processBox.cancel()
                    }
                    try? inputPipe.fileHandleForWriting.close()
                } catch {
                    try? fileManager.removeItem(at: temporaryDirectory)
                    continuation.resume(throwing: error)
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            processBox.cancel()
        }
    }

    /// Kept internal so the descriptor-level guarantee has deterministic
    /// coverage without relying on a scheduling race against a short-lived child.
    static func suppressSIGPIPE(on fileDescriptor: Int32) throws {
        guard fcntl(fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw posixError(errno)
        }
    }

    /// Kept internal so descriptor-zero inheritance has deterministic
    /// coverage without changing the test process's standard input asynchronously.
    static func spawnProcess(
        executableURL: URL,
        arguments: [String],
        inputPipe: Pipe,
        outputURL: URL,
        errorURL: URL
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        let actionsResult = posix_spawn_file_actions_init(&actions)
        guard actionsResult == 0 else {
            throw posixError(actionsResult)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        let inputDescriptor = inputPipe.fileHandleForReading.fileDescriptor
        let inputWriteDescriptor = inputPipe.fileHandleForWriting.fileDescriptor

        // Under POSIX_SPAWN_CLOEXEC_DEFAULT, even an existing descriptor zero
        // must be named by a file action to survive into the child.
        let duplicateInput = posix_spawn_file_actions_adddup2(
            &actions,
            inputDescriptor,
            STDIN_FILENO
        )
        guard duplicateInput == 0 else {
            throw posixError(duplicateInput)
        }
        if inputDescriptor != STDIN_FILENO {
            let closeInput = posix_spawn_file_actions_addclose(&actions, inputDescriptor)
            guard closeInput == 0 else {
                throw posixError(closeInput)
            }
        }
        let closeInputWriter = posix_spawn_file_actions_addclose(
            &actions,
            inputWriteDescriptor
        )
        guard closeInputWriter == 0 else {
            throw posixError(closeInputWriter)
        }
        let openOutput = outputURL.path.withCString { outputPath in
            posix_spawn_file_actions_addopen(
                &actions,
                STDOUT_FILENO,
                outputPath,
                O_WRONLY | O_TRUNC,
                mode_t(0o600)
            )
        }
        guard openOutput == 0 else {
            throw posixError(openOutput)
        }
        let openError = errorURL.path.withCString { errorPath in
            posix_spawn_file_actions_addopen(
                &actions,
                STDERR_FILENO,
                errorPath,
                O_WRONLY | O_TRUNC,
                mode_t(0o600)
            )
        }
        guard openError == 0 else {
            throw posixError(openError)
        }

        var attributes: posix_spawnattr_t?
        let attributesResult = posix_spawnattr_init(&attributes)
        guard attributesResult == 0 else {
            throw posixError(attributesResult)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        var defaultSignals = sigset_t()
        guard sigfillset(&defaultSignals) == 0 else {
            throw posixError(errno)
        }
        _ = sigdelset(&defaultSignals, SIGKILL)
        _ = sigdelset(&defaultSignals, SIGSTOP)
        var signalMask = sigset_t()
        guard sigemptyset(&signalMask) == 0 else {
            throw posixError(errno)
        }
        let signalConfiguration = [
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
            posix_spawnattr_setsigmask(&attributes, &signalMask)
        ]
        if let error = signalConfiguration.first(where: { $0 != 0 }) {
            throw posixError(error)
        }

        let flagsResult = posix_spawnattr_setflags(
            &attributes,
            Int16(
                POSIX_SPAWN_CLOEXEC_DEFAULT
                    | POSIX_SPAWN_SETSIGDEF
                    | POSIX_SPAWN_SETSIGMASK
            )
        )
        guard flagsResult == 0 else {
            throw posixError(flagsResult)
        }

        var argumentPointers: [UnsafeMutablePointer<CChar>?] = []
        defer {
            for argumentPointer in argumentPointers {
                free(argumentPointer)
            }
        }
        for argument in [executableURL.path] + arguments {
            guard let argumentPointer = strdup(argument) else {
                throw POSIXError(.ENOMEM)
            }
            argumentPointers.append(argumentPointer)
        }
        argumentPointers.append(nil)

        var processIdentifier: pid_t = 0
        let spawnResult = executableURL.path.withCString { executablePath in
            argumentPointers.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(
                    &processIdentifier,
                    executablePath,
                    &actions,
                    &attributes,
                    buffer.baseAddress!,
                    environ
                )
            }
        }
        guard spawnResult == 0 else {
            throw posixError(spawnResult)
        }
        return processIdentifier
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private func validate(_ result: CommandResult) throws {
        if result.exceededOutputLimit {
            throw RemoteFileError.responseTooLarge
        }
        guard result.status == 0 else {
            throw RemoteFileError.commandFailed(friendlyMessage(from: result.error))
        }
    }

    /// Ordered: the first entry whose text appears in the detail wins, so
    /// overlapping matches resolve the same way they did as a branch chain.
    private static let messageTable: [(matches: [String], message: String)] = [
        (["permission denied"], "Permission was denied for this server or path."),
        (["host key verification failed"], "SSH could not verify this server’s host key."),
        (["no such file", "not found"], "The remote path wasn’t found."),
        (["could not resolve hostname"], "The saved server could not be found."),
        (["operation timed out", "connection timed out"], "The connection timed out."),
        (["connection refused"], "The server refused the connection."),
        (["connection closed", "connection reset"], "The connection was lost.")
    ]

    private func friendlyMessage(from errorOutput: String) -> String {
        let lines = errorOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasPrefix("sftp>") }
        let rawDetail = lines.suffix(2).joined(separator: " ")
        let safeScalars = rawDetail.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let detail = String(String.UnicodeScalarView(safeScalars).prefix(512))

        let match = Self.messageTable.first { entry in
            entry.matches.contains { detail.localizedCaseInsensitiveContains($0) }
        }
        if let match { return match.message }
        return detail.isEmpty ? "The remote operation failed." : detail
    }

    /// Progress polling scales with how much of the tree each walk has to visit.
    /// Single files stay on the cheap fixed interval; one `stat` costs nothing.
    static func progressPollingInterval(
        forEntryCount entries: Int,
        isDirectory: Bool
    ) -> Duration {
        guard isDirectory else { return .milliseconds(250) }
        return .seconds(max(1, min(8, entries / 1_000)))
    }

    private func localSize(of url: URL) -> Int64 {
        measureLocal(url).bytes
    }

    /// Exposed so the polling-cost benchmark measures the real walk.
    func benchmarkMeasureLocal(_ url: URL) -> (bytes: Int64, entries: Int) {
        measureLocal(url)
    }

    private func measureLocal(_ url: URL) -> (bytes: Int64, entries: Int) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return (0, 0)
        }
        if attributes[.type] as? FileAttributeType != .typeDirectory {
            return ((attributes[.size] as? NSNumber)?.int64Value ?? 0, 1)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else {
            return (0, 0)
        }
        var total: Int64 = 0
        var entries = 0
        for case let fileURL as URL in enumerator {
            guard !Task.isCancelled else { return (total, entries) }
            entries += 1
            guard
                let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                values.isRegularFile == true
            else { continue }
            let result = total.addingReportingOverflow(Int64(values.fileSize ?? 0))
            guard !result.overflow else { return (.max, entries) }
            total = result.partialValue
        }
        return (total, entries)
    }

    private func securePartialPermissions(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let permissions = url.hasDirectoryPath ? 0o700 : 0o600
        try? fileManager.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func readString(at url: URL, maximumBytes: Int64) -> String {
        guard
            maximumBytes > 0,
            maximumBytes <= Int64(Int.max),
            let handle = try? FileHandle(forReadingFrom: url)
        else {
            return ""
        }
        defer { try? handle.close() }
        do {
            guard let data = try handle.read(upToCount: Int(maximumBytes)) else {
                return ""
            }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
