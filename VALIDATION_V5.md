# LatticeLens / Reference_manager 1.0 — v5 validation ledger

Status date: 2026-08-28.  This is a fail-closed working ledger, not a final
release declaration.  The only permissible final name remains
`LatticeLens 1.0.0 / Reference_manager 1.0 — final same-Mac local release,
ad-hoc signed, not notarized`, and only after every mandatory and manual gate
is independently evidenced.

## Scope and safety boundary

- All work was confined to this project directory.  No active Application
  Support library, PDF library, Keychain item, live INSPIRE endpoint, live LLM
  endpoint, `/Applications/LatticeLens.app`, or user-selected Research Bundle
  was read or changed.
- The user-authorized synthetic, disposable V7 `.store` family was migrated
  on 2026-08-26 into a fresh, pre-existing empty project-local output root.
  The retained evidence records `sourceOrigin=synthetic_v7_benchmark`; it
  proves the migration/backup/recovery mechanics only, not a real user-library
  migration or a manual application/data rollback.
- Historical v1–v4 ledgers, releases and result bundles remain historical
  evidence only.  They are not promoted to current v5 source evidence.

## Provenance-valid automatic candidate — manual landing still pending

`zsh Scripts/verify_v5.sh --local-only` produced
`validation-v5-20260828T023235Z-134.json` with the non-empty build-input-tree
hash `f1458e59d1aa5b3703bff11ec07679ffda1786525ce9994c2540cef163d5a711`.
Its prepackage validation, package manifest and independent mounted-DMG
fixture/no-network smoke are mutually bound to that same hash.  The package
manifest is `Release-1.0.0-local/manifest-v1.0.json`, SHA-256
`2564c849ad05beea10463ea09f75fc707a5a74fb0ab49d9f211b8c252d74dd36`; it
describes `1.0.0 (100)`, `x86_64 arm64`, `ad_hoc_local`,
`developer_id=false`, and `notarized=false`.

| Gate | Current evidence | Disposition |
| --- | --- | --- |
| Automatic product gates | SwiftPM, actual SwiftData benchmark, SwiftPM Release, Xcode build/analyze/unit, typed store, physics validator, Radar, Compare, Notebook, Bundle and icon/version are all `true` in the same summary | PASS for the recorded candidate |
| Fixture UI | Readable current verifier results: normal **21/21 passed, 0 failed, 0 skipped**; large **5/5 passed, 0 failed, 0 skipped** | PASS for the recorded candidate |
| Synthetic disposable migration | `migration-v7-disposable-drill.json`: source `synthetic-v7-benchmark-disposable.store`, origin `synthetic_v7_benchmark`, final schema 9, activated journal and current search index | PASS for disposable mechanics only |
| DMG | `LatticeLens-1.0.0-local.dmg` SHA-256 `82903e434cfc213068cfa8019c3bde9b5507511606033bf3497a7f257739d99b`; mounted fixture/no-network smoke passed | PASS for same-Mac ad-hoc local artifact only |
| Cleanup | Approved manifest SHA-256 `2b00e57a4ad4a50a2f397e558fd62b5c085f3c58654fcf0a121acf780b04cfcf`; `CleanupApplyReceipt-v1.0-20260828T030918Z.json` records 207 deleted paths, 0 absent paths and 40,327,176,192 bytes | PASS for this approved whitelist |
| Manual acceptance | `MANUAL_V5_ACCEPTANCE.md` remains `NOT_RUN`; no manifest-bound receipt has been synthesized | BLOCKED / fail-closed |

The current candidate must be revalidated after any tracked build input
changes. In particular, this ledger/README/CHANGELOG update is intentionally
not back-projected onto the prior hash: it requires a new package before any
subsequent manual receipt can be bound.

## Superseded automatic run — build-input provenance invalid

`zsh Scripts/verify_v5.sh --local-only` produced
`validation-v5-20260827T142210Z-50893.json` before the provenance repair.
Its `build-inputs-v5.json` had `files:[]`; therefore its recorded tree hash
`096667c4ba61e0d8c984861b01171b3b49cd5a2d2a2ffa41c1446bda38142f95` covered
none of Sources, Tests, Scripts, assets, Xcode project, `Package.swift`,
`README.md`, or `CHANGELOG.md`.  This is a v5 G1 P0 failure.  The prior
release was preserved, without alteration, as
`Release-1.0.0-local-provenance-invalid-build-inputs-20260827T142210Z/`; it
is historical execution evidence and **not** a current candidate.

| Gate | Evidence | Disposition |
| --- | --- | --- |
| SwiftPM + actual disk benchmark | 2,000 authors, 20,000 papers, 100,000 links and 10,000 chunks; p95: warm search 31 ms, cold open 28 ms, single-row mutation 3 ms, V7 warm search 27 ms | Historical execution PASS only; needs new provenance-bound run |
| Xcode Debug / Release / analyze / unit | Fresh default-timeout verifier gates were all `true` | Historical execution PASS only; needs new provenance-bound run |
| Normal fixture UI | Readable `ui-normal.xcresult`: **21 passed / 0 failed / 0 skipped** | Historical execution PASS only; needs new provenance-bound run |
| Large fixture UI | Readable `ui-large.xcresult`: **5 passed / 0 failed / 0 skipped** | Historical execution PASS only; needs new provenance-bound run |
| Typed store / validator / Radar / Compare / Notebook / Bundle | Each named automatic contract gate was `true` in the same machine summary | Historical execution PASS only; needs new provenance-bound run |
| Synthetic disposable migration | Source origin `synthetic_v7_benchmark`; V7 family source is retained separately from the active target; semantic counts are 2,000 authors, 20,000 papers, 100,000 links and 10,000 chunks | Historical synthetic/disposable mechanics PASS only |
| DMG | The archived universal (`x86_64 arm64`) ad-hoc app, matching dSYM, checksum manifest, mounted-DMG verification and project-local fixture/no-network copy-launch smoke were recorded | **FAIL for current candidate:** empty build-input manifest invalidates provenance |
| Cleanup | Historical 2026-08-27 dry-run only; it predates the reviewed 2026-08-28 207-target whitelist and its applied receipt recorded above | Historical only; superseded by the current approved cleanup evidence |
| Manual acceptance | `MANUAL_V5_ACCEPTANCE.md` remains `NOT_RUN` | BLOCKED / fail-closed |

The archived, provenance-invalid package manifest is
`Release-1.0.0-local-provenance-invalid-build-inputs-20260827T142210Z/manifest-v1.0.json`, SHA-256
`f52b4375457fdb2c85a25c39b40999759130413d918cee110695479179ebda83`.
It honestly records `signature_class=ad_hoc_local`, `developer_id=false`,
`notarized=false`, and a `rejected_or_unavailable` `spctl` disposition.  It
does not imply build provenance, Developer ID, notarization, Gatekeeper
acceptance, cross-Mac install, a real user-library migration, or manual
physics validation.

## Historical and preparatory automated evidence

| Gate | Current evidence | Disposition |
| --- | --- | --- |
| SwiftPM warnings-as-errors build | `swift build -Xswiftc -warnings-as-errors` exited 0 on 2026-08-26 | PASS (source build) |
| SwiftPM contract suite | `swift test` executed **123**, passed **121**, failed **0**, skipped **2** on 2026-08-27.  The skips are the actual disk benchmark and the user-authorized migration drill. | PASS for the normal host-free loop; not a final aggregate |
| Earlier bounded v5 verifier | `LATTICELENS_V5_XCODE_TIMEOUT_SECONDS=60 LATTICELENS_V5_XCRESULT_TIMEOUT_SECONDS=30 zsh Scripts/verify_v5.sh --local-only` completed on 2026-08-26; ledger: `validation-v5-20260826T084736Z-81959.json`. | Historical diagnostic only: the 60-second cold-build limit was too short for current universal Debug/Release builds; it remains fail-closed for migration/package/cleanup/UI |
| Current Xcode build/analyze | `validation-v5-xcode-g2-20260827T031500Z.json`: Debug build, Release build and analyze passed. | PASS for the recorded Xcode build/analyze scope |
| Current Xcode unit execution | `validation-v5-xcode-unit-two-stage-20260827T084956+0800.json`: `LatticeLens-Unit` used a fresh arm64 xctestrun followed by `test-without-building`; the readable current result is 123 total / 121 passed / 0 failed / 2 explicit opt-in skips. | PASS for current Xcode unit scope; it is not UI evidence |
| Legacy disk SwiftData benchmark | `LATTICELENS_RUN_V4_BENCHMARK=1 swift test --filter V4BenchmarkTests/testActualSwiftDataLargeStoreBenchmark` exited 0 in 107.647 s.  Dataset: 2,000 authors, 20,000 papers, 100,000 links, 10,000 chunks. | Historical V6/V7 compatibility evidence only; it cannot establish the subsequently added V9 final search path |
| Legacy benchmark thresholds | `benchmark-v5-local-20260826T162300Z.json`, SHA-256 `a67a9980c2b31a80bfb9fcb4e6faa9d0086642a56539589c0d7a05930521b8aa`: disk cold-open p95 39 ms; disk warm-search p95 49 ms; disk single-row mutation p95 3 ms; V7 active-domain warm-search p95 49 ms; V7 active-domain single-row mutation p95 10 ms. | Historical compatibility metrics only |
| Authorized disposable V7 migration / backup / recovery | `Scripts/migration_v7_disposable_drill.sh` ran against the user-authorized synthetic source and fresh `DisposableMigrationFinalDrillOutput-20260826T154715Z/`. Evidence SHA-256 `f7d729758396e2df1c466a34c1916bf6dbf339bdb77d4b60ef23c66aff897635`; source family bytes remained identical; backup manifest is schema 7 / `sqlite_store_family`; journal is `activated`; pre/post semantic summaries match: 2,000 authors, 20,000 papers, 100,000 links, 10,000 chunks. | PASS for synthetic disposable migration, backup and recovery mechanics; not evidence for a real user library or manual app/data rollback |
| AppIcon source / catalog / resource build | Root `AppIcon-master.svg`, root 16/32/128/512 contact sheet, deterministic render script and macOS catalog are present. `AppIcon-validation-v1.0.json` records PNG pixel sizes, alpha and hashes. A fresh isolated Release build reported `BUILD SUCCEEDED`, produced `AppIcon.icns` (86,565 bytes; SHA-256 `c8ab41a824d9d51d214033c0ec080208c499f63a469a182fbca688bf460b2661`), `1.0.0 (100)`, and `x86_64 arm64`. | PASS for current source/resource build only; mounted-DMG Finder/Dock verification remains pending |
| V8 typed core / V9 search contracts | Current source includes staged V7→V8 byte-stability, crash/recovery, backup/sidecar verification, V9 durable incremental-token update and V9 Bundle restore contracts. | Source change awaiting a new full-suite result |
| Physics truth table | Current suite includes direct, inference, cross-paper double-anchor, missing, and caveat no-fabricated-evidence tests, plus numeric corpus and quarantined/stale checks. | PASS for local validator contract |
| Radar / Compare / Notebook / Bundle | The v5 verifier now binds these gates to named current XCTest cases for semantic diff/dedup/durable pause, atomic rejected matrix retention, exact selection/multi-anchor/import, and typed staging restore. | PASS for host-free contract scope |

## Historical host UI XCTest failure and recovery (superseded by the latest full suites)

The earlier 60-second verifier was unsuitable for clean universal builds:
current Debug and Release builds now pass, and the current readable unit
result is `Passed` with 121 total / 119 passed / 0 failed / 2 explicit opt-in
skips. The retained current evidence is
`validation-v5-xcode-host-20260826T103220Z.json`; it was generated from a
new project-local DerivedData root and does not reuse historical `.xcresult`.

At that point, the normal fixture UI invocation remained fail-closed.  The GUI run of
`testFixtureGlobalSearchAndSmartFilterAreAccessibleControls()` did not begin a
test case and reported:

```text
The test runner failed to initialize for UI testing.
Underlying Error: Timed out while enabling automation mode.
```

The official `xcodebuild -checkFirstLaunchStatus`, `xcodebuild -runFirstLaunch`,
and post-repair check all exited 0.  GUI inspection shows
Xcode enabled in both Developer Tools and Accessibility; no Automation prompt
or pending Xcode row was present.  Crucially, a newly generated macOS App
project with Xcode's own `XCTest for Unit and UI Tests` template reproduced
the identical pre-method failure.  The temporary probe project was closed and
deleted.  `validation-v5-xcode-host-20260826T161251Z.json` records both
readable result summaries.

That diagnostic proves neither a product UI pass nor a LatticeLens case
failure.  It is retained as historical evidence of a pre-method Xcode/XCUITest
host failure; it is no longer asserted to be the current state.

Before the later complete command-line execution, the graphical Xcode Test navigator ran
`LatticeLensUITests.testFixtureResearchHomeUsesLocalSnapshotCounts()` through
the `LatticeLens-UIFixture` scheme to **Passed** and then displayed `Test
Completed`, without a Developer Tools, automation, debugger, or component
repair prompt.  This is current runtime evidence for one process-local fixture
case only.  It does not execute or prove the complete normal fixture suite,
the large-fixture suite, VoiceOver, or the manual three-size acceptance; both
`ui_normal` and `ui_large_scroll_accessibility` therefore remain
**FAIL-CLOSED**.  No historical UI result has been substituted.

A subsequent pre-repair fresh arm64 command-line two-stage normal invocation produced an
`LatticeLens-UIFixture` xctestrun, then failed in `test-without-building`
before any `LatticeLensUITests` method entered.  Its readable result reports
0 passed / 1 runner-level failed / 0 skipped, with `Timed out while enabling
automation mode`; see
`validation-v5-ui-normal-cli-two-stage-20260827T090509+0800.json`.  The
project-local fixture-store root was newly created for that attempt and was
removed afterwards.  This establishes a current GUI-versus-CLI XCUITest-host
discrepancy, not a product-case failure.  The large CLI run was not repeated
because it would exercise the same failed host boundary.

The UI project configuration itself is not missing: a fresh `build-for-testing`
produced an `.xctestrun` entry marked `IsUITestBundle=true` with
`UITargetAppPath=__TESTROOT__/Debug/LatticeLens.app`; all 26 source UI test
methods, including normal/large fixture cases, were present as compiled bundle
symbols. That is static configuration evidence only, not a replacement for a
current executed UI result.

## Product changes covered by the current source suite

- `PhysicsCellStatus.caveat` now represents a non-factual caveat without a
  fabricated anchor, while a caveat carrying a numeric claim must have a
  same-paper value-and-unit anchor.  The Compare matrix, editor and
  accessibility value expose the status explicitly.
- `V4StoreBackupManifest` exports a source-path category rather than a private
  absolute path, while safely redacting old manifests during re-encoding.
- The V7 disposable migration script rejects unsafe path forms, source/output
  overlap, non-empty output roots and symlinks before it invokes the staged
  migration test.
- The DMG packaging and smoke scripts remain pre-promotion-only: universal
  architecture, dSYM UUID, ad-hoc signing, read-only mount, icon/version and
  project-local fixture launch are checked only after all pre-package gates
  are true. `verify_v5.sh` now writes an ephemeral
  `latticelens-prepackage-v5` receipt before invoking the packager; both sides
  serialize the same sorted complete build-input tree and the packager rejects
  any source drift before building. The independent smoke now rechecks the
  package schema, DMG, dSYM ZIP and `SHA256SUMS.txt`. A deliberately false
  all-green prepackage receipt was rejected with exit 65 at the source-drift
  boundary and left neither `Release-1.0.0-local/` nor task-owned package
  scratch behind. This is a fail-closed script-contract check, **not** DMG
  production evidence.
- The final verifier no longer treats a pre-existing cleanup dry-run as an
  approval. It invokes the restricted project-local cleanup applicator only
  after a reviewed `approved_apply` manifest is supplied, validates its
  applied receipt and records its SHA-256 and deleted-byte total. In the
  absence of that explicit receipt it remains nonzero/fail-closed; no approval
  or manual PASS has been synthesized.

## Verifier remediation after the package-chain audit

- The benchmark-backed SwiftPM suite now explicitly removes all three
  disposable-migration environment variables before it runs.  It therefore
  retains exactly the one named migration opt-in skip; the separately audited
  helper alone receives the user-authorized V7 source/output paths.  The
  current formatter records that skip as `Test Case … skipped`; the verifier
  now parses that concrete XCTest record rather than an obsolete text format.
- `current_xcresult_is_readable` no longer uses zsh's special `path` name, so
  its `jq` parse cannot lose `$PATH`.  The Xcode unit gate now performs a
  fresh `build-for-testing` followed by `test-without-building` on the emitted
  arm64 `.xctestrun`; it requires a readable result with zero failures and
  exactly the two named opt-in skips.  Normal and large UI gates now each use
  their own fixture-scheme `build-for-testing` and `test-without-building`
  action, and require zero UI skips.  Xcode and UI timeouts remain
  independently bounded at 600 s and 900 s; invalid timeout input exits 66.
  These are verifier reliability fixes.  The later complete 21-case normal
  and 5-case large result bundles are recorded in the latest-candidate table.
- During the post-fix diagnostic run, the benchmark-backed SwiftPM suite,
  SwiftPM Release build, and clean-DerivedData Xcode Debug/Release/analyze
  gates completed successfully.  The manually chosen 180 s diagnostic cap
  interrupted Xcode unit compilation before test execution; it is explicitly
  **not** unit-test failure evidence and is not promoted.  The later full run
  used the default 600 s Xcode / 900 s UI limits and retained readable
  nonempty result bundles.

## Mandatory work still open

1. Rerun the complete automatic verifier after this tracked-document update
   and create the package on whose mounted DMG the manual observations will
   be performed.
2. Complete the VoiceOver script, 820×640 / 1120×700 / 1440×900 manual
   acceptance, and the three sanitized LQCD-paper rubric.  These must label
   direct evidence, inference and missing evidence separately.  Record them
   in `MANUAL_V5_ACCEPTANCE.md` only after the new package manifest SHA-256 is
   available; it currently remains `NOT_RUN`.
3. Manually test that mounted candidate DMG under the user-selected
   `/Applications` retain/replace/cancel choice, no-network product flow,
   uninstall boundary and disposable app/data rollback.  Bind those observed
   results to the package-manifest SHA-256 in the acceptance receipt.
4. Rerun the verifier after all hashed-source changes and after both receipts
   are available; it must retain current result bundles, current final hashes,
   and zero failures before the final name can be used.

The archived provenance-invalid release must not be described as
`Reference_manager 1.0 final` or used for manual acceptance. The current
candidate is an ad-hoc same-Mac local artifact only until its current package,
manual receipt and final verifier jointly pass.
