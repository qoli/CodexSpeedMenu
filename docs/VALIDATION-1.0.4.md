# Version 1.0.4 validation

Validated on 2026-10-05 with Xcode 27.0 (27A266a).

## Distribution

- Requires macOS 14 or later; the executable contains arm64 and x86_64 architectures.
- Signed with `Developer ID Application: Weicai Huang (WQY45CL427)` using hardened runtime and a secure timestamp.
- Apple notarization accepted the final app with no reported issues.
- The notarization ticket was stapled and validated.
- Gatekeeper accepted the app as `Notarized Developer ID`.
- The final ZIP was extracted and its app passed strict code signature verification, ticket validation, and Gatekeeper assessment.
- SHA-256 of `Codex-Speed-1.0.4.zip`: `e1a6ac5d08b10d9c57c12c4776bfecfd50ba1452edbc151754f822485b979247`.

## Runtime

The exported app was launched through macOS LaunchServices. Its actual AppKit status item displayed `idle`, a fixture speed of `20.0`, and `idle` again after expiry. The Quit menu item reached application termination.

Long metadata was exercised with a 107-character rollout filename and a Unicode model label. All menu text stayed within 420 points; the native menu measured 494 points including AppKit padding. Full values remained attached to native tooltips.

The core suite previously passed 11 XCTest cases, including real FSEvents append integration. Later presentation changes were rebuilt and verified through the native UI smoke test. For publication, the benchmark executable was rebuilt with a portable source-relative fixture path; its one-second append check processed all 220,400 expected bytes and 200 samples with no errors.

The speed UI check uses a synthetic fixture; it does not establish a fresh production response measurement. The universal binary was validated on Apple silicon; execution on an Intel Mac was not tested.

Raw build, test, notarization and UI evidence is retained locally in `Evidence/`, which is excluded from the public repository.
