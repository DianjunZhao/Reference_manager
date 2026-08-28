# LatticeLens v4 validation ledger

日期：2026-08-26（Asia/Shanghai）  
范围：`$PROJECT_ROOT`。本记录只覆盖 local/fixture
证据；不读取用户资料库、浏览器、通信记录或凭据，也不执行 INSPIRE 写操作或远程 LLM POST。

## 结论先行

## 2026-08-26 current-source execution record

当前 source-of-truth 的 `Sources/Tests/Scripts` 聚合 SHA-256 为
`dd72df978b0c3872539bd46fce271a45f3965cd202a6c014e551185a225d9907`。当前 non-UI
verifier 是 `20260825T234536Z-47201`，命令
`zsh Scripts/verify_v4.sh --local-only --skip-ui` 以 exit **0**、`failures=0` 完成：
SwiftPM **89 executed / 0 skipped / 0 failed**，Release `warnings-as-errors` 通过；
Xcode Debug/Release/analyze/build-for-testing 通过；unit result 可读且为
**89 total / 88 passed / 1 explicit opt-in benchmark skipped / 0 failed**。

该 run 的 actual SwiftData V6 disk-backed benchmark 为 warm-search p95 **25 ms**、
cold-open p95 **23 ms**、single-row mutation p95 **3 ms**；V7 active-domain 分别为
**24/81/10 ms**。两种 disk-backed store 的 backup 均经验证，规模均为
2,000 authors / 20,000 papers / 100,000 links / 10,000 chunks。迁移/rollback
contract 的三个指定 XCTest 也通过；这不等于真实用户资料库演练。

同一 source hash 的前台 Xcode `Test` action 生成了可读的
[validation-v4-ui.xcresult]($PROJECT_ROOT/validation-v4-ui.xcresult)。
`xcresulttool` summary 为 **109 total / 108 passed / 0 failed / 1 skipped**、
`result=Passed`；test tree 中 `LatticeLensUITests` 为 **20/20/0/0**，
`LatticeLensTests` 为 **88 passed / 1 explicit opt-in benchmark skipped**。复制到
工作区的 bundle-tree SHA-256 是
`0f91c533be90d870741231e562061031cd1a6b3b9c4d31701178460fc9cf48ca`。

这是一份明确的 **composite current-source** 证据：`verify_v4.sh` 本轮只执行
non-UI gates，CLI UI stage 因 `--skip-ui` 被有意跳过，**没有**被写成 scripted UI
通过；前台 Xcode 的完整 fixture aggregate 则独立满足 20 个业务 case。每个 case 的
首个业务断言均等待 `fixtureModeIndicator`，只使用 `InMemoryLibraryStore`、
`AppFixtureTransport`、`UIFixtureKeychainStore` 与本地 PDF/image substitute。
因此不读取用户资料库、不访问 live INSPIRE、live provider 或 persistent Keychain。

历史的 18-case bundle 已保留为
`validation-v4-ui-historical-20260825T103443Z-24874.xcresult`，旧 summaries 也以
`historical-*` 文件名保留；它们不参与当前判定。机器可读 current ledger 是
`validation-v4.json`、`validation-v4-ui-summary.json`、
`validation-v4-ui-independent-summary.json` 与 `v4_completion_checklist.json`。

- **v4 local automated verdict：`feature-complete within the contract/fixture scope`**。
  当前 hash 的 non-UI gates 和 20-case fixture UI aggregate 均通过。
- **仍未建立的边界**：人工 browse/search/note/PDF/Compare 验收、明确可丢弃的真实资料库
  migration/backup/rollback drill、live INSPIRE/provider、persistent Keychain、VoiceOver、
  Developer ID、notarization、Gatekeeper、跨机安装及 public release。

### Current same-Mac local archive

[Release-v4-local-final-20260826]($PROJECT_ROOT/Release-v4-local-final-20260826)
是新的 no-overwrite、unsigned same-Mac artifact。其 manifest SHA-256 为
`8fa9d662b0dca7924a9db111ace5dc00bf0c8070f18e586b36f817494549d98a`，payload SHA-256
为 `f684c532870e755705655dfe86e249edcc6de0b3d1cf22eb20c59c88915f338b`；universal
executable 为 `x86_64 arm64`，executable SHA-256 为
`57eec61d1fb263531537d5384161fb3bcf02cb2fab34ddda17bdd0b36e701429`。

manifest 记录 `validation_matches_current_source=true`、current fixture aggregate
**20/20/0/0**、`same_mac_install=fixture_smoke_passed` 与
`local_candidate=pending_manual_local_drill`。archive 生成时和 final manifest
provenance 更新后均独立运行 smoke：验证 payload hash、解压到 project-local scratch、
以 fixture 启动至少 3 秒、只终止该 inspection process 并删除 inspection copy。它不
读取 active library、PDF 或 Keychain，不触网，也不等于人工或 public-release 验收。

## Archived historical records (not current-source evidence)

### 2026-08-25 final same-source record

入口：

```zsh
zsh Scripts/verify_v4.sh --local-only
```

- run id：`20260825T103443Z-24874`；exit **0**；`failures=0`。
- `Sources/Tests/Scripts` 聚合 SHA-256：
  `af967914432b886d04989702b408b1099f8d6b1848f64b72f06893ddc1435ffe`。该值与
  `validation-v4.json.artifact_hash` 的独立复算结果相同。
- SwiftPM：**85 executed / 0 skipped / 0 failed**；Release `warnings-as-errors` 通过。
- Xcode（macOS 26.5.1 arm64）：Debug build、Release build、analyze、build-for-testing
  全部通过。`LatticeLensTests` 的可读 result summary 为 **77 passed / 8 skipped /
  0 failed**（total 85）；ledger 不把 skip 计为 pass。
- SwiftData 实测为 in-memory normalized store：2,000 authors、20,000 papers、
  100,000 links、10,000 chunks；insert 26,881 ms、single-row mutation 2 ms、
  warm-search p50/p95 **46/46 ms**，低于 250 ms 目标。RSS max 为 1,135,837,184 bytes。
  这不是 disk-backed cold-open/RSS/migration production benchmark。
- 迁移/rollback 的 disk-backed contract tests 通过：
  `testPreOpenV5ToV6MigrationWritesVerifiedBackupAndIndependentJournal`、
  `testV7MaterializesLegacySnapshotOnceThenUsesDomainRecordsAsActiveTruth`、
  `testDiskBackedV6ToV7MaterializesWithVerifiedPreOpenBackupAndReopens`。它们不等同于
  对真实用户 library 的演练。
- 当前 [validation-v4-ui.xcresult]($PROJECT_ROOT/validation-v4-ui.xcresult)
  独立读取为 **18 total / 18 passed / 0 failed / 0 skipped**，`result=Passed`。每个
  case 都先断言 `fixtureModeIndicator`，随后仅使用 in-memory store、allowlisted local
  transport、process-local Keychain 和 local PDF/image substitute；不读取用户 library、
  不访问 INSPIRE 或外部模型。
- 本 run 的 UI attempt 1 达到 900 s 上限，随后由 verifier 记录为失败证据并仅清理其
  exact-scratch 进程；15 s cooldown 后的独立 attempt 2 产生上述完整 aggregate。最终
  gate 仅以 attempt 2 的当前 result bundle 判定通过，未读取任何历史 root summary。

[v4_completion_checklist.json]($PROJECT_ROOT/v4_completion_checklist.json)
是 R01–R13、V4-1–V4-3 与 A–R 的 machine-readable audit。它严格区分 source/contract、
fixture UI、actual SwiftData、人工和真实资料库证据。

### 同机未签名归档

[Release-v4-local-final-20260825-r5]($PROJECT_ROOT/Release-v4-local-final-20260825-r5)
是最终同源验证后的 no-overwrite artifact。其 manifest SHA-256 为
`dc2ed39f35613ce8aad74ac815bb400d2673f73a13695353cb1e97157b20f98a`，payload SHA-256 为
`5cf61a5c23da33a30af13b6d09288bee369d81dbdd81f68e77e6e1dee666267a`；universal executable
为 `x86_64 arm64`，executable SHA-256 为
`6d4a12fb7e62d0eaf0c0bb85acd24711f1ce4a9b2852c9380b53e6c05c67525c`。

manifest 明确记录 `validation_matches_current_source=true`、
`current_verifier=passed_current_18_case_fixture_aggregate` 与
`same_mac_install=fixture_smoke_passed`。创建时实际复算 source/validation hash、验证
payload、以 fixture 启动 archive 内 app 至少 3 秒并只删除该 inspection copy。状态仍为
`pending_manual_local_drill`：这不是人工 browse/search/note/PDF/Compare、真实用户库
rollback、VoiceOver/manual、Developer ID、notarization、Gatekeeper 或跨机安装证据。

随后的一次 GUI 人工烟测没有被计入验收：前台实例未暴露必需的
`fixtureModeIndicator`，因此按 fail-closed 规则没有执行任何业务控件交互，并立即退出该
实例、删除项目内的 manual-fixture scratch。该现象不改变已经通过的 `XCUIApplication`
证据，也不构成对真实资料库、真实 INSPIRE 或人工产品流程的通过结论。

## Earlier pre-current ledger (superseded where it conflicts)

### 1. 源码与 contracts

已落地的 local 证据包括：

- R01：shared content-addressed PDF 的 reference-count deletion plan、owned
  path canonicalization、orphan deletion journal 和真实临时文件测试；
- R02：partial literature/h-index checkpoint 优先恢复、generation staging/active
  separation 与 terminal outcome 持久化路径；
- R03：`V4ExportCoordinator` 的 `prepared → presenting → succeeded/cancelled/failed`
  事务，file exporter callback 之前不写 succeeded；note editor 以 paper identity
  重置，tag/collection 删除显示关联数并确认；
- R05：observable `V4AnalysisRunState`（run/request/bytes/chars/deadlines/source
  hash/provider/model）；完整 timeout injection 仍是 remaining issue；
- R06：evidence ID/hash/quarantine/same-anchor value+unit validator、section role
  mapping、signed/scientific numeric contract；
- R07：INSPIRE/BibTeX bounded streaming、ephemeral session、strict redirect policy；
- R08：V5 normalized SwiftData entities、backup/verify/restore helpers、增量 paper
  row mutation contract；完整 disk-backed migration benchmark 尚未运行；
- R10：Radar added/removed/modified field-level diff、before/after hash/display/source/
  batch 和 citation nil unknown semantics；
- R11/R12：deterministic Compare extractor、missing-not-guessing、annotation/hash、
  Notebook import/export/bundle contract；production LLM Compare 与 PDFKit selection
  UI 尚未闭环；
- V4-1/2/3：provenance-aware local search、Research Home、Research Bundle
  verify/dry-run/restore-to-new-target；Graph 明示 `Preview: no edge ingestion yet`。

### 2. 自动化命令与结果

入口：

```zsh
zsh Scripts/verify_v4.sh --local-only
```

本轮 run id：`20260824T065715Z-36205`。`validation-v4.json` 是该 run 的机器摘要；
源码聚合 hash 为：
`fec5ae26078bcae38c3d1fbf9e6c974074c3e12d01ac29bd7333c457663096e2`。

| Gate | 结果 | 直接记录 |
|---|---|---|
| SwiftPM tests | passed | 67 executed / 1 skipped（仅 opt-in benchmark test）/ 0 failed；`LATTICELENS_TEST_STORE_ROOT` 使 PDF/JSON integration tests 在项目内运行 |
| SwiftPM Release | passed | warnings-as-errors |
| Xcode Debug | passed | macOS arm64，strict concurrency |
| Xcode unit | passed | `LatticeLensTests` target；result summary 读取路径仍需改进，见 issue V4-VER-02 |
| Xcode Release | passed | warnings-as-errors |
| Xcode analyze | passed | Debug analyze |
| build-for-testing | passed | app/unit/UI targets 均可编译；v4 文件已登记到 `project.pbxproj` |
| v4 local contract | passed | V4LocalTests 11/11；包含 blob、checkpoint、export、Radar、physics、bundle、search、normalized SwiftData |

### 3. Actual SwiftData benchmark

证据文件：[benchmark-v4.json]($PROJECT_ROOT/benchmark-v4.json)。

| 项目 | 实测 |
|---|---:|
| store | SwiftData in-memory（V5 normalized schema） |
| authors / papers / links / chunks | 2,000 / 20,000 / 100,000 / 10,000 |
| insert | 19,414 ms |
| warm search | 652 ms |
| single-row mutation | 12 ms |
| physical memory | 17,179,869,184 bytes（16 GiB） |

方案建议的 warm-search ≤250 ms 目标**未达到**；没有通过降低 byte bound、关闭
validator 或篡改数据来掩盖该结果。该 run 不是 disk-backed cold-open/RSS/migration
benchmark；这些项为 `not_run`。

### 4. UI fixture runtime

新增/登记的 8 个 business cases：

1. `testSettingsWorkflowIsKeyboardDiscoverable`
2. `testFixtureAuthorSearchPaperSelectionAndFiveTabs`
3. `testFixtureAnalysisCancellationCacheAndFigureDegradation`
4. `testFixtureReferenceManagerControlsAreKeyboardDiscoverable`
5. `testFixtureFullTextScopeAndAnchorJumpStayLocal`
6. `testFixtureCaptionOnlyAndVisionDisclosureRemainSeparate`
7. `testFixtureResearchHomeUsesLocalSnapshotCounts`
8. `testFixtureWorkbenchEntryShowsRadarCompareNotebookAndGraphPreview`

每个 case 的第一步是等待 `fixtureModeIndicator`，之后才允许交互；fixture 使用
in-memory store、allowlisted local transport、process-local Keychain 和 local
PDF/image substitute。可读结果包：[validation-v4-ui.xcresult]($PROJECT_ROOT/validation-v4-ui.xcresult)，其摘要为 1 个
runner failure、0 passed、0 skipped：

> `LatticeLensUITests-Runner ... Early unexpected exit, operation never finished
> bootstrapping (signal kill before establishing connection)`

因此机器摘要明确为 `compiled=true`、`executed=false`、`readable_result=true`
（保留的失败摘要）、`feature_complete_gate=false`、business cases passed=0。
这不是 UI 功能通过，也不是 VoiceOver/manual 结果。

### 5. Bundle/backup/migration counts

- Research Bundle `verify/dryRun/restoreToNewStore/tamper` contract：通过；restore
  只允许新 target，不覆盖 active store。
- V4 backup coordinator 的 manifest/hash/verified restore helper：静态和 unit
  contract 已编译；本轮未进行 disk-backed backup/restore drill。
- migration/rollback：`not_run`；没有把未运行写成 0。
- quarantine：validator/quarantine contract 有测试；本轮没有真实用户库迁移，
  因而没有可报告的 production quarantine count。

## 网络、provider 与发布边界

- `verify_v4.sh --local-only` 本身不触网；随后单独运行的
  `Scripts/live_smoke_v4.sh` 返回 9/9 个 credential-free GET/HEAD、HTTP 200，
  `failures=0`，没有保留 raw body，也没有 POST 或写回 INSPIRE。
- 这只是 2026-08-24 的 read-only shape smoke，不能证明长期服务契约、fresh app
  store E2E 或 live provider workflow；当天状态已写入 `validation-v4.json`。
- CloudKit：`out_of_scope`；没有 mock graph 晋升为 live graph。
- API key、Keychain、真实 provider SSE/structured output、Vision pixels、真实 PDF
  下载、Developer ID、notarization、Gatekeeper、跨机安装：未验证。

## Historical backlog / superseded issue IDs

- **V4-VER-01 (P0)**：同一 Mac 已有独立 18/18 fixture UI evidence，但最后一次
  aggregate 无法重建 XCTest runner；需要在 automation host 恢复后，让最新 verifier
  重新获得 18/18 result，而不是复用旧 bundle。
- **V4-VER-02 (P1)**：Xcode unit result bundle 在 `-quiet` gate 中未被稳定解析，需
  将 unit `.xcresult` summary 纳入 verifier；unit exit status 本身为 passed。
- **V4-PERF-01 (P1)**：当前 actual in-memory warm-search p95 为 61 ms，满足 250 ms
  目标；disk-backed cold-open、RSS/batch/migration benchmark 仍为 `not_run`。
- **V4-MIG-01 (P0)**：真实 library 副本 migration/backup/rollback/corrupt-store
  read-only recovery 尚未演练。
- **V4-R04-01 (P0)**：tracked-job owner registry、full Updates/Sync Center progress
  and cancellation lifecycle 仍需完整 production/UI proof。
- **V4-R05-01 (P0)**：connect/first-content/idle/hard timeout injection、late callback
  与 artifact-count clear confirmation 尚未闭环。
- **V4-R06-01 (P0)**：V1 false-positive corpus、独立 Compare validator atomic-replace
  matrix 尚需扩展。
- **V4-R07-01 (P0)**：PDF Content-Length preflight、frozen Vision preflight、actual
  bytes/hash/pages UI 尚未形成 runtime evidence。
- **V4-R10-01 (P0)**：removed-paper query diff、field-diff inspector、acknowledge
  relaunch UI 与全 generation dedup 尚未完成。
- **V4-R11-01 (P0)**：Compare workspace extractor production wiring、exact page/quote
  jump 与 local/fixture response rejection matrix 尚未闭环。
- **V4-R12-01 (P0)**：PDFKit selection/range、annotation edit/delete/stale UI、Notebook
  multi-anchor/import dry-run UI 尚未闭环。
- **V4-R13-01 (P1)**：Graph 诚实保持 `Preview: no edge ingestion yet`；没有 edge
  ingestion，因此不能报告 graph passed。

## Cleanup and ownership

所有本轮 scratch 均置于项目内 `.codex-task-tmp-*`；仅本次明确创建的 verifier/recovery
scratch 会在交付前清理，既有 `.build/`、v1–v4 方案、旧 scratch、`Release-v2/`、
`Release-v3/` 与历史 `Release-v4-local/` 均不删除。当前没有由本轮启动且仍在运行的
后台服务或进程。
