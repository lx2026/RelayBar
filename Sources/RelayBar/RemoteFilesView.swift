import SwiftUI

/// One reused formatter. `ByteCountFormatter.string(fromByteCount:countStyle:)`
/// builds a formatter per call, and these run per row inside a render pass.
/// `.formatted(.byteCount(style: .file))` is not a substitute: it renders SI
/// `kB` rather than `KB` and rounds 999 bytes up to `1 kB`.
///
/// Confined to the main actor because `ByteCountFormatter` is not thread-safe
/// and every caller is a SwiftUI view body.
@MainActor
enum RemoteByteCount {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func string(_ byteCount: Int64) -> String {
        formatter.string(fromByteCount: byteCount)
    }
}

struct RemoteFilesView: View {
    @ObservedObject var model: RemoteFilesModel
    @FocusState private var isPathFocused: Bool

    var body: some View {
        Group {
            if model.screen == .launcher {
                launcher
            } else {
                ZStack {
                    browser
                        .opacity(model.screen == .browser ? 1 : 0)
                        .allowsHitTesting(model.screen == .browser)
                        .accessibilityHidden(model.screen != .browser)

                    if model.screen == .preview {
                        preview
                            .background(Color(nsColor: .windowBackgroundColor))
                            .zIndex(1)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var launcher: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Remote path")
                    .font(.system(size: 12, weight: .semibold))
                TextField("/srv/app/output", text: $model.remotePath)
                    .textFieldStyle(.roundedBorder)
                    .focused($isPathFocused)
                    .onSubmit {
                        if model.canOpen {
                            model.openRemotePath()
                        }
                    }
                if let message = model.pathValidationMessage, !model.remotePath.isEmpty {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Server")
                    .font(.system(size: 12, weight: .semibold))
                if model.servers.isEmpty {
                    Text("Save a tunnel first.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .frame(height: 25)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Server", selection: $model.selectedServerID) {
                        ForEach(model.servers) { server in
                            Text(server.displayName)
                                .tag(Optional(server.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }

            if let errorMessage = model.errorMessage {
                ErrorMessage(message: errorMessage)
            }

            Button {
                model.openRemotePath()
            } label: {
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Open")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canOpen)
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .onAppear {
            isPathFocused = true
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            browserToolbar
            Divider()

            if let transfer = model.transfer {
                TransferStrip(model: model, transfer: transfer)
                Divider()
            }

            if let errorMessage = model.errorMessage {
                LoadErrorStrip(
                    message: errorMessage,
                    onRetry: model.retryLastLoad,
                    onDismiss: model.dismissLoadError
                )
                Divider()
            }

            if model.isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Opening folder…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Empty folder")
                    Text("This folder is empty")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileList
            }
        }
        .background(
            RemoteFilesKeyboardMonitor(
                onPreview: {
                    if let entry = model.selectedEntry, entry.isPreviewable {
                        model.preview(entry)
                        return true
                    }
                    return false
                },
                onActivate: {
                    guard let entry = model.selectedEntry else { return false }
                    model.activate(entry)
                    return true
                },
                isEnabled: model.screen == .browser
            )
            .frame(width: 0, height: 0)
        )
        .onExitCommand {
            if model.canGoBack {
                model.goBack()
            }
        }
    }

    private var browserToolbar: some View {
        HStack(spacing: 12) {
            Button {
                model.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!model.canGoBack)
            .help(model.canGoBack ? "Go back" : "Cancel the transfer before closing this folder")

            Spacer()

            Text(model.currentPath)
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.currentPath)
                .accessibilityLabel("Current path \(model.currentPath)")

            Spacer()

            Button {
                model.refresh()
            } label: {
                if model.isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refresh")
                    }
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isLoading || model.isRefreshing)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private var fileList: some View {
        List(selection: $model.selectedEntryID) {
            ForEach(model.entries) { entry in
                RemoteFileRow(
                    entry: entry,
                    isSelected: model.selectedEntryID == entry.id,
                    onSelect: { model.select(entry) },
                    onActivate: { model.activate(entry) },
                    onPreview: { model.preview(entry) },
                    onDownload: { model.download(entry) }
                )
                .tag(entry.id)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.visible)
                .listRowSeparatorTint(Color.primary.opacity(0.08))
            }
        }
        .listStyle(.plain)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    model.closePreview()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .keyboardShortcut("[", modifiers: .command)
                .frame(width: 110, alignment: .leading)

                Text(model.previewEntry?.name ?? "Image")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)

                Button("Download") {
                    if let entry = model.previewEntry {
                        model.download(entry)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.transfer?.phase == .active
                        || model.transfer?.phase == .cancelling
                )
                .frame(width: 110, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)

            Divider()

            if let transfer = model.transfer {
                TransferStrip(model: model, transfer: transfer)
                Divider()
            }

            if model.isLoadingPreview {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading preview…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = model.errorMessage {
                errorState(message: errorMessage, retry: model.retryPreview)
            } else if let image = model.previewImage {
                GeometryReader { geometry in
                    let maximumWidth = max(0, geometry.size.width - 40)
                    let maximumHeight = max(0, geometry.size.height - 40)
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            width: min(image.size.width, maximumWidth),
                            height: min(image.size.height, maximumHeight)
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(20)
                        .accessibilityLabel(
                            "Image preview of \(model.previewEntry?.name ?? "remote file")"
                        )
                }
            } else if let markdown = model.previewMarkdown {
                SafeRemoteMarkdownView(document: markdown)
            }
        }
        .onExitCommand {
            model.closePreview()
        }
    }

    private func errorState(message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct RemoteFileRow: View {
    let entry: RemoteFileEntry
    let isSelected: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    let onPreview: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16))
                .foregroundStyle(iconColor)
                .frame(width: 22)

            Text(entry.name)
                .font(.system(size: 12.5, weight: entry.isDirectory ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 20)

            Text(entry.modificationText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .trailing)

            Text(sizeText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)

            if isSelected {
                Button {
                    onDownload()
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .help(entry.isDirectory ? "Download folder" : "Download file")
                .accessibilityLabel(entry.isDirectory ? "Download folder" : "Download file")
                .frame(width: 26)
            } else {
                Color.clear.frame(width: 26, height: 1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 43)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onActivate)
        .onTapGesture(perform: onSelect)
        .contextMenu {
            if entry.isDirectory {
                Button("Open", action: onActivate)
            } else if entry.isPreviewable {
                Button("Preview", action: onPreview)
            }
            Button(entry.isDirectory ? "Download Folder…" : "Download…", action: onDownload)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(
            named: Text(entry.isDirectory ? "Open" : (entry.isPreviewable ? "Preview" : "Download")),
            onActivate
        )
        .accessibilityAction(named: Text(entry.isDirectory ? "Download Folder" : "Download"), onDownload)
    }

    private var iconName: String {
        if entry.isDirectory { return "folder.fill" }
        if entry.isPreviewableImage { return "photo" }
        if entry.isPreviewableMarkdown { return "doc.richtext" }
        if entry.kind == .symbolicLink { return "link" }
        return "doc"
    }

    private var iconColor: Color {
        entry.isDirectory ? Color.accentColor : Color.secondary
    }

    private var sizeText: String {
        guard let size = entry.size else { return "—" }
        return RemoteByteCount.string(size)
    }

    private var accessibilityLabel: String {
        let type: String
        switch entry.kind {
        case .directory: type = "folder"
        case .file:
            if entry.isPreviewableImage {
                type = "image"
            } else if entry.isPreviewableMarkdown {
                type = "Markdown document"
            } else {
                type = "file"
            }
        case .symbolicLink: type = "symbolic link"
        }
        return "\(entry.name), \(type), modified \(entry.modificationText), \(sizeText)"
    }
}

private struct TransferStrip: View {
    @ObservedObject var model: RemoteFilesModel
    let transfer: RemoteFilesModel.TransferPresentation

    var body: some View {
        HStack(spacing: 11) {
            statusIcon
                .accessibilityLabel(statusAccessibilityLabel)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                if transfer.phase == .active || transfer.phase == .cancelling {
                    if let fraction = transfer.fraction {
                        ProgressView(value: fraction)
                        .accessibilityLabel(title)
                        .accessibilityValue(progressText)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(title)
                            .accessibilityValue(progressText)
                    }
                } else if let message = transfer.message {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(transfer.phase == .failed ? .red : .secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if transfer.phase == .active {
                Text(progressText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    model.cancelTransfer()
                }
            } else if transfer.phase == .cancelling {
                Text(progressText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Canceling…") {}
                    .disabled(true)
            } else if transfer.phase == .completed {
                Button("Reveal in Finder") {
                    model.revealTransfer()
                }
                Button {
                    model.dismissTransfer()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss transfer")
            } else {
                Button("Try Again") {
                    model.retryTransfer()
                }
                Button("Dismiss") {
                    model.dismissTransfer()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.06))
    }

    @ViewBuilder private var statusIcon: some View {
        switch transfer.phase {
        case .active:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(Color.accentColor)
        case .cancelling:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch transfer.phase {
        case .active:
            return "Downloading \(transfer.entry.name)"
        case .cancelling:
            return "Canceling \(transfer.entry.name)"
        case .completed:
            return "Downloaded \(transfer.entry.name)"
        case .failed:
            return "Couldn’t download \(transfer.entry.name)"
        case .cancelled:
            return "Canceled \(transfer.entry.name)"
        }
    }

    private var statusAccessibilityLabel: String {
        switch transfer.phase {
        case .active:
            return "Download in progress"
        case .cancelling:
            return "Canceling download"
        case .completed:
            return "Download complete"
        case .failed:
            return "Download failed"
        case .cancelled:
            return "Download canceled"
        }
    }

    private var progressText: String {
        let completed = RemoteByteCount.string(transfer.completedBytes)
        guard let total = transfer.totalBytes else { return completed }
        return "\(completed) of \(RemoteByteCount.string(total))"
    }
}

private struct LoadErrorStrip: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Load error")

            Text(message)
                .font(.system(size: 11))
                .lineLimit(2)

            Spacer(minLength: 12)

            Button("Try Again", action: onRetry)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.red.opacity(0.06))
    }
}

private struct ErrorMessage: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum RemoteFilesKeyboardShortcut {
    static func isUnmodified(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad]) == []
    }

    static func isCommandDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.command, .numericPad, .function]) == []
            && flags.contains(.command)
    }
}

private struct RemoteFilesKeyboardMonitor: NSViewRepresentable {
    let onPreview: () -> Bool
    let onActivate: () -> Bool
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPreview: onPreview,
            onActivate: onActivate,
            isEnabled: isEnabled
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onPreview = onPreview
        context.coordinator.onActivate = onActivate
        context.coordinator.isEnabled = isEnabled
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var onPreview: () -> Bool
        var onActivate: () -> Bool
        var isEnabled: Bool
        private var monitor: Any?

        init(
            onPreview: @escaping () -> Bool,
            onActivate: @escaping () -> Bool,
            isEnabled: Bool
        ) {
            self.onPreview = onPreview
            self.onActivate = onActivate
            self.isEnabled = isEnabled
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // AppKit invokes local event monitors on the installing thread. RelayBar
                // installs this monitor from the main actor, but the imported callback
                // lacks that annotation.
                let mainThreadEvent = MainThreadNSEvent(value: event)
                let result = MainActor.assumeIsolated { () -> MainThreadNSEvent? in
                    guard let self else { return mainThreadEvent }
                    return self.handle(mainThreadEvent.value)
                        .map(MainThreadNSEvent.init(value:))
                }
                return result?.value
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard
                isEnabled,
                event.window === view?.window,
                isFileListResponder(event.window?.firstResponder),
                RemoteFilesKeyboardShortcut.isUnmodified(event.modifierFlags)
            else {
                if
                    isEnabled,
                    event.window === view?.window,
                    isFileListResponder(event.window?.firstResponder),
                    event.keyCode == 125,
                    RemoteFilesKeyboardShortcut.isCommandDown(event.modifierFlags)
                {
                    return onActivate() ? nil : event
                }
                return event
            }

            switch event.keyCode {
            case 36, 76:
                return onActivate() ? nil : event
            case 49:
                return onPreview() ? nil : event
            default:
                return event
            }
        }

        private func isFileListResponder(_ responder: NSResponder?) -> Bool {
            guard let view = responder as? NSView else { return false }
            var currentView: NSView? = view
            while let candidate = currentView {
                if candidate is NSTableView || candidate is NSOutlineView {
                    return true
                }
                currentView = candidate.superview
            }
            return false
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}

private struct MainThreadNSEvent: @unchecked Sendable {
    let value: NSEvent
}
