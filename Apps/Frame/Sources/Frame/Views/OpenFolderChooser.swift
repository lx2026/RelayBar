import BridgeProtocol
import FrameKit
import SwiftUI

struct OpenFolderChooser: View {
  @ObservedObject var store: LibraryStore
  private var relayInstalled: Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: FrameBridgeEnvironment.relayBundle) != nil
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Open").font(.title2.weight(.semibold))
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          heading("Local")
          Button(action: { store.showsOpenChooser = false; store.presentOpenPanel() }) {
            Label("Choose Folder…", systemImage: "folder.badge.plus")
          }.buttonStyle(.bordered).disabled(!store.canOpenLocalFolder)
          ForEach(store.recentFolders.prefix(5)) { recent in
            Button { Task { await store.openRecent(recent.id) } } label: {
              row(symbol: recent.available ? "folder" : "folder.badge.questionmark",
                  text: abbreviated(recent.parentPath + "/" + recent.name))
            }.buttonStyle(.plain).disabled(!store.canOpenLocalFolder).help(recent.available ? recent.parentPath + "/" + recent.name : "Unavailable · locate folder")
              .contextMenu { Button("Remove from Recents") { store.removeRecent(recent.id) } }
          }
          if store.showsRemoteFolders {
            Divider().padding(.vertical, 8)
            HStack {
              heading("Remote")
              Spacer()
              if store.isLoadingRemoteLocations { ProgressView().controlSize(.mini).accessibilityLabel("Loading remote locations") }
              if let error = store.remoteCatalogError {
                Image(systemName: "exclamationmark.circle").foregroundStyle(FramePalette.muted)
                  .help(error).accessibilityLabel(error)
                Button { Task { await store.refreshRemoteLocations() } } label: { Image(systemName: "arrow.clockwise") }
                  .buttonStyle(.plain).help("Retry").accessibilityLabel("Retry remote locations")
              }
            }
            Button("Browse in RelayBar…", action: store.openRelayBar).buttonStyle(.bordered)
              .disabled(!relayInstalled).help(relayInstalled ? "Choose a folder, then Open in Frame" : "Install RelayBar to open remote folders")
            ForEach(store.remoteLocations.prefix(5)) { location in
              Button { Task { await store.openRemote(location.source, path: location.path) } } label: {
                HStack(spacing: 8) {
                  Image(systemName: "network").foregroundStyle(FramePalette.muted)
                  Text(location.source.name).fontWeight(.medium)
                  Text(location.path).foregroundStyle(FramePalette.muted).lineLimit(1).truncationMode(.middle)
                  Spacer(minLength: 0)
                }.padding(.vertical, 4).contentShape(Rectangle())
              }.buttonStyle(.plain).help(location.source.name + ":" + location.path)
            }
            if !relayInstalled {
              Text("RelayBar isn’t installed.")
                .font(.subheadline).foregroundStyle(FramePalette.muted)
            }
          }
        }
      }.frame(maxHeight: 410)
      HStack { Spacer(); Button("Cancel") { store.showsOpenChooser = false }.keyboardShortcut(.cancelAction) }
    }.font(.callout).padding(24).frame(width: 500)
      .foregroundStyle(FramePalette.ink).background(FramePalette.paper)
      .task { if store.showsRemoteFolders && relayInstalled { await store.refreshRemoteLocations() } }
  }
  private func heading(_ text: String) -> some View { SectionLabel(text) }
  private func row(symbol: String, text: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: symbol).foregroundStyle(FramePalette.muted)
      Text(text).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 0)
    }.padding(.vertical, 4).contentShape(Rectangle())
  }
  private func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

struct FrameSettings: View {
  @ObservedObject var store: LibraryStore
  var body: some View {
    Form {
      Toggle("Show remote folders", isOn: Binding(get: { store.showsRemoteFolders }, set: { value in Task { await store.setShowsRemoteFolders(value) } }))
        .disabled(store.isFileOperation)
      Section("Previews") {
        ForEach(FrameComposition.descriptors) { descriptor in
          Toggle(descriptor.title, isOn: Binding(get: { store.previews.enabledKinds.contains(descriptor.id) }, set: { enabled in
            Task {
              do { try await store.previews.setEnabled(descriptor.id, enabled) }
              catch { store.errorMessage = error.localizedDescription }
            }
          }))
          if descriptor.maximumBytes < Int64.max {
            Picker("\(descriptor.title) size limit", selection: Binding(get: {
              store.previews.maximumBytes(descriptor.id) ?? descriptor.maximumBytes
            }, set: { bytes in
              Task {
                do { try await store.previews.setMaximumBytes(descriptor.id, bytes) }
                catch { store.errorMessage = error.localizedDescription }
              }
            })) {
              ForEach([1, 2, 5, 10], id: \.self) { mib in Text("\(mib) MiB").tag(Int64(mib * 1_024 * 1_024)) }
            }.disabled(!store.previews.enabledKinds.contains(descriptor.id))
          }
        }
      }
    }.formStyle(.grouped).frame(width: 420, height: 550)
      .task {
        do { try await store.previews.start() }
        catch { store.errorMessage = error.localizedDescription }
      }
  }
}
