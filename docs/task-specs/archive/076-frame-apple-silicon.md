# Task 076 — Apple silicon support for future Frame releases

Status: Complete

## Outcome

Frame builds after 2.0.0 Beta 3 target Apple silicon on macOS 14 or later. Intel users can download Beta 3.

## Delivery Boundary

Frame's app bundle, CI build, release checks and support documentation.

## Work

Target arm64 in Frame's build script and verify the executable architecture before assembling the bundle. Document the last compatible Intel release and the native QA target for future releases.

## Acceptance

- A signed Release bundle extracted from a local ZIP contains an arm64-only Frame executable, has the macOS 14 minimum and matches its debug symbols.
- Frame's tests pass on Apple silicon.

## Verification

On November 18, 2026, `./scripts/package-release.sh frame` produced a local Frame 2.0.0 build 24 ZIP. In a fresh extraction, `lipo -archs` returned `arm64`, the Mach-O deployment target and the app's minimum OS were both 14.0, the executable and dSYM UUIDs matched, and strict deep code-signature verification passed. Both Debug and Release packaging rejected the universal Beta 3 executable when supplied as the build output.

`./scripts/test.sh frame` reported 238 Frame tests with 3 skipped and zero failures on Apple silicon. All 17 release-script tests passed.
