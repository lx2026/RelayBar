import AppKit
import FrameKit
import SwiftUI

struct MetadataPanel: View {
  let photo: PhotoItem
  @ObservedObject var store: LibraryStore
  @State private var embeddedExpanded = false
  private var sidecar: SidecarSummary { SidecarSummary(text: store.metadata.sidecarText) }
  private var hasEmbeddedGeneration: Bool {
    store.metadata.prompt != nil || store.metadata.negativePrompt != nil || !store.metadata.aiGeneration.isEmpty
  }
  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        if photo.sidecar != nil, sidecar.hasGeneration {
          MetadataSectionView(title: hasEmbeddedGeneration ? "Generation · JSON" : "Generation", rows: sidecar.rows,
            prompt: sidecar.prompt, negativePrompt: sidecar.negativePrompt)
          Divider()
        }
        if hasEmbeddedGeneration {
          MetadataSectionView(title: sidecar.hasGeneration ? "Generation · Embedded" : "Generation", rows: store.metadata.aiGeneration,
            prompt: store.metadata.prompt, negativePrompt: store.metadata.negativePrompt)
          Divider()
        }
        MetadataSectionView(title: "File", rows: identityRows)
        if !store.metadata.capture.isEmpty {
          Divider()
          MetadataSectionView(title: photo.format.isVideo ? "Video" : "Capture", rows: store.metadata.capture)
        }
        ForEach(photo.companions, id: \.relativePath) { companion in
          Divider()
          SidecarSection(name: companion.url.lastPathComponent,
            text: store.metadata.companions.first { $0.name == companion.url.lastPathComponent }?.text)
            .id(companion.contentID)
        }
        if !store.metadata.embedded.isEmpty {
          Divider()
          DisclosureGroup("All metadata (\(store.metadata.embedded.count))", isExpanded: $embeddedExpanded) {
            MetadataSectionView(title: nil, rows: store.metadata.embedded)
          }.font(.system(size: 11)).padding(16)
        }
      }
    }.background(FramePalette.paper).id(photo.id)
  }
  private var identityRows: [MetadataRow] {
    var rows = store.metadata.identity
    if !rows.contains(where: { $0.label == "Path" }) {
      rows.append(MetadataRow(label: "Path", value: photo.relativePath))
    }
    return rows
  }
}

private struct SidecarSection: View {
  let name: String
  let text: String?
  @State private var expanded = false
  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      Text(text ?? "No text preview.").font(.system(size: 11, design: .monospaced))
        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
    } label: {
      Text(name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
    }.padding(20)
  }
}

private struct MetadataSectionView: View {
  let title: String?
  let rows: [MetadataRow]
  var prompt: String?
  var negativePrompt: String?

  init(
    title: String?,
    rows: [MetadataRow],
    prompt: String? = nil,
    negativePrompt: String? = nil
  ) {
    self.title = title
    self.rows = rows
    self.prompt = prompt
    self.negativePrompt = negativePrompt
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let title {
        HStack {
          Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(FramePalette.faint)
          Spacer()
          if title.hasPrefix("Generation") {
            Button(action: copySection) { Image(systemName: "doc.on.doc").font(.system(size: 9)) }
              .buttonStyle(.plain).foregroundStyle(FramePalette.faint).help("Copy generation metadata")
              .accessibilityLabel("Copy \(title)")
          }
        }
      }

      if let prompt, !prompt.isEmpty {
        PromptBlock(label: "Prompt", value: prompt)
      }
      if let negativePrompt, !negativePrompt.isEmpty {
        PromptBlock(label: "Negative", value: negativePrompt)
      }

      Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 7) {
        ForEach(rows) { row in
          GridRow {
            Text(row.label)
              .foregroundStyle(FramePalette.muted)
              .frame(width: 88, alignment: .leading)
            Text(row.value)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .font(.system(size: 12))
    }
    .padding(.horizontal, 20)
    .padding(.vertical, title == nil ? 4 : 15)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func copySection() {
    var parts: [String] = []
    if let prompt { parts.append("Prompt: \(prompt)") }
    if let negativePrompt { parts.append("Negative prompt: \(negativePrompt)") }
    parts.append(contentsOf: rows.map { "\($0.label): \($0.value)" })
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(parts.joined(separator: "\n"), forType: .string)
  }
}

private struct PromptBlock: View {
  let label: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(FramePalette.muted)
      Text(value)
        .font(.system(size: 12))
        .lineSpacing(2)
        .textSelection(.enabled)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(FramePalette.panel, in: RoundedRectangle(cornerRadius: 6))
  }
}
