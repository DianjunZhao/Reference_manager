# Changelog

This file records implementation changes. It is not a release certification;
the authoritative 1.0 gate remains `zsh Scripts/verify_v5.sh --local-only`.

## Unreleased — Reference_manager 1.0 / v5 in progress

- Rebuilt the local 1.0.0 (100) DMG from commit `2db81d5`. Author-index
  pagination now repairs persisted page-41 checkpoints, HTTP 400 citation
  summary responses fall back to the auditable local most-cited calculation,
  and independently verified h>20 rows remain visible while a generation is
  interrupted. INSPIRE MathML is normalized in titles/timeline/Paper Lens,
  and the Evidence tab now foregrounds LLM-generated, anchor-bound formula
  derivations. The rebuilt package passed the mounted fixture/no-network
  smoke; UI automation remains host-blocked and is not claimed here.

- Completed a provenance-valid full local automatic candidate on 2026-08-28:
  `validation-v5-20260828T023235Z-134.json` binds all automatic product gates
  to non-empty build-input hash
  `f1458e59d1aa5b3703bff11ec07679ffda1786525ce9994c2540cef163d5a711` and
  to the universal, ad-hoc local `1.0.0 (100)` DMG manifest. This is not a
  final release: VoiceOver/LQCD/install/rollback observations still require a
  user attestation bound to the exact package manifest.
- Applied the user-approved 207-directory project-local cleanup whitelist.
  `CleanupApplyReceipt-v1.0-20260828T030918Z.json` records 40,327,176,192
  deleted bytes; active libraries, Keychain, `/Applications`, package assets
  and every non-whitelisted path remained out of scope.
- Repaired the v5 build-input enumeration and added fail-closed coverage
  requirements for Sources, Tests, Scripts, assets, Xcode project, package and
  release documents. The previous automatic package was preserved under
  `Release-1.0.0-local-provenance-invalid-build-inputs-20260827T142210Z/` after
  its `files:[]` manifest was found to provide no source provenance.
- Added a current structured cleanup dry-run manifest with canonical paths,
  bytes, symlink and `lsof` checks. The verifier now invokes the restricted
  cleanup applicator only after a reviewed `approved_apply` manifest is
  supplied, validates the resulting receipt, and otherwise remains
  fail-closed without deleting anything.
- Added a current full local-only verifier candidate with readable fixture UI
  results (normal 21/21 and large 5/5), synthetic disposable V7 migration,
  universal ad-hoc DMG creation and independent mounted-DMG fixture smoke.
- Corrected the Xcode 26 `lipo` invocation in the DMG packager and independent
  smoke so the executable is supplied before `-verify_arch arm64 x86_64`.
- Package `CHANGELOG.md` with the compact validation material so a mounted
  1.0 local artifact includes its user-facing change record.
- Introduced an atomic typed `PaperSyncPageCommit` boundary. A literature page
  now commits paper/link rows, revision snapshots, semantic Radar events, its
  durable checkpoint, and its sync job event together in the V8 active store.
- Added a disk-backed V8 relaunch regression for that page commit. It verifies
  that the complete durable page write-set is readable after reopening, while
  a V8 activation marker remains migration/initialization-only.
- Replaced production Radar legacy/semantic double writes with one canonical
  field-level semantic pipeline. Its deterministic event identity derives from
  paper, field, kind, and before/after hashes so retries replace rather than
  duplicate the same transition.
- Kept prior v4 release artifacts and evidence as historical records, and
  changed the README status to fail closed until all v5 mandatory gates pass.

## Historical v4

Historical local fixture evidence and artifacts remain in the project for
auditability. They must not be interpreted as a v5 or 1.0 final release.
