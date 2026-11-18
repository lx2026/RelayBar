# HTML preview

Status: Complete — 2026-11-07

## Outcome

Render HTML inside RelayBar, including online resources approved by the user, with the same behavior available in Frame.

## Delivery Boundary

HTML/HTM preview uses one ephemeral WKWebView. Relative dependencies load on demand from the opened folder through the existing service; online CSS, scripts, fonts and images may load normally. No recursive download, persistent cache or dependency history entries. Existing Markdown/media previews remain.

## Work

- Recognize HTML, add rendering and resource loading, preserve file-preview selection and keyboard focus.
- Test actual WebKit with relative and online dependencies and temporary cleanup.
- Build, sign and update Applications; keep release version 1.6.0 unchanged.

## Acceptance

- HTML opens in RelayBar's preview and executes local/online visualization scripts.
- Relative resources stay within the opened folder and are fetched only when requested.
- Document keys do not delete or change the selected file.
- Existing preview tests pass; the installed build is signed and running.

Evidence: full suite 356 executed, 332 passed, 24 optional skips, zero failures; three focused HTML tests also pass after the stale-link error fix. Signed universal RelayBar 1.6.0/20 and Frame 0.1.0/15 are installed and running. Existing remote HTML renders in installed Frame without the offline warning. RelayBar’s model/WebKit flow is tested; its menu-bar window was not available to automation. The full record is `docs/system-specs/verification-2026-11-07-html-parity.md` in the sibling Frame repository.

User confirmation: “works” on 2026-11-07 in response to the requested Remote Files check. Installed-preview verification is user-confirmed; no agent screenshot is claimed.
