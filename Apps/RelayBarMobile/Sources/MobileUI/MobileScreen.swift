import Composition
import HouseStyle
import MobileCore
import SwiftUI

@MainActor public final class MobileApplication: ObservableObject {
  let core: MobileComposition?
  let demo: DemoHost?
  let error: String?
  public init() {
    do {
      if CommandLine.arguments.contains("--demo-host") {
        let host = try DemoHost()
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        core = try MobileComposition(
          directory: folder, cache: folder.appending(path: "cache"), keys: DemoKeys()
        ) {
          _, _, _ in host
        }
        demo = host
      } else {
        core = try MobileComposition(
          directory: .applicationSupportDirectory,
          cache: URL.cachesDirectory.appending(path: "Documents"))
        demo = nil
      }
      error = nil
    } catch {
      self.error = error.localizedDescription
      core = nil
      demo = nil
    }
  }
}
public struct MobileScreen: View {
  @ObservedObject var application: MobileApplication
  @State private var ready = false
  @State private var message = ""
  public init(application: MobileApplication) { self.application = application }
  public var body: some View {
    Group {
      if ready, let core = application.core, let prefs = core.runtime.service(Profiles.self) {
        SceneScreen(core: core, profiles: prefs, states: core.states)
      } else {
        Text(application.error ?? message).task {
          guard let core = application.core else { return }
          do {
            _ = try await application.demo?.install(in: core)
            await core.runtime.settled()
            ready = true
          } catch { message = error.localizedDescription }
        }
      }
    }.foregroundStyle(HouseColor.ink).tint(MobileAccent.link).buttonStyle(.plain).textFieldStyle(
      .plain)
  }
}

struct HostsPage: View {
  @Environment(\.renderingGallery) var snapshot
  let hosts: [Profile]
  let history: [Visit]
  let states: [UUID: HostState]
  @Binding var query: String
  let connect: () -> Void
  let settings: () -> Void
  let choose: (Profile) -> Void
  @FocusState var focus: Bool
  var body: some View {
    PageScroll {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text("Hosts").mobileFont(32, .bold)
          Spacer()
          IconButton(label: "Settings", symbol: "gearshape", action: settings)
          IconButton(label: "Add host", symbol: "plus") {
            if query.isEmpty { focus = true } else { connect() }
          }
        }
        Text("Connect").secondaryText().padding(.top, 20)
        Group {
          if snapshot {
            Text("Host, or user@host").foregroundStyle(HouseColor.faint).frame(
              maxWidth: .infinity, alignment: .leading)
          } else {
            TextField("Host, or user@host", text: $query).focused($focus).mobileField().onSubmit(
              connect)
          }
        }.mobileFont(16)
          .padding(.horizontal, 14).frame(minHeight: 50).card(14).padding(.vertical, 6)
        Text("A tailnet name is enough. A pasted ssh command works too.").secondaryText().padding(
          .bottom, 18)
        ForEach(hosts) { profile in
          HostRow(
            profile: profile, state: states[profile.id] ?? .idle,
            lastVisit: history.first { $0.profile == profile.id }
          ) { choose(profile) }
        }
      }.padding(.horizontal, 20)
    }.background(HouseColor.paper)
  }
}

private struct SceneScreen: View {
  let core: MobileComposition
  @ObservedObject var profiles: PreferenceStore<Preferences>
  @ObservedObject var states: HostStates
  @Environment(\.scenePhase) var phase
  @State private var scene = UUID()
  @State private var selected: Profile?
  @State private var initialRoute: Route?
  @State private var query = ""
  @State private var endpoint: HostEndpoint?
  private enum Sheet: String, Identifiable {
    case connection, settings
    var id: Self { self }
  }
  @State private var sheet: Sheet?
  @State private var closing = false
  @State private var requestedConnection = false
  @State private var message = ""
  @State private var askAccount = false
  var body: some View {
    VStack(spacing: 0) {
      if !message.isEmpty { Text(message).mobileFont(13).foregroundStyle(HouseColor.failure) }
      if let selected {
        HostWorkspace(
          core: core, profile: selected, profiles: profiles, initialRoute: initialRoute,
          switchService: { host, route in
            select(host)
            initialRoute = route
          }, choose: select,
          resume: { profile, path in
            select(profile)
            initialRoute =
              profiles.value.history.first { $0.profile == profile.id && $0.path == path }.map(
                Route.recent) ?? .document(path)
          },
          add: {
            query = $0
            prepare()
          }, settings: { show(.settings) }, hosts: { self.selected = nil }
        )
        .id(selected.id)
      } else {
        HostsPage(
          hosts: profiles.value.hosts, history: profiles.value.history, states: states.values,
          query: $query, connect: prepare, settings: { show(.settings) }, choose: select)
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(HouseColor.paper)
      .onAppear {
        selected = profiles.value.hosts.first { $0.id == profiles.value.lastHost }
        endpoint = selected.map(HostEndpoint.init)
        demand()
      }
      .onChange(of: selected) { demand() }.onChange(of: phase) { demand() }
      .onDisappear { core.runtime.service(Demand.self)?.show(nil, in: scene) }
      .background {
        if let selected {
          AuthPortView(port: core.runtime.port(AuthenticationPort.self, realm: selected.realm)) {
            auth in
            Color.clear.onChange(of: auth?.prompt, initial: true) { _, prompt in
              if prompt != nil {
                requestedConnection = true
                show(.connection)
              }
            }.onChange(of: auth?.status, initial: true) { _, status in
              if let status, auth?.prompt == nil, !status.hasSuffix("…") {
                requestedConnection = false
                if sheet == .connection { dismiss() }
              } else if auth?.prompt == nil, !askAccount, !requestedConnection, sheet == .connection
              {
                dismiss()
              }
            }
          }
        }
      }
      .onChange(of: sheet) { old, new in
        if old != nil && new == nil {
          closing = false
          if requestedConnection || askAccount { show(.connection) }
        }
      }
      .bottomPanel(shown: sheet != nil, fraction: 0.9) {
        if sheet == .connection, let endpoint {
          if let selected {
            AuthPortView(port: core.runtime.port(AuthenticationPort.self, realm: selected.realm)) {
              auth in
              connection(endpoint, selected, auth)
            }
          } else {
            connection(endpoint, nil, nil)
          }
        } else {
          SettingsScreen(core: core, profiles: profiles, done: dismiss)
        }
      }
  }
  private func show(_ destination: Sheet) {
    guard !closing, sheet != destination else { return }
    if sheet != nil { dismiss() } else { sheet = destination }
  }
  private func dismiss() {
    closing = true
    sheet = nil
  }
  func connection(_ endpoint: HostEndpoint, _ profile: Profile?, _ auth: SignIn?) -> ConnectionSheet
  {
    ConnectionSheet(
      host: endpoint.host, account: profile?.account ?? "", prompt: auth?.prompt,
      status: auth?.status ?? "Connecting…", error: message,
      submitAccount: { account in
        askAccount = false
        requestedConnection = true
        save(account)
      },
      trust: { method in
        do {
          if method == .automatic || profile?.method == method {
            try auth?.trust()
          } else if let profile {
            try auth?.pinForNewMethod()
            try profiles.update { prefs in
              if let index = prefs.hosts.firstIndex(where: { $0.id == profile.id }) {
                prefs.hosts[index].method = method
              }
            }
          }
        } catch { message = error.localizedDescription }
      },
      submitPassword: { p, keep in
        do { try auth?.submit(p, remember: keep) } catch { message = error.localizedDescription }
      },
      copyKey: {
        Task {
          do {
            if let key = try await core.runtime.service(Keys.self)?.existingKey()?.authorizedKey {
              #if os(iOS)
                UIPasteboard.general.string = key
              #else
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key, forType: .string)
              #endif
            } else { message = "No device key exists yet. Use Create Key in Settings." }
          } catch { message = error.localizedDescription }
        }
      },
      cancel: {
        askAccount = false
        requestedConnection = false
        dismiss()
        selected = nil
      })
  }
  func demand() {
    core.runtime.service(Demand.self)?.show(phase == .background ? nil : selected?.id, in: scene)
  }
  func prepare() {
    do {
      let parsed = try HostEndpoint(query)
      endpoint = parsed
      let matches = profiles.value.hosts.filter { $0.host == parsed.host && $0.port == parsed.port }
      if let user = parsed.account {
        save(user)
      } else if matches.count == 1, let existing = matches.first {
        select(existing)
      } else {
        selected = nil
        askAccount = true
        show(.connection)
      }
    } catch { message = error.localizedDescription }
  }
  func save(_ account: String) {
    guard let endpoint, !account.isEmpty else { return }
    let profile =
      profiles.value.hosts.first {
        $0.host == endpoint.host && $0.port == endpoint.port && $0.account == account
      }
      ?? Profile(host: endpoint.host, account: account, port: endpoint.port)
    do {
      try profiles.update { if !$0.hosts.contains(profile) { $0.hosts.append(profile) } }
      select(profile)
    } catch { message = error.localizedDescription }
  }
  func select(_ profile: Profile) {
    do {
      try profiles.update { $0.lastHost = profile.id }
      endpoint = HostEndpoint(profile)
      message = ""
      initialRoute = nil
      if case .failed = states.values[profile.id] { try core.retry(profile.id) }
      selected = profile
    } catch { message = error.localizedDescription }
  }
}

private struct AuthPortView<Content: View>: View {
  @ObservedObject var port: ServicePort<SignIn>
  let content: (SignIn?) -> Content
  var body: some View {
    if let auth = port.value { ObservedAuth(auth: auth, content: content) } else { content(nil) }
  }
}
private struct ObservedAuth<Content: View>: View {
  @ObservedObject var auth: SignIn
  let content: (SignIn?) -> Content
  var body: some View { content(auth) }
}

struct HostRow: View {
  let profile: Profile
  let state: HostState
  let lastVisit: Visit?
  let choose: () -> Void
  var body: some View {
    VStack(spacing: 0) {
      Button {
        choose()
      } label: {
        HStack(spacing: 14) {
          StatusMark(state: state)
          VStack(alignment: .leading, spacing: 2) {
            Text(profile.host).mobileFont(17, .semibold)
            if case .failed(let reason) = state {
              Text(reason).mobileFont(13)
                .foregroundStyle(HouseColor.failure)
            } else {
              Text(
                lastVisit.map {
                  "On your tailnet · " + $0.title
                } ?? "On your tailnet · " + state.label.lowercased()
              ).secondaryText()
            }
          }
          Spacer()
          if case .failed = state {
            Text("Retry").foregroundStyle(MobileAccent.link)
          } else {
            Glyph("chevron.right").font(.caption).foregroundStyle(HouseColor.faint)
          }
        }.frame(minHeight: 68).contentShape(Rectangle())
      }.buttonStyle(.plain)
      Hairline().padding(.leading, 26)
    }
  }
}
