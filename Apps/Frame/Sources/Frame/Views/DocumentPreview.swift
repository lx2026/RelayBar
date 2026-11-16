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
      HStack(spacing: 12) {
        Button(action: renderer.back) { Image(systemName: "chevron.left") }.disabled(!renderer.canGoBack).help("Back")
        Button(action: renderer.forward) { Image(systemName: "chevron.right") }.disabled(!renderer.canGoForward).help("Forward")
        Spacer()
        if renderer.loading { ProgressView().controlSize(.mini) }
        if let error = renderer.error {
          Text(error).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).help(error)
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
        }
      }.buttonStyle(.plain).padding(.horizontal, 16).frame(height: 32)
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

private struct DocumentWebView: NSViewRepresentable {
  let renderer: DocumentRenderer
  func makeNSView(context: Context) -> WKWebView { renderer.webView }
  func updateNSView(_ view: WKWebView, context: Context) {}
}
