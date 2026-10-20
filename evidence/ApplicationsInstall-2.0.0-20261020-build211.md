# LatticeLens 2.0.0 Build 211 — Local Install Receipt

Status: **installed and structurally verified; overall candidate remains `PARTIAL_NOT_FINAL`.**

## Artifact and validation provenance

- Project: `Reference_manager`, branch `main`; source baseline before this change: `83d902600e82891397bcac4f963e444921455483`.
- Candidate: `release-assets/Release-2.0.0-candidate-20261020-stream-idle-build211/`.
- Package run: `20261020T103624Z-da5ab0a2`.
- Host-free validation run: `20261020T102459Z-2a57d7d3`; input-manifest SHA-256: `0799297274742127cdd4c5201e96a53ca84ec008421a535d39178b44b3651289`.
- DMG SHA-256: `cf52858dcd8ca788b7654a303fc80c1e81f0c17c6cb52d1c13419e58ba222334` (`hdiutil verify` passed; `SHA256SUMS.txt` passed).

## Installation record

- Installed at `/Applications/LatticeLens.app` as version `2.0.0`, build `211`.
- Executable SHA-256: `426d7d7c9aadfb3ec26a2544eb48d3cdafc7d9f0bd5f61b5c4f85e51cb46e299`.
- Architectures: `x86_64 arm64`.
- `codesign --verify --deep --strict` passed. Signature is ad-hoc; the app is not Developer ID signed or notarized.
- The previously installed Build 210 was moved recoverably to `/Users/zhaodianjun/.Trash/LatticeLens.app.previous-build210-20261020`; its executable SHA-256 is `3b2039f429ba1f459d3b19ca122e0d0f9c21e39837e5fc7b04f11187d21bf5a1`.
- The installed app was left closed. No real user library, PDF, Keychain item, live INSPIRE service, or cloud-model provider was opened or contacted.

## Evidence boundary

- Host-free SwiftPM validation: `293 passed, 0 failed, 7 skipped` out of 300; Release warnings-as-errors build and V12 disk-performance stage passed. The manifest-bound disposable V10-to-V12 migration drill passed.
- Focused deadline/SSE regressions passed after the change. They verify that response-body transport activity refreshes stream-idle only after the first decoded content; it does not satisfy the independent first-content deadline, and the finite hard deadline remains unchanged. No live cloud-provider stream was run, so provider throughput behavior is not claimed.
- Xcode/XCUITest, VoiceOver, human three-paper physics review, live INSPIRE/provider checks, real-user-library startup/migration, and older-app data rollback remain `NOT_RUN` or incomplete. The package manifest and validation report therefore retain `PARTIAL_NOT_FINAL`; this receipt records installation, not full release acceptance.
