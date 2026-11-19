# Task 075 — Frame 2.0.0 Beta 3

Status: Complete

## Outcome

Frame users can download the window-reopen and Quit fixes in build 23.

## Delivery Boundary

Frame's manual GitHub pre-release channel for Apple silicon and Intel Macs running macOS 14 or later.

## Work

Freeze the source, run the Frame tests, build and notarize the universal app, and publish the stapled archive as `Frame.zip` under `frame-v2.0.0-beta.3`.

## Acceptance

- The release identifies build 23, the compatible RelayBar beta and the open report about Icons mode.
- A clean extraction passes the signature, entitlement, architecture, symbol, resource, Gatekeeper and staple checks.
- The annotated tag points to the tested source. The anonymous download matches the checked archive byte for byte, and GitHub lists the release as a pre-release.

The [release verification](../../verification/075-frame-2.0.0-beta-3.md) records the public asset, notarization and native retest.
