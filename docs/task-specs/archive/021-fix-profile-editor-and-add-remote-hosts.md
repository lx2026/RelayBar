# Task 021 — Fix Profile Editor and Add Remote Hosts

Status: Complete

Created: 2026-07-26

Completed: 2026-07-26

## Outcome

The New Profile editor fits the 380-point menu window, and Remote Files can
connect to an SSH server without requiring that server to own a forwarding
profile.

## Delivery Boundary

- Keep forwarding profiles and standalone Remote Files hosts as separate local
  records.
- Combine recent Remote Files connections, standalone hosts, forwarding-profile
  connections, and concrete aliases from the user’s OpenSSH config.
- Continue to invoke the system `sftp` executable with structured arguments.
- Do not modify `~/.ssh/config`, create an implicit forwarding rule, or start an
  SSH forwarding process when a standalone host is added.
- Keep saved and recent host metadata local to RelayBar.

## Work

- Constrain the profile editor’s vertical scroll content to the menu width,
  preserve horizontal padding, and remove the duplicate Group picker label.
- Add a bounded OpenSSH-config alias reader that ignores wildcard and negated
  host patterns.
- Persist user-added Remote Files hosts independently of tunnel profiles.
- Persist a bounded list of successfully opened recent servers.
- Merge and deduplicate all server sources by SSH host and safe connection
  arguments, with recent servers first.
- Add an accessible Add Host flow to the Remote Files launcher and allow
  user-added hosts to be removed.

## Acceptance

- New Profile content stays inside the 380 × 440 menu window in light and dark
  appearances, with 16-point horizontal content padding and one Group label.
- A user with no forwarding profiles can add `user@server`, select it, and open
  an absolute remote path.
- Concrete `Host` aliases from `~/.ssh/config` appear without creating RelayBar
  records; `Host *`, wildcard, and negated patterns do not appear.
- Equivalent recent, standalone, profile, and config connections appear once.
- A successful folder open promotes that connection to the bounded recent list;
  a failed open does not.
- Removing a standalone host does not delete a forwarding profile or edit SSH
  config.
- Existing Remote Files navigation, preview, download, cancellation, and
  forwarding-profile selection tests continue to pass.
- Relevant unit tests, visual evidence, `swift test`, and `git diff --check`
  pass.
