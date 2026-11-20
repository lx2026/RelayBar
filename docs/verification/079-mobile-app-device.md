# Task 079 device checklist

**Status: Not yet run.** Record the device, OS build, app revision and observed result for each check. Use a test account and redact host identities from shared evidence.

- [ ] Open Hosts on an iPhone. Add a tailnet host, compare the displayed fingerprint with the host’s key, and trust it. Verify tailnet identity sign-in without a password or device key.
- [ ] On a public-key host, copy the device key and authorize it. Compare the public key across a relaunch. On a password host, check both one-time sign-in and remembering a password on the device.
- [ ] Change the test server’s host key. Confirm that the connection is blocked before a credential prompt.
- [ ] Browse folders, use Back and its system gesture, enter paths and switch hosts in Open Location. Open Markdown with a relative image, inspect its outline and source, and copy a code block.
- [ ] Scroll into a named section, leave and reopen from Continue reading. Move that heading on the server and check the heading-relative restore. Remove it and check the offset fallback.
- [ ] Change an open file and check its change mark. Reopen and verify the current contents. Check UTF-8 text, JSON, an oversized file and an image with PNG text, EXIF or a sidecar.
- [ ] With the reader open, background and return. Leave the host unreachable and inspect the saved copy, status and retry message. Restore connectivity and verify that browsing works again.
- [ ] On iPad, open two scenes on the same host. Background one, then both, and verify the connection lifetime. Repeat with two different hosts.
- [ ] Clear one host’s cache and confirm the other host retains its saved copies.
- [ ] Compare Hosts, First Connection, Home, Folder, Document, Image, the reconnecting reader and Open Location in light and dark appearance. Check the largest accessibility text sizes, VoiceOver order and labels, tap targets and keyboard dismissal.

- [ ] Enter a bare host, account-qualified host, custom port and pasted SSH invocation. Verify that an account prompt and any successive trust or password prompt stay on one sheet, including after dismissing Settings.
- [ ] Inspect a linked directory, thumbnail, timestamp and change dot in list and grid views. Filter and search, favourite a file, then reopen it from Home. Search an opened image by its prompt.
- [ ] Launch with `--demo-host` and compare the screens with the off-screen gallery. On the device, check keyboard focus, sheet transitions, Markdown assets and the heading restore after continuous scrolling.

Record release checks in the [mobile device checklist](mobile-device-checklist.md).

## Headless evidence

On 2026-11-18, `./scripts/test.sh mobile` passed 17 script tests and 15 Swift tests on macOS. The SSH test used a temporary loopback OpenSSH server. Xcode 27.2 built the unsigned app for the generic iOS Simulator SDK with Swift compiler warnings treated as errors. The gallery wrote all eight screens in both appearances, each 390 × 844 pixels at 1×. Document and Resume use the off-screen WebKit placeholder. Device-only checks above are pending. This paragraph describes the first version; the current headless results are in the [Tasks 077–083 verification record](077-083-relaybar-mobile.md).
