# RelayBar Privacy Policy

Effective August 30, 2026

RelayBar does not collect, sell, or share personal data. It contains no analytics, advertising, telemetry, tracking, or accounts. Its open-source Markdown packages run locally and contain no RelayBar analytics or account integration.

## Mac apps

Tunnel names, hosts, ports, and imported safe SSH options are stored locally in RelayBar's application preferences on the user's Mac. RelayBar sends connection information only to the SSH hosts that the user explicitly configures. SSH authentication is performed by the SSH client supplied by macOS using the user's normal SSH configuration, agent, and identity files. RelayBar does not request or store passwords or private-key contents.

RelayBar keeps at most 16 successfully opened remote folder locations in local
application preferences. Each recent location contains the normalized absolute
path, the exact SSH host connection identity, and local display metadata; it
does not contain directory listings, remote file contents, credentials, or
connection state. A user can remove one recent location or clear all recent
locations. Downloaded files are written only to a destination the user chooses.
Uploads read only the one local file the user chooses and send it to the open
SSH folder through a hidden remote staging name. Upload byte measurements are
session-only. Image, Markdown, JSON, and MP4 previews use private temporary storage
that RelayBar removes when the preview or window closes. A direct Delete action
permanently removes only the selected remote regular file or browser selection
of regular files after a five-second Undo window. Undo during that window
cancels deletion before submission; there is no remote Trash or recovery after
submission. RelayBar persists no deletion history, result, or filename. Remote file
contents are transferred only between the user's configured SSH server and Mac;
RelayBar sends them to no third party.

Markdown images, embeds, wiki links, tags, HTML, and Mermaid source do not make network requests. Markdown and JSON parsing, syntax highlighting, and math rendering happen locally. RelayBar sends an HTTP, HTTPS, or email link to macOS only after the user clicks that link; the selected system browser or mail app then applies its own privacy policy.

Removing RelayBar and its application data removes its saved tunnel definitions. Questions or security reports can be submitted through the project's GitHub repository.

## iPhone and iPad

RelayBar uses a built-in SSH client. When you first trust a host, RelayBar pins its key. A changed key blocks sign-in. If a host asks for a device key, the Secure Enclave creates one. The private key never leaves the device. If you choose to remember a password, RelayBar saves it as a this-device-only Keychain item after successful sign-in.

Host profiles, pinned host keys and reading history stay on the device. History holds up to 100 visits, including paths and reading positions. Favourites and search entries for opened images are also local. Opened files and thumbnails share a purgeable cache. In Settings, under Storage, choose Clear beside a host to clear its copies. To remove profiles and history together, delete the app and its local data. The cache control applies only to files and thumbnails.

RelayBar reads remote files over SSH from the host you choose. RelayBar has no developer account system or analytics.

### Web services and HTML previews

The service browser tries a reachable host directly, then opens a private name through an authenticated proxy over SSH. For a service that requires the exact name `localhost`, you can approve a gated listener on the device for that page. The service page can read its token in the user agent. Servers the page contacts can receive it there. Possession of the token does not prove who sent a request.

Service pages keep website data separately for each host. The optional Host’s Network plugin asks before connecting to another destination through that host. HTML file previews use a separate temporary store. Scripts follow your HTML Scripts setting. Internet resources load only with your permission for that host and contact the site that serves them.
