import AppKit
import WebKit

public enum DocumentFocus {
  @MainActor public static func ownsKeys(_ responder: NSResponder?) -> Bool {
    var view = responder as? NSView
    while let current = view {
      if current is WKWebView { return true }
      view = current.superview
    }
    return false
  }
}
