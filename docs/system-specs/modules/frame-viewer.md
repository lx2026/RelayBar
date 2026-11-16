# Frame viewer handoff and remote assets

Bridge v7 bundles were installed as RelayBar 1.6.0/21 and Frame 0.1.0/16 on 2026-11-14. Only build numbers changed; public stable remains 1.6.0/11. Strict Developer ID signatures and launch were verified; native interaction and live-host acceptance remain open. See [Task 063 installation evidence](../../verification/063-one-markdown-renderer.md#local-installation). The earlier bridge v6 installation on 2026-11-07 had native local document/media and saved-folder document checks; those checks do not certify the newer source. No publication or notarization occurred.

Open in Frame hands off the current folder/selection through a one-use 60-second nonce. It is a RelayBar plugin, on by default only when Frame was installed as RelayBar launched; an explicit choice in the Plugins window always wins. While it is off RelayBar shows nothing of Frame (no Open in Frame buttons, no Frame Viewer access row in Settings) and its bridge does not listen. Turned on by hand without Frame, the button shows a message that Frame isn't installed; an incompatible Frame shows an update message. No download website has been supplied. RelayBar owns SSH credentials, aliases, arguments and host-key checks. Frame receives opaque IDs, paths and bounded content.

Frame reads but **never changes RelayBar history**, including explicit descendant opens. Legacy rememberOpen is a compatibility no-op. RelayBar's own history behavior is unchanged.

## Session and wire

Source and the current installed test pair use wire v7. Older wire versions are rejected as incompatible, so both apps must be updated together.

- **One connection per session.** Frame opens one connection to RelayBar's socket when it connects and sends every request on it. Each request carries an id and its reply carries the same id, so a slow request never delays another.
- **Identity once per connection.** Each peer verifies the other's audit-token code identity when the connection opens. The check itself is unchanged.
- **The end of the connection is the end of the session.** RelayBar quitting, stopping its host or crashing ends the connection, and Frame withdraws its remote features at once without sending anything. Frame quitting or crashing ends it from the other side, and RelayBar cancels that session's jobs and removes their transfer directories immediately; jobs no longer wait for an expiry timer.
- **Revoke.** RelayBar sends connected sessions a notice carrying the reason and then ends those connections. New connections are still accepted and are answered as unauthorized.
- **Long operations.** A request that starts work still returns a job id. Frame's status request for that job is held and answered when the job finishes, or after at most half a second with transfer progress. Frame no longer polls on a timer, and makes no periodic liveness request while connected.
- **Cancellation.** A cancelled caller stops waiting. If RelayBar had already accepted work for that call, the late receipt is released automatically.
- **Other versions.** A v6 peer's bare request is answered in the v6 shape as incompatible and never reaches the broker. A v7 Frame treats a v6 reply as incompatible. Failures end a session only when RelayBar names them (unavailable, unauthorized, incompatible); a file or helper error leaves it usable. The former matching of English error strings is removed.
- Frame still looks for RelayBar every three seconds while it has no session; that is discovery, not liveness.

## Permissions and interface

Both peers verify kernel audit-token code identity against expected bundle IDs and Apple-anchored Developer ID team 39HYFR5Z65. The shared App Group socket is mode 0600; Frame remains sandboxed. RelayBar protects each accepted connection against SIGPIPE before anything can write to it; a peer that has already hung up by then is closed unanswered.

Linked Frame access permits browsing, previews, original downloads, Archive/Restore and direct Delete. There is no second write prompt or delete confirmation. Revoke retires access and jobs/services. There is no trash, upload or arbitrary-shell endpoint. Older protocol versions are rejected.

## Prompt Search

Prompt Search is a plugin, on by default. While it is on, the toolbar has a search field in both layouts; Command-F focuses it and Escape clears it. Typing filters the current folder, after its other filters, to the assets whose text contains every word typed, ignoring case and diacritics. Words are separated by spaces; quotes are ordinary characters.

- An asset's text is its file name and its companion text. On this Mac that is the whole of each companion file up to 2 MiB, and a PNG's text chunks, to 256,000 characters per asset. Through RelayBar it is the companion text the session returns, which is the first 24,000 characters of each companion; embedded PNG text is not searched remotely. The sentences shown in place of an unreadable, oversized or binary companion are never searched.
- A search starts 200 ms after the last change to the query or to the folder scope. A newer search cancels and supersedes an older one; the list keeps showing the previous result until the new one arrives. The toolbar shows the number of matches beside the field.
- The selection always stays inside the filtered list, and delete, archive, restore and favourite read their targets from what the list shows, so they never apply to an asset the search hides. Choosing a file in the sidebar or through a link ends a search that hides it, and Show all files ends the search along with the other filters. Undo is the exception: it restores what the last Trash operation moved whether or not the search shows it.
- Text is read at most six assets at a time, under the folder access or session the realm already holds, and kept in memory while the plugin is loaded, up to 16,000,000 characters; passing that empties the cache. Each asset is matched as it is read, so a search holds no more text than the cache does. An asset is read again when its size, modification time or file identity changes, or a companion's does, or a companion is added, removed or renamed; an asset with a companion or PNG that could not be read, or whose read was cancelled, is not cached. A search in progress is joined before the plugin finishes unloading. Nothing is written.
- Single keys act on the selection whenever no text control has focus (Backspace deletes, permanently for a remote file), so typing must never fall through to them. Three things ensure that. The field sits in the toolbar, which is not rebuilt while someone types. The grid and the viewer, which take the keyboard when they appear, do not take it from a text control being edited. And the key monitor remembers that someone was working in a text control: if that control loses the focus without a click in the window or a key that leaves it (Tab; or Return, Enter or Escape in a field other than search), a key that would run a shortcut is dropped instead, and the search field is given the focus back. Editing commands such as Command-A and Command-V keep that protection on, and Command-Backspace is covered like Backspace.
- When the plugin is switched off, or the session behind a remote folder is withdrawn, the query is cleared, the filter is removed, a pending search is dropped and the field goes away.

## Host behavior

Protocol 6 adds `documentStat` for 1–128 root-contained paths. It returns stat fingerprints in one fixed-helper invocation, rejects traversal/symlinks, and omits missing files. No history changes or content transfers occur. Frame renders Markdown/HTML on the Mac, fetching only the page and dependencies through existing authorized file transfers. No remote web server is installed. In the current source Markdown is drawn with the shared `MarkdownRendering` page that RelayBar's preview also uses ([Markdown preview](markdown-preview.md)); Frame adds its palette and lets ordinary images load.

Markdown (`.md`, `.markdown`) and HTML (`.html`, `.htm`) are independent primary files. Media grouping excludes them. Document Archive/Delete acts on the document alone; referenced CSS/JS/data/images are never inferred as companions. Existing JSON/TXT grouping remains unchanged.

The signed app contains a fixed Python helper, executed over the existing SSH control socket. JSON is sent on stdin; paths never enter shell text. Python 3 is required for Frame browsing/actions, Pillow for JPEG/PNG derivatives/metadata, and ffmpeg/ffprobe for video posters/metadata. Nothing is installed automatically.

Listings return precise stat fingerprints and omit symlinks and managed Archive. Previews are 512 or 2048 pixels with bounded metadata and companion text. Frame and RelayBar share filename grouping: longest same-folder dot-prefix wins, exact media filenames take precedence over tied stems, ambiguous stems remain ungrouped. Arbitrary suffixes/extensions and multiple companions are supported, e.g. `name1.png`, `name1.xyz.json`, `name1.qqq.txt`. No content guessing or suffix whitelist.

Conditional validation returns unchanged without another image transfer. Images download for Original/Export; selected video downloads for native AVKit playback, without requiring ffmpeg/ffprobe. Those host tools remain optional for grid posters. No whole-video download occurs just to fill the contact sheet. Each downloaded member is stat-checked before and after SFTP.

Delete immediately unlinks media and all companions. `deleteBatch` accepts up to 500 selected media paths with retained listing IDs and runs one helper invocation with per-item outcomes. Frame limits each batch to 16 distinct listings so expired-listing renewal fits the broker cache; 100 items in one folder still use one mutation request/helper invocation. No move, Trash, delay, confirmation, Undo or recovery record. Files are checked against listing fingerprints before unlinking; partial failures name already-deleted files. Deleting an archived item also removes only its known manifest and empty record directory.

Archive stays separate: the full group moves into managed Archive UUID folders on the same filesystem, retaining original paths. Existing one/two-file records still load. Restore refuses collisions. Moves use no-clobber hard links followed by unlink, preflight and rollback. No recursive source deletion occurs. The old `.FrameTrash` folders, if any, are not automatically modified.

## Bounds

Messages: 8 MiB; derivative: 4 MiB; original/companion download: 100 MiB per file; text preview: 2 MiB input/24,000 characters per companion and 256,000 characters total; listing: 10,000 entries. Four active jobs, 32 retained jobs/listings, eight services and eight transfer directories. Helper CPU/wall limits: 30/50 seconds; Linux address space: 2 GiB. Frame now keeps derivatives/metadata/originals only in bounded session temporary storage. RelayBar's bridge transfer directories remain disposable.

## Verification

[Task 055](../../task-specs/archive/055-frame-batch-delete.md): 351 tests executed, 329 passed, 22 opt-in skips, zero failures; local debug build succeeds. Broker regression sends 100 four-file groups to one helper invocation. Python tests cover whole-group Archive/Restore/Delete, JSON/TXT previews and per-item batch failures. Mirrored wire files match and diff whitespace checks pass. Frame separately verifies stable deletion order, recursive listing renewal, and favorite-and-next. No private host was opened or changed.

[Task 053 evidence](../../verification/053-frame-direct-delete.md) records the installed direct-delete build. [Task 052 evidence](../../verification/052-frame-remote-assets.md) records the earlier persistent-cache design. Real-host latency, full URL handoff and every interruption boundary remain manual acceptance limits.

Earlier behavior remains recorded in [Task 051](../../verification/051-explicit-frame-history.md) and [Task 050](../../verification/050-frame-viewer-local-install.md).

RelayBar build 20 adds HTML/HTM directly to its own preview. Both apps allow online HTML resources with unchanged macOS transport protections. See [Task 057](../../task-specs/archive/057-html-preview.md); the user confirmed the installed RelayBar preview works on 2026-11-07.
