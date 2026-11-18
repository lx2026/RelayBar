import AssetGrouping
import Foundation

public struct AssetExportPlan: Sendable {
  let photo: PhotoItem
  let folder: URL
  let existing: [String: AssetFile]
  /// The file at each name the plan replaces, as the person confirmed it; only that file may be replaced.
  let identities: [String: FileIdentity]
  public var replacementNames: [String] { existing.keys.sorted() }
}

public enum AssetExporter {
  public static func plan(_ photo: PhotoItem, folder: URL) throws -> AssetExportPlan {
    let folder = folder.resolvingSymlinksInPath().standardizedFileURL
    guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw AssetError("Choose a destination folder.") }
    let names = Set(photo.exportMembers.map { $0.url.lastPathComponent })
    let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    guard children.count <= 20_000 else { throw AssetError("Choose a destination with fewer than 20,000 files.") }
    let media = Set(children.map(\.lastPathComponent).filter(AssetCompanionNames.isMedia)).union([photo.name])
    let candidates = Set(children.map(\.lastPathComponent)).union(names).subtracting(media)
    let grouped = Set(AssetCompanionNames.groups(media: Array(media), files: Array(candidates))[photo.name] ?? [])
    if let stale = grouped.subtracting(names).sorted().first {
      throw AssetError("\(stale) would attach old metadata to this export. Choose an empty folder or resolve that file first.")
    }
    guard Set(photo.companions.map { $0.url.lastPathComponent }).isSubset(of: grouped) else {
      throw AssetError("Companion filenames would belong to another image. Choose an empty destination folder.")
    }
    var existing: [String: AssetFile] = [:], identities: [String: FileIdentity] = [:]
    for member in photo.exportMembers {
      try member.validate()
      let destination = folder.appendingPathComponent(member.url.lastPathComponent)
      for source in photo.exportMembers {
        if source.url.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() { throw ExportError.sourceAndDestinationMatch }
        if let target = try? AssetFile.snapshot(destination, relativePath: destination.lastPathComponent),
           let identity = source.identifier, identity == target.identifier { throw ExportError.sourceAndDestinationMatch }
      }
      if AssetPaths.exists(destination) {
        existing[destination.lastPathComponent] = try AssetFile.snapshot(destination, relativePath: destination.lastPathComponent)
        guard let identity = try FileIdentity.at(destination) else { throw AssetError("Destination changed while it was checked. Choose Export again.") }
        identities[destination.lastPathComponent] = identity
      }
    }
    return AssetExportPlan(photo: photo, folder: folder, existing: existing, identities: identities)
  }

  /// `copy` publishes one member, replacing at most what its third argument allows, and returns the file it published.
  public static func export(_ plan: AssetExportPlan, copy: (URL, URL, ExactCopyExporter.Replacement) throws -> PublishedFile = {
    try ExactCopyExporter.export(source: $0, destination: $1, replacing: $2)
  }) throws {
    let fresh = try self.plan(plan.photo, folder: plan.folder)
    guard fresh.existing == plan.existing, fresh.identities == plan.identities else { throw AssetError("Destination changed after confirmation. Choose Export again.") }
    let fm = FileManager.default
    let stage = plan.folder.appendingPathComponent(".frame-export-\(UUID())")
    try fm.createDirectory(at: stage, withIntermediateDirectories: false)
    var committed: [PublishedFile] = []
    var retainRecovery = false
    defer { if !retainRecovery { try? fm.removeItem(at: stage) } }
    do {
      for (index, member) in plan.photo.exportMembers.enumerated() {
        try member.validate()
        try fm.copyItem(at: member.url, to: stage.appendingPathComponent("new-\(index)"))
        if let old = plan.existing[member.url.lastPathComponent] {
          try old.validate()
          try fm.copyItem(at: old.url, to: stage.appendingPathComponent("old-\(index)"))
        }
      }
      for (index, member) in plan.photo.exportMembers.enumerated() {
        let destination = plan.folder.appendingPathComponent(member.url.lastPathComponent)
        let old = plan.existing[member.url.lastPathComponent]
        if let old { try old.validate() }
        else if AssetPaths.exists(destination) { throw CocoaError(.fileWriteFileExists) }
        // A planned replace may replace only the file the plan confirmed, and a planned create nothing: a file saved
        // or put there during the copy is reported as a collision and the rollback below handles the rest.
        let replacing = plan.identities[member.url.lastPathComponent].map(ExactCopyExporter.Replacement.file) ?? .nothing
        committed.append(try copy(stage.appendingPathComponent("new-\(index)"), destination, replacing))
      }
    } catch {
      var left: [String] = []
      for (index, published) in committed.enumerated().reversed() {
        // Only a file this export published is taken back; one another writer has put at its name is left.
        if let path = ExactCopyExporter.remove(published) { left.append(path); retainRecovery = true; continue }
        let backup = stage.appendingPathComponent("old-\(index)")
        guard AssetPaths.exists(backup) else { continue }
        do { try ExactCopyExporter.export(source: backup, destination: published.url, replacing: .nothing) }
        catch { retainRecovery = true }
      }
      let others = left.isEmpty ? "" : " Left as it is, as another app replaced it or it could not be removed: " + left.joined(separator: ", ") + "."
      throw AssetError(error.localizedDescription + others
        + (retainRecovery ? " Recovery copies are retained at \(stage.path)." : " Previous destination files were preserved."))
    }
  }
}
