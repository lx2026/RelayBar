import MarkdownRendering
import AppKit
import Foundation
import SwiftUI
import WebKit

struct RemoteMarkdownDocument: Sendable {
    let referenceToken: String
    let page: MarkdownPage

    var plainText: String {
        page.plainText
    }
}

enum RemoteMarkdownDecoder {
    static let maximumByteCount = 2 * 1_024 * 1_024

    static func load(
        contentsOf url: URL,
        renderingWith renderer: @escaping @Sendable (String, String) throws -> MarkdownPage = {
            MarkdownRenderer.page($0, options: .init(referenceToken: $1, images: .placeholder, links: .indexed))
        }
    ) async throws -> RemoteMarkdownDocument {
        let referenceToken = UUID().uuidString.lowercased()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let data = try readBoundedData(from: url)
            try Task.checkCancellation()
            let source = try decode(data)
            try Task.checkCancellation()
            let page = try renderer(source, referenceToken)
            // A cancelled render returns an empty page, which must not be published.
            try Task.checkCancellation()
            return RemoteMarkdownDocument(referenceToken: referenceToken, page: page)
        }
        return try await withTaskCancellationHandler {
            let document = try await worker.value
            try Task.checkCancellation()
            return document
        } onCancel: {
            worker.cancel()
        }
    }

    static func decode(_ data: Data) throws -> String {
        guard data.count <= maximumByteCount else {
            throw RemoteFileError.markdownTooLarge
        }
        guard var source = String(data: data, encoding: .utf8) else {
            throw RemoteFileError.invalidMarkdownEncoding
        }
        guard !source.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw RemoteFileError.invalidMarkdownEncoding
        }
        if source.unicodeScalars.first?.value == 0xFEFF {
            source.removeFirst()
        }
        return source
    }

    private static func readBoundedData(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumByteCount + 1) ?? Data()
        guard data.count <= maximumByteCount else {
            throw RemoteFileError.markdownTooLarge
        }
        return data
    }
}

enum SafeMarkdownLinkPolicy {
    enum Decision: Equatable {
        case external
        case wiki(String)
        case tag(String)
        case footnote(String)
        case internalMarkdown(String)
        case blocked
    }

    static func decision(for url: URL, referenceToken: String) -> Decision {
        if
            let wiki = ObsidianMarkdownCompatibility.internalValue(
                from: url,
                expectedScheme: "relaybar-wiki",
                referenceToken: referenceToken
            ),
            wiki.kind == "open"
        {
            return .wiki(wiki.value)
        }
        if
            let tag = ObsidianMarkdownCompatibility.internalValue(
                from: url,
                expectedScheme: "relaybar-tag",
                referenceToken: referenceToken
            ),
            tag.kind == "open"
        {
            return .tag(tag.value)
        }
        if
            let footnote = ObsidianMarkdownCompatibility.internalValue(
                from: url,
                expectedScheme: "relaybar-footnote",
                referenceToken: referenceToken
            ),
            footnote.kind == "note"
        {
            return .footnote(footnote.value)
        }
        if allows(url) {
            return .external
        }
        if let reference = internalMarkdownReference(from: url) {
            return .internalMarkdown(reference)
        }
        return .blocked
    }

    static func allows(_ url: URL) -> Bool {
        guard
            let scheme = url.scheme?.lowercased(),
            ["http", "https", "mailto"].contains(scheme),
            decodedWithoutControls(url.absoluteString) != nil
        else {
            return false
        }

        if scheme == "mailto" {
            return hasMailRecipient(in: url.absoluteString)
        }
        return url.user == nil
            && url.password == nil
            && url.host?.isEmpty == false
    }

    private static func hasMailRecipient(in value: String) -> Bool {
        guard let separator = value.firstIndex(of: ":") else {
            return false
        }
        let payload = value[value.index(after: separator)...]
        let recipient = payload.prefix { $0 != "?" && $0 != "#" }
        return !recipient.isEmpty
    }

    private static func internalMarkdownReference(from url: URL) -> String? {
        let rawReference = url.relativeString
        guard
            let decodedReference = decodedWithoutControls(rawReference),
            url.scheme == nil,
            url.host == nil,
            url.user == nil,
            url.password == nil,
            !rawReference.isEmpty,
            !rawReference.hasPrefix("/"),
            !rawReference.hasPrefix("//"),
            !url.path.isEmpty || url.fragment != nil,
            rawReference.utf8.count <= ObsidianMarkdownCompatibility
                .maximumFormulaCharacterCount
        else {
            return nil
        }
        return decodedReference
    }

    private static func decodedWithoutControls(_ value: String) -> String? {
        guard
            let decoded = value.removingPercentEncoding,
            !value.unicodeScalars.contains(where: isControl),
            !decoded.unicodeScalars.contains(where: isControl)
        else {
            return nil
        }
        return decoded
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar)
            || CharacterSet.newlines.contains(scalar)
    }
}

struct SafeRemoteMarkdownView: View {
    let document: RemoteMarkdownDocument

    @State private var linkAlert: MarkdownLinkAlert?

    var body: some View {
        RemoteMarkdownPageView(document: document) { decision in
            linkAlert = MarkdownLinkAlert.explaining(decision)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .alert(item: $linkAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

private struct RemoteMarkdownPageView: NSViewRepresentable {
    let document: RemoteMarkdownDocument
    let onDecision: (SafeMarkdownLinkPolicy.Decision) -> Void

    func makeNSView(context: Context) -> RemoteMarkdownWebView {
        let view = RemoteMarkdownWebView()
        view.onDecision = onDecision
        view.show(document)
        return view
    }

    func updateNSView(_ view: RemoteMarkdownWebView, context: Context) {
        view.onDecision = onDecision
        view.show(document)
    }

    static func dismantleNSView(_ view: RemoteMarkdownWebView, coordinator: ()) {
        view.close()
    }
}

/// Shows one rendered Markdown page and nothing else. The page runs no script, loads
/// nothing and never navigates; every link the reader clicks is judged here instead.
final class RemoteMarkdownWebView: WKWebView, WKNavigationDelegate, WKUIDelegate {
    static let baseScheme = "relaybar-markdown"
    static let contentPolicy =
        "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'"
    /// The context-menu items that would navigate, open a window or download, and Copy Link,
    /// which would copy a reference that means nothing outside this page.
    static let navigatingMenuItems: Set<String> = [
        "WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
        "WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierCopyLink",
        "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierDownloadImage",
        "WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierOpenFrameInNewWindow",
        "WKMenuItemIdentifierOpenMediaInNewWindow", "WKMenuItemIdentifierDownloadMedia"
    ]
    private static let reloadLimit = 3

    /// Every link decision except Copy, after an external link has been opened.
    var onDecision: ((SafeMarkdownLinkPolicy.Decision) -> Void)?
    var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var copyText: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        _ = NSPasteboard.general.setString(text, forType: .string)
    }

    private struct Content {
        let html: String
        let baseURL: URL
        let referenceToken: String
        let codeBlocks: [String]
        let links: [String]
    }

    private(set) var document: RemoteMarkdownDocument?
    private var content: Content?
    private var awaitsLoad = false
    private var reloads = 0
    private var feedback: Task<Void, Never>?

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        super.init(frame: .zero, configuration: configuration)
        navigationDelegate = self
        uiDelegate = self
        allowsBackForwardNavigationGestures = false
        allowsMagnification = false
        allowsLinkPreview = false
        // The surrounding view paints the text background, so loading never flashes white.
        setValue(false, forKey: "drawsBackground")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ document: RemoteMarkdownDocument) {
        if
            let current = self.document,
            current.referenceToken == document.referenceToken,
            current.page == document.page
        {
            return
        }
        self.document = document
        load(
            body: MarkdownRenderer.body(document.page),
            referenceToken: document.referenceToken,
            codeBlocks: document.page.codeBlocks,
            links: document.page.links
        )
    }

    /// Loads a page body after this view's own head and content policy. Tests use it
    /// directly to hand the view markup the renderer would never produce.
    func load(body: String, referenceToken: String, codeBlocks: [String] = [], links: [String] = []) {
        var base = URLComponents()
        base.scheme = Self.baseScheme
        base.host = referenceToken
        base.path = "/"
        guard let baseURL = base.url else { return }
        let head = "<!doctype html><meta charset=\"utf-8\">"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"\(Self.contentPolicy)\">"
        content = Content(
            html: head + body,
            baseURL: baseURL,
            referenceToken: referenceToken,
            codeBlocks: codeBlocks,
            links: links
        )
        reloads = 0
        loadContent()
    }

    func close() {
        feedback?.cancel()
        feedback = nil
        onDecision = nil
        navigationDelegate = nil
        uiDelegate = nil
        stopLoading()
        content = nil
    }

    private func loadContent() {
        guard let content else { return }
        awaitsLoad = true
        // Nothing is ever fetched from the base; it only gives relative links a recognisable form.
        loadHTMLString(content.html, baseURL: content.baseURL)
    }

    // MARK: - Navigation

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if
            awaitsLoad,
            action.navigationType == .other,
            action.targetFrame?.isMainFrame == true,
            let content,
            action.request.url == content.baseURL
        {
            awaitsLoad = false
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if action.navigationType == .linkActivated, let url = action.request.url {
            activate(url)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // A document that keeps crashing WebKit is left blank rather than reloaded forever.
        guard reloads < Self.reloadLimit else { return }
        reloads += 1
        loadContent()
    }

    private func activate(_ url: URL) {
        guard let content else { return }
        if
            let index = MarkdownRenderer.copiedBlockIndex(from: url, referenceToken: content.referenceToken),
            content.codeBlocks.indices.contains(index)
        {
            copyText(content.codeBlocks[index])
            showCopied(url)
            return
        }
        // Every link in the page is a reference into the destinations the document wrote, so the
        // page itself names no server: WebKit starts connecting to a clicked link's host before
        // it asks whether to follow it. Anything else that was clicked is not one of ours.
        guard
            let index = MarkdownRenderer.linkedIndex(from: url, referenceToken: content.referenceToken),
            content.links.indices.contains(index),
            let authored = URL(string: content.links[index])
        else {
            onDecision?(.blocked)
            return
        }
        let decision = SafeMarkdownLinkPolicy.decision(for: authored, referenceToken: content.referenceToken)
        if decision == .external {
            openExternal(authored)
        }
        onDecision?(decision)
    }

    /// Marks the clicked Copy link done for a moment. Page script stays off; the app's own
    /// script runs in its own world and only touches the link's class.
    private func showCopied(_ url: URL) {
        feedback?.cancel()
        let mark = """
            for (const link of document.querySelectorAll('a.copy')) {
                link.classList.toggle('done', link.href === target);
            }
            """
        callAsyncJavaScript(
            mark,
            arguments: ["target": url.absoluteString],
            in: nil,
            in: .defaultClient,
            completionHandler: nil
        )
        feedback = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self else { return }
            self.callAsyncJavaScript(
                "for (const link of document.querySelectorAll('a.copy.done')) { link.classList.remove('done'); }",
                arguments: [:],
                in: nil,
                in: .defaultClient,
                completionHandler: nil
            )
        }
    }

    // MARK: - Context menu

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        Self.removeNavigatingItems(from: menu)
    }

    static func removeNavigatingItems(from menu: NSMenu) {
        for item in menu.items {
            if let identifier = item.identifier?.rawValue, navigatingMenuItems.contains(identifier) {
                menu.removeItem(item)
            }
        }
        // Removal can leave separators leading, trailing or doubled.
        var previousIsSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousIsSeparator {
                menu.removeItem(item)
            } else {
                previousIsSeparator = item.isSeparatorItem
            }
        }
        if let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
    }
}

private struct MarkdownLinkAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    /// Nil for an external link, which opens instead.
    static func explaining(_ decision: SafeMarkdownLinkPolicy.Decision) -> MarkdownLinkAlert? {
        switch decision {
        case .external:
            return nil
        case .wiki(let target):
            return .wiki(target)
        case .tag(let tag):
            return .tag(tag)
        case .footnote(let label):
            return .footnote(label)
        case .internalMarkdown(let target):
            return .internalMarkdown(target)
        case .blocked:
            return .blocked
        }
    }

    static func wiki(_ target: String) -> MarkdownLinkAlert {
        MarkdownLinkAlert(
            title: "Wiki Link Not Opened",
            message:
                "“\(target)” is shown as a link, but RelayBar does not resolve remote vault links or fetch linked files."
        )
    }

    static func footnote(_ label: String) -> MarkdownLinkAlert {
        MarkdownLinkAlert(
            title: "Footnote \(label)",
            message: "The footnote is listed at the end of this document."
        )
    }

    static func tag(_ tag: String) -> MarkdownLinkAlert {
        MarkdownLinkAlert(
            title: "Tag Not Opened",
            message:
                "“#\(tag)” is shown as a tag, but RelayBar does not index or search the remote vault."
        )
    }

    static func internalMarkdown(_ target: String) -> MarkdownLinkAlert {
        MarkdownLinkAlert(
            title: "Remote Link Not Opened",
            message:
                "“\(target)” refers to content in the remote vault. RelayBar shows the link but does not fetch or resolve remote files."
        )
    }

    static let blocked = MarkdownLinkAlert(
        title: "Link Not Opened",
        message: "RelayBar only opens absolute HTTP, HTTPS, and email links."
    )
}
