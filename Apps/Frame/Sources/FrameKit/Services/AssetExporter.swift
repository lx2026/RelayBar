import AssetGrouping
import Foundation

public struct AssetExportPlan: Sendable {
  let photo: PhotoItem
  let folder: URL
  let existing: [String: AssetFile]
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
    var existing: [String: AssetFile] = [:]
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
      }
    }
    return AssetExportPlan(photo: photo, folder: folder, existing: existing)
  }

  public static func export(_ plan: AssetExportPlan,
    copy: (URL, URL) throws -> Void = { try ExactCopyExporter.export(source: $0, destination: $1) }) throws {
    let fresh = try self.plan(plan.photo, folder: plan.folder)
    guard fresh.existing == plan.existing else { throw AssetError("Destination changed after confirmation. Choose Export again.") }
    let fm = FileManager.default
    let stage = plan.folder.appendingPathComponent(".frame-export-\(UUID())")
    try fm.createDirectory(at: stage, withIntermediateDirectories: false)
    var committed: [AssetFile] = []
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
        if let old = plan.existing[member.url.lastPathComponent] { try old.validate() }
        else if AssetPaths.exists(destination) { throw CocoaError(.fileWriteFileExists) }
        try copy(stage.appendingPathComponent("new-\(index)"), destination)
        // Preserve recovery data if even this post-write snapshot cannot be obtained.
        retainRecovery = true
        committed.append(try AssetFile.snapshot(destination, relativePath: member.url.lastPathComponent))
        retainRecovery = false
      }
    } catch {
      for (index, destination) in committed.enumerated().reversed() {
        do {
          try destination.validate()
          let backup = stage.appendingPathComponent("old-\(index)")
          if AssetPaths.exists(backup) { try ExactCopyExporter.export(source: backup, destination: destination.url) }
          else { try fm.removeItem(at: destination.url) }
        } catch { retainRecovery = true }
      }
      throw AssetError(error.localizedDescription + (retainRecovery ? " Recovery copies are retained at \(stage.path)." : " Previous destination files were preserved."))
    }
  }
}
