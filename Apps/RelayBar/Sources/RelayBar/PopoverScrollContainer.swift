import AppKit
import HouseStyle
import SwiftUI

enum RelayBarPopoverLayout {
    static let width: CGFloat = 380
    static let height: CGFloat = 440
    static let size = CGSize(width: width, height: height)
    /// The profile editor's balanced inset.
    static let contentInset: CGFloat = 16

    static let headerHeight: CGFloat = 44
    /// Leading inset of the header's title.
    static let headerTitleInset: CGFloat = 16
    /// Inset of an icon button at either end of a header bar.
    static let headerButtonInset: CGFloat = 9
    static let footerHeight: CGFloat = 40
    static let footerInset: CGFloat = 8

    static let iconButtonSize: CGFloat = 26
    static let rowIconButtonSize: CGFloat = 24
    static let buttonCornerRadius: CGFloat = 7

    static let listHorizontalInset: CGFloat = 6
    static let listTopInset: CGFloat = 4
    /// Also the height of the list's fade, so the last row clears it at the end of the list.
    static let listBottomInset: CGFloat = 16
    static let rowHeight: CGFloat = 46
    static let rowCornerRadius: CGFloat = 8
    static let rowLeadingInset: CGFloat = 10
    static let rowTrailingInset: CGFloat = 8
    static let rowSpacing: CGFloat = 10
    static let statusColumnWidth: CGFloat = 10
    static let groupHeaderHeight: CGFloat = 26
    /// Extra space above every group header but the first.
    static let groupSpacing: CGFloat = 6

    /// Cards in the profile editor's form.
    static let cardCornerRadius: CGFloat = 12

    static func contentWidth(
        for viewportWidth: CGFloat,
        horizontalInset: CGFloat = contentInset
    ) -> CGFloat {
        max(0, viewportWidth - (horizontalInset * 2))
    }
}

/// The one colour the popover derives for itself; every other colour comes from the house palette.
enum RelayBarPopoverPalette {
    /// The accent colour, darkened in light appearance and lightened in dark so small text stays legible.
    static let accentText = NSColor(name: nil) { appearance in
        var accent = NSColor.systemBlue
        appearance.performAsCurrentDrawingAppearance {
            accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? accent
        }
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? accent.blended(withFraction: 0.35, of: .white) ?? accent
            : accent.blended(withFraction: 0.25, of: .black) ?? accent
    }
}

/// The popover's icon button: a rounded square with no resting fill, a faint fill under the pointer and a
/// stronger one while pressed.
struct PopoverIconButtonStyle: ButtonStyle {
    var size: CGFloat = RelayBarPopoverLayout.iconButtonSize
    var glyphSize: CGFloat = 14
    var tint: Color = HouseColor.muted

    /// The smaller buttons a row shows under the pointer.
    static func row(tint: Color = HouseColor.ink) -> PopoverIconButtonStyle {
        PopoverIconButtonStyle(size: RelayBarPopoverLayout.rowIconButtonSize, glyphSize: 12, tint: tint)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: glyphSize))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .modifier(PopoverHoverFill(isPressed: configuration.isPressed))
    }
}

/// A text button in the popover's chrome, as tall as an icon button and in its shape.
struct PopoverTextButtonStyle: ButtonStyle {
    var tint: Color = HouseColor.ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: RelayBarPopoverLayout.iconButtonSize)
            .modifier(PopoverHoverFill(isPressed: configuration.isPressed))
    }
}

private struct PopoverHoverFill: ViewModifier {
    @HouseTracking private var house
    let isPressed: Bool
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: RelayBarPopoverLayout.buttonCornerRadius, style: .continuous)
        content
            .opacity(isEnabled ? 1 : 0.4)
            .background(shape.fill(fill))
            // Pressed is the hover fill laid twice.
            .background(shape.fill(isEnabled && isPressed ? HouseColor.fill : .clear))
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .clearingHoverWhenWindowResignsKey($isHovered)
    }

    private var fill: Color {
        guard isEnabled, isPressed || isHovered else { return .clear }
        return HouseColor.fill
    }
}

extension View {
    /// The popover hides while the pointer is still over whatever was clicked, and no
    /// hover-exit arrives for a hidden window, so the highlight would still be there
    /// when it next opens.
    func clearingHoverWhenWindowResignsKey(_ isHovered: Binding<Bool>) -> some View {
        onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            isHovered.wrappedValue = false
        }
    }
}

/// Uppercase labels above a group of settings, fields or sidebar rows.
struct SectionLabel: View {
    @HouseTracking private var house
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(HouseColor.muted)
    }
}

extension View {
    /// Gives an actions menu the same shape and hit target as the icon buttons.
    func popoverIconMenu(style: PopoverIconButtonStyle = .row()) -> some View {
        menuStyle(.button)
            .buttonStyle(style)
            .menuIndicator(.hidden)
            .fixedSize()
    }

    /// The raised card behind the profile editor's rule editors.
    func popoverCard() -> some View {
        let shape = RoundedRectangle(
            cornerRadius: RelayBarPopoverLayout.cardCornerRadius,
            style: .continuous
        )
        return background(shape.fill(HouseColor.card))
            .overlay(shape.stroke(HouseColor.line, lineWidth: 1))
    }
}

/// A popover scroller that moves only vertically. Its document is exactly as
/// wide as the clip view under either scroller style, and its content is laid
/// out at that width less balanced insets and never wider, so long text, focus
/// rings and intrinsically wide controls cannot create a horizontal scroll
/// range or shift the document away from its leading inset. Its scroller is
/// the overlay style whatever the "Show scroll bars" setting, so the viewport
/// is normally the full width; when something puts it back on the legacy
/// scroller, the content narrows with the viewport rather than run under it.
struct PopoverScrollContainer<Content: View>: View {
    let horizontalInset: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    @ViewBuilder let content: () -> Content

    /// How much of the scroll view's width its scroller takes, once measured: zero on the overlay scroller.
    @State private var scrollerWidth: CGFloat?

    init(
        horizontalInset: CGFloat = RelayBarPopoverLayout.contentInset,
        topInset: CGFloat = RelayBarPopoverLayout.contentInset,
        bottomInset: CGFloat = RelayBarPopoverLayout.contentInset,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.horizontalInset = horizontalInset
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.content = content
    }

    var body: some View {
        // The container's width, unlike the scroll view's, does not follow the document's.
        GeometryReader { geometry in
            ScrollView(.vertical) {
                content()
                    // Exactly the width offered, whatever a child asks for.
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, horizontalInset)
                    .padding(.top, topInset)
                    .padding(.bottom, bottomInset)
                    // SwiftUI derives the width it offers from the scroller style only when it lays the
                    // scroll view out itself, not when the style changes behind its back.
                    .frame(width: scrollerWidth.map { max(0, geometry.size.width - $0) }, alignment: .topLeading)
                    .background(VerticalScrollingOnly(scrollerWidth: $scrollerWidth))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// Holds the enclosing scroll view to vertical scrolling on the overlay scroller and reports how much of
/// its width the scroller takes.
private struct VerticalScrollingOnly: NSViewRepresentable {
    @Binding var scrollerWidth: CGFloat?

    func makeNSView(context: Context) -> VerticalScrollingOnlyView { VerticalScrollingOnlyView() }

    func updateNSView(_ view: VerticalScrollingOnlyView, context: Context) {
        view.scrollerWidth = $scrollerWidth
        view.apply()
    }
}

final class VerticalScrollingOnlyView: NSView {
    var scrollerWidth: Binding<CGFloat?>?
    private weak var scrollView: NSScrollView?
    private var isWidthReportPending = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self, name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil
        )
        guard window != nil else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferredScrollerStyleDidChange),
            name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil
        )
        apply()
    }

    override func layout() {
        super.layout()
        apply()
    }

    func apply() {
        guard let enclosing = enclosingScrollView else { return }
        if enclosing !== scrollView {
            if let previous = scrollView?.contentView {
                for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                    NotificationCenter.default.removeObserver(self, name: name, object: previous)
                }
            }
            scrollView = enclosing
            let clip = enclosing.contentView
            clip.postsFrameChangedNotifications = true
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipViewFrameDidChange),
                name: NSView.frameDidChangeNotification, object: clip
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipViewBoundsDidChange),
                name: NSView.boundsDidChangeNotification, object: clip
            )
        }
        if enclosing.scrollerStyle != .overlay { enclosing.scrollerStyle = .overlay }
        if enclosing.hasHorizontalScroller { enclosing.hasHorizontalScroller = false }
        if enclosing.horizontalScrollElasticity != .none { enclosing.horizontalScrollElasticity = .none }
        keepAtLeadingEdge()
        reportScrollerWidth()
    }

    /// The document is never wider than the clip view, so its leading edge is the only horizontal position.
    private func keepAtLeadingEdge() {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        guard clip.bounds.origin.x != 0 else { return }
        clip.setBoundsOrigin(NSPoint(x: 0, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The clip view resizes inside AppKit's and SwiftUI's layout passes, where SwiftUI state must not
    /// change, so the width is read and published on the next turn. It is measured against the scroll
    /// view rather than taken from the clip view alone, which keeps a document laid out for one style from
    /// fixing the width it is given under the other.
    private func reportScrollerWidth() {
        guard !isWidthReportPending else { return }
        isWidthReportPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            isWidthReportPending = false
            guard let scrollView, let scrollerWidth else { return }
            let width = max(0, scrollView.frame.width - scrollView.contentView.frame.width)
            if scrollerWidth.wrappedValue != width { scrollerWidth.wrappedValue = width }
        }
    }

    /// A scroller style change, from whatever source, resizes the clip view.
    @objc private func clipViewFrameDidChange(_ notification: Notification) {
        keepAtLeadingEdge()
        reportScrollerWidth()
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        keepAtLeadingEdge()
    }

    /// Each scroll view adopts the new preferred style in its own observer, which may run after this one.
    @objc private func preferredScrollerStyleDidChange(_ notification: Notification) {
        apply()
        Task { @MainActor [weak self] in self?.apply() }
    }
}
