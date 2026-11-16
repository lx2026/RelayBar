import SwiftUI

enum RelayBarPopoverLayout {
    static let width: CGFloat = 380
    static let height: CGFloat = 440
    static let contentInset: CGFloat = 16

    static func contentWidth(
        for viewportWidth: CGFloat,
        horizontalInset: CGFloat = contentInset
    ) -> CGFloat {
        max(0, viewportWidth - (horizontalInset * 2))
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
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
