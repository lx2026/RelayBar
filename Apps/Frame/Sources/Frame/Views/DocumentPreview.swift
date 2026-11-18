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
      // Back and Forward live in the top row above (DocumentNavigation); only a failure takes a row here.
      if let error = renderer.error {
        HStack(spacing: 12) {
          Text(error).font(.subheadline).foregroundStyle(FramePalette.muted).lineLimit(1).help(error)
          Spacer(minLength: 0)
          Button("Retry") { if photo.remote == nil { renderer.retry() } else { show() } }
          Button("Open in Default App", action: store.openSelectedInDefaultApp).disabled(!store.canOpenSelectedInDefaultApp)
        }.buttonStyle(.plain).padding(.horizontal, FrameMetrics.readerLeading).frame(height: FrameMetrics.barHeight)
          .background(FramePalette.panel)
      }
      // A page brings its own layout and colours, so it is framed as a card; Markdown and text read on the paper.
      let card = photo.format == .html && !renderer.showsSource
      DocumentWebView(renderer: renderer, card: card)
        .overlay {
          if card {
            UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10, style: .continuous)
              .strokeBorder(FramePalette.line, lineWidth: 1).padding(.bottom, -1).allowsHitTesting(false)
          }
        }
        .padding(.top, card ? 4 : 0)
        .padding(.leading, card ? FrameMetrics.readerLeading : 0)
        .padding(.trailing, card ? FrameMetrics.readerTrailing : 0)
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

/// Back and Forward through the documents shown, in the top row's More menu.
struct DocumentHistoryItems: View {
  @ObservedObject var renderer: DocumentRenderer
  var body: some View {
    Button("Back", action: renderer.back).disabled(!renderer.canGoBack)
    Button("Forward", action: renderer.forward).disabled(!renderer.canGoForward)
  }
}

/// A small spinner beside the document's name while it loads.
struct DocumentProgress: View {
  @ObservedObject var renderer: DocumentRenderer
  var body: some View {
    if renderer.loading { ProgressView().controlSize(.mini).padding(.leading, 4) }
  }
}

/// The renderer's one web view, inside a container that gives a page its card corners.
private struct DocumentWebView: NSViewRepresentable {
  let renderer: DocumentRenderer
  let card: Bool
  func makeNSView(context: Context) -> DocumentContainer { DocumentContainer() }
  func updateNSView(_ view: DocumentContainer, context: Context) { view.show(renderer.webView, card: card) }
}

final class DocumentContainer: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    layer?.cornerCurve = .continuous
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  private var card = false
  func show(_ web: WKWebView, card: Bool) {
    if web.superview !== self {
      web.removeFromSuperview()
      web.frame = bounds
      web.autoresizingMask = [.width, .height]
      addSubview(web)
    }
    self.card = card
    layer?.cornerRadius = card ? 10 : 0
    layer?.masksToBounds = card
    needsDisplay = true
    updateLayer()
  }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {
    layer?.backgroundColor = card ? NSColor.white.cgColor : NSColor.clear.cgColor
  }
}
