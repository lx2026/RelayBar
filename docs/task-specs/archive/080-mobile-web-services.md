# Task 080: Web services on mobile

Status: Complete
Design: [RelayBar for iPhone and iPad](../../designs/relaybar-ios.md)
Verification: [record](../../verification/077-083-relaybar-mobile.md)
Depends on: Task 079

## Outcome

A service on a host opens in a built-in browser by the simplest route that works, and no other app or web page can use those routes.

## Delivery Boundary

Included: the proxy and the localhost gate in `Packages/RelayTransport`; route features, the service page, Open Location and the open-services list in `Apps/RelayBarMobile`; the app's App Transport Security settings; system specs.

Excluded: other machines the host can reach, and TLS services under a private name (Task 082); iPad layouts (Task 081).

## Work

1. Proxy: a SOCKS5 server on loopback with a port that stays fixed while its profile has pages. It accepts only username and password sign-in with a random per-session credential, and only CONNECT. Destinations are limited to the profile's private name at ports the user opened. Stream errors map to reply codes. Half-close and backpressure work in both directions. Limits: 16 streams and 5-second handshakes; opens beyond 8 at once wait in a bounded queue. New connections wait briefly while the session reconnects.
2. Gate: listeners on `127.0.0.1` and `::1` at the service's port, present only while a page needs them and the app is active, and absent if either address cannot be bound. Every HTTP/1.1 request head is checked as the design states; the token is stripped before forwarding; a validated WebSocket upgrade becomes a raw relay. The token selects the profile, so two hosts can share a port number. Refusals and failed opens are answered with a small page naming the reason. Silent sockets and oversized or slow heads are bounded.
3. Route choice: direct, then private name, then an offer to open as localhost when the server refuses the private name or redirects to `localhost`. The answer is remembered per service, can be changed from the page menu, and is never applied without the user's consent.
4. Web view: one persistent data store per host, with the proxy applied to `.localhost` names only, set before the first load, failover off. Pages on the exact route carry the token in the user agent and an HttpOnly cookie, are barred from loopback ports the gate is not serving for that host, and lose the token when the listener stops. A reconnect does not reload a page; a terminated content process does. Load errors show the app's own message.
5. Open Location resolves a port, a path, a host or an address, and shows ambiguous matches before acting. Pinned Services and Service Labels arrive as plugins.
6. Screens: the service page (Back, Forward, Reload, find, copy address), the offer sheet and the open-services list. Only service pages are tabs.
7. App Transport Security: local networking, and an exception for `localhost` and its subdomains. No arbitrary loads.

## Acceptance

- Headless transport tests on macOS: the proxy refuses wrong or missing credentials and destinations outside its list, reaches a local server through the test `sshd`, and maps a closed port to the right reply. Each gate rule has a passing and a failing case, including a request with a foreign `Origin` and no fetch metadata. The upstream never sees the token. A WebSocket upgrade relays. Two profiles on one port are told apart. A taken address yields no listener.
- A windowless web-view test on macOS shows a private-name page loading through the proxy as a secure context, an exact-route page loading with its token, and a second web view without the token being refused.
- Logic tests cover the route-choice states and each Open Location resolver.
- The app builds for the iOS Simulator SDK with warnings as errors.
- `docs/system-specs/modules/mobile-web-services.md` and `shared/security-boundaries.md` describe the result.
