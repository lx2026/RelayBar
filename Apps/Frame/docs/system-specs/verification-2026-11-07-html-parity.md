# HTML preview parity — 2026-11-07

Installed and running: **Frame 0.1.0/15** and **RelayBar 1.6.0/20**. Release versions unchanged. Both strict Developer ID signatures verify; RelayBar is universal and both executable UUIDs match its dSYM. No publication, notarization, commit or push. Previous bundles are preserved in `.build/backups/2026-11-07-html-parity/`.

## Behavior

RelayBar now recognizes `.html` and `.htm` and renders them directly in its file-preview workspace. One ephemeral WKWebView loads the selected document; only requested relative dependencies transfer over the existing connection. Resource checks reuse the existing root-contained helper, with four concurrent transfers, 128 paths and 64 MiB per preview. Files are checked before/after transfer, temporary downloads are removed after reading, and closing the preview cancels resource work. Resource reads do not write recent history. Existing Markdown/media previews remain unchanged.

The user explicitly approved online resources. Both HTML renderers now allow online scripts, stylesheets, fonts, images, media and fetch/WebSocket requests. The earlier blanket network block and its “External resources blocked” message were removed. Folder containment, ephemeral website storage, popup restrictions and document keyboard ownership remain.

macOS App Transport Security is unchanged. HTTPS resources load normally; insecure HTTP may still be rejected by macOS. Automatic approval review rejected adding the broader `NSAllowsArbitraryLoadsInWebContent` exception, so it was not applied.

## Verification

- Frame: **102 tests passed**, zero failures, warnings treated as errors. Actual WebKit loads external script/CSS/JSON responses from a loopback HTTP fixture; local-file escape and existing document/media regressions pass.
- RelayBar: **356 executed, 332 passed, 24 optional skips**, zero failures, warnings treated as errors. Three new HTML tests exercise model-to-WebKit rendering with relative/online dependencies, requested-only transfers, unchanged history, resource limits, temporary cleanup, ephemeral storage and document-focus detection. Those three pass again after guarding stale link errors against newer selections.
- Both signed release builds succeed. RelayBar's Xcode simulator-version diagnostic concerns unused iOS simulator support; the macOS universal build and signing finish successfully. Mirrored bridge files remain unchanged; `git diff --check` passes.
- Installed Frame opened an existing saved remote HTML document. Its title and content rendered with no offline-policy or resource-error indicator. No remote files were changed.
- RelayBar's installed process is running, but its menu-bar-only UI did not expose a window to automation. SystemUIServer access was not approved; the user was asked to open Remote Files. The user subsequently replied “works” on 2026-11-07 to the requested Remote Files check. This closes the installed-preview item as user-verified; the agent did not inspect or capture that window. Frame's Browse in RelayBar action also showed a trust error during that launch attempt; subsequent independent signature and bridge checks passed. The launch path remains a manual follow-up.

Final installed SHA-256:

- Frame: `190972010b08e04d2add5c26840a4f45e9490ccd0c4f6019a8aa9a5b06dc5e7b`
- RelayBar: `94404e97ede0137835b15fa74abc2d23a2aeb1847db3a104ee783636e926734f`

Final process check: Frame PID 24932, RelayBar PID 26657, both from `/Applications`.
