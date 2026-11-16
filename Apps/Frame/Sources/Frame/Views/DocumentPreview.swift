import AppKit
import FrameKit
import SwiftUI
import WebKit

struct DocumentPreview: View {
  let photo: PhotoItem
  @ObservedObject var store: LibraryStore
  @ObservedObject private var renderer: DocumentRenderer
  init(photo: PhotoItem, store: LibraryStore) {
    self.photo = photo; self.store = store; renderer = store.documentRenderer
  }
  var body: some View {
    VStack(spacing: 0) {
      // Back and Forward live in the header or toolbar above (DocumentNavigation); only a failure takes a row here.
      if let error = renderer.error {
        HStack(spacing: 12) {
          Text(error).font(.subheadline).foregroundStyle(FramePalette.muted).lineLimit(1).help(error)
          Spacer(minLength: 0)
          Button("Retry") { if photo.remote == nil { renderer.retry() } else { show() } }
          Button("Open in Default App") {
            Task {
              do {
                let file = photo.remote == nil ? photo : try await store.previews.media.resolveOriginal(photo)
                NSWorkspace.shared.open(file.url)
              }
              catch { store.errorMessage = error.localizedDescription }
            }
          }.disabled(!store.canOpenSelectedInDefaultApp)
        }.buttonStyle(.plain).padding(.horizontal, FrameMetrics.inset).frame(height: FrameMetrics.barHeight)
          .background(FramePalette.panel)
      }
      DocumentWebView(renderer: renderer)
    }
    .onAppear { show() }
    .onChange(of: photo.id) { _, _ in show() }
    .onChange(of: store.previews.settingsID(for: photo)) { _, _ in
      if store.previews.enabledKinds.contains(FrameComposition.kind(for: photo)),
         photo.remote == nil || store.previews.link.isConnected { show() }
    }
    .onChange(of: store.documentRevision) { _, _ in Task { await renderer.refresh() } }
    .onChange(of: photo.contentID) { _, _ in Task { await renderer.refresh() } }
    .onDisappear { store.previews.stopDocument() }
  }
  private func show() {
    guard let location = store.documentLocation else { return }
    renderer.onNavigate = { store.openDocumentLink($0) }
    store.previews.showDocument(photo, path: store.documentPath(photo), location: location)
  }
}

/// Back and Forward for the document on screen, shown in the row that already sits above it.
struct DocumentNavigation: View {
  @ObservedObject var renderer: DocumentRenderer
  var body: some View {
    HStack(spacing: 0) {
      Button(action: renderer.back) { Image(systemName: "chevron.left") }.disabled(!renderer.canGoBack).help("Back")
      Button(action: renderer.forward) { Image(systemName: "chevron.right") }.disabled(!renderer.canGoForward).help("Forward")
      if renderer.loading { ProgressView().controlSize(.mini).padding(.leading, 4) }
    }.buttonStyle(IconButtonStyle())
  }
}

private struct DocumentWebView: NSViewRepresentable {
  let renderer: DocumentRenderer
  func makeNSView(context: Context) -> WKWebView { renderer.webView }
  func updateNSView(_ view: WKWebView, context: Context) {}
}
