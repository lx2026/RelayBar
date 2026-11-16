# Document workspace verification — 2026-11-07

## Implementation and checks

- Frame: full suite **102 passed**, zero failures, warnings treated as errors. After native verification found sidebar sizing and WebKit Backspace navigation issues, both were fixed; all **7 document tests** passed again, including the new native-history regression. The final signed release build succeeds.
- RelayBar: **353 executed, 329 passed, 24 optional tests skipped**, zero failures. The skips require opt-in live SSH, visual fixtures, or optional local Pillow/ffmpeg test dependencies.
- Actual WKWebView tests: bundled Markdown, sibling CSS/JS/JSON, interactive slider, relative fetch, browser-popup rejection, external-fetch rejection, ephemeral data store, Back navigation and document-focus ownership. Local descriptor tests reject traversal/symlinks, detect atomic replacement and revalidate returning pages.
- Simulated RelayBar transport: listing fetches no bodies; HTML requests only page/CSS/JS/data, not the unrelated MP4. Changed JSON refetches once while other resources reuse bytes. Returning from Markdown uses cached unchanged resources. Polling uses a batch, disconnect retains the last rendered page, and unexpected history operations fail the fixture.
- Actual RelayBar fixed Python helper tests: bounded multi-resource stat, changed fingerprints, traversal/symlink rejection, document Archive/Restore/Delete preserving sibling dependencies. Existing media/group/batch/history regressions pass. Mirrored protocol files compare byte-for-byte; `git diff --check` passes.
- Real FSEvents fixture: atomic additions appear, only the expanded root is indexed, removing the selected file retains its selection and missing state.

## Performance

Final integrated debug test run on the development Mac: 10,000 mixed Markdown/HTML entries listed in **0.716 s**. **200 switches in 5.998 s** (about 30 ms per switch, including 25 ms test polling); one WKWebView was retained. Test-process peak RSS at 100/200 switches: **188.4 / 188.4 MB**. These values exclude WebKit's separate process memory and network latency; they are not a remote-host benchmark.

Tree rows use NSOutlineView virtualization. Rebuilds follow directory revisions rather than each selection or metadata update. Documents use filename/type grid cards, without background browser rendering. Parser work is serial and off the main actor. Existing media decoding/batch-operation limits remain.

## Visual and live acceptance

[Interactive layout mock](../design/assets/2026-11-07-document-workspace/mock.html). After the Mac was unlocked, both installed apps were relaunched. Frame opened Markdown and HTML from an existing saved RelayBar folder. The HTML page rendered its diagram and content; blocked external dependencies produced the concise resource indicator. This was read-only verification: no remote files were added, edited or deleted.

Native checks covered local Markdown tables/code/images, HTML sibling CSS/JS/JSON, a working slider, text-field Delete/F/arrow handling, relative links and Back with matching tree selection, Preview/Grid selection, local live refresh, sidebar resizing and persistence after relaunch. The sidebar now starts at 260 points and gives window growth to the preview. WebKit's implicit Backspace history navigation is disabled; Frame's Back/Forward still work. Build 14 was checked after installation.

An isolated native debug bundle using the same source verified light appearance, the 960-point minimum window, nested image preview, inspector resizing, MP4 playback to its final frame, and full-screen heart/delete controls. It was closed afterwards; the installed apps remain running. System appearance was not changed.

Screenshots use synthetic local content only:

- [Markdown, dark](assets/2026-11-07-documents/markdown-dark.png) — installed build 13; layout unchanged in 14.
- [HTML, dark](assets/2026-11-07-documents/html-dark.png) — installed build 14.
- [Markdown, light](assets/2026-11-07-documents/markdown-light.png), [minimum window](assets/2026-11-07-documents/markdown-minimum.png), [image and resized Info](assets/2026-11-07-documents/image-light.png) — isolated native verification bundle.

Coverage limits: the identical dependency/change/disconnect fixture uses simulated RelayBar transport plus actual helper tests; the real host check covers existing Markdown/HTML, not injected failures or throughput. A fresh RelayBar-button handoff, mixed media/document 200-switch stress, rapid-write stress and forced renderer-process failure were not manually exercised. These are follow-up acceptance coverage, not claims made by the tests above.

## Applications update

Installed and running in `/Applications`: Frame **0.1.0 build 14**, RelayBar **1.6.0 build 18**, bridge protocol **6**. Release versions unchanged. Developer ID signing uses the existing team and entitlements. Strict signatures verify both staged and installed bundles. Frame retains App Sandbox, user-selected read/write access, bookmarks, network client and the existing App Group. The bundled Markdown license is present. RelayBar's arm64/x86_64 executable UUIDs match its dSYM. No publication, notarization, commit or push.

Installed executable SHA-256 values match the signed build outputs:

- Frame: `ca20bd72480c44b0eaed0736752120c8d0aa167a9cd2aabe4ecd80dc13a3e270`
- RelayBar: `922f57e5a47af0b0d611eaf386abc0e8a0c7c2e3ce1d06c50c01799772de0cc9`

Prior bundles are retained under `.build/backups/2026-11-07-documents/`: Frame builds 11–13 and RelayBar build 17. Preferences, catalogs and user folders were not moved or reset. RelayBar restarted successfully; Frame's chooser reads its saved locations through protocol 6. Final process verification found installed Frame PID 21105 and RelayBar PID 19770.
