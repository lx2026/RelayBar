# Tunnel Management

Each saved item is a forwarding profile: one SSH connection plus an ordered, non-empty collection of typed forwarding rules.

## Contract

- Users can add, edit, delete, start, and stop profiles.
- Each profile may have one optional group tag. The editor places a native **Group · Optional** picker below Name, and Quick Add leaves the selected group unchanged.
- When every profile is ungrouped, the saved list keeps its original flat presentation. Once any profile has a group, named sections use localized standard ordering, preserve saved order within each section, and place **Ungrouped** last when needed.
- Row menus can move a profile to Ungrouped, an existing group, or a new inline-created group. Named section menus can rename the group or ungroup every member; no separate group records are stored.
- Each row is one flat line of the popover list (layout in [Application shell](application-shell.md)): a status glyph in a 10-point column, the name in 13-point medium, a second line, and a switch.
  - The glyph differs by shape as well as colour: stopped is a hollow faint ring, running a solid green dot, starting an open muted arc that turns (still under Reduce Motion), retrying the same arc in orange, and failed a red warning triangle. The colours are the house palette's faint, running, muted, retrying and failure tokens ([House style](../shared/house-style.md)). Its accessibility label names the state.
  - The second line is one 11-point line: the compact port mapping in secondary monospaced text, whose tooltip and accessibility label are the full summary, then ` · ` and a detail. The two share the line evenly when both are long: the mapping gives up its middle and the detail its tail, so neither is squeezed out. A local SOCKS rule's compact mapping ends at "SOCKS", because the host follows it. Stopped and running rows show the SSH host with any Service Labels suffix; starting shows "Connecting…"; retrying shows, in orange text, "Retrying in 4s · attempt 2 of 10" with "Retrying in 4s · <reason>" as its tooltip, and VoiceOver reads the countdown, the attempt and the reason; failed shows the failure message in red text with the full message as its tooltip. The orange and red text are the warning and failure tokens, which keep at least 4.5:1 contrast on the popover's paper in both appearances and both forms of the palette.
  - The switch (`.mini`, drawn 36 × 16 points) is on while the profile is starting, retrying or running and starts or stops it. Its position always follows the profile's state, including after a request that changes nothing. Its tooltip is "Start profile" or "Stop profile" and its accessibility label "Start <name>" or "Stop <name>".
  - Under the pointer, or while keyboard focus is in the row, two 24-point buttons appear before the switch: Open in Browser (`arrow.up.right`, single Local TCP profiles only; tooltip "Open in browser", "Open in browser when connected" or "Start tunnel and open in browser" by state) and the row menu (`ellipsis`, tooltip and accessibility label "More actions for <name>"). Otherwise they take no space and stay in place invisibly, so keyboard focus and VoiceOver still reach them. Right-clicking the row opens the same menu.
  - **Move to Group › New Group…** opens an inline "New group name" field under the row, which keeps a faint fill until the field closes.
- Named section headers show the group name in 11-point semibold secondary text and one text action in 11-point medium accent at the trailing edge: Stop All while any member is starting, retrying or running, otherwise Start All. Start All needs an inactive member and Stop All needs an active one. Long names truncate before the controls; the action's help and accessibility label name the group ("Start all tunnels in <group>"). The actions menu appears just before it under the pointer or keyboard focus and is also the header's right-click menu. Ungrouped has a plain header without actions, and an all-ungrouped list has no headers.
- Named section menus hold Start All, Stop All and Restart All above rename and ungroup, separated; each is enabled under the same rule as before (Start All needs an inactive member, Stop All and Restart All an active one), so a group with some members running and some stopped keeps both. Targets for every group lifecycle action are resolved by canonical group identity and snapshotted when the action begins; profiles outside the group are never affected.
- Start All starts inactive members (an unsafe member fails visibly on its own row), Stop All stops starting, retrying, and running members while stopped and failed members keep their phase and message, and Restart All replaces each member active at invocation with one fresh launch of its current saved definition without starting stopped members.
- A rule is Local, Local SOCKS, Remote, or Remote SOCKS. Fixed Local and Remote rules independently support TCP-port and Unix-socket listeners and destinations; SOCKS listeners are TCP.
- The editor presents those four rule kinds in a menu with a rule-specific
  accessibility label, keeping the card inside the 380-point popover. The SSH
  host placeholder is plain text. A fixed explanation above Add Profile or
  Save Changes names the first invalid field or rule, even below the fold;
  invalid profiles remain unsavable.
- Tunnel-list summaries omit default `localhost` host text (`:8000 → db:5432`
  or `:8000 → :5432`), preserve explicit bindings, bracket IPv6, and show
  allocated remote ports. Full summaries remain in help and accessibility;
  copied endpoints and SSH arguments are unchanged.
- The editor can add, remove, duplicate, and reorder rules. It requires valid endpoints, unique rule identities, no overlapping listeners in the same namespace, and at least one rule.
- New listeners default to explicit loopback. Each explicit non-loopback listener names its rule and whether exposure is on the Mac or SSH server.
- Remote SOCKS requires an explicit Any, None, or host-and-port allowlist policy. Its effective policy remains visible in the profile summary and rule menu.
- Remote TCP port `0` means Automatic. Its allocated port is runtime-only, is shown and copyable while running, and is cleared on stop or restart.
- Profile-level Unix controls store a validated octal bind mask and whether a retry may remove a stale local socket whose type, device, and inode RelayBar recorded during the current app run. RelayBar never replaces an unowned path; remote socket cleanup remains server-controlled.
- Single Local TCP profiles retain the browser shortcut. Menus otherwise expose only type-correct copy or local-socket reveal actions. Reveal is offered from the rule's own shape rather than a filesystem probe, and falls back to the enclosing folder when the socket is already gone.
- Derived sections are computed once per change to the saved list rather than per view evaluation, so phase and runtime-port updates do not rebuild them.
- Editing an active profile stops it before replacing its definition.
- Changing only a group tag, moving a profile, renaming a group, or ungrouping members is metadata-only and preserves process phase, retries, pending browser work, runtime ports, and process ownership.
- Deleting a profile cancels its connection, control operation, retry, pending browser launch, runtime ports, and owned temporary artifacts.
- Definitions persist immediately after add, edit, delete, move, rename, or ungroup operations.
- With the Service Labels plugin on, a running profile's row shows what answered on its browser rule after the host: `<host> · <name>`, `· responding` when the page has no recognisable name, or `· no response`. The name is a recognised product (ComfyUI, Jupyter, TensorBoard, Stable Diffusion WebUI, Open WebUI, Gradio) or the page title. In the row's rule menu a labelled rule's title gains ` · <name>`. Labels disappear when the profile stops running. With the plugin off the list is unchanged. The request limits are in [Security boundaries](../shared/security-boundaries.md).

See [Data and state](../shared/data-and-state.md) for the stored schema.
