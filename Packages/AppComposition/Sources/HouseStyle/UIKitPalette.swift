#if os(iOS)
import UIKit

// The standard Mac appearance in sRGB. UIKit's semantic colours use different surfaces and alphas.
enum StandardColors {
    static let windowBackgroundColor = pair(0xffffff, 0x1e1e1e)
    static let underPageBackgroundColor = pair(0xf6f6f6, 0x282828)
    static let controlBackgroundColor = windowBackgroundColor
    static let unemphasizedSelectedContentBackgroundColor = pair(0xdcdcdc, 0x464646)
    static let labelColor = pair(0, 0xffffff, 216 / 255, 216 / 255)
    static let secondaryLabelColor = pair(0, 0xffffff, 127 / 255, 140 / 255)
    static let tertiaryLabelColor = pair(0, 0xffffff, 66 / 255, 63 / 255)
    static let separatorColor = pair(0, 0xffffff, 0.1, 0.12)
    static let systemGreen = pair(0x34c759, 0x30d158)
    static let systemOrange = pair(0xff8d28, 0xff9230)
    static let systemRed = pair(0xff383c, 0xff4245)

    private static func pair(_ light: UInt32, _ dark: UInt32, _ lightAlpha: CGFloat = 1, _ darkAlpha: CGFloat = 1) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? HouseToken.srgb(dark, alpha: darkAlpha)
                : HouseToken.srgb(light, alpha: lightAlpha)
        }
    }
}

// All component reads follow resolution to one of the sRGB colours constructed here.
extension UIColor {
    convenience init(srgbRed: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(cgColor: CGColor(srgbRed: srgbRed, green: green, blue: blue, alpha: alpha))
    }

    var redComponent: CGFloat { cgColor.components![0] }
    var greenComponent: CGFloat { cgColor.components![1] }
    var blueComponent: CGFloat { cgColor.components![2] }
    var alphaComponent: CGFloat { cgColor.alpha }
}
#endif
