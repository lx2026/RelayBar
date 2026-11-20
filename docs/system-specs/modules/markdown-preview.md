# Markdown Preview

Markdown preview is a safe, read-only state inside the Remote Files window.

## Entry and lifecycle

- Regular files ending in `.md`, `.markdown`, `.mdown`, or `.mkd` are previewable.
- Preview uses the active server snapshot and downloads to a private temporary directory.
- The service rejects a known size above 2 MiB before transfer and aborts a transfer that crosses the same limit.
- The decoder reads at most 2 MiB plus one byte, accepts UTF-8 with an optional BOM, and rejects NULs.
- Parsing runs away from the main UI path. Preview cancellation is forwarded into the detached worker, and the compatibility pass checks cancellation throughout its line, character, and lookahead loops.
- A generation token prevents a canceled or superseded preview from publishing stale state.
- Published preview state keeps the rendered page (its HTML, plain text and the text of each code block) and its private-reference token. The original and compatibility-transformed Markdown strings are not retained.
- The preview's web view keeps a copy of the page so it can show it again if WebKit's content process ends, at most three times for one document; after that the preview stays blank.
- Leaving preview or closing the window removes its temporary directory and closes the web view.

## Rendering

The page is produced by the shared `MarkdownRendering` library, which Frame uses too, so a document looks the same in both apps apart from Frame's palette and its loading of images.

- Away from the main thread, the library runs the Obsidian compatibility pass, parses the result with swift-cmark 0.8.0's cmark-gfm in safe mode (CommonMark plus GFM autolinks, strikethrough, tasks and tables), and then rewrites the parsed tree: it writes code blocks, typeset math and table containers itself and removes anything else that would load. The result is one static HTML page with one stylesheet and no script.
- The macOS and iOS libraries share the HTML writer, syntax colours and font traits, and the Core Graphics bitmap and PNG encoder. Equations use transparent backgrounds and black ink at two pixels per point with the pixel dimensions rounded up. The page preserves the scaled descent for inline alignment and inverts the ink in dark appearance. On iOS, SwiftMath lays out an unattached label on the main actor, then the renderer draws its display list at the bounded output size.
- RelayBar shows that page in a web view; WebKit lays it out and draws only what is visible. Measured on this Mac, a dense 20 KB note is ready in about 0.04 s and a 200 KB document in about 0.3 s, where the previous native view took 0.9 s and 7 s.
- Text is selectable across the whole document, in a centred reading column capped at 680 points with 32-point side padding and additional bottom breathing room.
- One stylesheet serves light and dark appearance. Normal prose sits on the text background; callouts and blockquotes are quiet tinted containers; inline code and code blocks keep their own surfaces.
- Code blocks show their language, never wrap (they scroll sideways), and have a **Copy** control that puts the block's exact text on the pasteboard and shows a tick for about a second. Unlabelled code and unsupported languages are plain and monospaced.
- Tables keep the column alignment the document gives, wrap cell text to fit the reading column, and scroll sideways only when a cell cannot wrap.
- Headings, lists, tables and task checkboxes are ordinary HTML elements, so assistive technology reads them through WebKit. A plain bullet in a list that also has tasks is a bullet, not an empty checkbox.
- HighlighterSwift 3.1.0 highlights only explicit, supported languages, only when a code block is at most 64 KiB, and for at most 128 labelled code blocks per document; each block is highlighted once for each appearance. Overflow code remains plain and readable; Mermaid keeps its source-only safety label independently of that budget.
- SwiftMath 1.7.3 typesets at most 256 inline or display formulas per document and at most 4,096 characters per formula, as images embedded in the page. An inline formula sits on the text baseline. Display formulae keep their intrinsic reading size, are never enlarged, and shrink only when needed to fit the reading column or the 180-point display-height limit.
- A formula is typeset only if it parses, nests no deeper than 32 levels, and uses no colour command (`\color`, `\textcolor`, `\colorbox`): SwiftMath's typesetter stops the process on some lists its parser accepts, and both recurse as deeply as a formula nests. Refused, invalid and overflow formulas remain selectable source.
- Xcode app builds keep Highlighter's formatter plus the `github` and `github-dark` themes, and SwiftMath's default Latin Modern font, metrics, and license files. Unused highlight themes, alternate math fonts, and a package-development conversion script are removed from the generated app bundle.

## Obsidian reading compatibility

- Frontmatter becomes a compact properties callout with one visual line per property. Common indented list and block-scalar values are grouped with their top-level key rather than appearing as stray rows.
- Callout markers become labelled callout content with distinct title and body lines. Built-in types and aliases use a stable visual symbol; custom types fall back to the note treatment.
- Obsidian `+` and `-` fold markers are removed and their bodies remain expanded in the continuous read-only view, so remote text is never hidden. Nested callouts preserve their blockquote depth.
- Highlight markers are removed while their emphasis is preserved.
- A single non-space character in an Obsidian task marker is normalized to the completed GFM task state for rendering, including in normally indented nested lists. The downloaded source retains its original marker.
- Obsidian comments are hidden outside code.
- Up to 1,024 named definitions or Obsidian inline footnotes become superscript references and a numbered section at the document end. Named definitions support Obsidian's two-space or tab-indented continuation lines and blank-separated continuation paragraphs; overflow definitions and inline notes remain readable source.
- Up to 2,048 combined wiki links, tags, and footnote links remain visibly labelled but are not resolved. Relative Markdown links are also kept inert and explain that RelayBar does not resolve remote vault content when clicked.
- Valid inline tags preserve case, nested `/` paths, Unicode letters, and emoji. Numeric-only tags, leading, trailing, or doubled `/`, URL and CSS fragments, escapes, and tag-looking text inside code remain literal. Clicking a rendered tag explains that RelayBar does not index or search the remote vault.
- Wiki aliases and embed size hints using Obsidian's table-safe `\|` delimiter are parsed without treating the escape as part of the remote target. Embed dimensions remain inert metadata and are not applied.
- Valid Obsidian block identifiers at the end of prose, list, or quote lines are hidden in reading mode. Escaped identifiers and identifier-looking text inside code remain literal; block references inside wiki-link targets remain inert labelled links.
- Up to 512 Obsidian embeds or Markdown images become explicit not-loaded states. Inline, full-reference, collapsed-reference, and shortcut-reference images keep their author-provided alt text visible and selectable; Obsidian `|width` and `|widthxheight` hints, including `\|` inside tables, remain inert and are omitted from the visible label. Undefined references remain literal, and overflow links, images, and embeds remain readable source.
- Inline and display math become private math-image references consumed only by RelayBar's renderer.
- Inline code—including code spans that cross a soft line break—plus fenced and indented code is not rewritten, including when the code is nested inside a blockquote, callout, or list container.

## Active-content boundary

- Raw HTML never executes. HTML-looking spans are escaped before parsing so active tags such as `script` and `style` remain selectable literal text even when a tag spans lines or appears inside a Markdown link label; valid HTTP, HTTPS, mail, and email angle autolinks keep their link behavior. The parser then runs in safe mode, which leaves out any raw HTML and any `javascript:`, `vbscript:`, `file:` or `data:` destination that still reached it, and the renderer empties every remaining `data:` link.
- The web view is a second, independent barrier. It runs no page script, keeps no data, has no scheme handler, user script or message handler, and loads the page under the policy `default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'`. It allows one navigation, the load of the page RelayBar built, and cancels every other: link clicks, drops, reloads and new windows. Its context menu has no item that navigates, opens a window or downloads, and no Copy Link, which would copy a reference; Look Up, Translate, Search, Speech and Share remain and act on the selected text as they do in any macOS text view. Tests give the view markup the renderer would never write (script, event handlers, remote images, stylesheets, fonts, frames, media, a refresh) and observe that nothing runs and a loopback server receives no connection.
- Normal Markdown images and Obsidian embeds never fetch network or local content. Inline and reference-style Markdown images become compact not-loaded text with their alt label instead of an empty image tile. An image the compatibility pass did not recognise is replaced the same way in the parsed tree, including inside table cells.
- Mermaid and other diagrams remain selectable source and never execute.
- Only clicked absolute HTTP, HTTPS, and email URLs without credentials or raw/percent-decoded control characters reach macOS.
- Relative Markdown references are handled locally with a remote-vault explanation and never fetched. Absolute local paths plus file, data, JavaScript, unknown, and credential-bearing URLs are blocked.
- The page carries no link address. Each link is a reference, carrying the preview's token, into the list of destinations the document wrote; a click is looked up there and judged by the link policy exactly as written, so a leading `/` or `../` and a malformed address are seen as they are. WebKit starts connecting to a clicked link's server before it asks whether the link may be followed, so a page that named servers would contact one on a click even when the policy refuses the link. A reference gives it nothing to connect to, and a test with a loopback server observes no connection. A clicked address that is not one of the page's references is refused.
- Private wiki, tag, footnote, math and Copy URLs carry a random per-preview capability token. Remote-authored private-looking URLs do not have that token, remain inert, and never bypass document enrichment limits; a forged math link is not typeset and a forged Copy link copies nothing.
- The Remote Files window's own keys (Left, Right, Escape, Command-Delete and Command-[) behave the same whether or not the preview has the keyboard focus. Other keys reach the page: scrolling, Command-C and Command-A.
- Markdown editing and remote writes are absent.

This describes the source after Task 063, which has not replaced the installed build; the installed 1.6.0 draws Markdown natively with MarkdownUI. See [Security boundaries](../shared/security-boundaries.md), [Task 063 verification](../../verification/063-one-markdown-renderer.md) and [Task 002 verification](../../verification/002-read-only-markdown.md).
