import PreviewSupport
import Composition
import HouseStyle
import ImageIO
import MobileCore
import SwiftUI
import UniformTypeIdentifiers

private struct OriginalFile: Transferable {
  let url: URL
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .data) { SentTransferredFile($0.url) }
  }
}

struct OutlineHeading {
  let text: String
  let level: Int
}

private struct ReaderUpdate: Equatable {
  var generation: Int
  var choices: PluginChoices
  var local: PluginChoices?
}

struct ReaderScreen: View {
  let path: String
  let profile: Profile
  let core: MobileComposition
  @ObservedObject var profiles: PreferenceStore<Preferences>
  @ObservedObject var reader: ServicePort<Reader>
  @ObservedObject var scriptPort: ServicePort<Bool>
  @ObservedObject var files: ServicePort<any RemoteFiles>
  @Environment(\.galleryRows) var facts
  @State private var siblings: [String] = []
  @State private var position: String?
  @Environment(\.padReader) private var pad
  @Environment(\.readerControls) private var controls
  @Environment(\.readerFocused) var focused
  @Environment(\.renderingGallery) var snapshot
  @Environment(\.splitReader) private var split
  var openFolder: (String) -> Void = { _ in }
  var orderedPaths: [String] = []
  @State private var currentHeading: Int?
  @State private var progress = 0.0
  @State private var width: CGFloat = 0
  var galleryOutline = false
  var galleryHeadings: [String] = []
  var galleryInternet: Bool?
  @State private var preview: HTMLPreview?
  @State private var local: URL?
  @State private var playbackURL: URL?
  @State private var exporting = false
  @State private var preparing: Task<Void, Never>?
  @State private var sharing = false
  var galleryImage: CGImage? = nil
  @State var document: ReadDocument?
  @State private var source = false
  @State private var outline = false
  @State private var headings: [OutlineHeading] = []
  @State private var jump: Int?
  @State private var error = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let doc = document {
        Group {
          HStack {
            if let inset = controls?.leadingInset, inset > 0 {
              Color.clear.frame(width: inset - 8, height: 1)
            }
            if let controls {
              let parent = (path as NSString).deletingLastPathComponent
              let paths = orderedPaths.contains(path) ? orderedPaths : siblings
              if !split && (width >= 820 || width == 0) {
                Button {
                  openFolder(parent)
                } label: {
                  Label((parent as NSString).lastPathComponent, systemImage: "chevron.left")
                    .lineLimit(1)
                }.accessibilityLabel("Back to " + parent)
                if let i = paths.firstIndex(of: path) {
                  IconButton(label: "Previous file", symbol: "chevron.up", circle: false) {
                    controls.open(paths[i - 1])
                  }.disabled(i == 0)
                  Text("\(i + 1) of \(paths.count)").secondaryText().fixedSize()
                  IconButton(label: "Next file", symbol: "chevron.down", circle: false) {
                    controls.open(paths[i + 1])
                  }.disabled(i + 1 == paths.count)
                }
              } else {
                Menu {
                  Button("Back to " + (parent as NSString).lastPathComponent) { openFolder(parent) }
                  if let i = paths.firstIndex(of: path) {
                    Text("\(i + 1) of \(paths.count)")
                    Button("Previous file") { controls.open(paths[i - 1]) }.disabled(i == 0)
                    Button("Next file") { controls.open(paths[i + 1]) }.disabled(
                      i + 1 == paths.count)
                  }
                } label: {
                  Glyph("chevron.left").frame(width: 32, height: 44)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(
                  "Folder navigation")
              }
            }
            if pad {
              VStack(alignment: .leading) {
                Text(doc.title).mobileFont(16, .semibold).lineLimit(1)
                Text(
                  doc.isImage
                    ? (facts[path]?.position ?? position ?? "")
                    : (path as NSString).lastPathComponent
                ).secondaryText().lineLimit(1)
              }
            } else {
              Button {
                openFolder((path as NSString).deletingLastPathComponent)
              } label: {
                Text(
                  doc.isImage
                    ? imageCaption(path, position: facts[path]?.position ?? position)
                    : displayPath(
                      (path as NSString).deletingLastPathComponent,
                      home: profiles.value.homeFolders?[profile.id])
                ).secondaryText().lineLimit(1).frame(minHeight: 44)
              }.accessibilityLabel("Open folder " + (path as NSString).deletingLastPathComponent)
            }
            Spacer()
            if doc.isImage {
              if let actions = core.runtime.service(FileActions.self, realm: profile.realm) {
                Entries(registry: actions) { entries in
                  if let favourite = entries.first(where: { $0.id == "favourite" }) {
                    let saved = profiles.value.places(for: profile.id).contains { $0.path == path }
                    IconButton(
                      label: saved ? "Unpin" : "Pin",
                      symbol: saved ? "pin.fill" : "pin", circle: false
                    ) {
                      do { try favourite.perform(path) {} } catch {
                        self.error = error.localizedDescription
                      }
                    }.card(22)
                  }
                }
              }
            } else if doc.html != nil {
              if pad && !split && width >= 700 {
                HStack(spacing: 0) {
                  ForEach([false, true], id: \.self) { value in
                    Button {
                      source = value
                    } label: {
                      Text(value ? "Source" : "Rendered").mobileFont(13, .semibold)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(
                          value == source ? HouseColor.card : Color.clear,
                          in: RoundedRectangle(cornerRadius: 7))
                    }.accessibilityAddTraits(value == source ? .isSelected : [])
                  }
                }.padding(2).background(HouseColor.fill, in: RoundedRectangle(cornerRadius: 9))
              } else if !split {
                HStack(spacing: 0) {
                  if !pad && !doc.isHTML {
                    Button {
                      outline = true
                    } label: {
                      Glyph("list.bullet").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("On this page")
                  }
                  Button {
                    source.toggle()
                  } label: {
                    Glyph(
                      source ? "doc.richtext" : "chevron.left.forwardslash.chevron.right"
                    ).frame(width: 44, height: 44)
                  }.accessibilityLabel(source ? "Show rendered" : "Show source")
                }.buttonStyle(.plain).card(22)
              }
            }
            if pad, width < 1000 || focused, doc.html != nil, !doc.isHTML, !source {
              IconButton(label: "On this page", symbol: "list.bullet", circle: false) {
                outline.toggle()
              }
              .popover(isPresented: $outline) {
                outlineView(doc).frame(width: 310, height: 620).presentationCompactAdaptation(
                  .popover)
              }
            }
            if let controls, !split {
              IconButton(
                label: "Open beside reader", symbol: "rectangle.split.2x1", circle: false,
                action: controls.split)
            }
            #if os(iOS)
              Menu {
                Button("Share file") { prepare(doc, share: true) }
                Button("Save to Files") { prepare(doc, share: false) }
              } label: {
                Glyph("square.and.arrow.up").frame(width: 44, height: 44)
              }
              .accessibilityLabel("Share or save").disabled(preparing != nil)
            #else
              Glyph("square.and.arrow.up").frame(width: 44, height: 44)
            #endif
            if let controls, !split {
              IconButton(
                label: focused ? "Leave Focus" : "Focus",
                symbol: "arrow.up.left.and.arrow.down.right", circle: false, action: controls.focus)
            }
          }.padding(.leading, pad ? 12 : 22).padding(.trailing, 14)
        }
        if pad { Hairline() }
        if doc.changed {
          Text("Changed since you read it").secondaryText().padding(.horizontal, 20)
        }
        if doc.isHTML && !source {
          let allowed =
            galleryInternet ?? profiles.value.hosts.first { $0.id == profile.id }?
            .allowsInternetResources ?? false
          let scripts = scriptPort.value == true
          Button(
            allowed
              ? "Internet resources allowed · Turn off" : "Allow internet resources for this host"
          ) {
            do {
              try profiles.update { value in
                if let i = value.hosts.firstIndex(where: { $0.id == profile.id }) {
                  value.hosts[i].allowsInternetResources = !allowed
                }
              }
            } catch { self.error = error.localizedDescription }
          }.secondaryText().padding(10)
          if let galleryImage {
            Image(decorative: galleryImage, scale: 1).resizable()
          } else {
            ZStack {
              if let preview {
                ServiceWebView(web: preview.web).id(ObjectIdentifier(preview))
              } else {
                ProgressView()
              }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
              .task(id: [allowed, scripts, files.value != nil]) {
                preview?.web.stopLoading()
                preview = nil
                do {
                  let page = try await HTMLPreview(
                    path: path, html: doc.source, files: files.value, scripts: scripts,
                    internet: allowed, host: profile.host)
                  try await page.load()
                  try Task.checkCancellation()
                  preview = page
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
              }
          }
        } else if doc.isVideo {
          #if os(iOS)
            if let files = files.value,
              let media = try? MediaSource(path: path, stamp: doc.file.stamp, files: files)
            {
              VideoReader(loader: VideoLoader(media), local: playbackURL) {
                prepare(doc, share: nil)
              }
            } else {
              Text("Waiting for video…")
            }
          #endif
        } else if doc.isImage {
          ImagePage(doc: doc, image: galleryImage)
        } else if let html = doc.html, !source {
          GeometryReader { geo in
            HStack(alignment: .top, spacing: 0) {
              #if os(iOS)
                MarkdownView(
                  html: html, id: doc.id, path: path, files: files.value, position: doc.position,
                  token: doc.token, blocks: doc.codeBlocks,
                  headings: $headings, jump: $jump,
                  track: {
                    currentHeading = $0
                    progress = $1
                  }, save: save)
              #else
                if let galleryImage {
                  Image(decorative: galleryImage, scale: 1).resizable().frame(
                    maxWidth: .infinity, maxHeight: .infinity)
                }
              #endif
              if pad, !focused, geo.size.width >= 1000, !entries.isEmpty, !galleryOutline {
                Divider()
                outlineView(doc).frame(width: 288)
              }
            }.overlay(alignment: .topTrailing) {
              if pad && galleryOutline {
                outlineView(doc).frame(width: 310, height: 620).background(
                  HouseColor.card, in: RoundedRectangle(cornerRadius: 14)
                ).shadow(radius: 6).padding(12)
              }
            }
          }
        } else {
          #if os(iOS)
            let form: HouseForm = profiles.value.enabled(PaperAppearance.plugin, host: profile.id)
              ? .paper : .standard
            let html = plainTextPage(doc.source, form: form)
            MarkdownView(
              html: html, id: doc.id, path: path, files: nil, position: doc.position,
              token: "", blocks: [], headings: .constant([]), jump: .constant(nil)
            ) { position, excerpt in
              if doc.html == nil { save(position, excerpt) }
            }
          #else
            Text(doc.source).font(.body.monospaced())
          #endif
        }
        if files.value == nil {
          Text("Saved copy from \(doc.file.date.formatted(.relative(presentation: .named)))")
            .secondaryText().padding(.horizontal, 12).padding(.vertical, 6).card(15).frame(
              maxWidth: .infinity)
        }
      } else if error.isEmpty {
        Text("Opening document…").secondaryText().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if !error.isEmpty { Text(error).padding(20) }
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(
      HouseColor.paper
    )
    .task(
      id: ReaderUpdate(
        generation: reader.generation, choices: profiles.value.plugins,
        local: profiles.value.hostPlugins?[profile.id])
    ) {
      do {
        if snapshot { return }
        if let live = reader.value {
          let result = try await live.open(path)
          try Task.checkCancellation()
          if document?.file.stamp != result.file.stamp
            || (document?.html == nil) != (result.html == nil)
          {
            document = result
          }
          error = ""
        } else if document == nil {
          let saved = try await core.savedDocument(path, profile: profile)
          try Task.checkCancellation()
          document = saved
          if saved == nil { error = "Waiting for the host…" }
        }
      } catch {
        if !Task.isCancelled {
          document = nil
          self.error = error.localizedDescription
        }
      }
    }
    .task(id: files.generation) {
      guard let service = files.value else { return }
      if let rows = try? await service.list((path as NSString).deletingLastPathComponent) {
        let extended = profiles.value.enabled(PreviewPlugins.moreImages, host: profile.id)
        let order = profiles.value.folderOrder?[profile.id] ?? .modified
        position = imagePosition(path, rows: rows, extended: extended, order: order)
        let parent = (path as NSString).deletingLastPathComponent as NSString
        siblings = sortedFolderFiles(groupedRows(rows, extendedImages: extended), order: order)
        .filter { !$0.stamp.directory && !$0.name.hasPrefix(".") }.map {
          parent.appendingPathComponent($0.name)
        }
      }
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        if let stamp = try? await service.stat(path), !Task.isCancelled, let doc = document,
          stamp != doc.file.stamp
        {
          document?.changed = true
        }
      }
    }
    #if os(iOS)
      .fileExporter(
        isPresented: $exporting, item: local.map(OriginalFile.init), contentTypes: [.data],
        defaultFilename: (path as NSString).lastPathComponent
      ) { result in
        if case .failure(let error) = result { self.error = error.localizedDescription }
      }
      .sheet(isPresented: $sharing) { if let local { ActivitySheet(file: local) } }
      .onDisappear {
        preparing?.cancel()
        if let local { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
      }
    #endif
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
    .bottomPanel(shown: !pad && (outline || galleryOutline), fraction: 0.68) {
      if let doc = document { outlineView(doc) }
    }
  }
  private var entries: [OutlineHeading] {
    galleryHeadings.isEmpty
      ? headings
      : galleryHeadings.map { text in
        let level = text.prefix { $0 == "#" }.count
        return OutlineHeading(
          text: String(text.dropFirst(level)).trimmingCharacters(in: .whitespaces),
          level: max(1, level))
      }
  }
  private func outlineView(_ doc: ReadDocument) -> some View {
    let entries = self.entries
    let selected = currentHeading ?? entries.firstIndex { $0.text == doc.position.heading } ?? 0
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("On this page").mobileFont(pad ? 14 : 20, .semibold)
        Spacer()
        Text(
          "\(max(0, Int(ceil(Double(doc.wordCount) * (1 - min(1, max(0, progress))) / 220)))) min left"
        ).secondaryText()
        if !pad { Button("Done") { outline = false } }
      }.padding(.horizontal, 12)
      Hairline()
      ScrollViewReader { proxy in
        PageScroll {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(entries.indices, id: \.self) { i in
              let entry = entries[i]
              let active = i == selected
              Button {
                source = false
                jump = i
                outline = false
              } label: {
                Text(entry.text).mobileFont(15, active ? .semibold : .regular)
                  .multilineTextAlignment(
                    .leading
                  )
                  .fixedSize(horizontal: false, vertical: true).padding(
                    .leading, CGFloat(max(0, entry.level - 1)) * 12 + 10
                  )
                  .padding(.trailing, 8).padding(.vertical, 7).frame(
                    maxWidth: .infinity, minHeight: 40, alignment: .leading
                  )
                  .background(
                    active ? HouseColor.fill : Color.clear, in: RoundedRectangle(cornerRadius: 8))
              }.accessibilityAddTraits(active ? .isSelected : []).id(i)
            }
          }
        }
        .onChange(of: selected) {
          if pad && width >= 1000 && !focused { proxy.scrollTo(selected, anchor: .center) }
        }
      }
    }.padding(12)
  }

  #if os(iOS)
    func prepare(_ doc: ReadDocument, share: Bool?) {
      guard preparing == nil else { return }
      preparing = Task {
        defer { preparing = nil }
        do {
          if local == nil {
            let result: URL
            if doc.isVideo {
              guard let files = files.value else { throw URLError(.notConnectedToInternet) }
              let source = try MediaSource(path: path, stamp: doc.file.stamp, files: files)
              result = try await DownloadTracker.shared.download(
                source, core: core, profile: profile.id)
            } else {
              let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
              try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: false)
              result = folder.appending(path: (path as NSString).lastPathComponent)
              try doc.file.data.write(to: result, options: .atomic)
            }
            local = result
          }
          if let share {
            if share { sharing = true } else { exporting = true }
          } else {
            playbackURL = local
          }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
      }
    }
  #endif
  func save(_ position: ReadingPosition, _ excerpt: String?) {
    guard
      let index = profiles.value.history.firstIndex(where: {
        $0.profile == profile.id && $0.path == path
      })
    else { return }
    do {
      if let live = reader.value {
        try live.save(position: position, path: path, excerpt: excerpt)
      } else {
        try profiles.update { value in
          value.history[index].position = position
          if let excerpt { value.history[index].excerpt = excerpt }
        }
      }
      document?.position = position
    } catch { self.error = error.localizedDescription }
  }
}

struct ImagePage: View {
  let doc: ReadDocument
  @State var image: CGImage?
  @Environment(\.padReader) private var pad
  var body: some View {
    VStack(spacing: 0) {
      if let image {
        Image(decorative: image, scale: 1).resizable().scaledToFit().padding(20).frame(
          maxWidth: .infinity, maxHeight: .infinity
        )
        .accessibilityLabel(doc.title)
      }
      PageScroll {
        VStack(alignment: .leading, spacing: 8) {
          if !pad {
            Capsule().fill(HouseColor.fill).frame(width: 36, height: 5).frame(maxWidth: .infinity)
          }
          if !pad {
            Text(doc.title).mobileFont(17, .semibold)
            Text(
              [
                doc.details["Dimensions"], (doc.path as NSString).pathExtension.uppercased(),
                ByteCountFormatter.string(
                  fromByteCount: Int64(doc.file.data.count), countStyle: .file),
              ].compactMap { $0 }.joined(separator: " · ")
            ).secondaryText()
          }
          let details = doc.imageDetails
          ForEach(details.prompts) { row in
            Text(row.label).secondaryText().padding(.top, 6)
            Text(row.value).mobileFont(15).textSelection(.enabled)
          }
          let identity = pad ? [
            MetadataRow(label: "Dimensions", value: doc.details["Dimensions"] ?? ""),
            MetadataRow(label: "File size", value: ByteCountFormatter.string(fromByteCount: Int64(doc.file.data.count), countStyle: .file))
          ] : []
          LazyVGrid(
            columns: pad
              ? Array(repeating: GridItem(.flexible()), count: 2)
              : [GridItem(.adaptive(minimum: 85), alignment: .topLeading)], alignment: .leading,
            spacing: 8
          ) {
            ForEach(details.rows + details.capture + identity) { row in
              if pad {
                VStack(spacing: 5) {
                  Hairline()
                  HStack {
                    Text(row.label).secondaryText()
                    Spacer()
                    Text(row.value).mobileFont(14)
                  }
                }
              } else {
                VStack(alignment: .leading, spacing: 2) {
                  Text(row.label).secondaryText()
                  Text(row.value).mobileFont(15).textSelection(.enabled)
                }
              }
            }
          }.padding(.top, 6)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(
          .vertical, 8)
      }.frame(maxHeight: pad ? 218 : 207).background(
        HouseColor.card,
        in: UnevenRoundedRectangle(topLeadingRadius: pad ? 0 : 24, topTrailingRadius: pad ? 0 : 24))
    }.background(HouseColor.stage).task(id: doc.id) {
      let data = doc.file.data
      let thumbnail = await Task.detached {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
          return nil as CGImage?
        }
        return CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3072,
          ] as CFDictionary)
      }.value
      image = thumbnail
    }
  }
}

#if os(iOS)
  private struct ActivitySheet: UIViewControllerRepresentable {
    let file: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
      UIActivityViewController(activityItems: [file], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
  }
#endif
