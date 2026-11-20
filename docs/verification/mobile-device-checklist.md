# Mobile device checklist

Use physical devices and disposable accounts. For each row record the device, OS build, app revision, route and observed result. Redact host identities, paths, credentials and gate tokens from shared evidence.

## Connection and sign-in

| Exercise | Pass criterion | State |
| --- | --- | --- |
| Add a Tailscale SSH host on iPhone. Compare its fingerprint out of band. | The displayed fingerprint matches. After trust, the server accepts SSH `none` with no device key or password. | Not yet run |
| Use ordinary sshd with public-key authentication. Authorise the copied public key and relaunch. | Sign-in succeeds and the same public key appears after relaunch. | Not yet run |
| Use ordinary sshd with a password. Try once without saving, then opt to remember it. | A fresh session asks again after one-time use. After a successful remembered password, a fresh session signs in without prompting. | Not yet run |
| Replace a pinned test host’s key. | Sign-in stops before any credential prompt or offer to the changed host. | Not yet run |
| Enter a bare host, an account-qualified host, a custom port and a pasted SSH invocation, including just after closing Settings. | Each resolves to the intended endpoint. Missing account, trust and password prompts follow in one sheet with usable keyboard focus. | Not yet run |

## Files and readers

| Exercise | Pass criterion | State |
| --- | --- | --- |
| Browse folders using Back and the system gesture. Enter a path and switch hosts in Open Location. | Each returns to or opens the expected folder on the chosen host. | Not yet run |
| Inspect a linked directory, thumbnails, timestamps and change dots in list and grid. Filter changed files and search by name. | The link opens its directory. Both layouts show the expected metadata and matching results. | Not yet run |
| Favourite a file and open an image with an indexed prompt. | The favourite reopens from Home and a prompt search finds the opened image. | Not yet run |
| Open Markdown with a relative image, outline and fenced code. | The image appears, the outline jumps to the heading, Source shows the original text and copying the code yields its contents. | Not yet run |
| Scroll continuously into a section, leave, then use Continue Reading. Move the heading remotely and repeat. Then remove it. | The reader restores the offset within the heading, follows the moved heading and falls back to the saved absolute offset when it disappears. | Not yet run |
| Change an opened file on the host. | The file shows its change mark and reopening displays the updated contents. | Not yet run |
| Read UTF-8 text, formatted JSON and an image with PNG text, EXIF or sidecar details. Try text over 2 MiB and an image over 100 MiB. | Characters, formatting and available image details match the samples. The reader enforces the size limits. | Not yet run |
| Preview an HTML file with a script, a remote image and a link to the gated service. | Scripts run in an isolated store without service credentials. The remote image loads only after permission for this host. Another host still requires permission. | Not yet run |
| Play a remote video, seek beyond read-ahead, then try AirPlay with a compatible receiver. | Playback resumes at the requested position, range requests serve the seek and the selected receiver plays the media. | Not yet run |
| Clear cached files for one of two hosts in Settings. Disconnect both. | Only the second host’s saved copies remain readable. | Not yet run |

## Web routes and gate

Use a service reachable on the VPN, one bound only to host loopback and one requiring the exact localhost name. Use disposable service pages that can report request headers without logging credentials.

| Exercise | Pass criterion | State |
| --- | --- | --- |
| Open the VPN-reachable port. | The page opens directly at the host and port over the VPN. | Not yet run |
| Open the loopback-only service under its private name. Inspect the route and secure-context flag. | The private name goes through the authenticated proxy to the SSH host. WebKit reports a secure context. Missing or incorrect proxy credentials and unlisted destinations fail without direct fallback. | Not yet run |
| Request the exact-name service. Decline the offer, then reopen it from the page menu and accept. Inspect both device loopback address families. | Declining opens no listener. With consent the page uses device loopback at the same port, bypassing the configured proxy. An occupied address prevents either listener from remaining open. | Not yet run |
| Load a page, image, media range, scripted fetch and WebSocket on the exact route. Override the user-agent header in a fetch. | Each request needs a valid token in the user agent or cookie. A stripped header alone grants no access. Playback, seeking and the upgrade work with valid credentials. The upstream receives neither token carrier’s secret. | Not yet run |
| Inspect the page’s own user agent. Repeat a request from another browser, including a cross-site subresource and a navigation. | The service page can read its token. Foreign origins, wrong hosts, cross-site subresources and requests without a token are refused. Navigation alone grants no access. Inspect the actual Origin and fetch metadata sent by iOS. | Not yet run |
| Open two profiles using the same service port. Close one page, then background the app. | Each page reaches only its profile. Closing revokes its token and sockets. Backgrounding closes remaining listeners and sockets. Old tokens fail on return. | Not yet run |

## Lifecycle

| Exercise | Pass criterion | State |
| --- | --- | --- |
| Background an open reader, disconnect, return and retry. Restore connectivity. | The cached page remains readable. Status shows the interruption and suggests checking Tailscale and retrying. Reconnection restores browsing. | Not yet run |
| Leave a host idle and silently drop replies. Restore the network or foreground the app during backoff. | After 30 idle seconds the client probes. Two missed ten-second intervals interrupt the session. Retries back off with jitter in the one-to-30-second range. Foreground return triggers an immediate attempt. Switch between Wi-Fi and cellular with a service form partly filled. A healthy path probe keeps the session. A failed probe or a switch during backoff starts a reconnect immediately. The page retains its form contents and scroll position. | Not yet run |
| Interrupt a connection with a service tab open. | The tab survives reconnection and retains page state. | Not yet run |

## iPad

| Exercise | Pass criterion | State |
| --- | --- | --- |
| Open two scenes on one host. Background one, then both. Repeat with different hosts. | A shared session lives until its last scene leaves. With different hosts, each session follows its own scenes. Returning reconnects the visible host. | Not yet run |
| Use the sidebar, host switcher, file tree, outline rail and two pages with the divider. Compare a document with Frame at the same width. | The correct pane navigates, both pages remain usable after resizing and the document matches Frame’s layout. | Not yet run |

## Appearance and accessibility

| Exercise | Pass criterion | State |
| --- | --- | --- |
| Install the review build, check its icon in standard, dark and tinted Home Screen appearances, then cold-launch it. | Each icon shows the route mark. The launch screen is plain paper. Settings shows version 1.0.0 (1). | Not yet run |
| Launch with `--demo-host`. Compare Hosts, First Connection, Home, Folder, Document, Image, the reconnecting reader and Open Location with the gallery in light and dark appearance. | Layout and contrast hold in both appearances. The live reader renders its Markdown assets and restores the heading after scrolling. | Not yet run |
| Try the largest accessibility text sizes and VoiceOver on each screen. Operate controls, navigate sheets and dismiss the keyboard. | Text and actions remain reachable. Labels and focus order describe the task. Status marks differ by shape. Tap targets are at least 44 points and focus returns predictably after dismissal. | Not yet run |

## Performance targets

| Exercise | Pass criterion | State |
| --- | --- | --- |
| Repeat a cold document open, folder listing and media seek over direct and confirmed relayed VPN paths. Record round-trip time, file size, time to readable content and seek delay. | Both paths complete with intact content. Record timings for both. The design gives no fixed latency or throughput threshold. | Not yet run |
| Read a large file while requesting a page. Inspect outstanding reads and buffered bytes. | At most 16 reads of up to 32 KiB are outstanding and read-ahead stays within 2 MiB per host. Waiting page traffic gets priority. | Not yet run |
| List a directory with more than 10,000 eligible entries. | Files and the iPad sidebar keep the partial listing and show “Showing the first 10,000 items”. Repeat at exactly 10,000 eligible entries and verify the notice disappears. | Not yet run |

## Reader interactions on device

| Exercise | Pass criterion | State |
| --- | --- | --- |
| Read on iPad, open a service beside the document, drag the divider, then restore the scene. | Both selections and the divider position return. The host badge counts only open services. | Not yet run |
| Play the sample MP4 and seek repeatedly. Repeat with a large video on a throttled connection. | A new seek starts ahead of ongoing reads. Sustained slow streaming offers download and local playback. | Not yet run |
| Select an AirPlay receiver from the native video controls and switch back. | Check picture, audio and seek on the receiver and on return to the device. | Not yet run |
| Save or share a video, background during the download and cancel through the system. | Granted continued processing reports progress and honors cancellation. Without a grant the download stops in the background. | Not yet run |
| Toggle HTML Scripts and allow or revoke internet resources. Repeat on another host. | Scripts and the external image follow their separate settings. Permission survives relaunch for the selected host. | Not yet run |
| Enable Low Data Mode or use an expensive path. | Data Saver suppresses thumbnails and speculative reads. Ordinary document reads and seeks still work. | Not yet run |

## Plugins on device

| Exercise | Pass criterion | State |
| --- | --- | --- |
| Change global and host choices from phone Settings and the iPad inspector. Compare the two network plugin symbols, turn a plugin on for one host only, and select a feature on the map. Reopen a saved notebook and an external service with their plugins off. | The two symbols differ. The row names the host exception. Selected edges use the accent colour and the inspector names the host. Host overrides take precedence. Saved locations stay listed and identify the plugin to enable. | Not yet run |
| Delete a disposable regular file, undo, then repeat while another client replaces the file. | Undo preserves the file. The changed target is refused. A directory and a symbolic link have no Delete action. | Not yet run |
| Follow a growing log, scroll up, resume, then truncate or replace the log. | Follow pauses during reading and continues from the new contents after rotation. | Not yet run |
| Open an external service and follow a redirect to a new host. Refuse, allow once, remember and remove a remembered destination. | The sheet names each new endpoint. Persistent choices apply only to that profile. | Not yet run |
| Open a self-signed HTTPS page with a script and WebSocket. Approve once, reopen and rotate the certificate. | The matching certificate loads all resources. The changed fingerprint is shown and the new connection is refused. | Not yet run |
