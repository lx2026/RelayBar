# SSH transport

RelayTransport provides an SSH client for macOS 14 and iOS 27. Each connected
`SSHSession` owns one Network framework TCP connection. The session accepts
outbound SFTP and direct TCP channels and rejects peer-initiated channel opens.

## Session and trust

Create a `SessionConfiguration` with a host, port, username and async trust
callback. Supply a saved `HostKey` to enforce an existing pin. The callback
receives the SSH key type and the OpenSSH SHA-256 fingerprint of the wire key.
A matching pin bypasses the trust callback. A mismatch fails before credential
providers run. After successful sign-in the session retains the accepted key
across reconnects. The caller owns persistent pins and credential storage.

`resume()` connects and returns the accepted sign-in method. Concurrent callers
share connection establishment. The client first offers SSH none, then an
offered public-key method with a supplied signer, then an offered password
method with a supplied password callback. SigningKey accepts CryptoKit Ed25519,
P-256 and Secure Enclave P-256 signing keys. The banner callback receives server
authentication messages. Refusal reports the server methods recognized by the
SSH library, and negotiation failure reports the supported algorithms. A signer
or password provider that throws ends sign-in as a refusal, or as cancellation
when the provider was cancelled. A TCP connection attempt reports network
refusals immediately and has a 15-second deadline. The SSH handshake has a
120-second deadline that pauses while the caller answers the trust question.

Consume `states` as a single async event stream. It emits connecting, verifying,
authenticating, ready, interrupted and failed states. After connection loss,
the session opens a new transport with jittered exponential backoff between
one and 30 seconds. The first retry waits one to two seconds by default. A
reconnect attempt that fails to reach the host is reported as interrupted while
retries continue. Failed means the session has stopped. Trust and sign-in
failures stop retries. Suspending closes the transport and its channels and
cancels retries. Resuming starts immediately, including after a failed manual
attempt.

After 30 seconds without an SFTP reply, the session probes with a read-only
SFTP stat of the root directory. Two missed ten-second response intervals
interrupt the transport. SessionPolicy configures these intervals and backoff.

A network path change wakes pending backoff or probes the current ready session
with an SFTP stat. A reply or server refusal keeps the session. While the reply
is pending, each nonempty TCP read on that connection extends the path-change
deadline by one probe interval, including bytes for other SSH channels. A silent
connection reconnects immediately. Each connection tracks its own activity so
a late probe cannot reconnect a newer session.

## Files

Concurrent calls to `sftp()` share a lazily negotiated SFTP v3 subsystem.
Paths must be absolute, free of control characters and at most 32 KiB. The client
supports realpath, stat, lstat, directory listing, and opening files for reads.
Open, stat, lstat and list accept either a string or raw path bytes (Data).
Listing awaits the visitor before reading the next directory packet. It
returns the delivered count and a truncation flag. The flag is true only if
another eligible entry exists beyond the caller’s limit (default 10,000).
Listing filters path-shaped, dot, control-containing and oversized basenames.
Entries preserve the original filename bytes and supply a display string with
UTF-8 replacement characters. Attributes expose optional size, owner, group, mode and timestamps.

`SFTPFile.read(range:priority:consume:)` delivers ordered chunks. The default
range runs to EOF. Each file handle supports one active read. Open another
handle for concurrent operations. The session defaults to 16 outstanding
32 KiB reads and a 2 MiB ceiling on bytes held across reads, configurable
through ReadPolicy. The sliding window refills as requests complete, including
while the consumer is busy. Completed replies wait in file-offset order and
continue to count against the byte budget until the consumer returns.
When advertised, the OpenSSH limits extension further bounds packet size,
read size and open handles. The client matches replies by request ID, fills
short reads and gives waiting interactive operations priority when capacity
becomes available. While requests are pending, each reply restarts the
30-second silence timeout. Expiry closes the subsystem and fails pending requests.

Close file handles explicitly after use. Cancellation during a read closes the
handle before reporting cancellation. A directory listing closes its handle
when it ends or the visitor throws. SFTP errors distinguish missing files,
denied access, EOF, malformed replies, local handle limits and other server
status codes.

### Guarded removal and log following

Create an `SFTPFileFingerprint(path:attributes:)` from the selected row's exact
absolute path and listed attributes. It requires a regular file with a known
size and modification time. `remove(_:matching:)` rechecks those fields and
the path with LSTAT immediately before sending one REMOVE. Both APIs accept
String and Data paths. Refusals distinguish directory, symbolic link, changed
file and missing path. Only a successful server status acknowledges deletion.
SFTP v3 leaves a race between LSTAT and REMOVE if another client changes the
path during that interval.

`tail(_:offset:identity:)` accepts either path form. Each poll opens the file,
gets its size from that handle and returns up to 2 MiB from the supplied
offset. Pass the returned `nextOffset` and `identity` into the next poll.
A shorter file, short read or continuity mismatch yields `reset`, empty bytes
and offset zero. SFTP v3 supplies no inode identifier. The token checks the
path, offset and SHA-256 digest of up to 4 KiB immediately before that offset.
A replacement preserving that window can be indistinguishable from an append.

## Forwarded streams

`withStream(host:port:_:)` opens one direct-tcpip channel for the duration of
the closure. Async writes and a single-consumer byte sequence use NIO channel
backpressure. Finishing writes sends EOF and leaves reads available. A refused
destination connection and an administrative forwarding denial have distinct
transport errors. Read and write failures on an open stream report
disconnection or cancellation. Errors thrown by the caller’s stream closure
propagate to the caller. The pinned SSH library exposes the numeric channel-open
failure reason in its formatted diagnostic.
