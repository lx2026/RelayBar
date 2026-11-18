# Frame + RelayBar: UI review brief

Status: Proposed — external design review
Created: 2026-10-22

Frame is a minimal native macOS media viewer: a contact sheet with adjustable thumbnails, a resizable attached preview and metadata pane, favorites, native batch selection, safe Trash/Undo, and exact-copy export. PNG/JPEG and MP4/MOV/M4V only. Local folders stay in place; no import catalog for media.

Approved additions: pair media and unambiguously matching JSON as one asset; keep JSON separately labelled from embedded metadata. Archive moves whole assets into a managed Archive subfolder and Restore refuses collisions. Remote folders use SSH/SFTP inside Frame, with saved hosts and paths, not Finder mounts. First remote version is read-only, bounded folder-by-folder browsing and on-demand caching; no remote Trash/Archive yet.

The user now wants a one-click **Open in Frame** action in RelayBar's remote file browser, or the Frame download website when absent. They want both apps to share saved history seamlessly. RelayBar is an existing SSH utility with saved hosts and recently opened remote paths. This brief contains requirements and conceptual behavior only: no RelayBar source, actual hosts, private keys, or connection records.

Constraints: Frame currently retains App Sandbox. A disposable sandboxed SFTP authentication proof succeeded with explicit identity and known-hosts files. Production authentication and cross-app authority still need a secure design. Do not silently copy credentials, grant broad home access, disable host-key checks, share app-scoped bookmarks as if portable, or trust arbitrary URL-scheme requests to trigger network activity. Frame has no verified public download URL yet. No website publication is authorized by this task.

Candidate UI: RelayBar has one toolbar action, **Open in Frame** (context menu equivalent). Current folder opens in Frame; a selected supported media file focuses that asset. Frame retains the same contact-sheet/preview/metadata layout with a quiet `host · path` location label. A remote connection chooser uses saved locations first, with manual connection setup secondary. Recent locations are distinct from saved host definitions and credentials. A first-link consent pairs the two apps once; repeated launches from that trusted association should be one click. Unknown callers are confirmation-gated. Missing Frame offers an explicit Get Frame action without transmitting host/path to a website.

Please critique the complete flow in practical terms: (1) the smallest coherent sharing model for recent locations and saved hosts, (2) first-use versus repeat-use behavior, (3) folder versus selected-file handoff, (4) absent app / offline / denied permission states, (5) minimal changes to the contact sheet for JSON and Archive, and (6) concrete wording and layout. Identify assumptions requiring a user choice. Do not invent a download URL. Offer a compact text wireframe and prioritize 3–5 refinements. Avoid adding unrelated features.
