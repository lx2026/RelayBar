import AppKit

public enum MediaKeyAction: Equatable {
  case delete, previous, next, toggleSelection, favorite

  public static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                             viewing: Bool, editingText: Bool, selecting: Bool = false) -> Self? {
    guard !editingText else { return nil }
    // Arrow events can include numericPad/function; neither is a user modifier.
    let modifiers = modifiers.intersection([.command, .shift, .option, .control])
    if [51, 117].contains(keyCode), modifiers.isEmpty || modifiers == .command { return .delete }
    if keyCode == 49, selecting, modifiers.isEmpty { return .toggleSelection }
    if keyCode == 3, modifiers.isEmpty { return .favorite }
    guard viewing, modifiers.isEmpty else { return nil }
    switch keyCode {
    case 123: return .previous
    case 124: return .next
    default: return nil
    }
  }
}
