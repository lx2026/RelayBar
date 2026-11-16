import FrameKit
import SwiftUI
import WebKit

/// Window-scoped keys remain available after clicking viewer controls or metadata.
struct MediaKeyboardShortcuts: NSViewRepresentable {
  let store: LibraryStore
  func makeCoordinator() -> Coordinator { Coordinator(store: store) }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.install(in: view)
    return view
  }
  func updateNSView(_ view: NSView, context: Context) { context.coordinator.store = store }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

  @MainActor final class Coordinator {
    var store: LibraryStore
    private var monitor: Any?
    /// Keystrokes meant for a text control that lost the focus on its own never become shortcuts.
    private var typing = TypingGuard()
    init(store: LibraryStore) { self.store = store }
    func install(in view: NSView) {
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak view] event in
        guard let self, let window = view?.window, event.window === window else { return event }
        guard event.type == .keyDown else {
          typing.pointerDown()
          return event
        }
        guard window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
              !store.showsOpenChooser, store.fileActionFailures.isEmpty, store.errorMessage == nil else { return event }
        let focused = TypingGuard.field(for: window.firstResponder)
        // What this key would do to the selection if nothing were being typed.
        let shortcut = MediaKeyAction.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags,
            viewing: store.viewMode == .inspect, editingText: false, selecting: store.isSelecting)
        if case .swallow(let refocusSearch) = typing.key(code: event.keyCode, focused: focused, wouldAct: shortcut != nil) {
          if refocusSearch {
            store.focusSearch()
          }
          return nil
        }
        let editing = focused != nil
        if DocumentFocus.ownsKeys(window.firstResponder) { return event }
        // Web content owns all its keys, including contenteditable, canvas and native controls.
        var responder = window.firstResponder as? NSView
        while let current = responder {
          if current.identifier?.rawValue == "FrameFileTree" { return event }
          responder = current.superview
        }
        guard let action = MediaKeyAction.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags,
            viewing: store.viewMode == .inspect, editingText: editing, selecting: store.isSelecting) else { return event }
        switch action {
        case .delete: store.deleteSelected()
        case .previous: store.navigate(by: -1)
        case .next: store.navigate(by: 1)
        case .toggleSelection: store.toggleCurrentSelection()
        case .favorite: store.toggleFavorite()
        }
        return nil
      }
    }
    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}
