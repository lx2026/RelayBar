# HTML preview in both apps

Status: Complete — 2026-11-07

## Outcome

Open HTML directly in RelayBar or Frame, including online scripts, stylesheets, fonts and images. The user explicitly approved online resources on 2026-11-07, replacing the previous offline-only requirement.

## Work

- Add HTML/HTM to RelayBar's native preview, with requested relative resources fetched through its existing connection.
- Allow online HTML resources in both apps. Keep temporary storage, folder-relative access and document keyboard focus.
- Verify actual rendering, local dependencies, online resources and existing previews; rebuild/update both Applications bundles with build-only increments.

## Acceptance

- HTML opens inside RelayBar instead of falling through to Download.
- Both render online CSS/JS and data without the old offline-policy message.
- HTML inputs do not trigger file deletion or previous/next-file shortcuts.
- Only requested relative resources transfer; closing the RelayBar preview cancels requests and releases temporary content. No history entries are created for dependencies.
- Signed updated apps are running in Applications; release versions remain 0.1.0 and 1.6.0.

Evidence: [verification](../system-specs/verification-2026-11-07-html-parity.md). Frame 0.1.0/15 and RelayBar 1.6.0/20 are signed and running. HTTPS resources are enabled; macOS transport restrictions remain unchanged.

User confirmation: “works” on 2026-11-07 in response to the requested RelayBar Remote Files check. This closes the remaining installed-preview verification item.
