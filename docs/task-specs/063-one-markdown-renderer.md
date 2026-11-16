# One Markdown renderer

Status: Implemented — 2026-11-14. The automated gate passes and two independent reviews are answered. Signed local builds were installed and launched for user testing on 2026-11-14; native interaction and live-host acceptance remain open. Evidence: [verification record](../verification/063-one-markdown-renderer.md).

## Outcome

Markdown looks the same in RelayBar and Frame and opens quickly in both: RelayBar's reading design and Obsidian compatibility, drawn by WebKit. One shared renderer turns Markdown into a static HTML page; each app shows that page in its own web view under its own rules.

Measured before this task, on a dense 20 KB note and a 200 KB document: RelayBar's native view needed 0.9 s and 7.2 s to first layout and held 185 MB and 1.3 GB; Frame's WebKit view needed under 0.02 s and 0.07 s but showed no highlighting, math, footnotes or Obsidian syntax, lost right-aligned columns, drew frontmatter as a heading and dropped HTML blocks silently.

## Delivery Boundary

- The page the renderer produces contains no script and needs none. Raw HTML in a document stays literal text in both apps.
- RelayBar's Markdown boundary is unchanged in effect: nothing a remote document says can run, fetch or navigate. Its web view runs no page script and loads nothing from the network or the remote host; images stay "not loaded"; links go through the existing link policy.
- Frame keeps loading images and following links to neighbouring documents exactly as it does now.
- Obsidian behaviour (frontmatter, callouts, comments, highlights, tasks, footnotes, wiki links, tags, embeds, block identifiers, math) and every limit in the Markdown preview spec are kept; the compatibility pass moves, it is not rewritten.
- Excluded: Mermaid rendering, an allow-list for inline HTML such as `<kbd>` or `<details>`, resolving wiki links, find-in-page, editing. No release, version or build-number change.

## Work

1. **Shared renderer.** A `MarkdownRendering` library in the shared package: the Obsidian compatibility pass (moved from RelayBar), GitHub-flavoured parsing in safe mode, code blocks with a language label, a Copy link and highlighting, typeset math as images, tables that keep their column alignment and scroll sideways, task lists, and one stylesheet for light and dark. An option chooses whether ordinary Markdown images are passed through (Frame) or replaced by a "not loaded" label (RelayBar).
2. **Frame.** Markdown documents go through the shared renderer. Documents above 2 MiB skip the Obsidian pass, highlighting and math. The app bundle carries the highlighter's and the math fonts' resources and their licences.
3. **RelayBar.** The Markdown preview becomes a web view that shows the shared page with page script disabled and a content policy that allows no network, no remote resource and no navigation. Links, wiki links, tags, footnotes and relative references keep their current decisions and messages; the page carries references rather than addresses, so a click contacts nothing. Keyboard handling in the Remote Files window is unchanged whether or not the preview has the focus. MarkdownUI and the code that existed only to drive it are removed.
4. Update the Markdown preview, security boundaries, Frame viewer and build specs, and record before-and-after renders and timings.

## Acceptance

- The same document renders with the same structure and styling in both apps, in light and dark, with only the palette and image handling differing; renders of the two reference documents are stored with the verification record.
- Renderer tests: no `<script>`, event handler, `style` element or unsafe URL from a document reaches the page; raw HTML appears as text; a forged private link without the preview's token is inert; highlighting, math and their fallbacks; table alignment; a plain bullet beside task items has no checkbox; unlabelled code is monospaced; every existing compatibility test passes unchanged in substance.
- RelayBar, in a real web view: a document's script does not run, nothing is requested from the network, a link click reaches the link policy and never navigates the view, Copy puts the block's text on the pasteboard.
- Frame, in a real web view: images and document links still work; the existing document tests pass.
- A 20 KB note is laid out in under 0.1 s and a 200 KB document in under 0.5 s in both apps, measured the same way as the figures above.
- Frame's assembled app bundle contains the resource bundles the renderer needs.
- `scripts/test.sh` passes with warnings as errors; both apps build, including RelayBar's Xcode target; `git diff --check` passes.
