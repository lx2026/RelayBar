import Combine
import Composition
import Foundation
import PreviewSupport

struct FramePreferenceValues: Codable, Equatable, Sendable {
    var showsMediaInfo = true
    var showsRemoteFolders = true
    var localIncludesSubfolders = true
    var thumbnailWidth = ContactSheetMetrics.defaultThumbnailWidth
    var layouts: [String: FrameViewMode] = [:]

    func validate() throws {
        guard thumbnailWidth.isFinite, thumbnailWidth == ContactSheetMetrics.normalizedWidth(thumbnailWidth),
              layouts.keys.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw CompositionError("Invalid display preferences.")
        }
    }

    func layout(for root: UUID) -> FrameViewMode { layouts[root.uuidString] ?? .inspect }
}

/// Everything Frame stores about the user's choices. Catalog records, bookmarks, favourites and
/// RelayBar's access grants stay in their own stores.
struct FramePreferenceDocument: Codable, Equatable {
    struct Preview: Codable, Equatable {
        var enabled = true
        var maximumBytes: Int64
    }

    var display = FramePreferenceValues()
    /// Only formats the user changed are stored; every other format uses its default.
    var previews: [String: Preview] = [:]
    /// Folders known before layouts were remembered open in the contact sheet. Applied once, when the catalog first opens.
    var importedDocumentLayouts = false
    /// Only plugins the user switched away from their default are stored.
    var plugins = PluginChoices()

    @MainActor
    func preview(_ kind: String) -> Preview {
        previews[kind] ?? Preview(maximumBytes: FrameComposition.descriptors.first { $0.id == kind }?.maximumBytes ?? 0)
    }

    /// The descriptor a format runs with: its fixed extensions and the chosen limit.
    @MainActor
    func descriptor(_ base: PreviewDescriptor) -> PreviewDescriptor {
        PreviewDescriptor(id: base.id, title: base.title, extensions: base.extensions, maximumBytes: preview(base.id).maximumBytes)
    }

    @MainActor
    func validate() throws {
        try display.validate()
        for (kind, preview) in previews {
            guard let base = FrameComposition.descriptors.first(where: { $0.id == kind }),
                  preview.maximumBytes > 0, preview.maximumBytes <= base.maximumBytes else {
                throw CompositionError("Invalid preview size limit.")
            }
        }
    }
}

extension FramePreferenceDocument {
    /// Reads every key as before. A document written before plugins existed has no `plugins` key and gets the defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        display = try container.decode(FramePreferenceValues.self, forKey: .display)
        previews = try container.decode([String: Preview].self, forKey: .previews)
        importedDocumentLayouts = try container.decode(Bool.self, forKey: .importedDocumentLayouts)
        plugins = try container.decodeIfPresent(PluginChoices.self, forKey: .plugins) ?? PluginChoices()
    }
}

/// The preference document plus the legacy UserDefaults values it is first created from.
@MainActor
final class FramePreferences {
    let store: PreferenceStore<FramePreferenceDocument>
    private var legacyDefaults = UserDefaults.standard

    init(url: URL?) {
        store = PreferenceStore(url: url, initial: FramePreferenceDocument()) { try $0.validate() }
    }

    /// Names the defaults domain holding pre-document preferences. Ignored once the document exists.
    func configure(defaults: UserDefaults) {
        guard !store.isLoaded else { return }
        legacyDefaults = defaults
    }

    /// The display preferences; before the document is loaded, what the legacy defaults say.
    var value: FramePreferenceValues { store.isLoaded ? store.value.display : legacyValues() }

    /// Display preferences each time the document is loaded or saved; nothing before it has loaded.
    var values: AnyPublisher<FramePreferenceValues, Never> {
        store.$value.dropFirst().map(\.display).removeDuplicates().eraseToAnyPublisher()
    }

    func load() throws {
        try store.load(importing: { [self] in FramePreferenceDocument(display: legacyValues()) })
    }

    private func legacyValues() -> FramePreferenceValues {
        var value = FramePreferenceValues()
        value.showsMediaInfo = legacyDefaults.object(forKey: "showsMediaInfo") as? Bool ?? true
        value.showsRemoteFolders = legacyDefaults.object(forKey: "showsRemoteFolders") as? Bool ?? true
        value.localIncludesSubfolders = legacyDefaults.object(forKey: "localIncludesSubfolders") as? Bool ?? true
        value.thumbnailWidth = ContactSheetMetrics.normalizedWidth(
            legacyDefaults.object(forKey: "contactSheetThumbnailWidth") as? Double ?? ContactSheetMetrics.defaultThumbnailWidth)
        for (key, raw) in legacyDefaults.dictionaryRepresentation() where key.hasPrefix("layout.") {
            guard let id = UUID(uuidString: String(key.dropFirst("layout.".count))),
                  let raw = raw as? String, let layout = FrameViewMode(rawValue: raw) else { continue }
            value.layouts[id.uuidString] = layout
        }
        return value
    }

    /// Runs once, when the catalog is first available: every folder that existed before layouts were
    /// remembered, including those outside the recent menu, keeps opening in the contact sheet.
    func importDocumentLayouts(roots: [UUID]) throws {
        guard store.isLoaded, !store.value.importedDocumentLayouts else { return }
        let alreadyMigrated = legacyDefaults.bool(forKey: "documentLayoutMigrated")
        try store.update { document in
            if !alreadyMigrated {
                for root in roots where document.display.layouts[root.uuidString] == nil {
                    document.display.layouts[root.uuidString] = .contactSheet
                }
            }
            document.importedDocumentLayouts = true
        }
    }
}
