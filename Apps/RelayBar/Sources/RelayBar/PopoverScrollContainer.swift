import SwiftUI

enum RelayBarPopoverLayout {
    static let width: CGFloat = 380
    static let height: CGFloat = 440
    static let contentInset: CGFloat = 16

    static let headerHeight: CGFloat = 56
    static let cardCornerRadius: CGFloat = 12
    static let iconButtonSize: CGFloat = 28
    /// Resting fill of neutral icon buttons.
    static let neutralFill = Color.primary.opacity(0.07)

    static func contentWidth(
        for viewportWidth: CGFloat,
        horizontalInset: CGFloat = contentInset
    ) -> CGFloat {
        max(0, viewportWidth - (horizontalInset * 2))
    }
}

/// The popover's one icon-button shape. Only the action a person most likely
/// wants next is emphasised, and never while it is unavailable.
struct PopoverIconButtonStyle: ButtonStyle {
    var isEmphasized = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, isEmphasized: isEmphasized)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let isEmphasized: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let emphasized = isEmphasized && isEnabled
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(emphasized ? Color.white : Color.primary.opacity(isEnabled ? 0.8 : 0.3))
                .frame(
                    width: RelayBarPopoverLayout.iconButtonSize,
                    height: RelayBarPopoverLayout.iconButtonSize
                )
                .background(
                    Circle().fill(emphasized ? Color.accentColor : RelayBarPopoverLayout.neutralFill)
                )
                .contentShape(Circle())
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}

/// Uppercase labels above a group of settings, fields or sidebar rows.
struct SectionLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }
}

extension View {
    /// Gives an actions menu the same shape and hit target as the icon buttons.
    func popoverIconMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(PopoverIconButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
    }

    /// The raised card behind tunnel rows, settings groups and rule editors.
    func popoverCard() -> some View {
        let shape = RoundedRectangle(
            cornerRadius: RelayBarPopoverLayout.cardCornerRadius,
            style: .continuous
        )
        return background(shape.fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(shape.stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

/// A vertical popover scroller whose document width is always derived from
/// the viewport. Focus rings and intrinsically wide controls therefore cannot
/// create a horizontal scroll range or shift the document away from its
/// leading inset.
struct PopoverScrollContainer<Content: View>: View {
    let fillsViewport: Bool
    let horizontalInset: CGFloat
    let verticalInset: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        fillsViewport: Bool = false,
        horizontalInset: CGFloat = RelayBarPopoverLayout.contentInset,
        verticalInset: CGFloat = RelayBarPopoverLayout.contentInset,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.fillsViewport = fillsViewport
        self.horizontalInset = horizontalInset
        self.verticalInset = verticalInset
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = RelayBarPopoverLayout.contentWidth(
                for: geometry.size.width,
                horizontalInset: horizontalInset
            )
            let minimumContentHeight = max(
                0,
                geometry.size.height - (verticalInset * 2)
            )

            ScrollView(.vertical) {
                content()
                    .frame(width: contentWidth, alignment: .topLeading)
                    .frame(
                        minHeight: fillsViewport ? minimumContentHeight : nil,
                        alignment: .topLeading
                    )
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, verticalInset)
                    // An always-visible scroller narrows the scroll view; keep
                    // the leading inset rather than centring the overflow.
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
