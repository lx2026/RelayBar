# Tasks 077–083: RelayBar for iPhone and iPad, closing verification

Date: 2026-11-19. Scope: the uncommitted change on the iPhone and iPad feature branch, based on `main` at `90c457e`, covering [Tasks 077–083](../task-specs/). Environment: Xcode 27.2 (27B52), Swift 6.4.2, iOS Simulator SDK 27.2, on an Apple silicon Mac. No simulator was booted and nothing ran on a device. All checks ran off screen.

## 2026-11-19 — Follow-up to the independent review

The feature branch had no upstream and its base `90c457e` matched the fetched remote main. All runtime checks ran headlessly on the Mac.

| Check | Evidence |
| --- | --- |
| HTML preview isolation | Before the fix, both new page-and-iframe cases printed FAIL. With preview-only Lockdown Mode, document-start API removal, the capture-permission denial and the updated policy, they printed `PASS Preview blocks WebRTC in page and iframe (internet off)` and `PASS Preview blocks WebRTC in page and iframe (internet on)`. Each realm attempted peer construction with the fixture's loopback TURN URL. The passive TCP listener received zero connections. The check ends at construction and does not exercise ICE gathering. Runtime verification on iOS remains open. |
| URL filtering | `publicInternetPreviewRules` passed with the added local suffixes and IPv6 ranges, including adjacent allowed addresses. With internet permission, the existing limit for public DNS names that resolve to private addresses remains. |
| Busy SSH session | `pathChangeDuringLargeReadPreservesSession` transferred 2 MiB while the server held the path-change stat reply until file close. The transfer lasted more than twice the configured probe timeout and kept the original SFTP client. The silent-probe recovery test also passed. |
| Gate rollback | Both address families were reserved during setup. A setup collision retries on a fresh port. Both post-failure rebind assertions passed in all three runs. |
| Mobile and transport suites | `./scripts/test.sh mobile` passed 40 Swift tests, ten WebKit cases and 17 script tests. Three consecutive `./scripts/test.sh transport` runs each passed 45 Swift tests and 17 script tests. |
| Generic iOS Simulator SDK build | The unsigned app built for the generic destination. Swift warnings were enabled and treated as errors across the app and its dependencies. The App Intents metadata tool reported its usual missing-framework notice. |
| Working tree | `git diff --check` passed. The edited files, including untracked sources, were also checked for trailing whitespace and absolute home paths. |

## Independent review of the closing fixes

Date: 2026-11-19. Each of the nine closing fixes was read with its test, and the suites were run again one at a time, off screen. No simulator was booted.

| Check | Result |
| --- | --- |
| `./scripts/test.sh shared` | 115 XCTest cases (90 and 25), four opt-in skips, zero failures. All 17 script tests passed. |
| `./scripts/test.sh transport` | First run: 43 of 44 passed. `gateRollsBackBothAddressFamilies` failed to bind the other address family's port (`EADDRINUSE`). Three re-runs and the run after this review's changes: 44 passed. |
| `./scripts/test.sh mobile` | 40 Swift tests, all eight web-view checks and 17 script tests passed, before and after this review's changes. |
| `./scripts/test.sh relaybar` | 465 XCTest cases, 33 opt-in skips, zero failures. |
| `./scripts/test.sh frame` | 234 XCTest cases, three opt-in skips, zero failures. |
| App for `generic/platform=iOS Simulator`, the documented command with `clean build` | Succeeded. `RelayBarMobile`, `MobileCore` and `MobileUI` compiled with warnings as errors. The only warning was the App Intents metadata notice. |
| Gallery and mobile tests with outbound IP connections limited to loopback (`sandbox-exec`) | The gallery wrote 82 PNGs, and the reference image followed the permission in both appearances. Web-view check: 8 of 8. Swift tests: 39 of 40. `openSSHContinueReading` cannot connect under this sandbox. The transport's loopback-only `sshd` tests fail the same way there, so the sandbox is the cause, not outside network use. The sandbox does not cover WebKit's own network process. |
| Windowless WebKit check of the internet-mode rules (loopback targets only) | 22 address forms were blocked. Each one reached the listener when the rules were removed. Forms: decimal, hex, octal, shortened and trailing-dot IPv4; user information (through an image load, since `fetch` refuses it); mixed-case and trailing-dot `localhost`; long-form `[::1]`; IPv4-mapped IPv6 in both spellings; `.localhost` subdomains; `https:` and `ws:`. A WebRTC TURN-over-TCP connection did reach loopback. |
| `git diff --check` | Clean. |

Mutation checks, each one restored afterwards:

- Making a path change always reconnect fails the new transport assertion. It also fails `openSSHContinueReading`, through that test's next SFTP call.
- Removing the 20 MiB ceiling fails `thumbnailsBoundReadsAndKeepOriginalOutOfCache`, but only through the demo host's out-of-range read error.
- Removing the sanitising on decode fails the new scene assertion.

| Item | Finding |
| --- | --- |
| 1 | Real for URL hosts, and confirmed in WebKit. Not covered: WebRTC (see below); names that resolve to private addresses (an accepted limit); suffixes and ranges outside the list, such as `.home`, `.corp`, `fec0::/10` and `64:ff9b::/96`. The unit test checks patterns with `NSRegularExpression`, so it does not exercise WebKit's address rewriting. |
| 2 | Real. Preferences, pins and scene storage encode only sanitised addresses, and scene routes are also sanitised when decoded. An older preference document keeps tabs with queries until its next write. WebKit's per-host persistent store keeps its own HTTP cache, which this fix does not touch. |
| 3 | Real. Reads stop at the stated size and never exceed 20 MiB. Only the 128-pixel PNG is cached, and Data Saver sets the limit to zero. The test catches a missing ceiling only indirectly. |
| 4 | Real. Host comparison ignores case and a trailing dot. A conflict names the other profile, is checked again on approval, and fails before sign-in. |
| 5 | Real. A locked Keychain gets its own message. The failure is not treated as a refused password, so a saved password is kept, and Retry rebuilds the session. |
| 6 | Real in the code: Settings and Copy Key use the read-only lookup. The test checks only that lookup, not how Settings calls it. |
| 7 | Real. A probe runs only when no connection attempt is in progress. Path events are handled one at a time, with one buffered. A late probe cannot act on a newer generation. The service upstream is never cleared on loss, so `openSSHContinueReading`'s upstream check cannot detect a teardown; the transport test now checks that a healthy probe keeps the session and its SFTP client. The existing reconnection tests remain and pass. |
| 8 | Real, in the folder screen and the iPad sidebar. The notice shares its line with error messages. |
| 9 | Real for the app process; see the sandboxed runs. |

Changes made in this review:

- `Packages/RelayTransport/Tests/RelayTransportTests/OpenSSHTests.swift`: `openSSHKeysAndLifecycle` checks that a path change answered by the live server keeps the session and its SFTP client.
- `Apps/RelayBarMobile/Tests/MobileCoreTests/RemainingReadersTests.swift`: `sceneAndTabStorageStripServiceSecrets` decodes a scene written before sanitising.
- `docs/system-specs/modules/mobile-app.md`: records that WebRTC is outside the preview filters.

Still open, most serious first:

1. **WebRTC in HTML previews.** HTML Scripts is on by default. With it on, a previewed page's own script opened a TURN-over-TCP connection to loopback under the preview's policy and rule list, with internet resources both off and on. Neither filter looks at the address. So the same path can reach private hosts, and, with internet resources off, an outside TURN server that receives a username of the page's choosing. WKWebView has no public setting to turn WebRTC off. Options include a document-start script that removes the WebRTC constructors, or turning scripts off by default. Not yet checked on iOS.
2. **Congested sessions.** A path-change probe ignores other replies on the connection. If its reply waits behind more than 10 seconds of queued data on a slow link, a healthy session is ended and reconnected.
3. **Flaky rollback test.** `gateRollsBackBothAddressFamilies` fails when another listener holds the same port number on the other address family.

## Verification after the closing fixes

The feature branch had no upstream. Its base, `90c457e`, matched the fetched remote main branch.

| Check | Result |
| --- | --- |
| Mobile suite | 40 Swift tests, all eight windowless WebKit checks and 17 script tests passed. |
| Shared suite | 115 XCTest cases, four opt-in skips, zero failures. All 17 script tests passed. |
| Transport suite | 44 Swift tests and 17 script tests passed. |
| Generic iOS Simulator SDK build | Unsigned build succeeded using the app and packages’ warnings-as-errors settings. No simulator booted. Xcode’s App Intents metadata tool warned that extraction was skipped because the app has no App Intents dependency. |
| Gallery | The gallery process ran with outbound IP connections restricted to loopback. The reference image uses a reserved name, an authenticated loopback proxy with failover disabled, and a bundled PNG served in process. WebKit reported a decoded image only after permission in both appearances. All 82 PNGs were written. |
| Working tree | `git diff --check` passed. |

The transport change adds a path-change entry point to the session. It checks the active connection generation before reconnecting, so a late probe cannot revive a suspended session. The Mac app suites below were last run during the original review.

## Original review runs

| Check | Result | Time |
| --- | --- | --- |
| `./scripts/test.sh shared` | 115 XCTest cases, 0 failures, 4 opt-in tests skipped; 17 script tests passed | 19 s |
| `./scripts/test.sh transport` | 43 Swift tests passed (private loopback OpenSSH server and in-process server); 17 script tests passed | 22 s |
| `./scripts/test.sh mobile` | 35 Swift tests passed (34 before this review); the web-view check passed all 8 of its checks; 17 script tests passed | 42 s |
| `./scripts/test.sh relaybar` | 465 XCTest cases, 0 failures, 33 opt-in tests skipped | 143 s |
| `./scripts/test.sh frame` | 234 XCTest cases, 0 failures, 3 opt-in tests skipped | 61 s |
| App for the iOS Simulator SDK, `generic/platform=iOS Simulator`, command from [Build and release](../system-specs/operations/build-and-release.md), clean derived data | Succeeded with no compiler warnings; `RelayBarMobile`, `MobileCore` and `MobileUI` compiled with warnings as errors | 65 s |
| `AppComposition-Package` for the iOS Simulator SDK | Succeeded; all eight targets compiled, `BridgeProtocol` and `CompositionFixtures` empty on iOS | 22 s |
| `RelayTransport-Package` for the iOS Simulator SDK | Succeeded; `RelayTransport` and `RelayWebRoutes` | 49 s |
| Screen gallery, `swift run --package-path Apps/RelayBarMobile ScreenGallery` | 82 PNGs: 41 screens, light and dark (390 × 844 phone, 1194 × 834 iPad) | 23 s |
| `./scripts/archive-mobile.sh --dry-run` | Printed the two steps it would take; exit 0 | — |
| `./scripts/archive-mobile.sh` with no `DEVELOPMENT_TEAM` | Refused with “Set DEVELOPMENT_TEAM to your signing team.”; exit 1 | — |
| `ITSAppUsesNonExemptEncryption` in the app's Info.plist | Absent, so the script's declaration check refuses before archiving (the check was run on its own; the script was not run with a team set) | — |
| `git diff --check` and a trailing-whitespace scan of untracked files | Clean | — |

The suites were run one at a time. Before running the RelayBar and Frame suites their test sources were checked: every window they make is a quiet off-screen window whose process cannot activate, the one plain Plugins window is constructed but never ordered in, and every test composition is built without windows. Both suites ran in full. RelayBar's log contains CoreData messages about the address book store failing to connect; no prompt appeared.

The first app build attempt failed because `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` was added on the command line, which also reaches the remote package targets that Xcode builds with warnings suppressed. The documented command relies on the target setting and on the mobile package's `treatAllWarnings(as: .error)`, and passes.

Building the packages on their own resolved their dependencies from GitHub.

### The shared suite's test count

The shared suite was reported once as 130 passing tests and later as 115. No test was removed, renamed or made opt-in between the reports: every test file in `Packages/AppComposition/Tests` was last written before the 130 report. The macOS run has 115 XCTest cases: 90 in `CompositionTests` and 25 in `MarkdownRenderingTests`. Four of them are opt-in and skip unless an environment variable is set: two composer snapshot tests and two Markdown snapshot and measurement tests. Two further tests, in `UIKitPaletteTests`, are compiled only for iOS. `scripts/test.sh` also runs 17 Python release-script tests first. The 130 report counted passing tests across both runners with the composer snapshots enabled, since that task rendered them: 113 XCTest passes plus 17 script tests, with the two Markdown tests skipped. The 115 report counted XCTest cases executed, skipped ones included.

## Acceptance

“Met” names the evidence. Device-only behaviour is listed under [What remains unverified](#what-remains-unverified).

### 077 Shared packages on iOS

- Five products build for the iOS Simulator SDK, generic destination: met (`AppComposition-Package` build).
- `./scripts/test.sh` passes for shared, RelayBar and Frame with warnings as errors: met.
- Markdown fixtures through the platform-neutral path match the macOS output, including math image metrics: partly. `ReferenceOutputTests.testReferenceDocumentsMatchMacRendering` passes on macOS. iOS lays equations out through a different, UIKit path (`MathDrawing.swift`), and that path has not run because no simulator or device was available.
- Realm-relative plugin membership mounts once per realm, prunes per realm and reports ownership in each: met (`RealmPluginTests.testRelativeMembershipTracksEachRealmAndPrunesItsSubtree`).
- Composition, house-style and Markdown-preview specs describe the result: met.

### 078 SSH transport package

- Private `sshd`: host-key callback before sign-in, pinned-key mismatch fails, Ed25519 and P-256 sign in after `none` is refused: met (`openSSHKeysAndLifecycle`, `hostKeyRefusal`, `changedHostKeyStopsReconnect`).
- In-process server: `none` succeeds, password succeeds and fails: met (`AuthenticationTests`, three cases).
- SFTP: 10,000-entry listing, 64 MiB pipelined read, range read, cancelled read closes its handle, typed missing and unreadable errors: met (`openSSHFiles`). The handle check is from the client's side.
- Streams: local HTTP server reached, closed port gives the typed error, 50 concurrent streams: met (`openSSHStreams`).
- Session: stopping `sshd` interrupts, restarting reconnects, `suspend()` then `resume()` returns to ready: met (`openSSHKeysAndLifecycle`).
- Builds for the iOS Simulator SDK: met (`RelayTransport-Package` build).
- `ssh-transport.md` describes the behaviour: met.

### 079 Mobile app core

- App builds for the iOS Simulator SDK with warnings as errors: met.
- Logic tests on macOS for stores, history, cache keys and revalidation, composition tree: met (`compositionAndHistory`, `trustAndPreferenceVersion`, `budgetEvictsLeastRecentlyUsedAndSurvivesRestart`, `contributionsFollowTheirHostRealm`).
- Realm on demand, lost session clears dependents, recovery restores them, no feature id in stored documents: met (`compositionAndHistory`).
- Mac HTML from shared fixtures, relative image through a fake file service, reading position round trip: met (`macReaderFixtures`, `identityAndAssets`, `schemeServesDocumentAndAssets`, `compositionAndHistory`).
- Headless end-to-end against the test `sshd`, through Continue Reading after a restart: met (`openSSHContinueReading`).
- Gallery writes one image per screen per appearance without a window; registries filled by features: met (gallery run; `registeredLocationsAndPluginOverrides`).
- Mobile tests run from `scripts/test.sh` and CI: partly. Both are wired; CI was not run, and its `macos-15` runner was not checked against this package's iOS 27 and Swift 6.2 requirements.
- Device checklist marked not yet run: met.
- `mobile-app.md` describes the behaviour: met after the corrections below.

### 080 Web services on mobile

- Proxy credentials, destination list, OpenSSH reach, closed-port reply; each gate rule passing and failing, including a foreign `Origin` without fetch metadata; token never reaches the upstream; WebSocket relay; two profiles on one port; a taken address yields no listener: met (`proxyAuthenticationAndPolicy`, `proxyRefusesDestinationLookalikes`, `proxyThroughOpenSSH`, `gateAuthorizationAndProfileIsolation`, `gateRefusesNearMissHostsTokensAndOrigins`, `gateStripsEveryCredentialForm`, `gateRelaysOnlyAConfirmedWebSocketSwitch`, `gateRollsBackBothAddressFamilies` and others).
- Windowless web view: private name as a secure context, exact route with its token, a second view refused: met (web-view check).
- Route-choice states and each Open Location resolver: met (`serviceRouteChoice`, `serviceResolversAndSavedAddresses`, `registeredLocationsAndPluginOverrides`, prompt resolver in `contributionsFollowTheirHostRealm`).
- Builds for the iOS Simulator SDK: met.
- `mobile-web-services.md` and `security-boundaries.md` describe the result: met after the corrections below.

### 081 iPad layout and remaining readers

- Range reader ordered, out of order and cancelled seek; notebook and table fixtures and size limits; HTML permission per host, default off: met (`mediaRangesAndCancelledSeek`, `cancellingAnOutstandingSeek`, `structuredPreviewFixturesAndLimits`, `hostPermissionRoundTrip`).
- Previewed HTML cannot reach the gate or the proxy: met (web-view check, with and without internet permission).
- Builds for iPhone and iPad: met (one build, device family 1 and 2).
- Checklist gains iPad, video and AirPlay checks, not yet run: met.
- `mobile-app.md` describes the result: met.

### 082 Plugins on mobile

- Per-host override beats the global choice both ways; a restored tab for a disabled plugin is kept and marked: met (`MobilePluginTests`, `choicesPersistOnlyCatalogKeysAndPreserveOtherOverrides`, `savedPagesAndApprovalsSurviveRestart`).
- Remove only a regular file whose fingerprint matches; proxy refuses an unapproved destination and accepts it after approval: met (`guardedRemovalAndTail`, `proxyExternalApproval`).
- Self-signed service opens after approval, replaced certificate refused: met (web-view check).
- Undo cancels before submission; Log Follow emits appended lines and survives truncation: met (`undoCancelsBeforeSubmission`, `guardedRemovalAndTail`, `openSSHContinueReading`).
- Builds for the iOS Simulator SDK: met.
- `composition.md` and `mobile-app.md` describe the result: met.

### 083 Mobile release preparation

- Archive script produces an archive or stops with a clear message, never uploads: partly. The dry run and the missing-team refusal ran; the missing-declaration refusal was shown by its check alone. No archive was produced, on purpose. The script has no upload or export step.
- `git diff --check` clean and the test script passes: met (all five suites, run one at a time).
- Checklist, review notes and store text exist under `docs/` and name no private host, account or path: met.
- `build-and-release.md` describes the mobile build and states that publication needs approval: met.

## Review

Reviewed with security in mind: gate token creation, installation, removal and storage; the loopback content rule; the proxy configuration of each host's data store; the private-certificate pin; destination approvals; Delete with Undo; the preference, trust and scene-storage contents; Keychain and Secure Enclave use; main-actor error handling; crash paths. Found correct: the token is 16 bytes from the system random source and compared in constant time; rules, cookie and user agent are installed before the first load and removed on stop, hide of an exact page, scene deactivation and tab close; no token is persisted; the proxy store has its credential, a `.localhost` match domain and failover off before the first load; the certificate pin is the SHA-256 of the leaf, keyed by profile, name and port; approvals are per profile; removal re-checks type, size and modification time with `lstat` and refuses directories and links; Keychain items are this-device-only and a refused saved password is removed; no secret or feature id is written to preferences; no force unwrap depends on remote data.

### Fixed in this review

- `Apps/RelayBarMobile/Package.swift:1`: the tools-version comment followed `import Foundation`. It now comes first.
- `Apps/RelayBarMobile/Sources/MobileCore/FilePlugins.swift:55`: Undo pressed after the five-second sleep finished but before its task resumed still deleted the file. The task now checks for cancellation before submitting.
- `Apps/RelayBarMobile/Sources/MobileCore/DocumentCache.swift:153` and `:185`: a failed cache write, for example on a full disk, failed the open of a document that had already arrived. Cache writes are now best effort. Test: `failedCacheWriteStillOpensTheDocument`.
- `Apps/RelayBarMobile/Sources/MobileUI/ServiceBrowser.swift:467`: Service Labels saved a Host's Network page title under the host's own port, relabelling the host's service. Titles are now saved only for the host's own services.
- `Apps/RelayBarMobile/Sources/MobileCore/HTMLPreview.swift:18`: the policy tag came before the document's doctype, so every HTML preview rendered in quirks mode. It is now preceded by a doctype and charset, as on the Mac.

### Closing corrections and regression coverage

| Item | Result and evidence |
| --- | --- |
| 1. HTML internet permission | Public-resource rules block private literals, local suffixes and the profile endpoint. `publicInternetPreviewRules` covers the ranges and their boundaries. The windowless WebKit check exercises both permission states. DNS resolution remains outside the filter. |
| 2. Service addresses | `sceneAndTabStorageStripServiceSecrets` inspects both iPad panes, back and forward history, saved tabs and pinned services. Old scene URLs are sanitized when restored. |
| 3. Thumbnails | `thumbnailsBoundReadsAndKeepOriginalOutOfCache` checks the 20 MiB ceiling, Data Saver and absence of a cached original. |
| 4. Shared endpoint pins | `endpointPinsAreSharedAndConflictsNameTheProfile` checks silent reuse and a conflict created while another scene is waiting for trust. |
| 5. Locked Keychain | `lockedCredentialsAndReadOnlyKeyLookup` exercises locked password and signing-key reads and retry following unlock with injected providers. `openSSHContinueReading` checks the message delivered by the SSH connection and signs in after Retry. |
| 6. Device key creation | The same test reads an empty key store without accessing the Secure Enclave. Settings exposes Create Key. Device key generation remains a physical-device check. |
| 7. Path changes | `openSSHContinueReading` checks that a healthy probe preserves the service upstream. `pathChangeRecoversAfterSilentProbe` withholds the SFTP reply and requires recovery before ordinary backoff expires. |
| 8. Truncated folder | `openSSHContinueReading` reads a 10,001-entry directory over SFTP, checks its partial rows and notice, and checks an untruncated listing. |
| 9. Gallery fixture | The gallery checks the reference poster's decoded width against the permission in each appearance. The demo serves bundled bytes through its in-process HTTP stream and loopback proxy. |
| 10. Accepted DNS limit | The web-service and security-boundary specs record the path from a token-carrying page to a local listener through a public DNS name. `loopbackRuleDestinations` checks literal rules. |

### Left open

- Low, not confirmed. Refusing an untrusted certificate cancels the challenge without setting a reason (`ServiceApproval.swift:213`, `:222`), which may leave a blank page.
- Low. Content rule list names include destination names and are never removed (`ServiceApproval.swift:167`); subresource reads are unbounded in number and size up to 100 MiB (`DocumentScheme.swift:40`); certificate evaluation runs on the main actor (`ServiceApproval.swift:212`); a redirect tab is saved before approval; a failed tree rebuild sets `treeError` but nothing shows it (`CompositionTree.swift:296`).
- Gaps against the design: both routes forward to `127.0.0.1` only, so a service bound only to `::1` is unreachable; the IPv4-compatible literal `[::127.0.0.1]` is not in the loopback rule.

### Documentation corrected

The module specs and device checklist describe the implemented preview, storage, listing and reconnect behavior. The original closing review also updated the module index, build instructions, device record, privacy, security and README.

Left for the maintainer: `PRIVACY.md` keeps its August 30, 2026 effective date, does not list history titles and excerpts, service tabs and labels, remembered destinations, certificate pins or localhost choices, and does not say that a remembered password can be removed only by a refused sign-in or deleting the app. The Mac apps' statements in `PRIVACY.md`, `SECURITY.md` and `README.md` are unchanged in meaning, and `README.md` only adds an iPhone and iPad section.

## Hygiene

Every added or changed file was searched for home-directory paths, the local account name, names of AI tools and models, signing team identifiers, tailnet names, private addresses and other real host names. None were found. The bundle prefix already appears in the Mac apps.

## What remains unverified

- Every check in the [mobile device checklist](mobile-device-checklist.md) and the [first device checklist](079-mobile-app-device.md): sign-in with tailnet identity, the Secure Enclave key and Keychain on a device, all three service routes and their WebKit behaviour on iOS, media requests through the proxy and gate, video, AirPlay, sharing, continued-processing downloads, iPad scenes and layout, VoiceOver, Dynamic Type and touch, and performance on a relayed path.
- iOS-only code paths: `UIKitPaletteTests`, the UIKit equation layout and every SwiftUI screen as drawn by iOS. The gallery draws the shared views on macOS.
- The CI workflow, which was not run.
- A signed archive, which needs the maintainer's team, signing assets and encryption declaration. No upload, export, notarisation or store action was taken.
