# 2026-10-21: Video viewing

Task status: Completed — 2026-10-21\
Design status: Accepted — user approved implementation; see the Contact Sheet amendment for later selection changes

## Outcome

Browse local MP4, MOV, and M4V alongside JPEG/PNG, play the selected video, and read its metadata in the same inspection workspace.

[Reviewed design](../design/2026-10-21-frame-redesign.md) · [Interactive mock](../design/assets/2026-10-21-frame-redesign/frame-redesign.html)

## Interaction contract

- Scan supported video extensions recursively and case-insensitively. A supported container does not guarantee a supported codec; use macOS decoding through AVFoundation/AVKit.
- Show a cached poster, play badge, and duration in the shared filmstrip/contact sheet. Preserve aspect ratio in the stage.
- Open paused with native playback, scrub, and audio controls. Stop and release playback on selection/root/scope change; retain position across Focus transitions.
- Keep the selected video and metadata adjacent. Async reads must not allow a previous selection's metadata or frame to overwrite the current selection.
- Metadata, when present: duration, dimensions with orientation applied, frame rate, video codec, file size, creation date, and audio presence/format. Omit unknown fields and expose remaining readable embedded metadata.
- An unsupported or corrupt video shows a concise error and Reveal in Finder; file identity and available metadata remain usable.

## Keyboard and actions

Space plays/pauses a video only. Return enters/leaves Focus when the viewer owns keyboard input. Arrow keys navigate files when the viewer owns input; focused native controls, fields, menus, and disclosures retain their normal keys. Tooltips and native menus expose the shortcuts.

Favorite, folder-scoped filtering, Trash/Undo, and Export apply equally to videos. Export preserves the original container and complete bytes, replacing the destination's former metadata with the source's metadata. Large copies must not block the UI. Unsupported playback must not prevent an otherwise valid byte copy.

Centralize command availability so menu shortcuts and toolbar actions agree. No playback is allowed without an active player; no export/delete is allowed without an available selected source.

## Implementation boundary

Extend the media format model and scanner without changing persisted root IDs/favorite keys. Add async video metadata and bounded poster caching, and use a native player for the stage. Prefer a representative frame just after the start, with a safe fallback for very short or undecodable clips.

Primary components: `PhotoItem`, `FileScanner`, `ImageRepository`, metadata services, `LibraryStore`, `MainWorkspace`, and native commands. Internal renaming is optional; a large model migration is not required.

No transcoding, editing, codec downloads, streaming, or network features. The later Contact Sheet amendment adds batch Trash for both images and videos; batch export remains excluded.

## Acceptance and verification

- [x] Mixed nested JPEG/PNG/MP4/MOV/M4V fixtures scan and filter correctly.
- [x] Real short fixtures produce posters and metadata; native playback and timeline seeking verified. AAC track/controls verified; audible-output listening remains manual.
- [x] Automated navigation/root/filter lifecycle and stale-result tests pass; previous players are stopped and released.
- [x] Portrait/rotated and very short fixtures preserve geometry, including a native 90 × 160 MOV.
- [x] Corrupt video finishes with no poster and usable identity; the player exposes an actionable error view.
- [x] Viewer keys are scoped to focus; native controls retain their keys. Empty/unavailable actions and layered Escape verified. Full control/accessibility traversal remains manual.
- [x] Existing export destination becomes byte-identical to source; source is unchanged, including alias protection.
- [x] Existing image/metadata tests pass; bounded reusable thumbnail work is separate from playback.

## Completion record

Delivered in Frame 0.2.0 (build 2), installed in Applications. Added AVFoundation metadata/posters, paused AVKit playback, static Browse posters, and off-main-thread exact exports without changing the persisted favorite schema.

Verification: 30 tests passed, including real MP4/MOV/M4V fixtures, orientation, corruption, stale results, lifecycle, and destination replacement. Native playback, 0.5-second timeline seeking, and both appearances were checked. [Delivery evidence and screenshots](../system-specs/verification-2026-10-21.md).

Limits: codec support is macOS-provided; no codecs, editing, or transcoding added. Audible-output listening, broad real-world codec coverage, older OS, and Intel hardware were not tested. The later Contact Sheet spec extends this task with video batch Trash, not batch export.
