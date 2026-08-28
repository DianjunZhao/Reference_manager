# LatticeLens 1.0.0 — v5 manual acceptance record

Status: **NOT_RUN**.  This is a fail-closed worksheet, not a release
declaration.  Fill a field only from the current same-Mac run identified
below; a historical `.xcresult`, a host-free test, or an implementation
inspection is not a substitute for the required manual observation.

## Run identity and safety boundary

| Field | Required value | Recorded value |
| --- | --- | --- |
| Date/time and operator | Local time and the person who performed the observation | `NOT_RUN` |
| Current v5 validation | Path, SHA-256 and run ID with every automatic prepackage gate `true` | `NOT_RUN` |
| App artifact | DMG/app manifest path, SHA-256, version `1.0.0`, build `100` | `NOT_RUN` |
| Fixture mode | Current fixture UI result first asserts `fixtureModeIndicator`; large cases also assert `largeFixtureModeIndicator` | `NOT_RUN` |
| Disposable migration source | User-supplied V7 store-family path category only; never record a private active-library path | `NOT_RUN` |
| Safety | Confirm no active Application Support library, Keychain secret, live INSPIRE, or live LLM was read or changed | `NOT_RUN` |

If any row is unavailable, conflicting, malformed, or not current, the
manual verdict is **FAIL-CLOSED**.

## Machine-readable handoff after manual observation

The worksheet above remains the human-readable source of observations.  After
all required rows have been independently observed as `PASS`, the operator may
create a separate, project-local JSON receipt for the final verifier.  It must
not be generated before the observation and must bind to the SHA-256 of the
specific `Release-1.0.0-local/manifest-v1.0.json` that was mounted:

```json
{
  "schema_version": "latticelens-manual-acceptance-v5",
  "package_manifest_sha256": "<64 lowercase hex>",
  "mandatory": {
    "voiceover": true,
    "lqcd_rubric": true,
    "applications_install": true,
    "disposable_library_drill": true
  },
  "applications_installation_choice": "preserved_and_renamed_old_app | replaced_after_verified_backup | no_old_app"
}
```

Pass its project-local path explicitly as
`LATTICELENS_V5_MANUAL_ACCEPTANCE_JSON` to `verify_v5.sh`.  This JSON is an
attestation pointer, not a substitute for the filled worksheet, current
`.xcresult`, mounted-DMG observation, or user-approved cleanup receipt.

## VoiceOver and accessibility inspection

Run the current built app in fixture mode.  VoiceOver/Accessibility Inspector
must expose a usable label/value/action for each item; status must not be
conveyed by color alone.  Record the result, the concrete screen/action, and
the issue ID or `none`.

| Required observation | Result (`PASS` / `FAIL` / `NOT_RUN`) | Evidence / issue |
| --- | --- | --- |
| Pinned self author, author selection and paper selection have stable names and values | `NOT_RUN` | `NOT_RUN` |
| Paper-Lens tabs and read/favorite/sync state are announced | `NOT_RUN` | `NOT_RUN` |
| PDF page and evidence anchor source/status are announced | `NOT_RUN` | `NOT_RUN` |
| Compare cell states distinguish `direct`, `inference`, `cross_paper_inference`, `missing`, and `caveat` | `NOT_RUN` | `NOT_RUN` |
| Sticky destructive/apply/send/save actions remain reachable in long sheets | `NOT_RUN` | `NOT_RUN` |
| Preflight totals, validation errors, backup/recovery and rollback messages are announced | `NOT_RUN` | `NOT_RUN` |
| Accessibility Inspector finds no missing primary labels and no color-only primary status | `NOT_RUN` | `NOT_RUN` |

## Window, keyboard, and long-list acceptance

Perform each observation at 820×640, 1120×700, and 1440×900.  Verify native
scroll regions/scrollbars, keyboard focus and durable-ID selection before and
after scrolling or filtering.

| Requirement | 820×640 | 1120×700 | 1440×900 | Evidence / issue |
| --- | --- | --- | --- | --- |
| Authors 300+ scroll/search/Z selection and preserved selection | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |
| Papers 500+ filter/first/last and preserved selection | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |
| Tags/collections, models/terminology, jobs/errors and Radar lists stay reachable | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |
| Compare chooser/workspace/matrix and Notebook/conflict regions scroll independently | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |
| `PageUp`/`PageDown`/`Home`/`End`/`Tab`/`Space`/`Escape`/`Return` act on the focused region | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |
| Relaunch isolated temporary fixture store; CRUD/ack/workspace/note/annotation state is durable | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |

## Sanitized LQCD fixture-paper rubric

Choose three sanitized fixture papers.  For every populated field, record
the paper-local title/abstract/caption/PDF anchor and classify it as
`direct`, `inference`, or `missing`.  A plausible value without an anchor is
not direct evidence.  Do not record a numerical value, ensemble, convention,
or scheme in this worksheet unless it was actually observed in the current
fixture run.

| Field | Paper A | Paper B | Paper C |
| --- | --- | --- | --- |
| Fixture paper identity and current anchor hash | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |
| Lattice action | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |
| Ensemble | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |
| Lattice spacing `a` | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |
| Volume `L^3 × T` | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |
| Pion mass `m_π` | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |
| Momentum convention/value | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |
| Source–sink separation | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |
| Operator and Euclidean/sign convention | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |
| Renormalization scheme and scale | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |
| Fourier convention/normalization | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |
| Perturbative matching | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |
| Statistics, correlations, and systematic uncertainties | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |
| Direct/inference/missing boundary correct in display and export | `NOT_RUN` | `NOT_RUN` | `NOT_RUN` |

## Installed-artifact, migration, and rollback drill

These steps use a user-authorized **disposable** library copy only.  Install
and uninstall must affect the app bundle alone unless a separately reviewed
data action is explicitly chosen.

| Required observation | Result (`PASS` / `FAIL` / `NOT_RUN`) | Evidence / issue |
| --- | --- | --- |
| Mounted DMG shows LatticeLens icon/version/build and ad-hoc local boundary | `NOT_RUN` | `NOT_RUN` |
| Copy to `/Applications` preserves a pre-existing app until the user chooses replacement | `NOT_RUN` | `NOT_RUN` |
| Actual `/Applications` choice | `NOT_RUN` | One of `preserved_and_renamed_old_app`, `replaced_after_verified_backup`, or `no_old_app`; never leave a placeholder |
| No-network browse/search/note/PDF/Compare/Notebook/Bundle works against the disposable fixture | `NOT_RUN` | `NOT_RUN` |
| Quit/relaunch preserves expected disposable state | `NOT_RUN` | `NOT_RUN` |
| V7→V8 migration backup/semantic verification/recovery/rollback evidence matches manifest hashes | `NOT_RUN` | `NOT_RUN` |
| Old app is not pointed at a V8/half-migrated store; restore targets a new explicit location | `NOT_RUN` | `NOT_RUN` |
| Default uninstall removes only app; libraries/PDFs/Keychain remain intact | `NOT_RUN` | `NOT_RUN` |

## Final manual verdict

| Condition | Value |
| --- | --- |
| All required rows are independently evidenced `PASS` | `NOT_RUN` |
| Any `FAIL`, `NOT_RUN`, missing provenance, or unaudited cleanup target remains | `NOT_RUN` |
| Manual verdict | **NOT_RUN / FAIL-CLOSED** |

Only after this record, the current automatic machine summary, the disposable
migration evidence, and the user-approved cleanup whitelist all pass may the
project be named `LatticeLens 1.0.0 / Reference_manager 1.0 final`.
