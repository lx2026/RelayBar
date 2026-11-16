# Tasks 061 and 062 verification

Status: Implemented — 2026-11-14. The plugin catalog, the Plugins window and the three plugins are in both apps and pass the automated gate. Nothing here was tried in a signed, running app; see "Not verified".

## What was built

- **Kernel** (`Composition`): `FeatureGraph` published by the runtime, `dependents(of:)`, `PluginDescriptor`, `PluginChoices`.
- **Plugins window** (`CompositionUI`, inside the `Composition` library product): `PluginComposer`, `PluginComposerView`, `FeatureMapLayout`.
- **RelayBar**: catalog `RelayPlugins`, a `plugins` object in `preferences.json`, a Plugins row in Settings, and two plugins, Reconnect on Wake (`recovery`, on by default) and Service Labels (`services`, off by default).
- **Frame**: catalog `FramePlugins`, a `plugins` object in `preferences.json`, a Plugins… item in the app menu, and Prompt Search (`prompt-search`, on by default, mounted at the root and in the `remote` realm).

Lines added, production: shared 1,052 (graph and catalog 180, window 862, runtime 10); RelayBar 688 (catalog, window and Settings 126, Reconnect on Wake 105, Service Labels about 455); Frame 581 (Prompt Search, its store state and toolbar field, the typing guard, the catalog and window). Tests added: about 385 shared, 970 RelayBar, 770 Frame.

## Acceptance

Task 061:

- Graph: nodes, edges and realm containers for a known tree; an unsatisfied need with and without a provider; the graph changing when a slot fills and clears; `dependents(of:)` transitive and including children (`FeatureGraphTests`, 4).
- Layout: providers left of consumers, no overlapping nodes, containers enclosing exactly their members, a stable result, spacing read from the layout's own metrics (`FeatureMapLayoutTests`, 5).
- Choices: defaults, overrides, an override removed when set back to the default, the plain-object JSON shape (`PluginChoicesTests`, 3).
- Per app: switching a plugin changes only its features and leaves every other feature's generation alone; the choice survives a restart; a preference document without `plugins` loads with defaults (`PluginTests` in RelayBar; `PromptSearchTests` and `PreferenceMigrationTests` in Frame).
- Snapshots: produced offscreen by opt-in tests and reviewed. The shared fixture (`COMPOSITION_SNAPSHOT_DIR`) covers running, waiting, failed and off states with and without a selection, light and dark. Each app renders the window from its own running tree (`RELAYBAR_SNAPSHOT_DIR`, `FRAME_SNAPSHOT_DIR`). Five of those are kept in [assets/061-plugins-window](assets/061-plugins-window/): RelayBar as installed and with Service Labels selected; Frame without RelayBar, with the waiting remote source selected, and connected with the remote search feature selected in dark appearance.

Task 062:

- Reconnect on Wake: a profile waiting on a 60-second delay makes its attempt at once on an injected event and keeps its attempt number and budget; two events inside the debounce window make one attempt; failed and stopped profiles are untouched; switching the plugin off ends the event stream, cancels a pending wait and later events do nothing; `retryNow()` outside a scheduled retry does nothing; nothing launches after command admission closes.
- Service Labels: labels appear when a profile runs and go when it stops; only rules that open in a browser are asked, and only on loopback; a rule bound elsewhere shows nothing; a changed rule set is asked afresh; an unanswered port shows "no response" without an alert; at most four probes run at once; switching the plugin off with four probes held and two queued finishes and records nothing; with the plugin off nothing is asked. The probe itself, against a loopback listener: non-loopback and HTTPS URLs are refused without a request; redirects to another host, port or scheme are not followed and one carrying a name and password is followed without them; only the fixed headers are sent; no cookie or credential is sent and a challenge is not answered or retried; a body promised at ten megabytes is cut at 64 KiB without waiting for the rest or the timeout.
- Prompt Search: exact results for single-word, multi-word and no-match queries over JSON, TXT and PNG-text companions; the whole of a local companion is searched, not its display-shortened form; the remote realm answers through a fixture session and a withdrawn session stops a pending search and clears the query; a superseded query never overwrites a newer result; the cache is reused, bounded, and bypassed when size, modification time or a remote `modified` value changes; an unreadable or cancelled read is not cached; nothing the search hides can be acted on; Show all files ends the search; views are told at once when the search feature comes and goes; unloading waits for a search in progress.
- Typing guard (`TypingGuard`): after typing in a text control that then lost the focus, Backspace, F and Space are dropped and the search field is refocused; a click or Tab releases it; editing commands and Return, Enter or Escape in the search field do not; without earlier typing nothing changes.

## Independent review

Both plugin lanes were read by a second reviewer, Frame's twice.

- **RelayBar.** Reconnect on Wake's retry path was found sound. For Service Labels the review led to: HTTP only, so no certificate is evaluated and nothing can be fetched on a certificate's behalf; every redirect sent as the probe's own rebuilt request; fixed `User-Agent`, `Accept` and `Accept-Language` in place of defaults that name the app, its version and the person's languages; and each probe's session torn down before the probe returns. Found in the architect's own read before that: a probe cancelled by its profile stopping could record a stale "no response"; a rule bound to another address showed "no response" for what was a refusal; a running profile whose rules changed kept its old targets; a configured proxy was not bypassed; and the page title was not stripped of control and formatting characters. All are fixed and tested. Not changed: the wake observer and path monitor are removed and cancelled when the feature unloads, but their callbacks are not drained.
- **Frame.** The first review found that typing in the search field could fall through to single-key shortcuts, because the grid takes the keyboard whenever it is rebuilt; that choosing a file in the sidebar could select an asset the search hides; that a cancelled read could be cached; and gaps in the cache key, ownership and memory. The second review found the same focus theft in the Preview layout's viewer and that Command-key edits released the guard. The result is the three protections described in the Frame viewer spec, selection and action targets limited to what the list shows, and the cache rules listed there. Accepted as they are: Undo restores what the last Trash operation moved whether or not the search shows it; `export(_:to:)` copies the asset its caller passes, and its caller is limited to a visible selection; an active search alone does not show "Clear filters" in the file filter menu, since the field has its own clear button.

## Gate

- `scripts/test.sh`, warnings as errors, exit 0 (`.build/task-060-062-final.log`): 2 release-plan tests, 68 shared (1 optional skip), 414 RelayBar (28 optional skips), 185 Frame (1 optional skip), zero failures.
- `swift build --package-path Apps/Frame --product Frame -Xswiftc -warnings-as-errors`: complete.
- `xcodebuild -project Apps/RelayBar/RelayBar.xcodeproj -scheme RelayBar -configuration Debug CODE_SIGNING_ALLOWED=NO build`: succeeded, which also shows the project lists the three new sources and links `CompositionUI` through the existing `Composition` product.
- `git diff --check`: clean.
- RelayBar's opt-in visual harness: `testCaptureRetrySettingsSnapshots` passes with the Plugins row present, so Settings still fits its 380 × 440 viewport without scrolling in either appearance; `testCaptureTunnelListSnapshots` passes with the tunnel row's label plumbing in place and Service Labels off. The harness's stall as a whole class is older than this work and is described in the [Task 060 record](060-lines-reduction.md).

## Not verified

- No signed build and no running app. Not tried by hand: the Plugins window in either app (switches, selection, scrolling, Retry, light and dark); the Settings row and the menu item that open it; the Service Labels text in the tunnel row and rule menu; Prompt Search's toolbar field at the 960-point minimum width, Command-F, Escape, and the three focus protections, whose AppKit parts (the grid's and viewer's focus rules, the key monitor's wiring) cannot be reached from the test target.
- No real wake or network change was produced; the system event source is covered only through its protocol. No real web service was probed through a real tunnel.
- Offscreen snapshots draw an "on" switch grey because the window is never key.
- Installed apps are unchanged. Nothing was committed, pushed, signed or published.
