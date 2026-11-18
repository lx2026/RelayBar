# Task 063 verification

Status: Implemented — 2026-11-14. Both apps render Markdown through the shared `MarkdownRendering` library and pass the automated gate. Signed local builds were subsequently installed and launched on 2026-11-14; see "Local installation". Native interaction and live-host acceptance remain open.

## Baseline

- Branch `codex/task-058-composition` at `5ebcfdd`, identical to `origin/main`, no upstream. The work of Tasks 058–062 is uncommitted and is this task's starting point.
- Snapshot of that tree: `.build/task-059-baseline/checkpoint-before-063.tar.gz`. With the shared library in place but both apps still on their old views: `checkpoint-063-shared-renderer.tar.gz`.
- The comparison that led to the task, on the same two reference documents and the same generated benchmark files used below: RelayBar's MarkdownUI view looked finished but needed 0.9 s and 7.2 s to lay out a dense 20 KB note and a 200 KB document, holding 185 MB and 1.3 GB; Frame's WebKit view needed 0.02 s and 0.07 s but had no highlighting, math, footnotes or Obsidian syntax.

## What was built

- **Shared** (`Packages/AppComposition`, target and product `MarkdownRendering`): the Obsidian compatibility pass, moved unchanged from RelayBar apart from becoming public, an option to pass ordinary images through, and a bound on its escape check; `MarkdownRenderer` (cmark-gfm in safe mode, then a rewrite of the parsed tree); `CodeHighlighter`; `MathTypesetter`; one stylesheet. 557 new lines plus the 2,711-line pass.
- **RelayBar**: `SafeRemoteMarkdownView` now hosts `RemoteMarkdownWebView`, whose page carries link references rather than addresses. The MarkdownUI theme, the SwiftUI code block and Copy button and `MarkdownRenderingSupport.swift` are gone, and RelayBar no longer depends on MarkdownUI (or, through it, NetworkImage); HighlighterSwift and SwiftMath arrive through the shared library. Its own sources fell from 20,488 to 17,349 lines: 2,688 moved, 451 removed.
- **Frame**: `DocumentHTML` calls the shared renderer with images passed through and Frame's palette; `DocumentRenderer` handles Copy; `Scripts/bundle-renderer-resources.sh` puts the highlighter's and the math font's resource bundles and licences in the app bundle.
- Production lines across the three packages: 33,166 before, 33,316 after.

## Renders

Each app's real view drew the two reference documents offscreen at 820 points wide. Stored at 1× in [assets/063-markdown](assets/063-markdown/):

| | Before | After |
| --- | --- | --- |
| RelayBar, ordinary | `before-relaybar-ordinary.png` | `after-relaybar-ordinary.png` |
| RelayBar, extended | `before-relaybar-extended.png` | `after-relaybar-extended.png`, `after-relaybar-extended-dark.png` |
| Frame, ordinary | `before-frame-ordinary.png` | `after-frame-ordinary.png`, `after-frame-ordinary-dark.png` |
| Frame, extended | `before-frame-extended.png` | `after-frame-extended.png` |

What changed in them: in RelayBar a plain bullet beside tasks no longer has a checkbox, unlabelled and Mermaid code is monospaced, and the wide table fits its column with its last two columns visible. In Frame the page has RelayBar's structure in Frame's palette: frontmatter as a Properties card, callouts, highlighted code with a language label and Copy, typeset math, footnotes, right-aligned number columns, task items without bullets, and raw HTML shown as text rather than dropped. The two apps' pages have the same layout; Frame's is taller only where its image loads.

## Timing

Optimized test builds, 820-point window, the same generated files as the baseline (a table and a highlighted code block about every 30 lines). "Ready" is from the file's bytes to a laid-out page in the app's own view class.

| Document | RelayBar before | RelayBar after | Frame before | Frame after |
| --- | --- | --- | --- | --- |
| 20 KB dense | 0.9 s | 0.03–0.04 s | 0.01–0.02 s | 0.04 s |
| 20 KB prose | 0.44 s | 0.04 s | not measured | 0.04 s |
| 200 KB dense | 7.2 s | 0.47–0.51 s | 0.07 s | 0.32–0.51 s |
| 1 MB dense | not run | 1.6 s | 0.31 s | 1.6 s |
| Re-layout after a resize, 200 KB | 0.5 s | 0.01 s | 0.01 s | 0.01 s |

- Memory at 200 KB: RelayBar's own process grew by 1.3 GB before and by about 16 MB now, with about 65 MB in WebKit's content process. The first Markdown preview in a session adds about 67 MB once (WebKit and the highlighter).
- The first preview in a session takes about 0.45 s for the 20 KB note: it starts WebKit's content process and loads the highlighter. Preparation runs off the main thread in both apps.
- The task's own targets were 0.1 s and 0.5 s. The 20 KB target is met in both apps. The 200 KB figure sits on the line: 0.51 s the first time a document's code blocks are highlighted and 0.32–0.47 s afterwards.
- Frame is slower than it was on large documents, because it now runs the Obsidian pass (about 1.25 ms per KB, the largest share) and highlights code. A document above 2 MiB skips both.

## Independent review

A second reviewer read the work twice, read-only: the shared library on its own, then both app lanes against the tree from before the task.

**Shared renderer: six findings, all fixed and tested.**

1. An image inside a table cell was not replaced, because a table cell accepts only a few kinds of inline content: a remote image, a forged math link or a legitimate formula stayed as the document wrote it. Placeholders are now ordinary text nodes, math is wrapped in emphasis where a cell refuses it, and an image that cannot be replaced is removed.
2. `$x\textcolor{#ff0000}{}$` stops the process inside SwiftMath's typesetter with "Index out of range". This was confirmed by running it. The same calls are in the native view the installed 1.6.0 uses, so that build very likely has the crash. Colour commands and nesting beyond 32 levels are now refused before typesetting; 3,315 edge-case formulas were then typeset without a trap, and about a thousand of them stay as a test.
3. Reading an image's label recursed once per level of nesting. It is now iterative and stops at 512 characters.
4. The compatibility pass's escape check rescanned a run of backslashes for every character after it, so one long line of backslashes meant trillions of steps. The count now stops at 64. This was in the moved code and is in the installed build too.
5. cmark's safe mode lets `data:` links of image type through. The renderer empties them.
6. The options' default token was a fixed word. It is now random for each set of options.

Found before that review, by the author: an image nested in another image's label was freed with its parent and then visited. Images are now handled innermost first.

Not found: a memory fault in the tree rewriting, a race, or an escaping fault in the markup the renderer writes itself.

**Both apps: four findings.**

1. Frame. An HTML document, which may run script, could rewrite its own address to end in `.md` and pass the Copy check, putting text on the pasteboard unasked. The check now uses what the renderer recorded when the page was committed. The new test fails against the old check: the planted text is copied.
2. RelayBar. The first version looked a clicked link up in the page to recover what the document wrote. When that lookup failed, its fallback could turn `/https://example.com/` into an external address.
3. RelayBar. In the same version an absolute link was judged in the form WebKit repaired it to, so `https:example.com` opened where the link policy had refused it.
4. RelayBar. "Search the Web" on selected text opens the browser without the link policy. Kept: it acts on the reader's own selection at the reader's request, as in any macOS text view, and the spec now says so.

A test written for findings 2 and 3 showed something neither review had: WebKit connects to a clicked link's server before it asks whether the link may be followed, so the preview itself contacted the server named by a link, including one the policy then refused. The page now carries references instead of addresses, which removes the lookup of findings 2 and 3 as well; a test with a loopback server sees no connection after clicking an allowed and a refused link.

No finding on keyboard handling, lifecycle, Frame's handling of HTML, text, images and document links, the bundle scripts, or the project files. Test gaps closed: plain Backspace, Delete and typed letters do nothing in the preview, focused or not; a clicked address that is not one of the page's references is refused. Not added: real drag-and-drop, the three-reload limit, and deallocation after teardown.

## Gate

Run after the last review fix.

- `scripts/test.sh`, warnings as errors, exit 0 (`.build/task-063-final.log`): 2 release-plan tests; 92 shared (68 kernel with 1 optional skip, 24 Markdown with 2 optional skips); 427 RelayBar (29 optional skips); 190 Frame (2 optional skips); zero failures. The log's `CoreData: error` lines come from a system service during the RelayBar suite and number the same as in earlier tasks' logs.
- `swift build --package-path Apps/Frame --product Frame -Xswiftc -warnings-as-errors`: complete.
- `xcodebuild -project Apps/RelayBar/RelayBar.xcodeproj -scheme RelayBar -configuration Debug CODE_SIGNING_ALLOWED=NO build`: succeeded. The built app's `Contents/Resources` holds the pruned `Highlighter_Highlighter.bundle` and `SwiftMath_SwiftMath.bundle`.
- `git diff --check`: clean. `Apps/` and `Packages/` are untracked, so the files this task touched were also checked directly for trailing whitespace.
- Frame's bundle step, run by hand without signing into a scratch directory: both resource bundles pruned to the `github` themes and the Latin Modern font, with four licence files; the helper stops with a message when a bundle, a required file or the destination is missing.
- Opt-in tests, run separately: the three snapshot tests (`MARKDOWN_SNAPSHOT_DIR`, `RELAYBAR_SNAPSHOT_DIR`, `FRAME_SNAPSHOT_DIR`) and the shared timing test (`MARKDOWN_PERF_SOURCES`, `MARKDOWN_PERF_OUT`). The per-app timings above came from throwaway tests that were removed.

## Local installation

On 2026-11-14 the user requested replacement of both Applications bundles for testing. After fetching remotes, `codex/task-058-composition` remained at `5ebcfdd`, 0 ahead / 0 behind `origin/main`, with no upstream and the implementation uncommitted.

- Installed and launched `/Applications/RelayBar.app` **1.6.0 (21)** and `/Applications/Frame.app` **0.1.0 (16)**. Only build numbers changed. Both processes were observed running from Applications; their installed executable hashes match the verified build outputs.
- Both passed strict deep signature verification with Developer ID team `39HYFR5Z65` and hardened runtime. Both retain the shared App Group; Frame retains App Sandbox. RelayBar contains arm64 and x86_64; this local Frame build contains arm64 only.
- Both bundles contain the highlighter, its light/dark GitHub themes, and Latin Modern math font and metrics. This verifies packaging, signing and application launch, not first-use rendering in the installed app.
- The existing RelayBar terminated normally. Previous bundles are recoverable at `.build/local-install-063/backups/RelayBar-1.6.0-build20.zip` and `Frame-0.1.0-build15.zip`. Preferences and user data were retained.
- Fresh `scripts/test.sh`: 2 release-plan tests, 92 shared tests (3 optional skips), 427 RelayBar tests (29 optional skips), 190 Frame tests (2 optional skips), zero failures. Both Release build/signing scripts completed. `git diff --check` and direct trailing-whitespace checks of new code/configuration files passed.
- Logs, signature/resource/architecture evidence, installed executable SHA-256 values and backup paths are in `.build/local-install-063/`. No commit, push, notarization or publication occurred.

## Not verified at the original renderer gate

- No signed build and no running app. Not tried by hand in RelayBar: selection and Command-C in the preview, the context menu, scrolling by trackpad, the absence of a flash in dark appearance, VoiceOver, and above all the window's keys after clicking inside the preview. Tests drive Left, Right, Escape, Command-[ and Command-Delete with synthesized events with the preview focused and unfocused, but SwiftUI's own focus does not run in the test process: if the sidebar were to keep its focus after a click in the web view, Command-Delete and Left/Right would do nothing until focus moved.
- Frame's assembled bundle was checked unsigned for its contents only. It has not been signed, notarized or launched, so loading the highlighter and the math font from inside the app, and signing after the resource bundles' own seals are removed, are untested.
- No real remote host. RelayBar's preview was fed files from disk through its decoder; Frame used local folders and its simulated session.
- Offscreen renders show a horizontal scroll bar's space under a code block with a long line; with overlay scroll bars there is none.
- Installed apps were unchanged at the original renderer gate; the subsequent local installation above supersedes that state. Nothing has been committed, pushed, notarized or published.

## Left for later

- The compatibility pass works on arrays of characters and dominates rendering time above about 100 KB.
- Each code block is highlighted twice, once per appearance, because the highlighter returns styled text rather than class names.
- Inline HTML such as `<kbd>`, `<br>` and `<details>` stays literal text; an allow-list would need its own review.
- The compatibility pass's tests still live in RelayBar's test target.
