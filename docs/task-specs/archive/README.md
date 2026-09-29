# Accepted Task Specifications

Move a task spec into this directory only after its acceptance criteria pass and its status is `Complete`.

- [Task 001 — Remote Files](001-remote-files.md)
- [Task 002 — Read-only Markdown](002-read-only-markdown.md)
- [Task 003 — Flexible SSH Forwarding Profiles](003-flexible-ssh-forwarding.md)
- [Task 004 — Group Saved Forwards by Tag](004-group-saved-forwards-by-tag.md)

Tasks 005 through 019 came from one review pass over the app sources for reliability, performance, and conciseness. They share [one verification report](../../verification/005-019-audit-remediation.md).

- [Task 005 — Reject Remote Paths That sftp Would Glob](005-reject-glob-metacharacter-paths.md) — **withdrawn**, the finding was incorrect and the change was reverted
- [Task 006 — Clear Control Pipe Handlers Before Draining](006-clear-pipe-handlers-before-draining.md)
- [Task 007 — Key SSH Control State by Launch](007-key-control-state-by-launch.md)
- [Task 008 — Remove the PID-Based Force-Kill Race](008-remove-pid-force-kill-race.md)
- [Task 009 — Build Tunnel Grouping Once Per Render](009-build-grouping-once-per-render.md)
- [Task 010 — Compile the PermitRemoteOpen Expression Once](010-compile-permitremoteopen-expression-once.md)
- [Task 011 — Bound Directory Download Progress Polling](011-bound-directory-progress-polling.md)
- [Task 012 — Cheapen Syntax Highlight Cache Lookups](012-cheapen-highlight-cache-lookups.md) — **withdrawn**, measured 28-179x slower than what it replaced
- [Task 013 — Hoist Cancellation Checks Out of Leaf Scanners](013-hoist-cancellation-checks.md) — **withdrawn**, the removed cost measured under 1% of a render
- [Task 014 — Remove Formatter and Filesystem Work From View Bodies](014-remove-work-from-view-bodies.md)
- [Task 015 — Table-Driven sftp Error Messages](015-table-driven-sftp-messages.md)
- [Task 016 — Deduplicate Control Output Buffering](016-deduplicate-control-buffering.md)
- [Task 017 — Name the Master Error Buffer Limit](017-name-master-error-buffer-limit.md)
- [Task 018 — Remove Dead Compatibility Accessors](018-remove-dead-compatibility-accessors.md)
- [Task 019 — Count Running Phases Without an Intermediate Array](019-count-running-phases-without-array.md)
- [Task 023 — Homebrew Cask](023-homebrew-cask.md)
- [Task 028 — Secure Self-Updates](028-secure-self-updates.md)
- [Task 029 — Formal Notarized 1.3.0 Release](029-formal-notarized-1.3.0-release.md)
- [Task 030 — Show Version and Project Links](030-version-and-project-links.md)
- [Task 031 — Fix Edit Profile Insets](031-fix-edit-profile-insets.md)
- [Task 033 — Private Update Rehearsal Correctness](033-private-update-rehearsal-correctness.md)
- [Task 034 — Open Direct Remote File Paths](034-open-direct-remote-file-paths.md)
- [Task 035 — Stabilize Copy Confirmation Test](035-stabilize-copy-confirmation-test.md)
- [Task 038 — Reliable Homebrew Upgrade and Visible Group Controls](038-homebrew-upgrade-and-group-controls.md)
- [Task 039 — RelayBar 1.5.1 Stable Release](039-relaybar-1.5.1-release.md)
- [Task 040 — JSON Preview and Upload Percentage Progress](040-json-preview-and-upload-progress.md)
- [Task 041 — Direct Remote File Deletion](041-remote-file-deletion.md)
- [Task 042 — File Selection Mode and Bulk Delete](042-file-selection-and-bulk-delete.md)
- [Task 043 — JSON Preview Wrapping and Scrolling](043-json-preview-wrapping-and-scrolling.md)
- [Task 044 — MP4 Video Preview](044-mp4-video-preview.md)
- [Task 045 — Configurable SSH Retries](045-configurable-ssh-retries.md)
- [Task 046 — Remote Delete Undo Window](046-remote-delete-undo-window.md)
- [Task 047 — Readable Connection and Path Labels](047-readable-connection-and-path-labels.md)
- [Task 048 — Profile Editor Validation and Layout](048-profile-editor-validation-and-layout.md)
- [Task 049 — RelayBar 1.6.0 Stable Release](049-relaybar-1.6.0-release.md)
