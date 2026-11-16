import AppKit

/// Remembers that someone was working in a text control. If that control then loses the focus without a
/// click in the window or a key that leaves it, the next keystroke was still meant for it, so it must not
/// run a single-key shortcut such as Delete.
public struct TypingGuard: Equatable, Sendable {
  /// The text control that was being typed in.
  public enum Field: Equatable, Sendable {
    case search
    case other
  }

  /// What to do with a keystroke.
  public enum Outcome: Equatable, Sendable {
    /// Handle the key as usual.
    case pass
    /// Drop the key. `refocusSearch` is true when the control that lost the focus was the search field.
    case swallow(refocusSearch: Bool)
  }

  /// Names Prompt Search's field, so typing in it can be told from typing in any other text control.
  public static let searchFieldIdentifier = NSUserInterfaceItemIdentifier("FramePromptSearch")
  private static let tab: UInt16 = 48
  /// Return, keypad Enter and Escape end editing in an ordinary field. The search field keeps the focus.
  private static let endingKeys: Set<UInt16> = [36, 76, 53]
  private var typingIn: Field?

  public init() {}

  /// A pointer press in the window: the person chose where the focus goes.
  public mutating func pointerDown() {
    typingIn = nil
  }

  /// Records a keystroke. `focused` is the text control being edited when the key arrives, if any, and
  /// `wouldAct` says whether the key would run a shortcut on the selection.
  ///
  /// Every key that arrives while a text control has the focus, including editing commands such as
  /// Command-A and Command-V, keeps the guard on. Only Tab, or Return, Enter or Escape in a field other
  /// than search, releases it, because those are how someone leaves a field from the keyboard.
  public mutating func key(code: UInt16, focused: Field?, wouldAct: Bool) -> Outcome {
    if let focused {
      let leaves = code == Self.tab || (focused == .other && Self.endingKeys.contains(code))
      typingIn = leaves ? nil : focused
      return .pass
    }
    guard let typingIn, wouldAct else { return .pass }
    return .swallow(refocusSearch: typingIn == .search)
  }

  /// True when the responder is a text control being edited: an editable text view, which includes a field
  /// editor, or a text field.
  @MainActor public static func isEditingText(_ responder: NSResponder?) -> Bool {
    (responder as? NSTextView)?.isEditable == true || responder is NSTextField
  }

  /// The text control being edited, if any. A field editor stands for the field it edits.
  @MainActor public static func field(for responder: NSResponder?) -> Field? {
    guard isEditingText(responder) else { return nil }
    let editor = responder as? NSTextView
    let edited = editor?.isFieldEditor == true ? editor?.delegate as? NSView : nil
    let control = edited ?? responder as? NSView
    return control?.identifier == searchFieldIdentifier ? .search : .other
  }
}
