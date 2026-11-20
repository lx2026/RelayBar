import HouseStyle
import MobileCore
import SwiftUI

enum MobileAccent {
  #if os(macOS)
    static let link = Color(
      nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(
          srgbRed: dark ? 0.57 : 0.141, green: dark ? 0.72 : 0.337, blue: dark ? 0.98 : 0.651,
          alpha: 1)
      })
  #else
    static let link = Color(
      uiColor: UIColor { traits in
        let dark = traits.userInterfaceStyle == .dark
        return UIColor(
          red: dark ? 0.57 : 0.141, green: dark ? 0.72 : 0.337, blue: dark ? 0.98 : 0.651, alpha: 1)
      })
  #endif
}
extension View {
  func card(_ radius: CGFloat = 16) -> some View {
    background(HouseColor.card, in: RoundedRectangle(cornerRadius: radius))
      .overlay {
        RoundedRectangle(cornerRadius: radius).strokeBorder(HouseColor.line, lineWidth: 1)
      }
  }
  func secondaryText() -> some View { mobileFont(13).foregroundStyle(HouseColor.muted) }
  func mobileField() -> some View {
    #if os(iOS)
      self.textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.go)
    #else
      self
    #endif
  }
  func hideNavigation() -> some View {
    #if os(iOS)
      self.toolbarVisibility(.hidden, for: .navigationBar)
    #else
      self
    #endif
  }
}
struct Hairline: View {
  var body: some View {
    Rectangle().fill(HouseColor.line).frame(height: 1).accessibilityHidden(true)
  }
}
struct Glyph: View {
  let name: String
  init(_ name: String) { self.name = name }
  var body: some View { Image(systemName: name).accessibilityHidden(true) }
}
struct IconButton: View {
  let label: String
  let symbol: String
  var circle = true
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Glyph(symbol).frame(width: 44, height: 44).background(
        circle ? HouseColor.fill : .clear, in: Circle())
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain).accessibilityLabel(label)
  }
}
struct MainButton: View {
  let title: String
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Text(title).mobileFont(17, .semibold).frame(maxWidth: .infinity, minHeight: 50)
        .foregroundStyle(HouseColor.buttonText).background(HouseColor.button, in: Capsule())
    }.buttonStyle(.plain)
  }
}
struct StatusMark: View {
  let state: HostState
  var body: some View {
    Group {
      switch state {
      case .connected: Circle().fill(HouseColor.running)
      case .connecting:
        Circle().trim(from: 0.08, to: 0.83).stroke(
          HouseColor.retrying, style: StrokeStyle(lineWidth: 2, lineCap: .round))
      case .failed: Glyph("exclamationmark.triangle.fill").foregroundStyle(HouseColor.failure)
      case .idle: Circle().strokeBorder(HouseColor.faint, lineWidth: 1.6)
      }
    }.frame(width: 12, height: 12).accessibilityLabel(state.label)
  }
}
struct LocationBar: View {
  @Environment(\.dynamicTypeSize) private var typeSize
  let host: String
  let location: String
  let state: HostState
  var back: (() -> Void)?
  let go: () -> Void
  var body: some View {
    HStack(spacing: 8) {
      if let back {
        Button(action: back) { Glyph("chevron.left").frame(width: 46, height: 46).card(23) }
          .accessibilityLabel("Back")
      }
      Button(action: go) {
        HStack(spacing: 8) {
          StatusMark(state: state)
          Text(host).mobileFont(15, .semibold)
            .frame(maxWidth: typeSize.isAccessibilitySize ? 108 : nil, alignment: .leading)
            .layoutPriority(1)
          Rectangle().fill(HouseColor.line).frame(width: 1, height: 18)
          Text(state == .connected ? location : state.label).truncationMode(.head).mobileFont(15)
            .frame(
              maxWidth: .infinity, alignment: .leading
            )
            .foregroundStyle(state == .connected ? HouseColor.ink : HouseColor.warning)
        }.lineLimit(1).padding(.horizontal, 14).frame(minHeight: 46).card(23)
      }.accessibilityLabel("Open Location, \(host), \(location), \(state.label)")
    }.dynamicTypeSize(...DynamicTypeSize.xxxLarge).buttonStyle(.plain).shadow(
      color: HouseColor.ink.opacity(0.10), radius: 10, y: 6
    )
    .padding(.horizontal, 14).padding(.vertical, 4)
    .background(alignment: .bottom) {
      LinearGradient(
        colors: [HouseColor.paper.opacity(0), HouseColor.paper, HouseColor.paper],
        startPoint: .top, endPoint: .bottom
      )
      .frame(height: 100).allowsHitTesting(false)
    }
  }
}
struct FileLine: View {
  @Environment(\.dynamicTypeSize) private var typeSize
  let icon: String
  let title: String
  let subtitle: String
  var time: String? = nil
  var changed = false
  var chevron = false
  var rule = true
  var image: CGImage? = nil
  let action: () -> Void
  var body: some View {
    VStack(spacing: 0) {
      Button(action: action) {
        HStack(spacing: 12) {
          ZStack {
            HouseColor.fill
            if let image {
              Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
              Glyph(icon).foregroundStyle(HouseColor.muted)
            }
          }.frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 10))
          VStack(alignment: .leading, spacing: 1) {
            Text(title).mobileFont(16, .medium)
            if !subtitle.isEmpty { Text(subtitle).secondaryText() }
            if typeSize.isAccessibilitySize, let time { Text(time).secondaryText() }
          }
          Spacer(minLength: 4)
          if !typeSize.isAccessibilitySize, let time {
            Text(time).secondaryText().monospacedDigit()
          }
          if changed {
            Circle().fill(MobileAccent.link).frame(width: 8, height: 8).accessibilityLabel(
              "Changed since you read it")
          }
          if chevron { Glyph("chevron.right").font(.caption).foregroundStyle(HouseColor.faint) }
        }.frame(minHeight: 54).contentShape(Rectangle())
      }.buttonStyle(.plain)
      if rule { Hairline().padding(.leading, 52) }
    }
  }
}

extension EnvironmentValues {
  @Entry var renderingGallery = false
}

/// ImageRenderer draws SwiftUI primitives. A native scroll viewport needs a window,
/// so use its content at the same proposed width for the off-screen portrait.
struct PageScroll<Content: View>: View {
  @Environment(\.renderingGallery) var snapshot
  @ViewBuilder var content: Content
  var body: some View {
    if snapshot {
      GeometryReader { proxy in
        content.frame(width: proxy.size.width, alignment: .topLeading).fixedSize(
          horizontal: false, vertical: true)
      }.clipped()
    } else {
      ScrollView { content }
    }
  }
}
struct MobileFont: ViewModifier {
  #if os(macOS)
    @Environment(\.dynamicTypeSize) var typeSize
    let base: CGFloat
    // macOS does not scale ScaledMetric with the iOS content size category.
    // Match the iOS Body point sizes for the two gallery endpoints.
    var points: CGFloat {
      switch typeSize {
      case .xSmall: base * 14 / 17
      case .accessibility5: base * 53 / 17
      default: base
      }
    }
  #else
    @ScaledMetric var points: CGFloat
  #endif
  var weight: Font.Weight
  init(_ points: CGFloat, _ weight: Font.Weight) {
    #if os(macOS)
      base = points
    #else
      _points = ScaledMetric(wrappedValue: points, relativeTo: .body)
    #endif
    self.weight = weight
  }
  func body(content: Content) -> some View { content.font(.system(size: points, weight: weight)) }
}
extension View {
  func mobileFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
    modifier(MobileFont(size, weight)).dynamicTypeSize(
      ...(size >= 22 ? DynamicTypeSize.xxxLarge : .accessibility5))
  }
}

/// Keep the panel attached to the lower edge while the keyboard changes its available height.
extension View {
  func bottomPanel<Panel: View>(
    shown: Bool, fraction: CGFloat, @ViewBuilder content: @escaping () -> Panel
  ) -> some View {
    self.disabled(shown).accessibilityHidden(shown).overlay {
      if shown {
        GeometryReader { proxy in
          ZStack(alignment: .bottom) {
            Color.black.opacity(0.22).ignoresSafeArea()
            content()
              .frame(maxWidth: .infinity)
              .frame(height: proxy.size.height * fraction)
              .background(HouseColor.panel)
              .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
              .background(alignment: .bottom) {
                HouseColor.panel.frame(height: 1).ignoresSafeArea(edges: .bottom)
              }
          }.accessibilityAddTraits(.isModal)
        }
      }
    }
  }
}
