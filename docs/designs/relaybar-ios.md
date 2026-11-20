# RelayBar for iPhone and iPad

Status: the mobile app has been run on an iPad. Implemented behaviour is described under `docs/system-specs/`; where this page and those specs differ, the specs and the code are right.

## Purpose

With the phone on the same tailnet as the Mac, connect to the same host over SSH and read the same documents, rendered as Frame renders them. The app also browses folders, shows images and video with their details, and opens web services that listen on the host.

It has no terminal, forwards nothing for other apps and installs no network extension. It works while it is on screen and reconnects and restores its pages on return. Minimum system: iOS and iPadOS 27. Display name: RelayBar. Bundle identifier: `com.lx2026.RelayBar.ios`.

## Main path

1. Launch reconnects to the last host. On iPhone, Home offers Continue reading, Places, up to five recent items before Show All, and Websites. Tap Home or a pinned folder in Places to browse it. Tap a pinned file to read it.
2. On iPad, Start puts the article and website search field first. A return within ten minutes restores the previous page.
3. Continue restores the document by heading and offset. Folder breadcrumbs and the iPhone reader’s folder path navigate directly to a folder.

Documents use Back and Recent. Websites keep tabs. Open Location accepts a port, path or host and completes paths one directory at a time. From Home it offers hints and Hosts. Other pages also offer Places, Recent and Websites.

If a host cannot be reached the message is "Couldn't reach NAME. Check Tailscale is connected, then retry." The app cannot tell that a VPN is off.

## iPad layout

Start places Continue beneath the search field, followed by website tiles, up to six recent cards and Places. Typing a name replaces those sections with a top hit and grouped results. The same field appears on folder pages. Command-K focuses search throughout the workspace.

The 264-point sidebar marks Start, a folder or a website. A document marks its parent folder. Each folder has a page with breadcrumbs, ordering, hidden-item disclosure and a grid or dense list. Date order groups files into Today, This week and Earlier. The grid shows three file cards across a wide page and two in portrait.

A document uses the page, with navigation in the folder’s order and a return to its scroll position. Markdown has a 288-point outline at page widths of at least 1,000 points. Narrower pages open the outline from the bar. A website can share the page with a document across an adjustable divider. Image details sit below the image stage.

## Structure

| Unit | Role |
| --- | --- |
| `Packages/AppComposition` | Existing kernel, composer model, house palette, preview registry, companion grouping and Markdown renderer, built for iOS as well as macOS |
| `Packages/RelayTransport` | New, with no interface code: SSH session, SFTP client, forwarded streams, and later the proxy and the localhost gate |
| `Apps/RelayBarMobile` | New: a package of features and SwiftUI views, and a thin Xcode project for the app target |

One Composition runtime per process. Root features: profiles, trust (pinned host keys), keys, registries, scene demand, and the localhost gate. Each connected host is a realm: `session` fills its slot on sign-in and clears it on loss; `files`, `streams`, readers and web routes need it. A realm exists while a scene shows a page of that host. Listeners and tabs belong to scene demand and outlive reconnects.

## SSH

- swift-nio-ssh on NIO Transport Services. One TCP connection per host carries one SFTP channel and one `direct-tcpip` channel per forwarded connection.
- The host key is shown and pinned before any credential is sent. A changed key blocks the connection.
- Sign-in order: `none` (a host using Tailscale SSH accepts it), then public key, then password. There is one P-256 key per device, created in the Secure Enclave when a host first asks for a key. A password may be kept in the Keychain as a this-device-only item.
- Liveness: any SFTP reply counts. After 30 seconds idle a cheap request is sent; two 10-second misses end the session. Reconnects wait 1 to 30 seconds with jitter and start at once on return to the foreground or a network change.
- No command is run on the host.

## Files and readers

- SFTP version 3 with streamed directory reads, pipelined file reads (16 outstanding 32-KiB reads, 2 MiB of read-ahead per host, page traffic first) and `limits@openssh.com`.
- Disk cache keyed by profile, account, pinned host key and path, revalidated on reopen, in a purgeable location.
- Limits as on the Mac: Markdown, JSON and text 2 MiB; images 100 MiB; 10,000 directory entries.
- Markdown goes through the shared renderer into a web view with scripts off and no network, using the same stylesheet and 680-point article width as Frame. Relative images and other assets are served from the document's folder.
- Images show details from PNG text, EXIF and sidecar files. HTML files run scripts in a throwaway store with no credentials and load internet resources only after the user allows it for that host. Video is read by byte ranges.

## Web services

Routes are tried in this order.

1. **Direct.** `http://HOST:PORT` over the tailnet, when the service listens on the host's tailnet address.
2. **Private name.** `http://PROFILE.localhost:PORT` through a SOCKS5 proxy the app runs on loopback. The proxy requires a per-session username and password, applies only to `.localhost` names, and never fails over to a direct connection.
3. **Exact localhost.** A listener on the phone's `127.0.0.1` and `::1` at the same port, loaded as `http://localhost:PORT`. It is offered per service when the server refuses the private name, and is never chosen automatically.

The gate on the exact route checks every HTTP/1.1 request head: `Host` is loopback at that port; `Origin`, when present, is a loopback origin of this profile or its private name; a request marked `Sec-Fetch-Site: cross-site` is refused unless it is a top-level navigation; and a 128-bit token made for that opened service is present in `User-Agent` or an HttpOnly cookie named for the port. The token is stripped before forwarding and discarded, with any open sockets, when the listener stops or the app leaves the screen. Listeners exist only while a page needs them and are not opened if either loopback address is taken. The web view that carries a token is barred from every loopback port the gate is not serving for that host, and has its token removed when the listener stops.

The token is a shared secret, not proof of the sender: pages of that service can read it, and every server such a page contacts receives it in the user agent.

TLS services on the host's own `localhost` open only under the private name, with a certificate the user approves once. Other machines the host can reach are a plugin, limited to HTTPS and short names, and each new redirect destination asks first.

## Plugins

A plugin is a statically linked feature a person can switch off. Extension points are typed registries: page kinds, location resolvers, preview formats, start-page sections, file actions, web routes, service labellers, transports and sign-in methods, and host importers.

| Plugin | Default |
| --- | --- |
| Localhost Compatibility, Notebook Preview, Table Preview, Pinned Websites, Pinned Places, File Search, Prompt Search, HTML Scripts, Data Saver, Paper Appearance | On |
| The Host's Network, Service Labels, Log Follow, Delete with Undo | Off |

Pinned Places keeps ordered file and folder pins per host. Switching it off leaves Home in Places. Pinned Websites controls service pins separately.

Reaching a host through another host is deferred. Host-key trust, secrets, the session lifecycle, tab restoration, the proxy's destination limits, the gate's checks and resource ceilings are never plugins. A plugin can be forced on or off for one host.

## Evidence and open checks

Measured on macOS with a headless web view: loopback addresses never go through a configured proxy; `NAME.localhost` does, is a secure context, and needs an App Transport Security exception for `localhost` and its subdomains; proxy credentials are enforced and fail closed; a token in the web view's user agent reaches every request type tested except one whose script overrides the header; a page in another browser cannot reach a loopback listener without a cross-site mark or its own `Origin`.

Not yet shown on a device: all of the above on iOS, media requests, sign-in with `none` against Tailscale SSH, and performance on a relayed path.
