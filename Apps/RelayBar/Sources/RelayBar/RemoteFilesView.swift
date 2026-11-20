import PreviewSupport
import AVKit
import HouseStyle
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

enum RemoteSidebarFocus: Hashable {
    case previewEntry(String)
    case location(UUID)
    case showAllRecentFolders
    case host(UUID)
    case showAllHostPaths(UUID)
}

enum RemoteSidebarFocusNavigator {
    static func adjacent(
        to current: RemoteSidebarFocus?,
        moving direction: MoveCommandDirection,
        within items: [RemoteSidebarFocus]
    ) -> RemoteSidebarFocus? {
        guard !items.isEmpty else { return nil }
        guard direction == .up || direction == .down else { return current }
        guard let current, let index = items.firstIndex(of: current) else {
            return direction == .up ? items.last : items.first
        }
        let offset = direction == .up ? -1 : 1
        return items[min(max(index + offset, 0), items.count - 1)]
    }
}

struct RemoteFilesView: View {
    @HouseTracking private var house
    @ObservedObject var model: RemoteFilesModel
    @FocusState private var focusedSidebarItem: RemoteSidebarFocus?
    @State private var isAddingPath = false
    @State private var isConfirmingServerRemoval = false
    @State private var pendingServerRemovalID: UUID?
    @State private var isPreviewSidebarVisible = true
    @State private var expandedHostIDs: Set<UUID> = []
    @State private var showsAllRecentFolders = false
    @State private var showsAllHostPaths: Set<UUID> = []
    @State private var isConfirmingRecentClear = false
    private let initialFocusedSidebarItem: RemoteSidebarFocus?

    init(
        model: RemoteFilesModel,
        previewSidebarVisible: Bool = true,
        expandedHostIDs: Set<UUID> = [],
        initialFocusedSidebarItem: RemoteSidebarFocus? = nil
    ) {
        self.model = model
        _isPreviewSidebarVisible = State(initialValue: previewSidebarVisible)
        _expandedHostIDs = State(initialValue: expandedHostIDs)
        self.initialFocusedSidebarItem = initialFocusedSidebarItem
    }

    var body: some View {
        let isEnabled = isPreviewSidebarVisible && effectiveFocusedSidebarItem != nil
        Group {
            if isPreviewSidebarVisible {
                HSplitView {
                    workspaceSidebar
                        .frame(minWidth: 210, idealWidth: 250, maxWidth: 360)
                    workspaceDetail
                        .frame(minWidth: 430)
                        .layoutPriority(1)
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                focusedSidebarItem = nil
                            }
                        )
                }
            } else {
                workspaceDetail
            }
        }
        .background(HouseColor.paper)
        .background(
            KeyDownMonitor { event, window in
                guard
                    isEnabled,
                    event.window === window,
                    event.keyCode == 36 || event.keyCode == 76,
                    RemoteFilesKeyboardShortcut.isUnmodified(event.modifierFlags)
                else { return false }
                return activateFocusedSidebarItem()
            }
            .frame(width: 0, height: 0)
        )
        .onAppear {
            if focusedSidebarItem == nil {
                focusedSidebarItem = initialFocusedSidebarItem
            }
        }
        .onChange(of: model.deletionAnnouncement) { announcement in
            if let announcement {
                SystemAccessibilityAnnouncer().announce(announcement)
            }
        }
        .sheet(isPresented: $isAddingPath) {
            AddRemotePathView(model: model)
        }
        .confirmationDialog(
            "Clear all recent remote paths?",
            isPresented: $isConfirmingRecentClear
        ) {
            Button("Clear Recent Locations", role: .destructive) {
                model.clearRecentLocations()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved hosts, forwarding profiles, and SSH config will not change.")
        }
        .confirmationDialog(
            "Remove this saved host?",
            isPresented: $isConfirmingServerRemoval
        ) {
            Button("Remove Saved Host", role: .destructive) {
                if let pendingServerRemovalID {
                    model.removeSavedServer(id: pendingServerRemovalID)
                }
                pendingServerRemovalID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingServerRemovalID = nil
            }
        } message: {
            Text("Its recent paths are removed. Forwarding profiles and SSH config will not change.")
        }
    }

    @ViewBuilder private var workspaceDetail: some View {
        switch model.screen {
        case .welcome:
            workspaceWelcome
        case .browser:
            browser
        case .preview:
            workspacePreview
        }
    }

    private var workspaceSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Locations")
                    .font(.headline)
                Spacer()
                Button {
                    isAddingPath = true
                } label: {
                    Label("Add Path…", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.canActivateLocation)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: RemoteFilesWindowSizing.toolbarHeight)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.screen == .preview, !model.previewableEntries.isEmpty {
                        sidebarSection("IN THIS FOLDER") {
                            ForEach(model.previewableEntries) { entry in
                                Button {
                                    model.selectPreviewEntry(id: entry.id)
                                } label: {
                                    PreviewSidebarRow(
                                        entry: entry,
                                        isSelected: model.previewEntry?.id == entry.id
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(!model.canActivateLocation)
                                .focused(
                                    $focusedSidebarItem,
                                    equals: .previewEntry(entry.id)
                                )
                            }
                        }
                    }

                    if !model.recentLocations.isEmpty {
                        let showsRecentHost = Set(model.recentLocations.map { $0.server.connectionIdentity }).count > 1
                        sidebarSection("RECENT FOLDERS") {
                            ForEach(globallyVisibleRecentLocations) { location in
                                RemoteLocationRow(
                                    location: location,
                                    isActiveRoot: model.screen == .browser
                                        && model.activeLocationID == location.id,
                                    isWorkspaceRoot: model.activeLocationID == location.id,
                                    isKeyboardFocused: effectiveFocusedSidebarItem
                                        == .location(location.id),
                                    showsHost: showsRecentHost,
                                    onActivate: { model.activate(location) },
                                    onRemove: { model.removeRecentLocation(id: location.id) }
                                )
                                .disabled(!model.canActivateLocation)
                                .focused(
                                    $focusedSidebarItem,
                                    equals: .location(location.id)
                                )
                            }
                            if model.recentLocations.count > model.recentFolderLocations.count {
                                Button(showsAllRecentFolders ? "Show Less" : "Show All Recent Folders…") {
                                    showsAllRecentFolders.toggle()
                                }
                                .buttonStyle(.plain)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.top, 4)
                                .focused(
                                    $focusedSidebarItem,
                                    equals: .showAllRecentFolders
                                )
                            }
                        } menu: {
                            Button("Clear Recent Locations…", role: .destructive) {
                                isConfirmingRecentClear = true
                            }
                        }
                    }

                    let recentHosts = model.servers(from: .recent)
                    if !recentHosts.isEmpty {
                        sidebarSection("RECENT HOSTS") {
                            ForEach(recentHosts) { server in
                                recentHost(server)
                            }
                        }
                    }
                }
                .padding(8)
            }
            .onMoveCommand(perform: moveSidebarFocus)

            Divider()
            Text("Recent paths stay on this Mac. RelayBar connects only after you open one.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        // Paper puts the sidebar on its panel tone; the standard form keeps the translucent sidebar it had.
        .background(house == .paper ? AnyShapeStyle(HouseColor.panel) : AnyShapeStyle(.ultraThinMaterial))
        .accessibilityLabel("Remote locations")
    }

    private func sidebarSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title)
                .padding(.horizontal, 8)
            content()
        }
    }

    private func sidebarSection<Content: View, MenuContent: View>(
        _ title: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder menu: () -> MenuContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel(title)
                Spacer()
                Menu {
                    menu()
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 18)
                .accessibilityLabel("Recent folders actions")
            }
            .padding(.horizontal, 8)
            content()
        }
    }

    /// This host's recent paths that Recent Folders does not already show, the ones listed
    /// under the host, and whether that list leaves some out.
    private func hostPaths(
        for server: RemoteServer
    ) -> (all: [RemoteLocation], shown: [RemoteLocation], hasMore: Bool) {
        let visibleKeys = Set(globallyVisibleRecentLocations.map(\.key))
        let all = model.recentLocations.filter {
            $0.server.connectionIdentity == server.connectionIdentity
                && !visibleKeys.contains($0.key)
        }
        let nested = model.nestedLocations(
            for: server,
            excluding: globallyVisibleRecentLocations
        )
        let shown = showsAllHostPaths.contains(server.id) ? all : nested
        return (all, shown, all.count > nested.count)
    }

    @ViewBuilder private func recentHost(_ server: RemoteServer) -> some View {
        let paths = hostPaths(for: server)
        let canExpand = !paths.all.isEmpty
        let isExpanded = canExpand && expandedHostIDs.contains(server.id)

        Button {
            if canExpand {
                expandedHostIDs.formSymmetricDifference([server.id])
            } else {
                model.selectedServerID = server.id
                isAddingPath = true
            }
        } label: {
            HStack(spacing: 7) {
                Image(
                    systemName: canExpand
                        ? (isExpanded ? "chevron.down" : "chevron.right")
                        : "plus"
                )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: server.name.isEmpty ? server.sshHost : server.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !server.name.isEmpty && server.name != server.sshHost {
                        Text(verbatim: server.sshHost)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text("\(model.recentLocationCount(for: server)) recent "
                        + (model.recentLocationCount(for: server) == 1 ? "path" : "paths"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canActivateLocation)
        .focused($focusedSidebarItem, equals: .host(server.id))
        .help(server.displayName)
        .contextMenu {
            Button("Add Path…") {
                model.selectedServerID = server.id
                isAddingPath = true
            }
            .disabled(!model.canActivateLocation)
            if model.isSavedServer(id: server.id) {
                Divider()
                Button("Remove Saved Host…", role: .destructive) {
                    pendingServerRemovalID = server.id
                    isConfirmingServerRemoval = true
                }
                .disabled(!model.canActivateLocation)
            }
        }
        .accessibilityLabel(
            "\(server.displayName), \(model.recentLocationCount(for: server)) recent "
                + (model.recentLocationCount(for: server) == 1 ? "path" : "paths")
        )
        .accessibilityHint(
            canExpand ? "Show remote paths" : "Add a path for this host"
        )

        if isExpanded {
            ForEach(paths.shown) { location in
                RemoteLocationRow(
                    location: location,
                    isActiveRoot: model.screen == .browser
                        && model.activeLocationID == location.id,
                    isWorkspaceRoot: model.activeLocationID == location.id,
                    isKeyboardFocused: effectiveFocusedSidebarItem == .location(location.id),
                    isNested: true,
                    onActivate: { model.activate(location) },
                    onRemove: { model.removeRecentLocation(id: location.id) }
                )
                .disabled(!model.canActivateLocation)
                .focused(
                    $focusedSidebarItem,
                    equals: .location(location.id)
                )
            }
            if paths.hasMore {
                Button(showsAllHostPaths.contains(server.id) ? "Show Less" : "Show All Paths…") {
                    showsAllHostPaths.formSymmetricDifference([server.id])
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .padding(.leading, 40)
                .padding(.top, 2)
                .focused(
                    $focusedSidebarItem,
                    equals: .showAllHostPaths(server.id)
                )
            }
        }
    }

    private var sidebarFocusItems: [RemoteSidebarFocus] {
        var items: [RemoteSidebarFocus] = []
        if model.screen == .preview {
            items += model.previewableEntries.map {
                .previewEntry($0.id)
            }
        }

        items += globallyVisibleRecentLocations.map { .location($0.id) }
        if model.recentLocations.count > model.recentFolderLocations.count {
            items.append(.showAllRecentFolders)
        }

        for server in model.servers(from: .recent) {
            items.append(.host(server.id))
            guard expandedHostIDs.contains(server.id) else { continue }
            let paths = hostPaths(for: server)
            items += paths.shown.map { .location($0.id) }
            if paths.hasMore {
                items.append(.showAllHostPaths(server.id))
            }
        }
        return items
    }

    private var globallyVisibleRecentLocations: [RemoteLocation] {
        showsAllRecentFolders ? model.recentLocations : model.recentFolderLocations
    }

    private var effectiveFocusedSidebarItem: RemoteSidebarFocus? {
        focusedSidebarItem ?? initialFocusedSidebarItem
    }

    @discardableResult
    private func activateFocusedSidebarItem() -> Bool {
        guard let focusedSidebarItem = effectiveFocusedSidebarItem else { return false }
        switch focusedSidebarItem {
        case .previewEntry(let id):
            guard model.canActivateLocation else { return false }
            model.selectPreviewEntry(id: id)
        case .location(let id):
            guard
                model.canActivateLocation,
                let location = model.recentLocations.first(where: { $0.id == id })
            else { return false }
            model.activate(location)
        case .showAllRecentFolders:
            showsAllRecentFolders.toggle()
        case .host(let id):
            guard
                model.canActivateLocation,
                let server = model.servers(from: .recent).first(where: { $0.id == id })
            else { return false }
            if !hostPaths(for: server).all.isEmpty {
                expandedHostIDs.formSymmetricDifference([id])
            } else {
                model.selectedServerID = id
                isAddingPath = true
            }
        case .showAllHostPaths(let id):
            showsAllHostPaths.formSymmetricDifference([id])
        }
        return true
    }

    private func moveSidebarFocus(_ direction: MoveCommandDirection) {
        if case .host(let serverID) = focusedSidebarItem {
            if direction == .right {
                expandedHostIDs.insert(serverID)
                return
            }
            if direction == .left {
                expandedHostIDs.remove(serverID)
                return
            }
        }
        focusedSidebarItem = RemoteSidebarFocusNavigator.adjacent(
            to: focusedSidebarItem,
            moving: direction,
            within: sidebarFocusItems
        )
    }

    private var workspaceWelcome: some View {
        VStack(spacing: 0) {
            HStack {
                sidebarToggle
                Spacer()
                Text(model.isLoading ? model.presentedPath : "Choose a remote location")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") {}
                    .disabled(true)
                Button("Upload…") {}
                    .disabled(true)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: RemoteFilesWindowSizing.toolbarHeight)
            Divider()
            if let errorMessage = model.errorMessage {
                LoadErrorStrip(
                    message: errorMessage,
                    onRetry: model.retryLastLoad,
                    onDismiss: model.dismissLoadError,
                    showsRemoveFromRecents: model.failedLocationID != nil,
                    onRemoveFromRecents: model.removeFailedLocation
                )
                Divider()
            }
            if model.isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Opening remote folder…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Open a remote folder")
                        .font(.title3.weight(.semibold))
                    Text("Choose a recent folder or a path under a recent host. "
                        + "RelayBar won’t connect until you open a location.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 390)
                    Button("Add Path…") {
                        isAddingPath = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canActivateLocation)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            }
        }
    }

    private var workspacePreview: some View {
        let isEnabled = model.screen == .preview
        let isSidebarFocused = isPreviewSidebarVisible && focusedSidebarItem != nil
        return VStack(spacing: 0) {
            previewToolbar
            Divider()
            previewDetail
        }
        .background(
            KeyDownMonitor { event, window in
                guard let window else {
                    return false
                }
                if RemoteHTMLFocus.ownsKeys(window.firstResponder) { return false }
                if
                    isEnabled,
                    !isSidebarFocused,
                    event.window === window || NSApplication.shared.keyWindow === window,
                    event.keyCode == 51 || event.keyCode == 117,
                    RemoteFilesKeyboardShortcut.isCommandDown(event.modifierFlags)
                {
                    guard model.canDeletePreviewEntry else { return false }
                    model.deletePreviewEntry()
                    return true
                }
                guard
                    isEnabled,
                    !isSidebarFocused,
                    event.window === window || NSApplication.shared.keyWindow === window,
                    !hasActiveDocumentTextResponder(in: window),
                    RemoteFilesKeyboardShortcut.isUnmodified(event.modifierFlags)
                else {
                    return false
                }

                switch event.keyCode {
                case 123:
                    return model.movePreviewSelection(by: -1)
                case 124:
                    return model.movePreviewSelection(by: 1)
                default:
                    return false
                }
            }
            .frame(width: 0, height: 0)
        )
        .onExitCommand {
            model.closePreview()
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                focusedSidebarItem = nil
            }
        )
    }

    private var sidebarToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isPreviewSidebarVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.leading")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("s", modifiers: [.control, .command])
        .help(isPreviewSidebarVisible ? "Hide location sidebar" : "Show location sidebar")
        .accessibilityLabel(
            isPreviewSidebarVisible ? "Hide location sidebar" : "Show location sidebar"
        )
    }

    private var browser: some View {
        let isEnabled = model.screen == .browser
        let isSidebarFocused = isPreviewSidebarVisible && focusedSidebarItem != nil
        return VStack(spacing: 0) {
            browserToolbar
            Divider()

            if let upload = model.upload {
                UploadStrip(model: model, upload: upload)
                Divider()
            }

            if let deletion = model.deletion {
                DeletionStrip(model: model, deletion: deletion)
                Divider()
            }

            if let transfer = model.transfer {
                TransferStrip(model: model, transfer: transfer)
                Divider()
            }

            if let errorMessage = model.errorMessage {
                LoadErrorStrip(
                    message: errorMessage,
                    onRetry: model.retryLastLoad,
                    onDismiss: model.dismissLoadError,
                    showsRemoveFromRecents: model.failedLocationID != nil,
                    onRemoveFromRecents: model.removeFailedLocation
                )
                Divider()
            }

            if model.isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Opening folder…")
                        .font(.callout)
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
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileList
            }
        }
        .background(
            KeyDownMonitor { event, window in
                if
                    isEnabled,
                    !isSidebarFocused,
                    event.window === window,
                    isFileListResponder(event.window?.firstResponder),
                    event.keyCode == 51 || event.keyCode == 117,
                    RemoteFilesKeyboardShortcut.isCommandDown(event.modifierFlags)
                {
                    return deleteSelectedFilesOrEntry()
                }
                guard
                    isEnabled,
                    !isSidebarFocused,
                    event.window === window,
                    isFileListResponder(event.window?.firstResponder),
                    RemoteFilesKeyboardShortcut.isUnmodified(event.modifierFlags)
                else {
                    if
                        isEnabled,
                        event.window === window,
                        isFileListResponder(event.window?.firstResponder),
                        event.keyCode == 125,
                        RemoteFilesKeyboardShortcut.isCommandDown(event.modifierFlags)
                    {
                        return activateSelectedEntry()
                    }
                    return false
                }

                switch event.keyCode {
                case 36, 76:
                    return activateSelectedEntry()
                case 49:
                    return previewSelectedEntry()
                default:
                    return false
                }
            }
            .frame(width: 0, height: 0)
        )
        .onExitCommand {
            if model.isSelectingFiles {
                model.cancelFileSelection()
            } else if model.canGoBack {
                model.goBack()
            }
        }
    }

    private func previewSelectedEntry() -> Bool {
        guard !model.isSelectingFiles else { return false }
        if let entry = model.selectedEntry, entry.isPreviewable {
            model.preview(entry)
            return true
        }
        return false
    }

    private func activateSelectedEntry() -> Bool {
        guard !model.isSelectingFiles else { return false }
        guard let entry = model.selectedEntry else { return false }
        model.activate(entry)
        return true
    }

    private func deleteSelectedFilesOrEntry() -> Bool {
        if model.isSelectingFiles {
            guard model.canDeleteSelectedFiles else { return false }
            model.deleteSelectedFiles()
            return true
        }
        guard
            let entry = model.selectedEntry,
            model.canDelete(entry)
        else { return false }
        model.delete(entry)
        return true
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

    private func hasActiveDocumentTextResponder(in window: NSWindow) -> Bool {
        guard let textView = window.firstResponder as? NSTextView else {
            return false
        }
        return !textView.isFieldEditor
    }

    private var browserToolbar: some View {
        GeometryReader { geometry in
            browserToolbarContent(compact: geometry.size.width < 650)
                .frame(height: geometry.size.height)
        }
        .frame(height: RemoteFilesWindowSizing.toolbarHeight)
    }

    private func browserToolbarContent(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            sidebarToggle

            Button {
                model.goBack()
            } label: {
                toolbarLabel("Back", systemImage: "chevron.left", compact: compact)
            }
            .fixedSize()
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!model.canGoBack)
            .help(model.backHelp)

            Text(model.presentedPath)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
                .help(model.presentedPath)
                .accessibilityLabel("Current path \(model.presentedPath)")

            if model.frameViewer != nil {
                Button(action: model.openInFrame) {
                    toolbarLabel("Open in Frame", systemImage: "photo.on.rectangle", compact: compact)
                }
                .fixedSize()
                .disabled(model.currentPath.isEmpty || model.isLoading || model.isDeletionInProgress)
                .help("Open this folder and selected media in Frame’s full viewer")
            }

            if model.isSelectingFiles {
                Button("Cancel") {
                    model.cancelFileSelection()
                }
                .fixedSize()
                .disabled(model.isDeletionInProgress)

                Text("\(model.selectedFileIDs.count) Selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
                    .accessibilityLabel(
                        "\(model.selectedFileIDs.count) "
                            + (model.selectedFileIDs.count == 1 ? "file selected" : "files selected")
                    )

                Button(role: .destructive) {
                    model.deleteSelectedFiles()
                } label: {
                    Label(
                        model.selectedFileIDs.isEmpty
                            ? "Delete"
                            : "Delete \(model.selectedFileIDs.count)",
                        systemImage: "trash"
                    )
                }
                .fixedSize()
                .foregroundStyle(model.canDeleteSelectedFiles ? Color.red : Color.secondary)
                .disabled(!model.canDeleteSelectedFiles)
                .help("Delete the selected files after a 5-second Undo window")
            } else {
                Button {
                    model.refresh()
                } label: {
                    if model.isRefreshing {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            if !compact { Text("Refresh") }
                        }
                    } else {
                        toolbarLabel("Refresh", systemImage: "arrow.clockwise", compact: compact)
                    }
                }
                .fixedSize()
                .help("Refresh folder")
                .accessibilityLabel("Refresh folder")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.canActivateLocation)

                Button {
                    model.beginFileSelection()
                } label: {
                    toolbarLabel("Select", systemImage: "checklist", compact: compact)
                }
                .fixedSize()
                .disabled(!model.canBeginFileSelection)
                .help("Select files for an action")

                Button {
                    model.beginUpload()
                } label: {
                    toolbarLabel("Upload…", systemImage: "arrow.up.circle", compact: compact)
                }
                .fixedSize()
                .help("Upload a file")
                .buttonStyle(.borderedProminent)
                .disabled(!model.canUpload)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: RemoteFilesWindowSizing.toolbarHeight)
    }

    @ViewBuilder
    private func toolbarLabel(_ title: String, systemImage: String, compact: Bool) -> some View {
        if compact {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    private var fileList: some View {
        let listing = model.listing
        return List {
            ForEach(listing.shown) { entry in
                RemoteFileRow(
                    entry: entry,
                    isSelected: model.selectedEntryID == entry.id,
                    isSelectionMode: model.isSelectingFiles,
                    isFileSelected: model.selectedFileIDs.contains(entry.id),
                    showsActions: !model.isSelectingFiles
                        && model.selectedEntryID == entry.id,
                    onSelect: { model.select(entry) },
                    onToggleSelection: { model.toggleFileSelection(entry) },
                    onActivate: { model.activate(entry) },
                    onPreview: { model.preview(entry) },
                    onDownload: { model.download(entry) },
                    onDelete: { model.delete(entry) },
                    canDelete: model.canDelete(entry)
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.visible)
                .listRowSeparatorTint(Color.primary.opacity(0.08))
            }
            if listing.hidden > 0 {
                HStack {
                    Text(FolderListing.hiddenLabel(listing.hidden))
                    Spacer()
                    Button(FolderListing.show) { model.showsHidden = true }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(house == .paper ? .hidden : .automatic)
        .disabled(!model.canInteractWithFileList)
    }

    private var previewToolbar: some View {
        HStack(spacing: 12) {
            sidebarToggle

            Button {
                model.closePreview()
            } label: {
                Label("All Files", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back to folder")
            .disabled(!model.canGoBack)

            Divider()
                .frame(height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.previewEntry?.name ?? "Preview")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let entry = model.previewEntry {
                    Text(previewDescription(for: entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 12)

            if model.frameViewer != nil {
                Button("Open in Frame", systemImage: "photo.on.rectangle") { model.openInFrame() }
                    .buttonStyle(.bordered)
                    .disabled(model.currentPath.isEmpty || model.isLoading || model.isDeletionInProgress)
                    .help("Open this folder and selected asset in Frame’s full viewer")
            }

            Button {
                if let entry = model.previewEntry {
                    model.download(entry)
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .disabled(
                model.transfer?.phase == .active
                    || model.transfer?.phase == .cancelling
                    || model.isDeletionInProgress
                    || model.isLoadingPreview
            )

            Divider()
                .frame(height: 18)

            Button(role: .destructive) {
                model.deletePreviewEntry()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .foregroundStyle(model.canDeletePreviewEntry ? Color.red : Color.secondary)
            .disabled(!model.canDeletePreviewEntry)
            .help("Delete this file after a 5-second Undo window")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: RemoteFilesWindowSizing.toolbarHeight)
    }

    private var previewDetail: some View {
        VStack(spacing: 0) {
            if let transfer = model.transfer {
                TransferStrip(model: model, transfer: transfer)
                Divider()
            }


            if let deletion = model.deletion {
                DeletionStrip(model: model, deletion: deletion)
                Divider()
            }

            if model.isLoadingPreview {
                VStack(spacing: 10) {
                    if let progress = model.previewProgress,
                       let fraction = progress.fraction
                    {
                        ProgressView(value: fraction)
                            .frame(width: 240)
                    } else {
                        ProgressView()
                    }
                    Text(model.previewProgress?.message ?? "Loading preview…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let progress = model.previewProgress {
                        Text(previewProgressDescription(progress))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button("Cancel", action: model.cancelPreviewLoading)
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = model.errorMessage {
                errorState(message: errorMessage, retry: model.retryPreview)
            } else if let videoURL = model.previewVideoURL {
                RemoteVideoPlayerView(url: videoURL)
            } else if let image = model.previewImage {
                GeometryReader { geometry in
                    let maximumWidth = max(0, geometry.size.width - 64)
                    let maximumHeight = max(0, geometry.size.height - 64)
                    ZStack {
                        HouseColor.stage

                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                width: min(image.size.width, maximumWidth),
                                height: min(image.size.height, maximumHeight)
                            )
                            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                            .padding(32)
                            .accessibilityLabel(
                                "Image preview of "
                                    + "\(model.previewEntry?.name ?? "remote file")"
                            )
                    }
                }
            } else if let html = model.previewHTML {
                RemoteHTMLView(renderer: html, retry: model.retryPreview)
            } else if let markdown = model.previewMarkdown {
                SafeRemoteMarkdownView(document: markdown)
            } else if let json = model.previewJSON {
                SafeRemoteJSONView(document: json)
            }
        }
        .background(house == .paper ? HouseColor.paper : Color(nsColor: .textBackgroundColor))
    }

    private func previewDescription(for entry: RemoteFileEntry) -> String {
        let kind = (RemotePreviewPresentation.format(of: entry) ?? .markdown).label
        guard let size = entry.size else { return kind }
        return "\(kind) · \(RemoteByteCount.string(size))"
    }

    private func previewProgressDescription(
        _ progress: RemoteFilesModel.PreviewProgressPresentation
    ) -> String {
        let completed = RemoteByteCount.string(progress.completedBytes)
        guard let total = progress.totalBytes else { return completed }
        let percentage = progress.percentage.map { "\($0)% · " } ?? ""
        return "\(percentage)\(completed) of \(RemoteByteCount.string(total))"
    }

    private func errorState(message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct AddRemotePathView: View {
    @HouseTracking private var house
    @ObservedObject var model: RemoteFilesModel

    @Environment(\.dismiss) private var dismiss
    @State private var isAddingHost = false
    @State private var isOpening = false
    @FocusState private var isPathFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Remote Path")
                    .font(.title3.weight(.semibold))
                Text("Choose an SSH host and enter an exact absolute path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Host")
                    .font(.caption.weight(.medium))
                HStack(spacing: 8) {
                    if model.servers.isEmpty {
                        Text("No SSH hosts available")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Picker("Host", selection: $model.selectedServerID) {
                            ForEach(RemoteServer.Source.pickerOrder, id: \.self) { source in
                                let servers = model.servers(from: source)
                                if !servers.isEmpty {
                                    Section(source.pickerSectionTitle) {
                                        ForEach(servers) { server in
                                            Text(server.displayName)
                                                .tag(Optional(server.id))
                                        }
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .disabled(!model.canActivateLocation)
                    }
                    Button("Add Host…") {
                        isAddingHost = true
                    }
                    .disabled(!model.canActivateLocation)
                }
                Text("Recents, saved hosts, forwarding profiles, and SSH config")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Remote path")
                    .font(.caption.weight(.medium))
                TextField("/srv/app/output", text: $model.remotePath)
                    .textFieldStyle(.roundedBorder)
                    .focused($isPathFocused)
                    .onSubmit(open)
                if let message = model.pathValidationMessage, !model.remotePath.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else {
                    Text("Enter an absolute path beginning with /")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if isOpening, let errorMessage = model.errorMessage {
                ErrorMessage(message: errorMessage)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isOpening && model.isLoading)
                Button(action: open) {
                    if isOpening && model.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Open")
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canOpen)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430)
        .background(HouseColor.paper)
        .onAppear {
            isPathFocused = true
        }
        .onChange(of: model.successfulOpenSequence) { _ in
            if isOpening {
                dismiss()
            }
        }
        .interactiveDismissDisabled(isOpening && model.isLoading)
        .sheet(isPresented: $isAddingHost) {
            AddRemoteServerView { name, sshHost in
                try model.addServer(name: name, sshHost: sshHost)
            }
        }
    }

    private func open() {
        guard model.canOpen else { return }
        isOpening = true
        model.openRemotePath()
    }
}

private struct RemoteLocationRow: View {
    let location: RemoteLocation
    let isActiveRoot: Bool
    let isWorkspaceRoot: Bool
    let isKeyboardFocused: Bool
    var isNested = false
    var showsHost = true
    let onActivate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 8) {
                Image(systemName: isNested ? "arrow.turn.down.right" : "folder.fill")
                    .font(.system(size: isNested ? 10 : 14))
                    .foregroundStyle(isActiveRoot ? Color.white : Color.accentColor)
                    .frame(width: 19)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isNested ? location.path : location.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.head)
                    if !isNested {
                        Text(verbatim: location.path)
                            .font(.caption2)
                            .foregroundStyle(isActiveRoot ? Color.white.opacity(0.78) : .secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        if showsHost {
                            Text(verbatim: location.server.sshHost)
                                .font(.caption2)
                                .foregroundStyle(isActiveRoot ? Color.white.opacity(0.78) : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                Spacer(minLength: 4)
                if isWorkspaceRoot && !isActiveRoot {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Workspace root")
                }
            }
            .padding(.horizontal, isNested ? 20 : 8)
            .frame(minHeight: isNested ? 29 : 38)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActiveRoot ? Color.accentColor : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        isKeyboardFocused
                            ? (isActiveRoot ? Color.white : Color.accentColor)
                            : Color.clear,
                        lineWidth: 2
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open", action: onActivate)
            Button("Remove from Recents", role: .destructive, action: onRemove)
        }
        .accessibilityLabel(
            "\(location.displayName), \(location.server.displayName), \(location.path)"
                + (isWorkspaceRoot ? ", workspace root" : "")
        )
        .accessibilityHint("Open this remote folder")
        .help("\(location.server.displayName)\n\(location.path)")
        .accessibilityAddTraits(isActiveRoot ? .isSelected : [])
    }
}

enum RemoteJSONSyntaxHighlighter {
    static func attributedString(for text: String) -> NSAttributedString {
        let source = text as NSString
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        )
        let punctuation = CharacterSet(charactersIn: "{}[],:" )
        let numberCharacters = CharacterSet(charactersIn: "-+0123456789.eE")
        var index = 0

        while index < source.length {
            let scalar = UnicodeScalar(source.character(at: index))
            if scalar == "\"" {
                let start = index
                index += 1
                while index < source.length {
                    let character = source.character(at: index)
                    if character == 0x5C {
                        index = min(index + 2, source.length)
                    } else if character == 0x22 {
                        index += 1
                        break
                    } else {
                        index += 1
                    }
                }
                var next = index
                while next < source.length,
                      CharacterSet.whitespacesAndNewlines.contains(
                        UnicodeScalar(source.character(at: next))!
                      )
                {
                    next += 1
                }
                let isKey = next < source.length && source.character(at: next) == 0x3A
                result.addAttribute(
                    .foregroundColor,
                    value: isKey ? NSColor.systemPurple : NSColor.systemRed,
                    range: NSRange(location: start, length: index - start)
                )
                continue
            }

            if let scalar, numberCharacters.contains(scalar),
               scalar == "-" || CharacterSet.decimalDigits.contains(scalar)
            {
                let start = index
                index += 1
                while index < source.length,
                      let current = UnicodeScalar(source.character(at: index)),
                      numberCharacters.contains(current)
                {
                    index += 1
                }
                result.addAttribute(
                    .foregroundColor,
                    value: NSColor.systemBlue,
                    range: NSRange(location: start, length: index - start)
                )
                continue
            }

            let remaining = NSRange(location: index, length: source.length - index)
            if source.range(of: "true", options: [], range: remaining).location == index
                || source.range(of: "false", options: [], range: remaining).location == index
                || source.range(of: "null", options: [], range: remaining).location == index
            {
                let length = source.character(at: index) == 0x66 ? 5 : 4
                result.addAttribute(
                    .foregroundColor,
                    value: NSColor.systemOrange,
                    range: NSRange(location: index, length: length)
                )
                index += length
                continue
            }

            if let scalar, punctuation.contains(scalar) {
                result.addAttribute(
                    .foregroundColor,
                    value: NSColor.secondaryLabelColor,
                    range: NSRange(location: index, length: 1)
                )
            }
            index += 1
        }
        return result
    }
}

@MainActor
enum RemoteJSONTextViewFactory {
    static func make(document: RemoteJSONDocument) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView(
            frame: NSRect(origin: .zero, size: scrollView.contentSize)
        )
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel("Read-only JSON preview")
        scrollView.documentView = textView
        update(scrollView, document: document)
        scrollView.needsLayout = true
        return scrollView
    }

    static func update(_ scrollView: NSScrollView, document: RemoteJSONDocument) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let attributed = RemoteJSONSyntaxHighlighter.attributedString(
            for: document.formattedText
        )
        guard textView.attributedString() != attributed else { return }
        textView.textStorage?.setAttributedString(attributed)
        if let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
        }
        scrollView.needsLayout = true
        scrollView.layoutSubtreeIfNeeded()
    }
}

private struct SafeRemoteJSONView: NSViewRepresentable {
    let document: RemoteJSONDocument

    func makeNSView(context: Context) -> NSScrollView {
        RemoteJSONTextViewFactory.make(document: document)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        RemoteJSONTextViewFactory.update(scrollView, document: document)
    }
}

@MainActor
final class RemoteVideoPlayerController {
    let player = AVPlayer()
    private(set) var url: URL?

    func show(_ url: URL) {
        guard self.url != url else { return }
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        self.url = url
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        url = nil
    }
}

@MainActor
struct RemoteVideoPlayerView: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        let controller = RemoteVideoPlayerController()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        playerView.player = context.coordinator.controller.player
        playerView.setAccessibilityLabel("Video preview")
        context.coordinator.controller.show(url)
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        playerView.player = context.coordinator.controller.player
        context.coordinator.controller.show(url)
    }

    static func dismantleNSView(_ playerView: AVPlayerView, coordinator: Coordinator) {
        coordinator.controller.stop()
        playerView.player = nil
    }
}

/// How each preview format is shown: its symbol, its short label and its spoken name.
private struct RemotePreviewPresentation {
    let symbol: String
    let label: String
    let spokenName: String

    /// The preview screen and its sidebar also show this for an entry no format claims.
    static let markdown = RemotePreviewPresentation(symbol: "doc.richtext", label: "Markdown", spokenName: "Markdown document")
    private static let formats: [String: RemotePreviewPresentation] = [
        "image": RemotePreviewPresentation(symbol: "photo", label: "Image", spokenName: "image"),
        "markdown": markdown,
        "json": RemotePreviewPresentation(symbol: "curlybraces", label: "JSON", spokenName: "JSON document"),
        "video": RemotePreviewPresentation(symbol: "film", label: "Video", spokenName: "video"),
        "html": RemotePreviewPresentation(symbol: "globe", label: "HTML", spokenName: "HTML document")
    ]

    /// The format that previews `entry`, or nil when none does.
    static func format(of entry: RemoteFileEntry) -> RemotePreviewPresentation? {
        entry.previewKind.flatMap { formats[$0] }
    }
}

private struct PreviewSidebarRow: View {
    let entry: RemoteFileEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: (RemotePreviewPresentation.format(of: entry) ?? .markdown).symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minHeight: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.20), lineWidth: 0.5)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Select to preview this file")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var metadata: String {
        guard let size = entry.size else { return entry.modificationText }
        return "\(entry.modificationText) · \(RemoteByteCount.string(size))"
    }

    private var accessibilityLabel: String {
        let kind = (RemotePreviewPresentation.format(of: entry) ?? .markdown).spokenName
        return "\(entry.name), \(kind), \(metadata)"
    }
}

private struct AddRemoteServerView: View {
    let onAdd: (String, String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sshHost = ""
    @State private var errorMessage: String?
    @FocusState private var isHostFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add SSH Host")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Name · Optional")
                    .font(.caption.weight(.medium))
                TextField("Development server", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("SSH host")
                    .font(.caption.weight(.medium))
                TextField("user@server", text: $sshHost)
                    .textFieldStyle(.roundedBorder)
                    .focused($isHostFocused)
                    .onSubmit(add)
                Text("RelayBar uses your existing OpenSSH config, keys, and agent.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Host", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            isHostFocused = true
        }
    }

    private func add() {
        do {
            try onAdd(name, sshHost)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RemoteFileRow: View {
    let entry: RemoteFileEntry
    let isSelected: Bool
    let isSelectionMode: Bool
    let isFileSelected: Bool
    let showsActions: Bool
    let onSelect: () -> Void
    let onToggleSelection: () -> Void
    let onActivate: () -> Void
    let onPreview: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void
    let canDelete: Bool

    var body: some View {
        HStack(spacing: 10) {
            if isSelectionMode {
                if entry.kind == .file {
                    Image(
                        systemName: isFileSelected
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                    .font(.system(size: 16))
                    .foregroundStyle(isFileSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                } else {
                    Color.clear.frame(width: 22, height: 1)
                }
            }

            Image(systemName: iconName)
                .font(.system(size: 16))
                .foregroundStyle(iconColor)
                .frame(width: 22)

            Text(entry.name)
                .font(.callout.weight(entry.isDirectory ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 20)

            Text(entry.modificationText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 132, alignment: .trailing)

            Text(sizeText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)

            if showsActions {
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
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .background(
            (isSelectionMode ? isFileSelected : isSelected)
                ? Color.accentColor.opacity(0.12)
                : Color.clear
        )
        .opacity(isSelectionMode && entry.kind != .file ? 0.58 : 1)
        .contentShape(Rectangle())
        .remoteFileRowGestures(
            isSelectionMode: isSelectionMode,
            isSelectableFile: entry.kind == .file,
            onSelect: onSelect,
            onActivate: onActivate,
            onToggleSelection: onToggleSelection
        )
        .contextMenu {
            if !isSelectionMode {
                if entry.isDirectory {
                    Button("Open", action: onActivate)
                } else if entry.isPreviewable {
                    Button("Preview", action: onPreview)
                }
                Button(entry.isDirectory ? "Download Folder…" : "Download…", action: onDownload)
                if entry.kind == .file {
                    Divider()
                    Button("Delete", role: .destructive, action: onDelete)
                        .disabled(!canDelete)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            accessibilityLabel
                + (isSelectionMode && entry.kind == .file
                    ? (isFileSelected ? ", selected for actions" : ", not selected for actions")
                    : "")
        )
        .accessibilityHint(
            isSelectionMode
                ? (entry.kind == .file
                    ? "Toggle this file's selection"
                    : "Folders cannot be selected in file-selection mode")
                : ""
        )
        .accessibilityAddTraits(
            (isSelectionMode ? isFileSelected : isSelected) ? .isSelected : []
        )
        .remoteFileRowAccessibilityActions(
            entry: entry,
            isSelectionMode: isSelectionMode,
            isFileSelected: isFileSelected,
            canDelete: canDelete,
            onActivate: onActivate,
            onDownload: onDownload,
            onDelete: onDelete,
            onToggleSelection: onToggleSelection
        )
    }

    private var iconName: String {
        if entry.isDirectory { return "folder.fill" }
        if let format = RemotePreviewPresentation.format(of: entry) { return format.symbol }
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
        case .file: type = RemotePreviewPresentation.format(of: entry)?.spokenName ?? "file"
        case .symbolicLink: type = "symbolic link"
        }
        return "\(entry.name), \(type), modified \(entry.modificationText), \(sizeText)"
    }
}

private extension View {
    @ViewBuilder
    func remoteFileRowGestures(
        isSelectionMode: Bool,
        isSelectableFile: Bool,
        onSelect: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        onToggleSelection: @escaping () -> Void
    ) -> some View {
        if isSelectionMode {
            if isSelectableFile {
                onTapGesture(perform: onToggleSelection)
            } else {
                self
            }
        } else {
            onTapGesture(count: 2, perform: onActivate)
                .onTapGesture(perform: onSelect)
        }
    }

    @ViewBuilder
    func remoteFileRowAccessibilityActions(
        entry: RemoteFileEntry,
        isSelectionMode: Bool,
        isFileSelected: Bool,
        canDelete: Bool,
        onActivate: @escaping () -> Void,
        onDownload: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onToggleSelection: @escaping () -> Void
    ) -> some View {
        if isSelectionMode {
            if entry.kind == .file {
                accessibilityAction(
                    named: Text(isFileSelected ? "Deselect" : "Select"),
                    onToggleSelection
                )
            } else {
                self
            }
        } else {
            accessibilityAction(
                named: Text(
                    entry.isDirectory
                        ? "Open"
                        : (entry.isPreviewable ? "Preview" : "Download")
                ),
                onActivate
            )
            .accessibilityAction(
                named: Text(entry.isDirectory ? "Download Folder" : "Download"),
                onDownload
            )
            .remoteDeleteAccessibilityAction(enabled: canDelete, action: onDelete)
        }
    }

    @ViewBuilder
    func remoteDeleteAccessibilityAction(
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if enabled {
            accessibilityAction(named: Text("Delete"), action)
        } else {
            self
        }
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
                    .font(.callout.weight(.medium))
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
                        .font(.caption)
                        .foregroundStyle(transfer.phase == .failed ? .red : .secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if transfer.phase == .active {
                Text(progressText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    model.cancelTransfer()
                }
            } else if transfer.phase == .cancelling {
                Text(progressText)
                    .font(.system(.caption, design: .monospaced))
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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

private struct UploadStrip: View {
    @ObservedObject var model: RemoteFilesModel
    let upload: RemoteFilesModel.UploadPresentation

    var body: some View {
        HStack(spacing: 11) {
            statusIcon
                .accessibilityLabel(statusAccessibilityLabel)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if upload.phase == .active || upload.phase == .cancelling {
                    if upload.phase == .active,
                       upload.operationPhase == .staging,
                       let fraction = upload.fraction
                    {
                        ProgressView(value: fraction)
                            .accessibilityLabel(title)
                            .accessibilityValue(progressText)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(title)
                            .accessibilityValue(upload.message ?? "In progress")
                    }
                } else if let message = upload.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(upload.phase == .failed ? .red : .secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            if upload.phase == .active {
                Text(
                    upload.operationPhase == .staging
                        ? progressText
                        : (upload.message ?? upload.operationPhase.presentationText)
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") { model.cancelUpload() }
            } else if upload.phase == .cancelling {
                Button("Canceling…") {}
                    .disabled(true)
            } else if upload.phase == .failed || upload.phase == .cancelled {
                Button("Try Again") { model.retryUpload() }
                Button("Dismiss") { model.dismissUpload() }
            } else {
                Button("Dismiss") { model.dismissUpload() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
    }

    @ViewBuilder private var statusIcon: some View {
        switch upload.phase {
        case .active:
            Image(systemName: "arrow.up.circle")
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
        let name = upload.localFile.lastPathComponent
        switch upload.phase {
        case .active: return "Uploading \(name)"
        case .cancelling: return "Canceling \(name)"
        case .completed: return "Uploaded \(name)"
        case .failed: return "Couldn’t upload \(name)"
        case .cancelled: return "Canceled \(name)"
        }
    }

    private var statusAccessibilityLabel: String {
        switch upload.phase {
        case .active: return "Upload in progress"
        case .cancelling: return "Canceling upload"
        case .completed: return "Upload complete"
        case .failed: return "Upload failed"
        case .cancelled: return "Upload canceled"
        }
    }

    private var progressText: String {
        if let percentage = upload.percentage {
            return "\(percentage)% · \(RemoteByteCount.string(upload.completedBytes)) of "
                + RemoteByteCount.string(upload.totalBytes)
        }
        return upload.message ?? upload.operationPhase.presentationText
    }
}

private struct DeletionStrip: View {
    @ObservedObject var model: RemoteFilesModel
    let deletion: RemoteFilesModel.DeletionPresentation

    var body: some View {
        HStack(spacing: 10) {
            if deletion.phase == .active {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Deletion in progress")
            } else if deletion.phase == .pendingUndo {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Deletion pending")
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Deletion warning")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(deletion.message ?? "Deleting \(deletion.entry.name)…")
                    .font(.caption)
                    .lineLimit(2)
                if let deadline = deletion.undoDeadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Undo available for \(max(0, Int(ceil(deadline.timeIntervalSince(context.date)))))s")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 12)

            switch deletion.phase {
            case .pendingUndo:
                Button("Undo") { model.undoDeletion() }
                    .keyboardShortcut("z", modifiers: .command)
            case .active:
                Text("Deleting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed:
                Button("Dismiss") { model.dismissDeletion() }
            case .outcomeUnknown:
                Button("Refresh") { model.refreshAfterUnknownDeletion() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.07))
    }
}

private struct LoadErrorStrip: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void
    let showsRemoveFromRecents: Bool
    let onRemoveFromRecents: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Load error")

            Text(message)
                .font(.caption)
                .lineLimit(2)

            Spacer(minLength: 12)

            Button("Try Again", action: onRetry)
            if showsRemoveFromRecents {
                Divider()
                    .frame(height: 16)
                Button("Remove from Recents", role: .destructive) {
                    onRemoveFromRecents()
                }
                .foregroundStyle(.red)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.06))
    }
}

private struct ErrorMessage: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum RemoteFilesKeyboardShortcut {
    static func isUnmodified(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function]) == []
    }

    static func isCommandDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.command, .numericPad, .function]) == []
            && flags.contains(.command)
    }
}

/// One key-down monitor for the window that shows this view. `handle` receives
/// the event and that window, and returns true when it consumed the event.
private struct KeyDownMonitor: NSViewRepresentable {
    let handle: (NSEvent, NSWindow?) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(handle: handle)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.handle = handle
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var handle: (NSEvent, NSWindow?) -> Bool
        private var monitor: Any?

        init(handle: @escaping (NSEvent, NSWindow?) -> Bool) {
            self.handle = handle
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
                    return self.handle(mainThreadEvent.value, self.view?.window) ? nil : mainThreadEvent
                }
                return result?.value
            }
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
