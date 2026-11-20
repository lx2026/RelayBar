# RelayBar System Specs

Concise specifications for the behavior currently implemented by RelayBar. Frame integration bundles updated: 2026-11-07. RelayBar 1.6.0/20 and Frame 0.1.0/15 use bridge v6 document resources, batch deletion and companion groups. Both apps are running; native remote Markdown/HTML viewing passed. Local signed update only; public stable remains 1.6.0/11. The source has since moved to the single-owner composition kernel and bridge v7 ([Task 059](../task-specs/059-single-owner-composition.md)); those changes are not installed.

## Modules

- [Application shell](modules/application-shell.md)
- [Tunnel management](modules/tunnel-management.md)
- [SSH command import](modules/ssh-command-import.md)
- [Process lifecycle](modules/process-lifecycle.md)
- [Browser launch](modules/browser-launch.md)
- [Remote files](modules/remote-files.md)
- [Frame viewer handoff](modules/frame-viewer.md)
- [Markdown preview](modules/markdown-preview.md)
- [JSON preview](modules/json-preview.md)
- [Video preview](modules/video-preview.md)
- [SSH transport](modules/ssh-transport.md)
- [RelayBar for iPhone and iPad](modules/mobile-app.md)
- [Web services on iPhone and iPad](modules/mobile-web-services.md)

## Shared contracts

- [Composition and previews](shared/composition.md)
- [House style](shared/house-style.md)
- [Data and state](shared/data-and-state.md)
- [Security boundaries](shared/security-boundaries.md)

## Operations

- [Build and release](operations/build-and-release.md)
- [Verification](operations/verification.md)

Update the relevant spec with behavior changes. Keep proposed behavior explicitly labeled; source code remains authoritative when a spec is stale.

RelayBar directly previews HTML/HTM with requested relative dependencies and online resources. See [Remote Files](modules/remote-files.md).
