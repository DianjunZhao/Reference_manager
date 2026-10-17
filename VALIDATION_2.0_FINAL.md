# LatticeLens 2.0 Final Local Validation

**Verdict: PARTIAL_NOT_FINAL** — mandatory gates remain incomplete; this is not a release receipt.

Run ID: `20261003T144924Z-56009e8f`  
Verification mode: `host_free_only`  
Input manifest SHA-256: `8066e8d3c17017f9cda42b345cd1ca199625c567917e7a657b82931884d14161`  
Machine-readable report SHA-256: `b566c49b94cf4676f13f426a55fbb233f247f527f2cd36944b836b2206c155d4`  
Working tree dirty: `true`.

## Current automated evidence

- `swift test --scratch-path <run-scratch>/swiftpm -q`: 254 passed, 0 failed, 5 skipped out of 259.
- Warnings-as-errors SwiftPM Release build: `PASS`.
- Xcode actions: `NOT_RUN` by host-free mode; no Xcode build, test runner, or result inspection was started.
- Static checks: 10/10 passed.
- Host-free accessibility fixture is included in SwiftPM counts; it is not XCUITest or VoiceOver acceptance.

Skip allowlist:

- `testOptInLiveInspireFreshPersistentStoreLoadsPinnedAuthorAndPapers`: Live INSPIRE is optional and was not enabled.
- `testActualSwiftDataLargeStoreBenchmark`: The benchmark is a separate mandatory performance gate, not a unit-test pass.
- `testActualSwiftDataV11FormulaStoreBenchmark`: The V11 disk benchmark is run as a separate mandatory performance stage.
- `testAuthorizedDisposableV10ToV11MigrationDrill`: The V10-to-V11 reconciliation/rollback drill is run as its own manifest-bound mandatory stage.
- `testAuthorizedDisposableV7MigrationDrill`: This legacy-store drill requires an explicitly authorized disposable path.

## Mandatory gates

| Gate | Status | Evidence boundary |
| --- | --- | --- |
| G01 | PARTIAL | The SwiftPM baseline and category regressions ran; category/facet reachability and the full pagination UI matrix still require successful XCUITest evidence. |
| G02 | PARTIAL | The current SwiftPM run passed V8-to-V11 and V9-to-V11 staged factory migrations with source-family preservation, real V9 category-crash rollback, and a synthetic V8/V9/V10 matrix covering seven coordinator crash points, main/WAL/SHM byte preservation, corruption of each backed-up family member, semantic mismatch, cancellation, and an injected file-write-out-of-space error. WAL and SHM symlink refusal also passed. The manifest-bound V10-to-V11 activation/restore/rollback drill passed. G02 remains PARTIAL: physical disk exhaustion, missing-sidecar behavior, duplicate-ID corruption, and rejection by an older app build are not certified. |
| G03 | PARTIAL | Current parser and typed-proof regressions ran; the complete parser corpus and all tamper/relaunch cases are not certified. |
| G04 | PARTIAL | Finite request deadlines, heartbeat, late-callback and multi-batch regressions ran; full cancel/quit/relaunch lifecycle is not certified. |
| G05 | PARTIAL | Typed derivation-step validation ran; three-paper human physics review receipts are absent. |
| G06 | PARTIAL | Host-free mode intentionally marked every Xcode build/test/result action NOT_RUN. NOT_RUN by --host-free-only; no Xcode build or test command was started. Manual VoiceOver acceptance remains separate. |
| G07 | PARTIAL | The current SwiftPM run passed schema-6 typed inventory/job/claim/validation-report and analysis-run/attempt round-trip, schema-5 import into V11 staging, existing-target and tampered-report rejection before staging, and pre-stage and mid-stage cancellation checks. Injected post-stage failures at store-open, library-materialization, search-index, typed-state, and semantic-comparison checkpoints all removed the exact new SQLite family without changing Bundle bytes. The disk-backed V11 Radar/Compare/Notebook/Search regression also verifies row persistence across reopen and preservation of the prior Compare matrix after rejection. G07 remains PARTIAL: interactive Bundle UI/relaunch acceptance is not certified. |
| G08 | PASS | Current V11 disk benchmark met the checked gates: cold reopen p95=10 ms, warm search p95=111 ms; each 100-sample read/favorite/note mutation series met its 100 ms ceiling. |
| G09 | NOT_RUN | No provenance-bound 2.0 DMG, isolated install, or app/data rollback has been executed. |
| G10 | PARTIAL | This verifier cleans its own scratch and static checks ran; final manifest-driven cleanup/re-verification remains. |

## Blockers and limits

- Xcode unit runner: `NOT_RUN` — NOT_RUN by --host-free-only; no Xcode build or test command was started.
- XCUITest: `NOT_RUN` — NOT_RUN by --host-free-only; no Xcode build or test command was started.
- Manual VoiceOver and three-paper human physics review are `NOT_RUN`; a model or fixture cannot self-certify these reviews.
- G02 V10-to-V11 disposable migration: `PASS` — A generated V10 source was activated as V11, its verified pre-migration backup was restored to a fresh target after activation and reopened through the production factory, and a separate pre-activation crash recovered without publishing staging.
- G08 V11 disk benchmark: `PASS` — Current V11 disk benchmark met the checked gates: cold reopen p95=10 ms, warm search p95=111 ms; each 100-sample read/favorite/note mutation series met its 100 ms ceiling.
- G07 injected post-stage rejection checkpoints now verify exact new-store-family removal and unchanged Bundle bytes; disk-backed Radar/Compare/Notebook/Search persistence and rejected Compare matrix preservation are also required SwiftPM cases. Interactive Bundle UI/relaunch acceptance remains NOT_RUN. G09 is intentionally NOT_RUN in this pre-package verifier report; later candidate checks are recorded separately in the package manifest.
- A prior `xcrun simctl list devices available` diagnostic started `xcodebuild -runFirstLaunch`; its task-owned process group was terminated. Any partial global Xcode initialization effect is unverified; no global cleanup was attempted.
- Live INSPIRE/ar5iv/provider checks were not run and are not substituted by fixtures.
- The verifier writes a report when incomplete; `PARTIAL_NOT_FINAL` distinguishes unverified/blocked gates from explicit gate failures, and only `FINAL` returns zero.

## Reproduction

From the project directory run: `zsh Scripts/verify_2_0_final.sh --local-only --host-free-only`.
The run creates a unique project-local scratch, uses only synthetic stores, clears live opt-ins, freezes a source manifest before tests, runs the V11 performance opt-in as a separate manifest-bound stage, and removes only its own scratch after child processes exit. Host-free mode records every Xcode stage as NOT_RUN and does not invoke Xcode tooling.

Raw stage log: `evidence/Validation-2.0-final-local-20261003T144924Z-56009e8f.log`.
