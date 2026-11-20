import Composition
import CompositionUI
import HouseStyle
import MobileCore
import SwiftUI

func pluginGroup(_ plugin: PluginDescriptor) -> String {
  switch plugin.id {
  case "more-images", "notebook-preview", "table-preview", "html-scripts": "Previews"
  case "pinned-services", "favorites", "prompt-search", "file-search", "log-follow": "Pages"
  case "delete-undo": "Files"
  case "paper": "Appearance"
  default: "Network"
  }
}
struct SettingsScreen: View {
  let core: MobileComposition
  @ObservedObject var profiles: PreferenceStore<Preferences>
  let done: () -> Void
  var body: some View {
    NavigationStack {
      SettingsContent(core: core, profiles: profiles, done: done)
    }
    .environment(\.pluginHostRealms, profiles.value.hosts.map(\.realm))
    .pluginDetailSupplement { plugin in
      HostPluginSettings(core: core, profiles: profiles, plugin: plugin)
    }
  }
}

struct SettingsContent: View {
  let core: MobileComposition
  @ObservedObject var profiles: PreferenceStore<Preferences>
  let done: () -> Void
  @State var key = ""
  @State private var keyMissing = false
  @State private var error = ""
  @State var sizes: [UUID: Int] = [:]
  @Environment(\.renderingGallery) private var gallery
  var body: some View {
    PageScroll {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text("Settings").mobileFont(32, .bold)
          Spacer()
          Button("Done", action: done)
        }
        NavigationLink {
          GeometryReader { geometry in
            Group {
              if geometry.size.width >= 760 {
                MobilePluginsWorkspace(
                  composer: core.composer, groupTitle: pluginGroup, realmTitle: title)
              } else {
                MobilePluginsList(
                  composer: core.composer, groupTitle: pluginGroup, realmTitle: title)
              }
            }
          }
        } label: {
          HStack {
            Label("Plugins", systemImage: "puzzlepiece.extension")
            Spacer()
            Glyph("chevron.right")
          }.padding().card()
        }
        Text("Storage").secondaryText()
        ForEach(profiles.value.hosts) { host in
          HStack {
            VStack(alignment: .leading) {
              Text(host.host)
              Text(
                ByteCountFormatter.string(
                  fromByteCount: Int64(sizes[host.id] ?? 0), countStyle: .file)
              ).secondaryText()
            }
            Spacer()
            Button("Clear") {
              Task {
                do {
                  try await core.cache.clear(host.id)
                  sizes[host.id] = await core.cache.size(host.id)
                } catch { self.error = error.localizedDescription }
              }
            }
          }.padding().card().task { sizes[host.id] = await core.cache.size(host.id) }
        }
        Text("Device public key").secondaryText()
        VStack(alignment: .leading, spacing: 8) {
          Text(key.isEmpty ? (keyMissing ? "No device key exists yet." : "Checking device key…") : key).font(.caption.monospaced()).textSelection(
            .enabled)
          if keyMissing && key.isEmpty {
            Button("Create Key") {
              Task {
                do { key = try await core.runtime.service(Keys.self)?.key().authorizedKey ?? "" }
                catch { self.error = error.localizedDescription }
              }
            }
          }
          Button("Copy") {
            #if os(iOS)
              UIPasteboard.general.string = key
            #else
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(key, forType: .string)
            #endif
          }.disabled(key.isEmpty)
        }.padding().card()
        Text("About").secondaryText()
        Text(
          "RelayBar · "
            + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
              ?? "—") + " ("
            + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—") + ")")
        if CommandLine.arguments.contains("--demo-host"), let host = profiles.value.hosts.first {
          NavigationLink("Demo approval sheets") {
            DemoApprovalScreens(profile: host)
          }
        }
        if !error.isEmpty { Text(error).foregroundStyle(HouseColor.failure) }
      }.padding(20)
    }.background(HouseColor.paper).task {
      if !gallery {
        do {
          guard let provider = core.runtime.service(Keys.self) else { return }
          key = try await provider.existingKey()?.authorizedKey ?? ""
          keyMissing = key.isEmpty
        } catch {
          self.error = error.localizedDescription
        }
      }
    }
  }
  private func title(_ realm: String) -> String {
    profiles.value.hosts.first { $0.realm == realm }?.host ?? realm
  }
}

struct HostPluginSettings: View {
  let core: MobileComposition
  @ObservedObject var profiles: PreferenceStore<Preferences>
  let plugin: PluginDescriptor
  @State private var error = ""
  var body: some View {
    ForEach(profiles.value.hosts) { host in
      if !plugin.realmRelativeFeatures.isEmpty
        && !core.composer.graph.nodes.contains(where: { $0.id == host.realm })
      {
        Picker(
          host.host,
          selection: Binding(
            get: { core.composer.hostChoice(for: plugin, in: host.realm) },
            set: { choice in
              Task { await core.composer.setHostChoice(choice, for: plugin, in: host.realm) }
            })
        ) {
          ForEach(PluginHostChoice.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
      }
      if plugin == networkPlugin, let destinations = profiles.value.destinations?[host.id],
        !destinations.isEmpty
      {
        Text("Allowed destinations · " + host.host).font(.headline)
        ForEach(
          destinations.sorted { $0.label < $1.label },
          id: \.self
        ) { endpoint in
          HStack {
            Text(endpoint.label)
            Spacer()
            Button("Remove") {
              do { try profiles.update { _ = $0.destinations?[host.id]?.remove(endpoint) } } catch {
                self.error = error.localizedDescription
              }
            }
          }
        }
      }
    }
    if !error.isEmpty { Text(error) }
  }
}

private struct DemoApprovalScreens: View {
  let profile: Profile
  @State private var prompt: ServicePrompt?
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Button("Destination approval") { prompt = .destination(.init(name: "dashboard", port: 6006)) }
      Button("Certificate approval") {
        prompt = .certificate(
          .init(name: profile.privateName, port: 8443),
          .init(subject: "Demo service", fingerprint: DemoHost.certificateFingerprint),
          previous: nil)
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
      .bottomPanel(shown: prompt != nil, fraction: 0.65) {
        if let prompt {
          ApprovalSheet(prompt: prompt, host: profile.host) { _ in self.prompt = nil }
        }
      }
  }
}
