import HouseStyle
import MobileCore
import SwiftUI

struct ServiceBar<Actions: View>: View {
  let host: String
  let port: UInt16
  let count: Int
  let state: HostState
  let back: () -> Void
  let go: () -> Void
  let reload: () -> Void
  let tabs: () -> Void
  @ViewBuilder let actions: () -> Actions
  var body: some View {
    HStack(spacing: 6) {
      IconButton(label: "Back", symbol: "chevron.left", action: back)
      HStack(spacing: 4) {
        Button(action: go) {
          HStack(spacing: 6) {
            StatusMark(state: state)
            Text(host).mobileFont(15, .semibold).lineLimit(1)
            Divider().frame(height: 18)
            Text(":" + String(port)).font(.footnote.monospaced()).fixedSize()
          }
        }
        Spacer(minLength: 0)
        IconButton(label: "Reload", symbol: "arrow.clockwise", circle: false, action: reload)
      }.padding(.leading, 10).card(23)
      Menu(content: actions) { Glyph("ellipsis").frame(width: 32, height: 44) }.accessibilityLabel(
        "Page menu")
      Button(action: tabs) {
        Text(String(count)).font(.caption.bold()).padding(4).overlay {
          RoundedRectangle(cornerRadius: 5).strokeBorder()
        }.frame(width: 44, height: 44).card(22)
      }.accessibilityLabel("Open websites")
    }.padding(.horizontal, 12).padding(.vertical, 4).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
  }
}

struct LocalhostOffer: View {
  let host: String
  let title: String
  let accept: () -> Void
  let decline: () -> Void
  var body: some View {
    PageScroll {
      VStack(alignment: .leading, spacing: 16) {
        Text("This server answers only to localhost").mobileFont(24, .bold).dynamicTypeSize(
          ...DynamicTypeSize.xxxLarge)
        Text(
          "\(title) on \(host) can open as localhost through a listener on this device that checks every request."
        ).mobileFont(16)
        Label(
          "Pages on this service can read a session token. Choose this for services you trust.",
          systemImage: "lock"
        ).mobileFont(15).padding().card()
        MainButton(title: "Open as Localhost", action: accept)
        Button("Not now", action: decline).frame(maxWidth: .infinity, minHeight: 44)
        Text("Remembered for \(title) on \(host)").secondaryText()
      }.padding(20)
    }.background(HouseColor.panel)
  }
}

struct ServicePreview {
  let image: CGImage?
  let route: String
}

struct OpenServices: View {
  @Environment(\.dynamicTypeSize) private var typeSize
  let hosts: [Profile]
  let data: Preferences
  let states: [UUID: HostState]
  let current: UUID
  let disconnect: () -> Void
  var showHosts: (() -> Void)? = nil
  var preview: (Profile, ServiceAddress) -> ServicePreview? = { _, _ in nil }
  let done: () -> Void
  let new: () -> Void
  let open: (Profile, ServiceAddress) -> Void
  let close: (Profile, ServiceAddress) -> Void
  var body: some View {
    VStack {
      HStack {
        Text("Open websites").mobileFont(28, .bold).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        Spacer()
        Button("Done", action: done)
      }.padding(.horizontal, 20)
      PageScroll {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(hosts) { host in
            if let tabs = data.serviceTabs?[host.id], !tabs.isEmpty {
              HStack {
                StatusMark(state: states[host.id] ?? .idle)
                Text(host.host).mobileFont(17, .semibold)
                Spacer()
                if host.id == current, states[host.id] == .connected {
                  Button("Disconnect", action: disconnect).foregroundStyle(MobileAccent.link)
                } else {
                  Text(states[host.id]?.label ?? "Not connected").secondaryText()
                }
              }
              LazyVGrid(
                columns: [.init(.adaptive(minimum: typeSize.isAccessibilitySize ? 290 : 147))],
                alignment: .leading
              ) {
                ForEach(tabs, id: \.self) { address in
                  VStack(alignment: .leading, spacing: 0) {
                    let page = preview(host, address)
                    ZStack(alignment: .topTrailing) {
                      Button {
                        open(host, address)
                      } label: {
                        ZStack {
                          HouseColor.fill
                          if let image = page?.image {
                            Image(decorative: image, scale: 1).resizable().scaledToFill()
                              .frame(maxWidth: .infinity, maxHeight: 90, alignment: .top).clipped()
                          } else {
                            Glyph("network").foregroundStyle(HouseColor.muted)
                          }
                        }
                      }

                    }.frame(height: 90).clipped()
                    HStack(spacing: 0) {
                      Button {
                        open(host, address)
                      } label: {
                        VStack(alignment: .leading, spacing: 4) {
                          Text(
                            address.destination ?? data.serviceTitles?[host.id]?[address.port]
                              ?? "Website"
                          )
                          .mobileFont(16, .semibold)
                          if let plugin = data.missingPlugin(for: address, host: host.id) {
                            Text("Turn on " + plugin.title).secondaryText()
                          }
                          Text(
                            ":\(address.port)" + (address.path == "/" ? "" : address.path)
                              + (page.map { " · " + $0.route } ?? "")
                          ).secondaryText()
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                      }
                      Button {
                        close(host, address)
                      } label: {
                        Glyph("xmark").font(.caption).padding(10)
                      }.accessibilityLabel("Close service")
                    }
                  }.card()
                }
              }
            }
          }
          if data.serviceTabs?.values.allSatisfy(\.isEmpty) != false {
            Text("No open websites").secondaryText().padding(.vertical)
          }
        }.padding(20)
      }
      HStack {
        Button(action: new) {
          Label("Open a website", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 46)
            .card(23)
        }
        IconButton(label: "Hosts", symbol: "server.rack", action: showHosts ?? disconnect)
      }.padding(.horizontal, 16).serviceFade()
    }.background(HouseColor.paper)
  }
}

extension View {
  func serviceFade() -> some View {
    background(alignment: .bottom) {
      LinearGradient(
        colors: [HouseColor.paper.opacity(0), HouseColor.paper], startPoint: .top, endPoint: .bottom
      )
      .frame(height: 88).allowsHitTesting(false).ignoresSafeArea(edges: .bottom)
    }
  }
}

struct PadServiceHeader: View {
  let title: String
  let host: String
  let port: UInt16
  let back, forward, reload, close: () -> Void
  var route: String? = nil
  @Environment(\.readerControls) private var controls
  var body: some View {
    HStack(spacing: 4) {
      if let controls { Color.clear.frame(width: controls.leadingInset, height: 1) }
      IconButton(label: "Back", symbol: "chevron.left", circle: false, action: back)
      IconButton(label: "Forward", symbol: "chevron.right", circle: false, action: forward)
      IconButton(label: "Reload", symbol: "arrow.clockwise", circle: false, action: reload)
      VStack(alignment: .leading) {
        Text(title).mobileFont(16, .semibold)
        Text(verbatim: "\(host) · :\(port)").secondaryText()
      }
      Spacer()
      if let route { Text(route).secondaryText().padding(5).card(10) }
      IconButton(label: "Close this page", symbol: "xmark", circle: false, action: close)
    }.padding(.horizontal, 12).frame(height: 44)
  }
}
