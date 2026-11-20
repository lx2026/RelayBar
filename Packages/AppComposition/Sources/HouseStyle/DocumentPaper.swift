/// The reader column's paper as CSS colours, light and dark, for the form in use when it was read.
public struct DocumentPaper: Equatable, Sendable {
  public let light: String
  public let dark: String

  @MainActor public init(form: HouseForm) {
    light = HousePalette.paper.css(in: form, dark: false)
    dark = HousePalette.paper.css(in: form, dark: true)
  }

  /// The paper of the active form.
  @MainActor public static var current: DocumentPaper { DocumentPaper(form: HousePalette.form) }
  public var palette: String {
    """
    :root{--frame-page:1;--md-bg:\(light);--md-text:#242821;--md-secondary:rgba(36,40,33,.6);--md-link:#3c6a42;--md-accent-rgb:60,106,66}
    @media(prefers-color-scheme:dark){:root{--md-bg:\(dark);--md-text:#e3e6df;--md-secondary:rgba(227,230,223,.6);--md-link:#a2c6a2;--md-accent-rgb:98,148,104}}
    article{padding-top:16px}
    """
  }
}
