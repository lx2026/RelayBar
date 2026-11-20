import HouseStyle
import MobileCore
import SwiftUI

/// One sheet stays mounted from account entry through host verification and authentication.
struct ConnectionSheet: View {
  let host: String
  let account: String
  let prompt: SignIn.Prompt?
  let status: String
  var error = ""
  let submitAccount: (String) -> Void
  let trust: (LoginMethod) -> Void
  let submitPassword: (String, Bool) -> Void
  let copyKey: () -> Void
  let cancel: () -> Void
  @State private var username = ""
  @State private var password = ""
  @State private var remember = false
  @State private var method = "Tailscale SSH"

  private var deviceKey: String {
    #if os(iOS)
      UIDevice.current.userInterfaceIdiom == .pad ? "This iPad’s key" : "This iPhone’s key"
    #else
      "This iPhone’s key"
    #endif
  }

  var body: some View {
    VStack(spacing: 0) {
      Capsule().fill(HouseColor.fill).frame(width: 36, height: 5).padding(.top, 8)
      PageScroll {
        VStack(alignment: .leading, spacing: 8) {
          Text("Connect to \(host)").mobileFont(26, .bold)
          Text(account.isEmpty ? "On your tailnet" : account + "@" + host + " · on your tailnet")
            .secondaryText()
          if !error.isEmpty { Text(error).secondaryText().foregroundStyle(HouseColor.failure) }
          if account.isEmpty {
            TextField("Account", text: $username).mobileField().onSubmit { submitAccount(username) }
              .padding(14).card()
          } else if case .trust(let key) = prompt {
            Text("Check the host key").secondaryText().padding(.top, 16)
            VStack(alignment: .leading, spacing: 6) {
              Text(key.algorithm.replacingOccurrences(of: "ssh-", with: "").uppercased()).font(
                .caption.weight(.semibold)
              ).foregroundStyle(HouseColor.muted)
              Text(key.fingerprint).font(.footnote.monospaced()).textSelection(.enabled)
              Hairline().padding(.vertical, 6)
              Text("Compare it with the host’s own answer to").secondaryText()
              Text(
                "ssh-keygen -lf /etc/ssh/ssh_host_\(key.algorithm.contains("ed25519") ? "ed25519" : "ecdsa")_key.pub"
              )
              .font(.footnote.monospaced()).foregroundStyle(HouseColor.muted)
            }.padding(16).card()
            Text("Sign in").secondaryText().padding(.top, 16)
            VStack(spacing: 0) {
              row("Tailscale SSH", "Signs you in by your tailnet identity. No key or password.")
              Hairline().padding(.leading, 50)
              row("Password", "For an ordinary SSH server.")
              Hairline().padding(.leading, 50)
              HStack {
                row(deviceKey, "Made when a host asks for one.")
                Button("Copy key", action: copyKey).foregroundStyle(MobileAccent.link).padding(
                  .trailing, 12)
              }
            }.card()
            Text(
              "RelayBar tries Tailscale SSH first and only asks when the host wants something else."
            ).secondaryText()
          } else if prompt == .password {
            SecureField("Password", text: $password).padding(14).card()
            Button {
              remember.toggle()
            } label: {
              Label(
                "Keep on this device", systemImage: remember ? "checkmark.square.fill" : "square"
              ).frame(minHeight: 44)
            }
          } else {
            Text(status).secondaryText()
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
      }
      VStack(spacing: 4) {
        if account.isEmpty {
          MainButton(title: "Check host key") { submitAccount(username) }.disabled(username.isEmpty)
        }
        if case .trust = prompt {
          MainButton(
            title: "Trust and connect",
            action: {
              trust(
                method == "Password" ? .password : method == deviceKey ? .key : .automatic
              )
            })
        }
        if prompt == .password {
          MainButton(title: "Sign in") {
            submitPassword(password, remember)
            password = ""
          }
        }
        Button("Cancel", action: cancel).frame(minHeight: 44).foregroundStyle(MobileAccent.link)
      }.padding(.horizontal, 20).padding(.bottom, 8)
    }.buttonStyle(.plain).frame(maxWidth: .infinity, maxHeight: .infinity).background(
      HouseColor.panel
    ).interactiveDismissDisabled()
  }
  private func row(_ name: String, _ detail: String) -> some View {
    Button {
      method = name
    } label: {
      HStack(spacing: 12) {
        Glyph(method == name ? "checkmark.circle.fill" : "circle").font(.title2)
          .foregroundStyle(method == name ? MobileAccent.link : HouseColor.faint)
        VStack(alignment: .leading, spacing: 2) {
          Text(name).mobileFont(16, .semibold)
          Text(detail).secondaryText()
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 56)
    }.accessibilityAddTraits(method == name ? .isSelected : [])
  }
}
