# Task 082: Plugins on mobile

Status: Complete
Design: [RelayBar for iPhone and iPad](../../designs/relaybar-ios.md)
Verification: [record](../../verification/077-083-relaybar-mobile.md)
Depends on: Task 081

## Outcome

A person can see, switch and override the app's plugins, and the plugins that write to a host or widen its reach are available and off by default.

## Delivery Boundary

Included: `Apps/RelayBarMobile`; an iOS Plugins view in `Packages/AppComposition`; the write and proxy additions these plugins need in `Packages/RelayTransport`.

Excluded: Jump Hosts, which is deferred; release work (Task 083).

## Work

1. Plugins screen: on iPhone a Settings list grouped by what a plugin extends, with a detail page showing status per host, needs, offers and what else would unload. On iPad the list sits beside the feature map and inspector, using the shared composer model and map layout.
2. Per-host overrides: inherit, on or off, stored beside the host profile and resolved when its realm is built. A tab whose plugin is off stays listed and names the plugin.
3. Delete with Undo: a file action with the five-second Undo window and the fingerprint recheck the Mac uses. It needs SFTP remove in the transport.
4. Log Follow: a page kind that follows a growing text file by reading its tail over SFTP.
5. The Host's Network: the proxy also accepts HTTPS destinations and short names the user opened. Each new redirect destination asks first.
6. TLS under a private name: a service with a certificate the system does not trust opens after the user approves that certificate once. The approval is pinned to profile, name and port, and a different certificate is refused.

## Acceptance

- Composition tests: a per-host override beats the global choice in both directions, and a restored tab for a disabled plugin is kept and marked.
- Transport tests: remove deletes only a regular file whose fingerprint still matches; the proxy refuses a destination that was not approved and accepts it after approval.
- A windowless web-view test shows a self-signed service opening after approval and a replaced certificate being refused.
- Logic tests: the Undo window cancels before submission; Log Follow emits appended lines and survives truncation.
- The app builds for the iOS Simulator SDK with warnings as errors.
- `docs/system-specs/shared/composition.md` and `modules/mobile-app.md` describe the result.
