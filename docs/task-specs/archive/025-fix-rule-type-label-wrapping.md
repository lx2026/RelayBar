# Task 025 — Fix Rule Type Label Wrapping

Status: Complete

Created: 2026-07-26

Issue: [#13 — The rule type label is wrapping incorrectly](https://github.com/lx2026/RelayBar/issues/13)

## Outcome

Keep the forwarding-rule type segmented control readable at the existing
380-point popover width without weakening its accessibility name.

## Delivery Boundary

- Change only the profile editor's forwarding-rule type picker presentation.
- Preserve all rule kinds, selection behavior, forwarding semantics, and the
  existing 380 × 440 popover.
- Do not release or deploy this change.

## Work

- Hide the picker's redundant visual **Type** label and provide a rule-specific
  accessibility label.
- Document the implemented editor contract.
- Capture and inspect the new-profile editor in light and dark appearances.

## Acceptance

- The rule type control shows the four segments without a wrapped or clipped
  **Type** label at 380 points wide.
- VoiceOver identifies the control as the current rule's type picker.
- Local, Local SOCKS, Remote, and Remote SOCKS remain selectable and unchanged.
- Light and dark editor snapshots, `swift test -Xswiftc -warnings-as-errors`,
  the Release build, and `git diff --check` pass.
- No release or deployment occurs.

## Evidence (2026-07-26)

- The rule-kind picker hides its visual label, retains all four unchanged
  segments, and exposes the explicit accessibility label `Rule <n> type`.
- `testCaptureTask025Snapshots` scrolls the real new-profile editor to the rule
  card at 380 × 440. The generated light and dark captures were inspected:
  all four segments stay on one line and no **Type** label is visible, wrapped,
  or clipped.
- The focused snapshot harness, `swift test -Xswiftc -warnings-as-errors`
  (180 tests; 13 opt-in skips), the Xcode Release build, and
  `git diff --check` pass.
- No release or deployment occurred.
