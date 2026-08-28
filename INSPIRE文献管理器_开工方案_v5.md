# INSPIRE 文献管理器开工方案 v5：v4 严格审计、Reference_manager 1.0 本地最终收口与 GPT-5.6 Terra 执行说明

> 文档角色：这是交给 GPT-5.6 Terra 的最终施工与验收说明，不是“当前已经完成 1.0”的声明。
>
> 目标平台：macOS 14+，原生 SwiftUI / SwiftData / PDFKit，本机（local-only）实现与发行。
>
> 产品名：`LatticeLens`；本方案所称 `Reference_manager 1.0` 对应 `LatticeLens 1.0.0`。
>
> 审计日期：2026-08-26；审计目录：本文件所在的 `Reference_manager` 项目目录。

## 0. 给 GPT-5.6 Terra 的第一指令

你接手的不是一个“再加几项测试即可发布”的工程。v4 已经建立了相当多的 local contract 和短 fixture UI 证据，但仍有会破坏数据正确性、科研证据边界、长列表可达性、迁移回滚和本地安装的结构性缺口。

请按以下顺序完成工作：

1. 先重跑/复核本方案列出的 v4 缺口，不得把当前 README、checklist、测试名或历史 `.xcresult` 当成完成事实。
2. 先为每个 P0 缺口增加能够失败的 regression test，再修生产代码；不得为通过测试降低 validator、byte limit、事务性或 UI 可达性要求。
3. 完成 normalized persistence、同步任务、PDF ownership、Radar、Compare、Notebook、Research Bundle、local LLM profile 和 UI 滚动可达性。
4. 冻结最终 build inputs，生成 1.0 版本信息、AppIcon、universal Release app、ad-hoc local signature 和只读 `.dmg`。
5. 在可丢弃资料库副本上完成 migration / backup / restore / app rollback 演练；绝不直接把真实 active library 当测试数据。
6. 固化唯一的机器摘要和人工验收记录，然后按白名单清理旧 scratch、重复 release、重复 `.xcresult` 和可再生成缓存。
7. 清理后复核最终 DMG、manifest、dSYM 和 source-input hashes；任一 mandatory gate 未通过就保持 `BLOCKED` 或 `FAIL`，不得命名为 `Reference_manager 1.0 final`。

### 0.1 local-only 的准确含义

本方案的 1.0 完成线包含：

- 当前 Mac 上完成 Debug/Release/build/analyze/unit/integration/UI；
- live-shaped INSPIRE fixtures 和完全 process-local 的大列表 UI fixtures；
- 当前 Mac 上的 local OpenAI-compatible endpoint 支持与 deterministic substitute；
- same-Mac universal `.app`、ad-hoc signing、`.dmg`、安装、卸载和回滚演练；
- 可丢弃 library 副本的真实磁盘迁移、备份、恢复和 corruption drill；
- no-network 模式下读取既有资料、搜索、笔记、PDF、Compare 和 Bundle 的人工流程。

下列项目不属于 1.0 mandatory gate：

- Developer ID Application 证书；
- Apple notarization；
- 面向公共下载的 Gatekeeper 通过；
- 跨 Mac 安装；
- CloudKit；
- paid/live LLM provider；
- 依赖当天网络状态的完整 INSPIRE live crawl。

可选的 credential-free INSPIRE short smoke 只能写为 `optional_run` / `blocked_by_network` / `not_run`，不得替代 fixture contract；同样，不得把 local ad-hoc app 写成 Developer ID signed 或 notarized。

### 0.2 不得改变的产品与科研不变量

1. 本人 INSPIRE author recid 固定为 `2010363`，始终显示在作者列表最前面，不受 h-index 门槛影响。
2. 普通候选作者定义为 INSPIRE author record 的 `arxiv_categories` 包含 `hep-lat`；这是当前产品定义，不外推为“历史上发过所有 hep-lat cross-list 的作者全集”。
3. 普通正式作者必须满足 INSPIRE `h(all, including self-citations) > 20`；`20` 不合格，`21` 合格。
4. h-index 请求失败、缺失或过期只能是 `unknown` / `failed` / `stale`，绝不能写成 `0` 或 `rejected`。
5. 本人置顶后，其余作者按可搜索归一化姓名的 A–Z 排序；搜索支持 display name、native name、BAI 和重音/连字符归一化。
6. 论文按 INSPIRE record ID 幂等同步；不得按标题去重；分页只跟随经校验的 trusted `links.next`。
7. 原标题、原摘要和 INSPIRE metadata 是不可被 LLM 覆盖的 source truth。中文标题、摘要翻译、物理解释和重要图像说明都是版本化 derived artifacts。
8. title/abstract/caption、PDF text、Vision image pixels 是不同 evidence scope；存在 PDF URL 不等于读取 PDF，caption-only 不等于 Vision。
9. `direct`、`inference`、`missing`、`caveat` 必须区分；模型自称有证据不能替代本地 validator。
10. Compare 中别篇论文的物理数值不能补成当前论文的 direct value；每个数值与单位必须能回到同论文、同 document hash、同 anchor 局部窗口。
11. API Key 只允许进入 Keychain；不得进入 SwiftData、UserDefaults、日志、截图、Bundle、fixture 或 provenance export。
12. Graph 在 1.0 可以保持 `Preview: no edge ingestion yet`，但不得伪装为完成；完整 edge ingestion 留给 2.0。

### 0.3 工作区与数据安全规则

- 开工前读取当前 README、`Package.swift`、Xcode shared scheme、相邻实现与现有测试。
- 在修改前生成 build-input manifest；保留 v1–v5 方案，不覆盖历史文件。
- 禁止 `git init`，禁止 destructive Git 操作，禁止清空整个项目目录。
- 任何删除先生成 `CleanupManifest-v1.0.json` dry-run；只删除 manifest 中明确允许且 canonical path 位于项目根下的目标。
- 禁止清理 active library、Application Support 中的 store/PDF、Keychain、用户选择的 Research Bundle、当前 `/Applications/LatticeLens.app` 或未验证 backup。
- fixture 必须先显示并由 UI test 断言 `fixtureModeIndicator`；fixture 不得读取用户 library、真实 Keychain、live INSPIRE 或外部 provider。
- 若需要真实迁移演练，必须由用户显式给出“可丢弃副本”路径；没有该路径时 Gate `MIGRATION-DRILL` 为 `BLOCKED`，不能静默改用真实库。

## 1. v4 multi-agent 对打审计与一致结论

本次审计采用两条独立证据链：

- **数据/科研正确性审计**：逐项追踪 persistence、checkpoint、blob ownership、evidence validator、Radar、Compare、Notebook、Search、Bundle 的真实生产数据流，重点反驳“contract/test 名存在即完成”。
- **macOS UI/发行审计**：逐项检查窗口尺寸、滚动容器、长列表选择器、键盘/VoiceOver、版本、资源、签名、archive、DMG、安装和回滚，重点反驳“后台正确即用户可用”。

两位审计者互相提出反驳后没有保留分歧，并与主审达成以下共识：

> **v4 严格判定为 `PARTIAL`，不是 Reference_manager 1.0 final candidate。后台 correctness gate 与 UI/release gate 必须同时通过；任一方通过都不能替代另一方。**

### 1.1 本轮直接证据

- 审计时 `Sources/Tests/Scripts` 聚合 SHA-256：`dd72df978b0c3872539bd46fce271a45f3965cd202a6c014e551185a225d9907`。
- 当前可读 Xcode aggregate：109 total / 108 passed / 0 failed / 1 explicit opt-in skipped，result 为 `Passed`。
- 其中 `LatticeLensUITests`：20 total / 20 passed / 0 failed / 0 skipped。
- 当前 non-UI verifier run ID：`20260825T234536Z-47201`；实际命令为 `zsh Scripts/verify_v4.sh --local-only --skip-ui`。
- 因此当前结论是“同 source hash 的 non-UI verifier + 后续前台 Xcode UI composite evidence”，不是一次 mandatory CLI aggregate 完整执行。
- 最新 local ZIP artifact 的 manifest/hash、universal architectures 和 fixture launch smoke 有证据，但产物是 unsigned ZIP，不是 DMG，也没有完成真实资料库副本安装/回滚。
- 本轮没有读取真实用户 library、Keychain、live provider 或 live INSPIRE，也没有把未运行项写为通过。

### 1.2 为什么 20/20 UI 仍不足以发布

当前 20 个 case 主要证明短 fixture 下入口存在、局部状态可见和部分 contract 可连接；它们没有证明：

- 300+ authors、500+ papers、100 tags、100 collections、200 models、500 Radar events 等长列表的最后一项可达；
- 实际发送 PageDown/Home/End/Tab/Space/Escape/Return 后 selection 和 Inspector identity 不变；
- 820×640 窄窗、1120×700、1440×900 三档布局无 clipped/off-screen action；
- VoiceOver 可以读出状态、页码、证据来源和主要动作；
- Bundle 有用户可操作的产品 UI；
- PDFKit user text selection、Notebook multi-anchor 和 import accepted-field merge；
- Compare 的完整 `physics-contract-v1`、坏 cell 零提交和 exact anchor jump；
- 真实 SwiftData store package 的 V7→最终 schema 迁移与 app/data rollback；
- AppIcon、版本字段、DMG 安装和本机回滚。

### 1.3 v4 逐项复判

状态含义：`PASS` 仅表示目标本身完整；`PARTIAL` 表示存在生产路径但语义/UI/恢复链未闭合；`FAIL` 表示 P0 核心目标尚未实现或有反例；`HONEST_PREVIEW` 表示允许明确降级但不能计作 feature complete。

| ID | v4 复判 | 关键反例 | v5 mandatory closure |
| --- | --- | --- | --- |
| R01 PDF blob lifecycle | **PARTIAL** | shared-delete 已有 refcount/owned path，但 re-download/supersede 未可靠执行旧 blob cleanup；orphan 无 retry worker；plan 与 mutation 不是单一原子边界 | 统一 `BlobMutationPlan`；commit 后按 refcount 清 file；orphan journal + retry；真实双论文共享文件 test |
| R02 checkpoint / generation | **FAIL** | author/page/checkpoint/generation 独立 mutation；retryable 可在 `complete()` 后被清空和封死；恢复 queue 不严格只来自 pending/retryable | 同 generation 原子计数；pending/retryable 非空禁止 active switch；每 page/h item crash injection；relaunch 只重试未完成 ID |
| R03 reference CRUD/export | **PARTIAL** | note 局部改善，但 tag/collection rename 无完整产品 UI；删除文案/链路数仍不可靠；export success 与实际 file callback/ledger 不总是 durable | searchable manager；rename/delete link count；draft Cancel 零写入；export transaction 只在 callback success 后提交 |
| R04 Updates/Sync Center | **PARTIAL** | 当前只显示 coarse summary；缺完整 jobID/generation/count/diff；job owner 主要是 process-local，终止后的 durable semantics 未证明 | durable job rows、单 owner、progress/cancel/resume/relaunch；50 jobs 长列表 UI |
| R05 LLM run state | **PARTIAL** | timeout/late callback contract 有进展，但 Evidence/Vision 仍存在旧状态路径；current/last-success provenance 和 model discovery cache/invalidation 不完整 | 所有 AI workflow 统一 `AnalysisRunState`；owner/cancel/cache revision；失败保留 last success |
| R06 scientific validator | **FAIL** | `crossPaperInference` 可绕 same-anchor value+unit；未强制当前 paper context anchor + foreign value anchor；quarantined/stale/document hash 过滤不完整 | 完整 truth table；active document hash；same-paper direct/inference；cross-paper 显式双 anchor + origin paper UI |
| R07 network/disclosure | **PARTIAL** | 多数 path bounded/ephemeral，但 endpoint-class redirect、effective port、userinfo/path/auth matrix 不完整；兼容 PDF 入口可能绕 preflight | 唯一 bounded loader；每 endpoint class redirect policy；所有发送前 frozen disclosure；无旁路 API |
| R08 active persistence | **FAIL** | 多数 mutation 仍从全量 `LibrarySnapshot` materialize/persist；V7 row 仍含 generic `payload: Data`；search index hot path 全库重建；corruption/migration resume 不闭合 | typed normalized final schema；bounded row transaction；独立 backup/journal；V7→final real disk migration；禁止 hot-path snapshot rewrite |
| R09 verifier/UI truth | **PARTIAL** | 可读 `.xcresult` 真实，但 mandatory CLI 运行显式 `--skip-ui`；20 个短 case 不覆盖 relaunch/large-list/resize/scroll/VoiceOver/DMG | 单一 `verify_v5.sh --local-only`，不可 skip mandatory UI；large fixture + readable result + DMG smoke；自动生成 ledger |
| R10 Radar semantics | **FAIL** | production author/query sync 仍可写 legacy `V3RadarDiff` 错误事件和 V4 semantic event 两套；document/figure change 可被写成 `new` | 只保留一种 item-level added/removed/modified event；field hashes、dedup、ack、relaunch；禁止双写 |
| R11 Compare | **FAIL** | 目前主要是少量 local rules + 可手填 matrix；无完整 frozen per-paper LLM contract、rejected report 和原子 workspace 管理 | `physics-contract-v1`；2–6 papers；per-paper frozen scope；全矩阵 validator；任一坏 cell 零提交；exact anchor/PDF jump |
| R12 Notebook | **FAIL** | annotation 不是 PDFKit user text selection；无真正 `NotebookEntry + multi-anchor links`；import accept/reject 未执行用户确认字段的 merge | selection range/quote/hash/page；multi-anchor entry；accepted fields transaction；stale relocation；真实 import/export UI |
| R13 Graph | **HONEST_PREVIEW** | UI 明示 `Preview: no edge ingestion yet` | 1.0 保持 preview 且不计 PASS；把 edge-ingestion contracts/fixtures 留作 2.0 |
| V4-1 Local Search | **PARTIAL** | 生产查询/Mutation 仍频繁从全 snapshot rebuild；增量 token repository 和 annotation index 不完整 | typed FTS/token index；changed-ID update；20k real store benchmark；index 可删可重建 |
| V4-2 Home/Inbox | **PARTIAL** | counts 有 projection，但 metrics 不都可点击；reading priority/workflow mutation、recent records 和 active jobs 不完整 | store queries 驱动；每个 count 可进入 records；durable inbox/reading/done/archived；长列表可滚动 |
| V4-3 Research Bundle | **FAIL** | 目前近似 `library.json + manifest` contract；无产品 UI；restore 未建立并语义验证新的 staging SwiftData store | UI export/import/read-only；verify→dry-run→staging store→semantic verify→atomic activation；active library 永不覆盖 |
| V4-4 Local profile | **FAIL** | Release 没有正式 `Local OpenAI-compatible` no-key profile；loopback HTTP、health/models、discovery UI 未闭合 | Release 允许严格 loopback HTTP/HTTPS；no-key default；health/models/completion 分离；明确 `Local process not bundled` |

### 1.4 v4 仍然成立、不得回退的基础

Terra 不应重写已经有效的全部工程。以下能力应保留并加 regression test：

- Swift 6 strict concurrency / warnings-as-errors build baseline；
- author recid、hep-lat、h-index 门槛与 unknown/stale 语义；
- trusted pagination、record-ID upsert 和 live-shaped fixture；
- bounded stream、SSE no silent retry、Keychain 和 request provenance 的现有正确部分；
- current readable `.xcresult` 抽取、private process-group timeout/cleanup 的 verifier 思路；
- fixture-mode isolation；
- shared PDF refcount、analysis timeout、semantic diff、search、bundle 等现有 contract 中已经正确的子集；
- Graph 的诚实 preview 文案。

## 2. Reference_manager 1.0 的产品完成定义

1.0 的最小完整用户闭环是：

```text
作者索引与搜索
  → 本人置顶 / h(all)>20 的 hep-lat 作者 A–Z
  → 选择作者并可靠同步论文
  → Library / Updates / Favorites / Needs Review
  → 选择论文并查看原文 + 中文标题 + 摘要翻译
  → 阅读 PDF / figures / evidence anchors
  → 生成可回溯的物理解释和重要图像说明
  → Radar / Compare / Notebook / local search
  → 导出 Research Bundle
  → 退出、重启、安装新 app、恢复或回滚，数据仍然正确
```

以下均为 1.0 P0：

- v4 R01–R12 的全部 closure；
- V4-1 Search、V4-2 Home、V4-3 Bundle；
- V4-4 local profile 的用户可用路径；
- 长列表 scrollbar/keyboard/selection/resize/VoiceOver；
- AppIcon、1.0 version/build metadata、universal Release app、local DMG；
- migration/backup/restore/app rollback；
- 最终 cleanup 和可复现 evidence。

可留给 2.0：

- Graph edge ingestion 和大图交互；
- CloudKit/多机同步；
- Developer ID/notarization/public distribution；
- 内置 local model runtime；
- 多用户/团队协作；
- 需要公网 provider 或大型 corpus 才能验证的增强语义功能。

## 3. 最终数据架构：typed normalized store 是唯一 active truth

### 3.1 最终 schema

不要继续用 generic payload row 或全量 Codable snapshot 驱动业务。可以将最终 schema 命名为 V8（若代码已经占用 V8，则顺延版本号），但语义必须满足：

- `StoredAuthor`
- `StoredHIndexSnapshot`
- `StoredPaper`
- `StoredPaperAuthorLink`
- `StoredSyncCheckpoint`
- `StoredAuthorIndexGeneration`
- `StoredSyncJob`
- `StoredSyncBatch`
- `StoredRevisionSnapshot`
- `StoredRadarEvent`
- `StoredContentBlob`
- `StoredDocumentReference`
- `StoredEvidenceChunk`
- `StoredEvidenceAnchor`
- `StoredUserAnnotation`
- `StoredAIArtifact`
- `StoredProviderRunProvenance`
- `StoredTag` / `StoredPaperTagLink`
- `StoredCollection` / `StoredPaperCollectionLink`
- `StoredReferenceRecord`
- `StoredWorkspace` / `StoredWorkspacePaperLink`
- `StoredPhysicsContract` / `StoredPhysicsCell`
- `StoredNotebookEntry` / `StoredNotebookAnchorLink`
- `StoredImportRecord` / `StoredImportConflict`
- `StoredExportTransaction`
- `StoredReadingWorkflowState`
- `StoredSearchIndexState`
- `StoredBundleRecord`
- `MigrationJournal`
- `StoreBackupManifest`

允许保留 versioned Codable snapshot 作为 fixture、export、compatibility import 或 backup 表示，但它不能参与正常单行 mutation/read 的 active path。

### 3.2 repository 与事务边界

必须提供按 stable ID 的 typed repository API。至少证明：

- mark read/favorite；
- note create/update/delete；
- tag/collection create/rename/link/unlink/delete；
- annotation create/edit/delete；
- paper metadata upsert；
- sync checkpoint/page commit；
- Radar event append/ack；
- Compare matrix atomic replace；
- import accepted fields merge；
- PDF reference/blob retirement；
- local search changed-ID index update。

每项 mutation 的 test/benchmark 记录 fetched rows、written rows、index rows touched 和 transaction count。单 note/read mutation 不得 decode/encode 20k paper snapshot，不得 fetch/delete/reinsert 整表，也不得重建全库 search index。

### 3.3 final migration coordinator

打开最终 schema 前执行：

1. 获取 store package 的稳定状态，不在 active writer 运行时盲复制。
2. 将 store、WAL/sidecars 和必要 blob metadata 复制到新的 timestamped backup 目录。
3. 写 `StoreBackupManifest`：source path category、schema、app version、file sizes、per-file SHA-256、createdAt；不得记录私人绝对路径到导出物。
4. 在独立 staging store 中执行 V7→final typed migration。
5. 每一 phase 写外置 journal：`prepared / copied / migrated / semanticallyVerified / activated / failed / rolledBack`。
6. 核对 pre/post record counts、stable IDs、link counts、semantic hashes、quarantine counts、orphan blobs 和 index rebuild status。
7. 只有 semantic verification 全过才 atomic switch active pointer。
8. crash 后从 journal 恢复或回滚；旧 store package 始终保持可读、不可被半迁移覆盖。
9. corruption 时显示“只读打开 / 恢复到新 library / 取消”，绝不 silent empty 或 silent JSON fallback。

必须对 phase boundaries 注入 crash；测试至少覆盖 copy 后、migration 中、semantic verify 前、active switch 前/后。

### 3.4 real disk benchmark

使用产品 repository 和实际 SwiftData disk store，而不是 Python container 或纯内存 projection，固定生成：

- 2,000 authors；
- 20,000 papers；
- 100,000 author-paper links；
- 100 PDF metadata records；
- 至少 10,000 chunks/anchors；
- 500 Radar events；
- 200 annotations；
- 100 tags / 100 collections。

记录 hardware、OS、filesystem、build configuration、sample count、p50/p95、peak RSS、store bytes 和 index bytes。目标仍为：warm search p95 ≤ 250 ms、single note/read mutation p95 ≤ 100 ms、cold open p95 ≤ 5 s。若未达标，不得偷偷降低数据规模或只报告平均值；Gate 失败并保留数据。

## 4. v4 P0 缺口的最终修复契约

### 4.1 PDF blob ownership 与文件清理

统一 create/download/supersede/delete 为一套 `BlobMutationPlan`：

1. plan 中包含 document ID、old/new blob hash、reference delta、owned canonical relative path 和 cleanup eligibility。
2. store mutation 在一个 transaction 中提交 document/reference/blob/refcount/orphan-journal。
3. 只有 commit 成功且 old blob refcount 为 0，service 才能删 app-owned file。
4. 文件删除失败写 durable orphan record；后台 retry 只处理 canonical root 内、hash/size 匹配的目标。
5. symlink、`..`、绝对 filename、root escape 一律拒绝。
6. re-download 相同 hash 幂等；不同 hash 正确 retire old file；两篇共享旧 hash 时不得提前删除。

集成测试使用真实 temp PDF：两 paper 共用 blob → 删一篇仍可用 PDFKit 打开第二篇 → supersede 第二篇 → 旧 blob 最终清除 → orphan delete failure/relaunch/retry。

### 4.2 candidate generation、h queue 和 literature checkpoint

- author pages、candidate membership、h queue outcomes 和 generation counters 属于同一 generation。
- 新 generation 未 terminal 前继续显示旧 completed generation。
- `pending` 或 `retryable` 非空时禁止 `complete()`、清 queue 或切 active。
- `failed`、`cancelled`、`unknown` 语义分开；pause 保留 pending；cancel 不写 failed。
- 每个 page/h item outcome 与 checkpoint/job event 原子提交。
- process recreation 后只从 durable pending/retryable 构造 queue；不重请求 success/rejected。
- author selection/app start 发现 non-completed checkpoint 时优先 resume，不受旧 freshness 时间戳影响。

故障注入：page 2、h item N、commit 前后、force rebuild、old-freshness + active checkpoint、pause/relaunch、cancel/rebuild。

### 4.3 reference CRUD 与 export transaction

- note editor identity 为 `paperID + noteID`；切 paper 立即取消旧 draft/task，加载新 identity。
- tag/collection 改成 searchable management sheet；支持 create/rename/delete/link/unlink。
- destructive confirmation 显示将解除的 link count；Cancel 零写入。
- collection toggle 必须支持 add/remove，不得只有加入。
- export 状态机固定为 `prepared → presenting → succeeded | cancelled | failed`。
- 只有系统 file exporter completion callback 成功后才写 succeeded ledger，并记录 format、destination category、bytes、SHA-256、paper IDs；不得写绝对路径。
- 任一 authoritative BibTeX 缺失时显示“先获取/跳过/取消”，不得静默输出空记录。

### 4.4 durable jobs、Updates 与 Sync Center

每个 job 具有 stable jobID、kind、generation、owner token、state、counts、last checkpoint、created/updated/finished time、last bounded error。只有一个 owner 可运行同一 job。

Sync Center 必须显示并可操作：author pages、h queue、tracked authors、saved queries、paper sync、fulltext、text/evidence、Vision、Compare extractor、local index、Bundle import/export。app close、untrack、query delete、paper delete 时按 contract cancel 并持久化 terminal state。

Updates 只来自一个 semantic diff pipeline，按 batch 展开 metadata/citation/document/figure 的 added/removed/modified；Favorites 和 Needs Review 是 store query，不是内存临时 filter。

### 4.5 统一 AI run state

Insight、Evidence、Compare、Vision 和 model discovery 使用统一 owner/state：

```text
runID, paperSet, workflowKind, requestIndex/requestTotal,
phase, receivedBytes/chars, elapsed,
connectDeadline, firstContentDeadline, idleDeadline, hardDeadline,
providerProfileRevision, modelID, promptVersion, schemaVersion,
frozenPayloadHash, sourceDocumentHashes
```

current run 与 last successful artifact 分开。fail/cancel/timeout/oversize/late callback 不覆盖 last success；POST 不自动重试；SSE failure 不静默改成 non-streaming。clear preview 必须先显示各 scope 的 artifact counts/paper set，commit 后只记录 count/hash 范围，不记录内容。

### 4.6 科学证据 validator

强制 truth table：

| status | 当前 paper anchor | foreign paper anchor | value+unit | 允许写入 |
| --- | --- | --- | --- | --- |
| `direct` | 必须，同 active document hash | 禁止 | 同一局部窗口必须匹配 | 是 |
| `inference` | 必须，支持推理前提 | 禁止 | 若输出数值，仍需同 anchor 支持 | 是，UI 标 inference |
| `cross_paper_inference` | 必须，说明当前 paper context | 必须，提供 foreign value origin | foreign value/unit 同 foreign anchor；不得改标 direct | 是，UI 同时显示两篇来源 |
| `missing` | 禁止伪 anchor | 禁止 | 无值 | 是 |
| `caveat` | 若陈述可核验事实则必须 | 视陈述而定 | 适用时校验 | 是，UI 标 caveat |

全局拒绝条件：duplicate evidence ID、cross-document mismatch、quote hash mismatch、inactive document hash、quarantined/stale anchor、unsupported source scope、无法定位的 page/range、部分 matrix 验证失败。

numeric corpus 覆盖 signed/scientific notation、parenthesized uncertainty、`±`、区间、百分比、`L^3×T`、`a^{-1}`、`GeV^2`、`fm^{-1}`、ensemble count、fit range、source-sink separation；年份、reference number、equation label、page number 是 false-positive corpus。

### 4.7 唯一 bounded network layer 与发送前 disclosure

- INSPIRE JSON/facet/BibTeX/PDF/figure 与 LLM request 使用 app-owned bounded transport；禁止绕过 preflight 的 compatibility downloader。
- redirect 每跳验证 scheme、exact host、effective port、userinfo、query/fragment、path class 和 auth forwarding；Authorization 永不跨 origin。
- PDF 在 GET 前显示 URL origin、Content-Length estimate（若有）、hard limit、cache category；完成后显示 bytes/hash/pages。
- Vision 先本地下载/缩放并冻结，再展示 figure keys、原始/发送尺寸、逐图/总 bytes、endpoint、request count、payload hash；Accept 只绑定该 hash。
- `maximumFigures=0` 时 UI disabled，payload image count=0，provider request count=0。
- 任何 disclosure 使用可滚动 sheet，不使用可能截断长内容的 Alert。

### 4.8 Radar、Compare、Notebook 与 Bundle

Radar：

- 生产代码只能调用一套 semantic diff；移除 legacy 双写。
- canonical item sets 产生 `added/removed/modified`；citation unknown 与 0 分开。
- event 保存 bounded before/after field hashes/diff、paperID、batchID、source/fetchedAt。
- dedup key = paper + field/item + event kind + before/after hashes。
- acknowledge、pause、cancel、relaunch 后状态持久。

Compare：

- workspace 限制 2–6 papers，支持 rename/delete/reorder/note/frozen export。
- deterministic local extractor 只能提取明确格式；无法确认就 `missing`。
- local LLM path 使用严格 `physics-contract-v1`；每篇 paper 绑定 frozen chunks/bytes/hash、anchor allowlist 和 active document hash。
- response 全部通过本地 validator 后，在一个 transaction 中 atomic replace matrix；任一坏 cell 保留旧 matrix并生成 rejected report。
- 每个 cell 可以精确跳转 abstract/caption/PDF page/quote，不只打开论文顶层。

Notebook：

- PDFKit user text selection 与 abstract/caption selection 创建 annotation；保存 exact range、quote/hash、page、paper/document、label/color/note。
- document 更新只允许 unique exact relocation；否则 stale，不做 silent fuzzy move。
- `NotebookEntry` 可链接多个 annotation/evidence anchor，稳定排序并可点击。
- import 先 bounded parse/dry-run，再显示 match/conflict；Accept 只事务性合并用户确认字段，Reject 不改变 paper。
- Markdown/provenance export 默认不含绝对路径；取消/失败不记 success。

Research Bundle：

- 提供真实 UI：export、inspect/read-only、import dry-run、restore to new library。
- manifest 记录 schema/app version、record counts、per-file SHA-256、是否包含 PDF。
- 默认排除 Keychain、endpoint、logs、raw LLM response、绝对路径和 PDF bytes；PDF 仅显式选择并先显示总 bytes。
- import 流程固定为 verify hashes/schema → dry-run counts/conflicts → new staging typed store → semantic verify → atomic activation。
- active library 永不原地覆盖；tamper、partial archive、duplicate IDs、older schema、cancel、disk-full/failure 均保持旧库不变。

## 5. 1.0 最终界面：Local Research Cockpit

建议把 Evidence Workbench 从孤立大 sheet 收回稳定 product navigation。宽屏布局：

```text
┌ NAV ───────────┬ AUTHORS / LIBRARY ────────────┬ READER / COMPARE ─────────────────┬ EVIDENCE INSPECTOR ───────┐
│ Home        8  │ [作者搜索………………]               │ 中文标题（主）                      │ direct / inference / missing│
│ Authors        │ ★ Zhao, Dian-Jun  (固定)        │ English title（始终同屏）            │ paper/source/hash           │
│ Library        │ ─── A–Z 可滚动作者列表 ───       │ [概览][物理][图像][全文][证据]        │ quote/page/[跳转]           │
│ Radar       5  │ Papers / Updates / Favorites   │ PDF / physics matrix / notebook     │ stale/validated/local       │
│ Compare     2  │ Needs Review + 可滚动论文列表    │ 独立可滚动正文                       │ [加入 annotation]           │
│ Notebook    3  │                                │                                  │ extraction/schema version  │
│ Sync Center   │                                │                                  │ Activity Shelf（固定底部）  │
└───────────────┴────────────────────────────────┴──────────────────────────────────┴───────────────────────────┘
```

窗口宽度 `<1120` 时 Inspector 变 trailing sheet；`1120` 是 preferred breakpoint，不是硬 minimum。hard minimum 建议 `820×640`。本人卡片和作者搜索始终可见，普通 A–Z 作者列表独立滚动。

中文标题作为主要阅读标题，英文标题始终同屏可见；摘要原文与翻译可以左右或上下对照。物理解释每个段落显示 status、source scope、model/prompt/schema、document hash 和 evidence chips。重要图像区域显示 thumbnail、原 caption、中文 caption、为什么重要、source/figure key；未启用 Vision 时明确写 `caption-only`。

## 6. 所有长列表/选框的 scrollbar 与可达性契约

### 6.1 全局规则

1. 使用原生 macOS scroll container，不绘制纯装饰滚动条。
2. 关键长列表使用 `.scrollIndicators(.visible)`；若目标 macOS 的 SwiftUI `List/ScrollView` 仍受系统 auto-hide 影响，则为这些 region 封装 `NSScrollView`，设置 `hasVerticalScroller/hasHorizontalScroller = true`、`autohidesScrollers = false`。
3. 每个滚动 region 有独立 accessibility label、稳定 row ID 和 keyboard focus，不得把整个复杂页面塞进一个无边界滚动区。
4. header/search/filter 和 destructive/apply actions 固定；只让中间数据区滚动。长错误/说明正文可滚动，但 `Cancel/Apply/Send/Save` 永远可见。
5. 所有 selection 使用 durable ID，不使用数组 offset。
6. search/filter 隐藏当前 selection 时显示“当前选择被过滤”，不得自动选择第一项。
7. store refresh 后若 ID 仍存在，保留 selection 与 scroll anchor；若已删除，显示明确空状态。
8. sheet/popover 使用 draft state；Cancel 不提交，Apply 才写 store。
9. first/last row 必须可通过 scrollbar、trackpad、PageUp/PageDown、Home/End 和 keyboard focus 到达并 hittable。
10. 状态不得只靠颜色；同时显示 text/icon 并支持 VoiceOver。

### 6.2 scrollbar matrix

| Surface | 1.0 实现 | Mandatory large-fixture acceptance |
| --- | --- | --- |
| Authors | self card + search 固定；普通作者 A–Z 独立 `List`；可见垂直 scrollbar；字母 jump rail | 300+ authors；本人始终可见；name/native/BAI 搜索；PageDown 到 Z；清除搜索不丢 selection |
| Papers | search/filter/status 固定；paper list 独立滚动 | 500+ papers；首末项可达；filter 前后已选 paper 不被静默替换 |
| Overview / Physics / Source | 每个 tab 独立 vertical ScrollView；Activity Shelf 固定；保存 `paperID + tab` scroll state | 20k-char abstract/translation；Home/End；切 tab/论文不串 state |
| Figures | 左 figure List 与右 caption/analysis 各自滚动；preview sheet 可滚动 | 100 figures + 长 caption；最后 figure 可选；右侧到末尾 |
| Evidence / PDF | anchor List 有 scrollbar；PDFKit continuous vertical scroll + 原生 zoom/page controls | 200 anchors；keyboard 到末 anchor；PDF p.1/p.N jump；VoiceOver 宣告页码 |
| Tags / Collections | 废弃长 `Menu`；searchable management sheet；固定 search/header/footer，中间 checkbox List 滚动 | 100 tags + 100 collections；Space toggle；末项 rename/delete；Cancel 零提交 |
| Settings models | discovered models 改 searchable popover/sheet + bounded List；saved model 用 selected chip 保留 | 200 models；搜索排除当前项仍显示 saved selection；末项可达 |
| Terminology | input/actions 固定；terms bounded List 滚动；Save/Cancel sticky | 500 terms；末项 edit/delete；重开 identity 正确 |
| Research Home | 整页 vertical ScrollView；Reading Inbox 为 bounded-height List；主要导航动作固定 | 820×640 + 50 inbox；所有 metrics/action 可达且可进入 records |
| Sync Center | title/filter 固定；job List 滚动；全局动作固定 | 50 jobs + 长 error；每行 Cancel/Resume 键盘可达 |
| Radar | saved queries 与 events 分栏，各有独立 scrollbar；diff/Inspector 可滚动 | 100 queries / 500 events；长 before/after；ack 后 selection 不跳 |
| Compare paper/workspace chooser | searchable selection sheet；selected chips 固定；不用无限 Picker | 1000 papers / 100 workspaces；最后一项可选；2–6 chips 始终可见 |
| Compare matrix | 横纵 scrollbar 始终可见；首行/首列 sticky；Inspector 独立滚动 | 6 papers × 全 rows；末列/末行可达；scroll 后 cell identity 保留 |
| Notebook | split/tabs：papers、imports/conflicts、annotations 各自 List；editor 独立滚动 | 500 papers / 200 annotations / 100 conflicts；末项 edit/delete/accept/reject |
| Graph Preview | paper/author Picker 改 searchable selection sheet/List | 20k papers / 2k authors；按 recid/name 搜索；末项可选；仍显示 preview 边界 |
| PDF/Vision/AI preflight | Alert 改 sheet；totals/hash/endpoint 和 Cancel/Send 固定；payload items ScrollView | 50 figures、长 endpoint/byte list；首末项可读；Send 始终可见 |
| Editors/error detail | 长 quote/note/error body 可滚动；Cancel/Save sticky | 820×640；Tab 顺序、Esc、Return；关闭/重开不显示前对象 draft |

### 6.3 responsive、keyboard 与 accessibility

至少测试 `820×640`、`1120×700`、`1440×900`。删除 app 和 Workbench 对 `minWidth: 1120` 的硬限制；窄窗采用 column collapse / Inspector sheet，不能把 action 推到屏幕外。

快捷键建议：

- `⌘K`：Unified Local Search；
- `⌘⇧A`：将当前 selection 加入 annotation；
- `⌘⇧C`：加入 Compare；
- `⌘Return`：打开 source；
- `Esc`：取消当前 draft/task；
- `Space`：toggle checkbox/read/favorite（在相应 focus region）；
- `PageUp/PageDown/Home/End`：实际作用于 focused scroll region。

VoiceOver manual script 是 1.0 P0，不再留作 P1。必须检查：本人置顶、作者/论文选择、tab、状态、PDF 页码、evidence status/source、Compare cell、sticky actions、preflight totals、错误和回滚提示。Accessibility Inspector 必须零缺失主要 label、零仅颜色状态。

## 7. LLM 设置、中文分析与物理展示

### 7.1 设置界面

实现时可参考同一 Mac 上 `Speech2AI` 项目的 provider settings、model discovery、streaming progress 和参数布局，但只能复用交互思想/可公开代码结构：不得复制 credential、用户配置、日志或项目私有数据。

最终 profile 至少包含：

- `Local OpenAI-compatible`（1.0 推荐默认）；
- OpenAI-compatible remote profile（代码可保留，live 不是 mandatory）；
- Base URL；
- model ID / searchable discovered models；
- API Key required/optional indicator；
- streaming capability；
- temperature、max output tokens、timeout policy；
- Fast / Deep；
- important figures maximum `0/3/5`；
- caption-only / Vision 明确开关；
- “Test connection”和“Discover models”分离。

Local profile 在 Release 中只允许 `localhost`、`127.0.0.1`、`::1` 的 HTTP/HTTPS，默认 no-key；需要 token 时仍只进 Keychain。UI 固定显示 `Local process not bundled`，不得声称 LatticeLens 内置模型。OpenAI-compatible 没有通用 health endpoint 时，`GET /v1/models` 可作为 connection/discovery probe；若支持独立 health path，应是显式配置且同样受 loopback/size/timeout policy 约束。

### 7.2 论文分析展示

对选中论文生成四组不可混写的 derived artifacts：

1. **中文标题**：忠实翻译；与英文标题同屏；禁止扩写论文结论。
2. **摘要翻译**：逐段映射原摘要；原文可一键对照；缺 abstract 时明确 missing。
3. **物理解释**：研究问题、方法/格点设置、主要结果、系统误差/限制、与用户研究方向的关系；每项使用 direct/inference/missing/caveat 和 evidence chips。
4. **重要图像**：figure key、thumbnail、原 caption、中文 caption、重要性说明、source scope；Vision 未运行时只能基于 caption，不能描述未见像素内容。

建议 Paper Lens 顶部显示固定 provenance strip：

```text
[Local/Fixture/Remote] [model] [prompt/schema] [source scope]
[paper recid] [document hash] [generatedAt] [validated/rejected/stale]
```

任何 validator rejection 显示 bounded rejected report，保留上次成功 artifact，不显示半成品为 current truth。

### 7.3 LQCD 人工 rubric

至少选择 3 篇 sanitized LQCD fixture papers，逐项核对：action、ensemble、`a`、`L^3×T`、`m_π`、momentum、source-sink separation、operator、renormalization scheme/scale、Fourier convention、matching、statistics/systematics。人工记录必须区分：

- 原始 title/abstract/caption/PDF anchor 直接支持；
- 合理推断；
- fixture 不足、尚未验证。

这个 rubric 证明 UI/provenance/validator 行为，不证明模型对任意论文的物理解释都正确。

## 8. AppIcon 设计：Lattice Lens

### 8.1 视觉概念

图标表达“格点 QCD + 文献检索 + 阅读收藏”，不使用文字，不使用 INSPIRE 官方 logo，不使用具体实验/合作组标志。

- 背景：macOS rounded-square / squircle，深靛蓝到科研蓝的轻微对角渐变。
- 格点：3×3 cyan lattice nodes 与细 links，代表 lattice 和文献关系网络。
- 主体：中央偏右的暖金色 magnifying-lens ring，形成清晰视觉焦点。
- 镜内：一张极简白色 paper/page，最多两条短横线；页面折角只在大尺寸出现。
- 镜柄：向右下延伸，末端轻微 bookmark 形，暗示阅读和收藏。
- 小尺寸：16 px 只保留四个 lattice nodes、lens ring 和 handle；移除细网格、paper lines 和折角。

推荐色值：

| Token | Hex | 用途 |
| --- | --- | --- |
| Deep Indigo | `#111A3A` | 背景暗部 |
| Research Blue | `#2458A6` | 背景亮部 |
| Lattice Cyan | `#45D7E8` | nodes/links |
| Lens Gold | `#F5B94C` | lens/handle |
| Paper White | `#F7FAFF` | paper |
| Ink Blue | `#20325B` | paper 短线/局部阴影 |

1024×1024 master 的有效图形保留约 12% safe margin；master 中关键 stroke 不小于 32 px。不要只把 1024 图机械缩小：为 16/32/128 px 做 optical correction，增强轮廓、减少节点/细节、避免 Finder 深浅背景下糊成一团。

### 8.2 必须交付的 icon 资产

- editable vector/master source（例如 `AppIcon-master.svg` 或等价源文件）；
- deterministic render script；
- `Assets.xcassets/AppIcon.appiconset/Contents.json`；
- macOS 16/32/128/256/512 的 1x/2x PNG，1024 作为 512@2x，禁止 upscale；
- 16/32/128/512 contact sheet；
- icon validation summary，列出像素尺寸、alpha、hash 和 asset catalog build result。

built app 必须实际包含 `Contents/Resources/AppIcon.icns` 或 asset catalog 等价产物；Finder、Dock、About panel 和 mounted DMG 中均显示该 icon，不能回退到 generic app icon。Xcode Resources/build settings 和最终 build-input hash 必须覆盖 assets。

## 9. 版本、DMG、安装和回滚

### 9.1 版本与 build provenance

- `MARKETING_VERSION = 1.0.0`
- `CURRENT_PROJECT_VERSION = 100`
- `CFBundleShortVersionString = 1.0.0`
- `CFBundleVersion = 100`
- bundle ID 保持 `org.latticelens.app`
- minimum macOS 明确记录为当前实际 target（现为 macOS 14.0），不得只写 README 不写 bundle metadata。

最终 source/build-input hash 至少覆盖：

- `Sources/`
- 核心 `Tests/` 与保留 fixtures
- 最终 `Scripts/`
- `Package.swift`
- `LatticeLens.xcodeproj/project.pbxproj`
- shared scheme
- Assets/AppIcon/resources
- version/config/entitlements

hash manifest 必须按相对路径稳定排序，记录 file SHA-256；不得继续只 hash `Sources/Tests/Scripts`。

### 9.2 DMG 设计

最终文件：`Release-1.0.0-local/LatticeLens-1.0.0-local.dmg`。

DMG volume 名称：`LatticeLens 1.0`。Finder window 建议 660×420、icon size 128 px：左侧 `LatticeLens.app`，右侧 `/Applications` alias，中间简洁箭头；背景沿用 deep indigo / cyan 视觉，但安装说明和可访问信息不得依赖背景图文字。

`Scripts/package_v1_local_dmg.sh` 必须：

1. 拒绝覆盖既有 output；需要重跑时使用新的 staging/run ID，最终由明确 promotion 选择唯一产物。
2. scratch 只在项目内本轮唯一目录，trap 只清自己创建的目标和进程。
3. 生成 Release universal app，并验证 executable 同时包含 `arm64`、`x86_64`。
4. 生成 dSYM；确认 UUID 与 binary 匹配后压缩。
5. 对 app 执行 ad-hoc local signing：`codesign --force --sign - --timestamp=none`，再执行 `codesign --verify --deep --strict`。
6. manifest 明确写 `signature_class=ad_hoc_local`、`developer_id=false`、`notarized=false`，禁止 overclaim。
7. 创建 staging、`Applications` symlink 和 Finder layout，再用 `hdiutil` 生成只读 UDZO DMG。
8. `hdiutil verify`；只读 attach；在 mount 中重新核对 app version/build、architectures、icon resource、signature 和 hashes。
9. 将 app 复制到项目内 user-selected inspection directory，使用 fixture/no-network 参数启动并做 smoke；只终止本脚本启动的 PID。
10. detach volume，验证无 mounted/staging/temp app 残留；记录 DMG SHA-256。
11. 运行 `spctl` 并诚实记录结果；local ad-hoc 可能被公共 Gatekeeper policy 拒绝，不得用 `xattr -dr` 掩盖。

### 9.3 实际安装、卸载与回滚演练

安装前检测 `/Applications/LatticeLens.app` 是否存在；不得静默覆盖。人工 gate 中让用户选择：保留旧 app 并重命名、取消、或在已验证 backup 后替换。

安装验收：

- 从 DMG 拖到 `/Applications`；
- 启动并确认 About/version/icon；
- no-network 浏览作者缓存、搜索、note、PDF、Compare、Notebook、Bundle；
- 退出/relaunch，确认 persisted state；
- 检查没有意外 live request、Keychain 导出或 active library overwrite。

rollback 不是“换回旧 app”这么简单：

1. 若 1.0 未迁移 store，只需退出 1.0、移走 1.0 app、恢复旧 app，确认旧库可读。
2. 若 1.0 已迁移 store，必须先验证 pre-migration backup manifest/hash，再把旧 store 恢复到一个新的明确 target，最后由用户选择 active library；不得让旧 app 直接打开半迁移/新 schema store。
3. rollback drill 使用可丢弃副本；记录 old/new schema、counts、hashes、quarantine、app versions 和结果。
4. uninstall 默认只删除 app，保留 Application Support/library/PDF/Keychain。
5. full purge 只能作为单独人工步骤，必须先导出/验证 Research Bundle，并逐项列出将删除的用户数据；不纳入自动脚本默认行为。

`INSTALL_AND_ROLLBACK.md` 必须让不看源码的用户也能按步骤完成安装、保留旧版本、恢复数据、卸载 app 和识别 local ad-hoc 边界。

## 10. 测试与单一最终 verifier

### 10.1 必须新增的 regression/integration tests

- PDF shared blob delete/supersede/orphan retry/root containment；
- candidate page/h-item crash、retryable non-complete、old-generation visibility、relaunch exact queue；
- bounded typed row mutation 与 index rows touched；
- V7→final migration、phase crash、backup hash、semantic verify、rollback/corruption read-only；
- note identity、tag/collection rename/delete/link count/draft cancel；
- export prepared/cancelled/failed/succeeded callback；
- all AI workflow timeout/cancel/late callback/current-vs-last-success；
- evidence truth table、active document hash、cross-paper double anchor、quarantine/stale；
- signed/scientific/uncertainty/range/lattice units 和 false-positive numeric corpus；
- endpoint-class redirect/port/userinfo/query/path/auth matrix；
- Radar single-pipeline added/removed/modified/dedup/ack/relaunch；
- Compare frozen preflight、one-bad-cell zero commit、old matrix retained、exact anchor jump；
- PDFKit selection range、multi-anchor Notebook、stale relocation、accepted-field import merge；
- Bundle UI/core tamper/partial/older schema/cancel/staging/atomic activation；
- local provider Release loopback/no-key/discovery/cache invalidation；
- incremental local search and corruption rebuild。

### 10.2 large UI fixture

新增 `LATTICELENS_LARGE_UI_FIXTURE=1`，完全 process-local 生成大列表，不保留真实 PDF/用户数据。每个 XCUITest 先断言 `fixtureModeIndicator` 和 large-fixture sentinel。

UI suite 至少真实执行：

1. self fixed + 300+ author scroll/search/Z selection；
2. 500 papers filter/first/last/selection preservation；
3. 100 tags/100 collections searchable management + Cancel/Apply；
4. 200 models + 500 terminology entries；
5. 50 jobs + long error Sync Center；
6. 100 Radar queries / 500 events + ack/relaunch；
7. Compare 1000-paper chooser / 100 workspaces / 6-paper matrix 双向滚动；
8. Notebook 200 annotations / 100 conflicts；
9. 200 evidence anchors + PDF p.1/p.N；
10. 100 figures + 50-item preflight；
11. 820×640、1120×700、1440×900 resize；
12. PageDown/Home/End/Tab/Space/Escape/Return；
13. scroll 前后 selection、Inspector 和 draft identity 不变；
14. terminate/relaunch temp store 后 CRUD、ack、workspace、note、annotation 状态仍在。

自动化应验证关键 scroll region/scrollbar AX element、首末项 hittable 和 accessibility labels；最终再执行一轮真实 VoiceOver manual script。

### 10.3 单一 mandatory 入口

最终入口固定为：

```zsh
zsh Scripts/verify_v5.sh --local-only
```

1.0 final run 不允许 `--skip-ui`、复用旧 `.xcresult` 或手工把独立 summary 拼成 PASS。可以保留诊断参数，但任何 mandatory stage 被 skip 时总 verdict 必须 `BLOCKED/FAIL` 且退出非零。

最低执行序列：

1. source/build-input manifest；
2. SwiftPM unit/integration；
3. SwiftPM Release warnings-as-errors；
4. Xcode Debug/Release/analyze；
5. Xcode unit test；
6. normal fixture UI；
7. large fixture UI；
8. actual disk SwiftData benchmark；
9. migration/backup/rollback fixture + authorized disposable-copy drill status；
10. Research Bundle staging restore；
11. AppIcon/resources/version verification；
12. package DMG、mount/copy/launch smoke；
13. cleanup audit；
14. final artifact hashes。

机器摘要建议：

```json
{
  "schema_version": "latticelens-verify-v5",
  "product_version": "1.0.0",
  "build_number": 100,
  "local_only": true,
  "run_id": "",
  "build_input_tree_sha256": "",
  "mandatory": {
    "swiftpm": null,
    "xcode_build_analyze": null,
    "xcode_unit": null,
    "ui_normal": null,
    "ui_large_scroll_accessibility": null,
    "typed_store": null,
    "migration_backup_rollback": null,
    "physics_validator": null,
    "radar": null,
    "compare": null,
    "notebook": null,
    "bundle": null,
    "icon_version_resources": null,
    "dmg_smoke": null,
    "cleanup": null
  },
  "manual": {
    "voiceover": null,
    "lqcd_rubric": null,
    "applications_install": null,
    "disposable_library_drill": null
  },
  "optional": {
    "live_inspire": "not_run",
    "live_llm": "not_required",
    "developer_id": "out_of_scope",
    "notarization": "out_of_scope",
    "cross_machine": "out_of_scope"
  },
  "ui_cases": [],
  "benchmarks": {},
  "migration_counts": {},
  "artifact_hashes": {},
  "cleanup_manifest_sha256": "",
  "failures": []
}
```

规则：mandatory bool 任一 false/null、manual P0 任一未完成、unexpected skip、result 不可读、source hash mismatch、cleanup escape、DMG hash mismatch → nonzero；test counts/case names/summary 从 `.xcresult` 自动提取，不手抄。

## 11. 1.0 收口与安全清理

### 11.1 当前审计快照

审计时项目约 33 GiB，其中包括：

- 27 个顶层 `.codex-task-tmp-*`，合计约 32 GiB；
- 10 个重复 `Release-v4-local-final-*`；
- 20 个 `LatticeLens-UIFixture-*`；
- 多份大型 historical/independent `.xcresult`；
- `.build/`；
- `Scripts/__pycache__/`。

这些数字只是 2026-08-26 快照。Terra 清理前必须重新枚举，不能硬编码数量或把 glob 直接交给 destructive command。

### 11.2 cleanup manifest 与执行顺序

先运行 dry-run，生成 `CleanupManifest-v1.0.json`。每项至少记录：relative path、canonical path、type、bytes、symlink status、reason、retention class、allowedToDelete、process-in-use check、optional hash。任何 path 不在 project root、为 symlink escape、进程仍在使用或 classification unknown 时，拒绝删除。

正确顺序：

1. 归类旧 generated artifacts 和 2.0 migration assets；
2. dry-run 清理旧 scratch/重复 binary；
3. 用户/审计确认白名单；
4. 删除旧生成物；
5. 冻结最终 build inputs；
6. 执行最终 test/package/manual gates；
7. 固化 final evidence；
8. 删除本轮 ephemeral scratch、fixture app、mounted DMG；
9. 重新核对 final DMG/hash/tree；
10. 确认无 task-owned background process。

### 11.3 必须保留

- `Sources/`；
- 核心 `Tests/` 和必要 deterministic fixtures；
- `Package.swift`、Xcode project/shared scheme；
- v1–v5 开工方案；
- final README、CHANGELOG、1.0 validation/checklist/benchmark/UI compact summary；
- `Assets.xcassets/AppIcon.appiconset`、icon master、render script、contact sheet；
- `Scripts/verify_v5.sh`、disk benchmark、DMG packager/smoke、安全 cleanup script；
- `Release-1.0.0-local/`；
- 1.0 dSYM；
- 一个 current final `.xcresult`，或经过验证、可独立读取且能追踪 case/attachments 的压缩证据；不得保留多份重复巨型结果；
- compact legacy audit manifests/hashes；不必保留重复旧 app binary/ZIP；
- 2.0 所需的 sanitized schema migration golden stores、expected manifests、tamper/corruption samples 和对应 migration tests。

建议将 2.0 资产明确放在类似目录：

```text
Tests/Fixtures/MigrationLegacy/
├── README.md
├── v5-sanitized/
├── v6-sanitized/
├── v7-sanitized/
├── tampered-manifest/
├── partial-store/
└── expected-manifests/
```

每个 fixture 写生成方式、schema、record counts、hash、是否含虚构/脱敏数据；绝不把真实用户库复制进去。

### 11.4 最终证据固化后允许删除

- 所有确认无进程占用的 `.codex-task-tmp-*`；
- `.build/`、可再生成的 `.swiftpm` cache、`.DS_Store`；
- `LatticeLens-UIFixture-*`；
- `Scripts/__pycache__`；
- historical/independent v4 巨型 `.xcresult`，其 case summary/hash 已固化后删除；
- 重复 `Release-v4-local-final-*`、旧 `.xcarchive`、旧 ZIP/binary payload；
- Release-v2/v3/v4 中可由 manifest/hash 表示的重复 binary；
- 被 v5 最终 summary 替代的重复 benchmark/log/root summaries；
- package staging、mounted DMG、temporary app/inspection copy；
- 本次开发生成、未被 tests/2.0 migration 使用的 fixture PDF/image/store。

### 11.5 永久禁止自动删除

- active library；
- Application Support 中的 paper/PDF/store；
- Keychain；
- user-selected Research Bundle；
- `/Applications/LatticeLens.app`；
- 未验证 backup；
- 任何含真实用户资料的路径；
- 项目根、home、Desktop 或其它宽目录。

最终 `VALIDATION_V5.md` 报告清理前/后 bytes、删除/保留 count、manifest hash、未删除原因和后台进程检查。删除是 1.0 收口 gate，但不能以清理为理由丢掉复现 1.0 或迁移到 2.0 所需的核心证据。

## 12. 推荐施工顺序

### Phase 0 — 冻结与红色测试

- 生成 pre-change build-input manifest；
- 把本方案审计矩阵转为 machine-readable checklist；
- README 先改为 `v4 PARTIAL / 1.0 in progress`；
- 为 R01–R12、scroll matrix 和 package gates 写 red tests。

### Phase 1 — final typed store / migration / blob

- 实现 final normalized schema；
- bounded repositories；
- migration coordinator、backup/restore/corruption UI；
- PDF blob mutation/orphan retry；
- actual disk benchmark。

### Phase 2 — sync / Radar / job ownership

- generation/checkpoint atomicity；
- durable jobs/Sync Center；
- Updates/Favorites/Needs Review；
- 单一 Radar semantic diff。

### Phase 3 — evidence / network / local provider

- 统一 AI state；
- strict physics validator；
- bounded transport/redirect matrix；
- PDF/Vision/Compare preflight sheet；
- local OpenAI-compatible Release profile。

### Phase 4 — Compare / Notebook / Bundle / CRUD

- searchable tag/collection management；
- transactional export；
- `physics-contract-v1` 与 atomic matrix；
- PDFKit selection + multi-anchor Notebook；
- Research Bundle UI 和 staging restore。

### Phase 5 — Local Research Cockpit 与 scrollbar closure

- 820×640 responsive shell；
- 全部 long picker 替换；
- sticky actions、durable selection、keyboard/VoiceOver；
- normal + large fixture UI suite。

### Phase 6 — icon / version / DMG

- AppIcon master/assets/contact sheet；
- 1.0.0/100 metadata；
- universal Release、dSYM、ad-hoc sign；
- DMG verify/mount/copy/launch。

### Phase 7 — manual landing / cleanup / promotion

- disposable library migration/rollback；
- no-network installed-app flow；
- LQCD rubric + VoiceOver；
- safe cleanup；
- 冻结 manifest/hashes；
- 只有所有 mandatory gates 通过才 promotion 为 `Reference_manager 1.0 final local`。

## 13. 1.0 release gates

| Gate | Mandatory evidence | Failure meaning |
| --- | --- | --- |
| G0 Truth | v4 审计缺口都有 regression；README/checklist 自动生成且无 overclaim | 验收台账不可信 |
| G1 Build Inputs | full input hash、1.0.0/100、AppIcon resource、universal binary | 产物 provenance/身份不成立 |
| G2 Build/Test | SwiftPM、Xcode Debug/Release/analyze/unit，0 unexpected skip | 基线不成立 |
| G3 Typed Store | bounded mutations、disk benchmark、index incremental/rebuild | 数据仍不可扩展或 active truth 不唯一 |
| G4 Migration | verified backup、V7→final、crash resume、corrupt read-only、data rollback | 用户库不安全 |
| G5 Sync/PDF | generation/checkpoint、durable jobs、blob lifecycle/orphan retry | 同步或 PDF 可损坏 |
| G6 Evidence | validator truth table、bounded preflight、active document hash | 物理解释不可审计 |
| G7 Workbench | Radar 单语义、Compare atomic、Notebook selection/multi-anchor、Bundle staging | v4 产品目标未完成 |
| G8 UI Reachability | large fixture、visible scrollbar、keyboard、3 sizes、selection、VoiceOver | 用户无法获取完整信息 |
| G9 Manual Physics | 3-paper LQCD rubric，direct/inference/missing 边界正确 | fixture 不能支持科研展示验收 |
| G10 DMG | verify/mount/version/icon/hash/ad-hoc signature/copy/launch | 本地安装产物不成立 |
| G11 Install/Rollback | `/Applications` 安装、旧 app 保留、数据 backup/restore、uninstall 说明实演 | 1.0 不可安全落地 |
| G12 Cleanup | dry-run manifest、白名单删除、final hashes、无 scratch/process | 工程未收口或不可审计 |

所有 gate 通过后，允许的准确命名是：

> `LatticeLens 1.0.0 / Reference_manager 1.0 — final same-Mac local release, ad-hoc signed, not notarized.`

不得缩写成会让人误解为 public/notarized release 的 “macOS release”。

## 14. Terra 最终交付物

预期核心树应接近：

```text
Reference_manager/
├── Sources/
├── Tests/
│   └── Fixtures/MigrationLegacy/       # 仅 sanitized 2.0 migration 资产
├── Scripts/
│   ├── verify_v5.sh
│   ├── benchmark_v5_store.swift|sh
│   ├── package_v1_local_dmg.sh
│   ├── smoke_v1_local_dmg.sh
│   ├── cleanup_v1_generated.sh
│   └── render_app_icon.*
├── LatticeLens.xcodeproj/
├── Package.swift
├── Assets.xcassets/AppIcon.appiconset/
├── AppIcon-master.svg
├── AppIcon-contact-sheet.png
├── README.md
├── CHANGELOG.md
├── VALIDATION_V5.md
├── validation-v5.json
├── v5_completion_checklist.json
├── CleanupManifest-v1.0.json
├── INSPIRE文献管理器_开工方案_v1.md … v5.md
└── Release-1.0.0-local/
    ├── LatticeLens-1.0.0-local.dmg
    ├── LatticeLens-1.0.0.dSYM.zip
    ├── manifest-v1.0.json
    ├── INSTALL_AND_ROLLBACK.md
    ├── CHANGELOG.md
    └── compact-validation/
```

Terra 的最终回复必须逐项给出：

1. v4 strict verdict 与每个 R/V4 ID 的 closure 状态；
2. changed/new/deleted/retained files；
3. final build-input tree hash；
4. 所有命令、exit status、test count、unexpected skip 和 `.xcresult` summary；
5. disk benchmark hardware、dataset、p50/p95/RSS/store bytes；
6. migration/backup/rollback schema、counts、hashes、quarantine；
7. UI case names、large-fixture sizes、scroll/keyboard/VoiceOver result；
8. 3-paper LQCD rubric 的 direct/inference/missing 边界；
9. AppIcon asset/resource/contact-sheet 验证；
10. `.app`/dSYM/DMG/manifest SHA-256、architectures、version/build、signature class；
11. `/Applications` install/uninstall/app+data rollback 演练；
12. live INSPIRE/provider 的 run/not-run/out-of-scope 边界；
13. cleanup before/after bytes、manifest hash、保留的 2.0 assets 和未删除原因；
14. remaining P0/P1 issue IDs。

## 15. 最终验收句

**只有当 typed SwiftData 是唯一 active truth，candidate/h-index 与 PDF blob 生命周期在 crash/relaunch 后仍正确，Radar 只产生一种语义事件，Compare 每个物理 cell 可回到同论文有效证据，Notebook/Bundle 具有真实产品事务，所有长列表和选框在 820×640 下可通过可见 scrollbar 与键盘到达末项，AppIcon/1.0 版本/DMG/安装/数据回滚均在同一台 Mac 上实演，并且清理后仍能复现最终 hashes 时，Reference_manager 才可以宣告 1.0 final local。**
