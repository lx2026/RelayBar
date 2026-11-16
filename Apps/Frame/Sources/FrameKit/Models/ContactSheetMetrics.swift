import Foundation

/// Shared sizing rules for native cells, keyboard rows, and bounded Retina requests.
public struct ContactSheetMetrics: Equatable, Sendable {
  public static let thumbnailRange = 100.0...360.0
  public static let defaultThumbnailWidth = 160.0
  public static let inset = 16.0
  public static let columnGap = 12.0
  public static let rowGap = 16.0
  public let width: Double
  public var height: Double { width + 24 }
  public let columns: Int

  public static func normalizedWidth(_ value: Double) -> Double {
    guard value.isFinite else { return defaultThumbnailWidth }
    return min(thumbnailRange.upperBound, max(thumbnailRange.lowerBound, value))
  }

  public init(preferredWidth: Double, viewportWidth: Double) {
    let available = max(1, viewportWidth.isFinite ? min(100_000, viewportWidth) - Self.inset * 2 : 1)
    let preferred = Self.normalizedWidth(preferredWidth)
    // A small fit adjustment avoids a nearly half-empty row at compact widths.
    // Deliberately large thumbnails still produce one column.
    columns = max(1, Int((available + Self.columnGap) / (preferred * 0.875 + Self.columnGap)))
    width = min(preferred, (available - Double(columns - 1) * Self.columnGap) / Double(columns))
  }

  public func visibleRows(in height: Double) -> Int {
    guard height.isFinite else { return 1 }
    return max(1, Int(min(100_000, max(0, height)) / (self.height + Self.rowGap)))
  }

  public func thumbnailPixels(scale: Double) -> Int {
    let scale = scale.isFinite ? min(3, max(1, scale)) : 2
    return min(1_152, max(128, Int(ceil((width - 6) * scale / 128)) * 128))
  }

  public static func previewPixels(width: Double, height: Double, scale: Double) -> Int {
    let longest = max(width, height)
    guard longest.isFinite, scale.isFinite else { return 640 }
    return min(4_096, max(128, Int(ceil(min(4_096, max(1, longest) * max(1, scale)) / 128)) * 128))
  }
}
