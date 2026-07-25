# Markdown Preview

Markdown preview is a safe, read-only state inside the Remote Files window.

## Entry and lifecycle

- Regular files ending in `.md`, `.markdown`, `.mdown`, or `.mkd` are previewable.
- Preview uses the active server snapshot and downloads to a private temporary directory.
- The service rejects a known size above 2 MiB before transfer and aborts a transfer that crosses the same limit.
- The decoder reads at most 2 MiB plus one byte, accepts UTF-8 with an optional BOM, and rejects NULs.
- Parsing runs away from the main UI path. Preview cancellation is forwarded into the detached worker, and the compatibility pass checks cancellation throughout its line, character, and lookahead loops.
- A generation token prevents a canceled or superseded preview from publishing stale state.
- Published preview state keeps the parsed document and its private-reference token without additionally retaining the original and compatibility-transformed Markdown strings.
- Leaving preview or closing the window removes its temporary directory.

## Rendering

- MarkdownUI 2.4.1 parses CommonMark plus GFM autolinks, strikethrough, tasks, and tables through swift-cmark 0.8.0's cmark-gfm products.
- Text is selectable in a centered reading column.
- The theme adds quiet callout/blockquote containers and code blocks with language, intrinsic-width horizontal overflow instead of line wrapping, and a local **Copy** action.
- Wide tables scroll horizontally inside the reading column. Headings carry accessibility header traits and task markers announce completion state.
- HighlighterSwift 3.1.0 highlights only explicit, supported languages, only when a code block is at most 64 KiB, and for at most 128 labelled code blocks per document. Overflow code remains plain and readable; Mermaid keeps its source-only safety label independently of that budget.
- SwiftMath 1.7.3 validates and renders at most 256 inline or display formulas per document and at most 4,096 characters per formula. Display formulae keep their intrinsic reading size, are never enlarged, and shrink only when needed to fit the reading column or 180-point display-height limit. Invalid, rejected, and overflow formulas remain selectable source.
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

- Raw HTML never executes. HTML-looking spans are escaped before parsing so active tags such as `script` and `style` remain selectable literal text even when a tag spans lines or appears inside a Markdown link label; valid HTTP, HTTPS, mail, and email angle autolinks keep their link behavior.
- Normal Markdown images and Obsidian embeds never fetch network or local content. Inline and reference-style Markdown images become compact not-loaded text with their alt label instead of an empty image tile.
- Mermaid and other diagrams remain selectable source and never execute.
- Only clicked absolute HTTP, HTTPS, and email URLs without credentials or raw/percent-decoded control characters reach macOS.
- Relative Markdown references are handled locally with a remote-vault explanation and never fetched. Absolute local paths plus file, data, JavaScript, unknown, and credential-bearing URLs are blocked.
- Private wiki, tag, footnote, and math URLs carry a random per-preview capability token. Remote-authored private-looking URLs do not have that token, remain inert, and never bypass document enrichment limits.
- Markdown editing and remote writes are absent.

See [Security boundaries](../shared/security-boundaries.md) and [Task 002 verification](../../verification/002-read-only-markdown.md).
