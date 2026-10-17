# Changelog

This file records implementation changes and is not a release certification.
The rolling 2.0 development ledger is `VALIDATION_2.0.md`; the latest unified
local receipt is `VALIDATION_2.0_FINAL.md`. Historical 1.0 verifier results do
not certify the current source tree.

## Unreleased — Reference_manager 2.0 / v5 in progress

- 2026-10-18 exact-cap author-index recovery (Build 205): a partition is now
  split as soon as `hits.total` reaches 10,000, including when a service or
  proxy omits `links.next` at the paging boundary. Parent probe rows are not
  staged, adjacent child ranges remain resumable, and pagination identity
  advances to revision 6 so Build 204 checkpoints restart under the corrected
  boundary rule. This closes the exact-cap/no-next-link case that the previous
  Build 204 regression suite did not cover.

- 2026-10-18 saturated author-index window fix (Build 204): a page-41 link
  now triggers recursive control-number partitioning even when INSPIRE caps
  `hits.total` at 10,000 or omits `size` from the link. The parent probe rows
  are discarded, sibling work remains in the checkpoint, and pagination
  identity advances to revision 5 so an older incomplete generation is not
  resumed under the repaired contract. The packager and verifier now derive
  version/build identity from the Xcode project and reject inconsistent app
  bundle settings.

- 2026-10-17 author-index window recovery (Build 203): page-window limits now
  follow the effective request size, so a recovered `size=100` request may
  continue through page 100 while respecting INSPIRE's 10,000-result offset
  cap. Stale out-of-window checkpoints rewind only their validated partition
  to page 1; an overfull partition is then split and resumed through its cursor
  instead of leaving the index permanently paused. Pagination identity advances
  to revision 4, rebuilding older in-flight generations without replacing the
  last completed index. Synthetic tests cover the reported 17,477-result
  page-41 case and encoded stale checkpoints. No live INSPIRE or real-library
  migration is claimed by these fixtures.

- 2026-10-17 author-index recovery: control-number ranges reporting more than
  INSPIRE's 10,000-result paging window are recursively divided into adjacent,
  disjoint child ranges. The split probe page is discarded, remaining work is
  carried in a validated checkpoint cursor, and open-ended tail ranges advance
  through finite windows. Pagination identity is now revision 3; a 512-page
  foreground budget pauses with a resumable checkpoint instead of making a
  completed-page safety cap permanent. Synthetic regression tests cover the
  17,477-result case, cursor serialization/resume, open-tail splitting, and
  preservation of the last completed author generation. No live INSPIRE or
  full UI acceptance is claimed by these fixtures.

- 2026-10-07 G02 store-path compatibility: fresh production libraries now use
  `Library-v12.store`, separate from the direct-open `Library-v8.store` path
  used by 1.0.11. Existing V8 stores, V11/V12 descriptors, and V7 candidates
  still select the verified migration base; established V12 data takes
  precedence over a later V8 file. A prior V12 database found at the retired
  V8 path is re-staged through the verified V12 descriptor flow, with a
  synthetic regression checking that the source SQLite family remains byte-
  identical. Full SwiftPM and Xcode Unit runs passed with six opt-in skips;
  older-app destruction was probed only on a disposable clone, and app-plus-
  data rollback, XCUITest, VoiceOver, and the final release gates remain open.
  See `evidence/Continuation-20261007-G02-StorePath.md`.

- 2026-10-05 V12 formula provenance: the default store factory now stages
  supported V8/V9/V10/V11 stores toward V12, whose typed rows preserve
  append-only formula derivation segments and their structured steps. Typed
  Research Bundle schema 7 carries those rows while older schema 6 and schema
  5 imports remain supported. The V12 disk benchmark fixture now uses the
  exact same conclusion in its claim and segment receipt; a prior run-specific
  verifier receipt is retained as pre-fix history and must not be reused for
  the corrected source. The focused benchmark alone is diagnostic, not a
  manifest-bound release or physics result; consult a fresh run-specific local
  receipt for current acceptance. The bounded disposable HFS+ ENOSPC drill
  also passes after updating its V12 journal-name expectation; the exact
  source-bound log records rollback with an unchanged source SQLite family.

- 2026-10-04 Category-facet acceptance follow-up: the author sidebar's
  `all-enabled` projection now uses only the configured category set; a
  qualified historical author from disabled `hep-th` remains available via
  its explicit facet instead of leaking into enabled counts. The large UI
  fixture now contains five deterministic category compositions (300 ordinary
  authors and 1,000 papers across `hep-lat`, `hep-ph`, multi-category,
  `hep-th`, and `hep-ph` + `hep-th`) with exact seed/reopen assertions. The
  targeted Swift matcher and disk-seed tests passed, and the UIFixture target
  built for testing; no XCUITest case execution or live INSPIRE coverage is
  claimed by this entry.

- 2026-10-03 Disk-backed large UI fixture: added an explicit relaunch-only
  SwiftData fixture mode whose store must be a distinct child of the project-
  local test root. A completed synthetic corpus is reopened without reseeding;
  empty stores are seeded, while partial/unknown/read-error stores fail closed.
  The UI exposes the exact fixture root and has a note-save/quit/relaunch test
  definition. This code/test addition does not claim an XCUITest execution,
  VoiceOver acceptance, or installed-app rollback.

- 2026-10-03 Local candidate packaging guardrails: the packager now accepts
  standard `--help`, rejects output paths with symlinked/out-of-project
  ancestors, and strips every inherited `LATTICELENS_*` variable before setting
  its own build or fixture-launch environment. A real packaging run showed
  that this host's `lipo -verify_arch` accepts one architecture per invocation;
  the packager now verifies arm64 and x86_64 separately. Four Python
  contract tests cover those boundaries and are registered in the final local
  verifier; their temporary symlink fixture is created and removed inside the
  project. This is package tooling coverage, not a final-release or
  interactive-install claim.

- 2026-10-03 V10 migration fixture teardown: explicitly drain the source
  `ModelContainer` autorelease pool before taking byte snapshots of its SQLite
  main/WAL/SHM family. The strict byte-equality checks remain intact; the full
  project-local SwiftPM suite then passed 248 cases with 0 failures and 5
  allowlisted skips. This is test-fixture determinism, not a production-store
  migration receipt.

- 2026-10-03 Test-root isolation follow-up: replaced assertions about
  `FileManager.default.temporaryDirectory` with checks on explicit verifier-owned
  roots, since setting `TMPDIR` alone does not control Foundation/XCTest's
  resolved temporary directory on this host. Fixture persistence and full-text
  cache fallbacks now fail closed when required project-local roots are absent;
  verifier children also discard inherited production-store isolation opt-ins.
  Contract tests, the full SwiftPM suite, and Unit/UIFixture `build-for-testing`
  passed locally. The Xcode test runners remain a separate gate and this edit
  does not claim they executed test cases.

- 2026-10-02 F06 ready-to-publish follow-up: completed evidence-insight
  artifacts are now saved to the existing V10 `AnalysisRun` table before the
  final library write, with a non-secret cache/source/inventory/provider-profile
  context and payload hash. A failed final save can be resumed without a second
  provider request; mismatched context fails closed. Schema-6 Research Bundles
  round-trip pending publications and still decode older state files that omit
  the additive field. The local full suite passed (233 tests, 5 opt-in skips),
  the warnings-as-errors SwiftPM Release build passed, and both verifier
  contract tests passed. This continuation does not refresh the unified G01–G10
  receipt or certify live services, manual UI/physics review, packaging,
  installation, rollback, or a 2.0 release; see
  `evidence/Continuation-F06-ready-publication-20261002.md`.

- 2026-10-02 G07 Bundle-cancellation follow-up: schema-5 and schema-6 typed
  restores now check cooperative task cancellation before staging and at the
  materialization, index, and semantic-verification boundaries. A cancelled
  import follows the existing exact-target SQLite-family cleanup path. Added a
  failing-first regression proving that pre-cancelled restore leaves the
  target absent and the source Bundle intact. The current local suite and
  warnings-as-errors SwiftPM Release build pass; this does not certify every
  mid-stage failure point, the full G07 rollback matrix, or a 2.0 release.
  See `evidence/Continuation-G07-bundle-cancel-20261002.md`.

- Set the development target to **2.0.0 (200)** without promoting it to a
  release. Added the configurable `hep-lat` / `hep-ph` / compatible `hep-th`
  category profile and category-aware author indexing, typed V10 category and
  formula-job persistence, and a bounded, checkpointed numbered-formula
  derivation workflow. Fresh service/client defaults now use hep-lat + hep-ph;
  the hep-lat + hep-th profile remains explicit for legacy checkpoints. Formula
  job identity binds a non-secret provider/model/settings fingerprint, complete
  checkpoints are revalidated and reused without another POST, and this-run
  request counts exclude reused batches. V10 formula batch/step rows now update
  by stable ID instead of being deleted and recreated on each checkpoint save.
  Added failing-first regression coverage. Numbered formulas now require typed
  steps with stable identity/order, current document hashes, current evidence
  anchors, and checked equation dependencies; a bounded TeX syntax subset gets
  a structural status, while unknown macros remain manual and physics review
  cannot be self-promoted. Legacy string steps remain readable but cannot
  satisfy the new contract. Full TeX/units/physics validation, typed-row source
  of truth, staging migration, unbounded recid coverage, UI/manual gates,
  complete Bundle 2.0, and 2.0 packaging remain incomplete. The separate V10
  disk-benchmark implementation and manifest-bound verifier stage are local
  synthetic evidence only; the current threshold verdict belongs to a fresh
  `VALIDATION_2.0_FINAL.md` receipt. This entry is not release evidence.

- 2026-10-02 F07 continuation: added an additive V11 schema and moved durable
  formula-job reads/writes to stable V11 job, claim, and structured-step rows.
  V10 remains unchanged; its checkpoint payload is used only to seed missing
  V11 rows during legacy backfill and is not rewritten by later checkpoints.
  Bundle export reads canonical V11 rows. Regressions cover damaged legacy
  projections, claim-hash tampering, staged V10-to-V11 upgrade/source-byte
  preservation, and Bundle round-trip. The current full SwiftPM suite and
  warnings-as-errors SwiftPM/Xcode Release builds pass locally. This focused
  continuation also moves the final performance stage to V11 and requires it
  to read eight typed claims and eight structured steps from each measured
  formula job. Its manifest-bound synthetic disk receipt passed independent
  validation: p95 cold reopen/search/read/favorite/note were 9/77/2/2/14 ms,
  typed inventory/job reads were 105/12 ms, and job checkpoint commit was 15 ms.
  The report records the 20k-paper/5k-formula dataset and 1.97 GiB process RSS
  high-water including synthetic setup; these are host-specific synthetic
  measurements, not physical correctness or a general performance guarantee.
  The focused evidence does not refresh the unified G01-G10 receipt or certify
  a release; see `evidence/Continuation-F07-typed-store-20261002.md`.

- Added a dedicated V10 disk-performance fixture through the production
  library/formula repositories: 20,000 papers, 100,000 links, 10,000 evidence
  chunks, 500 Radar events, and 5,000 formulas across 20 source-bound
  inventories. It records 20 fresh-container reopen samples, 100-sample warm
  search and read/favorite/note mutations, formula reads/checkpoint commits,
  batch planning/coverage validation, storage bytes and process RSS. The final
  verifier checks raw samples, thresholds, workload cardinalities and the
  frozen input-manifest hash. Synthetic coverage is not a physics review.

- 1.0.11 (111): replace subjective “important formula” selection with an
  ar5iv-only all-numbered-equations contract. The local extractor records one
  hash-bound TeX/evidence item for every labelled display equation, including
  equation-group rows; the prompt (`paper-insight-prompt-v10`) and validator
  require a one-to-one, source-TeX-preserving, anchored direct derivation for
  every item and canonicalize display order to the paper's own ordering. Old
  cached ar5iv HTML is re-indexed locally before any Keychain/provider access.
  A visible numbered tag without a recoverable TeX/evidence record, a payload
  or 256-equation bound, PDF fallback, missing/duplicate/unknown formula, or
  modified TeX is fail-closed: no partial artifact is saved or labelled as
  complete. This changes the evidence schema, prompt/cache version and V8
  persisted indexed-document metadata; it is not a live-provider claim.

- 1.0.10 (110): replace the formula-derivation segment VStack with one offline
  KaTeX/WebKit reader. Inline mathematics stays inside sentences; structured
  formula fields and display delimiters use consistent display math. Recognize
  conservative bare TeX runs without changing the cached source. Use numbered
  steps, consistent spacing and one collapsed raw-source disclosure per card.
  A permanent native vertical scrollbar, per-equation horizontal scrollbars
  and an expanded reading sheet keep long derivations accessible. Full-text
  controls remain in a separate scrolling source sheet after generation.
  Narrow-window filter/tab menus keep the reader inside the window. Preserve the
  claim's actual epistemic status instead of labelling all formulas direct.
  No schema, prompt, provider, persistence or evidence-boundary change.

- Promoted the current local candidate to **1.0.9 (109)**. Evidence v2 now
  repairs exactly one JSON syntax defect that is unambiguous at the grammar
  boundary: an omitted separator between two completed strings, or two
  completed objects, inside the same array. The repair neither creates nor
  edits reader-facing text, evidence IDs, anchors, formula fields, object
  members, numbers, escapes, or provenance. A malformed object, an incomplete
  string, malformed Unicode escape, unsupported value type, unknown key, and
  every post-parse evidence check remain fail-closed. The
  `paper-insight-prompt-v9` cache key prevents reuse of v8 output.

- Promoted the current local candidate to **1.0.8 (108)**. When a provider
  supplies a structurally valid `direct` or `inference` item but gives no
  evidence ID, or an ID outside the current bounded payload, the app now
  drops that exact unprovable item rather than inventing an anchor or failing
  an independently anchored formula derivation. The original text is never
  persisted; a generic `missing` notice records the omission. Malformed JSON,
  malformed/duplicate IDs, wrong section statuses, `missing` claims carrying
  IDs, and numeric claims not recoverable from their valid anchors still fail
  closed. The `paper-insight-prompt-v8` cache key prevents reuse of v7 output.

- Promoted the current local candidate to **1.0.7 (107)**.  Evidence v2 now
  binds a full-text anchor's coordinate rule to the actual document
  representation: ar5iv HTML excerpts have `page: null` and must exactly match
  the current payload's paper, document hash, anchor ID, quote and quote hash,
  plus its extracted section; INSPIRE/arXiv PDF excerpts still require the
  original page equality.  The prompt/cache key is `paper-insight-prompt-v7`,
  so a v6 artifact cannot be reused under this contract.  No cross-document or
  unanchored evidence is accepted.

- Promoted the current local candidate to **1.0.5 (105)**. Evidence v2 now
  deterministically repairs only a bare TeX command marker written inside a
  model JSON string (for example an unescaped `\\alpha`) before the existing
  strict duplicate-key grammar walk. Valid JSON escapes remain byte-identical;
  malformed unicode escapes still fail, and the schema, source scope, anchor,
  numeric-provenance, response-size and evidence-boundary checks are unchanged.
  The versioned prompt also requires valid JSON backslash serialisation.

- Promoted the current local candidate to **1.0.4 (104)**.  Evidence analysis
  now accepts `abstract_zh: ""` only as an explicit sentinel when the supplied
  source has no abstract; missing, `null`, whitespace-only, overlong, or
  otherwise non-string abstracts remain rejected.  The versioned Evidence
  prompt directs the model to preserve a frozen translation when present and
  never to invent an abstract from full-text chunks.  This resolves the
  previous `abstract_zh` nonempty-schema false rejection without weakening
  source scope, anchor, numeric-provenance, or duplicate-key validation.

- Promoted the current local candidate to **1.0.3 (103)**.  Evidence, model
  discovery, and the Settings connection probe now turn macOS TLS trust and
  negotiation failures into a Chinese, host-and-port-only diagnosis.  It
  confirms that the app did not automatically resubmit the full-text evidence
  and directs the user to the non-disclosing Settings connection check.  This
  retains HTTPS-only endpoint policy and normal macOS certificate validation;
  it neither trusts arbitrary certificates nor falls back to HTTP.

- Promoted the current local candidate to **1.0.2 (102)** so the Finder-visible
  installed version cannot be confused with the prior 1.0.1 package.

- Evidence now accepts a complete `paper-insight-v2` object carrying harmless
  OpenAI-compatible root metadata, or one conventional `data`/`result`/`output`
  envelope. Such transport fields are stripped and never persisted. Required
  schema fields, duplicate-key rejection, source scopes, anchor allowlists and
  numeric provenance checks remain fail-closed; the prompt now declares the
  complete required response shape explicitly.

- Historical 1.0 behavior: Evidence formula derivations had no
  application-imposed connection, first-content, idle, or total timeout. This
  behavior is superseded in 2.0 by finite per-request deadlines and a
  multi-request job with no aggregate wall-clock deadline.

- Made the deterministic ar5iv HTML link the preferred Evidence source for
  records with an arXiv identifier, independent of INSPIRE PDF coverage. The
  URL is shown directly and can be opened without a local download; reading it
  into the app-owned cache still requires explicit confirmation. Extracted
  MathML TeX annotations become real `$…$` math delimiters and feed bounded
  formula derivations. Existing INSPIRE/arXiv PDF downloads remain an explicit
  fallback.

- Fixed author-index pagination after a bounded HTTP 400 recovery: when the
  service accepts a smaller page size, the durable next URL now keeps that
  effective size instead of reverting to the rejected request on the next
  page. Added a regression covering the resumed page boundary.

- Prepared the local `1.0.1 (101)` candidate so its Finder-visible version
  distinguishes it from the stale `1.0.0 (100)` `/Applications` binary.
  The candidate was mounted and launched with a fresh disposable SwiftData
  root against read-only INSPIRE: it persisted the pinned author, 10 papers,
  and 10 author-paper links before its UI was inspected.
- Hardened the hep-lat/hep-th candidate pagination and `HTTP 400` recovery,
  throttled only the author-sidebar projection rather than durable progress,
  improved MathML/TeX rendering, localized Evidence Workbench labels, and
  centred the INSPIRE toolbar capsule.

- Rebuilt the local 1.0.0 (100) DMG from the current source after fixing the
  refresh-resume path: when candidate pagination is complete but h-index retry
  IDs remain, “继续索引” now reopens the active generation and processes only
  those IDs instead of restarting pagination. The current package passed the
  full SwiftPM suite (145 executed, 0 failures, 2 explicit skips), current
  Xcode normal/large UI gates, and mounted fixture/no-network smoke.

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
