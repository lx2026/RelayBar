# Task 065 — public-readiness cleanup

Date: 2026-11-16. Implemented and committed locally. No push, version change, installation, Apple submission or publication occurred, and the installed test apps were not replaced.

## Bundle identifier

- Frame is `com.lx2026.Frame`; its two helper builds are `com.lx2026.Frame.workspace-verification` and `com.lx2026.Frame.design-prototype`. The change covers Frame's `Info.plist`, `FrameBridgeEnvironment.frameBundle`, `VerificationLibrary` and the two helper plists. The App Group is unchanged.
- Earlier Frame verification records now name the new identifier; the builds they describe used a different, pre-release one. A Frame installed before this change keeps its old sandbox container, so the rebuilt pair must be installed together and Frame starts with fresh settings.
- The disposable loopback SFTP proof test uses the current user's name instead of a fixed one.

## Open in Frame plugin

- RelayBar's catalog has a third plugin, Open in Frame, which switches the bridge host and the window's Frame connection. Until the person chooses, it is on only if Frame was installed when RelayBar launched; a choice made in the Plugins window is stored even when it equals that launch's default, so it holds at every later launch.
- With the plugin off the bridge does not listen, and both Open in Frame buttons and the Settings Frame Viewer row are absent. Turning it off keeps an existing access grant.
- Tests cover the catalog, the default from an injected installed flag, an explicit choice in both directions, the absent listener and connection, and switching on and off at runtime.
- Writing the runtime test exposed a crash in the shared bridge server: a peer that connected and hung up at once could raise SIGPIPE when the server wrote its rejection. Each accepted socket is now protected before anything can write to it, and a peer that has already gone is dropped unanswered. The new test crashed three of three runs before the change and passed five of five after.
- Not run in a real app: controls appearing and disappearing, the real installed lookup, the third row in the Plugins window, and Frame reconnecting after the plugin is turned back on. The RelayBar captures under `assets/061-plugins-window/` predate the third plugin.

## Personal details

- Fourteen Frame screenshots showed a home-directory path under the window title, and two also showed one in the sidebar. Each path was covered with the surrounding background colour; dimensions, format and metadata are unchanged. Every edited image was reopened, and a text-recognition pass over all 75 committable images found no home path.
- Home paths and a private project name were removed from eight text files, tool-session identifiers and sign-in detail from ten, and a private link from the Task 059 spec. `build-workspace-mock.mjs` writes its extra copy only to a path given as an argument.
- `frame-workspace-preview.html`, a duplicate design preview that embedded third-party harness code, was deleted; nothing referenced it.
- Across every file to be committed, a search for the maintainer's home path and username, the private project name and tool-session links returns nothing. `/Users/` remains only in invented test paths.
- Left as they are: a real SSH user and host in RelayBar tests and in verification records 001, 003, 026, 029 and 034, all already in published history; the `Model:` lines in Frame's design-review notes; and widget-state hooks in the two remaining design mock pages.

## Checks

On the final tree with Swift 6.4.2: 9 script tests; 94 shared tests with 3 skipped; 431 RelayBar tests with 29 skipped (the opt-in capture classes); 190 Frame tests with 2 skipped; no failures. The Frame product builds with warnings as errors, the unsigned Release build of the RelayBar project succeeds, and `git diff --check` is clean. Log: `.build/task-065-gate.log`.
