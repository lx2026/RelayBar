# Adding a feature

Features are statically linked Swift code in this monorepo. They need no other repository, package release or runtime loader.

## When something is a feature

Make a feature only where something can come or go by itself: a user switch, availability that changes at run time (a session, a window, an open catalog), or a second realm. Everything else is a plain object owned by an effect scope inside a feature. Rows of user data, such as tunnel profiles, are not features.

## Steps

1. Name what it exchanges. A service key is a type:

   ```swift
   enum Thumbnails: ServiceKey { typealias Value = FrameThumbnailsFeature }
   ```

2. Write the feature as a struct. Stored properties are the whole contract.

   ```swift
   struct ExampleFeature: Feature {
       let limit: Int                                  // configuration: a new value reloads this feature
       @Constant var factory: ExampleFactory           // handed in by the composition root; never compared
       @Need(Tunnels.self) var tunnels                 // required; the feature waits until it is offered
       @Offer(Example.self) var example                // a slot this feature may fill and clear

       func run(_ context: FeatureContext) async throws {
           let resource = try factory.make(limit: limit, tunnels: tunnels)
           try context.effect("example resource", cancel: { resource.stop() }) { await resource.close() }
           example.set(resource)
       }
   }
   ```

   Keep the initializer free of side effects: the runtime builds a value to compare before it decides to load. Register the undo for anything acquired, with a label that will make sense in a stuck-cleanup report. Use `cancel:` when stopping must unblock work before anything is joined; it must be idempotent.

3. Return it from the app's tree function, under whatever condition makes it exist.

   ```swift
   if chosen.exampleEnabled { FeatureNode("example") { ExampleFeature(limit: chosen.exampleLimit, factory: factory) } }
   ```

4. If the shell needs the service, read it through a port or `runtime.service(Example.self)`. Do not assign it into a view model from inside the feature.

5. If the user can change it, add a field to the app's preference document and edit it through the preference store. Do not persist feature ids.

6. If the person should be able to switch the whole feature off, declare it as a plugin instead of adding a setting: add a `PluginDescriptor` to the app's catalog (`RelayPlugins` or `FramePlugins`) naming the feature ids it contributes, and return its nodes from the tree function only while `preferences.value.plugins.isEnabled(descriptor)` is true. The Plugins window then lists it, shows what it needs and what depends on it, and switches it; nothing else is required.

## Rules of thumb

- Own background work with `context.task` and calls whose late result must be dropped with `context.perform`. Both are joined before the feature finishes unloading.
- Availability that changes while the feature runs goes through the slot: `set` when it appears, `clear` when it ends. Do not ask the composition root to add or remove the node.
- A setting that tunes a live service without restarting it is a tiny feature whose configuration is the setting and whose `run` applies it.
- A mutation worker records any committed outcome it needs for recovery before it suppresses stale UI callbacks. Frame's Trash feature records its recovery receipt inside the owned operation.
- Never await `runtime.settled()` from work a feature owns; that work is joined before the feature can unload.

## Proof that the path works

`CompositionFixtures.FileProbe` lives in another module and is linked only by test targets. It owns a temporary file and a notification observer. The kernel tests and both apps' composition tests add it with a single node, observe a notification, remove it, add it again and remove it. A notification posted after removal cannot recreate its file, and an unrelated feature keeps the same instance throughout. Neither app shell imports the fixture or branches on it.
