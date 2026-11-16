# Task 054 verification

Date: 2026-10-22

- Restored the pre-development-bump labels: Frame 0.1.0 (verified against its first installed bundle) and RelayBar 1.6.0 (verified against repository HEAD/public stable metadata).
- Retained builds 10 and 16 exactly. No source-feature changes or rollback. Both `AGENTS.md` files now require explicit user direction before any marketing-version change; local development and Applications updates only permit necessary build-number increments.
- Rebuilt/signed/installed `/Applications/Frame.app` **0.1.0/10** and `/Applications/RelayBar.app` **1.6.0/16**. Plists and both RelayBar Xcode configurations agree. Strict/deep signatures and nested Sparkle signatures pass; Frame is arm64, RelayBar universal. RelayBar executable/dSYM UUIDs match.
- Preserved prior bundles in Frame `.build/backups/Frame-0.6.1-build10-2026-10-22.app` and `RelayBar-1.8.1-build16-2026-10-22.app`; preferences remain untouched.
- Both apps launched; Frame restored Downloads (1,666 assets, existing favorite/360 pt thumbnails). Open… read the same three RelayBar locations using bridge v4 without opening a remote host.
- `git diff --check` and plist lint passed. Build logs in each repository: `.build/version-correction-build.log`. No new unit-test run: only version metadata/documentation changed; [Task 053](053-frame-direct-delete.md) retains the source test evidence.
- No commit, push, notarization, publication or production-channel change. Public RelayBar remains 1.6.0/11; local development is 1.6.0/16.

Installed executable SHA-256:

```text
Frame     16e73ffc3463031de765273699a399683c19ae28c9dda0fa0d0ab3173ba35d24
RelayBar  0e5537c511f45936e615b3706bdf3e445d3b87a71ff2ac316d8c4acdf9236374
```
