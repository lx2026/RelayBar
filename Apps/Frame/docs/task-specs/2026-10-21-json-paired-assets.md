# Image and JSON paired assets

Status: Completed in 0.3.0, build 4 — 2026-10-22
Created: 2026-10-21

## Objective

Treat a media file and its matching JSON sidecar as one logical asset for browsing, selection, and file actions, while keeping both original files on disk.

## Scope and decisions

- Follow the exact-name and unambiguous-stem rules in the [shared design](../design/2026-10-21-remote-archive-assets.md).
- One tile, one favorite, one selected asset. Show a small JSON badge and an inspector section naming the sidecar.
- Read JSON lazily, off the UI thread, with a 2 MiB read limit and bounded formatting. Display errors without hiding the media. Never fetch references, execute content, rewrite JSON, or merge it silently into embedded metadata.
- Fresh member checks, explicit pair-aware Trash/Undo, exact export, and Archive/Restore. Pair-aware export must obtain directory permission and confirm replacement targets.
- Local pairing can be delivered before remote access; the asset model must not depend on temporary remote cache paths.

## Acceptance

- [x] Match `photo.jpg.json` preferentially; match `photo.json` only with one supported media stem. Handle uppercase extensions without fuzzy filename matching.
- [x] Reject ambiguous, symlinked, or outside-root sidecars; standalone JSON does not inflate media counts.
- [x] A sidecar content change invalidates metadata on Refresh without needlessly invalidating media thumbnails.
- [x] Malformed/oversized JSON keeps image preview and safe identity metadata available.
- [x] Every action validates all members before touching either file. Missing/changed members fail the asset with a clear explanation.
- [x] Trash/Undo/export failures and rollback collisions are tested; no orphaned pair is silently presented as complete.
- [x] Paired export replaces destination bytes and metadata for every approved member and refuses ambiguous old JSON.
- [x] Existing unpaired media behavior and favorites schema remain compatible.

## Evidence

[Verification](../system-specs/verification-2026-10-22.md): 52 passing Frame tests, native paired Archive/Restore, dark/light screenshots, and installed signed build. The design review led to readable JSON fields after Capture, nested disclosures, and separately collapsed Raw JSON. No physical disk-failure matrix or live remote-host UI is claimed by this local-asset task.

## Exclusions

No ZIP/container format, schema-specific generation editor, fuzzy pairing, arbitrary group creation, or JSON mutation.
