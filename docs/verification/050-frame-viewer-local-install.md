# Task 050 — local installation verification

Date: 2026-10-22. Branch: `codex/frame-viewer-handoff`, created from clean synchronized `codex/ssh-retry-settings` after fetch (0 ahead / 0 behind its upstream). No commit, push or PR was created.

## Results

- Full regression: 331 tests, 21 opt-in live/snapshot skips, zero failures, warnings as errors.
- A subsequent fourth bridge test passed with all four bridge tests against a disposable loopback-only sshd: real SFTP folder listing and exact image/JSON download, generated identity, strict known-host checking, no user config or agent. The fixture server was stopped. Initial fixture used arguments outside the production allowlist; a test-only executable wrapper isolated configuration instead. Production SSH policy was not loosened.
- Signed local-socket harness accepted the expected sandboxed Frame bundle/team and rejected a differently identified signed client. Dynamic code validation avoids peer-bundle sandbox access. Accepted descriptors explicitly clear inherited nonblocking mode.
- The installed Frame 0.3.0/4 launched RelayBar through its own recovery action, authenticated the installed broker, and received the expected first-use-consent gate. No user host or saved history was read through that gate, and no user consent was granted by the agent.
- Universal Release build passed. Strict outer/nested signatures passed, including explicit expected bundle/team requirements. App Group entitlement is present for both architectures. Frame retains App Sandbox. RelayBar executable/dSYM UUIDs match: x86_64 `05A000E6-EC90-3CBD-9E80-D7925746C96C`, arm64 `6E7F732A-39EA-341B-A9B4-DCD56B49EF2B`.
- Property lists and Xcode project lint passed; `git diff --check` passed. Shared wire source matches Frame byte-for-byte.

## Installation

The user explicitly approved updating both apps, including a brief tunnel interruption. RelayBar accepted a normal termination request; no force-quit was used. Installed `/Applications/RelayBar.app` is 1.7.0/build 12; its executable SHA-256 is `7f3cc44937cc8a9c126e73b319bd608c1baeb2b3eb57b28d75a5e29db1b19919`, byte-identical to the verified build output. The process was observed running from Applications after Frame's Open RelayBar action.

The previous 1.6.0/build 11 app is recoverable in the previous Frame working folder at `.build/backups/RelayBar-1.6.0-build11-2026-10-22.app`, executable SHA-256 `c14dae34748a904918f5d83f2a1590769eadf76df825a79a7187f40c85634937`. Preferences and SSH configuration were not removed. No notarization, release, feed, tap, or website changes occurred.

## Not yet accepted

Task 050 remains active for native first-use Allow, full one-click focus handoff, real-host shared-history round trip, and remote video/export UI acceptance on a user-selected disposable folder. No private host was chosen merely for testing. Native automation could not reliably attach to RelayBar's menu-bar-only UI. Existing broad Task 032/037 acceptance remains unchanged. Frame's companion verification includes native local Archive/Restore and dark/light JSON screenshots.
