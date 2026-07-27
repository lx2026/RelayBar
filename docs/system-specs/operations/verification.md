# Verification

## Required checks

- Run `swift test` for the complete forwarding parser matrix, migration, typed-profile and group-tag validation, grouping and metadata-only mutation behavior, group lifecycle batching (mixed phases, partial failure, canonical matching, group isolation, and membership snapshots), control sequencing, rollback and timeout, runtime port mapping, socket refusal, retry, cancellation, browser URL behavior, login-item state mapping through the injected service boundary, Remote Files connection deduplication, path/argument handling, listing parsing, navigation state, Markdown compatibility, link policy, and renderer limits. Login-item tests never read or change the developer machine's real registration.
- Build the Xcode app target with complete Swift strict-concurrency checking and warnings treated as errors.
- Run `plutil -lint` against the application property list.
- Run `git diff --check` before committing.

## Optional live check

Set `RELAYBAR_LIVE_TEST=1` and `RELAYBAR_LIVE_SSH_HOST` to test a real SSH forward and HTTP response on local port 3000.

Set `RELAYBAR_FLEXIBLE_LIVE_TEST=1` with `RELAYBAR_LIVE_SSH_HOST` to verify that a real RelayBar-managed Local Unix listener reaches Running with the configured mode and is removed on stop.

Flexible-forwarding changes additionally require a live OpenSSH control workflow. Exercise Local SOCKS with client-side hostname delegation, Remote SOCKS with allowed and denied `PermitRemoteOpen` destinations, repeated remote port-`0` allocation, and each server-supported fixed TCP/Unix matrix. Record server-controlled `GatewayPorts` or Unix-socket limitations instead of silently skipping them.

Set `RELAYBAR_REMOTE_FILES_LIVE_TEST=1`, `RELAYBAR_LIVE_SSH_HOST`, and `RELAYBAR_LIVE_REMOTE_PATH` to run the opt-in Remote Files listing test against a real saved-server target. Add `RELAYBAR_LIVE_REMOTE_EXPECT_NONEMPTY=1` when the configured path is known to contain entries so a false empty-folder result fails the test.

Remote Files changes should additionally exercise that server and absolute path manually for nested navigation, refresh, file download, recursive folder download, cancellation, image preview, and representative failures.

Before a live server is available, use the DEBUG-only Remote Files fixture to review light and dark appearance, minimum-window truncation, empty folders, long names, image and Markdown previews, refresh recovery, initial connection errors, and active, completed, failed, and canceled transfers. Fixture downloads must remain inside their private temporary directory and must not open Finder.

Start a DEBUG build with `--preview-window --flexible-forwarding-preview` to review rule-aware profile rows and the editor without reading or changing the user's saved profiles. Review add, type switching, duplicate, reorder, remove, automatic ports, Unix fields, exposure warnings, reverse-SOCKS policy, scrolling, keyboard focus, and accessibility labels in light and dark appearance.

Start a DEBUG build with `--preview-window --grouping-preview <scenario>` to review saved-profile grouping without reading or changing the user's saved profiles. Supported scenarios are `empty`, `zero-tag`, `all-untagged`, `one-bucket`, `mixed`, `all-tagged`, `long-tag`, and `many-sections`. Review the flat-list threshold, section order, Ungrouped placement, long-label truncation, scrolling, picker and row-menu parity, inline Return/Escape behavior, rename, ungroup-all, the Start All/Stop All/Restart All commands with state-aware enablement, keyboard focus, and accessibility labels in light and dark appearance.

Launch at Login changes require a signed packaged build verified manually for enable, login relaunch as the menu-bar-only app with every saved profile stopped, disable without quitting the running app, and state synchronization after changes made directly in System Settings. Use the offscreen snapshot harness for the settings screen and its approval-required caption in light and dark appearance.

For a native live-transport review without changing the user's saved tunnels, start a DEBUG build with `--remote-files-live-preview <ssh-host>`. This route uses the real SFTP service while keeping review downloads inside the same private temporary directory and suppressing Finder launch.

Markdown changes should exercise a local fixture in light and dark appearance for GFM, properties, callouts, code highlighting/copy, math, footnotes, blocked images/embeds, wiki links, inert tags, Mermaid source, raw HTML, keyboard return, and accessibility reading order.

Changes to bundled renderer resources should build the Xcode app in Debug and Release, verify that Highlighter retains only its formatter and the `github`/`github-dark` themes, verify that SwiftMath retains only Latin Modern metrics/font and licenses, record the Release app and executable sizes, match the stripped executable to its dSYM UUID, and exercise the affected renderer in the native fixture.

Release changes should additionally verify the code signature and notarized app with the scripts in [Build and release](build-and-release.md).
