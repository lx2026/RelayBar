# Task 012 — Cheapen Syntax Highlight Cache Lookups

Status: Withdrawn

Created: 2026-07-24

Withdrawn: 2026-07-25

## Withdrawal

The optimization made the code slower. It was implemented, committed to the branch, then reverted.

### What the task claimed

That `"\(appearanceKey)|\(language)|\(code)"` copies and hashes up to 64 KB on every lookup, so a fixed-size digest would be cheaper.

### What was measured

`PerformanceClaimTests.testHighlightCacheKeyCost` builds each key and performs one `NSCache` lookup. Release build, Apple silicon:

| code size | interpolated key | SHA-256 digest key | digest cost |
| --- | --- | --- | --- |
| 1 KB | 0.17 µs | 30.80 µs | 179× |
| 16 KB | 0.43 µs | 36.95 µs | 87× |
| 64 KB | 2.15 µs | 59.44 µs | 28× |

The premise was wrong in two ways. Swift's `NSString` bridging is lazy rather than an eager copy, and `NSCache` does not hash the whole string, so the original key never paid per byte. A digest must read every byte by definition, and the hex encoding through `String(format:)` dominated even that.

### Resolution

Reverted: the digest helper, the `CryptoKit` import, and the unit test that covered the helper. The interpolated key carries a note with the measured figures so it is not "optimized" again. The benchmark case is kept, renamed to mark the digest as the rejected shape, so the conclusion stays checkable.

### What went wrong in the process

"Copying and hashing 64 KB" was asserted from reading the expression, never measured. The unit test written for the task checked that the new key was stable and length-independent, which was true and irrelevant: it could not detect that the key was two orders of magnitude more expensive to produce. A performance change needs a measurement, not a correctness test.
