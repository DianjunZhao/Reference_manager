# LatticeLens v2 validation ledger

This ledger separates implementation evidence from claims about external services.
It starts as a baseline and is updated only with commands/artifacts produced in
this checkout. `Not run` is not a pass.

| Gate | Scope | Status | Required evidence | Current evidence |
| --- | --- | --- | --- | --- |
| A | Clean SwiftPM + Xcode Debug/Release builds | Passed (local) | exact command, exit status, artifacts | 2026-08-23 current-source refresh: `swift build -c release -Xswiftc -warnings-as-errors` exited 0; an arm64 Xcode Debug build with warnings-as-errors and complete concurrency exited 0 and contained `LatticeLens.app` (`org.latticelens.app`, minimum macOS 14.0); the regenerated generic-macOS Release archive also exited 0. These are local build/package facts only. |
| B | Offline unit/integration contracts | Passed (local) | isolated fixtures and test count | Latest isolated SwiftPM run executed 41 XCTest cases with 0 failures. It includes local PDFKit extraction, app-fixture PDF/evidence generation, v1→v2→v1 rollback, SwiftData reference-manager projection, ETag/304 and HTTP-date retry contracts, h-index cancellation/pause-resume durability, single-record INSPIRE detail mapping, native Markdown/TeX raw-source preservation, BibTeX failure preservation, Vision mock contracts, and fixture Keychain/model-discovery/fulltext/image isolation; it does not make a provider claim. |
| C | Live read-only INSPIRE path | Passed (read-only smoke) | self, nested search pages, facet, pagination ledger | 2026-08-22 HTTPS GETs returned 200 for self `2010363`, hep-lat author search, citation-summary facet, literature page and one BibTeX endpoint. Current `links.next` uses trailing-slash paths; client/test now permit only that endpoint-equivalent form while retaining HTTPS/origin/userinfo/fragment checks. This is a point-in-time API-shape smoke, not complete-index or long-term availability proof. |
| D | Persistence/recovery | Passed (local contracts) | restart, resume, migration, corruption, rollback | JSON restart/backup/corruption/concurrent-upsert; candidate and h-index durable checkpoint resume (including cancellation after one durable h-index outcome and a paused continuation that skips it); real SwiftData V1→V2 migration; retained checksum-backed V1 snapshot restored into an empty V1 rollback target; and normalized V2 rows for reading, notes, links, full text and anchors all pass. This does not prove every unknown historical user database. |
| E | Real macOS UI | Passed (local fixture) | `.app` plus `XCUIApplication` test result | 2026-08-23 current-source `LatticeLensUITests` `.xcresult` reports `totalTestCount=6`, `passedTests=6`, `failedTests=0`, `result=Passed` on arm64 macOS. It covers analysis cancellation/cache/bad-image degradation, author search entry/self pin/paper selection/five tabs, caption-only versus independent Vision disclosure, local full-text anchor jump, reference-manager controls, and settings/key clearing. Every case first observed `fixtureModeIndicator`; its activation now recognizes the actual `-LatticeLensUseFixtures YES` command-line spelling and uses in-memory store, allowlisted fixture transport and process-local Keychain. This is not VoiceOver/manual, live INSPIRE/LLM, real Keychain, signing or release evidence. |
| F | Full-text evidence | Passed (local fixture) | local PDF extraction, anchor/retrieval/claim tests | A local two-page text PDF is served through an isolated HTTPS `URLProtocol`, downloaded explicitly, SHA-256 hashed as original bytes, opened by PDFKit, chunked into page anchors, and then deleted with dependent chunks/artifacts. A `paper-insight-v2` direct numeric claim is validated against its actual page-1 anchor. No provider request occurred. |
| G | Reference manager | Passed (local contracts) | read/tag/collection/note/export persistence tests | SwiftData projection and in-memory tests cover read/favorite/note/tag/collection/search/secret-free Markdown. BibTeX accepts only a bounded, trusted endpoint response with source URL/time; a failed response preserves the previous record. The read-only live smoke received an INSPIRE `@article` response, but did not write any user library. |
| H | Live LLM providers | Not run | separately authorized per-provider records | no provider authority/key supplied |
| I | Local candidate | Blocked | archive/manual accessibility/package manifest | 2026-08-23 current-source archive regenerated at `2026-08-23T14:42:56Z`. The zip SHA-256 is `0ca8ea3b15c1d5ef8ed451c62429a92ec6c42f74884c38dc522d9ccd0e3c26d9`; it contains universal (`x86_64 arm64`) `org.latticelens.app`, minimum macOS 14.0 and productivity category. The 6/6 fixture `XCUIApplication` result now exists, but the artifact remains explicitly unsigned/pre-candidate. VoiceOver/manual, Developer ID, notarization, Gatekeeper and cross-machine evidence remain absent, so this is not a local candidate. |
| J | Public release | Not run | Developer ID, notarization, Gatekeeper/cross-machine | not authorized/not run |

## Baseline integrity

- `INSPIRE文献管理器_开工方案_v1.md` SHA-256: `7d3829e43676950c348880c1a93d0861ea714e90f26a0949b5287d2b4a51d0ad`
- `INSPIRE文献管理器_开工方案_v2.md` SHA-256: `b8113e0d52f8558b1905cdbb984bda8ff6b499f192f9e24b71d9268530ca7603`
- The working directory is intentionally not initialized as a Git repository.
- All test/build scratch output must be below `.codex-task-tmp-v2-*` and deleted after this task.

## Evidence policy

- Offline `URLProtocol`/fixture tests do not demonstrate live INSPIRE or provider behavior.
- Read-only live INSPIRE evidence does not demonstrate provider behavior, signing, notarization, or GUI accessibility.
- Live LLM verification is skipped until the user deliberately configures a provider and confirms the endpoint-specific disclosure in the app.
- This file never contains API keys, complete prompt payloads, or unredacted provider error bodies.

## 2026-08-22 local verifier record

Command: zsh Scripts/verify_v2.sh (exit status 0)

Final JSON line:

{"schema_version":"latticelens-verify-v2","local_only":true,"swiftpm_test":1,"swiftpm_release":1,"xcode_debug":1,"xcode_unit":1,"xcode_release":1,"xcode_analyze":1,"ui_runtime":false,"live_inspire":false,"live_llm":false,"failures":0}

The verifier uses only fixture/test data and project-local scratch directories,
then deletes its own scratch tree. It intentionally does not run UI automation,
PDF network download, live INSPIRE, a provider request, signing, notarization,
or cross-machine installation.

## 2026-08-22 final local verifier record

Command: `zsh Scripts/verify_v2.sh` (exit status 0)

Final JSON line:

```json
{"schema_version":"latticelens-verify-v2","local_only":true,"swiftpm_test":1,"swiftpm_release":1,"xcode_debug":1,"xcode_unit":1,"xcode_release":1,"xcode_analyze":1,"ui_runtime":false,"live_inspire":false,"live_llm":false,"failures":0}
```

The SwiftPM sub-gate executed 28 XCTest cases with 0 failures. `ui_runtime`
remains `false`: a separately attempted ad-hoc-signed `XCUIApplication` run
compiled its target but did not finish; the task-owned runner/app processes
were terminated after the Xcode debugger-version environment error and no
completed test result was produced.

## 2026-08-23 fixture isolation and bounded UI-runtime attempt

The UI fixture activation now resolves at the app dependency boundary and
accepts XCUITest's `-LatticeLensUseFixtures YES` launch default (with the
existing environment signal as a compatible fallback). In fixture mode the
store is `InMemoryLibraryStore`, the HTTP transport is `AppFixtureTransport`,
and the Keychain is a process-local substitute. A unit contract verifies that
this mode does not call an injected persistent Keychain.

Manual AX verification used an unsigned, task-local app with the distinct
bundle identifier `org.latticelens.fixture`, avoiding any collision with a
normal LatticeLens instance. It observed: pinned self author; only the
qualified `Zebra, Zed` (`h(all)=21`) after index construction; self-preserving
author search and clear; fixture paper `1234567`; all five Paper Lens tabs;
the no-PDF Evidence fallback with abstract/caption anchors; and the Settings
Base URL, secure API Key, model discovery, Save and Cancel controls. The
automatic LLM disclosure was explicitly declined, so no provider request or
credential entry occurred. This is AX/manual evidence, not a VoiceOver pass.

`build-for-testing` completed with exit 0. The subsequent bounded
`test-without-building` attempt only created an incomplete `.xcresult/Staging`
tree. Xcode reported a test worker waiting to materialize under
`IDELaunchServicesLauncher` and later `Waiting for -runningDidFinish`; no test
case completed, so `XCUIApplication` remains unpassed. A later verifier run
did complete SwiftPM's 29 XCTest cases, SwiftPM release, Xcode Debug and Xcode
Release, but the same host issue interrupted Xcode unit/analyze. Those two
interrupted sub-gates are not used as success evidence.

## 2026-08-23 local verifier and unsigned archive record

Command: `zsh Scripts/verify_v2.sh` (exit status 0)

Final JSON line:

```json
{"schema_version":"latticelens-verify-v2","local_only":true,"swiftpm_test":1,"swiftpm_release":1,"xcode_debug":1,"xcode_unit":1,"xcode_release":1,"xcode_analyze":1,"ui_runtime":false,"live_inspire":false,"live_llm":false,"failures":0}
```

The current SwiftPM sub-gate executed 30 XCTest cases with 0 failures. The Xcode
sub-gates completed under `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` and
`SWIFT_STRICT_CONCURRENCY=complete`; their `-quiet` output contains Xcode test
framework copy/strip diagnostics, but no compiler error and the verifier
returned 0. This verifies local build/test/analyze only, not a UI runtime.

After adding the fixture-only LLM/model-discovery substitutes, key-clear
control, and automatic-analysis/cancel/cache UI path, a separate
`xcodebuild ... build-for-testing` exited 0 with local ad-hoc signing. Its
`.xctestrun` marks `LatticeLensUITests` as `IsUITestBundle = true` and points
`UITargetAppPath` at `LatticeLens.app`; `codesign --verify --deep --strict`
passed for both the task-local app and UI runner. This is compile/wiring
evidence only: no UI test case was run and no VoiceOver claim follows.

Command: `zsh Scripts/archive_v2_unsigned.sh` (exit status 0)

The script created `Release-v2/` and cleaned its project-local scratch tree.
`manifest-v2.json` records the Release generic-macOS build settings, bundle ID
`org.latticelens.app`, app executable hash, universal architectures, unsigned
signature boundary, and zip SHA-256. A separate check confirmed that the
payload hash equals the manifest, the archive contains `LatticeLens.app`,
`LSApplicationCategoryType` is `public.app-category.productivity`, and the
script refuses to overwrite an existing output. The archive proves packaging
structure only; it does not provide Developer ID, notarization, Gatekeeper,
cross-machine, XCUIApplication, or VoiceOver evidence.

## 2026-08-23 final bounded UI runner and archive refresh

A fresh project-local `build-for-testing` invocation for the real
`LatticeLensUITests` target completed with local ad-hoc signing. Its
`test-without-building` invocation selected exactly
`testFixtureAnalysisCancellationCacheAndFigureDegradation`. Before any case
result was available, Xcode reported
`DebuggerLLDB.DebuggerVersionStore.StoreError` followed by `no debugger
version`. The requested `fixture-analysis.xcresult` was not readable by
`xcrun xcresulttool get test-results summary`: at the observation point its
`Info.plist` was absent. Thus this run establishes neither a pass nor a
failure of the SwiftUI workflow; it establishes only that the host-side runner
did not produce the required result evidence. The task-local app/test/scratch
processes then ended and their scratch tree was deleted.

The previous `Release-v2/` output was removed only after confirming its own
`unsigned_local_pre_candidate` manifest, then
`zsh Scripts/archive_v2_unsigned.sh` regenerated it from the current source.
`manifest-v2.json` records `generated_at_utc` as `2026-08-23T02:54:21Z`.
Direct post-build checks confirmed the payload SHA-256 matches the manifest,
the zip contains `LatticeLens.app`, bundle ID is `org.latticelens.app`,
`LSApplicationCategoryType` is `public.app-category.productivity`, and the
executable architectures are `x86_64 arm64`. `codesign --verify --deep
--strict` remains unsuccessful (`unsigned_or_unverified`), and a second archive
command correctly refused to overwrite the existing output. These are package
structure checks only, not signing, notarization, Gatekeeper, cross-machine,
UI-runtime, or VoiceOver proof.

## 2026-08-23 current-source verification refresh

The isolated command
`LATTICELENS_TEST_STORE_ROOT=<project-local-scratch> swift test --scratch-path <project-local-scratch>`
executed **41 XCTest cases with 0 failures**. The current-source
`swift build -c release -Xswiftc -warnings-as-errors` exited 0 (37.46 s).
An arm64 Xcode Debug build with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`,
`SWIFT_STRICT_CONCURRENCY=complete`, and `CODE_SIGNING_ALLOWED=NO` also exited
0; its task-local product was a `LatticeLens.app` with bundle identifier
`org.latticelens.app` and minimum system version 14.0. All of those scratch
directories were deleted after the checks.

The separate full `LatticeLensUITests` run did not establish GUI success: after
344.910 s, `xcodebuild` exited 65 and reported
`LatticeLensUITests-Runner ... The test runner hung before establishing
connection.` It produced no completed business test case. The build stream also
contained Xcode's framework-copy diagnostic (`command failed with exit code 0`),
but the recorded Gate E blocker is the final runner-hang result, not an inferred
SwiftUI failure. No live service, Keychain, provider, or user library was used.

After confirming the prior `Release-v2` manifest described an unsigned
pre-candidate, that exact task-owned directory was removed and
`zsh Scripts/archive_v2_unsigned.sh` regenerated it from the current source
(exit 0). The refreshed manifest is the current unsigned pre-candidate; its
zip SHA-256 is
`95bb448199e806f8f73c4a11922ef6ae3ff10add9063d1009d71020fb97b4dcc`.
Post-build inspection verified the zip contains `LatticeLens.app`, the bundle
identifier/category are `org.latticelens.app` /
`public.app-category.productivity`, and executable architectures are
`x86_64 arm64`. `codesign --verify --deep --strict` remains unsuccessful, as
expected for this unsigned artifact. This refresh does not verify Developer ID,
notarization, Gatekeeper, cross-machine installation, XCUIApplication, or
VoiceOver.

## 2026-08-23 fixture dependency isolation refresh

The UI fixture dependency graph now injects a process-local full-text
downloader, local PDF generator, Vision image loader, Vision completion, and
full-text evidence completion. Fixture routes accept only their explicit
`fixture.invalid` allowlist; all other URLs fail before a socket can be
created. Figure rendering also uses a deterministic local thumbnail for that
host instead of `AsyncImage`. The fixture activation signal no longer reads
the user's `UserDefaults`; it requires the explicit launch environment or
argument. New contract/integration coverage raises the isolated test count to
41, including PDF extraction plus a validated `paper-insight-v2` response.

This strengthens the no-network UI fixture boundary but does not change Gate E:
the host-side `LatticeLensUITests-Runner` still has no completed
`XCUIApplication` result, and VoiceOver remains unrun.

## 2026-08-23 bounded UI automation retry

A fresh local ad-hoc-signed run selected exactly
`LatticeLensUITests/LatticeLensUITests/testFixtureFullTextScopeAndAnchorJumpStayLocal`,
with parallel testing disabled and an arm64 macOS destination. Build and
signing completed, and Xcode produced a readable `ui.xcresult`; however the
runner failed before any business test case started:
`Timed out while enabling automation mode.` The xcresult summary reports one
failed runner initialization entry, zero passed business cases, and zero
completed UI test cases. This is host-side UI automation/permission or system
service evidence, not a SwiftUI workflow assertion. Gate E remains Partial and
requires a real automation-capable host plus VoiceOver/manual evidence.

## 2026-08-23 complete local verifier and archive refresh

Command: `zsh Scripts/verify_v2.sh` (exit status 0)

Final JSON line:

```json
{"schema_version":"latticelens-verify-v2","local_only":true,"swiftpm_test":1,"swiftpm_release":1,"xcode_debug":1,"xcode_unit":1,"xcode_release":1,"xcode_analyze":1,"ui_runtime":false,"live_inspire":false,"live_llm":false,"failures":0}
```

In the complete macOS/Xcode environment, the verifier executed **41 XCTest
cases with 0 failures** and completed the SwiftPM release, Xcode Debug,
Xcode unit, Xcode Release, and Xcode analyze sub-gates with warnings treated
as errors and strict concurrency enabled. The Xcode unit build stream emitted
the known framework-copy diagnostic (`command failed with exit code 0`), but
the Xcode command and verifier both exited 0. This remains local build/test
evidence only; `ui_runtime` is deliberately false.

The unsigned archive manifest was regenerated at `2026-08-23T10:44:16Z`.
Its payload SHA-256 is
`df2ce7aee440584d3471503dd3a598ceca08b387f20a532dcfbe2389fe342341`, which
was recomputed and matched against `manifest-v2.json`. Inspection confirmed
that the zip contains `LatticeLens.app`; its archive Info.plist reports bundle
ID `org.latticelens.app`, productivity category, minimum macOS `14.0`, and
architectures `x86_64 arm64`. `codesign --verify --deep --strict` remains
unsuccessful (`unsigned_or_unverified`). This verifies package structure, not
Developer ID, notarization, Gatekeeper, cross-machine installation,
XCUIApplication, or VoiceOver.

## 2026-08-23 final fixture UI, verifier, and archive record

The launch contract was corrected to recognize XCUITest's actual
`-LatticeLensUseFixtures YES` spelling (including the leading dash). Each
`XCUIApplication` case now blocks on a visible `fixtureModeIndicator` before
any author, paper, settings, PDF, or Vision action. In that mode the app uses
only `InMemoryLibraryStore`, `AppFixtureTransport`, fixture full-text/image
substitutes, and `UIFixtureKeychainStore`; no user library, provider, INSPIRE,
or macOS Keychain is in scope.

Command: an ad-hoc-signed, arm64 macOS
`xcodebuild ... test-without-building -parallel-testing-enabled NO
-only-testing:LatticeLensUITests` run using project-local DerivedData.
Its readable `.xcresult` summary reports **6 total / 6 passed / 0 failed / 0
skipped**, `result=Passed`. The passed cases cover analysis cancellation/cache,
author search entry and self pin, caption-only/Vision separation, full-text
anchors, reference-manager controls, and settings. Xcode also logged
`DebuggerLLDB.DebuggerVersionStore` / `no debugger version`, but the completed
test result—not that diagnostic—is the Gate E evidence. VoiceOver was not run.

One pre-fix diagnostic UI launch was excluded from all pass evidence: before
the leading-dash match existed, it rendered non-fixture local data and was
terminated immediately. Its persistent side effects were not inspected; no
subsequent UI run used that dependency graph. The corrected runs above all
observed `fixtureModeIndicator` before interaction.

Command: `zsh Scripts/verify_v2.sh` (exit status 0)

```json
{"schema_version":"latticelens-verify-v2","local_only":true,"swiftpm_test":1,"swiftpm_release":1,"xcode_debug":1,"xcode_unit":1,"xcode_release":1,"xcode_analyze":1,"ui_runtime":false,"live_inspire":false,"live_llm":false,"failures":0}
```

This final verifier executed **41 XCTest cases with 0 failures** and passed
its SwiftPM Release, Xcode Debug/unit/Release/analyze sub-gates. Its
`ui_runtime=false` remains deliberate: UI automation is recorded separately by
the completed `.xcresult`, not inferred by this credential-free verifier.

Command: `zsh Scripts/archive_v2_unsigned.sh` (exit status 0)

The archive manifest was regenerated at `2026-08-23T14:42:56Z`. Its payload
SHA-256 is
`0ca8ea3b15c1d5ef8ed451c62429a92ec6c42f74884c38dc522d9ccd0e3c26d9` and was
recomputed to the same value. The zip contains `LatticeLens.app`; archive
inspection verified bundle ID `org.latticelens.app`, productivity category,
minimum macOS `14.0`, and `x86_64 arm64`. `codesign --verify --deep --strict`
is still `unsigned_or_unverified`. This is local package-structure evidence
only: it does not verify VoiceOver, Developer ID, notarization, Gatekeeper, or
cross-machine installation.

## 2026-08-22 read-only INSPIRE smoke

All requests used HTTPS, no credentials and a 30 s maximum request time. The
observed responses were: self author `2010363` (200, `Zhao, Dian-Jun`,
`hep-lat` category); candidate page (200, nested `hits.hits`, total 1776,
trusted next URL); citation-summary facet (200, `h-index.value.all=4` for the
self record); literature page (200, nested `hits.hits`, total 10); and its
BibTeX endpoint (200, response begins `@article`). Raw bodies and headers were
task-local scratch only and were deleted; no library database was opened.
