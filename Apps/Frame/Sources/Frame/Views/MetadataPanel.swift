import AppKit
import FrameKit
import SwiftUI

/// The details beside an image or video: generation data, the sidecar files, then the kind and size.
/// It has no background or border of its own.
struct DetailsRail: View {
  let photo: PhotoItem
  @ObservedObject var store: LibraryStore
  @State private var fileExpanded = false
  @State private var embeddedExpanded = false
  private var sidecar: SidecarSummary { SidecarSummary(text: store.metadata.sidecarText) }
  private var hasEmbeddedGeneration: Bool {
    store.metadata.prompt != nil || store.metadata.negativePrompt != nil || !store.metadata.aiGeneration.isEmpty
  }
  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 0) {
        if photo.sidecar != nil, sidecar.hasGeneration {
          GenerationSection(title: hasEmbeddedGeneration ? "Generation · JSON" : "Generation", rows: sidecar.rows,
            prompt: sidecar.prompt, negativePrompt: sidecar.negativePrompt)
        }
        if hasEmbeddedGeneration {
          GenerationSection(title: sidecar.hasGeneration ? "Generation · Embedded" : "Generation", rows: store.metadata.aiGeneration,
            prompt: store.metadata.prompt, negativePrompt: store.metadata.negativePrompt)
        }
        if !store.metadata.capture.isEmpty {
          RailHeader(title: photo.format.isVideo ? "Video" : "Capture")
          ValueGrid(rows: store.metadata.capture)
        }
        let companions = store.companionItems(of: photo)
        if !companions.isEmpty {
          RailHeader(title: "Sidecar")
          VStack(spacing: 6) {
            ForEach(companions) { companion in
              SidecarRow(item: companion) { store.openCompanion(companion) }
            }
          }.padding(.bottom, 4)
        }
        summary
        if !otherIdentityRows.isEmpty {
          RailDisclosure(title: "File details", isExpanded: $fileExpanded) { ValueGrid(rows: otherIdentityRows) }
        }
        if !store.metadata.embedded.isEmpty {
          RailDisclosure(title: "All metadata (\(store.metadata.embedded.count))", isExpanded: $embeddedExpanded) {
            ValueGrid(rows: store.metadata.embedded)
          }
        }
      }
      .padding(.top, 10).padding(.bottom, 24)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlayScroller()
    }
    .scrollIndicators(.automatic)
    .id(photo.id)
  }

  /// The muted lines that close the rail: the kind with the pixel size, then when the file last changed.
  private var summary: some View {
    let dimensions = row("Dimensions")
    let changed = photo.modifiedAt.map(FrameFormat.relative.string(from:)) ?? row("Remote modified")
    return VStack(alignment: .leading, spacing: 0) {
      Text(photo.kindDescription + (dimensions.map { " · " + $0 } ?? ""))
      if let changed { Text(changed) }
    }
    .font(.system(size: 11.5)).lineSpacing(2).foregroundStyle(FramePalette.muted)
    .textSelection(.enabled)
    .padding(.top, 16)
    .help(photo.relativePath)
  }
  private func row(_ label: String) -> String? { store.metadata.identity.first { $0.label == label }?.value }
  /// Identity rows the summary does not already give.
  private var otherIdentityRows: [MetadataRow] {
    var rows = store.metadata.identity.filter { !["Type", "Dimensions", "Modified"].contains($0.label) }
    if !rows.contains(where: { $0.label == "Path" }) { rows.append(MetadataRow(label: "Path", value: photo.relativePath)) }
    return rows
  }
}

enum FrameFormat {
  /// "Today at 10:42", or a date for anything older than yesterday.
  static let relative: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    formatter.doesRelativeDateFormatting = true
    return formatter
  }()
}

private struct RailHeader<Accessory: View>: View {
  let title: String
  @ViewBuilder var accessory: () -> Accessory
  var body: some View {
    HStack {
      Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(FramePalette.muted)
      Spacer(minLength: 0)
      accessory()
    }
    .frame(height: 20).padding(.bottom, 6)
  }
}

extension RailHeader where Accessory == EmptyView {
  init(title: String) { self.init(title: title) { EmptyView() } }
}

private struct GenerationSection: View {
  let title: String
  let rows: [MetadataRow]
  var prompt: String?
  var negativePrompt: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      RailHeader(title: title) {
        Button(action: copySection) { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
          .buttonStyle(.plain).foregroundStyle(FramePalette.muted)
          .help("Copy generation metadata").accessibilityLabel("Copy \(title)")
      }
      if let prompt, !prompt.isEmpty { PromptBlock(label: "Prompt", value: prompt) }
      if let negativePrompt, !negativePrompt.isEmpty { PromptBlock(label: "Negative", value: negativePrompt) }
      ValueGrid(rows: rows)
    }
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
    VStack(alignment: .leading, spacing: 1) {
      Text(label).font(.system(size: 11)).foregroundStyle(FramePalette.muted)
      Text(value).font(.system(size: 12.5)).lineSpacing(2).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 8).padding(.horizontal, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(FramePalette.fill, in: RoundedRectangle(cornerRadius: FrameMetrics.radius, style: .continuous))
    .padding(.bottom, 6)
  }
}

/// Label and value pairs in two columns, the labels muted.
private struct ValueGrid: View {
  let rows: [MetadataRow]
  var body: some View {
    if !rows.isEmpty {
      Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 6) {
        ForEach(rows) { row in
          GridRow {
            Text(row.label).foregroundStyle(FramePalette.muted).frame(width: 74, alignment: .leading)
            Text(row.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .font(.system(size: 12.5))
      .padding(.horizontal, 2).padding(.top, 4).padding(.bottom, 12)
    }
  }
}

/// One sidecar file; choosing it opens the file in Files mode.
private struct SidecarRow: View {
  let item: PhotoItem
  let open: () -> Void
  @State private var hovered = false
  var body: some View {
    Button(action: open) {
      HStack(spacing: 8) {
        KindChip(text: item.kindChip)
        Text(item.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(FramePalette.muted)
      }
      .padding(.leading, 10).padding(.trailing, 8).frame(height: 32)
      .background(FramePalette.fill.opacity(hovered ? 1.6 : 1), in: RoundedRectangle(cornerRadius: FrameMetrics.radius, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .help("Open \(item.name)")
    .accessibilityLabel("Open sidecar \(item.name)")
  }
}

private struct RailDisclosure<Content: View>: View {
  let title: String
  @Binding var isExpanded: Bool
  @ViewBuilder var content: () -> Content
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button { isExpanded.toggle() } label: {
        HStack(spacing: 4) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
          Text(title).font(.system(size: 11, weight: .semibold))
        }.foregroundStyle(FramePalette.muted).contentShape(Rectangle())
      }.buttonStyle(.plain)
      if isExpanded { content() }
    }
    .padding(.top, 12)
  }
}
