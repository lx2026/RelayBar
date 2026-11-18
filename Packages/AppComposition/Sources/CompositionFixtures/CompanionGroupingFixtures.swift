/// Shared expectations for the grouping library, Frame scanner and RelayBar's fixed Python helper.
public struct CompanionGroupingFixture: Sendable {
    public let name: String
    public let files: [String]
    public let groups: [String: [String]]

    public static let all: [Self] = [
        .init(name: "documents-and-ranked-json",
              files: ["a.png", "a.png.json", "a.json", "a.prompt.json", "a.notes.txt", "a.md", "a.html", "independent.json", ".a.json"],
              groups: ["a.png": ["a.png.json", "a.json", "a.prompt.json", "a.notes.txt"]]),
        .init(name: "ambiguous-stems",
              files: ["a.png", "a.jpg", "a.json", "a.png.prompt.json", "a.jpg.txt", "a.md", "a.html"],
              groups: ["a.png": ["a.png.prompt.json"], "a.jpg": ["a.jpg.txt"]]),
        .init(name: "longest-prefix-and-folder-boundary",
              files: ["scene.png", "scene.detail.jpg", "scene.detail.prompt.json", "scene.detail.zz.txt", "scene.extra.bin", "folder/scene.png", "folder/scene.txt"],
              groups: ["scene.png": ["scene.extra.bin"], "scene.detail.jpg": ["scene.detail.prompt.json", "scene.detail.zz.txt"],
                       "folder/scene.png": ["folder/scene.txt"]]),
        .init(name: "uppercase-extensions",
              files: ["UPPER.MOV", "UPPER.MOV.JSON", "UPPER.json", "UPPER.data", "UPPER.md", "UPPER.htm"],
              groups: ["UPPER.MOV": ["UPPER.MOV.JSON", "UPPER.json", "UPPER.data"]]),
        .init(name: "exact-filename-beats-equal-stem",
              files: ["image.jpg", "image.png", "image.jpg.png", "image.jpg.json", "image.jpg.png.json", "image.jpg.note", "image.json"],
              groups: ["image.jpg": ["image.jpg.json", "image.jpg.note"], "image.jpg.png": ["image.jpg.png.json"]])
    ]
}
