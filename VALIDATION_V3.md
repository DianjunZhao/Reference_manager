# LatticeLens v3 validation ledger

更新时间：2026-08-24（Asia/Shanghai）  
工程目录：`$PROJECT_ROOT`

## 结论

`v3 local complete` 已达到 v3 方案定义的本地范围：A–G、K–M 的 contract/
integration/UI-fixture 证据通过，N 的 bounded graph 与 CloudKit mock contract
通过。`v2 recovered` 在同一 local/credential-free 范围成立。

这里的 “complete” 只表示本地可审计范围，不包含真实 LLM 物理解释、CloudKit
账户同步、VoiceOver 手工流程、Developer ID 签名、公证、Gatekeeper 或跨机器
安装。所有 fixture 使用脱敏资料、in-memory/temp store、allowlisted local
transport 和 process-local Keychain；没有上传 PDF/图像、没有 provider POST、没
有写回 INSPIRE，也没有读取用户资料库、浏览器、通信记录或凭据。

## 最终直接证据

### A–D、F–G、K–M、N local contract

最终执行：

```zsh
zsh Scripts/verify_v3.sh
```

结果：`failures=0`，且所有 local 子 gate 通过。

- SwiftPM XCTest：**55 tests, 0 failures, 0 skipped**；
- SwiftPM Release（warnings as errors）：通过；
- Xcode Debug、unit、Release、analyze（macOS arm64、strict concurrency）：通过；
- synthetic large-library benchmark：通过（2,000 authors、20,000 papers、100,000
  links、100 PDF metadata records）；
- source artifact hash（`Sources/`、`Tests/`、`Scripts/` 聚合）：
  `6874485db3aa319d8fafb34821ae11311947f7bb4941f2cc59e2fec7e3c0606c`。

Benchmark 的可复现输出保留在
[`benchmark-v3.json`]($PROJECT_ROOT/benchmark-v3.json)：
synthetic-only、metadata-only PDF，cold query p50/p95 = 3.747/5.149 ms，warm
query = 1.169/1.747 ms，projection = 0.159/0.381 ms，peak RSS = 39,296 KiB。
这些数值不代表用户资料库、GPU、MPI 或 CloudKit runtime。

本轮 v3 local contract 覆盖：

- paper/document-scoped evidence、shared PDF hash reference count、quote
  relocation 与 stale/quarantine；
- arbitrary INSPIRE literature query、saved-query manual refresh、Radar
  `SyncBatchV3`、revision snapshot diff 和 citation before/after；
- 2–6 paper Compare workspace、physics-cell fail-closed validator、missing/
  stale/cross-paper 约束与编辑 UI；
- BibTeX/RIS/CSL JSON import、DOI/arXiv/recid 匹配、imported provenance、
  conflict review、Notebook Markdown footnote provenance；
- bounded citation/coauthor graph、source URL/fetchedAt/query/batch inspector、
  deterministic bounds 与 source allowlist；
- allowlisted CloudKit record types、offline queue、bounded retry、idempotency、
  explicit conflict copy 与 mock engine；
- SwiftData V3 projection models、V3→V4 schema extension、migration journal、
  fail-visible `readErrorMessage`；
- terminology JSON import/export、normalized endpoint/provider/model/source/
  bytes/request/pixel disclosure；
- `Scripts/verify_v3.sh` 与 `Scripts/benchmark_v3.py` 的可复现聚合输出。

### E、真实 `XCUIApplication` fixture runtime

最终可读 result bundle 汇总：**6 total / 6 passed / 0 failed / 0 skipped**，
`result=Passed`，macOS 26.5.1 arm64。可读 summary hash：
`5b5bef4e91f5e33f671ca6892196ce26d7002705099fd64a752f052b6520b5dc`。

命令使用 ad-hoc “Sign to Run Locally” 两阶段流程：

1. `xcodebuild ... build-for-testing`；
2. `xcodebuild test-without-building -parallel-testing-enabled NO
   -only-testing:LatticeLensUITests`。

每个 case 先等待 `fixtureModeIndicator`，覆盖作者 self/search 与论文选择、五
个 tab、Fast/Deep fixture analysis disclosure/cancel/cache/bad-image degradation、
本地 PDF page evidence 与 preview、caption-only/Vision disclosure、read/favorite/
note/tag/collection/BibTeX、设置与 key-clear 控件。该证据仅证明 fixture/local
UI runtime，不证明 VoiceOver、真实 Keychain、signed release 或 provider。

### C、credential-free INSPIRE smoke

最终执行：

```zsh
zsh Scripts/live_smoke_v3.sh
```

结果 `failures=0`，共 **9 个 endpoint** 通过：self author、author search、
literature search、hep-lat candidate、citation-summary facet、self literature
page、BibTeX GET、PDF policy HEAD、figure policy HEAD，均为 HTTP 200。脚本只发送
不带 Authorization 的 HTTPS GET/HEAD，raw body 只存在于 task-local scratch，并
在退出时删除；不写回 INSPIRE。它证明当天网络/schema shape，不替代 fresh-store
完整作者队列、长期稳定性或物理结果验收。

## Gate A–N 矩阵

| Gate | 状态 | 直接证据 / 未覆盖边界 |
| --- | --- | --- |
| A — Clean build | **Passed local** | SwiftPM/Xcode Debug、Release、unit、analyze；arm64、ad-hoc/local scope |
| B — Local tests | **Passed** | 55/55 XCTest，0 failures，0 skipped；另有 synthetic benchmark |
| C — Live INSPIRE | **Passed read-only smoke / Partial E2E** | 9 个 GET/HEAD endpoint HTTP 200；未宣称 fresh-store 完整 E2E 或长期 API proof |
| D — Persistence/recovery | **Passed local contract** | V1→V2→V3→V4 projection/migration、backup/rollback、corrupt read-only、checkpoint/generation、shared blob delete；benchmark 为 synthetic |
| E — Real UI | **Passed local fixture** | 可读 `.xcresult` 6/6；VoiceOver/manual、真实 Keychain、signed release 未验证 |
| F — v2 evidence | **Passed local contract** | scoped PDF anchors、bounded payload、claim roles、numeric/unit/anchor validation、stale/quarantine；未验证真实 PDF/provider |
| G — reference manager | **Passed local contract/UI fixture** | read/favorite/note/tag/collection、BibTeX、Markdown/RIS/CSL/provenance、Radar/Sync Center |
| H — live LLM | **Not run / external blocked** | 未提供 API key；无 provider POST，fixture LLM 不是物理结论证据 |
| I — local candidate | **Blocked external** | 仅 unsigned/ad-hoc local artifact；无 VoiceOver/manual、Developer ID、notarization、Gatekeeper、跨机 proof |
| J — public release | **Not run** | 没有发布授权与 Developer ID/notarization/Gatekeeper/跨机证据 |
| K — Research Radar | **Passed local contract/UI entry** | arbitrary query、saved-query refresh、snapshot diff、acknowledge、SyncBatch、source URL；scheduled notification 未跑 |
| L — Compare/physics contract | **Passed local contract/UI entry** | 2–6 paper workspace、physics matrix、missing/stale/cross-paper fail-closed validator；未发送 multi-paper LLM 请求 |
| M — Notebook/export | **Passed local contract/UI entry** | BibTeX/RIS/CSL import、DOI/arXiv/recid match、provenance、conflict review、Markdown footnote hash/quarantine |
| N — graph/CloudKit | **Graph passed local / CloudKit blocked external** | bounded source-backed graph 与 mock conflict merge；无 private CloudKit entitlement/account/cross-device proof |

## F01–F12 checklist

| Item | 状态 | 回归证据 |
| --- | --- | --- |
| F01 evidence identity/delete scope | **Passed** | scoped identity、shared PDF hash/reference-count delete、migration quarantine |
| F02 checkpoint/freshness/generation | **Passed** | checkpoint resume、candidate generation/cancel/failure classification |
| F03 paper-author context | **Passed** | ownership contract 与 selection/session guards |
| F04 reference-manager path | **Passed** | note UUID reuse、tag/collection CRUD/export、BibTeX source preservation、RIS/CSL/Markdown |
| F05 update center | **Passed** | `SyncBatchV3`、Radar revision/event diff、UI Sync Center rows |
| F06 task/cache invalidation | **Passed** | provider/settings/key/terminology changes cancel insight/evidence/vision/model discovery |
| F07 evidence/schema/physics limits | **Passed** | byte/scalar/token estimates、bounded payload、numeric/unit/anchor validators |
| F08 streaming/redirect/Vision bounds | **Passed** | PDF/image byte limits、HTTPS host/path checks、Vision allowlist/preflight/hash |
| F09 persistence/migration/recovery | **Passed** | JSON backup/recovery/read-only failure、SwiftData projection/migration journal |
| F10 settings/privacy | **Passed** | model search/saved-undiscovered/manual、terminology CRUD、credential-revision cache |
| F11 UI/accessibility | **Passed local fixture** | v3 IDs/workbench entries plus readable 6/6 `.xcresult`；VoiceOver remains external |
| F12 docs/verifier/ledger | **Passed** | verifier aggregate exit、benchmark artifact、9-endpoint smoke、this ledger and JSON |

## 外部阻塞与下一步验收

- 不运行真实 LLM：需要用户明确 provider、endpoint、model、API key、预算与数据边界；当前没有凭据写入或网络 POST。
- CloudKit：需要 entitlement、Apple account、private database 和跨设备冲突验收。
- I/J：需要 VoiceOver/manual checklist、Developer ID、notarization、Gatekeeper 与跨机安装 authority。
- 物理结论只来自原始论文 evidence anchor 的 scope；fixture 文案不是 LQCD 数值或 ensemble 结论。

## 可复现命令

```zsh
cd $PROJECT_ROOT
zsh Scripts/verify_v3.sh
zsh Scripts/live_smoke_v3.sh              # credential-free HTTPS GET/HEAD only
python3 Scripts/benchmark_v3.py --output benchmark-v3.json
```

`verify_v3.sh` 的 `ui_runtime=false` 是设计边界：UI runtime 由上面的可读
`.xcresult` 独立记录，不能由 SwiftPM/Xcode build 推断。

## Release-v3

保留独立的 `Release-v3/`，不覆盖既有 `Release-v2/`。当前 manifest/payload：

- artifact class：`unsigned_local_pre_candidate`；
- payload：`Release-v3/LatticeLens-v3-unsigned-local.zip`；
- payload SHA-256：`946e695c1cd7be609eaf6fb19cd4bd602ef1fda7f4ce7bc9b48b9940e23b7a61`；
- manifest SHA-256：`7cdfe814c705814b11928fbf7d39b2c2832d6de056e569b7651f3cc5bde08395`。

该 unsigned/ad-hoc artifact 不是 local candidate 或 public release；其签名、公证、
Gatekeeper、VoiceOver 和跨机安装仍分别为 blocked/not run。现有 archive 目录
按脚本的 no-overwrite 规则保留，不能据此宣称它包含台账更新后的源码。
