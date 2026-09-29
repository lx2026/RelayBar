# Task 048 — Profile Editor Validation and Layout

Status: Complete

Created: 2026-09-28

Completed: 2026-09-28

Evidence: [Verification](../../verification/046-048-remote-files-and-editor-usability.md)

## Outcome

Explain disabled profile submission and keep forwarding-rule controls inside
the editor's standard viewport.

## Delivery Boundary

Preserve profile validation and SSH safety rules while improving the form's
explanations and layout. No invalid profile may be saved.

## Work

- Show the first actionable validation reason beside the fixed submit area,
  including the rule number and missing or invalid port when applicable.
- Make rule-type controls fit the card without clipping its right border.
- Render the SSH-host placeholder as plain text without link styling.

## Acceptance

- New and invalid edited profiles show a visible reason for disabled saving,
  even when the incomplete field is below the fold; valid profiles still save.
- Add/Edit rule cards and every rule type stay inside the 380-point viewport.
- Relevant validation tests, visual evidence, system specs, and diff checks pass.
