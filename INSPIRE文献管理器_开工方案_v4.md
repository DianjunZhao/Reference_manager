# INSPIRE 文献管理器开工方案 v4：v3 严格审计、本地闭环修复与 GPT-5.6 Terra 执行说明

> 产品工作名：LatticeLens  
> 文档版本：v4.0  
> 审计日期：2026-08-24（Asia/Shanghai）  
> 工作目录：`~/Desktop/Reference_manager`  
> 目标执行者：GPT-5.6 Terra  
> 本文用途：修复 v3 未闭合目标，再实现 v4 的纯本地产品目标；本文本身不是完成声明

## 0. 给 GPT-5.6 Terra 的第一指令

请直接在当前目录实现和验证，不要只做代码审查、UI 草图或再写一份计划。必须遵守：

1. 保留 `INSPIRE文献管理器_开工方案_v1.md`、`v2.md`、`v3.md` 与本文件，不覆盖历史方案。
2. 当前目录不是 Git repository；不得擅自 `git init`、commit、push、reset 或删除既有文件。
3. 先把本文 `R01–R13` 中的 P0 修复写成会失败的 regression tests，再修改实现；未通过本地恢复 gate 前，不开始堆叠 v4 新 UI。
4. 新建 `VALIDATION_V4.md`、`validation-v4.json`、`Scripts/verify_v4.sh` 和独立的 `Release-v4-local/`；不得篡改 v3 ledger 来宣称 v4 通过。
5. 所有 scratch、DerivedData、临时 store、fixture PDF 与 `.xcresult` 都放入本轮唯一的 `.codex-task-tmp-<run>/`；只清理本轮创建的内容。
6. 所有证据必须分为：source inspection、offline unit/integration、actual SwiftData、fixture `XCUIApplication`、credential-free INSPIRE、local model/fixture、同机 `.app` manual。一个层级成功不得外推到另一个层级。
7. 每个 `XCUIApplication` case 必须先等待并断言 `fixtureModeIndicator`，否则立即停止，不得接触用户资料库、真实 Keychain、公网、通知中心或通用 clipboard。
8. 不读取浏览器、通信记录、无关私人目录或凭据。API Key 不得进入日志、fixture、参数、截图、Markdown、manifest 或 `.xcresult` attachment。
9. 不静默覆盖用户 library、PDF、note、tag、collection、annotation、workspace、旧 insight 或旧 backup。迁移/恢复必须先 dry-run，再写到明确 target。
10. 完成后给出 exact commands、test counts、exit codes、artifact hashes、migration counts、UI summary、未完成 issue IDs 与清理记录；不得只写“all tests passed”。

## 1. 本轮范围：只做 local，不再让发布基础设施阻塞产品

### 1.1 v4 的 “local” 含义

本方案中的 local 是：

- 应用、用户资料库、PDF、annotation、search index、cache、backup 和导出都在当前 Mac；
- INSPIRE 仍是 credential-free、read-only HTTPS 数据源，因为作者索引、h-index 和文献同步是产品核心；
- LLM 可以使用 deterministic fixture、`localhost` OpenAI-compatible server，或用户以后明确配置的远端 provider；
- mandatory completion 不需要付费/live provider，也不需要保存任何真实 API Key；
- 同一台 Mac 上可构建、启动、迁移、恢复、操作和导出 `.app`。

### 1.2 明确移出 P0 与完成线

以下不实施或不作为 v4/local 最终阻塞项：

- CloudKit/iCloud、团队同步、跨设备冲突；
- Developer ID、notarization、Gatekeeper 跨机安装、Mac App Store、公网上架；
- public sharing、team database、协作账户；
- live/付费 LLM provider 验收；
- 自动写回 INSPIRE、自动上传 PDF、后台付费 LLM、系统级定时任务；
- 自动抓取全部 1776 位候选直到完成，作为每次本地验收的前置条件。

可以保留现有 CloudKit mock 代码，但不得继续扩大它，也不得用它占用 P0 时间。`Release-v4-local` 只需明确标为 `same_mac_local_build` 或 `ad_hoc_local_candidate`，不再使用 “public release blocked” 来否定本地完成。

## 2. v3 严格审计结论

### 2.1 总结

**判定：v3 未完成，状态为 `Partial / P0 blocked`。**

v3 有真实进展：paper/document-scoped ID、`ContentBlob`/`DocumentReference`、`SyncBatchV3`、Radar records、Compare/Notebook/Graph UI 入口、SwiftData v4 schema extension、55 个离线 XCTest、可启动 macOS `.app` 与 6 个通过的 fixture UI case 都存在。

但 README/ledger 的 `v3 local complete` 结论超出了证据。关键原因是：

- Compare 没有 extractor 或 multi-paper LLM workflow，只创建全为 `missing` 的空表，再允许用户手填；
- 6 个 UI case 全部是 v2 路径，没有一个打开 `Evidence Workbench`；
- SwiftData 仍以整份 `LibrarySnapshot` blob 为 active source，每次 mutation 全删全插 projections；
- “2k/20k/100k 大库 benchmark” 只测 Python dictionary/list/JSON，没有打开或写入 SwiftData；
- shared PDF blob 在 service 层仍可能被提前删除；
- partial checkpoint、Radar diff、Notebook annotation/export、physics validator、Vision disclosure、Sync Center 等仍有 P0 语义缺口；
- `verify_v3.sh` 自己输出 `ui_runtime:false`，却允许 `failures=0`；v3 ledger 仍把 F01–F12 全标为 passed。

因此当前版本可以称为：`v3 source/build baseline + partial local features`。不能称为 `v3 local complete`、`local candidate` 或最终可落地产品。

### 2.2 本轮直接证据

#### v3 方案与当前源码

- `INSPIRE文献管理器_开工方案_v3.md`：692 行；SHA-256 `6c4b4d3033b667b195d5de9eb5c5bd4d2f4de2708c4c354f8ada30934132a02a`。
- 当前 `Sources/ + Tests/ + Scripts/` 聚合 SHA-256：`6874485db3aa319d8fafb34821ae11311947f7bb4941f2cc59e2fec7e3c0606c`。

#### 当前 local verifier

本轮实际运行：

```zsh
zsh Scripts/verify_v3.sh
```

结果：exit `0`；SwiftPM 55 tests、0 failures、0 skipped；SwiftPM Release、Xcode Debug/unit/Release/analyze 与脚本内 Python benchmark 均通过。机器摘要同时明确：

```json
{"swiftpm_test":1,"test_count":55,"skipped_count":0,"xcode_debug":1,"xcode_unit":1,"xcode_release":1,"xcode_analyze":1,"large_library_benchmark":true,"ui_runtime":false,"failures":0}
```

这证明当前代码与当前 55 个 tests 一致，不证明 tests 覆盖了 v3 完成定义。

#### 当前 `XCUIApplication` 复验

本轮使用 project-local scratch、ad-hoc “Sign to Run Locally”、两阶段 `build-for-testing` + `test-without-building`，并从可读 `.xcresult` 直接汇总：

- build-for-testing exit `0`；
- test-without-building exit `0`；
- 6 total / 6 passed / 0 failed / 0 skipped；
- result `Passed`；macOS 26.5.1 arm64；
- task-local DerivedData/result bundle 已在汇总后清理。

这是真实 UI runtime 证据，但源码中的六个 case 只覆盖 Settings、author/search、单篇分析、reference controls existence、fulltext anchor 与 Vision fixture。它们没有点击 `workbenchButton`，没有验证 Radar、Compare、Notebook、Graph，也没有验证 v3 migration/recovery UI。

#### v3 archive

- `Release-v3/LatticeLens-v3-unsigned-local.zip` 实算 SHA-256：`946e695c1cd7be609eaf6fb19cd4bd602ef1fda7f4ce7bc9b48b9940e23b7a61`，与 manifest 一致；
- bundle id `org.latticelens.app`；minimum macOS `14.0`；architectures `x86_64 arm64`；
- `codesign --verify --deep --strict`：exit `1`，`code object is not signed at all`。

它只证明 unsigned archive structure。用户只要 local，所以签名/公证不再是 v4 P0；但必须生成与最终源码一致、可在同机启动的独立 v4 artifact。

#### live 边界

本轮按用户“只需要 local”没有重新发起 INSPIRE/live provider 请求。v3 ledger 自报 2026-08-24 的 9-endpoint credential-free smoke，但它不替代本轮源码的 fresh-store app E2E，也不属于本轮独立复验。v4 mandatory tests 应以 live-shaped fixtures 为基线；目标 Mac 有网络时再运行短 smoke。

### 2.3 v3 Gate 复判

| Gate | 本轮判定 | 直接依据与边界 |
| --- | --- | --- |
| A — build | **Passed local** | 当前 SwiftPM/Xcode Debug/Release/analyze 通过 |
| B — existing tests | **Passed suite / insufficient coverage** | 55/55；缺 actual SwiftData large-store、v3 UI、multi-paper extractor 等 |
| C — INSPIRE | **Not rerun / existing ledger only** | live-shaped fixtures 存在；本轮未做 fresh app live E2E |
| D — persistence/recovery | **Failed P0** | blob active source、全量 projection rewrite、无 actual SwiftData benchmark、迁移 backup/journal 不闭合 |
| E — UI runtime | **Partial** | 当前 6/6 可读结果；0 个 v3 workbench case |
| F — evidence/PDF | **Failed P0** | shared file lifecycle、validator、preflight 等仍不闭合 |
| G — reference manager | **Failed P0** | CRUD UI、note state、export outcome、updates/favorites 不完整 |
| H — live LLM | **Not required for local code complete** | fixture contract 可 mandatory；真实 provider 不外推 |
| I — same-Mac local candidate | **Not achieved** | v3 archive unsigned且早于最终审计；无 v3 manual product flow |
| K — Radar | **Partial / P0** | records/refresh 存在；diff 语义、cancel/progress/UI tests 缺失 |
| L — Compare | **Failed P0** | 只有 empty cells/manual editor；无 extractor/request/privacy contract |
| M — Notebook | **Partial / P0** | import/export 基础存在；annotation/multi-anchor/export transaction/UI 不完整 |
| N — Graph | **Stub / P1** | 只过滤已存在 edges，没有 INSPIRE edge ingestion；CloudKit 移出范围 |

### 2.4 高风险源码定位

| Issue | 当前定位 |
| --- | --- |
| shared PDF file 提前删除 | `Features/PaperLens/FullTextService.swift` → `delete(document:)`；对照 `Core/Persistence/LibraryStore.swift` → `deleteFullText(documentID:)` |
| partial job 未在 selection 优先恢复 | `App/AppViewModel.swift` → `loadPapers(for:syncIfNeeded:)` |
| candidate 与 h queue 非同一原子 generation | `Features/Authors/AuthorIndexService.swift` → `rebuildCandidateIndex`、`refreshHIndices` |
| note state/CRUD UI | `Features/PaperLens/PaperLensView.swift` → `ReferenceControls` |
| export 过早记 success | `Core/Workbench/V3WorkbenchService.swift` → `export`；`Features/Workbench/V3WorkbenchView.swift` → `prepareExport` |
| Updates/Sync Center 缺口 | `Features/PaperLens/MainWorkspaceView.swift` → `SyncCenterView`、`PaperTimeline` |
| request state/timeouts | `LLM/Workflow/InsightWorkflow.swift` → `InsightWorkflowState`；`LLM/Provider/OpenAICompatibleClient.swift` |
| role/numeric/anchor validator | `LLM/Schema/PaperInsightV2.swift` → `decode`、`numericTokensAreAnchored`；`Core/Workbench/V3WorkbenchService.swift` → `V3PhysicsContractValidator` |
| static PDF/Vision disclosure | `Features/PaperLens/MainWorkspaceView.swift` alerts；`LLM/Workflow/VisionWorkflow.swift` preflight |
| blob active source/full projection rewrite | `Core/Persistence/SwiftDataLibraryStore.swift` → `persist`、`synchronizeV2Projections`、`synchronizeV3Projections` |
| benchmark 未经过产品 store | `Scripts/benchmark_v3.py` |
| Radar diff 类型错误 | `Core/Workbench/V3WorkbenchService.swift` → `V3RadarDiff.events` |
| Compare 只有 empty/manual cells | 同文件 → `createWorkspace`；`Features/Workbench/V3WorkbenchView.swift` → `CompareWorkbenchTab` |
| annotation 没有 selection range/editor | `App/AppViewModel.swift` → `createUserAnnotation`；`Features/PaperLens/PaperLensView.swift` |
| v3 UI 未执行 | `Tests/LatticeLensUITests/LatticeLensUITests.swift` 的 6 个 case；`Tests/LatticeLensUITests/AccessibilityFixtureTests.swift` 仅为静态字符串 contract |
| verifier overclaim | `Scripts/verify_v3.sh`、`VALIDATION_V3.md`、`validation-v3.json`、`README.md` |

## 3. 必须先修复的 v3 缺口

### R01 — P0：shared PDF blob 的磁盘生命周期必须与 reference count 一致

当前证据：

- `LibrarySnapshot.deleteFullText` 会按 paper/document scope 删除 rows 并减少 `ContentBlob.referenceCount`；
- 但 `FullTextService.delete` 在调用 store 之前，直接按 `localFilename` 删除磁盘文件；
- 两篇论文共用相同 hash/filename 时，删除第一篇会让第二篇仍有 active reference、却失去实际 PDF；
- 现有 test 直接调用 `store.deleteFullText`，绕过了真正的 service/filesystem path。

要求：

1. 删除事务先向 store 请求 `DeleteFullTextPlan`，其中包含 document、blob、remaining reference count 与允许删除的 filename。
2. 只有 durable store mutation 成功且 remaining count 为 0 时才删除 content-addressed file；磁盘删除失败需记录 orphan/retry，不得回滚成错误 active reference。
3. re-download/supersede 同样走 blob ownership contract；不得泄漏旧 file 或误删 shared file。
4. path 必须位于 app-owned cache root，canonicalize 后再删除；拒绝 `..`、symlink escape 与绝对 filename。
5. integration test 使用真实 temp files：两篇同 hash → 删除一篇 → 文件仍存在且第二篇可由 PDFKit 打开 → 删除第二篇 → 文件被清理。

### R02 — P0：checkpoint resume、candidate generation 与 h queue 必须原子闭合

当前证据：

- literature sync 只在全部分页成功后更新 author freshness，这一部分已改善；
- `AppViewModel.loadPapers` 只看 `author.lastSyncedAt`，没有优先检查 non-completed checkpoint；旧成功时间很新时，partial job 不会自动恢复；
- candidate membership 在 metadata pages 完成后就切 active，随后才运行 h-index queue；
- `AuthorIndexGeneration.hQueue*` 没有随 h queue outcome 更新，candidate record count 还被写入 `hQueueCompleted`；
- `refreshHIndices` 每次重建 checkpoint，没有以 durable pending/failed/cancelled 集合恢复同一 generation。

要求：

1. app start/author selection 先查 `checkpoint(jobID:)`；只要 state 非 completed 且有 next/pending，就恢复，无视旧 `lastSuccessfulSyncAt` 是否 fresh。
2. metadata pages + h queue 属于同一 `AuthorIndexGeneration`；只有所有 candidates 进入 qualified/rejected/failed/cancelled terminal 集合后才原子切 active membership。
3. 新 generation 完成前继续显示旧 completed generation；普通作者的旧 h snapshot 可显示 stale provenance，但不得混入新 membership。
4. 每个 h outcome 原子写 author snapshot、generation counters、pending/failed/cancelled/retryable 与 `SyncJobEvent`。
5. pause 保留 pending；cancel 不写 failed；resume 只请求 pending/retryable，不重请求 success/rejected。
6. failure injection：page 2 failure、h item N failure、process recreation、force rebuild interruption、old freshness + active checkpoint。

### R03 — P0：reference-manager UI state 与 export outcome 必须真实

当前证据：

- service 层有 tag/collection rename/delete，但 UI 只有 create/toggle/join；
- `ReferenceControls.note` 只在 `onAppear` 读取一次，没有以 paperID/existing note identity 重置；切论文可把旧文本保存到新 paper；
- v3 UI test 只断言控件存在，没有点击、重启和读取；
- Workbench `ExportRecord.succeeded=true` 在系统 file exporter 真正写文件之前保存；用户取消/写失败仍被记为成功。

要求：

1. note editor 使用 `paperID + noteID` 作为 view identity；paper 变化时先刷新，再允许编辑。保存 existing note 保持 UUID/createdAt。
2. tags/collections 提供 rename/delete UI；destructive confirmation 显示将解除的 link count，确认后才 mutation。
3. collection menu 支持 add/remove，不是只允许加入。
4. 引入 `ExportCoordinator`：`prepared → presenting → succeeded/cancelled/failed`；只有 file exporter callback 成功后写 succeeded record 与实际 destination category/hash。
5. BibTeX batch 中任一 paper 缺 authoritative cached record 时，UI 明示缺失并让用户选择“先获取/跳过/取消”；不得静默导出空字符串。
6. UI fixture 真正修改 favorite/read/tag/collection/note，terminate/relaunch temp store 后再断言。

### R04 — P0：Update Center、Favorites 与 tracked jobs 必须成为产品路径

当前证据：

- `SyncBatchV3` 和 `SyncJobEvent` 已在生产 sync 写入；
- 中栏 filter 仍没有 `[论文] [更新] [收藏]`；
- Sync Center 只显示几个当前状态字符串，没有 tracked authors、Radar saved queries、batch diffs、page/remaining counts；
- foreground tracked refresh 使用 task group，不由可取消的 durable job owner 管理。

要求：

1. Library 中栏提供 Papers / Updates / Favorites / Needs Review；Updates 按 completed batch 展开 new/metadata/citation/document/figure diff。
2. Sync Center 分列 author pages、h queue、tracked authors、saved queries、paper sync、fulltext、text/evidence/vision/local-index；显示 jobID、generation、counts、last checkpoint。
3. 每个可运行 job 有单一 owner；pause/resume/cancel 语义与 service 支持一致。不能展示无效按钮。
4. tracked refresh 使用有界 owner registry；app close/author untrack/query delete 时取消并持久化 terminal state。
5. fixture 不请求 NotificationCenter 权限；local notification 继续作为非阻塞 P1。

### R05 — P0：LLM request state、timeout、cache 与清理必须可审计

当前证据：

- settings/key 变化已取消三类 analysis session，这是已完成部分；
- `InsightWorkflowState` 仍只有 connecting/waiting/receiving characters/validating，没有 request `i/N`、bytes、idle/hard timeout；
- transport 只有统一 URLRequest/resource timeout，无法区分 connect、first-content、stream-idle、hard-resource；
- clear scope 存在，但确认框不显示将删除的实际 artifact count。

要求：

1. `AnalysisRunState` 至少含 runID、paper set、request i/N、phase、received bytes/chars、elapsed、connect/first-content/idle/hard deadlines。
2. fixture 分别注入 connect timeout、first-byte timeout、mid-stream idle、oversize、cancel、late callback；不得自动重发 POST 或 SSE→non-stream fallback。
3. current/last successful artifact 分开；fail/cancel 保留 last successful 并标时间/provider/model/source hash。
4. clear confirmation 显示每个 scope 的 count 与 paper set；成功后 ledger 记录删除 count，不记录内容。
5. model discovery task 也有 owner、cancel 和 credential-revision cache invalidation test。

### R06 — P0：evidence 与 physics validator 必须证明“值和单位来自同一 paper anchor”

当前证据：

- v2 validator 只检查 evidence ID 属于 allowlist；duplicate IDs 未拒绝；
- section 与 epistemic role 没有强制映射；
- numeric regex 只覆盖简单正数/少量单位；
- v3 physics-cell validator 验证 same-paper ID 与 quote hash，却没有检查 cell 的 value+unit 是否共同出现在所引 anchor；任意文本 anchor 也可支持 `0.09 fm`。

要求：

1. research/method/result 必须 `direct`；reasonable inference 必须 `inference`；missing 必须 `missing` 且无 anchor；caveat 定义独立允许状态。
2. 拒绝 duplicate evidence ID、cross-paper/document ID、quote hash mismatch、quarantined/stale ID、unsupported source scope。
3. numeric parser 覆盖 signed/scientific notation、parenthesized uncertainty、`±`、区间、百分比、`L^3×T`、`a^{-1}`、`GeV^2`、`fm^{-1}`、ensemble count、fit range、source-sink separation。
4. 对每个 physics cell 解析 normalized `(value, unit)`，要求二者在同一 anchor 的同一局部窗口内匹配；只有 explicit `cross_paper_inference` 可引用其它 paper，且不能冒充该 paper 的 direct 值。
5. 提供 false-positive corpus：年份、reference number、equation label、page number 不得被当物理数值。
6. Compare extractor 输出必须经过独立 validator 后才写 store；失败保持旧 matrix，不部分覆盖。

### R07 — P0：所有网络边界与 disclosure 必须发生在发送前

当前证据：

- PDF 与 Vision image 已用 `URLSession.bytes` 做 streaming limit；
- INSPIRE metadata 与 BibTeX 仍通过 `data(for:)` 先收全量 body；
- PDF 下载 UI 未先展示 Content-Length estimate、上限与存储类别；
- Vision consent alert 是静态“最多三张”，actual preflight 在用户 consent 后才构建；
- redirect policy 没有明确拒绝非默认 port；BibTeX 默认使用 shared session。

要求：

1. INSPIRE JSON、facet、BibTeX、PDF、figure 全部使用 app-owned bounded stream loader；按 endpoint class 分配 byte/time limits。
2. 每次 redirect 验证 scheme、exact allowed host、effective port、userinfo、query/fragment、path class；Authorization 永不跨 origin。
3. PDF preflight 在 GET 前显示 source、server-reported Content-Length（若有）、hard limit、cache category；下载后显示 actual bytes/hash/pages。
4. Vision 先本地下载/缩放并冻结 preflight，再展示 figure keys、原始/发送尺寸、每图/总 bytes、endpoint、request count、frozen hash；accept 只对该 hash 有效。
5. `maximumFigures=0` 时 button disabled、preflight image count 0、provider requests 0。
6. BibTeX 使用 ephemeral session/redirect delegate；失败保留 old verified record。

### R08 — P0：SwiftData 必须成为真实可增量更新、可备份、可恢复的 active store

当前证据：

- `StoredLibraryDocument.snapshotData` 仍是 active source；每个 mutation 都 decode/encode 整个 snapshot；
- `synchronizeV2Projections` 和 `synchronizeV3Projections` 每次 fetch/delete 全表再 insert；
- V3 projections 不包含 revision snapshots、batches/job events、blobs/references、workspace links/contracts、graph edges 等完整实体；
- `Scripts/benchmark_v3.py` 只测 Python containers，不碰 SwiftData、迁移、并发或磁盘；
- v3→v4 SwiftData schema 是 lightweight migration，没有在 opening container 前创建独立 checksum backup；migration journal 是 snapshot 内记录，不是 crash-safe coordinator。

要求：

1. 选定一个 active source：推荐 normalized SwiftData entities。blob 只允许作为 versioned export/backup snapshot，不参与正常 mutation/read。
2. repository API 按 changed IDs upsert/delete；任何单 note/tag/read mutation 不得全表删除或重写 20k papers。
3. 补齐 v4 active entities：authors、h snapshots、papers、author links、checkpoints/generations/jobs/batches/revisions/events、PDF blobs/references/chunks/anchors、AI artifacts、reference records、workspaces/contracts/cells、annotations/imports/exports、search-index metadata。
4. 打开新 schema 前，由 bootstrap coordinator 复制整个 store package/sidecars 到 timestamped backup，计算 manifest hash；成功后才标 active。
5. migration journal 独立、阶段化、可在 crash 后 resume/rollback；pre/post row counts、semantic hashes、quarantine counts 一致。
6. corruption UI 提供只读打开、恢复到新 target、取消；不得 silent empty/silent overwrite。
7. actual SwiftData benchmark 创建 2k authors、20k papers、100k links、100 PDF metadata、至少 10k chunks；测 cold open、warm query、single-row mutation、batch upsert、backup、migration、disk/RSS。
8. 建议目标（是验收目标，不是现有结果）：当前目标 Mac warm search p95 ≤ 250 ms、single note/read mutation p95 ≤ 100 ms、cold open p95 ≤ 5 s；若未达标，Gate D 失败并记录真实数值，不降低数据正确性换取假通过。

### R09 — P0：v3 UI tests、verifier 与 ledger 必须停止“入口存在即通过”

要求：

1. 新增真实 Workbench UI cases，不能用字符串相等的 `AccessibilityFixtureTests` 代替运行时行为。
2. `verify_v4.sh` 的 mandatory local aggregate 必须包含 readable `.xcresult` summary；`ui_runtime=false` 时不得 `failures=0` 并宣称 feature-complete。
3. failed logs 不能随 trap 一起删除后再提示“see deleted log”；保留 compact sanitized evidence 或支持 `--keep-evidence`。
4. verifier 区分 `compiled`、`executed`、`readable result`、`business cases passed`。
5. README/ledger 删除现有 `v3 local complete` 与 F01–F12 全 passed 的过度声明，改为历史审计 + current v4 gate links。
6. source hash、test manifest、fixture sentinel、UI case names、test count、artifact hash 自动生成，不手写复制。

### R10 — P0：Research Radar diff 必须区分新增、删除、修改

当前实现把 documents/figures 的任意 hash 变化都标成 `newDocument`/`newFigure`，且 event 只保存 record-level before/after hash，没有 field-level hash/diff。

要求：

1. snapshot 保存 canonical normalized sets；diff 分类 `added/removed/modified`，相应 event kind 不得把删除写成新增。
2. 每个 changed field 保存 beforeFieldHash/afterFieldHash 与 bounded display diff；unknown citation 与 0 分开。
3. dedup key 为 paper + event kind + before/after field hashes；同一 batch/retry 不重复创建。
4. saved-query refresh 显示 progress/cancel；pause/delete active query 会取消 owner 并保存 terminal batch。
5. UI 展开 field diff、source/fetchedAt/batch；acknowledge 可持久化并在 relaunch 后保留。

### R11 — P0：Multi-paper Compare 必须从“空表编辑器”升级为 evidence-backed extractor

要求：

1. workspace 仍限制 2–6 papers；创建后可选择 `仅本地规则提取` 或 `LLM fixture/local endpoint`。
2. deterministic local extractor 先从 metadata/anchors 识别明确格式；无法确认就 `missing`，不得猜测 action、ensemble、Fourier 或 renormalization。
3. LLM path 使用独立 `physics-contract-v1` schema；request 绑定 paper set、每篇 anchor allowlist、source/document hash、total bytes、provider/model/prompt/schema。
4. 发送前显示每篇 selected chunks/bytes 与总量；同意绑定 frozen payload hash。
5. response 必须按 paper/row 验证 R06；全体通过后 atomic replace matrix，否则保留旧 matrix 并显示 rejected report。
6. Inspector 中每个 evidence chip 可跳到具体 abstract/caption/PDF page/quote；不是只跳到论文顶层。
7. workspace 支持 rename/delete/reorder/note/frozen export；删除不删除 paper/PDF。

### R12 — P0：Evidence Notebook 必须有真正的 annotation 与可验证导出事务

要求：

1. PDFKit text selection、abstract/caption selection 可创建 annotation，保存 exact character range、quote、quote hash、page、paper/document、label/color/note。
2. annotation 可 edit/delete；PDF 更新只做 unique exact relocation，失败 stale，绝不 fuzzy silent move。
3. 新增 `NotebookEntry`，一条 note 可引用多个 annotation/evidence anchors，稳定排序并可点击跳转。
4. Notebook tab 显示/筛选 annotations、stale/quarantined、unresolved import conflicts，不只是论文选择列表。
5. Markdown footnote 使用稳定短 ID；同时导出 source URL、document/quote hash、status。默认不含绝对本机路径。
6. import 有 hard file/count/string limits，先 parse/dry-run，再显示 match/conflict；accepted 只执行用户确认的字段，rejected 不改变 paper。
7. ExportRecord 采用 R03 transactional outcome，用户取消不得 succeeded。

### R13 — P1：Graph 要么接入真实本地数据管线，要么诚实标为 preview

当前 Graph button 只过滤 snapshot 中已有 edges，而生产代码没有从 INSPIRE 写入 citation/coauthor edges。

要求：

1. 若 v4 实现：用户点击后 credential-free 获取一跳 source-backed edges，逐页 bounded，保存 source query/fetchedAt/batch；失败 edge 不绘制。
2. 若 P0 时间不足：UI 明示 `Preview: no edge ingestion yet`，Gate N 标 Not implemented，不得继续写 `graph passed local`。
3. CloudKit 从 v4 范围移除；不要继续实现 mock/live CloudKit。

## 4. v4 新产品目标

修复 R01–R12 后，再实现下列 local-first 目标。P0 优先级高于 R13。

### V4-1 — P0：Unified Local Search 与 provenance-aware Smart Views

1. `⌘K` 搜索 title、abstract、author、arXiv、DOI、tag、collection、note、annotation 和已提取 PDF chunks。
2. 每个 result 标明命中来源；PDF/annotation 命中可直接跳 paper/page/quote。
3. index 完全本地、增量更新、可由 normalized source 重建；index corruption 不影响 authoritative library。
4. 支持 facets：Unread、Favorite、Updated、Has PDF、Has validated claims、Stale evidence、Needs import review。
5. 搜索 query/结果不发送给 provider；不索引 API Key、logs 或未选择的 raw response。
6. actual 20k-paper SwiftData/FTS benchmark，不得再次用 Python dictionary 替代产品路径。

### V4-2 — P0：Local Research Home / Reading Inbox

首页回答三件事：今天有什么变化、下一篇读什么、哪些证据需要处理。

- Radar unacknowledged events；
- unread/favorite/queued papers；
- stale/quarantined annotations/claims；
- pending import conflicts；
- active/failed/resumable local jobs；
- recent Compare workspaces 与 exports。

Reading state 增加 `inbox / reading / done / archived` 与 user priority；它只影响本地工作流，不改 INSPIRE metadata。所有 smart counts 必须来自 store query，不硬编码。

### V4-3 — P0：可恢复的 Local Research Bundle

提供 user-selected `.latticelensbundle`（directory package 或 zip）：

1. manifest、schema version、app version、createdAt、record counts、per-file SHA-256；
2. 默认包含 papers、links、notes、tags、collections、annotations、workspaces、contracts、provenance 与 imports/exports ledger；
3. 默认不含 PDF bytes、LLM raw response、本机绝对路径、endpoint、Keychain、logs；用户可显式选择包含 PDF blobs，并显示总 bytes；
4. import 先 verify hashes/schema → dry-run counts/conflicts → 写入新 staging store → atomic switch；
5. 支持“仅查看 bundle”与“恢复到新 library”，绝不覆盖 active library；
6. fixture 做 tamper、partial zip、duplicate IDs、older schema、cancel/rollback tests。

### V4-4 — P1：Local OpenAI-compatible profile

为了真正保持 local，可增加 `Local OpenAI-compatible` profile：

- 只允许 `localhost`、`127.0.0.1`、`::1` 的 HTTP/HTTPS；
- 默认不要求 Keychain API Key；若 local server 需要 token，仍只进 Keychain；
- health/models discovery 与 completion 分开；
- UI 显示 `Local process not bundled`，不声称 app 内置模型；
- deterministic fixture 为 mandatory；真实 Ollama/LM Studio/其它本地 server smoke 仅在用户环境存在时运行；
- 模型输出仍必须经过相同 schema/evidence validator，local 不等于可信物理结论。

## 5. 推荐展示：Local Research Cockpit

不要继续把 Evidence Workbench 放在一个与主流程割裂的大 sheet 中。建议改为稳定 product navigation：

```text
┌ NAV ───────────┬ INBOX / AUTHORS / LIBRARY ─────┬ READER / COMPARE ───────────────────┬ EVIDENCE INSPECTOR ──────┐
│ Home        8  │ ⌘K 本地统一搜索                 │ 中文标题（主）                         │ direct / inference / missing│
│ Authors        │ ★ Zhao, Dian-Jun                │ English title（次）                     │ paper / source / hash       │
│ Library        │ A … Z                           │ [阅读] [物理矩阵] [Notebook]            │ quote + page + [跳转]       │
│ Radar       5  │                                 │                                    │ stale / validated / local   │
│ Compare     2  │ Papers / Updates / Favorites    │ PDF page 或 physics-contract matrix      │ [加入 annotation]            │
│ Notebook    3  │ Smart Views / Needs Review      │                                    │ extraction/schema version   │
│ Search         │                                 │                                    │                             │
├───────────────┴─────────────────────────────────┴────────────────────────────────────┴─────────────────────────────┤
│ ACTIVITY SHELF  author pages 2/8 · h queue 41/120 · Radar page 1 · local index idle · LLM request 1/2           │
└───────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

交互原则：

- Authors 仍保持本人 recid `2010363` 永久第一，其他 A–Z，支持 native name/BAI 搜索；`h(all)>20`，20 不合格。
- Home 是 work queue，不是新闻 feed；每个数字都可进入具体 records。
- 中文标题优先展示，但原文标题始终同屏可见；摘要翻译与物理解释分别标 source scope。
- Compare 的 cell 用文本 status + icon，不只依赖颜色；点击直接在右栏展示 quote，再跳 PDF page。
- LLM 生成前显示 frozen payload preflight；生成时 Activity Shelf 显示 request i/N、bytes、elapsed；失败保留旧结果。
- 右栏 Inspector 在 Reader/Compare/Radar/Search 共用，避免四套证据 UI。
- 最小宽度 1120；窄窗口折叠 Inspector 为 sheet，Author search/self row 永不消失。
- 建议快捷键：`⌘K` search、`⌘⇧A` 加入 annotation、`⌘⇧C` 加入 Compare、`⌘Return` 打开 source、`Esc` cancel current local task。

## 6. v4 数据模型与 ownership

至少新增或重构：

- `StoredAuthor`、`StoredHIndexSnapshot`、`StoredPaper`、`StoredPaperAuthorLink`；
- `StoredSyncCheckpoint`、`StoredAuthorIndexGeneration`、`StoredSyncJob`、`StoredSyncBatch`、`StoredRevisionSnapshot`、`StoredRadarEvent`；
- `StoredContentBlob`、`StoredDocumentReference`、`StoredEvidenceChunk`、`StoredEvidenceAnchor`、`StoredUserAnnotation`；
- `StoredWorkspace`、`StoredWorkspacePaperLink`、`StoredPhysicsContract`、`StoredPhysicsCell`；
- `StoredNotebookEntry`、`StoredNotebookAnchorLink`、`StoredImportRecord`、`StoredImportConflict`、`StoredExportTransaction`；
- `StoredReadingWorkflowState`、`StoredSearchIndexState`、`StoredBundleRecord`；
- `MigrationJournal` 与独立 `StoreBackupManifest`。

Ownership 规则：

1. normalized SwiftData rows 是 active truth；Codable snapshot 只用于 backup/export/fixture。
2. INSPIRE-owned metadata 与 user-owned state 分表；refresh 不覆盖 note/read/tag/annotation。
3. PDF bytes 由 `ContentBlob(hash)` 拥有；paper/document 只持 reference。
4. AI artifact immutable，按 paper set/source hash/provider/model/prompt/schema 取 cache key；regenerate 新建 artifact，不原地改物理结论。
5. search index 是 rebuildable derived data；删除 index 不删除 library。
6. migration coordinator 是唯一允许切 active store 的 owner。

## 7. local 网络、隐私与证据契约

### 7.1 INSPIRE

- 只允许 credential-free idempotent GET/HEAD；不写回。
- live-shaped fixtures 是 mandatory；短 live smoke 只检查 schema/type/origin，不固定 totals/record ids。
- h-index failure 保持 unknown/stale；永不写 0 或 rejected。
- live smoke 不要求完整跑 1776 candidates；只跑 self、one candidate page、one facet、one literature page、BibTeX 与 bounded PDF/figure policy。

### 7.2 LLM

- POST 不自动 retry；用户重试生成新 runID。
- fixture/local/remote profile 分项记录；一个 profile 成功不外推另一个。
- direct/inference/missing 必须由 local validator 决定是否接受，不由 provider 自报。
- provider 收到的 exact source scope、paper set、bytes、pixels、request count 在发送前显示并冻结。

### 7.3 本地文件

- import/export/backup 只使用 user-selected URL 或 app-owned container；必须处理 security-scoped access。
- filename 不得直接成为 path；canonical root containment 后才读写/删除。
- local paths 默认不进入 Markdown/provenance；只有用户显式选择才写相对 bundle path。

## 8. 实施顺序

### Phase 0 — 冻结与纠正证据

- 生成 pre-change manifest/hash；
- 创建空 v4 ledger；
- 把 R01–R13 写成 machine-readable checklist；
- README 将 v3 改为 Partial，不能等最后才修 truthfulness。

### Phase 1 — 红色 regression tests

- shared PDF real-file test；
- incomplete checkpoint + fresh timestamp；
- candidate/h generation atomicity；
- note switch/export callback；
- role/numeric/value-unit validator；
- Radar removal/modification；
- actual SwiftData mutation/benchmark harness；
- Workbench UI fixtures。

### Phase 2 — persistence 与 blob ownership

- R01、R08；
- normalized repositories；
- pre-open backup、migration journal、rollback；
- actual large-store test。

### Phase 3 — sync/Radar/update center

- R02、R04、R10；
- generation/job owner；
- Updates/Favorites/Needs Review；
- Activity Shelf/Sync Center。

### Phase 4 — evidence/network/provider

- R05–R07；
- bounded stream loader；
- frozen PDF/Vision/multi-paper preflight；
- strict physics validator。

### Phase 5 — v3 product closure

- R03、R11、R12；
- Compare extractor；
- editable Notebook/multi-anchor notes；
- transactional import/export。

### Phase 6 — v4 product layer

- V4-1 unified local search；
- V4-2 Home/Reading Inbox；
- V4-3 Research Bundle；
- V4-4 local model profile only after P0 green。

### Phase 7 — real fixture UI/runtime

- 至少执行本文 UI matrix；
- current readable `.xcresult`；
- keyboard/resize/focus/local manual smoke；
- no-network relaunch 与 corrupt-store read-only UI。

### Phase 8 — same-Mac candidate

- `verify_v4.sh` single command；
- 独立 `Release-v4-local/`，manifest/hash/no-overwrite；
- 解压到 user-selected temp folder，在同一 Mac 启动、操作 fixture/local store、导出 bundle、rollback。

## 9. 必须新增的测试

### 9.1 Unit/contract

- shared blob refcount + canonical file containment；
- generation atomic switch、pending/failed/cancelled/retryable；
- Radar added/removed/modified/nil citation/dedup；
- export prepared/cancelled/failed/succeeded；
- note identity、tag/collection rename/delete link counts；
- evidence duplicate/cross-paper/stale/quote hash；
- signed/scientific/uncertainty/range/volume/inverse-unit/fit-range numeric corpus；
- physics cell value+unit same-anchor window；
- Vision 0/1/3, frozen preflight hash, port/redirect/size；
- bounded BibTeX/INSPIRE/local import；
- Compare atomic validator；
- annotation range/edit/delete/exact relocation/stale；
- bundle manifest/tamper/schema/rollback；
- local search rebuild/incremental delete/update。

### 9.2 Integration

- paper page 2 failure → process/store recreation → selection auto-resume；
- candidate pages complete + h queue interrupt → old generation remains active；
- tracked/Radar owner cancel and relaunch；
- two papers share actual PDF file → delete one → second PDFKit read succeeds；
- v3 store package backup → v4 migration interruption → old store unchanged → resume/rollback；
- actual 2k/20k/100k/10k-chunk SwiftData benchmark；
- Compare fixture response one bad cell → zero new cells committed；
- file exporter cancel/failure does not create success record；
- bundle import staging conflict/cancel/atomic switch；
- local FTS index corrupt → rebuild without library loss。

### 9.3 `XCUIApplication`

每个 case 先断言 `fixtureModeIndicator`。至少覆盖：

1. self-first + Z author + name/native/BAI search；
2. candidate pause/relaunch/resume 与 visible progress；
3. paper partial checkpoint + fresh timestamp 自动 resume；
4. Updates/Favorites/Needs Review 与 Sync Center counts；
5. note 切 paper、tag/collection rename/delete、relaunch persistence；
6. shared PDF delete isolation + anchor jump；
7. Vision maximum=0 与 actual frozen disclosure；
8. Radar save/refresh/cancel/diff/acknowledge/relaunch；
9. Compare create 2 papers → fixture extractor → matrix → cell → exact anchor/PDF page；
10. Compare rejected response 保留旧 matrix；
11. annotation create/edit/delete/stale；
12. BibTeX/RIS/CSL/Markdown/provenance exporter fixture success/cancel；
13. bibliography import dry-run/conflict accept/reject；
14. `⌘K` local search命中 note/annotation/PDF 并跳转；
15. Home counts 与 Reading Inbox state；
16. bundle export/tamper/import-read-only/restore-to-new-store；
17. corrupt library read-only recovery UI；
18. keyboard focus、1120/窄窗口、status 不只靠颜色。

### 9.4 Manual local

- 同机 `.app` 解压/启动；
- no-network browse/search/notes/PDF/Compare old artifacts；
- credential-free INSPIRE short smoke（网络可用时）；
- fixture 或 localhost LLM，至少 3 篇 LQCD fixture paper 做人工物理 rubric；
- backup/restore drill；
- memory/disk observation；
- VoiceOver 可作为 P1，keyboard/focus/accessibility labels 仍是 P0。

## 10. 本地 Gate 与完成定义

| Gate | v4 mandatory evidence | 失败含义 |
| --- | --- | --- |
| A | SwiftPM + Xcode Debug/Release/analyze warnings-as-errors | build baseline 不成立 |
| B | current unit/integration tests，0 unexpected skip | local contract 未闭合 |
| C | live-shaped fixtures；目标 Mac 可用时短 INSPIRE smoke | 数据契约或当前兼容性未知 |
| D | normalized SwiftData、backup/migration/rollback、actual large-store | 用户库仍不安全/不可扩展 |
| E | current readable `.xcresult` 且 v3/v4 business cases 实际执行 | GUI 功能未证明 |
| F | shared PDF lifecycle、anchors、validators、preflight | evidence reader 未闭合 |
| G | read/favorite/note/tag/collection/updates/import/export | reference manager 未闭合 |
| K | Radar semantic diff + cancel/progress/UI | Radar 未完成 |
| L | Compare extractor + atomic physics validation + anchor jump | Compare 未完成 |
| M | annotations + multi-anchor Notebook + transactional export | Notebook 未完成 |
| O | unified local search + actual index benchmark | V4-1 未完成 |
| P | Home/Reading Inbox durable state + UI | V4-2 未完成 |
| Q | Research Bundle verify/dry-run/restore | V4-3 未完成 |
| R | same-Mac `.app` launch + manual rollback drill | local candidate 未形成 |

严格命名：

- `v3 recovered local`：A–G、K–M 通过；不要求 live paid LLM/CloudKit/Developer ID。
- `v4 local feature-complete`：再通过 O–Q；C 的 live smoke 若因网络不可用可标 blocked，但 fixtures 必须全过。
- `v4 same-Mac candidate`：再通过 R；artifact 可以 ad-hoc/local signed，必须真实标 class。
- `Final local landing`：在用户实际 library 副本上完成一次 migration/rollback、一次配置好的 fixture/localhost/授权 provider workflow 与一轮人工 LQCD rubric；仍不等于 public release。

## 11. 建议验证入口

Terra 应将最终命令固化到 `Scripts/verify_v4.sh`，而不是让用户拼接。最低逻辑：

```zsh
zsh Scripts/verify_v4.sh --local-only
```

机器摘要至少包含：

```json
{
  "schema_version": "latticelens-verify-v4",
  "local_only": true,
  "swiftpm_tests": null,
  "xcode_unit_tests": null,
  "ui_total": null,
  "ui_business_cases": [],
  "ui_runtime": null,
  "swiftdata_large_store": null,
  "migration_rollback": null,
  "search_index": null,
  "bundle_restore": null,
  "live_inspire": "not_run",
  "live_llm": "not_required",
  "artifact_hash": "",
  "failures": null
}
```

规则：

- mandatory bool 任一 false → nonzero；
- `ui_runtime` 只能来自 readable `.xcresult`；
- test count 从 result 读取，不手写；
- live INSPIRE 与 live LLM 不得伪装成本地 test；
- failure logs 必须可读，或在 summary 中内嵌 sanitized failure snippets；
- scratch cleanup 后，不得留下 `.codex-task-tmp-*`、测试 app、fixture PDF 或后台进程。

## 12. Terra 最终交付物

至少包括：

- 修复后的 Sources/Tests/fixtures；
- normalized v4 SwiftData repositories 与 migration/backup/rollback coordinator；
- Compare extractor/schema/validator；
- annotation/Notebook/export transaction；
- local search/Home/Research Bundle；
- `Scripts/verify_v4.sh`、actual SwiftData benchmark、独立 optional live smoke；
- `VALIDATION_V4.md`、`validation-v4.json`；
- current UI summary，列出 v3/v4 case names；
- `Release-v4-local/` manifest、payload SHA-256、同机安装/回滚说明；
- README 的真实状态更新。

最终回复必须逐项列出：

1. v3 recovered verdict；
2. v4 local feature verdict；
3. changed/new files；
4. commands、counts、exit statuses、hashes；
5. actual SwiftData benchmark 与 hardware；
6. migration/backup/rollback/quarantine counts；
7. UI business case names 与 `.xcresult` summary；
8. live INSPIRE/provider 的 run/not-run 边界；
9. same-Mac artifact class；
10. remaining P0/P1 issue IDs；
11. cleanup 结果。

## 13. 预计还需要几版

按当前代码基础与本方案范围，**预计还需要 2 版才能在当前 Mac 上最终落地**：

- **v4**：修复本文件 P0、补齐真正的 Compare/Notebook/Radar、normalized persistence，并实现 local search/Home/bundle，形成 feature-complete build；
- **v5**：只做真实 library 副本迁移、长时间运行、UI/manual physics rubric、性能回归、同机安装/回滚与 bug burn-down，形成 final local candidate。

保守预留 **v6** 作为 contingency：只有 actual SwiftData migration、大库性能、PDFKit selection 或 UI automation 在 v5 暴露结构性问题时才需要。因此现实估计是 **2 版，保守 2–3 版**；不再计 CloudKit、Developer ID、公证或公开发布版本。

## 14. 最后约束

- 本人 recid `2010363` 始终第一；其他作者 A–Z；`h(all)>20`，20 不合格。
- h-index/INSPIRE failure 永不转成 0/rejected。
- PDF URL 存在不等于读过全文；只有 local extraction + valid anchor 才能升级证据范围。
- caption-only 不等于 Vision；Vision 不等于 PDF 全文证据。
- inference 不等于 direct；missing 不得有伪造 anchor。
- Compare 相邻论文的值不得用于补齐当前论文。
- local/fixture output 不是物理结论证据；人工 rubric 仍需逐项核对 action、ensemble、`a`、`L^3×T`、`m_π`、momentum、`t_sep`、operator、renormalization、Fourier、matching、statistics/systematics。
- 不得把 55 tests、6 个 v2 UI case、Python benchmark、source model、mock graph 或 unsigned archive写成 v3/v4 完成。
- 不得为了通过测试降低 byte bounds、跳过 migration backup、关闭 validator 或把失败状态改成 success。

一句话验收标准：**v4 只有在真实 normalized SwiftData 用户库可恢复、Radar 变化语义正确、Compare 每个物理 cell 能回到同论文原证据、Notebook annotation/导出事务真实、v3/v4 UI case 在 fixture-isolated `.app` 中实际执行，并能在同一台 Mac 上安装回滚时，才可称为 local feature-complete。**
