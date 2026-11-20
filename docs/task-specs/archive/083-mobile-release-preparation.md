# Task 083: Mobile release preparation

Status: Complete
Design: [RelayBar for iPhone and iPad](../../designs/relaybar-ios.md)
Verification: [record](../../verification/077-083-relaybar-mobile.md)
Depends on: Task 082

## Outcome

Everything a first TestFlight build needs is in the repository and checked, and nothing has been uploaded.

## Delivery Boundary

Included: statements, store text, review material, icons, build settings and scripts, and the device checklist.

Excluded: any upload, submission or other action against App Store Connect, which needs the maintainer's explicit approval; changes to the Mac apps.

## Work

1. `PRIVACY.md` and `SECURITY.md` cover the mobile app: a built-in SSH client, the device key, what is stored on the device, the two service routes and the permission for previewed HTML.
2. App icon and launch screen from the existing route mark, in the sizes iOS requires.
3. Version and build numbers, and notes on the export-compliance filing. The encryption declaration in the app's information property list is the maintainer's to make: the archive script refuses to run until it is present.
4. Store text: name, subtitle, description, keywords and the privacy answers, as a document.
5. Review material: notes for App Review, and a described, isolated review host with a sample document and a loopback service. Setting that host up is a manual step for the maintainer.
6. A script that produces a signed archive for TestFlight and stops before upload.
7. The device checklist, complete, with each check from the design's open list.

## Acceptance

- The archive script produces an archive for a generic iOS device, or stops with a clear message when signing assets are missing, and never uploads.
- `git diff --check` is clean, and the repository's test script passes.
- The checklist, review notes and store text exist under `docs/` and name no private host, account or path.
- `docs/system-specs/operations/build-and-release.md` describes the mobile build and states that publication needs approval.
