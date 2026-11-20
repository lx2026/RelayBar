# App Review notes

RelayBar reads files from an SSH host on iPhone and iPad. Video downloads can continue in the background when the system grants a continued-processing task. Leave the app and return to check reconnection and the saved reading position.

## Try the reader

Launch from Xcode with `--demo-host`. The bundled demo supplies an in-memory host with the Evaluation summary and Side-by-side comparison Markdown documents, poster images with generation details, text, JSON, HTML, a notebook, a table and a short video. Browse a folder, open a document, inspect an image and return through Continue Reading. The bundled samples need no SSH credentials. In Open Location enter `6006` to see the Run monitor dashboard through the private-name proxy. Enter `8888` for Notebooks. It rejects the private name and RelayBar offers to open it on exact localhost. Accept to view the notebook service, or decline to keep the listener closed.

For an installed review build, use the isolated host below. This path needs neither launch arguments nor access to the maintainer’s private network. In Hosts, enter `<REVIEW_ACCOUNT>@<REVIEW_HOST>:<SSH_PORT>`. Compare the fingerprint with `<HOST_FINGERPRINT>`, accept the match and enter `<REVIEW_PASSWORD>`. In Open Location enter `<SAMPLE_FOLDER>`. Open the Markdown document and check that its relative image appears.

## Network access and service browser

Local-network access lets RelayBar contact a host chosen by the reviewer or user on a local network. The browser keeps pages inside the app so WebKit can use the host’s SSH route and apply its service-specific access checks. Enter `<SERVICE_PORT>` in Open Location. The sample page should open under the host’s private name via SSH, even though its HTTP server listens only on the remote loopback interface.

The App Transport Security settings allow local networking for direct local HTTP services and HTTP for `localhost` and its subdomains. Those names address the gated device listener and the private-name proxy route. Neither route needs a general exception for internet traffic. Confirm the settings and browser instructions against the review build before submission.

## Prepare the review host manually

1. Provision one small disposable machine at `<REVIEW_HOST>` outside private networks. Give it a fresh Ed25519 or ECDSA SSH host key; the app does not accept RSA host keys. Allow inbound connections only on `<SSH_PORT>`.
2. Create `<REVIEW_ACCOUNT>` with a temporary password `<REVIEW_PASSWORD>`, no administrative rights and read-only access to the samples. Restrict SSH sessions to internal SFTP. Disable terminal, agent, X11 and remote forwarding. Allow local TCP forwarding only to `127.0.0.1:<SERVICE_PORT>` for the sample service.
3. Put a Markdown document with two headings and a relative link such as `![Sample poster](images/poster.png)` in `<SAMPLE_FOLDER>`. Include the matching image. Use only material cleared for sharing.
4. Run one static HTTP service bound to `127.0.0.1:<SERVICE_PORT>`. Give its page a recognisable title. Verify it accepts the private host header and cannot be reached directly from outside the machine.
5. From an independent network, test the reviewer steps with the restricted account. Obtain `<HOST_FINGERPRINT>` from the machine console. Supply the actual connection details, fingerprint, sample path and port privately in App Review notes. Keep the machine available throughout review, then revoke the password and retire it.
