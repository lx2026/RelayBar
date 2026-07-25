# Accepted Task Specifications

Move a task spec into this directory only after its acceptance criteria pass and its status is `Complete`.

- [Task 001 — Remote Files](001-remote-files.md)
- [Task 002 — Read-only Markdown](002-read-only-markdown.md)
- [Task 003 — Flexible SSH Forwarding Profiles](003-flexible-ssh-forwarding.md)
- [Task 004 — Group Saved Forwards by Tag](004-group-saved-forwards-by-tag.md)

Tasks 005 through 019 came from one review pass over the app sources for reliability, performance, and conciseness. They share [one verification report](../../verification/005-019-audit-remediation.md).

- [Task 005 — Reject Remote Paths That sftp Would Glob](005-reject-glob-metacharacter-paths.md)
- [Task 006 — Clear Control Pipe Handlers Before Draining](006-clear-pipe-handlers-before-draining.md)
- [Task 007 — Key SSH Control State by Launch](007-key-control-state-by-launch.md)
- [Task 008 — Remove the PID-Based Force-Kill Race](008-remove-pid-force-kill-race.md)
- [Task 009 — Build Tunnel Grouping Once Per Render](009-build-grouping-once-per-render.md)
- [Task 010 — Compile the PermitRemoteOpen Expression Once](010-compile-permitremoteopen-expression-once.md)
- [Task 011 — Bound Directory Download Progress Polling](011-bound-directory-progress-polling.md)
- [Task 012 — Cheapen Syntax Highlight Cache Lookups](012-cheapen-highlight-cache-lookups.md)
- [Task 013 — Hoist Cancellation Checks Out of Leaf Scanners](013-hoist-cancellation-checks.md)
- [Task 014 — Remove Formatter and Filesystem Work From View Bodies](014-remove-work-from-view-bodies.md)
- [Task 015 — Table-Driven sftp Error Messages](015-table-driven-sftp-messages.md)
- [Task 016 — Deduplicate Control Output Buffering](016-deduplicate-control-buffering.md)
- [Task 017 — Name the Master Error Buffer Limit](017-name-master-error-buffer-limit.md)
- [Task 018 — Remove Dead Compatibility Accessors](018-remove-dead-compatibility-accessors.md)
- [Task 019 — Count Running Phases Without an Intermediate Array](019-count-running-phases-without-array.md)
