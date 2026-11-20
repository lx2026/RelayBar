import Foundation
import PreviewSupport

public enum PNGFixture: String, CaseIterable {
  case latin, compressed, international, internationalCompressed = "international-compressed", oversized

  public func data() throws -> Data {
    try Data(contentsOf: Bundle.module.url(forResource: rawValue, withExtension: "png", subdirectory: "PNG")!)
  }
  public var prompt: String? {
    switch self {
    case .latin, .compressed: "café"
    case .international, .internationalCompressed: "blue 海"
    case .oversized: nil
    }
  }
}

public enum BrowsingFixture: String, CaseIterable {
  case newestFirst, nameOrder, hidden, parameters, direct, workflow, camera

  public var expected: [String] {
    switch self {
    case .newestFirst: ["folder", "z", "2", "10"]
    case .nameOrder: ["folder", "2", "10", "z"]
    case .hidden: ["file", "2 hidden items", ".folder", "file", ".file"]
    case .parameters: ["Prompt=Clouds", "Negative prompt=Rain", "Steps=20", "Seed=42"]
    case .direct: ["Prompt=Sky", "Model=Example", "Seed=7", "CFG scale=6"]
    case .workflow: ["Source=ComfyUI"]
    case .camera: ["Camera=Example Camera", "Lens=Prime", "Focal length=50 mm", "Exposure=1/100 s", "Aperture=ƒ/4", "ISO=200"]
    }
  }
  public var observed: [String] {
    let fields: [String: String]
    var camera: [(String, String)] = []
    switch self {
    case .newestFirst, .nameOrder:
      let entries: [FolderListing.Entry] = [("10", false, 10), ("z", false, 20), ("folder", true, nil), ("2", false, 10)]
      return entries.sorted { FolderListing.precedes($0, $1, newestFirst: self == .newestFirst) }.map(\.name)
    case .hidden:
      let entries = [".folder", "file", ".file"]
      let split = FolderListing.split(entries, name: \.self)
      return split.shown + [FolderListing.hiddenLabel(split.hidden)] + FolderListing.split(entries, name: \.self, revealed: true).shown
    case .parameters: fields = ["parameters": "Clouds\nNegative prompt: Rain\nSteps: 20, Seed: 42"]
    case .direct: fields = ["description": "Sky", "checkpoint": "Example", "seed": "7", "guidance": "6"]
    case .workflow: fields = ["prompt": #"{"1":{"class_type":"Sampler"}}"#]
    case .camera:
      fields = [:]
      camera = [("Make", "Example"), ("Model", "Camera"), ("LensModel", "Prime"), ("FocalLength", "50"),
                ("ExposureTime", "0.01"), ("FNumber", "4"), ("ISOSpeedRatings", "200")]
    }
    return ImageDetails.interpret(pngText: fields, flattened: camera).ordered.map { $0.label + "=" + $0.value }
  }
}

public let connectionFixtures: [(cause: ConnectionFailure, diagnostic: String, title: String)] = [
  (.hostKeyChanged, "REMOTE HOST IDENTIFICATION HAS CHANGED!\nOffending key\nRemove the old key\nHost key verification failed", "The host key has changed."),
  (.hostKeyNotTrusted, "Host key verification failed", "The host key was not trusted."),
  (.signInRefused, "Permission denied (publickey)", "The server refused sign-in."),
  (.hostNotFound, "Could not resolve hostname example.invalid: host not found", "The host could not be found."),
  (.connectionRefused, "Connection refused", "The server refused the connection."),
  (.timedOut, "Operation timed out", "The connection timed out."),
  (.connectionLost, "Connection reset by peer", "The connection was lost.")
]
