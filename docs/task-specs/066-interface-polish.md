# Interface polish

Status: Implemented — 2026-11-16. Automated checks pass; [verification](../verification/066-interface-polish.md). Awaiting the owner's review of the captures.

## Outcome

RelayBar and Frame each present one consistent button hierarchy, type scale, set of colour roles and spacing rhythm, with before-and-after captures for the owner to judge.

## Delivery Boundary

Visual and layout changes to the views under `Apps/RelayBar` and `Apps/Frame`. No change to behaviour, features, keyboard shortcuts, accessibility labels, shared packages, versions or installed apps; wording changes only where capitalisation or ellipsis use is inconsistent. One further local commit; no push. Larger changes to how a flow works are listed for the owner, not made.

## Work

- Give each surface a single emphasised action that matches its current state; keep other actions neutral, and separate destructive actions from their neighbours with the system destructive treatment.
- Reduce each surface to at most two button shapes with shared heights and aligned edges.
- Use system text styles with at most three levels per row, and keep text a person must read at readable contrast in light and dark appearance.
- Make selection look the same wherever it appears within an app.
- Gather values repeated three or more times into one small style file per app.

## Acceptance

- Before-and-after captures of the same screens and data exist for both apps in light and dark appearance.
- The interface principles hold: the default popover still fits its 380 × 440 point budget, and nothing clips at larger text.
- `scripts/test.sh`, both app builds and `git diff --check` pass.
- System specs that describe a changed control are updated, and a verification record lists what changed and what was left for the owner.
