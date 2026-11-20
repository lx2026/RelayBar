# Task 077: Shared packages on iOS

Status: Complete
Design: [RelayBar for iPhone and iPad](../../designs/relaybar-ios.md)
Verification: [record](../../verification/077-083-relaybar-mobile.md)

## Outcome

`Composition`, `HouseStyle`, `PreviewSupport`, `AssetGrouping` and `MarkdownRendering` build for iOS 27 and behave there as they do on macOS, and a plugin can own a feature inside every host realm.

## Delivery Boundary

Included: `Packages/AppComposition` and its tests, and the system specs that describe it.

Excluded: any iOS screen, including an iOS Plugins view (Task 081); `BridgeProtocol` on iOS; any change to how RelayBar or Frame look or behave on macOS; `scripts/` and CI, which Task 078 edits.

## Work

1. Add iOS 27 to the package platforms. Keep macOS 13 and every existing product name.
2. `CompositionUI`: `PluginComposer` and `FeatureMapLayout` compile on both platforms. The AppKit `PluginComposerView` compiles on macOS only.
3. `HouseStyle`: every token resolves on UIKit with the same values in both forms and appearances. Form switching and `HousePalette.didChangeNotification` work as on macOS. Callers of `HouseColor` do not change.
4. `MarkdownRendering`: no shared path depends on AppKit. Code highlighting and math produce the same HTML on both platforms, and a typeset equation keeps its size, baseline, scale and dark-appearance inversion.
5. Plugins: a `PluginDescriptor` can name features by a path relative to a realm, resolved over the realms present. Pruning and the composer's ownership, trouble and reveal use that resolution. The existing RelayBar and Frame catalogs behave as before.
6. Targets that cannot exist on iOS are compiled out there, not removed.

## Acceptance

- Each of the five products builds for the iOS Simulator SDK with a generic destination and no simulator booted.
- `./scripts/test.sh` passes for the shared package, RelayBar and Frame with warnings as errors.
- A test renders the existing Markdown fixtures through the platform-neutral path and matches the current macOS output, including math image metrics.
- Kernel tests show a plugin with realm-relative membership mounting once per realm, pruning per realm, and the composer reporting its ownership in each.
- `docs/system-specs/shared/composition.md`, `shared/house-style.md` and `modules/markdown-preview.md` describe the result.
