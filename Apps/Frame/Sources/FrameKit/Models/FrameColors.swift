import AppKit
import HouseStyle

/// Frame's names for the shared house palette. Each colour follows the active form and the drawing appearance.
public enum FrameColors {
  public static var paper: NSColor { HousePalette.paper.nsColor }
  public static var panel: NSColor { HousePalette.panel.nsColor }
  public static var stage: NSColor { HousePalette.stage.nsColor }
  public static var card: NSColor { HousePalette.card.nsColor }
  public static var ink: NSColor { HousePalette.ink.nsColor }
  public static var muted: NSColor { HousePalette.muted.nsColor }
  public static var faint: NSColor { HousePalette.faint.nsColor }
  public static var selected: NSColor { HousePalette.selected.nsColor }
  public static var amber: NSColor { HousePalette.amber.nsColor }
  public static var red: NSColor { HousePalette.red.nsColor }
  public static var button: NSColor { HousePalette.button.nsColor }
  public static var buttonText: NSColor { HousePalette.buttonText.nsColor }
  /// Hairlines between columns and above footers.
  public static var line: NSColor { HousePalette.line.nsColor }
  /// The quiet fill behind fields, segmented controls and blocks.
  public static var fill: NSColor { HousePalette.fill.nsColor }
}
