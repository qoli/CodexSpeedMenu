# Version 1.1.0 validation

Validated on 2026-10-09 with Xcode 27.0 (27A266a).

## Distribution

- Requires macOS 14 or later; the executable contains arm64 and x86_64 architectures.
- Signed with `Developer ID Application: Weicai Huang (WQY45CL427)` using hardened runtime and a secure timestamp.
- Apple notarization accepted submission `35873ef0-61b7-45a8-bac4-2ce12955f0db` with no reported issues.
- The notarization ticket was stapled and validated.
- Gatekeeper accepted the app as `Notarized Developer ID`.
- SHA-256 of `Codex-Speed-1.1.0.zip`: `9ce1d8eeef4fec5caba031f391db73368952af6d944da621ba0e9a9f822ebcec`.

## Runtime

The final exported and stapled app was launched through macOS LaunchServices. Its native AppKit smoke check exercised the unchecked and armed menu states, speed-triggered assertion acquisition and renewal, expiry while the checkbox remained enabled, immediate reacquisition from a fresh speed, explicit disabling, long metadata, speed expiry and Quit termination.

While the final app held its lease, `pmset -g assertions` reported `PreventUserIdleSystemSleep` owned by `CodexSpeedMenu` and named `Recent Codex response`. The assertion disappeared after the lease expired, and the app still passed strict code signature verification afterward. Display-sleep prevention was not requested.

The Swift package suite passed all 12 XCTest cases, including real FSEvents append integration and missed-notification diagnostics. The keep-awake smoke used a synthetic fixture and an accelerated lease; it did not write the persisted production preference.

The universal binary was validated on Apple silicon. Execution on an Intel Mac was not tested.

Raw build, test, notarization and UI evidence is retained locally in `Evidence/`, which is excluded from the public repository.
