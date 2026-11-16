import AppKit

/// Every text/surface pair resolves together, including live appearance changes.
public enum FrameColors {
  public static let paper = adaptive(0xf8f8f6, 0x242526)
  public static let panel = adaptive(0xf0f0ed, 0x292a2b)
  public static let stage = adaptive(0xe4e5e1, 0x17191a)
  public static let ink = adaptive(0x252823, 0xeeefeb)
  public static let muted = adaptive(0x585d54, 0xb5b9b0)
  public static let selected = adaptive(0xd4d7cf, 0x3d403b)
  public static let amber = adaptive(0x805000, 0xf1bd62)
  public static let button = adaptive(0x30352d, 0xe2e6dc)
  public static let buttonText = adaptive(0xffffff, 0x252823)

  private static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
      let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                     green: CGFloat((value >> 8) & 255) / 255,
                     blue: CGFloat(value & 255) / 255, alpha: 1)
    }
  }
}
