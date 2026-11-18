import BridgeProtocol
#if DEBUG
import FrameKit
import Foundation

/// Synthetic transport for the separate verification bundle. Never used in the shipping app.
enum VerificationLibrary {
  private struct Service: RemoteLibraryServing {
    func catalog() async throws -> BridgeResponse { VerificationLibrary.catalog() }
    func list(source: BridgeSource, path: String) async throws -> ScanResult { try await VerificationLibrary.load(source, path) }
    func handoff(_ nonce: UUID) async throws -> BridgeHandoff { throw BridgeError("Handoff is unavailable in the verification library.") }
    func rememberOpen(source: BridgeSource, path: String) async throws {}
  }
  /// A session that can list the bundled library and nothing else.
  @MainActor static var session: FixedRemoteSession { FixedRemoteSession(PartialRemoteSession(library: Service())) }
  static let bundleID = "com.lx2026.Frame.workspace-verification"
  static var source: BridgeSource {
    try! JSONDecoder().decode(BridgeSource.self, from: Data("{\"id\":\"\(String(repeating: "f", count: 64))\",\"name\":\"Studio\"}".utf8))
  }
  static func catalog() -> BridgeResponse {
    var response = BridgeResponse()
    response.locations = [try! JSONDecoder().decode(BridgeLocation.self,
      from: Data("{\"id\":\"fixture\",\"source\":{\"id\":\"\(source.id)\",\"name\":\"Studio\"},\"path\":\"/Photos\"}".utf8))]
    return response
  }
  static func load(_ source: BridgeSource, _ path: String) async throws -> ScanResult {
    try await Task.sleep(for: .milliseconds(350))
    guard source == self.source, let root = Bundle.main.resourceURL?.appendingPathComponent("VerificationLibrary") else {
      throw BridgeError("Verification fixture unavailable")
    }
    let id = RelayRemoteClient.rootID(source.id)
    if path == "/" {
      return ScanResult(photos: [], rootFolder: FolderNode(id: "/", name: "/", relativePath: "/", photoCount: 0,
        children: [FolderNode(id: "/Photos", name: "Photos", relativePath: "/Photos", photoCount: 0, children: [])]))
    }
    let result = try FileScanner.scan(rootURL: root, rootID: id)
    let localPath = path == "/Photos" ? "" : String(path.dropFirst("/Photos/".count))
    func find(_ node: FolderNode) -> FolderNode? {
      if node.relativePath == localPath { return node }
      return node.children.compactMap(find).first
    }
    guard let node = find(result.rootFolder) else { throw BridgeError("Folder unavailable") }
    func remoteItem(_ file: PhotoItem) -> PhotoItem {
      PhotoItem(id: "/Photos/" + file.relativePath, rootID: id, url: file.url,
        relativePath: "/Photos/" + file.relativePath, folderRelativePath: path, name: file.name, format: file.format,
        fileSize: file.fileSize, createdAt: file.createdAt, modifiedAt: file.modifiedAt, fileIdentifier: file.fileIdentifier,
        companions: file.companions)
    }
    let photos = result.photos.filter { $0.folderRelativePath == localPath }.map(remoteItem)
    let files = result.files.filter { $0.folderRelativePath == localPath }.map(remoteItem)
    let children = node.children.map { FolderNode(id: "/Photos/" + $0.relativePath, name: $0.name,
      relativePath: "/Photos/" + $0.relativePath, photoCount: 0, children: []) }
    return ScanResult(photos: photos, rootFolder: FolderNode(id: path, name: node.name, relativePath: path,
      photoCount: photos.count, children: children), files: files)
  }
}
#endif
