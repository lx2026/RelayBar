# Task 078: SSH transport package

Status: Complete
Design: [RelayBar for iPhone and iPad](../../designs/relaybar-ios.md)
Verification: [record](../../verification/077-083-relaybar-mobile.md)

## Outcome

A Swift package with no interface code gives an app an SSH session with pinned host keys, three sign-in methods, an SFTP client and forwarded streams, proven against a real `sshd` in automated tests.

## Delivery Boundary

Included: `Packages/RelayTransport`, its tests, its entry in `scripts/test.sh` and CI, and a new system spec.

Excluded: the SOCKS proxy and the localhost gate (Task 080); any view; where keys and passwords are stored, which the app decides; jump hosts; upload, rename and delete; `Packages/AppComposition`, which Task 077 edits.

## Work

1. Package for macOS 14 and iOS 27, depending on swift-nio, swift-nio-ssh 0.15 and swift-nio-transport-services at exact versions. No AppKit, UIKit or SwiftUI import.
2. Session: connect by name and port through Network framework. Publish state as an async sequence: connecting, verifying, authenticating, ready, interrupted with a reason, failed with a reason.
3. Host keys: before any credential is sent, the caller receives the key type and SHA-256 fingerprint and answers trust or refuse. A pinned key that differs fails with its own error.
4. Sign-in: try `none`, then a caller-supplied signer, then a caller-supplied password. The signer protocol covers a Secure Enclave P-256 key and in-memory Ed25519 and P-256 keys. Server banners reach the caller, and the method that succeeded is reported.
5. Liveness and reconnection are policy values with the design's defaults: a probe after 30 seconds idle, two 10-second misses, and 1 to 30 seconds of jittered backoff. `suspend()` and `resume()` serve the app lifecycle.
6. SFTP version 3: `realpath`, `stat`, `lstat`, a streamed directory listing with typed attributes, and `open`, `read` and `close` with pipelined reads inside a per-session budget that honours `limits@openssh.com`. Range reads. Cancellation closes handles. Status codes become typed errors. File names that are not UTF-8 do not crash.
7. Streams: `direct-tcpip` to a host and port as an async byte stream with half-close and backpressure. Refused and prohibited opens become typed errors.
8. An algorithm mismatch reports what this client supports.

## Acceptance

All checks run headless under `swift test` with warnings as errors.

- Against a private `sshd` started on a loopback port with a temporary host key and configuration: the host-key callback fires before sign-in; a pinned-key mismatch fails; Ed25519 and P-256 keys sign in after `none` is refused.
- Against an in-process SSH server: `none` succeeds, and password sign-in succeeds and fails as expected.
- SFTP: a 10,000-entry directory streams; a 64 MiB file reads intact with pipelining; a range read returns the right bytes; a cancelled read leaves no open handle; missing and unreadable files give typed errors.
- Streams: a local HTTP server is reached through the session; a closed port gives the typed error; 50 streams run at once.
- Session: stopping `sshd` yields interrupted, restarting it reconnects, and `suspend()` then `resume()` returns to ready.
- The package builds for the iOS Simulator SDK with no simulator booted.
- `docs/system-specs/modules/ssh-transport.md` describes the implemented behaviour.
