# Public-readiness cleanup

Status: Implemented — 2026-11-16. Automated checks pass; [verification](../verification/065-public-readiness.md). The plugin has not been tried in a running app.

## Outcome

The uncommitted work from Tasks 050–064 can be committed to the public repository: it carries no personal paths or private workflow records, Frame's bundle identifier matches RelayBar's, and RelayBar shows Frame only to people who have it.

## Delivery Boundary

One local commit on the feature branch. No push, release-version change, installation, Apple submission or publication. Acceptance of Tasks 058–063 remains separate.

## Work

- Rename Frame's bundle identifier and its two helper identifiers to the `com.lx2026.Frame` prefix.
- Add an Open in Frame plugin to RelayBar that switches the Frame bridge and the window's Frame controls. Its default is on only when Frame is installed at launch; an explicit choice takes precedence.
- Remove home-directory paths, private project names, tool-session identifiers and private links from documents and screenshots, and delete the duplicated design preview that embeds third-party harness code.

## Acceptance

- No file to be committed contains the maintainer's home path or username, a private project name, or a tool-session link or identifier; every edited screenshot is inspected.
- With the plugin off, RelayBar shows no Frame control and starts no bridge listener. Tests cover the default, the explicit choice and switching at runtime.
- `scripts/test.sh`, both app builds and `git diff --check` pass on the final tree.
- The relevant system specs and a verification record are updated.
