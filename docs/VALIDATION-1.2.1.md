# Version 1.2.1 validation

Validated on 2026-10-09 with Xcode 27.0 (27A266a).

## Distribution

- Requires macOS 14 or later; the executable contains arm64 and x86_64 architectures.
- Signed with `Developer ID Application: Weicai Huang (WQY45CL427)` using hardened runtime and a secure timestamp.
- Apple notarization accepted submission `127c3b5c-df9e-4f1a-b8c3-e672cc998667` with no reported issues.
- The notarization ticket was stapled and validated.
- Gatekeeper accepted the app as `Notarized Developer ID`.
- SHA-256 of `Codex-Speed-1.2.1.zip`: `4d22100a75c65b7e171ffcd5d91402aab54ec2b498b399f293007dc66eff1764`.

## Runtime

The final exported and stapled app was launched through macOS LaunchServices. Its native AppKit smoke check exercised the unchecked and armed menu states, speed-triggered assertion acquisition and renewal, expiry while the checkbox remained enabled, immediate reacquisition from a fresh speed, explicit disabling, source display, long metadata, speed expiry and Quit termination.

While the final app held its lease, `pmset -g assertions` reported `PreventUserIdleDisplaySleep` owned by `CodexSpeedMenu` and named `Recent coding agent response`. The assertion disappeared after the lease expired. Unified Logging recorded the assertion type, ID, expiration and release reason. Strict signature, stapling and Gatekeeper checks still passed afterward.

The Swift package suite passed all 12 XCTest cases, including real FSEvents append integration and missed-notification diagnostics. The universal release archive built successfully for Apple silicon and Intel. Execution was validated on Apple silicon; execution on an Intel Mac was not tested.

Raw build, test, notarization and UI evidence is retained locally in `Evidence/` and `dist/`, which are excluded from the public repository.
