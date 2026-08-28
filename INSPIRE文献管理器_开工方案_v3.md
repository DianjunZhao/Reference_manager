# INSPIRE 文献管理器开工方案 v3：v2 严格审计、修复清单与 GPT-5.6 Terra 执行说明

> 产品工作名：LatticeLens  
> 文档版本：v3.0  
> 审计日期：2026-08-24（Asia/Shanghai）  
> 工作目录：`~/Desktop/Reference_manager`  
> 目标执行者：GPT-5.6 Terra  
> 本文用途：先修复 v2 未完成的 P0，再实现 v3；本文不是 v2/v3 完成声明

## 0. 给 GPT-5.6 Terra 的第一指令

请直接在当前目录继续实现，不要只做代码审查、界面草图或再写一份计划。执行顺序必须是：

1. 保留 `INSPIRE文献管理器_开工方案_v1.md`、`INSPIRE文献管理器_开工方案_v2.md` 和本文件，不覆盖历史方案。
2. 先建立新的 `VALIDATION_V3.md` 与 `validation-v3.json` 空 ledger，并记录修改前文件 manifest/hash。
3. 先完成本文 `F01–F12` 的 v2 P0 修复，通过 Gate A–G；在此之前不得开始堆叠 v3 UI。
4. 再按 Phase 5–7 实现 `V3-1–V3-5`。P0 与 P1 必须分开，不能用 P1 装饰掩盖 P0 数据正确性。
5. 所有 fixture、mock、local build、live INSPIRE、live provider、GUI、VoiceOver、签名、公证和跨机安装证据必须分栏记录；一个层级成功不得外推到另一个层级。
6. 未获得用户授权和安全提供的 API Key 时，不调用付费/live LLM。API Key 只能进入 Keychain 或子进程环境，不能出现在参数、日志、fixture、截图、Markdown、manifest 或 `.xcresult` 附件中。
7. live INSPIRE 只允许 credential-free HTTPS GET；记录日期、endpoint 类别、HTTP 状态、schema 与漂移边界，不保存不必要的 raw body。
8. 不读取浏览器、通信记录、无关私人目录或凭据；不自动写回 INSPIRE，不自动上传 PDF，不创建团队账户。
9. 当前目录不是 Git repository；不要擅自 `git init`、commit、push、reset 或删除既有文件。
10. 所有 scratch、DerivedData、temporary store 和 result bundle 写入本轮 `.codex-task-tmp-<run>/`，退出时只删除本轮创建的临时项。不得删除既有 `.build`、`Release-v2`、用户资料库或系统 cache。

若环境不足，仍要完成所有安全的本地实现，并将未取得的证据写成 `Blocked`、`Not run` 或 `UNKNOWN`；不得用“代码已写”“build passed”替代运行时验收。

## 1. v2 严格完成判定

### 1.1 总结

**判定：v2 未完成，状态为 `Partial / P0 blocked`。**

当前实现比 v1 有实质进展：真实 nested INSPIRE envelope、typed checkpoint、`.xcodeproj` macOS app target、`XCUIApplication` fixture suite、SwiftData V2 schema、PDFKit page anchors、`paper-insight-v2`、Vision mock path、read/favorite/note/tag/collection 基础数据结构和 unsigned `.app` archive 都已出现。2026-08-24 的当前源码也通过了 41 个离线 XCTest 与本地 build/analyze gate。

但是，v2 方案要求的若干核心语义没有实现或没有被现有测试触及：

- 全文 chunk/anchor ID 不包含 paper/document scope，可能跨论文碰撞；删除一个 PDF 还可能按相同 hash 删除另一篇论文的 chunks/artifacts。
- partial paper sync 每成功一页就更新 author `lastSyncedAt`，重启后可能把未完成 checkpoint 当作 fresh，从而不自动继续。
- `CitationSnapshot`、`SyncBatch` 与 `citationChangedRecords` 只有模型/投影，没有生产写入路径；“更新中心”并未形成。
- BibTeX 只有 service 和 mock test，没有 app 入口、用户选择的导出位置或 UI 验收。
- global search 选中的论文仍把当前 sidebar author 传给 detail upsert，可能产生错误的 paper-author link。
- note 编辑 UI 没有稳定绑定当前 paper/existing note，可能重复创建 note，切论文时还可能保留旧 `@State` 文本。
- Markdown export 的 tag 行写成了字面量 `(tags.joined(...))`，且只导出 `mainResults`，没有完整 validated claims/evidence links。
- physical claim 右侧显示的是不可点击的 anchor ID 文本，不满足“从 claim 跳到原证据”。
- Vision disclosure 没有在发送前显示实际图像数、缩放尺寸/bytes、endpoint 与请求数；原图下载不是 streaming size bound，`maximumFigures=0` 仍会选择一张图。
- SwiftData 的 `snapshot()` 在读取失败时仍可返回空 `LibrarySnapshot`；normalized V2 rows 是每次全删全写的镜像，active source 仍是 blob，缺少大库性能与一致性证据。
- provider/model 设置缺少模型搜索、保存模型缺席时的可表示项和 terminology editor；配置/key 变化只取消 v1 insight，不取消 evidence/vision session。
- v2 toolbar、Sync Center、Updates/Favorites 视图和 UI coverage 均未达到 v2 文档的完成定义。

因此当前版本不能称为 `v2 local complete`，更不能称为 `v2 local candidate` 或公开发布。

### 1.2 本轮直接证据

#### 本地 verifier

2026-08-24 运行：

```zsh
zsh Scripts/verify_v2.sh
```

结果：exit status `0`；41 个 SwiftPM XCTest、0 failures；SwiftPM Release、Xcode Debug/unit/Release/analyze 均返回成功。最后 JSON 为：

```json
{"schema_version":"latticelens-verify-v2","local_only":true,"swiftpm_test":1,"swiftpm_release":1,"xcode_debug":1,"xcode_unit":1,"xcode_release":1,"xcode_analyze":1,"ui_runtime":false,"live_inspire":false,"live_llm":false,"failures":0}
```

Xcode unit stream 仍输出 framework copy 的 `command failed with exit code 0`/not-stripping 诊断；命令本身为 0，因此它不是 test failure，但 v3 verifier 应避免让 `error:` 字样与成功 gate 共存。

#### 本轮 XCUIApplication 复验

2026-08-24 使用独立 project-local DerivedData/result bundle、ad-hoc identity 和 `-only-testing:LatticeLensUITests` 运行当前 UI suite。第一次审计 wrapper 因误用 zsh 只读变量名而未取得摘要，不能计入证据；修正后重跑的 `xcodebuild` exit status 为 `65`。机器可读 `.xcresult` 显示：0 passed、1 runner-level failure，原因为：

```text
The test runner failed to initialize for UI testing.
Underlying Error: Timed out while enabling automation mode.
```

没有任何 LatticeLens 业务 test case 开始执行。因此这不是 SwiftUI case failure，也不是 pass；它是本轮主机 automation/runtime blocker。`VALIDATION_V2.md` 记录的 2026-08-23 6/6 fixture 结果只能保留为历史证据，不能替代当前源码的 runtime 复验。两次本轮 UI scratch/result bundle 均由 task-local cleanup 删除。

#### 2026-08-24 live INSPIRE 只读 smoke

本轮使用 HTTPS、无凭据、每请求最多 30 s，直接观察到：

- self author：recid `2010363`，name `Zhao, Dian-Jun`，含 `hep-lat`；
- author search：top-level `hits` 为 object，`hits.hits` 为 array，当前 total `1776`，next host 为 `inspirehep.net`；
- 当前第一页候选 author recid `1013274` 的 citation summary：`h(all)=56`、`h(published)=51`；
- self literature：当前 total `10`，一次 `size=100` 返回 10/10，未再给 next；其中 2 条有 documents、10 条有 figures；
- literature `3125667` 的 BibTeX endpoint 返回以 `@article{CLQCD:2` 开头的内容；
- 至少一个 self record 的公开 fulltext document 为 INSPIRE HTTPS file URL。

这些 total/record id 会随 INSPIRE 更新，不能写入固定断言。该 smoke 证明本日 HTTP/schema 语义，不证明 app 从 fresh store 完整跑完 1776 位候选的 h-index 队列、失败恢复或长期 API 稳定性。

#### Release-v2 只读检查

- manifest 与 zip 实算 SHA-256 一致：`0ca8ea3b15c1d5ef8ed451c62429a92ec6c42f74884c38dc522d9ccd0e3c26d9`；
- zip 含 `LatticeLens.app`，archive bundle id 为 `org.latticelens.app`，minimum macOS `14.0`，architectures 为 `x86_64 arm64`；
- `codesign --verify --deep --strict` 失败，manifest 也标记 `unsigned_or_unverified`。

它只证明 unsigned package structure，不证明 Developer ID、notarization、Gatekeeper、VoiceOver、跨机器安装或 public release。

### 1.3 v2 Gate A–J 矩阵

| Gate | 本轮判定 | 直接证据与边界 |
| --- | --- | --- |
| A — Clean build | **Passed local** | 当前 SwiftPM/Xcode Debug/Release/analyze 返回 0；仅本机 arm64 build 证据 |
| B — Local tests | **Passed existing suite / insufficient coverage** | 41/41 passed；缺少本文列出的碰撞、partial restart、真实 UI 行为、large-library 等 contract |
| C — Live INSPIRE | **Partial** | 2026-08-24 self/search/h/literature/BibTeX schema smoke 成功；未取得 app fresh-store end-to-end 与完整候选队列证据 |
| D — Persistence/recovery | **Failed P0** | 有 migration/corruption fixtures；仍有 silent empty snapshot、post-migration backup、blob mirror 与 partial-sync freshness 缺口 |
| E — Real UI | **Partial / current runtime UNKNOWN** | 有真实 app/UI-test target，历史 ledger 报告 6/6 fixture；本轮 runner 在 automation mode 初始化超时、0 个业务 case 执行；coverage、VoiceOver/live/real Keychain 均未闭合 |
| F — v2 evidence | **Failed P0** | 本地 PDF fixture 与 validator 存在；cross-paper ID/delete scope、retrieval provenance、click-through 与数值契约未闭合 |
| G — reference manager | **Failed P0** | local read/favorite/note/tag/collection 基础存在；BibTeX 无 UI，notes/export/updates/citation batch 不完整 |
| H — live LLM | **Not run** | 未获 API Key/provider 授权；不得外推 mock 成功 |
| I — local release | **Blocked** | unsigned artifact；VoiceOver/manual、Developer ID/notarization/Gatekeeper/cross-machine 未完成 |
| J — public release | **Not run** | 未签名、未公证、未跨机 |

严格状态：A/B 的通过只说明当前代码与当前测试一致；D/F/G 任一 P0 未通过都足以否决 `v2 local complete`。

### 1.4 v2 R1–R12 与 V2-1–V2-5 映射

| 目标 | 状态 | 结论 |
| --- | --- | --- |
| R1 live INSPIRE envelope | 基本完成 | nested DTO、flattened rejection 与当前 live shape 一致；仍需 app-level live decoder ledger |
| R2 checkpoint resume | 部分完成 / P0 | candidate/paper resume 与 per-outcome h durable 已出现；原子 generation、partial restart、实时 progress 与 cancel classification 未完成 |
| R3 h-index preservation/fallback | 部分完成 / P0 | old h 保留；fallback 对所有错误无差别触发，缺 freshness、mismatch provenance 与 explicit reset |
| R4 self/search/A–Z invariants | 部分完成 | self/Z/search 分流与 selection tag 已修；stable key 仍使用 `Locale.current`，fixture matrix 不完整 |
| R5 tracked sync | 部分完成 / P0 | local-first、detail/read、concurrency 2 已出现；tracked jobs 无 owner/progress，SyncBatch/citation change 未接入，partial last-sync 有误 |
| R6 task/state | 部分完成 / P0 | 多数 task/session id 已有；settings/key 变化未取消全部 LLM task，timeouts/request i/N/bytes 与 tracked task ownership 不完整 |
| R7 schema/cache/privacy | 部分完成 / P0 | duplicate/unknown/size/cache/consent 基础存在；evidence payload 总量、numeric grammar、status-role、Vision disclosure/redirect 不完整 |
| R8 Settings | 部分完成 / P0 | Keychain 状态/清除/model discovery 有实现；model search/preserved option/terminology editor 与全 session invalidation 缺失 |
| R9 persistence fail-visible | 部分完成 / P0 | VersionedSchema 与 fixture migration 有实现；silent empty、backup timing/recovery、blob scalability 仍失败 |
| R10 Paper Lens | 部分完成 / P0 | 五 tabs、source/figures/Markdown-TeX 有实现；source badges、claim→anchor、export 完整性与多个降级 UI 未闭合 |
| R11 real app/UI tests | 部分完成 | `.app` 与 `XCUIApplication` target 已有；v2 规定的十类 UI path 未全执行，VoiceOver 未取得 |
| R12 docs match implementation | 未完成 | README/VALIDATION 对 “core gates complete” 与 reference-manager/evidence 完成度表述过强 |
| V2-1 fulltext evidence | 部分完成 / P0 | explicit PDF/PDFKit/page anchors 有实现；ID scope、redirect、stream bound、retrieval audit/total bound 不完整 |
| V2-2 paper-insight-v2 | 部分完成 / P0 | strict root shape/anchor allowlist 有实现；claim role、semantic/numeric support 与 clickable evidence 不完整 |
| V2-3 Vision | 部分完成 / P0 | 独立 mock request/artifact/capability 有实现；preflight disclosure、0-image setting、download bound/provenance 不完整 |
| V2-4 reference manager | 部分完成 / P0 | CRUD 基础与 search 有实现；BibTeX product path、note correctness、batch/update center 未完成 |
| V2-5 Evidence Lens UI | 部分完成 / P0 | 三栏/五 tab 已有；Updates/Favorites、provider/scope/request toolbar、完整 Sync Center 缺失 |

## 2. 必须先完成的 v2 修复

以下 `F01–F12` 中标记 P0 的任务必须在 v3 feature 开工前完成。每项都要有 regression test；不能只改注释、README 或 ledger 状态。

### F01 — P0：全文 evidence identity 与删除必须 paper/document scoped

当前风险定位：

- `FullTextService.swift` 的 ID 为 `pdf:p<page>:q<chunk>:<textHash>`，不含 paper id 或 document hash；
- `LibraryStore.swift` 按 `documentHash` 全局过滤 chunks/evidence artifacts；同 hash 的另一篇论文可能被误删；
- PDF 文件用 hash 去重，但没有 reference count，删除一条 document 可能移除仍被其它 record 使用的文件。

要求：

1. canonical ID 至少包含 `paperID + documentHash + page + local ordinal + quoteHash`；metadata anchors 同样必须包含 paper id。
2. `EvidenceChunk`、`EvidenceAnchor`、`EvidenceInsightArtifact` 所有 join/delete 都显式带 paperID/documentID，不允许只按 hash 全局删除。
3. 若多个 document 共用相同 PDF hash，增加 content-addressed blob record + reference count，或删除前确认没有其他引用。
4. migration 将旧 ID 转换为新 ID，并同步重写 insight 中的 evidence ids；无法确定归属的旧 artifact 标 stale/quarantined，不静默猜测。
5. 测试两篇论文拥有相同 page text、相同 PDF hash、相同 figure key；保存/删除/重提取任何一篇都不得影响另一篇。

### F02 — P0：同步 checkpoint、freshness 与 generation 原子性

要求：

1. paper sync 只有整个 generation 成功结束时才写 author `lastSuccessfulSyncAt`；每页 durable 时间另存为 `lastCheckpointAt`。
2. app start/author selection 必须优先检查 non-completed checkpoint；即使旧数据很新，也要恢复未完成 job。
3. candidate rebuild 新 generation 写 staging membership；分页和 h queue 完成后原子切换 active generation。新结果完成前继续展示旧 snapshot。
4. 新 generation 中不再属于 hep-lat 的普通作者在切换后退出 active list，但保留用户 track/note/history，不直接删除。
5. cancelled item 不进入 `failedIDs`；分别记录 pending/failed/cancelled/retryable。
6. h snapshot 引入 freshness policy；facet transport/429 不得立刻对所有 author 启动昂贵 fallback。只有明确 schema/endpoint incompatibility 或用户选择时运行 local h fallback。
7. fallback 保存 input paper count、missing citation count、query、pages、computed formula version；若 official/local 值不一致，两份都保存并在 UI 显示 provenance。
8. service 提供 async progress stream/callback，UI 每页/每个 bounded batch更新 completed/qualified/rejected/failed/remaining。

最低 failure injection：page 2 failure → process/store recreation → 自动只请求 page 2；page 1 成功但 page 2 失败不得写 successful freshness；force rebuild 中途失败仍显示旧 generation。

### F03 — P0：paper-author link 与 selected-paper context 不得串库

要求：

1. global search selection 不得把当前 sidebar author 当作论文作者。detail enrichment 只更新 paper record，不创建新 author link；只有 INSPIRE authors metadata 或已有 authoritative link 可建立关系。
2. `PaperAuthorLink.position` 的定义写清：是论文作者顺序还是 author timeline order；只能保留一个语义，不能用 page position 填作者位置。
3. selected paper/context/task 使用 `paperID + selectionSessionID`，切作者/论文后所有迟到 callback 被丢弃。
4. tests 构造 Author A sidebar + 属于 Author B 的 global result，detail refresh 后 A 不得新增该 paper link。

### F04 — P0：reference-manager product path 必须真的可用

要求：

1. BibTeX 在 Source/Export UI 中提供“获取/刷新/导出”，使用系统 file exporter；显示 INSPIRE source URL、fetch time、cached/stale/failure，失败保留旧内容且不伪造字段。
2. note editor 使用 paper-scoped identity；切 paper 时重载，保存 existing note 时更新同 UUID，不得每次创建重复 note。
3. tags/collections 支持 add/remove/rename/delete，并在 destructive action 前显示影响的 link count。
4. 修复 Markdown tag 插值；导出 research question、method、results、inferences、missing、caveats、所有 evidence URLs/anchor labels、figure provenance 和用户 note。
5. `.md` 中本地 PDF link 只能在用户选择“包含本机路径”时生成；默认使用 INSPIRE/arXiv/public source link，不能泄露 Application Support 绝对路径。
6. batch export 至少支持 BibTeX 与 Markdown；RIS/CSL JSON 放入 V3-3。
7. read/unread/favorite/tag/collection/note 的 UI test 必须实际点击、重启 fixture app、再次读取验证，不得只检查控件存在。

### F05 — P0：把 CitationSnapshot/SyncBatch 接入真实 update center

要求：

1. 每次 completed literature sync 生成 `SyncBatch`，记录 new、metadataUpdated、citationChanged、unchanged、failed、duration 与 generation。
2. citation count 变化写 `CitationSnapshot`，相同 count 不生成重复 point；未知 count 不当 0。
3. 中栏增加 `[论文] [更新] [收藏]`；“更新”按 batch 展开具体 record diff，“收藏”真实过滤 favorite。
4. tracked-author foreground refresh 由可取消 task owner 管理，进入 Sync Center；不能用未保存的 unstructured Task 绕过 `paperSyncTasks`。
5. 本地 notification 仍需用户显式授权；fixture 不请求系统权限。

### F06 — P0：LLM task、timeout、cache 与清理语义统一

要求：

1. provider/Base URL/model/key/streaming/vision/source scope/terminology 变化必须取消并隔离 insight、evidence、vision、model-discovery 的相关 session。
2. 每个请求状态包含 request `i/N`、connecting、waiting first content、receiving bytes/chars、validating、completed/cancelled/failed、elapsed。
3. 分开实现 connect、first-content、stream-idle、hard-resource timeout；URLSession resource timeout 不得冒充全部状态。
4. SSE failure 不隐式改发 non-streaming；completion POST 不自动 retry。
5. `clear AI results` 必须由用户选择 scope：v1 insight、v2 evidence insight、vision artifact、全部；UI 文案与实际删除集合一致，先显示 count。
6. last successful artifact 在 regenerate/cancel/fail 中保留，且 UI 明示其生成时间/旧 session provenance。

### F07 — P0：evidence retrieval、schema 与物理数值契约闭合

要求：

1. `EvidenceChunk` 保存 byte/scalar/token-estimate count；request 设单 chunk、总 chunks、anchors、总 payload bytes 上限。
2. title/abstract/metadata anchor 同样 bounded；截断只在本地完成并记录 field/count/hash，不把被截文本写日志。
3. artifact 保存 retrieval query、ranker/version、score、selected chunk ids、prompt/schema version 与 payload hash。
4. schema 强制 role：research/method/result 为 `direct`，reasonable inference 为 `inference`，missing 为 `missing`；caveat 需单独定义允许状态。
5. numeric validator 覆盖 signed/scientific notation、uncertainty、区间、百分比、`L^3×T`、`a^{-1}`、`GeV^2`、`fm^{-1}`、ensemble count、fit range；数值与单位必须共同匹配同一 anchor。
6. validator 拒绝 duplicate evidence id、跨 paper/document id、quote hash mismatch、unsupported source scope 和过期 document hash。
7. 物理卡片中的 evidence chips 必须是按钮；点击可定位 Evidence tab 的 abstract/caption/PDF page，并高亮/滚动到 quote。PDF 被删后显示 stale anchor，不假装可跳转。
8. manual physics rubric 至少检查：action/ensemble、`a`、`L^3×T`、`m_π`、momentum、source-sink separation、operator/Wilson line、renormalization scheme/scale、Fourier convention、matching order、statistics/systematics。

### F08 — P0：PDF、figure 与 Vision 网络边界

要求：

1. INSPIRE metadata、PDF、figure、BibTeX 均使用 streaming byte limit；不得先 `data(for:)` 全量读入再检查。
2. redirect 每一跳验证 scheme、host/allowed-origin、port、userinfo、fragment、path class；PDF/figure 可声明明确的 INSPIRE/arXiv/CDN allowlist，不能只检查最终为 HTTPS。
3. PDF 下载前 UI 显示 source URL、Content-Length（若服务器提供则标“server-reported estimate”）、上限与存储位置类别；完成后显示 actual bytes/hash/pages。
4. Vision 在发送 pixels 前完成 local preflight，并展示 figure keys、原始/缩放尺寸、每图 bytes、总 bytes、endpoint、额外请求数；用户确认应绑定该 frozen preflight hash。
5. `maximumFigures=0` 时 Vision action 禁用且请求为 0；不得强制 `max(1, value)`。
6. Vision cache key 加 provider id、normalized endpoint、prompt/schema、capability、image hash/size；artifact 保存发送尺寸/bytes，不保存 API Key。
7. thumbnail/preview 也走 app-owned bounded loader，不使用无审计的 `AsyncImage` 路径。

### F09 — P0：persistence 真正 fail-visible、可恢复、可扩展

要求：

1. `snapshot()` 不得在 decode/fetch failure 时返回空库。改成 typed result/state，UI 持续显示 last-known-good immutable snapshot，同时进入 read-only failure。
2. SwiftData migration 前创建独立、checksum-backed、timestamped backup；migration 成功后再切 active store。测试 migration 中途 failure 与 rollback。
3. JSON primary 损坏时发现并验证 latest valid backup，向用户提供“只读打开/恢复到新文件/取消”；不得 silent restore 或 silent empty。
4. `ready/migrated/recovered/jsonFallback/readOnlyFailure` 全部在 app UI 可见，记录 source path category，不暴露不必要的绝对路径。
5. normalized entities 作为 active source of truth，或给 blob source 提供明确性能/并发依据。禁止每个小 mutation 全删全插全部 projection。
6. v3 migration 保留 v1/v2 insight、read/note/tag/collection/checkpoint/fulltext provenance；pre/post count/hash ledger 可回滚。
7. 加 2k authors、20k papers、100k links、100 PDFs 的 synthetic large-library test，记录硬件、cold/warm、p50/p95、peak RSS；没有数据不得声称性能完成。

### F10 — P0：Settings 与 privacy UX 完成 Speech2AI 风格契约

要求：

1. model list 可搜索；已保存 model 即使 discovery 不再返回，也以“saved / currently undiscovered”项保持可表示；manual model 始终可选。
2. discovery cache 按 provider + normalized Base URL + credential revision 隔离；key 清除后取消请求并清除该 credential 的 discovery cache。
3. 增加 bounded terminology editor：add/edit/delete/import/export；它作为 JSON data 进入 prompt，不覆盖原论文文本。
4. 保存前验证 endpoint/model；错误直接在对应 field 显示，不等到 LLM 请求才失败。
5. privacy sheet 显示 normalized/redacted endpoint、provider/model、source scope、字段/bytes、是否 pixels、request count；consent 绑定 frozen payload class。
6. OpenAI、DeepSeek、custom OpenAI-compatible profile 分开；不得把一个 provider 的 live 成功外推给另一个。

### F11 — P0：补齐 v2 UI、accessibility 与 UI tests

要求：

1. toolbar 显示 active provider/model、当前 source scope、text/vision request `i/N`；connectivity 仍是带时间的 last observation。
2. Sync Center 分开 author pages、h-index queue、tracked authors、当前 paper sync、fulltext、LLM/vision；各自有合法的 pause/resume/cancel 与实时 counts。
3. 五 tab 全部具备 keyboard focus order、accessibility label/value/hint；status 不只依赖颜色。
4. `XCUIApplication` 至少实际覆盖：checkpoint pause/relaunch/resume、tracked/new→read、no abstract、no figures、bad image、provider switch/model search/manual、claim→anchor、note/tag/collection persistence、BibTeX/Markdown exporter 出口。
5. fixture 必须继续使用 in-memory/temp store、mock network/process-local Keychain，不访问通用 clipboard、用户 Defaults、用户 database 或公网。
6. 单独执行 VoiceOver/manual checklist；没有手工结果时 Gate I 仍 Blocked。

### F12 — P0：README、verifier 与 evidence ledger 必须与实现一致

要求：

1. README 删除 “core gates completed” 等超出证据的表述，逐 Gate 链接 `VALIDATION_V3.md`。
2. `Scripts/verify_v3.sh` 必须返回 mandatory local gate 的聚合 exit code；机器摘要列出 test counts、UI runtime、live flags、artifact hash。
3. UI runtime 必须由 readable `.xcresult` 汇总，不从 source compiled/build-for-testing 推断。
4. live smoke 使用独立 credential-free script；不写死 totals/record ids，只验证 type、trusted origin、nonnegative values 与语义字段。
5. Release-v3 使用独立目录且拒绝覆盖；unsigned、ad-hoc、Developer ID、notarized 分成不同 artifact class。

## 3. v3 产品目标

v3 的核心不是再增加一个聊天框，而是把 LatticeLens 从单篇 Evidence Lens 升级成面向研究工作的 **Evidence Workbench**：可以知道“什么变了”、跨论文比较、把格点物理参数逐项回查，并将笔记/引用可靠导出。

### V3-1 — P0：Research Radar（作者、论文修订与引用变化）

#### 数据源与语义

- tracked authors；
- saved INSPIRE queries，例如 `arxiv_categories:hep-lat`、关键词/作者组合；
- 已收藏/已加入 collection 的 papers；
- INSPIRE record `updated`、citation count、documents/figures/title/abstract/publication metadata diff。

要求：

1. Radar event 只能由两份有时间戳的 INSPIRE snapshot diff 产生，不由 LLM 猜测。
2. event 类型至少包括 `newPaper`、`recordRevised`、`citationChanged`、`newDocument`、`newFigure`、`publicationChanged`。
3. 每条 event 保存 before/after field hash、observedAt、source record URL、sync batch id；UI 可展开 field-level diff。
4. citation `nil → n`、`n → nil` 与 `n → m` 分开，未知不当 0。
5. saved query 有明确 refresh policy、manual refresh、pause/cancel；默认不创建系统定时任务。
6. macOS notification 仅在用户显式授权且 batch complete 后发送；聚合通知不含摘要正文或敏感 note。

建议模型：

```swift
struct RadarEvent {
    let id: UUID
    let paperID: Int
    let authorRecids: [Int]
    let eventKind: RadarEventKind
    let beforeHash: String?
    let afterHash: String
    let changedFields: [String]
    let syncBatchID: UUID
    let observedAt: Date
    let sourceURL: URL
    var isAcknowledged: Bool
}
```

### V3-2 — P0：Multi-paper Compare 与 physics contract

用户可从 library 选择 2–6 篇论文加入一个 workspace。Compare 不能只显示 LLM 总结，而要把关键格点参数变成 evidence-backed matrix。

默认 physics contract 行：

- observable / research question；
- gauge/fermion action 与 ensemble；
- lattice geometry `L^3×T`；
- lattice spacing `a` / inverse spacing；
- pion/hadron mass；
- momentum、boost 与 momentum smearing；
- source/sink、`t_sep`、operator/Wilson line；
- correlation-function ratio/fit range；
- renormalization scheme/scale；
- Fourier sign/normalization 与 source/sink convention；
- perturbative matching order/scheme；
- continuum/chiral/finite-volume/physical-point extrapolation；
- statistics、systematic uncertainties 与 failed/missing items。

每个 cell 必须是：

```text
value + unit + epistemic status + paper id + evidence anchor(s) + extraction version
```

规则：

1. direct cell 至少一个同 paper 的有效 anchor；跨 paper 推论必须是 `cross_paper_inference`。
2. missing 保持空值/未知原因，不能根据相邻论文补齐。
3. 用户可点击任一 cell 跳到原 PDF/abstract/caption；source hash 改变后 cell 进入 stale。
4. Compare request 只发送所选 paper 的 bounded chunks；consent 绑定 paper set、source scope、total bytes 和 endpoint。
5. 保存 workspace、排序、用户 note 和 frozen export；删除 workspace 不删除 papers/fulltext。

### V3-3 — P0：Evidence Notebook 与可移植导出

要求：

1. 用户可从 PDF 页/abstract/caption 创建 local annotation，保存 page、character range、quote、quote hash、颜色/label、note 与 paper/document id。
2. PDF 重新下载后重定位 quote；精确匹配失败标 stale 并展示旧 quote，不静默移动到近似文本。
3. note 可以引用多个 anchors；Markdown 导出生成稳定脚注与 source URL。
4. 单篇/批量导出支持：authoritative INSPIRE BibTeX、RIS、CSL JSON、validated Markdown notebook、machine-readable provenance JSON。
5. RIS/CSL 优先 source endpoint/metadata；缺失字段省略，不猜 journal/page/year/DOI。
6. import 仅接受本地 BibTeX/RIS/CSL JSON 并保留 imported provenance；与 INSPIRE record 合并必须先匹配 DOI/arXiv/recid 并显示冲突。

### V3-4 — P1：可审计 citation/coauthor/topic graph

要求：

1. citation/coauthor edge 必须来自 INSPIRE record，不由 LLM 生成。
2. graph 默认只展示当前 paper/author 的一跳邻居；扩展每一跳由用户动作触发，设 nodes/edges/pages/bytes 上限。
3. node/edge 点击显示 source URL、fetchedAt、query、batch id；未知/failed edge 不画成存在。
4. topic clustering 若使用 embedding，默认本地；算法/version/seed/feature hash 可复现。LLM label 只能作为 `generated_label`，不能变成 edge evidence。
5. graph 是 library navigation，不替代原 A–Z author list。

### V3-5 — P1：可选 iCloud/CloudKit 私有同步

该目标依赖 Apple capability/entitlement，因此必须与 local v3 完成度分开。

1. 默认关闭；用户显式开启后只用 private database。
2. 同步 read/favorite/note/tag/collection/workspace/annotation；默认不同步 PDF bytes、LLM raw response、provider endpoint、API Key、logs。
3. API Key 永远只在每台 Mac 的 Keychain；credential revision 不跨设备当作 key identity。
4. conflict policy：immutable source snapshot append-only；note/collection 使用 deterministic merge 或明确 conflict copy，不能 last-write-wins 静默丢字。
5. 提供 mock sync engine、offline queue、retry idempotency 与 migration tests。没有真实 entitlement/account/cross-device 证据时标 `Blocked external`，不得称 live CloudKit 完成。

明确不在 v3 自动执行：team/shared database、公开分享链接、自动修改 INSPIRE record、自动上传用户 PDF、后台付费 LLM 调用。

## 4. v3 展示方案：Evidence Workbench

主窗口增加 product-level navigation，但 Author 浏览仍保持用户要求的 self-first + A–Z：

```text
┌ NAV ─────────┬ AUTHORS / RADAR / LIBRARY ─────┬ WORKSPACE ───────────────────────────┬ EVIDENCE INSPECTOR ───────┐
│ Radar   12   │ ★ 我的主页                      │ [阅读] [比较] [图谱]                  │ direct / inference / missing│
│ Authors      │ [姓名搜索] A…Z                  │ Physics Contract matrix               │ paper + PDF p.4 + quote     │
│ Library      │                                 │ a | L³×T | mπ | Pz | t_sep | renorm    │ [跳到原文] [加入笔记]       │
│ Compare  3   │ updates / favorites / papers    │ 每个 cell 都有 status/evidence chips  │ source hash / fetchedAt      │
│ Graph        │ batch diff / saved queries      │                                    │ stale / validated           │
└──────────────┴─────────────────────────────────┴──────────────────────────────────────┴───────────────────────────┘
```

交互重点：

- Radar 首屏回答“自上次同步以来什么变了”，不显示永久“在线”。
- Compare 顶部固定 paper chips；表格第一列是 physics contract，后续每列一篇论文。
- direct 为实线 evidence chip，inference 为虚线并写明依据，missing 为空心 badge；同时提供文本 label，不只靠颜色。
- 右侧 Inspector 始终显示当前 claim/cell 的原 quote、page/source、hash 与 stale 状态。
- Graph 展示 citation/coauthor 关系；选择 node 后仍回到同一 Evidence Inspector，不开第二套阅读器。
- toolbar 固定显示 provider/model、source scope、request i/N、local/offline、sync batch time。

推荐窗口最小宽度继续支持 1120；窄窗口时 Inspector 折叠成 sheet，Compare matrix 横向滚动，不能挤掉 author search/self row。

## 5. v3 schema 与迁移

V3 至少增加：

- `AuthorIndexGeneration`
- `PaperRevisionSnapshot`
- `RadarEvent`
- `SavedInspireQuery`
- `SyncBatchV3` / `SyncJobEvent`
- `ContentBlob` / `DocumentReference`
- `UserEvidenceAnchor` / `Annotation`
- `PaperWorkspace` / `WorkspacePaperLink`
- `PhysicsContract` / `PhysicsContractCell`
- `CitationEdge` / `CoauthorEdge`
- `ExportRecord`
- optional `CloudSyncRecordState` / `ConflictCopy`

迁移规则：

1. v2 source metadata、read/favorite/note/tag/collection/BibTeX/fulltext/anchors/artifacts 全部保留。
2. 旧 ambiguous PDF anchor 只能在 paper/document 唯一可推导时转换；否则 quarantine + UI 提示重新提取。
3. v2 paper-insight-v2 不自动升级成 physics contract；必须重新通过 V3 extractor/validator，旧 artifact 仍可只读展示。
4. pre-migration backup 在打开 V3 container 前完成；pre/post count/hash、quarantined count、duration 写 ledger。
5. rollback 只写用户明确选择的新 target，不覆盖 active V3 store。
6. migration 可重复运行且 idempotent；中途 crash 后可从 migration journal 恢复。

## 6. 网络与安全契约

### 6.1 INSPIRE GET

- 只对 idempotent GET retry；transport、429、502、503、504 分开，honor observed `Retry-After`，bounded attempts/backoff/jitter。
- next link 验证 exact origin（scheme/host/port）、userinfo、fragment、path class；每页重验。
- streaming response size、connect/request/resource timeouts、HTTP status/error class 可审计。
- ETag/Last-Modified 只复用已验证 body；304 无 local body 必须失败可见。
- 不记录完整 abstract、email、API payload；只记录 query hash/endpoint class/count/timing。

### 6.2 LLM POST

- 不自动 retry completion；用户重试产生新 request id。
- profile capability 明确区分 streaming、vision、structured output；不从 model 名称猜测。
- redirect fail closed，Authorization 不跨 origin。
- multi-paper request 保存 paper set、anchor allowlist、payload hash、provider/model、prompt/schema、request count。
- live provider 逐 profile 验收；OpenAI 成功不等于 DeepSeek/custom 成功。

### 6.3 CloudKit

- private database、explicit opt-in、field allowlist；不上传 secrets/PDF/LLM raw content。
- CloudKit live gate 独立，不能阻塞纯本地 v3，但 P1 状态必须诚实。

## 7. 实施顺序

### Phase 0 — 冻结 v2 基线

- 生成修改前 manifest/hash；
- 新建空 `VALIDATION_V3.md`、`validation-v3.json`；
- 将 F01–F12 转为 machine-readable checklist；
- 不改 v1/v2 方案与 Release-v2。

### Phase 1 — 数据正确性与 migration

- F01、F03、F09；
- V3 schema/migration journal；
- cross-paper collision、global-selection、corrupt/recovery、large-store 基础测试。

通过：错误删除/错误 author link/silent empty 均有失败测试先红后绿；v2→v3 rollback 可复现。

### Phase 2 — sync/network recovery

- F02、F05、F08 的 INSPIRE/PDF 部分；
- generation、SyncBatch、Radar input snapshots；
- streaming limits、redirect、timeouts。

通过：partial process recreation 自动 resume；completed batch 才更新 freshness；citation diff 可审计。

### Phase 3 — evidence/provider recovery

- F06、F07、F08 Vision、F10；
- claim role/numeric validator、clickable anchor、preflight disclosure、all-session invalidation。

通过：cross-paper/unknown/stale evidence 全 fail closed；0 figures 发 0 request；每次请求计数/bytes 可见。

### Phase 4 — v2 reference/UI closeout

- F04、F11、F12；
- BibTeX product path、note lifecycle、Updates/Favorites、完整 Sync Center、UI regression。

通过：Gate A–G 全部有 current evidence，才能写 `v2 recovered`。

### Phase 5 — Research Radar

- V3-1 event/diff/saved query；
- Radar UI、acknowledge/filter、optional notification contract。

### Phase 6 — Compare 与 Notebook

- V3-2 physics contract；
- V3-3 annotations、batch export/import；
- multi-paper privacy/cache/provenance。

### Phase 7 — Graph 与 optional CloudKit

- V3-4 bounded source-backed graph；
- V3-5 mock sync engine；live CloudKit 仅在 capability/authority 可用时运行。

### Phase 8 — candidate

- full local verifier、UI `.xcresult`、performance、VoiceOver/manual、live ledgers；
- 独立 Release-v3 package；签名/公证仍按权限分层。

## 8. 必须新增的测试

### 8.1 Unit/contract

- cross-paper chunk/anchor/figure key collision；
- shared PDF blob reference/delete；
- partial checkpoint 与 successful freshness；
- atomic candidate generation membership；
- h facet error classification/fallback provenance；
- global result 不创建错误 author link；
- note update/switch paper、tag export interpolation；
- all artifact clear scopes；
- model search/saved undiscovered/manual/terminology；
- payload total bytes/token estimate；
- numeric/unit/uncertainty/volume/fit-range validator；
- claim-role 与 clickable destination mapping；
- Vision 0/1/3、preflight hash、redirect/size；
- v2→v3 migration/quarantine/rollback/crash resume；
- Radar diff 与 nil citation semantics；
- physics contract per-paper anchor allowlist；
- RIS/CSL omission-not-invention。

### 8.2 Integration

- scripted multi-page sync：page 2 failure → store recreation → resume；
- candidate generation fail then atomic success；
- tracked author concurrent refresh + cancel + SyncBatch；
- detail selection races/global paper context；
- PDF streaming oversize/redirect/MIME/shared blob；
- LLM first-content/idle/resource timeouts；
- provider/key/settings switch cancels all relevant sessions；
- multi-paper Compare bounded retrieval/cache invalidation；
- Radar refresh dedup/idempotency；
- annotation stale relocation；
- large-library query/mutation benchmarks；
- optional CloudKit mock offline/conflict/idempotency。

### 8.3 XCUIApplication

至少覆盖：

1. self permanent + ordinary Z + local name search；
2. author index pause/relaunch/resume progress；
3. tracked sync、Updates batch、new→read、citation diff；
4. global search paper 不改变错误 author membership；
5. no abstract/no figures/bad image/offline stale；
6. Fast/Deep cancel/cache/regenerate preserves prior；
7. provider switch/model search/saved manual/key clear/terminology；
8. PDF download/preflight/anchor jump/shared delete isolation；
9. caption-only/Vision 0/3/disclosure；
10. note/tag/collection update/relaunch persistence；
11. BibTeX/Markdown/RIS/CSL exporter entrance；
12. Radar event diff/acknowledge；
13. Compare physics cell → Inspector → PDF page；
14. Graph bounded expansion；
15. keyboard/resize/focus/accessibility values。

fixture UI 禁止访问 live network、真实 Keychain、用户 Defaults、用户 database、通知中心或通用 clipboard。

### 8.4 Live/manual

- live INSPIRE：self、candidate、qualified h summary、self literature pagination、BibTeX、one PDF/figure HEAD/GET policy；
- live provider：仅授权 profile，逐个保存 ledger；
- physics rubric：至少 3 篇本地 fixture PDF，覆盖格距/体积/重整化/Fourier/source-sink/missing/numeric；
- VoiceOver、keyboard、window resize、offline/corrupt recovery；
- optional CloudKit：两设备/两账户边界明确；
- signing/notarization/Gatekeeper/cross-machine 分层。

## 9. Gate 与完成定义

沿用 A–J，并新增 K–N：

| Gate | 必须证据 | 失败含义 |
| --- | --- | --- |
| A | SwiftPM + Xcode Debug/Release/analyze warnings-as-errors | build baseline 不成立 |
| B | 完整 current unit/integration tests，无 live dependency | local contract 未完成 |
| C | current live INSPIRE app-level smoke | 核心数据源未验证 |
| D | restart/resume/migration/corruption/backup/rollback/large-store | 用户库不安全 |
| E | `.app` + current `XCUIApplication` readable `.xcresult` | GUI 行为未验证 |
| F | scoped PDF anchors + v2 claim validation/click-through | evidence reader 未完成 |
| G | read/favorite/note/tag/collection/BibTeX/Markdown/updates | reference manager 未完成 |
| H | 每个授权 provider 独立 live ledger | provider 只能称 mock-compatible |
| I | archive manifest + VoiceOver/manual + local install | local candidate 未完成 |
| J | Developer ID + notarization + Gatekeeper + cross-machine | public release 未完成 |
| K | Radar diff/saved query/SyncBatch fixtures + UI | V3-1 未完成 |
| L | multi-paper physics contract + per-cell anchors + UI | V3-2 未完成 |
| M | annotation + batch export/import provenance | V3-3 未完成 |
| N | bounded graph；CloudKit 单独标 local mock/live | P1 graph/sync 状态不完整 |

严格命名：

- `v2 recovered`：A–G 全通过；H 未授权 profile 可 Not run，但 mock contract 必须通过。
- `v3 local complete`：A–G、K–M 全通过；N 中 graph P1 可单独列状态，CloudKit 未授权可 `Blocked external`。
- `v3 local candidate`：再通过 I；H 逐授权 profile 记录。
- `Final/Public Release`：J 也通过。

## 10. 建议验证命令

命令需由 Terra 按最终 scheme/targets 同步到 `Scripts/verify_v3.sh`。所有临时产物使用唯一 project-local scratch：

```zsh
swift test --scratch-path .codex-task-tmp-<run>/swift-test

swift build -c release \
  --scratch-path .codex-task-tmp-<run>/swift-release \
  -Xswiftc -warnings-as-errors

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project LatticeLens.xcodeproj -scheme LatticeLens \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .codex-task-tmp-<run>/derived \
  -resultBundlePath .codex-task-tmp-<run>/unit.xcresult \
  CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  SWIFT_STRICT_CONCURRENCY=complete \
  -only-testing:LatticeLensTests test
```

UI test 使用可复现的 local/ad-hoc signing，并把 exact command 与 `.xcresult` summary 写 ledger。不要把 `build-for-testing` 当 runtime pass，也不要把 `CODE_SIGNING_ALLOWED=NO` build 当作可启动 UI evidence。

最终单命令：

```zsh
zsh Scripts/verify_v3.sh
```

它必须输出至少：schema version、local-only、test counts、build/unit/UI/analyze statuses、live flags、performance fixture status、failures；任一 mandatory local gate 失败时返回非零。

## 11. Terra 最终交付物

至少包括：

- 修复后的 Sources、Tests、fixtures；
- V3 SwiftData schema、migration journal、backup/rollback tools；
- `Scripts/verify_v3.sh` 与独立 live smoke script；
- `VALIDATION_V3.md`、`validation-v3.json`；
- current readable UI `.xcresult` 摘要（result bundle 可为 task-local，不必长期保留）；
- collision/partial-resume/large-library/performance evidence；
- Radar、Compare、Notebook 的 fixture screenshots 或 accessibility tree 摘要；
- 更新后的 README；
- 如生成包，只写 `Release-v3/`，包含 manifest、SHA-256、安装/回滚说明与真实 signature class。

最终回复必须列出：

1. v2 recovered verdict；
2. v3 implementation verdict；
3. changed/new files；
4. exact commands、test counts、exit status 与 artifact hashes；
5. live INSPIRE ledger；
6. live provider/CloudKit 分项结果或未授权边界；
7. GUI/VoiceOver/signing/notarization/cross-machine 边界；
8. migration/rollback/quarantine counts；
9. cleanup，仅删除本轮临时文件/进程；
10. 剩余 P0/P1，以 issue id 列出，不得写成笼统“后续优化”。

## 12. 最后约束

- 不得把 h-index request failure 写成 0 或 rejected；threshold 始终是 `h(all)>20`，20 不合格，本人 recid `2010363` 始终独立置顶。
- 不得把 PDF URL 存在写成“已读全文”；只有 extraction + valid anchor 才升级 scope。
- 不得把 caption-only 写成 Vision；不得把 Vision 写成 PDF 全文证据。
- 不得把 inference 写成 direct；missing 不得伪造 anchor。
- 不得静默覆盖/清空用户库、note、tag、collection、PDF 或旧 artifact。
- 不得把 41 tests、6 UI fixtures、unsigned archive 或一次 live endpoint 成功写成 v2/v3/public release 完成。
- 任何物理总结都必须能回到明确 paper/source/anchor；若未提供 action、格距、体积、动量、重整化、Fourier/source-sink、matching 或误差，必须明确写“原始资料未提供”。

一句话验收标准：**v3 只有在 v2 数据正确性先闭合、每个跨论文物理 cell 都可回查原证据、Radar 变化来自可审计 INSPIRE diff、用户库可恢复且所有 release 层级不越界时，才可称为 Evidence Workbench。**
