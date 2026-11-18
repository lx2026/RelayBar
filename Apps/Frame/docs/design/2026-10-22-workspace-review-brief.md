# Frame workspace UX review brief

Date: 2026-10-22. Design consultation only; do not edit implementation.

The user finds the installed app low quality, unintuitive and hard to use. They want a clear flow, UX mock screenshots and an independent design review before implementation. Prior mockups over-prioritized reducing visible navigation; the actual app now hides location switching and distinguishes preview from selection in a confusing way.

## Product boundaries

Native macOS, existing folders, no imports. JPEG/PNG and common native video. Fast contact sheet with adjustable thumbnail size, resizable preview, conventional Command/Shift selection, favorite, local Trash with Undo, local Archive/Restore, byte-exact single-asset export replacing destination metadata. Image + paired JSON is one asset. Read-only metadata with readable AI prompt/fields and explicit embedded versus JSON provenance. Image and metadata visible together. No editing, search, tags, ratings, albums or cloud library.

Remote viewing uses RelayBar-owned SSH/SFTP. Shared saved hosts/recent paths, no duplicate host setup in Frame. One-click Open in Frame from RelayBar after one-time consent. Remote originals cannot be archived or trashed. Remote export saves a local copy. No download website exists; do not invent one. RelayBar source, credentials and user history are outside this review; the integration can be discussed only from these requirements.

## Evidence you may read

Only the two fixture screenshots in docs/system-specs/assets/2026-10-22 (paired-json-light.png and remote-first-use.png) and this brief. They contain synthetic samples, not user photos. Do not read any other files unless a follow-up explicitly adds a design asset to scope. Do not use shell, network, agents or edits.

## Current pain points

- Top left folder menu, second scope/filter toolbar, optional nested folder rail, mode button, footer actions all compete.
- First item is previewed but not selected. Inspect/export disabled until clicking the item. Large empty area around tiny tiles while preview remains narrow.
- Preview above metadata shares a narrow right column; long paths and headings consume height.
- Remote first-use sheet repeats instructions, truncates copy, and asks user to shuttle between apps plus Retry.
- Archive mixed with filtering; action placement fragmented. Paired JSON suffix clutters filenames.

## Candidate direction

One stable Review workspace. Collapsible ~180pt location rail; recent local folders and RelayBar remote paths are visible, Open Folder is a labeled button. Current folder children expand in the same rail, no duplicate folder chooser. All/Favorites/Archive apply to the current local root and are clearly scoped.

Contact sheet on left of review area; currently selected image and concise metadata next to each other on the right, not vertically stacked by default. Resizable boundaries; thumbnail slider next to grid label. At 1280pt, rail can collapse and panel widths adapt. At 960pt, metadata may dock below preview but must remain visible, not a different tab. Full image optional via Return/double-click; not required for legible previews. Stable one-click selection updates preview and metadata; no mysterious not-selected preview. No destructive action without explicit selection or confirmation of count.

One action row beside selection count: Favorite, Export (single asset only), Archive, Move to Trash. Multi-selection keeps the active image visible with “Previewing X · N selected” and a visible selection border/check. Archive becomes Restore in archive scope. JSON is a quiet paired-file marker; metadata shows filename + source and expandable raw data. Remote browsing has a compact source/read-only label and omits unsupported actions with an explanatory hint.

First use: Open Folder or choose recent; app reopens last location thereafter. Remote connect is one clear “Continue in RelayBar” action, no fake authentication or auto-consent. Handoff returns to Frame automatically; missing app has no dead download button. Offline state remains in workspace and offers Retry/Open RelayBar without erasing location.

## Round 1 requested feedback

Critique the candidate rather than agree. Identify the 5 most important usability risks and a concrete recommended arrangement at 1280×800 and 960×640. Challenge four-column density, selection safety and remote-first-use friction. Give short must-change vs optional guidance. Do not add product scope. State which screenshots you actually inspected.
