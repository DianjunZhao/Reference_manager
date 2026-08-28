# INSPIRE 文献管理器开工方案 v2：v1 修复审计与 GPT-5.6 Terra 执行说明

> 产品工作名：LatticeLens  
> 文档版本：v2.0  
> 审计日期：2026-08-22（Asia/Shanghai）  
> 工作目录：~/Desktop/Reference_manager  
> 目标执行者：GPT-5.6 Terra  
> 本文用途：先修复 v1 未完成目标，再实现 v2 目标；不是产品完成声明

## 0. 给 GPT-5.6 Terra 的第一指令

请直接在当前目录继续实现，不要只做代码审查或重新写一份设计建议。严格顺序是：

1. 保留 **INSPIRE文献管理器_开工方案_v1.md** 和本文件，不覆盖原始方案。
2. 先修复本文 R1–R12 的 v1 P0 缺口，并通过 Gate A–E。
3. v1 live 主路径真正可用后，再实现 V2-1–V2-5。
4. 完成后运行本文全部适用测试，生成可审计 evidence；任何未授权的 live LLM、Developer ID、公证或跨机器验证都必须标为未验证。
5. 不要把 mock、静态 UI、swift build、进程退出码或一次 provider 成功外推成 live INSPIRE、完整 GUI、所有 provider、签名/公证或公开发布完成。
6. 不要读取浏览器、通信、无关私人目录或凭据。API Key 只能通过 app Keychain 或用户明确提供的安全环境进入运行时，不能进入参数、日志、fixture、截图、manifest 或 Markdown。
7. 当前目录不是 Git repository；不要擅自 git init、commit、push、重置或删除用户文件。

如果时间或环境不足，仍需完成尽可能多的安全实现，并在 **VALIDATION_V2.md** 中逐 gate 给出 Passed / Failed / Blocked / Not run，不得以“代码已写”替代验收。

## 1. v1 严格完成判定

### 1.1 总结

**判定：v1 未完成，状态为 Partial / P0 blocked。**

已有源码提供了可编译的 SwiftUI 三栏骨架、INSPIRE/LLM DTO、SwiftData/JSON store、Fast/Deep workflow 和少量离线 contract tests；但 live INSPIRE 作者/论文分页响应不能被当前 DTO 解码，作者索引 checkpoint 不能恢复，关注作者不会在启动时刷新，所谓 UI tests 没有启动 app。因此它尚不能完成用户的核心任务：

~~~text
live hep-lat 作者 → INSPIRE h(all)>20 → A–Z 作者列表 → 同步其文献 → 选择论文 → AI Paper Lens
~~~

### 1.2 本轮直接证据

审计环境：

- Apple Swift 6.3.3
- Xcode 26.6 (17F113)
- 当前 Xcode SDK build target：arm64-apple-macos14.0
- 当前项目形式：Swift Package executable，不是已配置的 .xcodeproj macOS app target

本地命令结果：

| 命令/检查 | 结果 | 能证明什么 | 不能证明什么 |
| --- | --- | --- | --- |
| swift test --scratch-path .codex-task-tmp-audit-v2/test | 8 tests passed | 当前 flattened fixtures 下的本地逻辑可编译并通过 | live INSPIRE、真实 UI、Keychain、provider |
| swift build -c release ... -Xswiftc -warnings-as-errors | Passed | Release Swift executable 可编译 | .app、archive、GUI 正确、分发 |
| xcodebuild ... build test | build 完成；7 个 core tests 通过；测试会话约 145 s 后仍未正常收尾，本轮中断 | Xcode 可以解析 package scheme 并构建 | 完整 Xcode test gate；UI tests 未获通过证据 |
| Build products | 只有 Mach-O LatticeLens executable，没有 LatticeLens.app | 当前产物类型 | 原生可分发 app bundle |
| LatticeLensUITests 源码 | 仅 1 个字符串相等测试 | identifier 名称被写入测试源码 | XCUIApplication 启动、点击、键盘、VoiceOver 或真实界面 |

2026-08-22 的 live read-only shape check：

~~~json
{
  "top_level_hits_type": "object",
  "nested_hits_hits_type": "array"
}
~~~

这同时出现在当前 author search 和 literature search 响应中；本轮快照分别报告 1776 个 hep-lat author records 和本人 10 条 literature records。两个总数会随 INSPIRE 更新，不能写成固定测试断言。

当前实现却定义：

~~~swift
struct InspirePage<Hit: Decodable & Sendable>: Decodable, Sendable {
    let hits: [Hit]
    let links: InspireLinks?
}
~~~

见 **Sources/LatticeLens/Core/Networking/InspireDTO.swift:62**。测试 fixtures 也把 hits 人工压平成 array，见 **Tests/LatticeLensTests/Fixtures/authors-page-1.json:2** 和 **literature-page.json:2**。因此 test pass 与 live contract 不一致。

### 1.3 v1 P0 完成度矩阵

| v1 P0 目标 | 状态 | 审计证据 | 严格结论 |
| --- | --- | --- | --- |
| 原生 SwiftUI macOS 14 app | 部分完成 | SwiftUI executable/build 通过；无 .app/app target | 不能称本地 app candidate |
| 本人 recid 2010363 始终置顶 | 部分完成 | domain contract 存在；self row 无显式 selection tag，搜索不匹配时本人会消失 | 逻辑意图存在，GUI 不满足“始终” |
| 可恢复 hep-lat 作者索引 | 未完成 | live page decode 不兼容；checkpoint 只写不读 | 核心 P0 blocker |
| 逐作者缓存 h-index，列表只含 h_all>20 | 部分完成 | threshold/facet mapper unit test 存在；候选链断裂、无 fallback、重建会清旧 h 状态 | 不能生成可信完整列表 |
| 姓名搜索、A–Z、同步状态/时间 | 部分完成 | search normalizer 存在；Z section 会被整组隐藏；search 每次调用 start()；无完整 last-sync UI | 关键不变量失败 |
| 关注作者、分页/增量同步、启动刷新 | 未完成 | live literature decode 不兼容；tracked authors 启动不刷新；checkpoint 不恢复 | 核心 P0 blocker |
| 自动中文标题/摘要/物理解释/选图 | 部分完成 | mockable Fast/Deep workflow 与 schema 存在 | live provider 未验；取消/cache/strict schema 有缺陷 |
| 原文与 LLM 产物并存 | 部分完成 | 四 tab 框架存在 | 缺 authors/documents、中文 caption、数学 renderer、Quick Look、export |
| Speech2AI 风格 provider/Keychain/model/SSE | 部分完成 | profile、Keychain、GET models、manual model、stream toggle 存在 | 无 saved-key status/清除、模型搜索、timeout、endpoint-bound consent |
| 持久化、离线、取消、重试、错误分层、缓存清理 | 未完成 | SwiftData/JSON actor 存在 | 无 retry/conditional request；取消状态错误；cache 删除范围不实；corruption fail-open |
| unit/integration/UI/live 分层验收 | 部分完成 | 8 个离线 tests | fixtures 不同于 live；无真正 UI tests/live ledger |

## 2. 必须先修复的 v1 缺口

下面的 R1–R12 都是 v2 开工前的必修任务。标记 P0 的任何一项未通过时，禁止声称 v1 或 v2 主流程完成。

### R1 — P0：修正真实 INSPIRE search envelope

涉及文件：

- Sources/LatticeLens/Core/Networking/InspireDTO.swift
- Sources/LatticeLens/Core/Networking/InspireClient.swift
- Tests/LatticeLensTests/Fixtures/*.json
- Tests/LatticeLensTests/CoreContractTests.swift

要求：

1. author/literature search DTO 必须解析真实 envelope：top-level hits object 内含 hits array 和 total，top-level links 包含 next/self 等。
2. 单条 author/literature record 与 search hit 可共享 metadata DTO，但 envelope 不可混淆。
3. fixtures 改为当前真实层级；删除只为迎合错误 DTO 的 flattened fixtures。
4. fixtures 必须脱敏，不包含 email/position/API Key；公共论文 title/abstract 可用短 synthetic values，但结构必须真实。
5. live smoke 不断言 1776/10 等易变总数，只断言类型、recid、可信 host、非负 total 和 schema 可解码。

最低测试：

- nested author page decodes and follows links.next；
- nested literature page decodes；
- flattened old fixture 被拒绝，防止 contract 回退；
- next URL 的 scheme、host、userinfo、fragment 和 path policy；
- live self author、candidate page、literature page、citation summary 分别记录结果。

### R2 — P0：checkpoint 必须可恢复，不是“只写不读”

当前问题：

- AuthorIndexService.rebuildCandidateIndex() 在 **AuthorIndexService.swift:85** 总从 nextURL=nil 开始。
- PaperSyncService.sync() 在 **PaperSyncService.swift:24** 同样总从第一页开始。
- h-index queue 到所有请求结束后才在 **AuthorIndexService.swift:137** 一次性保存。

要求：

1. LibraryStoring 增加 typed checkpoint read/update/complete/delete API，不能由 service 反复扫描 opaque snapshot。
2. checkpoint 至少包含 job id、query、generation/run id、next URL、completed pages/items、failed ids、started/updated/completed timestamp 和 terminal state。
3. partial job 从已验证的 next URL 继续；completed job 的“强制重建”从第一页开始但保留旧可用 snapshot，直到新 generation 完成后原子切换。
4. 每一页 paper/candidate 成功后立即 durable upsert + checkpoint。
5. h-index 每个 outcome 或小 batch 立即 durable；app 退出后跳过已有 fresh snapshot，仅处理 pending/stale/failed-retry author。
6. cancellation 与 request failure 分离；被取消 author 不得被批量标成 failed。
7. UI 提供暂停/取消/继续，并实时显示 page、verified、qualified、rejected、failed、remaining。

验收：人工注入第 2 页失败，重启 service 后只请求未完成页；h-index 第 N 项取消后，已成功结果仍在且继续从 N 附近恢复。

### R3 — P0：重建作者索引不得清空旧 h-index

当前 upsert(authors:) 只保留 isTracked/lastSyncedAt，会用候选 DTO 的 hIndex=nil/unknown 覆盖旧的 h snapshot。这与 v1 “保留上一版可用列表”相反。

要求：

- candidate metadata refresh 默认保留旧 hIndex/hIndexState；只有新成功 summary 才替换。
- refresh 失败时旧 snapshot 变为 stale，仍可显示并标明日期；不能变成 0 或直接消失。
- 只有 explicit reset 才删除 h snapshots，并展示 destructive scope。
- 实现 /facets 失效时的本地 fallback：按 mostcited 分页取得 citation counts，计算

  \[
  h=\max\{k\mid c_{(k)}\ge k\},
  \]

  source=locally-computed，不得标为 INSPIRE official summary。
- fallback 与 INSPIRE summary 在 fixtures 上做对照；数值不一致时同时保存口径和 provenance，不静默覆盖。

### R4 — P0：修复作者列表不变量

当前问题：

- **MainWorkspaceView.swift:60** 会过滤掉任何包含 self 的整个 section；本人姓氏为 Z，因此其他 Z 作者一起消失。
- AuthorIndexService.visibleAuthors() 对 self 也应用 search；搜索其他姓名时“我的主页”变成“正在加载”。
- self row 不是 ForEach 元素且没有显式 tag(me.recid)，selection 行为没有测试证据。
- **MainWorkspaceView.swift:68** 的每次 search 变化都会重新调用 start()，可能触发无关网络/文献同步。

要求：

1. 先把 self 与 ordinary authors 分流；self 永久在独立 section，ordinary authors 再 A–Z/# 分组。
2. search 只过滤 ordinary authors；self 始终可见。
3. self row 显式 tag(recid) 并可键盘选中。
4. search 是纯本地派生状态，不调用 start()、不发网络、不重置 selected paper。
5. 排序使用稳定 locale-independent sort key + localizedStandardCompare display fallback。
6. 加 fixtures：self + 两个 Z 作者、native name、BAI、重音、连字符、#、空 search、无匹配 search。

### R5 — P0：让“关注与同步”名副其实

要求：

- app 启动后先展示本地数据，再在前台空闲时刷新全部 tracked authors；设并发上限、取消和 progress。
- 选中作者：本地为空时自动首次同步；本地已有但 stale 时后台 refresh；永远保留可读旧数据。
- 同步使用 literature record id upsert，并比较 updated：区分 new、metadataUpdated、unchanged。
- 解析并持久化论文 authors/order、documents/fulltext、all sourced titles/abstracts、publication info、figures。
- 选中论文时可按需 GET /api/literature/<id> 补全 detail；失败不清空 search metadata。
- 实现 markRead/markUnread；当前蓝点不能永远存在。新增 filter 应定义为 firstSeen 后未读，命名与逻辑一致。
- UI 显示 author last sync、当前 batch、new/updated count、stale/error；不能用一次 ready 冒充“INSPIRE 在线”。
- 添加 author INSPIRE link、h(all)/h(published) 和 native/preferred name。

### R6 — P0：统一 Task ownership、取消与状态机

当前问题：

- manual generateSelectedInsight() 没把当前 Task 保存为 analysisTask，取消按钮可能取消旧 task 而不是当前请求。
- workflow 捕获 CancellationError 后抛 LatticeLensError.cancelled；AppViewModel 可能把 cancelled 再改成 failed。
- author index/paper sync 没有可操作的 task handle/cancel UI。

要求：

1. 每类长任务只有一个 owner：authorIndexTask、paperSyncTasks[recid]、insightTask。
2. auto/manual/regenerate/Deep 的所有 LLM 调用走同一 task 生命周期；新 selection 必须取消并 await/隔离旧 session。
3. cancellation 保持 terminal cancelled，不转 failed；旧 delta/完成回调以 session id 丢弃。
4. last successful artifact 在 regenerate/cancel/fail 期间仍显示，并明确“当前显示上一次成功结果”。
5. 状态至少包括 connecting/waitingFirstContent/receiving/validating/completed/cancelled/failed，显示 elapsed、received bytes/chars、request i/N。
6. completion 设置 first-content、idle 和 hard resource timeout；streaming 失败不能静默改发 non-streaming。

### R7 — P0：修复 LLM schema、cache 与隐私边界

要求：

- paper-insight-v1 和 Deep translation decoder 拒绝 unknown keys、duplicate keys、控制字符、空关键字段、超长 arrays/strings 和尾随内容。
- streaming 过程中施加 response byte 上限，不是全部读入后才检查 1 MB。
- 数值 anchor 必须按 token boundary/单位规范匹配，不允许 claim 中 2 因 source 中 2024 而通过。
- 所有可构成物理论断的字段都做 evidence validation，不只 mainResults/latticeConventionsReported。
- cache key 加入 insightSchemaVersion/sourceScope/maximumFigures/terminologyHash/providerCapability；设置从 3 figures 改为 0 时不能命中旧 3-figure artifact。
- prompt payload 明确携带 maximum figures；0 张时要求空 array。
- privacy consent 绑定 provider + normalizedBaseURL + sourceScope + sendsImagePixels。切 provider/Base URL 或开启 vision 时必须重新提示。
- endpoint redirect 每跳重验 scheme/host；Authorization 不得被带到未授权 origin。
- input title/abstract/caption 数量与字节上限显式化；超限时本地可见地截断/选择，记录 provenance。

### R8 — P0：补齐 Speech2AI 风格设置能力

要求：

- 每个 provider+normalized Base URL 独立 model discovery cache。
- 显示 saved API Key status；支持“替换并保存”和“清除 API Key”，清除后 credential revision 增加并取消相关请求。
- model list 可搜索；保存的 model 即使当前列表缺失仍保持 picker 可表示；manual model 始终可 fallback。
- discovery 可使用已保存 Keychain key，不要求用户每次重新输入。
- provider/Base URL/model/key 变化使 frozen LLM session 失效；无关 UI search 不影响 session。
- Base URL policy 与文档一致：Release HTTPS；Debug 只允许 loopback HTTP；userinfo/query/fragment 明确拒绝或明确规范化，测试与 UI 文案必须一致。v2 默认选择“拒绝 query/fragment”。
- 增加 bounded terminology list，作为不可信 JSON data 发送，不直接改写论文原文。

### R9 — P0：持久化失败必须 fail visible

当前 SwiftData/JSON store 在 decode/fetch 失败时可静默返回空 LibrarySnapshot；这会把 corruption 伪装成首次启动。JSON backup 也不会稳定轮换/恢复。

要求：

- store initialization 返回明确状态：ready/migrated/recovered/readOnlyFailure。
- decode/fetch/migration 失败不得自动写空库覆盖旧数据。
- v1 snapshot 在首次 v2 migration 前创建带 timestamp/checksum 的本地 backup；migration 成功后再切换。
- JSON fallback 必须说明为何启用，并能验证/恢复最新有效 backup；不要 silent fallback 到临时目录。
- 为 v2 引入真正的 VersionedSchema V2 与 migration tests，不允许只把 schema version 数字改为 2。
- persistence tests 使用 task-local temporary directory/container，覆盖重启、corruption、migration、rollback、concurrent upsert。
- clear image cache 只能清理 LatticeLens image cache；当前 URLCache.shared.removeAllCachedResponses() 会同时影响 metadata/LLM response cache，文案不准确。

### R10 — P0：补齐 Paper Lens 的 v1 展示承诺

要求：

- 概览同时展示中文标题、原始标题、中文摘要、原摘要及 source badge。
- 没有 abstract 时仍允许只翻译 title，并明确禁用摘要级物理解释；不能像当前实现一样把标题翻译也一起拒绝。
- 物理解释把 direct evidence、labeled inference、missing information 分开；不能只用 section 标题暗示来源。
- 重要图像展示 thumbnail、原图、原 caption、caption_zh、选择理由、source/filename 和 caption-only badge。
- 图片点击打开 app 内安全的原尺寸/Quick Look 风格窗口；只允许源自 INSPIRE record 的 HTTPS URL。
- 原始资料补 authors/order、documents/fulltext、所有 titles/abstracts、publication info、record updated、INSPIRE JSON/网页 link。
- 实现本地 bundled Markdown + TeX renderer；不加载远程 JS，不允许 LLM HTML/JS 直接执行；原始 LaTeX 可复制。
- 增加复制 validated Markdown note 与导出 .md；导出不含 key/Base URL/internal metadata。
- 所有空/失败状态都有明确降级：no abstract、no figures、bad image、multiple abstracts、LLM failed、offline。

### R11 — P0：真正的 macOS app target 与 UI tests

当前 Swift Package build product 是 Mach-O executable，不是 .app。**Tests/LatticeLensUITests/AccessibilityFixtureTests.swift** 没有 XCUIApplication。

要求：

1. 创建共享 LatticeLens.xcodeproj/scheme，包含 macOS app、unit tests、UI tests；不要复制两套业务源码。
2. 建议把当前非 @main 代码重组为 local package/library target，Xcode app target 只持有 app entry、Info.plist、assets、entitlements 和 dependency container。
3. shared project 不保存个人 Team、证书或 Keychain credential；本地 Debug UI test 使用可复现的 local/ad-hoc signing 配置。
4. UI fixture 通过 launch argument/environment 注入独立 temp store、mock INSPIRE、mock Keychain、mock LLM、mock image；不访问公网、用户数据库、用户 Defaults、用户 Keychain 或通用 clipboard。
5. UI tests 必须实际启动 XCUIApplication，覆盖 self 置顶、Z section、name search、author sync、paper selection、Fast progress/cancel/cache、four tabs、figure degradation、settings/key clear、offline stale。
6. build product 中必须存在 LatticeLens.app；archive 结构和 bundle metadata 单独验证。

### R12 — P1：修正文档与实现不一致

完成代码后更新 README.md，逐项删除或修正当前没有证据的陈述，特别是：

- checkpoint 可恢复；
- SwiftData migration/backup；
- 完整 UI tests；
- 图像 cache 只影响图像；
- endpoint 拒绝 query/fragment；
- live INSPIRE 主路径。

README 必须引用 VALIDATION_V2.md 的具体 gate，不写无证据的“已完成”。

## 3. v2 新产品目标

只有 R1–R11 的 P0 gate 通过后，才进入本节。v2 的主线不是堆更多装饰，而是把“摘要级 AI 卡片”升级为“可追溯全文证据的研究阅读器”。

### V2-1 — 全文证据管线

#### 数据来源

优先顺序：

1. INSPIRE literature record 的 documents 中可公开访问的 fulltext；
2. arXiv PDF；
3. 无全文时退回 title + abstract + figure captions。

要求：

- 下载必须由用户选择论文后的明确动作或设置授权触发；显示 URL、source、预计/实际 bytes、下载/删除状态。
- 只接受 HTTPS，限制最大文件大小、MIME/type、redirect origin；使用 SHA-256 去重与完整性记录。
- PDF 保存到 LatticeLens 自有 Application Support/Caches，不写工作目录；用户可逐篇删除或清空全文 cache。
- 使用 PDFKit 按页提取文本，保存 page number、section guess、character range、quote hash；OCR 不在 v2 P0，扫描 PDF 显式标 text extraction unavailable。
- PDF 提取失败不影响 metadata/摘要模式。
- 不能因文档 URL 存在就声称全文已读；只有 extraction 成功且 anchor 可回查时 source scope 才升级。

建议模型：

~~~swift
struct FullTextDocument {
    let paperID: Int
    let sourceURL: URL
    let sourceKind: SourceKind
    let sha256: String
    let byteCount: Int
    let pageCount: Int?
    let extractionState: ExtractionState
    let downloadedAt: Date
}

struct EvidenceAnchor {
    let id: String
    let paperID: Int
    let sourceKind: SourceKind       // abstract, caption, pdf
    let page: Int?
    let section: String?
    let quote: String
    let quoteHash: String
}
~~~

#### 检索与 LLM 输入

- 先做 deterministic local chunking；页边界不可丢。
- 每个 chunk 有 stable id 和 token/byte count。
- Deep explanation 只接收 bounded retrieved chunks；记录 retrieval query、chunk ids 和 prompt version。
- v2 不要求引入云 vector database。若使用 embedding，默认本地或用户显式配置，并同样进入隐私 disclosure。
- 每条 direct claim 必须返回 evidence anchor ids；app 只接受本次 allowlist 中的 ids。

### V2-2 — paper-insight-v2：直接证据、推断与未知量

建议 schema：

~~~json
{
  "schema_version": "paper-insight-v2",
  "source_scope": "fulltext_with_anchors",
  "title_zh": "...",
  "abstract_zh": "...",
  "physics": {
    "research_question": {
      "text_zh": "...",
      "epistemic_status": "direct",
      "evidence_ids": ["pdf:p2:q1"]
    },
    "method_and_data_flow": [
      {
        "text_zh": "...",
        "epistemic_status": "direct",
        "evidence_ids": ["pdf:p4:q2"]
      }
    ],
    "main_results": [],
    "reasonable_inferences": [],
    "missing_information": [],
    "caveats": []
  },
  "important_figures": [],
  "terminology": []
}
~~~

规则：

- direct 必须至少一个有效 anchor；inference 必须显式标注且至少引用其推断依据；missing 不得伪造 anchor。
- UI 点击 anchor 可跳到原摘要/caption/PDF 页并高亮 quote。
- 精确数值、单位、ensemble、lattice spacing、volume、mass、renormalization scheme、fit range、statistics 和 uncertainty 必须逐 token/单位匹配 evidence。
- source scope 只能由 app 决定：abstract_caption、fulltext_with_anchors、fulltext_plus_vision。
- schema validator 必须拒绝 unknown enum、unknown anchor、unknown figure、重复 key、额外根字段和超限内容。

### V2-3 — 可选 vision 图像解释

vision 是独立、显式、可审计的额外请求，不得把 caption-only 自动升级为“看图分析”。

要求：

- Provider profile 增加用户手工确认的 supportsVision capability；不能从 model 名称猜测。
- 首次发送图像像素前重新 disclosure；显示图像数、缩放后尺寸/bytes、目标 endpoint 和额外请求次数。
- 默认最多 3 张，由 caption ranking 先选；本地 downsample，保留原图 hash，不上传 PDF 其他页面。
- vision response 只允许引用本次 image key；evidence_mode=vision 与 caption_only 分开保存和展示。
- vision 失败时保留 caption-only artifact；不能覆盖成功的文本解释。
- UI 明确写“模型查看了缩放图像像素”或“模型只读取 caption”。

请求计数必须显式：

| 模式 | 请求 |
| --- | --- |
| Fast | 1 次 text |
| Deep abstract | 2 次 text |
| Deep fulltext | 最多 2 次 text，输入为 bounded evidence chunks |
| Vision | 在上述基础上额外 1 次 multimodal |

### V2-4 — 真正的 reference manager 功能

v2 P0：

- paper read/unread、favorite、用户 note；
- local tags 与 collections，多对多关系；
- 全局 paper search：title、author、arXiv id、DOI、tag、collection、note；
- BibTeX 导出：优先 INSPIRE BibTeX endpoint，保存 source timestamp；失败时不自造缺失字段；
- Markdown reading note 导出：原始 citation、中文 title/abstract、validated claims、evidence links、figure provenance；
- tracked author 新增/更新中心，按 batch 显示 new/metadataUpdated/citationChanged。

v2 P1：

- macOS local notification（用户显式授权后）；
- citation history plot；
- batch export；
- saved smart filters。

仍延后到 v3：

- iCloud/CloudKit；
- collaboration graph/主题聚类/citation graph；
- 团队账户与在线同步；
- 自动修改 INSPIRE record。

### V2-5 — v2 界面：Evidence Lens

保留三栏主结构，但做以下升级：

~~~text
┌ AUTHORS ─────────┬ PAPERS / UPDATES ────────┬ EVIDENCE LENS ─────────────────────────┐
│ ★ 我的主页       │ [论文] [更新] [收藏]     │ 中文标题 / Original title              │
│ [姓名搜索]       │ [全局论文搜索]           │ scope: fulltext_with_anchors            │
│ A…Z              │ Year sections            │ [概览][物理][图像][证据][原始资料]      │
│                  │ new / updated / cited     │ claim ── [PDF p.4] [caption fig2]       │
│ Index progress   │ Sync batch progress       │ direct / inference / missing             │
└──────────────────┴──────────────────────────┴──────────────────────────────────────────┘
~~~

- 证据 tab 展示所有 anchor，支持按 abstract/caption/PDF 过滤和跳转。
- 物理解释中每条 claim 右侧必须有 status badge 和 evidence chips。
- 顶部 connectivity 只表示最近一次 probe/sync 的真实状态，包含时间；不能把任一 ready 状态写成永久在线。
- toolbar 显示 active provider/model、source scope、text/vision request count。
- Sync Center sheet 显示 author-index、h-index、tracked-paper、fulltext jobs，均可暂停/继续/取消。
- 所有核心状态具备 accessibility label/value/hint，不依赖颜色。

## 4. v2 持久化与迁移

v2 至少新增：

- ReadingState
- UserNote
- Tag
- Collection
- PaperTagLink / CollectionPaperLink
- CitationSnapshot
- FullTextDocument
- EvidenceChunk
- EvidenceAnchor
- VisionArtifact
- SyncBatch

迁移要求：

1. v1 authors/papers/h-index/insights/checkpoints 不丢失。
2. v1 Paper.isRead 映射为 v2 ReadingState；没有真实 read event 的记录保持 unread，不伪造时间。
3. v1 paper-insight-v1 保留，只标 source scope；不假装迁移为带 anchors 的 v2 insight。
4. v2 cache key 包含 paper/document hash、evidence chunk set、prompt/schema、provider/model/credential、mode/detail/maxFigures/vision capability/terminology。
5. migration 前后分别记录 count/hash；rollback test 必须恢复 v1 backup。

优先采用规范化 SwiftData entities，而不是继续把所有数据塞进一个 snapshotData blob；如果保留 blob，必须给出性能、迁移和并发测试证据，不能仅以“实现简单”为理由。

## 5. 网络与同步契约

### 5.1 INSPIRE GET

- 请求超时、总资源时限、最大响应 bytes 明确。
- 仅对幂等 GET 自动 retry；建议只重试 transport、429、502、503、504，设 bounded attempts 和 jitter/backoff。
- 尊重实际出现的 Retry-After、X-RateLimit-*；header 不存在时不猜服务限额。
- author detail 在有 ETag 时使用 If-None-Match；304 不重新 decode。
- next link 每页重新验证；禁止非 HTTPS、不同 host、userinfo、fragment 和非预期 API path。
- 所有 sync job 的 query、page、counts、timing、HTTP status/error class 可审计，但不记录完整 abstract/Key/API payload。

### 5.2 LLM POST

- 不自动 retry completion POST；用户显式重试生成新 request id。
- SSE/non-streaming 是 profile capability，不做隐式 transport fallback。
- first content、stream idle、hard resource timeout 分开。
- 日志只含 provider id、model id、phase、bytes、duration、request id；Base URL 只保存 normalized/redacted display。
- redirect policy fail closed；错误 body 做 bounded/redacted parsing。

## 6. 实施顺序与里程碑

### Phase 0 — 冻结审计基线

- 保存现有文件 manifest/hash，不改 v1 方案。
- 把本文件的 v1 matrix 转成 issue checklist。
- 建立 VALIDATION_V2.md 和 machine-readable validation-v2.json 空 ledger。

通过标准：ledger 能区分 local fixture、live INSPIRE、live provider、GUI/manual、signing/release。

### Phase 1 — live INSPIRE recovery

- 完成 R1–R5、R11 中的 live DTO/unit 基础。
- 真实 nested fixtures；checkpoint resume；self/A–Z invariants；tracked sync/read state。

通过标准：在 fresh temp store 中，live self 加载、candidate first page、至少一个 h summary、本人全部文献分页均语义成功；测试不写死易变 totals。

### Phase 2 — task/persistence/security recovery

- 完成 R6–R9。
- timeout/cancel/retry/conditional request、strict schema、cache/consent、migration/corruption。

通过标准：failure injection 全部保持旧数据；cancel 不变 failed；provider/endpoint 变化重新 disclosure；v1→v2 migration/rollback 通过。

### Phase 3 — app target 与 v1 UI closeout

- 完成 R10–R12 和真实 app/UI tests。
- 数学 renderer、figure captionZH/Quick Look、source metadata、Markdown export。

通过标准：生成 LatticeLens.app；隔离 UI tests 启动 app 并覆盖 v1 主路径；Xcode test 正常退出，不出现本轮 145 s finalization hang。

### Phase 4 — fulltext evidence v2

- 完成 V2-1、V2-2、schema/prompt/golden rubric。

通过标准：至少一个 local fixture PDF 能产生 page anchors；每条 direct/numeric claim 可点击回查；无全文时可靠降级。

### Phase 5 — vision 与 reference manager

- 完成 V2-3、V2-4、V2-5。

通过标准：mock vision/caption paths 分离；tag/collection/note/read/favorite 持久化；BibTeX/Markdown export 可重现且不含 secret。

### Phase 6 — local candidate

- unit/integration/UI/build/analyze/archive、sanitizer（适用范围）、VoiceOver/manual、live ledgers。
- 打包本机 local-development candidate；没有 Developer ID/notarization 时明确标注。

通过标准：所有 P0 gates 有对应 artifact；任何 external blocker 保持 Partial，不写 Final Release。

## 7. 必须新增/扩充的测试

### 7.1 Unit/contract

- 真实 nested INSPIRE envelope、next links、total；
- 20/21 h threshold、self included/excluded 口径、local fallback；
- candidate refresh 保留 old h，failed 转 stale；
- self search invariant、Z section、selection tag；
- checkpoint resume/complete/new generation；
- paper new/updated/unchanged/read/unread；
- author/documents/fulltext/figures mapping；
- endpoint/redirect/ETag/304/429/Retry-After/max bytes；
- API Key save/read/delete、credential revision；
- SSE partial UTF-8、CRLF、comments/empty events、provider error、missing DONE、size/idle timeout；
- strict JSON unknown/duplicate/control/trailing/oversize；
- numeric unit anchors、unknown evidence/figure ids；
- cache key 受 maxFigures/source/document/vision/terminology 影响；
- v1→v2 migration、corruption、backup/rollback。

### 7.2 Integration

- URLProtocol scripted multi-page author/literature sync；
- page 2 failure + process/store recreation + resume；
- h queue cancellation + resume；
- tracked authors launch refresh with concurrency cap；
- automatic selection debounce only sends one request；
- Fast 1 request、Deep 2 requests、Vision +1 request；
- cancellation during first token/stream/validation；
- last successful artifact preserved；
- PDF download/extract/chunk/anchor/cache/delete；
- export contains provenance but no key/base URL/internal logs。

### 7.3 UI

必须使用 XCUIApplication，至少覆盖：

1. self 永久置顶，search Bali 时 self 仍显示；
2. 普通 Z 作者仍显示；
3. build/resume index progress 与 cancel；
4. tracked author、paper sync、new→read；
5. 四/五 tabs、no abstract/no figure/bad image；
6. Fast auto debounce、cancel、cache hit、regenerate preserves prior；
7. provider switch、saved key status、model search/manual fallback、clear key；
8. fulltext scope/anchor jump；
9. caption-only vs vision badge；
10. tag/collection/note/export。

fixture UI bundle 不允许访问 live network、真实 Keychain、用户 Defaults、用户 database 或通用 clipboard。

### 7.4 Live/manual

- live INSPIRE：self author、candidate page、h summary、literature pagination、one figure/fulltext（若存在）；
- live provider：只有用户授权并配置 API Key 时分别验证 OpenAI、DeepSeek/custom；一次成功不外推；
- manual physics rubric：至少覆盖 lattice parameters、renormalization、Fourier/source-sink conventions、missing information 和 numeric anchors；
- VoiceOver、keyboard、window resizing、offline recovery；
- signing/archive/notarization 分层。

## 8. Gate 与完成定义

| Gate | 必须证据 | 失败含义 |
| --- | --- | --- |
| A — Clean build | SwiftPM + Xcode Debug/Release warnings-as-errors | 不能继续称 candidate |
| B — Local tests | unit/integration 全通过、无 live dependency | 本地 contract 未完成 |
| C — Live INSPIRE | 当前 API nested shape 与主路径 smoke 成功 | 核心产品不可用 |
| D — Persistence/recovery | restart/resume/migration/corruption/rollback | 不可安全保存用户库 |
| E — Real UI | LatticeLens.app + XCUIApplication tests 正常退出 | GUI 未完成 |
| F — v2 evidence | PDF anchors + paper-insight-v2 direct claims 可回查 | 只能称 v1 摘要级 |
| G — reference manager | read/tag/collection/note/export 持久化 | v2 产品目标未完成 |
| H — live LLM | 每个已授权 provider 独立 ledger | 未验证 provider 不可声称支持 |
| I — local release | archive/package manifest/manual accessibility | 不能称 local candidate |
| J — public release | Developer ID/notarization/Gatekeeper/cross-machine | 未完成公开分发 |

严格状态规则：

- v1 recovered：A–E 全通过；F–G 可未开始。
- v2 local complete：A–G 全通过；H 中未授权 provider 可标 external not run，但 UI/mock contract 必须通过。
- v2 local candidate：A–I 全通过。
- Final/Public Release：J 也通过。

## 9. 建议验证命令

所有临时产物写入本轮 .codex-task-tmp-<timestamp>/，结束后删除。scheme/target 名若调整，先同步 README 与 verifier。

~~~bash
swift test --scratch-path .codex-task-tmp-<run>/swift-test

swift build -c release \
  --scratch-path .codex-task-tmp-<run>/swift-release \
  -Xswiftc -warnings-as-errors

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project LatticeLens.xcodeproj -scheme LatticeLens \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .codex-task-tmp-<run>/debug \
  CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  SWIFT_STRICT_CONCURRENCY=complete build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project LatticeLens.xcodeproj -scheme LatticeLens \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .codex-task-tmp-<run>/unit \
  -resultBundlePath .codex-task-tmp-<run>/unit.xcresult \
  CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  SWIFT_STRICT_CONCURRENCY=complete \
  -only-testing:LatticeLensTests test
~~~

UI test 需要可启动的本地签名 app。shared project 不写个人 Team；在当前机器确定可复现的 local/ad-hoc signing 参数后，把精确命令写入 verifier，不能直接沿用 CODE_SIGNING_ALLOWED=NO 并声称 UI 已跑。

还需要提供一个单命令 verifier，例如：

~~~bash
zsh Scripts/verify_v2.sh
~~~

它必须返回非零以表示任何 mandatory local gate 失败，并输出 machine-readable summary；不能只依赖最后一个 shell exit code 而忽略前面失败。

## 10. Terra 最终交付物

至少交付：

- 修复后的 Sources、Tests、fixtures；
- LatticeLens.xcodeproj 与 shared scheme；
- 可启动的 LatticeLens.app 本地 build 证据；
- Scripts/verify_v2.sh；
- VALIDATION_V2.md；
- validation-v2.json；
- v1→v2 migration/rollback fixtures；
- PDF/evidence/vision/reference-manager tests；
- 更新后的 README.md；
- 如生成本机 candidate，独立 Release-v2 manifest、安装/回滚说明和 SHA-256。

最终回复必须列出：

1. v1 修复 verdict；
2. v2 实现 verdict；
3. changed/new files；
4. 精确 commands、test counts、exit status 和 artifacts；
5. live INSPIRE ledger；
6. live provider 分项结果或未授权边界；
7. GUI/VoiceOver/signing/notarization/cross-machine 边界；
8. cleanup：只删除本轮临时文件和进程，不触碰用户既有 cache/data；
9. 剩余 P0/P1，不允许笼统写“后续优化”。

## 11. 审计中的关键代码定位

| 问题 | 当前定位 |
| --- | --- |
| live search envelope 错误 | Sources/LatticeLens/Core/Networking/InspireDTO.swift:62 |
| author candidates decode | Sources/LatticeLens/Core/Networking/InspireClient.swift:38 |
| literature decode | Sources/LatticeLens/Core/Networking/InspireClient.swift:60 |
| candidate checkpoint 只写 | Sources/LatticeLens/Features/Authors/AuthorIndexService.swift:84 |
| h-index 一次性末尾保存 | Sources/LatticeLens/Features/Authors/AuthorIndexService.swift:117 |
| paper checkpoint 只写 | Sources/LatticeLens/Features/Library/PaperSyncService.swift:23 |
| tracked authors 未启动刷新 | Sources/LatticeLens/App/AppViewModel.swift:62 |
| manual insight task ownership | Sources/LatticeLens/App/AppViewModel.swift:135 |
| cancellation 状态覆盖 | Sources/LatticeLens/App/AppViewModel.swift:211 与 Sources/LatticeLens/LLM/Workflow/InsightWorkflow.swift:74 |
| shared URLCache 全清 | Sources/LatticeLens/App/AppViewModel.swift:188 |
| Z section 被过滤 | Sources/LatticeLens/Features/PaperLens/MainWorkspaceView.swift:60 |
| search 触发 start/network | Sources/LatticeLens/Features/PaperLens/MainWorkspaceView.swift:68 |
| unread 永不转 read | Sources/LatticeLens/Core/Models/DomainModels.swift:103；没有 mark-read API |
| cache key 缺 maxFigures | Sources/LatticeLens/Core/Models/DomainModels.swift:151 |
| consent 未绑定 endpoint | Sources/LatticeLens/LLM/Provider/LLMSettings.swift:52 |
| SwiftData decode fail 返回空库 | Sources/LatticeLens/Core/Persistence/SwiftDataLibraryStore.swift:93 |
| JSON corruption 返回空库 | Sources/LatticeLens/Core/Persistence/LibraryStore.swift:69 |
| UI tests 没有 app launch | Tests/LatticeLensUITests/AccessibilityFixtureTests.swift:1 |

## 12. 最后约束

- v1 冻结口径保持：本人 recid 2010363 置顶；ordinary author 默认以 INSPIRE author arxiv_categories contains hep-lat 为候选；严格 h(all, including self-citations)>20。
- 若增加 cross-list historical coverage，必须作为另一个可选 scope，单独命名、计算和展示，不能静默改变 v1 集合。
- v2 fulltext/vision 只扩大证据范围，不改变论文原始 metadata；每条扩大后的 claim 都必须有 provenance。
- 不因 PDF、图像或 LLM 失败清除本地文献库。
- 不伪造论文图、引用、格点参数、误差、结论或模型能力。
- 信息足够时直接实施；只有会改变上述筛选口径、数据迁移或 provider 隐私范围的缺失信息才需要向用户提问。
