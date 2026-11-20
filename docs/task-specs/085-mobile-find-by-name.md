# Task 085: Find a file by name in the mobile app

Status: Active
Design: [RelayBar for iPhone and iPad](../designs/relaybar-ios.md)
Depends on: Task 084

## Outcome

Typing a few letters of a file's or folder's name in the location field finds it anywhere under the host's places, so a note in a large folder is reached without walking to it.

## Delivery Boundary

Included: `Apps/RelayBarMobile`.

Excluded: searching inside files, running any command on the host, and any change to the transport beyond what listing a folder already offers.

## Work

1. **Index.** For each folder place of a host, keep a list of the names beneath it, built by listing folders through the existing files port. No file is read. Limits per place: 20,000 files, 3,000 folders and twelve levels; Home is walked two levels deep. Hidden entries and folders that hold dependencies or build output are skipped. When a limit stops the walk, the index records it.
2. **Cost.** The walk yields to page traffic, keeps at most four listings in flight and stops when the app leaves the screen or the session is lost, resuming where it stopped. It starts after sign-in when a place has no index or one older than fifteen minutes. With Data Saver on it starts only when the person first searches. Any folder listing the app performs for another reason updates that folder's entries.
3. **Storage.** The index lives in the purgeable cache under the same identity as cached files (profile, account, pinned host key) and is removed with the host or the place.
4. **Matching.** Case and accents are ignored. Every word typed must appear in the path relative to the place. Order: name starts with the text, a word in the name starts with it, the name contains it, a folder on the path contains it; then documents read before, then shorter paths. At most thirty results. Titles of documents already read match as names do.
5. **Results.** The location field adds a Files source after Places: name, folder relative to its place, and the place when there is more than one. A file opens; a folder opens and can be pinned. Beneath the results, one quiet line reports a walk in progress with its count, or that a limit was reached and that pinning a deeper folder searches inside it.
6. **Plugin.** The feature is a plugin, File Search, on by default, with a per-host override. Off, nothing is walked and stored indexes for that host are removed.
7. **Keyboard.** On iPad with a hardware keyboard, Command-K puts the cursor in the location field.
8. **Gallery and specs.** The gallery shows results for a typed name, the in-progress line and the limit line. Update `docs/system-specs/modules/mobile-app.md` and the Plugins table of the design page.

## Acceptance

- With a pinned folder holding files several levels down, typing part of a deep file's name lists it, and choosing it opens the document.
- A walk in progress does not delay opening a document: page reads are served first.
- A place over a limit reports it and still returns matches from what was indexed.
- Turning File Search off for a host stops the walk and deletes that host's index; removing a host or a place deletes theirs.
- With Data Saver on, no listing is made for the index until the first search.
- Unit tests cover the limits and skips, resuming, matching order, storage identity and removal, and the Data Saver rule, against a fake files port.
- `scripts/test.sh mobile` passes, the app builds for the iOS SDK with warnings as errors, and the gallery images are regenerated and reviewed.
