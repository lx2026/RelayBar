# Three sample plugins

Status: Implemented — 2026-11-14. The automated gate passes; no plugin was tried in a running app, on a real wake, or against a real forwarded service. Evidence: [verification record](../verification/061-062-plugins.md).

## Outcome

Three plugins that are useful in the work these apps exist for (forwarding ports to remote machines and reviewing what those machines produce), each small, each exercising a different part of the kernel, all visible and switchable in the Plugins window from [Task 061](061-plugin-catalog-and-composer.md).

## Delivery Boundary

- Each plugin is one feature, owns everything it starts, and is off or on without affecting anything it does not depend on. With a plugin off, its app looks and behaves exactly as it does today.
- No plugin executes a command on a remote host, changes a remote file, or stores what it reads.
- Default state: Reconnect on Wake on; Service Labels off (it sends a request through the tunnel); Prompt Search on.
- Excluded, recorded as candidates: remote host vitals (needs a remote command, so a security review first), a watched remote folder that notifies and opens in Frame, side-by-side compare in Frame, connection history.

## Work

1. **Reconnect on Wake** (RelayBar, id `recovery`). Needs the tunnel store. When the Mac wakes, or the network path goes from unsatisfied to satisfied, every profile that is waiting to retry starts its next attempt now instead of at the end of its backoff. The attempt count and remaining budget are unchanged; stopped, failed and exhausted profiles are not touched. Triggers are debounced so a wake followed by a network change causes one retry. The store gains one method for this; the event sources are injected so tests need neither sleep nor a real network change.
2. **Service Labels** (RelayBar, id `services`). Needs the tunnel store; offers a label board the tunnel list reads through a port. For each running profile, for each rule that already supports Open in Browser, it requests the local URL once when the profile starts running and then every 30 seconds, and shows a short label on that rule: a recognised product name (ComfyUI, Jupyter, TensorBoard, Gradio, Stable Diffusion WebUI, Open WebUI), otherwise the page title, and whether it answered. Requests go to loopback only, with no cookies or credentials, a three-second timeout, at most 64 KiB read, and no redirect to another host. Labels disappear when the profile stops. The prober is injected for tests.
3. **Prompt Search** (Frame, id `prompt-search`). Mounted once at the root and once in the `remote` realm, written once against the realm's media source. It offers an index the workspace reads through a port. Typing in a search field filters the current folder to assets whose file name or companion text (prompt JSON, notes, PNG text chunks locally; companion text through the session remotely) contains every word typed, ignoring case and diacritics. Text is read lazily with bounded concurrency, cached in memory up to a fixed total while the plugin is loaded, and never written anywhere; a remote companion that could not be read is neither searched nor cached. A newer query supersedes an older one; a result that arrives after the plugin or the session is withdrawn is dropped. The field lives in the toolbar, which is not rebuilt while someone types, is visible in both layouts, shows how many assets match, and takes focus with Command-F. The selection always stays inside the filtered list. With the plugin off there is no field.
4. Register all three in their app's catalog with a title, summary and symbol, and update the relevant system specs (process lifecycle, application shell, security boundaries, Frame's workspace spec).

## Acceptance

- Reconnect on Wake: with the fake SSH fixture, a profile waiting on a long backoff starts its next attempt promptly after an injected wake and after an injected network return, with the same attempt number it would have had; a failed profile and a stopped profile are unchanged; two triggers inside the debounce window cause one attempt; with the plugin off nothing happens; unloading removes its observers.
- Service Labels: labels appear for a running profile's HTTP rule and clear when it stops; a non-HTTP rule is never requested; an unanswered port shows as not responding without an error alert; a redirect to another host is not followed; with the plugin off the tunnel list is unchanged and nothing is requested.
- Prompt Search: a folder fixture with JSON, TXT and PNG-text companions returns exactly the expected assets for single-word, multi-word and no-match queries; the remote realm works through a fixture session and stops at once when that session is withdrawn; a superseded query never overwrites a newer result; a query that excludes the selected asset leaves nothing selected outside the visible list; turning the plugin off removes the field and restores the unfiltered list.
- Each plugin appears in the Plugins window with its dependencies, and its dependents are named before it is turned off.
- `scripts/test.sh` passes with warnings as errors; both apps build, including RelayBar's Xcode target; `git diff --check` passes.
