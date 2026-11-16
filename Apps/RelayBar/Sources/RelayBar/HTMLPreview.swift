import BridgeProtocol
import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// One preview owns its resources. No folder history or persistent cache is involved.
actor RemoteHTMLResources {
    static let documentLimit = 10 * 1_024 * 1_024
    static let resourceLimit = 32 * 1_024 * 1_024
    private let service: RemoteFileServing
    private let server: RemoteServer
    let root: String
    private var cache: [String: Data] = [:]
    private var pending: [String: Task<Data, Error>] = [:]
    private var requested = Set<String>()
    private let slots = HTMLTransferSlots()
    private var closed = false
    private var retirement: Task<Void, Never>?

    init(service: RemoteFileServing, server: RemoteServer, root: String) {
        self.service = service; self.server = server; self.root = RemotePath.normalized(root)
    }

    static func normalized(_ path: String) throws -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { throw RemoteFileError.invalidPath }
                parts.removeLast()
            } else { parts.append(part) }
        }
        let value = parts.joined(separator: "/")
        guard !value.isEmpty, RemotePath.validationMessage(for: "/" + value) == nil else {
            throw RemoteFileError.invalidPath
        }
        return value
    }

    func entry(at path: String) async throws -> BridgeEntry {
        guard !closed else { throw CancellationError() }
        let relative = try Self.normalized(path)
        var input = BridgeAssetInput(action: "documentStat", root: root)
        let full = RemotePath.joining(root, relative)
        input.paths = [full]
        let result = try await service.frameAsset(server: server, input: input)
        guard !closed, !Task.isCancelled else { throw CancellationError() }
        if let error = result.error { throw BridgeError(error) }
        guard let entry = result.entries?.first(where: { $0.path == full && !$0.directory }) else {
            throw BridgeError("File unavailable.")
        }
        return entry
    }

    func data(at path: String, limit: Int = resourceLimit) async throws -> Data {
        let path = try Self.normalized(path)
        guard !closed else { throw CancellationError() }
        if let data = cache[path] {
            guard data.count <= limit else { throw RemoteFileError.previewTooLarge }
            return data
        }
        if let task = pending[path] {
            let data = try await task.value
            guard data.count <= limit else { throw RemoteFileError.previewTooLarge }
            return data
        }
        guard requested.contains(path) || requested.count < 128 else {
            throw BridgeError("Too many page resources.")
        }
        requested.insert(path)
        let task = Task { [service, server, slots] in
            await slots.acquire()
            do {
                try Task.checkCancellation()
                let before = try await self.entry(at: path)
                guard before.size <= limit else { throw RemoteFileError.previewTooLarge }
                let entry = RemoteFileEntry(name: before.name, path: before.path, kind: .file,
                    size: before.size, modificationText: before.modified)
                let url = try await service.prepareDocumentResource(server: server, entry: entry)
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                try Task.checkCancellation()
                let worker = Task.detached {
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    return try file.read(upToCount: limit + 1) ?? Data()
                }
                let bytes = try await worker.value
                guard bytes.count <= limit else { throw RemoteFileError.previewTooLarge }
                let after = try await self.entry(at: path)
                guard before.fingerprint == after.fingerprint else { throw BridgeError("File changed. Retry.") }
                await slots.release()
                return bytes
            } catch {
                await slots.release()
                throw error
            }
        }
        pending[path] = task
        defer { pending.removeValue(forKey: path) }
        let bytes = try await task.value
        guard !closed else { throw CancellationError() }
        guard cache.values.reduce(0, { $0 + $1.count }) + bytes.count <= 64 * 1_024 * 1_024 else {
            throw BridgeError("Page resources exceed 64 MiB.")
        }
        cache[path] = bytes
        return bytes
    }

    func close() async {
        if let retirement { await retirement.value; return }
        closed = true
        let work = Array(pending.values)
        for task in work { task.cancel() }
        pending.removeAll(); cache.removeAll()
        let task = Task { for task in work { _ = try? await task.value } }
        retirement = task
        await task.value
    }
}

private actor HTMLTransferSlots {
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if active < 4 { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().resume() }
    }
}

@MainActor final class RemoteHTMLRenderer: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var error: String?
    let webView: WKWebView
    let resources: RemoteHTMLResources
    var onNavigate: ((String) -> Void)?
    private let handler: HTMLResourceHandler
    private let host = UUID().uuidString.lowercased()
    private let path: String
    private var retirement: Task<Void, Never>?

    init(resources: RemoteHTMLResources, path: String, documentLimit: Int = RemoteHTMLResources.documentLimit) {
        self.resources = resources; self.path = path
        handler = HTMLResourceHandler(resources: resources, documentLimit: documentLimit)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.setURLSchemeHandler(handler, forURLScheme: "relaybar-document")
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        handler.host = host
        handler.onError = { [weak self] in self?.error = "Some page resources could not be loaded." }
        webView.navigationDelegate = self; webView.uiDelegate = self
        var url = URLComponents(); url.scheme = "relaybar-document"; url.host = host; url.path = "/" + path
        webView.load(URLRequest(url: url.url!))
    }

    func stop() {
        guard retirement == nil else { return }
        onNavigate = nil; webView.navigationDelegate = nil
        let work = handler.stop()
        webView.stopLoading()
        retirement = Task { [resources] in
            await resources.close()
            for task in work { await task.value }
        }
    }

    func close() async { stop(); await retirement?.value }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, action.navigationType != .backForward,
              action.targetFrame?.isMainFrame == true else { decisionHandler(.cancel); return }
        if url.scheme == "relaybar-document", url.host == host {
            let target = String(url.path.dropFirst())
            if target == path { decisionHandler(.allow); return }
            if action.navigationType == .linkActivated { onNavigate?(target) }
        } else if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { error = "Preview stopped." }
}

@MainActor private final class HTMLResourceHandler: NSObject, WKURLSchemeHandler {
    let resources: RemoteHTMLResources
    var host = ""
    var onError: (() -> Void)?
    private let documentLimit: Int
    private var active = true
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(resources: RemoteHTMLResources, documentLimit: Int) { self.resources = resources; self.documentLimit = documentLimit }

    func webView(_ webView: WKWebView, start schemeTask: WKURLSchemeTask) {
        guard active, let url = schemeTask.request.url, url.host == host,
              schemeTask.request.httpMethod == nil || schemeTask.request.httpMethod == "GET" else {
            schemeTask.didFailWithError(RemoteFileError.invalidPath); return
        }
        let key = ObjectIdentifier(schemeTask)
        tasks[key] = Task { [weak self, resources, documentLimit] in
            do {
                let path = try RemoteHTMLResources.normalized(url.path)
                let html = ["html", "htm"].contains((path as NSString).pathExtension.lowercased())
                let data = try await resources.data(at: path, limit: html ? documentLimit : RemoteHTMLResources.resourceLimit)
                guard !Task.isCancelled, let self, tasks[key] != nil else { return }
                let policy = "default-src 'none'; script-src relaybar-document: http: https: 'unsafe-inline' 'unsafe-eval'; style-src relaybar-document: http: https: 'unsafe-inline'; img-src relaybar-document: http: https: data: blob:; font-src relaybar-document: http: https: data:; media-src relaybar-document: http: https: blob:; connect-src relaybar-document: http: https: ws: wss:; frame-src 'none'; object-src 'none'; worker-src blob:; base-uri 'none'; form-action 'none'"
                let mime = html ? "text/html" : UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": mime, "Content-Security-Policy": policy, "Cache-Control": "no-store",
                    "Access-Control-Allow-Origin": "*", "X-Content-Type-Options": "nosniff"
                ])!
                let bytes = html ? Data(("<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"" + policy + "\">").utf8) + data : data
                schemeTask.didReceive(response); schemeTask.didReceive(bytes); schemeTask.didFinish()
                tasks.removeValue(forKey: key)
            } catch {
                guard !Task.isCancelled, let self, tasks[key] != nil else { return }
                onError?(); schemeTask.didFailWithError(error); tasks.removeValue(forKey: key)
            }
        }
    }
    func webView(_ webView: WKWebView, stop schemeTask: WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(schemeTask))?.cancel()
    }
    func stop() -> [Task<Void, Never>] {
        active = false
        let work = Array(tasks.values)
        for task in work { task.cancel() }; tasks.removeAll()
        return work
    }
}

enum RemoteHTMLFocus {
    /// A page that runs script keeps the keys it is given. The Markdown preview runs none,
    /// so the window's own shortcuts keep working while it has the focus.
    @MainActor static func ownsKeys(_ responder: NSResponder?) -> Bool {
        var view = responder as? NSView
        while let current = view {
            if current is RemoteMarkdownWebView { return false }
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }
}

struct RemoteHTMLView: View {
    @ObservedObject var renderer: RemoteHTMLRenderer
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            if let error = renderer.error {
                HStack { Text(error).font(.caption); Spacer(); Button("Retry", action: retry) }
                    .padding(10)
            }
            RemoteHTMLWebView(renderer: renderer)
        }
    }
}

private struct RemoteHTMLWebView: NSViewRepresentable {
    let renderer: RemoteHTMLRenderer
    func makeNSView(context: Context) -> WKWebView { renderer.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
