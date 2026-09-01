# LatticeLens

> 当前开发候选为 **LatticeLens 1.0.1 (101)**，仍是 same-Mac local candidate，尚非
> notarized/final release。它在 `release-assets/Release-1.0.1-local/` 中带有独立的
> `manifest-v1.0.1.json` 与 `SHA256SUMS.txt`；安装前必须核对其中的哈希及 Finder 的
> 版本号和 executable SHA-256，而不能以同样显示为 `1.0.1 (101)` 的旧
> `/Applications` 二进制代替它。当前发布包的 executable SHA-256 是
> `c39214603c5a59ae56545530707e4dbf3638fde4fb71750f2c5795f1a137017f`。
> 当前 verifier 会执行 SwiftPM、actual SwiftData disk benchmark、Xcode build/analyze/unit、normal/
> large fixture UI、synthetic disposable V7 migration、typed-store/physics/Radar/Compare/Notebook/
> Bundle 与 same-Mac DMG smoke；其成功仍不替代下列人工 P0 gate。
>
> 1.0.0 的历史自动化入口是 `zsh Scripts/verify_v5.sh --local-only`；只有 non-empty build-input manifest
> 所绑定的 verifier 才可作为 candidate。它真实执行 fixture UI、SwiftData disk benchmark、synthetic
> disposable V7 migration 和 same-Mac DMG smoke；不能用历史 `.xcresult`、单用例或静态 build 代替它。
> 2026-08-28 起，UI gate 是一次性 selected UI delta：1 个 normal case（Sync Center 滚动）与 2 个 large
> case（虚拟化作者选择、长 Settings 滚动），每个 case 均单独启动 fixture app 并生成一份可读 result。三种窗口
> 尺寸观察保留为人工 P0 receipt。完整 26-case fixture suite 仍用于开发回归，不再是该同机 release 的非重复
> 封存 gate；manifest 会记录该范围和确切计数。
> 对当前 **1.0.1 (101)** 安装包，使用
> `zsh Scripts/verify_v1_0_1_seal.sh --manual-receipt evidence/ManualAcceptanceReceipt-v1.0.1-*.json`
> 进行最终封存。该轻量脚本会校验两份 release DMG 的字节一致性、DMG image、当前
> `/Applications/LatticeLens.app` 的版本/签名/executable hash，并要求 receipt 精确绑定
> `manifest-v1.0.1.json`；它不把旧 1.0.0 的自动化记录冒充为 1.0.1 的新测试。
> 需要人工观察的最小清单与可直接回复的确认语句见
> [MANUAL_1_0_1_ACCEPTANCE.md](MANUAL_1_0_1_ACCEPTANCE.md)。
>
> 目前仍 fail-closed 的 1.0 边界是：真实 VoiceOver/Accessibility Inspector 与三种窗口尺寸观察、
> 三篇 sanitized LQCD fixture rubric、用户选择下的 `/Applications` install/uninstall/app+data
> rollback 演练。已审核的 207-path cleanup whitelist 已依
> `CleanupApplyReceipt-v1.0-20260828T030918Z.json` 删除；未完成这些人工事实前，仍不得称为
> `Reference_manager 1.0 final`。
>
> 所有 migration drill 仅使用用户授权的 synthetic/disposable V7 store family（主 `.store` 及存在时
> 的 `-wal`/`-shm`），绝不读取真实 active library。Developer ID、公证、Gatekeeper public release、
> cross-Mac install、live INSPIRE 与 paid/live LLM 不属于 1.0 local-only mandatory scope。
>
> [VALIDATION_V4.md]($PROJECT_ROOT/VALIDATION_V4.md) 与历史 v4
> release 目录仅保留为历史 fixture evidence，不能代表当前源码或 1.0 release 通过。

> v2 implementation status: the local evidence-reader and core reference
> manager paths have completed their local contract gates. See
> [VALIDATION_V2.md]($PROJECT_ROOT/VALIDATION_V2.md)
> for the audited ledger; it is not a v2 public-release claim.

LatticeLens 是一个原生 macOS SwiftUI 文献工作台，面向 INSPIRE 的 hep-lat / hep-th 作者与论文资料浏览。它实现了 `INSPIRE文献管理器_开工方案_v1.md` 冻结的 v1 约定：

- 作者候选仅指 `author.arxiv_categories` 含 `hep-lat` 或 `hep-th` 的 INSPIRE author record；完成 h-index 校验后仅展示 `h > 20`，不是历史 cross-list 合作者全集。
- 固定 INSPIRE recid `2010363` 为“我的主页”，无论 h-index 都置顶。
- 正式作者列表仅包含经验证的 `INSPIRE h(all, including self-citations) > 20`。`20` 不合格；请求失败保持 `failed/unknown`，绝不写成 `0` 或“不合格”。
- Paper Lens 默认只使用标题、摘要和 INSPIRE figure captions；有 arXiv ID 时优先提供对应的 ar5iv HTML 直链。用户明确确认后才读取受限 HTML（不下载 INSPIRE PDF）并生成 bounded evidence anchors；PDF 仅作为明确标注的回退路径。全文来源、URL、SHA-256 和提取状态会保留；不声称模型看过图像像素。

当记录存在 arXiv ID 时，Paper Lens 会提供明确标注的 ar5iv HTML 入口（`https://ar5iv.labs.arxiv.org/html/<arXiv-ID>`），无论 INSPIRE 是否提供 PDF。该链接可直接在浏览器打开；若要生成证据和公式推导，用户再确认一次受限 HTML 读取。ar5iv 是 LaTeX→HTML 的渲染服务，个别论文可能转换失败或缺少公式/结构；失败时应用保持原始 metadata 可用，不把失败伪装成全文成功。没有 arXiv ID 的记录仍只能使用其受信任的 INSPIRE 文档。

## 打开与运行

本工程是 macOS 14+ 的原生 SwiftUI app。可直接打开 [LatticeLens.xcodeproj]($PROJECT_ROOT/LatticeLens.xcodeproj/project.pbxproj) 的共享 `LatticeLens` scheme；保留 `Package.swift` 是为了在无图形界面的环境中运行同一份业务源码的快速 fixture test。工程包含：

- `LatticeLens`：macOS application target；
- `LatticeLensTests`：unit / integration fixture target；
- `LatticeLens-Unit`：只包含 `LatticeLensTests` 的共享 Xcode unit scheme；它将 host-free XCTest 与 UI
  bundle 分离，但仍必须由本轮可读 `.xcresult` 证明执行；
- `LatticeLensUITests`：真实 `XCUIApplication` target，通过 `-LatticeLensUseFixtures YES` 显式注入内存 fixture，不读取个人资料库、不访问 INSPIRE、provider 或 Keychain。

也可在终端中运行：

```bash
cd $PROJECT_ROOT
swift run LatticeLens
```

首启时会优先请求并缓存本人作者 record；点击“构建 hep-lat / hep-th 作者索引”后才会分页加载候选并以最多两个并发请求计算 h-index。选择作者时先显示本地论文，只有尚无本地数据才自动同步；分页每成功一页立即 upsert 与保存 checkpoint。已关注作者会在“置顶作者”区保持可见。无 abstract 的记录仅在用户同意后发送标题以生成严格的中文标题；不会生成物理解释或标题扩写的论文结论。

## 项目结构

```text
Sources/LatticeLens/
├── App/                     # App entry 与主状态机
├── Core/
│   ├── Models/              # 规范化 domain models 与筛选契约
│   ├── Networking/          # INSPIRE DTO、受信分页与 HTTP client
│   ├── Persistence/         # V1–V7→V8 core staged migration、V9 indexed active store 与 actor repository
│   └── Support/             # 哈希、clock、错误分类、搜索归一化
    ├── Features/
    │   ├── Authors/             # 候选索引、HIndexQueue、A-Z/search
    │   ├── Library/             # paper sync、checkpoint、upsert
    │   ├── PaperLens/           # 三栏界面、Evidence 第五 tab、图像 lazy-load
    │   ├── Workbench/           # v3 Radar、Compare/physics contract、Notebook/export
    │   └── Settings/            # provider、模型、隐私与分析选项
└── LLM/
    ├── Provider/            # Keychain、endpoint 验证、OpenAI-compatible SSE
    ├── Prompt/              # versioned system/user JSON contracts
    ├── Schema/              # paper-insight-v1 strict decoder/validator
    └── Workflow/            # cache、Fast/Deep、状态与取消
```

当前 active library 是 V8 typed SwiftData domain core 加 V9 durable local-search projection：作者、论文、link、checkpoint、reading state、notes、tags、collections、PDF/blob/reference、evidence、Radar、Compare、Notebook、Bundle 和 migration/backup record 均以稳定 ID 的独立 row 持久化。V9 token/reverse-token rows 是可重建投影；日常更新只修改受影响 paper 的 posting，`searchPapers` 不再 materialize 整个 `LibrarySnapshot`。`LibrarySnapshot` 只保留为 fixture、export/compatibility import 和只读 UI projection，不是 active truth，也不会作为正常 mutation 前的全库 rewrite 输入。V1–V7 source 会先复制带 SHA-256 的完整 store family，写入外置 journal，再在独立 V8 core staging store 完成 semantic verification，继而开启 V9 index 后激活；失败时 UI 进入只读恢复状态，绝不以空 JSON library 或 silent fallback 覆盖旧资料。所有 store 均 actor 隔离，SwiftUI 只接收不可变 projection。

## LLM 与隐私

- Provider profile 分别保存 Base URL、选择或手工 model ID 与 streaming capability；`OpenAI`、`DeepSeek` 和 OpenAI-compatible HTTPS endpoint 均可配置。
- API Key 只写入 macOS Keychain。它不会写入 `UserDefaults`、SwiftData、日志、fixture、导出或 UI 截图资料。credential revision 只是一枚递增整数，用于使缓存失效，不是 key 或 key hash。
- Release endpoint 必须是 HTTPS。Debug 仅允许 `localhost`、`127.0.0.1` 或 `::1` 使用 HTTP；拒绝 URL 中的 user/password、query 和 fragment。
- Fast 模式发送一次请求。Deep 模式严格发送两次：先从原始标题/摘要取得严格 JSON 翻译，再携带冻结翻译和原始资料生成解释。SSE 失败不会静默回退成 non-streaming 或重发。
- `paper-insight-v1` 会校验 JSON 大小、控制字符、重复 key、schema/source scope、figure key allowlist、caption-only 模式和数值陈述的摘要/caption token 锚点；不合格响应不会覆盖原始资料或既有成功 artifact。
- Paper Lens 的“公式与证据”标签在全文提取后会生成**原文重要公式、逐步 LLM 推导、结论与可回查锚点**；它不会把没有 anchor 的内容标记为原文直接支持。该标签中的 TeX、MathML、HTML-escaped MathML 与常见 Greek entities 使用本地原生数学预览，不向页面显示 `<math ...>` transport markup。
- 长公式推导没有应用层总时限：连接最长 120 秒、首段内容最长 180 秒、连续空闲最长 120 秒；健康流会持续到完成或用户取消。状态栏显示累计字符/UTF-8 字节、已等待时间和平均字符/秒，流解析和 UI 更新分别按 16 KiB 或 100 ms、约 250 ms 合并，避免客户端逐 token 更新反压。

### LLM 实际使用检查

1. 在 Settings 中选择 provider，填写 Base URL 和实际 model ID；本地
   OpenAI-compatible 服务默认使用 `http://127.0.0.1:11434/v1`，但 app 不会
   自动启动或捆绑模型进程。
2. 先点“测试连接”，再点“保存”；首次分析会显示发送范围并要求一次隐私确认。
   本地 provider 可以不填 API Key，OpenAI/DeepSeek/HTTPS custom provider 必须把
   API Key 保存到 Keychain。
3. Streaming 可按服务能力开启。客户端同时接受标准 `delta.content`、
   `choices[].text` 和 text-part 数组；兼容服务在 EOF 省略 `[DONE]` 时，只要已有
   有效 JSON 事件也会继续交给严格 schema validator。截断、空响应、错误对象或
   未锚定的数值声明仍会失败，不会静默重试或改发第二种请求。

若出现 `LLM stream idle deadline exceeded`，这表示 provider 在最后一个实际字节后
超过 idle 预算没有任何字节（不是 UI 卡死）。应先确认本地 model 进程和 model ID，
再在设置中关闭 Streaming 做一次明确的非流式请求；若非流式也失败，应查看 provider
自身日志或连接状态。fixture/UI 测试只证明离线替身和 schema/workflow 路径，不冒充
真实 provider 成功。

## 本地验证

```bash
cd $PROJECT_ROOT
./Scripts/verify_v1.sh
```

The current v2 local-only verifier is:

```bash
cd $PROJECT_ROOT
zsh Scripts/verify_v2.sh
```

v3 的 credential-free verifier 仍可复现历史基线：

```bash
cd $PROJECT_ROOT
zsh Scripts/verify_v3.sh
```

它在项目内 scratch 中运行 SwiftPM/Xcode local gates；这些结果属于 v3
recovered baseline，不能外推为当前 v4 UI 或 feature-complete。
本次 source artifact hash 为
`6874485db3aa319d8fafb34821ae11311947f7bb4941f2cc59e2fec7e3c0606c`；可读 UI
fixture summary hash 为
`5b5bef4e91f5e33f671ca6892196ce26d7002705099fd64a752f052b6520b5dc`。

合成大库 benchmark 可单独复现（不读取用户资料库、不生成真实 PDF bytes）：

```bash
python3 Scripts/benchmark_v3.py --output benchmark-v3.json
```

它固定生成 2,000 authors、20,000 papers、100,000 links、100 个 PDF metadata
records，并记录 cold/warm query 的 p50/p95、bounded projection 与 peak RSS。

v3 历史 macOS UI fixture 证据曾使用本地 ad-hoc “Sign to Run Locally” 的两阶段流程：
`build-for-testing` 后 `test-without-building -parallel-testing-enabled NO`，
并从可读 `.xcresult` 汇总 **6 total / 6 passed / 0 failed / 0 skipped**。每个
case 先确认 `fixtureModeIndicator`，再使用 in-memory store、allowlisted local
transport、process-local Keychain 和 local PDF/image substitute；这不是 VoiceOver
手工验收，也不证明真实 Keychain 或签名发布。

credential-free INSPIRE shape smoke 可单独运行：

```bash
zsh Scripts/live_smoke_v3.sh
```

该脚本只执行 credential-free HTTPS GET/HEAD，共验证 9 个 endpoint：self/candidate/
author/literature、facet h-summary、self pagination、BibTeX 以及 PDF/figure HEAD
policy；不保存 raw body、不写回 INSPIRE，也不把当前 total/record id 固化为产品
断言。live LLM、CloudKit、VoiceOver、Developer ID、
notarization、Gatekeeper 和跨机安装仍须独立授权与证据。

`verify_v3.sh` 是历史 baseline verifier；当前 v4 入口为：

```bash
cd $PROJECT_ROOT
zsh Scripts/verify_v4.sh --local-only
```

v4 verifier 会运行 host-free XCTest、SwiftPM Release、Xcode Debug/unit/Release/
analyze/build-for-testing、actual SwiftData normalized-store benchmark，并尝试
fixture-isolated `XCUIApplication`。summary 自动区分 `compiled`、`executed`、
readable `.xcresult` 与 business cases；UI runner 未建立连接时返回非零并保留
compact failure evidence，不会把 `ui_runtime=false` 写成通过。它不执行 live
INSPIRE、LLM POST、CloudKit、用户 Keychain、Developer ID、公证或跨机安装。
默认 Xcode gate 上限为 600 s，UI attempt 上限为 900 s；可仅为诊断目的通过
`LATTICELENS_V4_XCODE_TIMEOUT_SECONDS`、`LATTICELENS_V4_UI_TIMEOUT_SECONDS` 与
`LATTICELENS_V4_UI_MAX_ATTEMPTS` 收紧；UI retry 默认在 host 释放后等待 15 s，亦可用
`LATTICELENS_V4_UI_RETRY_DELAY_SECONDS` 调整。large `.xcresult` 最终化默认最多等待
600 s，也可用 `LATTICELENS_V4_XCRESULT_FINALIZATION_SECONDS` 调整。timeout 仍是失败，
不是跳过或通过。每次 `xcresulttool` 读取还由独立的 30 s 上界保护，可用
`LATTICELENS_V4_XCRESULT_COMMAND_TIMEOUT_SECONDS` 调整。

可选的 credential-free、只读 INSPIRE shape smoke：

```bash
zsh Scripts/live_smoke_v4.sh
```

该命令不携带 credential、不执行 POST，也不把当天 HTTP shape 当成长期服务契约。

2026-08-23 的 v2 历史 SwiftPM gate 为 41 个 XCTest、0 failures。真实
`XCUIApplication` fixture suite 的机器可读 `.xcresult` 为 **6 passed / 0
failed**：分析取消/缓存/坏图降级、作者输入与 self pin、caption-only 与
Vision disclosure 分离、全文 anchors、引用管理控件以及设置表单。每个 case
先验证 `fixtureModeIndicator`，并由 `-LatticeLensUseFixtures YES` 选择
in-memory store、allowlisted local transport 与 process-local Keychain。
这是本机 UI fixture 证据；它不证明 VoiceOver 手工流程、真实 INSPIRE/LLM、
真实 Keychain、签名或公证。请以 `VALIDATION_V2.md` 的 Gate E 为准。

## unsigned local archive

v3 使用独立的 `Release-v3/`，不会覆盖既有 `Release-v2/`：

```bash
zsh Scripts/archive_v3_unsigned.sh
```

生成 `manifest-v3.json`、`INSTALL_AND_ROLLBACK.md`、unsigned archive 与
payload SHA-256。该 artifact 仍是 local pre-candidate，签名/公证/VoiceOver/
Gatekeeper/cross-machine gates 继续明确为 Blocked/Not run。
当前 payload `Release-v3/LatticeLens-v3-unsigned-local.zip` 的 SHA-256 为
`946e695c1cd7be609eaf6fb19cd4bd602ef1fda7f4ce7bc9b48b9940e23b7a61`；archive
目录按 no-overwrite 规则保留，不能据此宣称已包含之后的台账文字更新。

## v4 same-Mac local artifact

v4 使用 no-overwrite 的独立目录，不会覆盖 v2/v3 或历史 v4 release：

```bash
zsh Scripts/archive_v4_local.sh
```

脚本生成 `manifest-v4.json`、`INSTALL_AND_ROLLBACK.md`、Release archive 与
payload SHA-256，并复制当前 v4 ledger、benchmark 与独立 UI summary（若存在）。
artifact class 是 `same_mac_unsigned_local_artifact`；它只适合同一台 Mac 的本地
检查，不能冒充 Developer ID、notarized、Gatekeeper 或 public release。脚本拒绝
覆盖已有输出目录，回滚只删除用户选定的 inspection copy，不触碰 active library、
PDF、Keychain 或旧 release。

历史归档 [Release-v4-local-final-20260826]($PROJECT_ROOT/Release-v4-local-final-20260826) 匹配 source hash
`dd72df978b0c3872539bd46fce271a45f3965cd202a6c014e551185a225d9907`，并记录 current
fixture UI **20/20 passed / 0 failed / 0 skipped**（full action **109/108/0/1**）。
manifest SHA-256 为 `8fa9d662b0dca7924a9db111ace5dc00bf0c8070f18e586b36f817494549d98a`，
payload SHA-256 为 `f684c532870e755705655dfe86e249edcc6de0b3d1cf22eb20c59c88915f338b`；
archive fixture launch/rollback smoke 已通过。它是 `pending_manual_local_drill` 的
unsigned same-Mac candidate，而不是 Developer ID、notarized、Gatekeeper 或 public
release；人工产品流程与明确可丢弃真实资料库副本的 migration/rollback drill 仍未运行。

同机 fixture artifact smoke 可运行：

```bash
zsh Scripts/smoke_v4_local_archive.sh $PROJECT_ROOT/Release-v4-local-final-20260826
```

该脚本校验 manifest/payload、将 zip 解压到 project-local scratch、以显式 fixture
依赖启动 app 至少 3 秒、只终止自己启动的进程并删除 inspection copy；它不读取用户库、
不触网，也不替代人工同机验收。

此前所有 `Release-v4-local-final-*` 均保留为历史 artifacts，不覆盖也不作为当前源码
evidence。真实 library rollback、Developer ID、公证、Gatekeeper、VoiceOver/manual 与
跨机安装仍未建立。

`Scripts/archive_v2_unsigned.sh` creates a reproducible, unsigned local
pre-candidate archive and its machine-readable manifest. The default output
is `Release-v2/`; the script refuses to overwrite an existing output directory
and cleans only its project-local build scratch on exit:

```bash
cd $PROJECT_ROOT
zsh Scripts/archive_v2_unsigned.sh
```

The generated `Release-v2/INSTALL_AND_ROLLBACK.md` explains hash inspection,
the data boundary, and rollback. It deliberately says **not** to bypass
Gatekeeper: an unsigned archive is neither a local candidate nor a release.
See `manifest-v2.json` and `VALIDATION_V2.md` for the explicit Gate I blockers.
当前 archive 已按最新源码重新生成；其 zip SHA-256 为
`0ca8ea3b15c1d5ef8ed451c62429a92ec6c42f74884c38dc522d9ccd0e3c26d9`。bundle
metadata 与 universal architectures 已被本地复核，但签名状态仍为
`unsigned_or_unverified`。它仍不是 local candidate 或 public release：
VoiceOver、Developer ID、公证、Gatekeeper 与跨机安装均未验证。

## v2 evidence and reference-manager boundary

- A PDF is downloaded only after an explicit per-paper user action. Extracted
  page chunks and anchors remain local; deleting the PDF also deletes its
  dependent v2 artifact but preserves metadata anchors.
- paper-insight-v2 accepts only bounded retrieved chunks plus the anchor
  allowlist from that run. Direct/inference claims require anchors; a missing
  information claim cannot carry one. v2 artifacts are separate from v1 cache.
- Before any full-text read, Evidence Lens shows the direct ar5iv URL (when an
  arXiv ID exists) and local abstract/caption anchors without labelling them as
  full-text evidence. Confirming the ar5iv path reads HTML once into the
  app-owned cache; it does not fetch an INSPIRE PDF.
- The UI contains local read/favorite/note/tag/collection controls and global
  paper search. Markdown export is secret-free; a BibTeX record is never
  fabricated if the INSPIRE endpoint fails.
- Vision is an independent opt-in path. The user must manually confirm
  supportsVision and accept a second, endpoint-bound disclosure before at most
  three locally downsized INSPIRE figure images are uploaded. Vision results
  are saved separately with evidence_mode vision; failures never overwrite
  caption-only or full-text artifacts.

该脚本把 SwiftPM scratch、DerivedData 和 temporary JSON stores 都限制在项目内，并在退出时删除；v1 verifier 另行覆盖 unsigned archive。当前离线测试使用脱敏 INSPIRE JSON fixtures，覆盖：

- authors `links.next` 分页与受信任 host 约束；
- `h(all)` 阈值、本人置顶、重音/连字符/native name/BAI 搜索；
- literature record id upsert 与首次发现时间保持；
- h-index `all/published` 映射；
- endpoint HTTPS/credential policy 与 CRLF SSE `[DONE]` 契约；
- LLM schema 的图像 allowlist 和重复 key fail-closed 行为；
- schema 的未知 key、尾随内容、控制字符、超长字段、数值 token 边界、title-only translation 和 cache-key scope；
- JSON restart、v1→v2→v1 rollback、backup rotation、concurrent upsert 与 corrupt store 的只读拒写；
- 真实本地 PDFKit 两页提取、页级 direct/numeric anchor、删除清理；
- SwiftData reference-manager projection，以及 INSPIRE-owned BibTeX source-time/failure-preservation contract；
- 主交互路径所依赖的 accessibility identifiers。

具体的 v2 命令、日期、结果和未验收边界见 [VALIDATION_V2.md]($PROJECT_ROOT/VALIDATION_V2.md)；
v3 的当前台账见 [VALIDATION_V3.md]($PROJECT_ROOT/VALIDATION_V3.md)。

## 证据边界与下一步验收

通过 fixture、本机 Xcode build/test、synthetic benchmark 和 unsigned archive 仅证明相应本地 Swift 逻辑与 mock transport；它不证明真实 rate limit、任意未知历史 SwiftData 数据库、provider 的 SSE/structured-output 兼容性、Keychain 在签名 app 内的行为、图像 URL 可用性、VoiceOver 手工流程、Developer ID 签名、公证或跨机器发布。2026-08-24 的只读 INSPIRE smoke 证明当天 9 个 GET/HEAD endpoint 的 HTTP/JSON shape，不能外推为长期服务契约。

在任何 live 请求前，请单独保存不含 API Key 的 acceptance ledger，至少记录：请求日期、目标 endpoint/provider、分页/失败/重试计数、h-index 口径、HTTP header、模型/streaming 配置、取消语义、schema 失败样本和人工物理审阅。不要把该 ledger 或本机 fixture 结果表述为已完成的真实 provider、Developer ID 或公证验收。
