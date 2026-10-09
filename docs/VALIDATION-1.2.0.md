# Version 1.2.0 validation

Validated on 2026-10-09 with Xcode 27.0 (27A266a).

## Distribution

- Requires macOS 14 or later; the executable contains arm64 and x86_64 architectures.
- Signed with `Developer ID Application: Weicai Huang (WQY45CL427)` using hardened runtime and a secure timestamp.
- Apple notarization accepted submission `56f9163c-f65f-4676-a6ed-02ffe8d1cd5f` with no reported issues.
- The notarization ticket was stapled and validated.
- Gatekeeper accepted the app as `Notarized Developer ID`.
- SHA-256 of `Codex-Speed-1.2.0.zip`: `e2d248db97bcfbce38ff1e4f20883fef86134308beb88475859bdd8bbe15858f`.

## Runtime

The final exported and stapled app was launched through macOS LaunchServices. Its native AppKit smoke check exercised the unchecked and armed menu states, speed-triggered assertion acquisition and renewal, expiry while the checkbox remained enabled, immediate reacquisition from a fresh speed, explicit disabling, source display, long metadata, speed expiry and Quit termination. Strict signature, stapling and Gatekeeper checks still passed afterward.

The Swift package suite passed all 12 XCTest cases, including real FSEvents append integration and missed-notification diagnostics. A bounded scan of the four most recent real local Pi Coding Agent v3 session files read 3,283,784 bytes and emitted 226 valid Pi samples. Live FSEvents observation against the real Pi session directory also emitted Pi-labelled samples without monitor errors during implementation validation. No generated Pi JSONL fixture was used.

The native UI smoke uses the project's embedded Codex fixture and an accelerated keep-awake lease; it does not write the persisted production preference. The universal binary was validated on Apple silicon. Execution on an Intel Mac was not tested.

Raw build, test, notarization, real-session scan and UI evidence is retained locally in `Evidence/` and `dist/`, which are excluded from the public repository.
