# LatticeLens

## Current status

The current target is **LatticeLens 2.0.0 (203)**. It remains a project-local development candidate, not a final release. The checked-in [VALIDATION_2.0_FINAL.md](VALIDATION_2.0_FINAL.md) and `evidence/Validation-2.0-final-local.json` are historical receipts until explicitly regenerated. Prefer the newest run-specific Markdown/JSON report and its matching `*-inputs.json`; treat any receipt as current only when its frozen input manifest matches the source snapshot being evaluated.

The final verifier places its managed SwiftPM/Xcode build products, test stores, fixture caches, temporary roots, logs, and result bundles under a unique project-local scratch. `TMPDIR` is provided to child tools, but Foundation/XCTest may resolve their system temporary directory independently; application/test data therefore uses explicit project-local roots and fails closed when an isolated store root is missing. This does not claim control over OS-managed XCTest state.

Fresh category profiles default to `hep-lat` + `hep-ph`. The legacy `hep-lat` + `hep-th` profile remains available for migrated or explicitly selected libraries; migration must not silently replace a saved profile. The author-recID partition table has an open-ended final range, so it has no fixed recid ceiling; ranges above INSPIRE's 10,000-result paging window are adaptively split into disjoint ranges, with the remaining ranges stored in a validated resumable checkpoint. Live global coverage is not claimed without a completed network crawl.

Historical 1.0 plans, validation, and release artifacts are retained for audit and rollback context. Their verifier receipts are not evidence for the current 2.0 source. The older `verify_v*` scripts remain historical tools; no 2.0 final-verifier PASS is claimed.

LatticeLens is a native macOS SwiftUI reference and evidence workstation for INSPIRE literature. The current candidate preserves these product invariants:

- Candidate authors are INSPIRE author records matching the configured arXiv category set; the enabled view is not a claim to enumerate every historical cross-listed collaborator.
- INSPIRE author recid `2010363` is pinned independently of h-index qualification.
- Ordinary qualification requires verified `h(all, including self-citations) > 20`; `20` does not qualify. Missing, failed, or stale values remain distinct from zero and rejection.
- Paper Lens starts from title, abstract, and INSPIRE figure captions. ar5iv HTML is offered for explicit local reading; source URL, SHA-256, extraction state, and evidence anchors are retained. The app does not claim that a text-only workflow inspected image pixels.

当记录存在 arXiv ID 时，Paper Lens 会提供明确标注的 ar5iv HTML 入口（`https://ar5iv.labs.arxiv.org/html/<arXiv-ID>`），无论 INSPIRE 是否提供 PDF。该链接可直接在浏览器打开；若要生成证据和公式推导，用户再确认一次受限 HTML 读取。ar5iv 是 LaTeX→HTML 的渲染服务，个别论文可能转换失败或缺少公式/结构；失败时应用保持原始 metadata 可用，不把失败伪装成全文成功。没有 arXiv ID 的记录仍只能使用其受信任的 INSPIRE 文档。

## 打开与运行

本工程是 macOS 14+ 的原生 SwiftUI app。可直接打开 [LatticeLens.xcodeproj]($PROJECT_ROOT/LatticeLens.xcodeproj/project.pbxproj) 的共享 `LatticeLens` scheme；保留 `Package.swift` 是为了在无图形界面的环境中运行同一份业务源码的快速 fixture test。工程包含：

- `LatticeLens`：macOS application target；
- `LatticeLensTests`：unit / integration fixture target；
- `LatticeLens-Unit`：只包含 `LatticeLensTests` 的共享 Xcode unit scheme，与 UI bundle 分离；目前该 XCTest target 以 `LatticeLens.app` 为 test host。无图形界面的 host-free 业务测试由 SwiftPM 提供；Xcode unit action 仍须由本轮可读 `.xcresult` 证明执行；
- `LatticeLensUITests`：真实 `XCUIApplication` target，通过 `-LatticeLensUseFixtures YES` 显式注入内存 fixture，不读取个人资料库、不访问 INSPIRE、provider 或 Keychain。

The large UI fixture remains in-memory by default. Quit/relaunch durability uses a
separate opt-in (`LATTICELENS_DISK_BACKED_UI_FIXTURE=1`) and a unique store root
strictly beneath the project-local `LATTICELENS_TEST_STORE_ROOT`. The app exposes
that exact root as an accessibility receipt, refuses unknown or partially seeded
stores without clearing them, and does not reseed a complete corpus on relaunch.
In this mode, content-addressed full-text blobs live in the fixture root's
`FullText/` child and survive process exit for offline reindexing; ordinary
process-local fixtures retain PID-scoped disposable caches.
This fixture mode is test-only; a disk-backed test definition is not an executed
XCUITest result or a VoiceOver acceptance receipt.

也可在终端中运行：

```bash
cd $PROJECT_ROOT
swift run LatticeLens
```

On first launch, the app prefers the pinned author record. Building the author index uses the configured category profile and a bounded h-index queue. Local papers are shown before an INSPIRE sync; each committed page persists its rows and checkpoint. User-selected authors remain pinned. A title-only translation requires consent when an abstract is absent and is not represented as a physics conclusion.

## 项目结构

```text
Sources/LatticeLens/
├── App/                     # App entry 与主状态机
├── Core/
│   ├── Models/              # 规范化 domain models 与筛选契约
│   ├── Networking/          # INSPIRE DTO、受信分页与 HTTP client
│   ├── Persistence/         # V1–V7→V8 staging, V9 search, V10 domain, V11 formula jobs, V12 derivation segments
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
    ├── Schema/              # versioned insight/formula contracts and strict validators
    └── Workflow/            # cache、Fast/Deep、状态与取消
```

The current code defines a V8 typed domain core, a rebuildable V9 local-search projection, V10 category/inventory/batch/checkpoint/analysis rows, V11 canonical formula-job/claim/structured-step rows, and V12 append-only derivation-segment/segment-step rows. The default factory stages V8/V9/V10/V11 stores toward V12 behind a verified backup, semantic checks, and an active descriptor; synthetic regressions cover source preservation, crash recovery, and a manifest-bound V10-to-V12 activation/restore/rollback drill. No real user library has been opened or migrated. Formula-job reads and writes reconstruct mutable job state, claims, structured steps, and segment provenance from typed rows; a V10 checkpoint payload is used only for one-time legacy backfill when the canonical job row is absent and is not refreshed on later writes. Bundle schema 7 exports and restores canonical V12 formula rows; schema 6 import and schema 5 typed import remain supported. `LibrarySnapshot` remains for fixtures, compatibility import/export, and bounded projections. Store ownership is actor-isolated, and views consume immutable projections.

Fresh production installs open `Application Support/LatticeLens/Library-v12.store`, keeping new V12 tables away from the direct `Library-v8.store` path used by 1.0.11. When the V8 path, a V11/V12 active descriptor, or a V7 candidate already exists, the factory retains `Library-v8.store` as the migration base and publishes migrated data through its verified V12 staging descriptor. An already established V12 path or descriptor takes precedence over a later-created V8 file. Explicit project-local test roots keep their separate `swiftdata/LatticeLens-v8.store` layout and never fall through to Application Support. This path boundary reduces schema-downgrade exposure; it is not by itself an app-plus-data rollback receipt.

## LLM 与隐私

- Provider profile 分别保存 Base URL、选择或手工 model ID 与 streaming capability；`OpenAI`、`DeepSeek` 和 OpenAI-compatible HTTPS endpoint 均可配置。
- API Key 只写入 macOS Keychain。它不会写入 `UserDefaults`、SwiftData、日志、fixture、导出或 UI 截图资料。credential revision 只是一枚递增整数，用于使缓存失效，不是 key 或 key hash。
- Release endpoint 必须是 HTTPS。Debug 仅允许 `localhost`、`127.0.0.1` 或 `::1` 使用 HTTP；拒绝 URL 中的 user/password、query 和 fragment。
- Fast 模式发送一次请求。Deep 模式严格发送两次：先从原始标题/摘要取得严格 JSON 翻译，再携带冻结翻译和原始资料生成解释。SSE 失败不会静默回退成 non-streaming 或重发。
- `paper-insight-v1` 会校验 JSON 大小、控制字符、重复 key、schema/source scope、figure key allowlist、caption-only 模式和数值陈述的摘要/caption token 锚点；不合格响应不会覆盖原始资料或既有成功 artifact。
- The ar5iv extractor builds a source-bound inventory of numbered equations and rejects missing or ambiguous source-TeX/evidence mappings. New numbered-equation results require a versioned typed step contract with stable step IDs, contiguous ordinals, source-document hashes, evidence anchors and equation dependencies; legacy string steps remain readable but do not satisfy this contract. The current `formula-coverage-v3-derivation-chain` contract requires the first step to start from the inventory source TeX (outer whitespace is ignored when comparing TeX), each following step to continue from the previous result, a nonempty rule/assumption and conclusion, and no more than 32 steps; over-limit results are rejected rather than silently truncated. Source coverage, derivation completeness, bounded TeX structural validation, and human physics review are separate dimensions. A complete local coverage report certifies exact source mapping, a complete bounded derivation chain and the supported structural checks only—not algebraic equivalence or physical correctness. Unsupported macros remain `needs_manual`, and physics stays `needs_manual_physics` without an independent receipt. Legacy `formula-coverage-v2` reports are marked stale and their formerly complete jobs become incomplete while claims remain readable. PDF fallback cannot claim complete numbered-equation coverage. The reader uses bundled offline KaTeX and supports wide formulas without a CDN.
- Formula jobs have no aggregate wall-clock deadline, but each request has finite phase/resource limits. The current default is connect 30 s, first content 120 s, content idle 120 s, and hard resource/request limit 600 s. Failed requests preserve validated batches for explicit retry/resume; a transport heartbeat is not decoded content.

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

The Evidence status reports waiting/receiving state and supports cancellation. A request that exceeds its finite content-idle or resource deadline fails as retryable; the overall multi-batch formula job has no single aggregate deadline. Fixture tests verify only local substitutes and schema/workflow behavior, not a real provider's availability or scientific correctness.

## 本地验证

The full LatticeLens 2.0 local verifier entry point is:

```bash
cd $PROJECT_ROOT
zsh Scripts/verify_2_0_final.sh --local-only --run-specific-outputs
```

It freezes a source-input manifest and runs the full local stages: SwiftPM
regressions, a manifest-bound synthetic V10-to-V12 migration drill, a
warnings-as-errors SwiftPM Release build, Xcode Debug/Release/Analyze and
Unit/UI build-and-test actions, the V12 disk benchmark, and static checks. The
benchmark uses 20,000 papers, 100,000 paper-author links, 10,000 evidence
chunks, 500 Radar events, and 5,000 formulas; it records 20 fresh-container
reopen samples, 100-sample warm search/read/favorite/note/formula-job
operations, storage bytes, and process RSS. Its JSON is bound to the frozen
manifest. All verifier-owned test stores, DerivedData, and scratch remain inside
the project and are removed when their owning stage exits. `--host-free-only`
is diagnostic mode: it does not launch an app or GUI automation, marks Xcode
and old-app rollback actions NOT_RUN, and cannot close UI gates. Run-specific
reports preserve earlier receipts by default.

When preparing a new candidate after changing the app binary, add
`--pre-package-validation` to freeze current-source software evidence before
the new DMG exists. This explicitly leaves G09 candidate acceptance as
`NOT_RUN`; the verifier still checks the selected existing package's integrity
and records G10 as partial when that package is stale. After packaging, rerun
the verifier with `--candidate-manifest` set to the exact new manifest to audit
the produced artifact. Do not edit a receipt's verdict by hand.
Synthetic source-coverage checks are not mathematical or physical correctness
reviews. XCUITest automation, manual VoiceOver and LQCD review, DMG creation,
isolated installation and app/data rollback remain independent acceptance
gates; a local receipt marked `PARTIAL_NOT_FINAL` is not a release claim.

When a current receipt and its exact manifest-bound performance and migration
receipts are available, the project-local packager can build a *candidate*.
Set these variables to the verifier JSON and the exact paths recorded in its
`input_manifest_path`, `performance_benchmark.report_path`, and
`migration_drill.receipt_path` fields:

```bash
cd $PROJECT_ROOT
VALIDATION_JSON=...
INPUT_MANIFEST_JSON=...
PERFORMANCE_JSON=...
MIGRATION_JSON=...
python3 -B Scripts/package_2_0_local_candidate.py \
  "$VALIDATION_JSON" "$INPUT_MANIFEST_JSON" \
  "$PERFORMANCE_JSON" "$MIGRATION_JSON"
```

The packager requires a `PARTIAL_NOT_FINAL` receipt, checks all supplied hashes,
builds a universal ad-hoc Release app and dSYM, verifies and read-only mounts
the DMG, then copies and launches it only under project-local fixture roots.
It refuses to overwrite an existing output and never installs to
`/Applications` or opens a user library. Its `release-assets/Release-2.0.0-local/`
directory is therefore a local candidate only; it does not close the separate
UI, VoiceOver, physics, interactive install or app/data rollback gates.
If this host cannot focus the isolated fixture window, pass
`--skip-fixture-ui-quit` to leave GUI quit explicitly `NOT_RUN`; the packager
still stops only the PID-matched sandbox process group and records that cleanup.

When preserving an existing canonical receipt, add `--run-specific-outputs` to
write the new JSON and Markdown reports under `evidence/` with the generated run
ID. The verifier refuses to replace an already-existing report or summary path
unless `--replace-canonical` is explicitly selected (it cannot be combined with
run-specific output).

```bash
cd $PROJECT_ROOT
./Scripts/verify_v1.sh
```

历史 v2 verifier 仅供复现旧基线，不是 LatticeLens 2.0 final 验收入口：

```bash
cd $PROJECT_ROOT
zsh Scripts/verify_v2.sh
```

LatticeLens 2.0 的唯一 local-only final verifier 为：

```zsh
cd $PROJECT_ROOT
zsh Scripts/verify_2_0_final.sh --local-only --run-specific-outputs
```

该入口会为未通过的 mandatory gate 返回非零；最新证据边界见
[VALIDATION_2.0_FINAL.md](VALIDATION_2.0_FINAL.md)。

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
