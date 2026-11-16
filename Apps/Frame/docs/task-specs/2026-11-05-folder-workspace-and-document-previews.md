# Folder workspace and document previews

Task status: Delivered and installed; native verification complete, extended acceptance coverage recorded below\
Design status: Accepted for implementation on 2026-11-07\
Created: 2026-11-05

## Outcome

Open a folder of agent-generated work, navigate its files, and see Markdown, HTML, images and video in a large preview. The filesystem is the source of truth. Agents and existing editors write files; Frame displays them without importing or editing them.

This expands Frame into a folder viewer, not a note-taking app or IDE. Keep the photo-review work that already functions well without making every document behave like a photo.

## First delivery

| File | Preview |
| --- | --- |
| `.md`, `.markdown` | Rendered headings, lists, tables, task lists, fenced code, links and local images. Task checkboxes are display-only. |
| `.html`, `.htm` | Rendered page, including local styles, assets and JavaScript for interactive visualizations. No server or build step. |
| JPEG, PNG | Existing zoom, full-screen, metadata and image-review behavior. |
| MP4, MOV, M4V | Existing native video playback. MP4 is already supported; this work integrates it into the file workspace. |
| Other files | Remain discoverable in the tree. Reuse bounded plain-text/JSON preview where possible; otherwise one “No preview” state and Open in Default App. No new format-specific engines. |

**Confirmed scope: both local folders and RelayBar remote folders in the first delivery.** Open either from the same chooser and select Markdown or HTML in the tree. Frame renders both on the Mac; the remote host doesn't need a web server or renderer.

For a RelayBar folder, listing files transfers names and attributes, not document contents. On selection, fetch the document and only the in-folder resources its preview requests (such as images, CSS, scripts or chart data). Resolve paths relative to the requesting file, within the opened root. Reuse the [existing bridge and session-only cache](../system-specs/remote-assets.md); bound requests and total bytes per preview, cancel stale loads and never add to RelayBar history.

## Workspace design

Two layouts, one selection: **Preview** and **Grid**. Preview is the default for new folders; existing folders retain their saved layout. Switching layouts keeps the active file and browsing position.

```text
┌ Open…    project / report.html                  Preview | Grid    Info ┐
│ project                  │                                            │
│   notes.md               │                                            │
│   report.html  ←         │           LARGE RENDERED PREVIEW             │
│   demo.mp4               │                                            │
│ ▾ images                 │                                            │
│     result.png           │                                            │
│     result.prompt.json   │                                            │
└──────────────────────────┴────────────────────────────────────────────┘
```

- The sidebar contains **folders and files**, retaining real nesting. Expand a directory on demand; single-click a file to preview it. No separate file dropdown or double-click requirement.
- Preview gets the remaining window, not a small pane beside an always-visible contact sheet. The sidebar is resizable and collapsible. Full screen stays available.
- Info is optional and resizable. Documents start with it closed; media retains the user's metadata-panel preference. No empty metadata panel reserves space.
- Grid retains adjustable thumbnails, its resizable attached preview, selection and batch actions. Documents get simple filename/type cards, not background browser renders. The sidebar still opens documents directly.
- Show the current filename/path once. Put contextual actions in menus or the relevant viewer controls. No onboarding subtitle, “read-only” badge, permanent format explanation or document-wide photo-action footer.

### Main flows

1. **Review work:** Open folder → choose `report.html` in the tree → read/interact in the large preview → choose `notes.md` → read rendered Markdown.
2. **Follow an agent:** Keep a file open → agent saves or atomically replaces it → preview refreshes in place. New files appear in the affected tree branch without reopening the folder.
3. **Review media:** Choose an image/video directly, or switch to Grid → browse thumbnails → enlarge, favorite-and-next or batch select as today.

## Preview behavior

The offline-network requirement below was superseded on 2026-11-07 by explicit approval to allow online HTML resources. See [HTML in both apps](2026-11-07-html-preview-in-both-apps.md).

- Markdown links to supported files inside the opened root navigate within Frame; anchors scroll within the document. User-clicked web links open the default browser. Back/Forward restores document and scroll position after link navigation.
- Resolve relative Markdown images and HTML dependencies from the document's directory, bounded by the opened root. Nested paths and filenames with spaces must work.
- HTML preserves its own styling; do not force dark-mode colors onto authored pages. Frame chrome follows macOS appearance; Markdown uses a readable light/dark theme.
- HTML supports inline/local scripts, sliders, canvas and local data. It is not a development server: no npm, shell commands, native application bridge, automatic downloads or source-file writes. Browser DOM state may change; files do not.
- No automatic external network access from the page, including CDN scripts, fonts, external fetch, WebSocket or frames. Relative requests for in-root resources work for either source. Only Frame talks to RelayBar; the page gets neither SSH access nor bridge commands. Local previews work offline. If a resource is blocked or unavailable, keep the page visible with one concise indicator.
- Use an ephemeral web data store; do not introduce persistent website storage or media caches. This does not mean the OS never writes temporary renderer data.
- File access must not escape the opened root through absolute paths, traversal or symlinks. A navigation delegate alone is not a complete subresource/network boundary; prove the containment approach in the renderer prototype before integration.
- Handle renderer failures in the preview only; the file tree must stay usable. Do not silently truncate rendered documents. Initial proposed text-document limit: 10 MiB, checked before parsing, with an explicit fallback for larger files.

Candidate engine: WKWebView for HTML and a bundled Markdown parser/theme, with no CDN dependencies. Apple's [local-file loading API](https://developer.apple.com/documentation/webkit/wkwebview/loadfileurl(_:allowingreadaccessto:)) provides an explicit read-access scope; its [nonpersistent data store](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/nonpersistent()) keeps website data in memory. These are building blocks, not evidence that the proposed containment policy is already implemented.

## Live updates and performance

- Watch local directory changes; coalesce save bursts and tolerate atomic replacements. Reconcile affected directories, not a full recursive scan on each event. Refresh remains available as recovery.
- For RelayBar, revalidate the visible document and its loaded dependencies with bounded, batched metadata checks while the preview is active. Refetch changed files only; no recursive polling or remote watcher installation. On disconnect, retain the last good preview and allow Retry. Refresh also reconciles the visible directory.
- Preserve scroll when possible, selection, expanded folders and surrounding grid position. HTML JavaScript state can reset on reload; retaining arbitrary application state is out of scope.
- Keep the last good preview during an incomplete write. If the file is actually removed, show “File missing” in place; never select an unrelated file automatically because an agent rewrote the directory.
- One active document renderer, no web view per tree row/card and no eager document thumbnails. Parse off the main thread, cancel stale loads and release the previous renderer/player when switching file kinds.
- Keep existing bounded image/video caches, incremental grid updates and session-only remote storage. Tree expansion must not fetch originals or render every file.

## Existing behavior and grouping

- Keep existing catalog identities, favorites, folder bookmarks, resizing, media shortcuts, batch selection and file operations. Do not rewrite the catalog or replace the established image/video pipeline.
- Proposed grouping rule: supported documents become primary items, just as supported images/videos already are. `result.png`, `result.md` and `result.html` are independently accessible and actionable; they must not disappear into a companion disclosure or be silently deleted with the image. Existing media owners still claim non-primary companions such as `result.prompt.json` and `result.qqq.txt` by the longest-prefix rule; adding a document must not create a new ownership tie. Frame and the RelayBar broker must agree on ownership before performing grouped actions.
- A document's CSS, JavaScript, images and linked files are dependencies, not automatically owned companions. Delete/Archive/Export acts on the document itself, not its references. Export is a file copy, not a self-contained website package; shared assets must never be removed with a document.
- List companion files under their real folder too. Reading a companion does not mean selecting its entire group for deletion. Group actions remain on the primary item; do not make individual companion deletion a new implicit behavior in this delivery.
- Keyboard handling becomes focus-aware: arrows navigate the tree when it has focus and scroll/interact inside documents. Preserve Left/Right and F/heart favorite-and-next for media review. HTML inputs, sliders and contenteditable fields must never trigger file Delete, selection or favorite shortcuts.
- Existing deletion semantics remain: local Trash/Undo; permanent remote Delete without confirmation; Archive separate. Rendered HTML has no route to these commands. Frame still never writes RelayBar history.

## Work

1. Review this layout and scope; produce lightweight Markdown/HTML/media mock states before changing the application shell.
2. Prototype Markdown and interactive HTML using the same fixtures through local and RelayBar sources. Verify relative assets, root containment and external network blocking; extend the bridge only where its existing authorized reads are insufficient.
3. Generalize the item/format model and preview dispatch incrementally. Current touchpoints: `PhotoItem`, `FileScanner`, `FolderSidebar`, `MainWorkspace`, `LibraryStore` and `MediaKeyboardShortcuts`. Keep identity and grouping independent from renderer choice; no plugin framework or wholesale rewrite.
4. Add the file tree, large Preview layout, optional inspector and link navigation; reuse Grid and native media viewers.
5. Add coalesced filesystem updates, dependency invalidation and focus-aware keyboard routing.
6. Run mixed-folder and existing photo/remote regressions, capture native screenshots, then update current-state docs only for verified delivery.

Implementation and verification: [document workspace](../system-specs/document-workspace.md), [test/install evidence and native screenshots](../system-specs/verification-2026-11-07-documents.md). Frame 0.1.0/14 and RelayBar 1.6.0/18 are installed and running. Local and real-host document checks passed; unchecked items below retain their broader stress/fault requirements.

## Acceptance

- [ ] Browse the same nested fixture from a local folder and a RelayBar folder: Markdown with a relative image/link, HTML with sibling CSS/JS/data, images and MP4. Both use the same sidebar and large preview; local viewing needs no network, remote viewing needs only RelayBar's host connection.
- [ ] Record bridge requests: expanding a directory reads no document bodies; selecting a page fetches only it and requested in-root resources. Revisiting unchanged content reuses temporary bytes. Verify dependency edits, cancellation, disconnect/retry, unchanged RelayBar history and rejection of out-of-root or symlink targets.
- [x] Markdown tables/code and HTML interactions render correctly on both sources; back navigation and layout switches preserve the current file/position.
- [x] Same-stem Markdown/HTML remain first-class files; image Delete/Archive/Export does not capture them as companions. Existing JSON/TXT companion regressions still pass.
- [ ] Agent saves, rapid successive writes, atomic replacements, dependency changes, additions and removals update correctly without full-tree rescans or preview jumps.
- [x] HTML cannot read outside the opened root, contact external endpoints, invoke native/file operations, open unsolicited windows or persist website data. Tests include traversal, symlinks and active subresource requests, not just clicked links.
- [x] Typing Delete/F/arrows in a document control cannot delete/favorite/navigate files. Media and batch-selection shortcuts still pass their existing tests.
- [ ] With a 10,000-entry fixture, expanding/selecting stays responsive; only the selected document renders. Record first-open/switch latency and memory across 200 mixed-file switches on the test Mac; no unbounded renderer growth or main-thread parsing.
- [ ] Light/dark, sidebar/inspector resizing, full screen, malformed/oversized documents and renderer failure have usable states. Native screenshots document Markdown, HTML and media layouts.
- [x] Existing automated local/remote image/video viewing, lazy remote folders, no-history-write behavior, immediate batch Delete, Archive, favorites and temporary-cache regressions pass. Native local MP4 playback and image viewing also passed.

Coverage notes: the same nested document fixture passed through local and simulated RelayBar transports; a real saved host separately rendered existing Markdown/HTML. Atomic writes, dependency refresh, additions/removals and missing selection pass automated checks; rapid-save stress is unmeasured. The 200-switch run alternates Markdown/HTML, not media. Light/dark, resizing, full screen and oversized-text handling are checked; forced renderer-process failure is untested. See the verification record for evidence and limits.

## Exclusions and review points

No editor, notes database, backlinks, agent chat, terminal, cloud sync, plugins, tabs, PDF renderer or promise to preview every file type. Release versions stay unchanged. The 2026-11-07 implementation request authorizes Frame and RelayBar changes, testing, rebuilding and replacing both apps in Applications; no publication.

Both sources, the preview-first layout and in-folder HTML dependencies are included in the accepted implementation.
