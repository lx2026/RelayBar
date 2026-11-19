import Composition
import CompositionUI
import FrameKit
import SwiftData
import SwiftUI

@main
struct FrameApp: App {
  static let mainWindowID = "main"
  @NSApplicationDelegateAdaptor(FrameAppDelegate.self) private var appDelegate
  @Environment(\.openWindow) private var openWindow
  @StateObject private var store: LibraryStore
  private let modelContainer: ModelContainer

  init() {
    // Frame's window always uses the overlay scroller. Native scroll views force it themselves; WebKit has no
    // per-view style and draws the document's scroll bars from this preference, so the app sets it for itself.
    var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments["AppleShowScrollBars"] = "WhenScrolling"
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    RemoteSessionStorage.start()
    let preferencesURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.lx2026.Frame", isDirectory: true)
      .appendingPathComponent("preferences.json")
#if DEBUG
    if Bundle.main.bundleIdentifier == VerificationLibrary.bundleID {
      let previews = FrameComposition(preferencesURL: preferencesURL, remoteSession: VerificationLibrary.session)
      _store = StateObject(wrappedValue: LibraryStore(previews: previews))
    } else {
      _store = StateObject(wrappedValue: LibraryStore(previews: FrameComposition(preferencesURL: preferencesURL, connectAutomatically: true)))
    }
#else
    _store = StateObject(wrappedValue: LibraryStore(previews: FrameComposition(preferencesURL: preferencesURL, connectAutomatically: true)))
#endif
    do {
      modelContainer = try FrameCatalogStore.open()
    } catch {
      fatalError("Could not create Frame catalog: \(error)")
    }
  }

  var body: some Scene {
    Window("Frame", id: Self.mainWindowID) {
      FrameRootView(store: store, modelContainer: modelContainer)
        .onAppear {
          appDelegate.store = store
          appDelegate.reopenMainWindow = { [openWindow] in openWindow(id: Self.mainWindowID) }
        }
        .frame(minWidth: 960, minHeight: 640)
        .onOpenURL { url in Task { await store.handleHandoff(url) } }
    }
    .defaultSize(width: 1_280, height: 800)
    .windowStyle(.hiddenTitleBar)
    .commands {
      FrameCommands(store: store)
#if DEBUG
      CommandMenu("Verification") {
        Button("Open Remote Verification Library") {
          guard Bundle.main.bundleIdentifier == VerificationLibrary.bundleID else { return }
          Task {
            await store.setShowsRemoteFolders(true)
            await store.openRemote(VerificationLibrary.source, path: "/Photos")
          }
        }
        Button("Open Bundled Verification Library") {
          guard let source = Bundle.main.resourceURL?.appendingPathComponent("VerificationLibrary"),
                FileManager.default.fileExists(atPath: source.path) else { return }
          let target = FileManager.default.temporaryDirectory.appendingPathComponent("FrameVerification-\(UUID())")
          do {
            try FileManager.default.copyItem(at: source, to: target)
            Task { await store.openRoot(target) }
          } catch { store.errorMessage = error.localizedDescription }
        }
        Button("Light Appearance") { NSApp.appearance = NSAppearance(named: .aqua) }
        Button("Dark Appearance") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        Button("System Appearance") { NSApp.appearance = nil }
        Divider()
        Button("Minimum Window") { NSApp.keyWindow?.setContentSize(NSSize(width: 960, height: 640)) }
        Button("Default Window") { NSApp.keyWindow?.setContentSize(NSSize(width: 1280, height: 800)) }
      }
#endif
    }
    Settings { FrameSettings(store: store) }
    Window("Plugins", id: "plugins") {
      PluginsWindow(composition: store.previews)
        .frame(minWidth: 900, minHeight: 540)
    }
    .defaultSize(width: 1_180, height: 720)
  }
}

/// The Plugins window's content. Its composer follows the running feature tree while the window is open.
private struct PluginsWindow: View {
  @StateObject private var composer: PluginComposer

  init(composition: FrameComposition) {
    _composer = StateObject(wrappedValue: PluginComposer(
      runtime: composition.runtime,
      plugins: FramePlugins.all,
      isEnabled: { composition.isPluginEnabled($0) },
      setEnabled: { try await composition.setPlugin($0, enabled: $1) }))
  }

  var body: some View {
    PluginComposerView(composer: composer)
  }
}

@MainActor
final class FrameAppDelegate: NSObject, NSApplicationDelegate {
  weak var store: LibraryStore?
  var reopenMainWindow: (() -> Void)?
  private var termination: Task<Void, Never>?

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
    // Settings and Plugins can stay visible after the library window closes.
    guard let reopenMainWindow else { return true }
    if sender.windows.contains(where: {
      $0.identifier?.rawValue == FrameApp.mainWindowID && $0.isVisible && !$0.isMiniaturized
    }) { return true }
    reopenMainWindow()
    return false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard termination == nil else { return .terminateLater }
    termination = Task {
      await store?.shutdown()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
  func applicationWillTerminate(_ notification: Notification) { RemoteSessionStorage.clear() }
}

private struct FrameCommands: Commands {
  @ObservedObject var store: LibraryStore
  @ObservedObject var playback: PlaybackController
  @Environment(\.openWindow) private var openWindow

  init(store: LibraryStore) {
    self.store = store
    self.playback = store.playback
  }

  var body: some Commands {
    CommandGroup(after: .appSettings) {
      Button("Plugins…") { openWindow(id: "plugins") }
    }
    CommandGroup(after: .newItem) {
      Button("Open…") {
        openWindow(id: FrameApp.mainWindowID)
        store.presentOpenChooser()
      }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(store.isFileOperation)
    }
    CommandGroup(replacing: .undoRedo) {
      Button(store.undoTitle, action: store.undoTrash)
        .keyboardShortcut("z", modifiers: .command)
        .disabled(!store.canUndoTrash)
    }
    CommandMenu("Media") {
      // Unmodified shortcuts belong to the focused viewer, never the app menu.
      Button("Previous File (← in viewer)") { store.navigate(by: -1) }
        .disabled(!store.hasAvailableSelection)
      Button("Next File (→ in viewer)") { store.navigate(by: 1) }
        .disabled(!store.hasAvailableSelection)
      Divider()
      Button("Favorite and Next (F)") { store.toggleFavorite() }
        .disabled(!store.canFavorite)
      Button("Contact Sheet (G in viewer)") { store.toggleContactSheet() }
        .disabled(store.visiblePhotos.isEmpty || store.isScanning || store.isFileOperation
                  || (store.viewMode == .contactSheet && store.batchSelection.ids.isEmpty))
      Button("Open Viewer (Return)") { store.openViewer() }
        .disabled(!store.canInspect)
      Button("Full Screen Viewer", action: store.toggleFullScreen)
        .keyboardShortcut("f", modifiers: [.control, .command])
        .disabled(!store.canInspect)
      Button(playback.isPlaying ? "Pause (Space in viewer)" : "Play (Space in viewer)") { store.togglePlayback() }
        .disabled(!store.hasAvailableSelection || playback.player == nil || store.viewMode != .inspect)
      Divider()
      Button(store.filter == .archive ? "Restore Selected Assets" : "Archive Selected Assets", action: store.archiveSelected)
        .disabled(!store.canArchive)
      Button("\(store.deleteTitle) \(store.actionPhotos.count) Assets") { store.deleteSelected() }
        .disabled(!store.canDelete)
      Button("Export Exact Copy…") { store.exportSelected() }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(!store.canExport)
    }
    CommandGroup(after: .sidebar) {
      if store.isRemote {
        Button("Parent Folder", action: store.remoteParent)
          .keyboardShortcut(.upArrow, modifiers: .command)
          .disabled(store.remotePath == "/" || store.isFileOperation)
      }
      Button("Refresh Folder") { store.refresh() }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(!store.canRefresh)
      if store.previews.isPluginEnabled(FramePlugins.promptSearch) {
        Button("Search Prompts", action: store.revealSearch)
          .keyboardShortcut("f", modifiers: .command)
          .disabled(!store.isSearchAvailable)
      }
    }
  }
}
