# Task 064 — release preparation

Date: 2026-11-14. Local preparation is complete. No commit, push, Apple submission, website deployment or release publication occurred. The installed test apps were not replaced or restarted.

## Distribution tooling

- `notarize-release.sh [relaybar|frame]` selects the correct app, build and archive; no argument retains RelayBar. Invalid or extra arguments, missing approval and missing profile stop before building.
- Apple submission must succeed and report `Accepted`. Only then does the script staple, recreate the ZIP, verify a clean extraction and emit the matching release plan and final SHA-256. A failed/rejected submission cannot reach stapling or final verification.
- Nine release-script tests passed: two existing release-plan tests and seven workflow tests. The workflow tests run copied scripts in disposable paths containing spaces, with substitute build/signing/Apple tools; successful routing, rejected/failed submissions, archive recreation, clean extraction and guards are covered. No test contacts Apple. Native `plutil` also parsed the status command successfully. Bash/Zsh syntax checks passed.
- Frame's Release script now requests arm64 and x86_64 and verifies each slice before signing. The actual universal build and `package-release.sh frame` succeeded. The extracted `.build/Frame.zip` passed strict deep Developer ID signature verification, metadata matching and architecture checks. Both renderer bundles, themes, math font/metrics, sandbox and App Group entitlements were verified. This ZIP is signed but **not notarized**. The installed Frame 0.1.0/16 remains the earlier arm64 test build.
- Build, package and bundle evidence is retained under `.build/release-preparation-064/`. A sandboxed signature check reported a false failure; verification with normal system access passed, including the clean extraction.

## Documentation and website

Both READMEs distinguish the stable RelayBar 1.6.0/11 download from current source. They describe Frame, bridge v7 pairing, plugin defaults, document limits, online HTML behavior and build/distribution commands. Benchmark copy uses the recorded 200 KB versus 1 MB figures. The Frame system spec now records the actual installed pair instead of the superseded v6 installation.

The site adds a clearly labelled Frame/source preview section and reuses the synthetic Task 063 renderer captures. Stable download URLs and `docs/appcast.xml` are unchanged. Local asset paths, anchors and README links resolve. Browser checks at 1280 px and 390 px confirmed the preview notice, responsive columns, loaded images and no page-width overflow. Captures: [desktop](assets/064-release-preparation/site-desktop.jpg), [mobile](assets/064-release-preparation/site-mobile.jpg).

## Commit preparation

The complete working tree was indexed separately with rename detection; the real index and branch were untouched. A five-patch sequence was reconstructed from the recovery checkpoints, then applied to a fresh disposable index and checked to reproduce the current prospective tree exactly:

1. **Import Frame and introduce shared app composition** — source baseline after Task 058, including earlier companion/document work.
2. **Unify feature ownership and move the bridge to persistent sessions** — Task 059.
3. **Simplify feature code and add built-in plugins** — Tasks 060–062; their shared-file edits are kept together.
4. **Share Markdown rendering across both apps** — Task 063.
5. **Prepare paired distribution and refresh product documentation** — local installation evidence and Task 064.

The patches, their hashes and final tree are in `.build/release-preparation-064/commit-series/` and `commit-series.json`; `prospective-name-status.txt` and `prospective-stat.txt` cover the whole proposed change, including formerly untracked files and detected renames. `prepare-series.py` regenerates them after new edits. Recovery archives contain local configuration and Finder metadata; those were excluded. `.gitignore` now also excludes AppleDouble `._*` files. Imported whitespace was normalized, preserving Markdown hard breaks; snapshot whitespace is normalized at first appearance. Both the current prospective diff and individual patches pass whitespace checks.

These are review patches, not commits. Their ordered application is verified; intermediate checkpoint builds have not been rerun in this preparation. Before committing the sequence, run each checkpoint's applicable gate in an isolated checkout, then rerun the final gate after any fixes from user testing. Do not apply the patches over the existing dirty worktree.

## Still required before release

- Native keyboard/focus, renderer, plugin, wake and real-host acceptance for the installed pair, plus prior-build update/Homebrew rehearsal.
- Resolve Task 059's guard-count acceptance mismatch explicitly; do not archive Tasks 058–063 merely because preparation is complete.
- Update the stable privacy/security summaries and changelog for HTML's network behavior, Service Labels, Frame's permissions and direct remote deletion when preparing the actual release.
- Choose approved release versions/builds, freeze source, submit both apps to Apple and verify final artifacts. Publish Frame before advancing RelayBar's release/feed; then update website download claims and Homebrew against verified immutable artifacts. This preparation grants no publication approval.
