import Darwin
import Foundation

protocol RemoteFileServing: AnyObject, Sendable {
    func loadPath(server: RemoteServer, path: String) async throws -> RemotePathLoadResult
    func list(server: RemoteServer, path: String) async throws -> [RemoteFileEntry]
    func download(
        server: RemoteServer,
        entry: RemoteFileEntry,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws
    func preparePreview(server: RemoteServer, entry: RemoteFileEntry) async throws -> URL
    func preparePreviewWithProgress(
        server: RemoteServer,
        entry: RemoteFileEntry,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL
    func upload(
        server: RemoteServer,
        localFile: URL,
        remoteDirectory: String,
        replaceExisting: Bool,
        phase: @escaping @Sendable (RemoteUploadPhase) -> Void
    ) async throws
    func uploadWithProgress(
        server: RemoteServer,
        localFile: URL,
        remoteDirectory: String,
        replaceExisting: Bool,
        update: @escaping @Sendable (RemoteUploadUpdate) -> Void
    ) async throws
    func delete(server: RemoteServer, entry: RemoteFileEntry) async throws
    func shutdown()
}

extension RemoteFileServing {
    func loadPath(server: RemoteServer, path: String) async throws -> RemotePathLoadResult {
        .directory(try await list(server: server, path: path))
    }

    func shutdown() {}

    func preparePreviewWithProgress(
        server: RemoteServer,
        entry: RemoteFileEntry,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        let url = try await preparePreview(server: server, entry: entry)
        let byteCount = Int64(
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        progress(byteCount)
        return url
    }

    func upload(
        server: RemoteServer,
        localFile: URL,
        remoteDirectory: String,
        replaceExisting: Bool,
        phase: @escaping @Sendable (RemoteUploadPhase) -> Void
    ) async throws {
        throw RemoteFileError.uploadCapabilityUnavailable("remote publication")
    }

    func uploadWithProgress(
        server: RemoteServer,
        localFile: URL,
        remoteDirectory: String,
        replaceExisting: Bool,
        update: @escaping @Sendable (RemoteUploadUpdate) -> Void
    ) async throws {
        let total = Int64(
            (try? localFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        try await upload(
            server: server,
            localFile: localFile,
            remoteDirectory: remoteDirectory,
            replaceExisting: replaceExisting
        ) { phase in
            update(
                RemoteUploadUpdate(
                    phase: phase,
                    completedBytes: phase == .staging ? 0 : total,
                    totalBytes: total,
                    isStagingComplete: phase != .staging
                )
            )
        }
    }

    func delete(server: RemoteServer, entry: RemoteFileEntry) async throws {
        throw RemoteFileError.deleteNotSubmitted("Deletion is unavailable for this server.")
    }

    func upload(
        server: RemoteServer,
        localFile: URL,
        remoteDirectory: String,
        replaceExisting: Bool
    ) async throws {
        try await upload(
            server: server,
            localFile: localFile,
            remoteDirectory: remoteDirectory,
            replaceExisting: replaceExisting,
            phase: { _ in }
        )
    }
}

/// Configuration is immutable after initialization. Each command owns separate
/// process state, and the small boxes shared with callbacks synchronize access.
final class SFTPRemoteFileService: RemoteFileServing, @unchecked Sendable {
    private final class UploadPhaseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var lastPhase: RemoteUploadPhase?

        func emit(
            _ phase: RemoteUploadPhase,
            to callback: @escaping @Sendable (RemoteUploadPhase) -> Void
        ) {
            lock.lock()
            let changed = lastPhase != phase
            if changed { lastPhase = phase }
            lock.unlock()
            if changed { callback(phase) }
        }
    }

    private final class UploadProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private let totalBytes: Int64
        private var storedCompletedBytes: Int64 = 0

        init(totalBytes: Int64) {
            self.totalBytes = max(0, totalBytes)
        }

        var completedBytes: Int64 {
            lock.withLock { storedCompletedBytes }
        }

        func advance(to proposedBytes: Int64) -> (bytes: Int64, changed: Bool) {
            lock.withLock {
                let next = min(max(proposedBytes, storedCompletedBytes), totalBytes)
                guard next > storedCompletedBytes else {
                    return (storedCompletedBytes, false)
                }
                storedCompletedBytes = next
                return (next, true)
            }
        }
    }

    private struct CommandResult {
        let status: Int32
        let output: String
        let error: String
        let exceededOutputLimit: Bool
        let sessionToken: String?
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

    private final class CapabilityBox: @unchecked Sendable {
        private struct Entry {
            let capabilities: RemoteUploadCapabilities
            let sessionToken: String?
        }

        private let lock = NSLock()
        private var values: [RemoteServer.ConnectionIdentity: Entry] = [:]

        func value(
            for identity: RemoteServer.ConnectionIdentity,
            sessionToken: String?
        ) -> RemoteUploadCapabilities? {
            lock.lock()
            defer { lock.unlock() }
            guard values[identity]?.sessionToken == sessionToken else { return nil }
            return values[identity]?.capabilities
        }

        func store(
            _ value: RemoteUploadCapabilities,
            for identity: RemoteServer.ConnectionIdentity,
            sessionToken: String?
        ) {
            lock.lock()
            values[identity] = Entry(
                capabilities: value,
                sessionToken: sessionToken
            )
            lock.unlock()
        }

        func removeAll() {
            lock.lock()
            values.removeAll()
            lock.unlock()
        }
    }

    private let executableURL: URL
    private let fileManager: FileManager
    private let previewSizeLimit: Int64
    private let markdownPreviewSizeLimit: Int64
    private let jsonPreviewSizeLimit: Int64
    private let videoPreviewSizeLimit: Int64
    private let standardOutputLimit: Int64
    private let standardErrorLimit: Int64
    private let forceStopDelay: TimeInterval
    private let signalProcess: @Sendable (pid_t, Int32) -> Int32
    private let connectionSession: RemoteFileSSHSession?
    private let capabilityBox = CapabilityBox()

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/sftp"),
        fileManager: FileManager = .default,
        previewSizeLimit: Int64 = 100 * 1_024 * 1_024,
        markdownPreviewSizeLimit: Int64 = Int64(RemoteMarkdownDecoder.maximumByteCount),
        jsonPreviewSizeLimit: Int64 = Int64(RemoteJSONDecoder.maximumByteCount),
        videoPreviewSizeLimit: Int64 = RemoteVideoPreview.maximumByteCount,
        standardOutputLimit: Int64 = 32 * 1_024 * 1_024,
        standardErrorLimit: Int64 = 1 * 1_024 * 1_024,
        forceStopDelay: TimeInterval = 2,
        connectionSharing: Bool = true,
        sshExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        sessionTemporaryDirectory: URL? = nil,
        processEnvironment: [String: String]? = nil,
        signalProcess: @escaping @Sendable (pid_t, Int32) -> Int32 = {
            Darwin.kill($0, $1)
        }
    ) {
        self.executableURL = executableURL
        self.fileManager = fileManager
        self.previewSizeLimit = previewSizeLimit
        self.markdownPreviewSizeLimit = markdownPreviewSizeLimit
        self.jsonPreviewSizeLimit = jsonPreviewSizeLimit
        self.videoPreviewSizeLimit = videoPreviewSizeLimit
        self.standardOutputLimit = standardOutputLimit
        self.standardErrorLimit = standardErrorLimit
        self.forceStopDelay = forceStopDelay
        self.signalProcess = signalProcess
        connectionSession = connectionSharing
            ? RemoteFileSSHSession(
                executableURL: sshExecutableURL,
                fileManager: fileManager,
                temporaryDirectory: sessionTemporaryDirectory,
                processEnvironment: processEnvironment,
                forceStopDelay: forceStopDelay,
                signalProcess: signalProcess
            )
            : nil
    }

    func shutdown() {
        capabilityBox.removeAll()
        connectionSession?.shutdown()
    }

    func list(server: RemoteServer, path: String) async throws -> [RemoteFileEntry] {
        let (output, normalizedPath) = try await listingOutput(server: server, path: path)
        return try SFTPListingParser.parse(output, parentPath: normalizedPath)
    }

    func loadPath(server: RemoteServer, path: String) async throws -> RemotePathLoadResult {
        let (output, normalizedPath) = try await listingOutput(server: server, path: path)
        return try SFTPListingParser.parsePath(output, path: normalizedPath)
    }

    private func listingOutput(
        server: RemoteServer,
        path: String,
        requiredSessionToken: String? = nil
    ) async throws -> (output: String, normalizedPath: String) {
        guard RemotePath.validationMessage(for: path) == nil else {
            throw RemoteFileError.invalidPath
        }
        let normalizedPath = RemotePath.normalized(path)
        let result = try await run(
            server: server,
            batchInput: SFTPCommandBuilder.listCommand(path: normalizedPath),
            requiredSessionToken: requiredSessionToken
        )
        try validate(result)
        return (result.output, normalizedPath)
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
        try await preparePreview(
            server: server,
            entry: entry,
            progress: { _ in }
        )
    }

    func preparePreviewWithProgress(
        server: RemoteServer,
        entry: RemoteFileEntry,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        try await preparePreview(server: server, entry: entry, progress: progress)
    }

    private func preparePreview(
        server: RemoteServer,
        entry: RemoteFileEntry,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        let maximumBytes: Int64
        let limitError: RemoteFileError
        if entry.isPreviewableMarkdown {
            maximumBytes = markdownPreviewSizeLimit
            limitError = .markdownTooLarge
        } else if entry.isPreviewableJSON {
            maximumBytes = jsonPreviewSizeLimit
            limitError = .jsonTooLarge
        } else if entry.isPreviewableVideo {
            maximumBytes = videoPreviewSizeLimit
            limitError = .videoTooLarge
        } else {
            maximumBytes = previewSizeLimit
            limitError = .previewTooLarge
        }
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
            ) { completedBytes in
                progress(completedBytes)
            }
            return destination
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func upload(
        server: RemoteServer,
        localFile: URL,
        remoteDirectory: String,
        replaceExisting: Bool,
        phase: @escaping @Sendable (RemoteUploadPhase) -> Void
    ) async throws {
        let phaseBox = UploadPhaseBox()
        try await uploadWithProgress(
            server: server,
            localFile: localFile,
            remoteDirectory: remoteDirectory,
            replaceExisting: replaceExisting
        ) { update in
            phaseBox.emit(update.phase, to: phase)
        }
    }

    func uploadWithProgress(
        server: RemoteServer,
        localFile: URL,
        remoteDirectory: String,
        replaceExisting: Bool,
        update: @escaping @Sendable (RemoteUploadUpdate) -> Void
    ) async throws {
        let values = try localFile.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey]
        )
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            values.isAliasFile != true,
            let fileSize = values.fileSize,
            fileSize >= 0
        else {
            throw RemoteFileError.invalidUploadSource
        }
        guard RemotePath.validationMessage(for: remoteDirectory) == nil else {
            throw RemoteFileError.invalidPath
        }

        let directory = RemotePath.normalized(remoteDirectory)
        let name = localFile.lastPathComponent
        guard !name.isEmpty else { throw RemoteFileError.invalidUploadSource }
        let target = RemotePath.joining(directory, name)
        guard RemotePath.validationMessage(for: target) == nil else {
            throw RemoteFileError.invalidPath
        }

        let initialEntries = try await list(server: server, path: directory)
        if let existing = initialEntries.first(where: { $0.name == name }) {
            guard existing.kind == .file else {
                throw RemoteFileError.unsupportedUploadTarget
            }
            guard replaceExisting else {
                throw RemoteFileError.uploadConflict
            }
        }

        let capabilityContext = try await uploadCapabilities(for: server)
        let capabilities = capabilityContext.capabilities
        if replaceExisting {
            guard capabilities.supportsPOSIXRename else {
                throw RemoteFileError.uploadCapabilityUnavailable("atomic replace")
            }
        } else {
            guard capabilities.supportsHardLink else {
                throw RemoteFileError.uploadCapabilityUnavailable("no-overwrite publish")
            }
        }

        let stagingName = ".relaybar-upload-\(UUID().uuidString).partial"
        let staging = RemotePath.joining(directory, stagingName)
        guard RemotePath.validationMessage(for: staging) == nil else {
            throw RemoteFileError.invalidPath
        }
        let progress = UploadProgressBox(totalBytes: Int64(fileSize))

        var ownsStaging = false
        var didStage = false
        var didPublish = false
        do {
            // `put` may create the staging entry before its child is cancelled
            // or reports failure. Claim the exact name before launching it so
            // every post-launch exit attempts bounded cleanup.
            ownsStaging = true
            update(
                RemoteUploadUpdate(
                    phase: .staging,
                    completedBytes: 0,
                    totalBytes: Int64(fileSize)
                )
            )
            let uploadResult = try await withThrowingTaskGroup(
                of: CommandResult?.self
            ) { group in
                group.addTask { [self] in
                    try await run(
                        server: server,
                        batchInput: SFTPCommandBuilder.uploadCommand(
                            localPath: localFile.path,
                            remotePath: staging
                        ),
                        requiredSessionToken: capabilityContext.sessionToken
                    )
                }
                group.addTask { [self] in
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(500))
                        do {
                            let measured = try await listingOutput(
                                server: server,
                                path: staging,
                                requiredSessionToken: capabilityContext.sessionToken
                            )
                            let result = try SFTPListingParser.parsePath(
                                measured.output,
                                path: measured.normalizedPath
                            )
                            guard case .file(let stagingEntry) = result,
                                  let size = stagingEntry.size
                            else { continue }
                            let advanced = progress.advance(to: size)
                            guard advanced.changed else { continue }
                            update(
                                RemoteUploadUpdate(
                                    phase: .staging,
                                    completedBytes: advanced.bytes,
                                    totalBytes: Int64(fileSize)
                                )
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // Measurement is advisory. Keep the last known value and
                            // let the upload command determine success or failure.
                        }
                    }
                    throw CancellationError()
                }
                defer { group.cancelAll() }
                while let result = try await group.next() {
                    if let result { return result }
                }
                throw CancellationError()
            }
            try validate(uploadResult)
            didStage = true
            _ = progress.advance(to: Int64(fileSize))
            update(
                RemoteUploadUpdate(
                    phase: .staging,
                    completedBytes: Int64(fileSize),
                    totalBytes: Int64(fileSize),
                    isStagingComplete: true
                )
            )
            try Task.checkCancellation()

            update(
                RemoteUploadUpdate(
                    phase: .publishing,
                    completedBytes: Int64(fileSize),
                    totalBytes: Int64(fileSize),
                    isStagingComplete: true
                )
            )
            let finalEntries = try SFTPListingParser.parse(
                try await listingOutput(
                    server: server,
                    path: directory,
                    requiredSessionToken: capabilityContext.sessionToken
                ).output,
                parentPath: directory
            )
            if let existing = finalEntries.first(where: { $0.name == name }) {
                guard existing.kind == .file else {
                    throw RemoteFileError.unsupportedUploadTarget
                }
                guard replaceExisting else {
                    throw RemoteFileError.uploadConflict
                }
            }

            let publishCommand = replaceExisting
                ? try SFTPCommandBuilder.renameCommand(
                    existingPath: staging,
                    newPath: target
                )
                : try SFTPCommandBuilder.hardLinkCommand(
                    existingPath: staging,
                    newPath: target
                )
            let publishResult = try await run(
                server: server,
                batchInput: publishCommand,
                requiredSessionToken: capabilityContext.sessionToken
            )
            do {
                try validate(publishResult)
                didPublish = true
            } catch {
                let diagnosticEntries = try? SFTPListingParser.parse(
                    try await listingOutput(
                        server: server,
                        path: directory,
                        requiredSessionToken: capabilityContext.sessionToken
                    ).output,
                    parentPath: directory
                )
                if !replaceExisting,
                   diagnosticEntries?.contains(where: { $0.name == name }) == true
                {
                    throw RemoteFileError.uploadConflict
                }
                throw error
            }

            if replaceExisting {
                ownsStaging = false
            } else {
                update(
                    RemoteUploadUpdate(
                        phase: .cleaningUp,
                        completedBytes: Int64(fileSize),
                        totalBytes: Int64(fileSize),
                        isStagingComplete: true
                    )
                )
                let cleanupResult = try await run(
                    server: server,
                    batchInput: SFTPCommandBuilder.removeCommand(path: staging)
                )
                try validate(cleanupResult)
                ownsStaging = false
            }
        } catch {
            if ownsStaging {
                update(
                    RemoteUploadUpdate(
                        phase: .cleaningUp,
                        completedBytes: progress.completedBytes,
                        totalBytes: Int64(fileSize),
                        isStagingComplete: didStage
                    )
                )
                let cleaned = await cleanupUploadStaging(server: server, path: staging)
                if !cleaned {
                    let context = didPublish
                        ? "The upload was published."
                        : error.localizedDescription
                    throw RemoteFileError.uploadCleanupUnconfirmed(
                        context
                    )
                }
                if didPublish { return }
            }
            throw error
        }
    }

    func delete(server: RemoteServer, entry: RemoteFileEntry) async throws {
        guard
            entry.kind == .file,
            RemotePath.validationMessage(for: entry.path) == nil,
            RemotePath.joining(RemotePath.parent(of: entry.path), entry.name)
                == RemotePath.normalized(entry.path)
        else {
            throw RemoteFileError.deleteNotSubmitted(
                "Only one listed regular file can be deleted."
            )
        }
        let removeCommand: String
        do {
            removeCommand = try SFTPCommandBuilder.removeCommand(path: entry.path)
        } catch {
            throw RemoteFileError.deleteNotSubmitted(error.localizedDescription)
        }

        let sessionToken: String?
        do {
            if let connectionSession {
                sessionToken = try await connectionSession.controlSocket(for: server).path
            } else {
                sessionToken = nil
            }
            let preflight = try await listingOutput(
                server: server,
                path: entry.path,
                requiredSessionToken: sessionToken
            )
            guard case .file(let current) = try SFTPListingParser.parsePath(
                preflight.output,
                path: preflight.normalizedPath
            ) else {
                throw RemoteFileError.deleteTargetChanged
            }
            guard
                current.path == entry.path,
                current.kind == .file,
                current.size == entry.size,
                current.modificationText == entry.modificationText
            else {
                throw RemoteFileError.deleteTargetChanged
            }
        } catch let error as RemoteFileError where error == .deleteTargetChanged {
            throw error
        } catch {
            throw RemoteFileError.deleteNotSubmitted(error.localizedDescription)
        }

        let result: CommandResult
        do {
            result = try await run(
                server: server,
                batchInput: removeCommand,
                requiredSessionToken: sessionToken
            )
        } catch let error as RemoteFileError
            where error == .connectionSessionUnavailable
                || error == .invalidConnection
                || error == .invalidPath
        {
            throw RemoteFileError.deleteNotSubmitted(error.localizedDescription)
        } catch {
            throw RemoteFileError.deleteOutcomeUnknown
        }
        if result.exceededOutputLimit {
            throw RemoteFileError.deleteOutcomeUnknown
        }
        guard result.status == 0 else {
            guard Self.isExplicitDeleteRejection(result.error) else {
                throw RemoteFileError.deleteOutcomeUnknown
            }
            throw RemoteFileError.deleteRejected(
                Self.friendlyMessage(from: result.error)
            )
        }
    }

    private static func isExplicitDeleteRejection(_ diagnostics: String) -> Bool {
        let normalized = diagnostics.lowercased()
        return [
            "permission denied",
            "no such file",
            "not found",
            "is a directory",
            "failure",
            "cannot remove",
            "can't remove",
            "couldn't remove"
        ].contains { normalized.contains($0) }
    }

    private func uploadCapabilities(
        for server: RemoteServer
    ) async throws -> (
        capabilities: RemoteUploadCapabilities,
        sessionToken: String?
    ) {
        let sessionToken: String?
        if let connectionSession {
            sessionToken = try await connectionSession.controlSocket(for: server).path
        } else {
            sessionToken = nil
        }
        if let cached = capabilityBox.value(
            for: server.connectionIdentity,
            sessionToken: sessionToken
        ) {
            return (cached, sessionToken)
        }
        let result = try await run(
            server: server,
            batchInput: SFTPCommandBuilder.quitCommand,
            diagnosticLevel: 2,
            requiredSessionToken: sessionToken
        )
        try validate(result)
        let capabilities = RemoteUploadCapabilities.parse(result.error)
        capabilityBox.store(
            capabilities,
            for: server.connectionIdentity,
            sessionToken: result.sessionToken
        )
        return (capabilities, result.sessionToken)
    }

    private func cleanupUploadStaging(server: RemoteServer, path: String) async -> Bool {
        let task = Task.detached { [self] in
            do {
                let result = try await run(
                    server: server,
                    batchInput: SFTPCommandBuilder.removeCommand(path: path)
                )
                try validate(result)
                return true
            } catch {
                return false
            }
        }
        return await task.value
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

    private func run(
        server: RemoteServer,
        batchInput: String,
        diagnosticLevel: Int = 0,
        requiredSessionToken: String? = nil
    ) async throws -> CommandResult {
        let controlSocket: URL?
        if let connectionSession {
            controlSocket = try await connectionSession.controlSocket(for: server)
        } else {
            controlSocket = nil
        }
        try Task.checkCancellation()
        if let requiredSessionToken, controlSocket?.path != requiredSessionToken {
            throw RemoteFileError.connectionSessionUnavailable
        }
        if
            let controlSocket,
            !fileManager.fileExists(atPath: controlSocket.path)
        {
            throw RemoteFileError.connectionSessionUnavailable
        }
        let arguments = try SFTPCommandBuilder.processArguments(
            for: server,
            controlSocket: controlSocket,
            diagnosticLevel: diagnosticLevel
        )
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
                                exceededOutputLimit: outputLimitBox.hasExceeded,
                                sessionToken: controlSocket?.path
                            )
                        )
                    }

                    do {
                        outputMonitor.resume()
                        guard processBox.shouldStart else {
                            throw CancellationError()
                        }
                        if
                            let controlSocket,
                            !fileManager.fileExists(atPath: controlSocket.path)
                        {
                            throw RemoteFileError.connectionSessionUnavailable
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
            if Task.isCancelled, result.status != 0 {
                throw CancellationError()
            }
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
            throw RemoteFileError.commandFailed(Self.friendlyMessage(from: result.error))
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

    static func friendlyMessage(from errorOutput: String) -> String {
        let lines = errorOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter {
                let lowercase = $0.lowercased()
                return !$0.hasPrefix("sftp>")
                    && !lowercase.hasPrefix("debug1:")
                    && !lowercase.hasPrefix("debug2:")
                    && !lowercase.hasPrefix("debug3:")
            }
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
