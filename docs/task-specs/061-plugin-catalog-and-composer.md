# Plugin catalog and composer

Status: Implemented — 2026-11-14. The automated gate passes and offscreen snapshots were reviewed; the window was not tried in a running app. Evidence: [verification record](../verification/061-062-plugins.md).

## Outcome

Optional features become plugins a person can see, understand and switch. Each app has a small catalog of plugins and a Plugins window that shows the live feature map: what is running, what each feature needs and offers, why something is waiting, and what turning a plugin off would take with it. Both apps use the same window.

## Delivery Boundary

- Builds on [Task 059](059-single-owner-composition.md). A plugin is a `Feature` that the user may turn off; nothing about the kernel's ownership rules changes.
- Composing means switching plugins and seeing the result. There is no drag-and-drop wiring, no runtime code loading and no third-party plugin format.
- The window is diagnostic as well as a switchboard, so it shows every feature, not only plugins. Core features cannot be turned off from it.
- Plugin choices are stored in each app's existing preference document as overrides of the defaults. A document saved before this task must still load.
- The shared view lives in a new `CompositionUI` module shipped inside the existing `Composition` library product, so RelayBar's Xcode project needs no new package product.
- Excluded: per-plugin settings screens, reordering, search, and any change to how core features are composed.

## Work

1. **Describe the running tree.** `FeatureRuntime` publishes a `FeatureGraph`: one node per wanted feature (id, parent, realm, phase with its reason, generation, the names of the services it needs and offers, owned-resource count) and one edge per need (provider, consumer, service name, satisfied or not). Add `dependents(of:)`: every feature that would unload, directly or transitively, if the named one were removed. Both are derived from what the runtime already knows.
2. **Catalog.** `PluginDescriptor` (id, title, one-sentence summary, SF Symbol name, default on or off, the feature ids it contributes) and a `PluginChoices` value (`[String: Bool]` overrides with `isEnabled(_:)`). Each app declares its catalog in one place and mounts a plugin's nodes from its tree function only while the plugin is enabled.
3. **Composer view** (`CompositionUI.PluginComposerView`, macOS 13+), driven by a small observable model protocol (plugins, graph, enabled state, `setEnabled`, `retry`):
   - **Plugins column** (248 pt): one row per plugin with its symbol, title, summary and a switch. A failed or stuck feature shows its reason and a Retry button; "Waiting" with the kernel's reason appears only when none of the plugin's features is running.
   - **Map**: features in columns by dependency depth, providers on the left; a realm is a labelled, dashed container. A node shows the feature id and a status mark. Plugin nodes carry the accent colour; core nodes are neutral. Edges run provider to consumer and stay faint until a node is selected; an unsatisfied edge is dashed and orange. Service names are listed in the inspector, not drawn on the map.
   - **Selection** highlights everything upstream and downstream of the node and dims the rest. The inspector lists status and reason, needs with their providers, offers, and for a plugin "Turning this off also unloads: …" from `dependents(of:)`.
   - Status is never colour alone: running, waiting, failed and stuck each have a distinct mark and a text label. The window works in light and dark appearance and with Reduce Motion.
   - Layout is a pure function from graph to positions so it can be tested without a window.
4. **Apps.** Each app gets a `plugins` field in its preference document, a "Plugins…" entry next to its existing settings, and a window hosting the composer. Toggling goes through the preference store, then the tree, like every other setting.
5. **Docs.** Extend the composition spec and the adding-a-feature guide with how to declare a plugin.

## Acceptance

- Graph tests: nodes, edges and realms match a known tree; an unsatisfied need is reported with its provider; `dependents(of:)` is transitive and includes children; the graph updates when a slot fills or clears.
- Layout tests: providers are left of consumers; no two nodes overlap; realm containers enclose exactly their nodes; the result is stable for the same graph.
- In each app, turning a plugin off unloads exactly its features and their dependents, turning it on restores them, the choice survives a restart, and a preference document without the `plugins` field loads with defaults.
- Offscreen snapshots of the composer (light and dark; a tree with running, waiting, failed and off states; one node selected) are produced by an opt-in snapshot test and reviewed.
- `scripts/test.sh` passes with warnings as errors; both apps build, including RelayBar's Xcode target; `git diff --check` passes; specs updated.
