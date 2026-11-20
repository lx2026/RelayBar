# Mobile web services

The RelayWebRoutes library accepts a RouteStreamOpener for each upstream SSH
profile. SSHSession conforms directly. An opener invokes its callback after
the destination accepts the connection and owns the stream until the callback
returns. Reads have one consumer. Writes apply backpressure and finishing the
write side keeps the read side available.

## Private-name proxy

SOCKSProxy.start binds an ephemeral IPv4 loopback port and generates a fresh
username and password. The port and credentials last for that proxy instance.
The caller replaces the set of exact ProxyDestination names and ports as pages
open and close, then calls stop to close the listener and its clients. Removing
a destination closes its established streams.

The server negotiates SOCKS5 username/password authentication and supports the
CONNECT command with domain, IPv4 and IPv6 address encodings. It checks the
destination before opening and again before acknowledging success. The profile
name and the IPv4 loopback aliases reach the SSH host's 127.0.0.1. An explicit
::1 entry reaches its IPv6 loopback. Refused connections yield reply 5,
administrative denial yields 2 and an unavailable host yields 4.

The optional `approval` callback on `SOCKSProxy.start` receives the exact
external destination when it is absent from the allow-list. Both allow answers
authorize that CONNECT to the requested host and port. The caller owns any
remembered decision and can include it in subsequent calls to
`setDestinations`. Refusal or expiry of `ProxyLimits.approvalTimeout` (default
30 seconds) yields reply 2. The callback never authorizes loopback literals or
localhost names. With no callback, only the private-name and loopback mappings
above are eligible.

ProxyLimits allows up to 16 upstream streams, including opens in progress, and
eight concurrent opens by default. Authenticated CONNECT requests waiting for
either limit enter a FIFO queue of up to 32 with a ten-second deadline. A full
queue or expired wait yields reply 1. The proxy bounds incoming sockets to the
combined stream and queue capacity and allows up to 16 incomplete handshakes.
Handshakes and upstream opens each have a five-second timeout. During reconnection
an admitted open holds its slot for up to five seconds waiting for recovery.
Both relay directions await writes and propagate EOF independently.

## Exact localhost gate

LocalhostGate.start binds 127.0.0.1 and ::1 on the requested port. A failed
second bind closes the first listener. When no port is requested, IPv4 chooses
the number; if that number is taken on ::1 the gate tries up to 32 further
numbers before failing. GateLimits defaults to 16 sockets
awaiting first authorization, 16 KiB per head and 45 seconds for a complete
head, including silent preconnects. When those slots fill, a new connection
displaces the oldest socket still awaiting authorization. Authorized sockets
can continue relaying.

GateRegistry.register issues a 128-bit random token tied to a profile, opener,
destination ports and allowed origins. Listeners on different ports can share a
registry. The caller appends GateToken.userAgentComponent to the user agent and
uses `GateToken.cookieName(for:)` and the token value for its HttpOnly cookie
on that port. Each HTTP/1.1 request, including a pipelined request, must pass
all of these checks.

- Host names localhost, 127.0.0.1 or [::1] at the listener's port. HTTP port 80 may be implicit.
- A supplied Origin names an explicitly registered loopback origin of the profile or its private .localhost name.
- A cross-site request requires fetch mode navigate and destination document (a top-level navigation).
- The user agent or gate cookie carries a registered token for this port. Credentials from different registered profiles on one request cause refusal. The first validated request fixes the connection's profile.

Credential comparison uses a constant-time byte comparison. The gate removes
the user-agent component and all cookies whose names begin with `__relay_`
before forwarding to the SSH host's 127.0.0.1 at the listener's port.
Other user-agent components and application cookies, including a service cookie
named `__relay`, pass through. Only the cookie named for the listener port can
supply a gate token. The gate emits fixed-text HTML for a refused head (403)
or an upstream open failure (502).

Each ordinary request has its own upstream stream. The gate streams
content-length and chunked uploads, consumes bounded request trailers locally
and validates the next request before forwarding it. Length-delimited replies
can reuse the client connection. A WebSocket upgrade switches to a bidirectional
byte stream after the upstream confirms the switch with a 101 response and
matching upgrade headers.

The owner revokes the service token when the page closes and stops each
listener when its last page closes or the app becomes inactive. Revocation
invalidates the grant across the registry and closes every client connection
that used it, including upgraded connections. Stopping a gate closes its
listeners and clients and revokes every grant covering its port, including
unused grants and grants shared with other ports. Restarting requires fresh
grants. `GateRegistry.revokeAll(for:)`
revokes every grant for one profile.

`GateRegistry.servedPorts(for:)` returns the intersection of currently bound
listener ports and the profile’s grants. The app can use this set to block
every other loopback port in a web view carrying the token. The token is a
shared secret. Service pages can read it in the user agent, and every server
a page contacts receives it there unless an intervening gate strips it.

## Mobile pages

Each signed-in host contributes direct and private-name routes. Localhost Compatibility adds the exact route and defaults on. Opening a service probes its host and TCP port for up to 650 ms. A reachable service opens directly. A failed probe or provisional direct load falls back to the host's private name. A rejected Host header or a main-frame redirect to localhost offers exact localhost. Declining suppresses future offers for that host and port. Accepting starts the listener for this page. Returning to exact localhost requires consent again. The page menu can reopen the offer or switch back to the private name.

Open pages on one host share an authenticated loopback proxy and a persistent WebKit data store identified by the profile UUID. The store receives its proxy configuration before the first request. Its match domain is `.localhost` and failover is disabled. Closing the last page lease stops the proxy. A live SSH reconnect keeps the page and proxy. WebKit content-process termination reloads the page.

The app serializes listener, grant and cookie changes across scenes. After binding a gate it compiles a WebKit content rule that blocks literal loopback destinations and exempts HTTP and WebSocket requests to the granted port. Each exact page uses only its own port from the profile's served ports. The session-only HttpOnly cookie and custom user agent are installed before navigation. Screen departure, scene deactivation and route changes release the grant, clear the user-agent component and remove the cookie. Other scenes sharing the port keep their own grants.

Open services groups saved service addresses by profile. Regular pages keep their live views while switching tabs in a workspace. Hidden pages stop when they use exact localhost, a Host's Network lease or an approved private certificate, or have an approval sheet pending. Saved tabs in the preference document contain scheme, port and path, and the destination name for a Host's Network page. Query strings, fragments, proxy credentials and gate grants stay out of that saved address. iPad scene restoration strips user information, queries and fragments from service URLs in both panes and their navigation history. The browser checks main-frame navigation against the chosen origin and displays navigation and HTTP errors.

Open Location accepts a port, a known host and port, or an HTTP(S) address on a known profile. It presents competing matches for selection. Pinned Websites defaults on and adds saved shortcuts to Home and Open Location. Website Labels defaults off. After a successful page load it makes one ephemeral GET with a three-second timeout, declines redirects, reads up to 64 KiB and recognises known products and otherwise keeps up to 40 characters of title. These plugins and Localhost Compatibility support a global choice and an override for each host.

The mobile test command includes an off-screen macOS WebKit executable with the app's embedded ATS exception. It checks the proxied secure context, a granted exact request, and a 403 response to a separate web view while the same gate is listening.

The exact-route content rule matches literal loopback addresses and localhost names. A public name that resolves to loopback can reach another local listener with the user-agent token. The service page can already read and disclose its token, so the DNS alias adds no new holder beyond those the page can choose. It does give the page a path to a local listener that can receive and replay the token. This DNS limitation is accepted.

## External destinations and private TLS

The Host’s Network adds an Open Location resolver for external HTTPS URLs and HTTP short names. Its web view uses a separate ephemeral store and a credentialed proxy with failover disabled. The proxy approval callback checks the requested name and port against the selected service. A WebKit content rule limits the page’s resource schemes and authorities. A main-frame redirect to another eligible destination opens that destination for separate approval. Full names over plain HTTP receive a reason. The sheet offers Allow once for the opened page, Always allow for this host, and Refuse. The plugin detail lists remembered endpoints by host and can remove them. Closing a page or withdrawing the route closes its proxy.

HTTPS on the SSH host opens under its private name. WebKit’s trust delegate checks the leaf certificate for the profile, private name and port. For an untrusted leaf the sheet shows the subject and SHA-256 fingerprint. An approved leaf answers subsequent challenges. A different leaf prompts review of both fingerprints and the connection is refused. Forgetting the old pin permits a fresh approval on retry.

The off-screen WebKit check creates temporary self-signed certificates and a loopback HTTP/1.1 service with a script and WebSocket. It loads the page through the private-name proxy, rotates the certificate at the same endpoint and checks refusal. A separate short-name page exercises the external route.
