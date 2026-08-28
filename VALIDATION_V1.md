# LatticeLens v1 validation ledger

Date: 2026-08-22 (Asia/Shanghai)  
Frozen input: `INSPIRE文献管理器_开工方案_v1.md`  
Plan SHA-256: `7d3829e43676950c348880c1a93d0861ea714e90f26a0949b5287d2b4a51d0ad`

## Passed local evidence

| Gate | Command / method | Result | Scope proven |
| --- | --- | --- | --- |
| SwiftPM fixture tests | `LATTICELENS_TEST_STORE_ROOT=<project scratch> swift test --scratch-path <project scratch>` | 18 XCTest passed | DTO mapping, trusted pagination, h-index boundary, self pin/search, checkpoint recovery, record-id upsert, strict v1 JSON, title-only translation, cache scope, JSON migration/backup/corruption semantics |
| Xcode project discovery | `xcodebuild -list -project LatticeLens.xcodeproj` | `LatticeLens`, `LatticeLensTests`, `LatticeLensUITests`, shared scheme found | Project/target wiring |
| Debug app | `xcodebuild ... -configuration Debug ... build` | `BUILD SUCCEEDED` | Native macOS app compiles with strict concurrency and warnings-as-errors requested |
| Xcode unit target | `xcodebuild ... -only-testing:LatticeLensTests test` | 15 passed; 3 persistence tests deliberately skipped because Xcode test-host did not forward the task-local store-root environment | App-hosted unit/integration fixtures; the three persistence cases are covered by the SwiftPM gate above |
| Release app | `xcodebuild ... -configuration Release ... build` | `BUILD SUCCEEDED` | Release compilation |
| Static analysis | `xcodebuild ... analyze` | `ANALYZE SUCCEEDED` | Xcode analyzer gate |
| Unsigned archive | `xcodebuild ... CODE_SIGNING_ALLOWED=NO ... archive` | archive contains universal `LatticeLens.app`; `SigningIdentity` and `Team` are empty | Local archive construction only, explicitly not signing/notarization |
| Live INSPIRE read-only smoke | Four public GET requests with 30 s bound: self author, hep-lat candidates (`size=1`), citation-summary facets, literature (`size=1`) | all HTTP 200; self fields, nested search envelopes, and a citation-summary `h-index` object were present | Current public response shape on this date only |

The Xcode commands emitted Xcode 26's `Traditional headermap style is no longer supported` warning. It is an Xcode project-setting warning, not a Swift compiler warning; the requested Swift warnings-as-errors setting remained active.

## Explicitly not proven

- `LatticeLensUITests` is a real `XCUIApplication` target with an in-memory fixture launch path, and it compiles. A complete scheme run including the UI-test bundle did not finish within 90 seconds in this desktop automation context and was cancelled. No UI runtime/VoiceOver claim is made.
- No live LLM provider call was attempted: there is no user-provided API key or authorization. Provider-specific model discovery, SSE behavior, cancellation latency, structured output compatibility and cost are unverified.
- The live INSPIRE smoke does not establish rate limits, future API stability, full pagination scale, image availability or physical correctness of any LLM output.
- Keychain behavior in a signed app, an existing production SwiftData store's historical migration, Developer ID signing, notarization, Gatekeeper, cross-machine behavior and public release are unverified.
- v1's evidence scope remains title + abstract + INSPIRE figure captions. PDF full text and image pixels are not part of the v1 UI/LLM workflow.

## Cleanup record

All live-request JSON/header files, DerivedData, package scratch directories, temporary test stores and the generated unsigned archive were created below this project and are removed after this ledger was written. No server, model provider, background process or user data was modified.
