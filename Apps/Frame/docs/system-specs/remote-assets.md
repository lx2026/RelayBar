# Remote assets

Snapshot: 2026-11-07 · Bridge v6 bundles installed as Frame 0.1.0/12 and RelayBar 1.6.0/18. Local signed update; no publication. RelayBar must relaunch to load the updated bridge; the locked Mac prevented native relaunch/visual checks.

## User flow

Open… → a RelayBar location → browse the expandable tree. Frame reads RelayBar's catalog but **never adds or promotes recent folders**, including explicit descendant opens. Only RelayBar's own navigation changes its history.

Contact Sheet retains adjustable thumbnails and a resizable attached preview/metadata panel. Thumbnails request 512-pixel derivatives; attached/enlarged image previews request up to 2048 pixels. Original explicitly downloads full image data. Selecting a video downloads that video for native playback; browsing the grid does not download every video. Export downloads the original and all companion files with the existing destination-replacement semantics.

Select → check targets while previewing → Delete: permanently unlink media and every companion on the host. No confirmation, delay, Trash or Undo. Delete also works in full-size view and Archive. One batch mutation/helper invocation handles up to 500 items and returns individual outcomes; 100 items in one retained folder use one request. Archive remains separate; Restore returns groups to their original paths. F/heart favorites the preview and advances without clearing checked targets.

Once Frame is linked to RelayBar, file actions require no further permission prompt. Host filesystem permissions still apply. Revoke disconnects Frame access.

## Host contract

Protocol 6 also serves Markdown/HTML through existing file transfers and adds `documentStat`, a metadata-only batch for at most 128 in-root resources. Frame renders on the Mac and downloads only the selected page and requested dependencies; no remote renderer or web server is required. [Document workspace](document-workspace.md) defines its containment, limits and live-update behavior. Markdown/HTML are independent primary items, excluded from media companions. Their dependencies are never grouped into document Delete/Archive/Export.

RelayBar runs a fixed program over its existing SSH session. JSON goes on stdin, never into shell text. There is no daemon, automatic installation or arbitrary-command API.

- Python 3 is required for listing/actions; Pillow for JPEG/PNG previews/metadata. ffmpeg/ffprobe is optional for grid video posters.
- Native video playback/metadata uses the selected original and does not require host video tools. Missing image preview dependencies still report an error rather than silently downloading every original.
- Symlinks, nonregular files and traversal are rejected. Directory handles use no-follow opens.
- Archive requires the same filesystem as the opened root. Open a mounted subtree directly to archive it. Delete does not move data and has no same-filesystem requirement.

## Asset safety

Frame and RelayBar share the same filename grouping algorithm: longest dot-delimited prefix in the same folder; exact media filename wins a tied stem; ambiguous stems remain ungrouped. Companion extensions and suffix labels are unrestricted. All non-media companions form one group, including multiple JSON and TXT files. The broker chooses members from its listing, not caller-supplied shell paths. Stat fingerprints identify files before mutation. Expired capabilities renew without history writes; changed groups are refused.

Delete uses direct unlink, without downloading or moving originals. Every group member is checked before deletion; a partial failure reports already-deleted paths. Only a successfully deleted archived item's known manifest and empty record directory are removed. No source directory is recursively deleted.

Archive/UUID retains original-path manifests. No-clobber hard links followed by unlink move regular files without downloading them. Archive moves preflight destinations and attempt rollback; Restore never replaces occupied paths. These are not multi-file atomic transactions. External writers, disconnection or termination can leave a partial group. Deleted files have no recovery path. Existing `.FrameTrash` folders from older builds are not automatically touched.

## Cache and limits

Remote derivatives, metadata and fetched originals live only under `FileManager.default.temporaryDirectory/FrameRemoteSession`. Normal termination clears the directory; startup clears crash leftovers and removes the former `Caches/FrameRemotePreviews-v1`. New cache instances never load a previous session's index. Removal of the old installed cache was verified after launching build 11.

Temporary derivative cache: 512 MiB/5,000 records with LRU eviction, atomic writes and an in-memory index. Decoded cache: 128 MiB; original cache: 512 MiB. Keys include all companion identities. Same-session revisits reuse validated content; new listings validate remote fingerprints. Two prioritized media operations and one directory request run from Frame. Offscreen consumers cancel.

Host limits: 4 MiB per derivative, 256,000 characters per metadata map/companion-text collection, 2 MiB per companion preview and 24,000 display characters per file, bounded PNG text and 80-million-pixel images. Binary companions remain grouped without a text preview. CPU/wall time: 30/50 seconds; Linux address space: 2 GiB. Bridge messages: 8 MiB. Original/companion downloads: 100 MiB per file.

Traversal retains its 10,000-entry listing, 512-folder, 20,000-asset and depth-64 bounds, Stop and partial results. RelayBar retains 32 listings, four active/32 tracked jobs, eight services and eight transfer directories. A delete batch uses at most 16 distinct listings, leaving room for preview renewals. Large recursive selections use several batches; expired folders must be relisted, so that first action has extra latency.

First-visit generation reads originals on the host, so its CPU/disk still matter. Reuse lasts only for the current session. [Current local verification](verification-2026-10-22-smooth-review.md) distinguishes synthetic measurements from untested private-host latency; [installed direct-delete verification](verification-2026-10-22-direct-delete.md) records the older Applications build.
