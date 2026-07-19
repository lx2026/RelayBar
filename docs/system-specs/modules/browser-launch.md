# Browser Launch

The browser button opens a forwarded web endpoint without requiring the user to type its URL.

## Contract

- The target is `http://<local-bind-host>:<local-port>/`.
- Missing and wildcard bind hosts (`*`, `0.0.0.0`, `::`) map to `localhost`.
- IPv6 hosts are emitted with URL brackets.
- A running tunnel opens immediately in the macOS default browser.
- A stopped tunnel starts first and opens after reaching running state.
- Starting or retrying tunnels retain one pending open request.
- Stop, edit, delete, quit, or retry exhaustion cancels the pending request.

The current model does not store custom schemes, paths, or per-tunnel launch URLs.
