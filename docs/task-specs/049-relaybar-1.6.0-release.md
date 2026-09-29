# Task 049 — RelayBar 1.6.0 Stable Release

Status: In progress

Started: 2026-09-29

## Outcome

Publish Tasks 040–048 as RelayBar 1.6.0 build 11 and install the final notarized
universal application in `/Applications`.

## Delivery Boundary

Includes the existing accepted changes, version metadata, release notes,
immutable GitHub archive, signed Sparkle feed, website, and Homebrew cask.
The maintainer explicitly requested pushing and publishing a new version.
The broader outstanding manual matrix in Task 032 remains separate.

## Work

- Freeze and push a clean release commit on `codex/ssh-retry-settings`, based on
  `1cc8c45815addd687ff330f89e9eac99505b1249`; the fetched `origin/main` has zero
  divergence at release preparation.
- Run strict tests, universal Release build, metadata, resources, licenses,
  dSYM, signing, notarization, ticket, Gatekeeper, and diff checks.
- Publish annotated `v1.6.0` and one immutable final `RelayBar.zip`; verify an
  anonymous download before advancing the signed feed and other channels.
- Verify the public feed and a prior-build update, update the cask to the same
  bytes, and install the final app. Record environment limitations explicitly.
- Update system specifications and archive this task after acceptance.

## Acceptance

- The stable GitHub release and tag identify the verified source commit and
  one signed, notarized, stapled ZIP containing 1.6.0 build 11 for both `arm64`
  and `x86_64`, with macOS 13 minimum and matching executable/dSYM UUIDs.
- Automated, visual, artifact, public-download, feed, and relevant Homebrew
  checks pass, with any unavailable manual environment clearly recorded.
- GitHub, the signed public appcast, README, website, and cask identify the same
  version and immutable archive. Feature-branch commits are pushed without a PR.
- The final notarized app is installed and launches from `/Applications/RelayBar.app`.
