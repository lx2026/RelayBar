# Task Specifications

Task specs are executable delivery contracts. Active specs live directly in this directory. Deferred proposals live under [`backlog/`](backlog/), and accepted specs move to [`archive/`](archive/).

## Required structure

Each new task should define:

- the intended outcome;
- the current authorities and constraints;
- what is included and excluded;
- the required work;
- observable acceptance checks;
- completion artifacts and explicitly deferred work.

Keep requirements in one place and keep future ideas outside the current acceptance boundary.
Application UI work also follows the
[RelayBar Interface Principles](../designs/interface-principles.md).

## Completion protocol

A task may be marked `Complete` only after:

1. every acceptance criterion has current evidence;
2. affected files under [`../system-specs/`](../system-specs/) describe the implemented behavior;
3. relevant automated and manual checks pass;
4. required evidence is recorded;
5. the spec is moved to [`archive/`](archive/).

Completion does not authorize a commit, push, release, or deployment. Follow [`AGENTS.md`](../../AGENTS.md) and obtain explicit deployment approval.

## Active tasks

- [Task 065 — Public-readiness cleanup](065-public-readiness.md) — implemented; Frame bundle identifier, Open in Frame plugin and removal of personal details before the first commit; automated checks pass, native acceptance not run

- [Task 063 — One Markdown renderer](063-one-markdown-renderer.md) — implemented; one shared renderer with RelayBar's reading design, drawn by WebKit in both apps; automated gate passes, native acceptance not run

- [Task 062 — Three sample plugins](062-sample-plugins.md) — implemented; Reconnect on Wake and Service Labels in RelayBar, Prompt Search in Frame; automated gate passes, native acceptance not run

- [Task 061 — Plugin catalog and composer](061-plugin-catalog-and-composer.md) — implemented; feature graph, per-app plugin catalog and a shared Plugins window; automated gate passes, native acceptance not run

- [Task 060 — Lines reduction](060-lines-reduction.md) — implemented; 586 production and 301 test lines removed by concept, no behaviour change intended, no test case removed; three larger cuts left for the owner

- [Task 059 — Single-owner composition kernel](059-single-owner-composition.md) — in progress; all work implemented and the automated gate passes; the guard-count acceptance line is unmet against pre-058 numbers and native acceptance stays with Task 058

- [Task 058 — Composable architecture for RelayBar and Frame](058-composable-app-architecture.md) — in progress; existing RelayBar monorepo, all six phases, separate app releases and preserved Homebrew/Sparkle setup

- [Task 052 — Frame remote assets](052-frame-remote-assets.md) — implemented and installed; remaining native acceptance overlaps Task 058; superseded permission/cache requirements are historical

- [Task 050 — Frame viewer handoff](050-frame-viewer-handoff.md) — implemented; native handoff/focus/offline acceptance overlaps Task 058

- [Task 032 — Release and Manual Acceptance](032-release-and-manual-acceptance.md)
- [Task 037 — Implement Remote Files Workspace](037-implement-remote-files-workspace.md) —
  in progress

## Backlog

No deferred tasks.

## Recent completed work

- [Task 064 — Paired-app release preparation](archive/064-release-preparation.md) — complete; universal Frame packaging, app-specific notarization, README/site refresh and a verified review patch sequence; no publication

- [Task 055 — Frame batch Delete and companion groups](archive/055-frame-batch-delete.md) — complete; RelayBar 1.6.0/17 and Frame 0.1.0/11 installed

- [Task 057 — HTML preview](archive/057-html-preview.md) — complete; installed as 1.6.0/20, tests pass, user confirmed it works.

- [Task 056 — Frame document workspace](archive/056-frame-document-workspace.md) — complete; RelayBar 1.6.0/18 and Frame 0.1.0/14 installed and running; native remote documents verified

- [Task 054 — Development version correction](archive/054-development-version-correction.md) — Complete; release labels restored, builds 16/10 retained, both apps updated.

- [Task 053 — Frame direct Delete](archive/053-frame-direct-delete.md) — Complete; development labels corrected by Task 054.

- [Task 051 — Explicit Frame folder history](archive/051-explicit-frame-history.md) — Complete; local 1.7.1/13 and Frame 0.5.1/7 installed.
