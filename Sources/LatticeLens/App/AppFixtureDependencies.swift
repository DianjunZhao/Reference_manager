import AppKit
import Foundation
import CoreText

/// Process-local credential substitute for UI fixtures.  It deliberately
/// cannot observe or modify macOS Keychain, even when a settings action is
/// exercised by XCUIApplication.
final class UIFixtureKeychainStore: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func save(_ value: String, service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values["\(service)|\(account)"] = value
    }

    func read(service: String, account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values["\(service)|\(account)"]
    }

    func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: "\(service)|\(account)")
    }
}

/// Deterministic substitute for all text completion paths exercised by the
/// UI bundle.  It is deliberately not an HTTP transport: even if a fixture
/// user acknowledges the disclosure or enters a test key, no provider request
/// can be made.  The short suspension leaves a visible, cancellable state for
/// UI automation without modelling a provider's latency or behavior.
struct AppFixtureLLMClient: LLMCompleting, VisionCompleting {
    private static let insightResponse = """
    {"schema_version":"paper-insight-v1","source_scope":"title_abstract_figure_captions","title_zh":"fixture 格点可观测量","abstract_zh":"fixture 摘要：重整化尺度为 2 GeV。","physics":{"research_question":"fixture 仅验证离线 UI 分析流程。","background":"该结果来自确定性测试资料。","method_and_data_flow":["fixture 数据流"],"main_results":["fixture 不代表物理结论。"],"lattice_conventions_reported":[],"missing_information":["真实 ensemble、格距和体积未提供。"],"caveats":["仅用于 UI fixture；未调用 provider。"]},"important_figures":[],"terminology":[]}
    """

    func complete(
        system: String,
        userPayload: String,
        profile: ProviderProfile,
        apiKey: String,
        maximumResponseBytes: Int,
        onTransportState: @escaping @Sendable (LLMTransportState) async -> Void,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        await onTransportState(.connected)
        await onTransportState(.waitingFirstContent)
        // Keep the test-only transport in a cancellable state long enough for
        // XCUIApplication to observe and activate the explicit cancel button.
        // This is not a model latency claim and never affects production.
        try await Task.sleep(for: .seconds(2))
        let response: String
        if system == PaperInsightPrompt.titleTranslationSystemInstruction {
            response = "{\"title_zh\":\"fixture 格点可观测量\"}"
        } else if system == PaperInsightPrompt.translationSystemInstruction {
            response = "{\"title_zh\":\"fixture 格点可观测量\",\"abstract_zh\":\"fixture 摘要：重整化尺度为 2 GeV。\"}"
        } else if system == EvidenceInsightPrompt.systemInstruction {
            response = try Self.evidenceResponse(for: userPayload)
        } else {
            response = Self.insightResponse
        }
        guard response.lengthOfBytes(using: .utf8) <= maximumResponseBytes else {
            throw LatticeLensError.schemaViolation("fixture LLM 响应超过调用方上限")
        }
        await onDelta(response)
        return response
    }

    func completeVision(
        system: String,
        userPayload: String,
        images: [VisionInputImage],
        profile: ProviderProfile,
        apiKey: String,
        maximumResponseBytes: Int,
        onTransportState: @escaping @Sendable (LLMTransportState) async -> Void,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        guard system == VisionInsightPrompt.systemInstruction, !images.isEmpty else {
            throw LatticeLensError.schemaViolation("fixture vision 输入不满足受限契约")
        }
        await onTransportState(.connected)
        await onTransportState(.waitingFirstContent)
        let values: [[String: String]] = images.map {
            ["figure_key": $0.figureKey, "text_zh": "fixture 本地图像替身；不代表真实图像内容。", "evidence_mode": "vision"]
        }
        let envelope: [String: Any] = [
            "schema_version": VisionInsightPrompt.schemaVersion,
            "evidence_mode": "vision",
            "figures": values
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        guard data.count <= maximumResponseBytes, let response = String(data: data, encoding: .utf8) else {
            throw LatticeLensError.schemaViolation("fixture vision 响应超过调用方上限")
        }
        await onDelta(response)
        return response
    }

    private static func evidenceResponse(for payload: String) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let source = root["source"] as? [String: Any],
              let anchors = source["anchors"] as? [[String: Any]],
              let anchor = anchors.first(where: { ($0["sourceKind"] as? String) == "pdf" || ($0["source_kind"] as? String) == "pdf" }),
              let anchorID = anchor["id"] as? String, !anchorID.isEmpty else {
            throw LatticeLensError.schemaViolation("fixture evidence payload 缺少 PDF anchor")
        }
        let direct: [String: Any] = ["text_zh": "fixture 全文含有可回查的局部证据。", "epistemic_status": "direct", "evidence_ids": [anchorID]]
        let formula: [String: Any] = [
            "text_zh": "原文直接给出格距定义 a=0.09 fm，并可按下列步骤核对。",
            "formula_tex": "$a=0.09\\,\\mathrm{fm}$",
            "derivation_steps": [
                "从 PDF anchor 读取格距记号 $a$。",
                "代入原文给出的数值 $0.09\\,\\mathrm{fm}$。",
                "单位保持为 fm，因此不需要额外换算。"
            ],
            "conclusion_zh": "该 fixture 的格距为 $a=0.09\\,\\mathrm{fm}$。",
            "epistemic_status": "direct",
            "evidence_ids": [anchorID]
        ]
        let inference: [String: Any] = ["text_zh": "fixture 仅用于验证证据流，不构成物理推断。", "epistemic_status": "inference", "evidence_ids": [anchorID]]
        let missing: [String: Any] = ["text_zh": "真实格点参数未在 fixture 中提供。", "epistemic_status": "missing", "evidence_ids": []]
        let envelope: [String: Any] = [
            "schema_version": PaperInsightV2Validator.schemaVersion,
            "source_scope": PaperInsightV2Validator.sourceScope,
            "title_zh": "fixture 全文证据",
            "abstract_zh": "fixture 本地 PDF 提取的受限证据摘要。",
            "physics": [
                "research_question": direct,
                "method_and_data_flow": [direct],
                "main_results": [direct],
                "important_formula_derivations": [formula],
                "reasonable_inferences": [inference],
                "missing_information": [missing],
                "caveats": [missing]
            ],
            "important_figures": [],
            "terminology": []
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        guard let response = String(data: data, encoding: .utf8) else { throw LatticeLensError.malformedPayload }
        return response
    }
}

struct AppFixtureModelDiscoverer: ModelDiscovering, ProviderConnectionTesting {
    /// Shared only by process-local large-fixture settings.  Keeping this
    /// deterministic collection here lets UI acceptance exercise the real
    /// searchable selection sheet without initiating an HTTP/model request.
    static let largeFixtureModelIDs = (1...200).map { String(format: "fixture-model-%03d", $0) }

    func discoverModels(profile: ProviderProfile, provider: LLMProvider, apiKey: String) async throws -> [String] {
        if AppLaunchConfiguration.usesLargeFixture {
            // This is deliberately generated in-process rather than read from
            // a fixture file or a local runtime.  It exercises the 200-model
            // settings surface without making a network request or exposing a
            // host configuration to UI automation.
            return Self.largeFixtureModelIDs
        }
        return ["fixture-text-model"]
    }

    func testConnection(profile: ProviderProfile, provider: LLMProvider, apiKey: String) async throws -> ProviderConnectionProbe {
        // This is a local fixture capability check, not an HTTP health call.
        // It provides a separate UI action while preserving the invariant that
        // fixture taps cannot contact any live/local model process.
        ProviderConnectionProbe(normalizedEndpoint: "fixture://in-process-model-discovery")
    }
}

/// Full-text UI cases use this local PDF generator rather than `URLSession`.
/// The returned response is deliberately constrained to the two explicit
/// fixture URLs; any other URL fails closed before a socket can be opened.
struct AppFixtureFullTextDownloader: FullTextDownloading {
    private static let allowedURLs: Set<String> = [
        "https://fixture.invalid/fulltext/1234567.pdf",
        "https://fixture.invalid/fulltext/1234568.pdf",
        "https://fixture.invalid/fulltext/large.pdf",
        "https://ar5iv.labs.arxiv.org/html/2509.09367"
    ]

    func preflight(request: URLRequest) async throws -> HTTPURLResponse {
        guard let url = request.url, Self.allowedURLs.contains(url.absoluteString) else {
            throw FullTextServiceError.invalidSource
        }
        let data = url.host == "ar5iv.labs.arxiv.org" ? AppFixtureHTML.data() : try AppFixturePDF.data()
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": url.host == "ar5iv.labs.arxiv.org" ? "text/html" : "application/pdf", "Content-Length": "\(data.count)"]) else {
            throw FullTextServiceError.invalidSource
        }
        return response
    }

    func download(request: URLRequest, maximumBytes: Int) async throws -> FullTextDownload {
        guard let url = request.url, Self.allowedURLs.contains(url.absoluteString) else {
            throw FullTextServiceError.invalidSource
        }
        let data = url.host == "ar5iv.labs.arxiv.org" ? AppFixtureHTML.data() : try AppFixturePDF.data()
        guard data.count <= maximumBytes,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": url.host == "ar5iv.labs.arxiv.org" ? "text/html" : "application/pdf"]) else {
            throw FullTextServiceError.fileTooLarge
        }
        return FullTextDownload(data: data, response: response)
    }
}

private enum AppFixtureHTML {
    static func data() -> Data {
        Data("""
        <!doctype html><html><head><title>Fixture ar5iv paper</title></head><body>
        <main><h1>Fixture lattice paper</h1><p>We define a reduced correlator.</p>
        <math alttext="C(t)=A exp(-m t)"><semantics><mrow><mi>C</mi><mo>(</mo><mi>t</mi><mo>)</mo><mo>=</mo><mi>A</mi><mi>e</mi><mo>−</mo><mi>m</mi><mi>t</mi></mrow><annotation encoding="application/x-tex">C(t)=A e^{-mt}</annotation></semantics></math>
        <p>The fit parameter is constrained by the displayed equation.</p></main></body></html>
        """.utf8)
    }
}

/// Vision fixtures already receive locally downsized bytes, so no image URL
/// loader is ever instantiated in the UI-test process.
struct AppFixtureVisionImageLoader: VisionImageLoading {
    func load(figure: PaperFigure) async throws -> VisionInputImage {
        guard (figure.key == "fig-fixture-local" || figure.key.hasPrefix("fig-large-")),
              figure.url?.host == "fixture.invalid" else {
            throw LatticeLensError.schemaViolation("fixture vision figure 不在本地 allowlist")
        }
        let data = Data("fixture-local-image-bytes:\(figure.key)".utf8)
        return VisionInputImage(figureKey: figure.key, originalHash: StableHash.sha256(data), mimeType: "image/jpeg", data: data)
    }
}

private enum AppFixturePDF {
    /// PDF generation may embed per-render metadata.  Freeze the local
    /// substitute once per fixture process so the two explicit fixture URLs
    /// really exercise one content-addressed blob rather than two lookalikes.
    private static let cachedData: Data = {
        guard let data = try? generate() else {
            fatalError("无法生成本地 fixture PDF")
        }
        return data
    }()

    static func data() throws -> Data { cachedData }

    private static func generate() throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw FullTextServiceError.unableToOpenPDF
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw FullTextServiceError.unableToOpenPDF
        }
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            // Both bounded fixture records deliberately resolve to these same
            // bytes.  This makes the UI exercise the production
            // content-addressed shared-PDF lifecycle while keeping the direct
            // `a=0.09 fm` Compare evidence on a concrete local PDF page.
            string: "Fixture full text: the renormalization scale is 2 GeV; a=0.09 fm.",
            attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black]
        ))
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }
}

/// Deterministic, network-free dependencies used only by the Xcode UI-test
/// launch environment.  The app never selects these in normal launches, so
/// fixture data cannot be mistaken for a live INSPIRE response.
struct AppFixtureTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let payload: String
        switch path {
        case "/api/authors/2010363":
            payload = """
            {"id":"2010363","metadata":{"name":{"value":"Zhao, Dian-Jun"},"native_names":[{"value":"Fixture User"}],"ids":[{"schema":"INSPIRE BAI","value":"D.Zhao.1"}],"arxiv_categories":["hep-lat"]}}
            """
        case "/api/authors", "/api/authors/":
            payload = """
            {"hits":{"total":2,"hits":[
              {"id":"2010363","metadata":{"name":{"value":"Zhao, Dian-Jun"},"native_names":[{"value":"Fixture User"}],"ids":[{"schema":"INSPIRE BAI","value":"D.Zhao.1"}],"arxiv_categories":["hep-lat"]}},
              {"id":77,"metadata":{"name":{"value":"Zebra, Zed"},"native_names":[],"ids":[{"schema":"INSPIRE BAI","value":"Z.Zebra.1"}],"arxiv_categories":["hep-lat"]}}
            ]},"links":{}}
            """
        case "/api/literature/facets":
            payload = """
            {"aggregations":{"citation-summary":{"h-index":{"value":{"all":21,"published":20}}}}}
            """
        case "/api/literature", "/api/literature/":
            payload = """
            {"hits":{"total":2,"hits":[{"id":1234567,"updated":"2026-08-20T12:00:00+00:00","metadata":{
              "titles":[{"title":"Fixture lattice observable","source":"fixture"}],
              "abstracts":[{"value":"Fixture abstract: the renormalization scale is 2 GeV.","source":"fixture"}],
              "arxiv_eprints":[{"value":"2608.12345","categories":["hep-lat"]}],
              "citation_count":4,"preprint_date":"2026-08-20",
              "documents":[{"key":"fixture-fulltext","url":"https://fixture.invalid/fulltext/1234567.pdf","source":"arXiv fixture","filename":"fixture-1234567.pdf","fulltext":true}],
              "figures":[
                {"key":"fig-fixture-local","url":"https://fixture.invalid/figures/1234567.jpg","label":"Figure fixture","caption":"Fixture caption supplied by local transport.","source":"fixture","filename":"fixture.jpg"},
                {"key":"fig-missing-url","label":"Figure without image","caption":"Fixture caption-only fallback; no image URL is provided.","source":"fixture","filename":"missing.png"}
              ]
            }},{"id":1234568,"updated":"2026-08-19T12:00:00+00:00","metadata":{
              "titles":[{"title":"Fixture lattice renormalization","source":"fixture"}],
              "abstracts":[{"value":"Fixture local comparison record; the bounded local PDF carries the spacing evidence.","source":"fixture"}],
              "arxiv_eprints":[{"value":"2608.12346","categories":["hep-lat"]}],
              "citation_count":1,"preprint_date":"2026-08-19",
              "documents":[{"key":"fixture-fulltext-1234568","url":"https://fixture.invalid/fulltext/1234568.pdf","source":"arXiv fixture","filename":"fixture-1234568.pdf","fulltext":true}],
              "figures":[]
            }}]},"links":{}}
            """
        case "/api/literature/1234567":
            payload = """
            {"id":1234567,"updated":"2026-08-20T12:00:00+00:00","metadata":{
              "titles":[{"title":"Fixture lattice observable","source":"fixture"}],
              "abstracts":[{"value":"Fixture abstract: the renormalization scale is 2 GeV.","source":"fixture"}],
              "arxiv_eprints":[{"value":"2608.12345","categories":["hep-lat"]}],
              "citation_count":4,"preprint_date":"2026-08-20",
              "documents":[{"key":"fixture-fulltext","url":"https://fixture.invalid/fulltext/1234567.pdf","source":"arXiv fixture","filename":"fixture-1234567.pdf","fulltext":true}],
              "figures":[
                {"key":"fig-fixture-local","url":"https://fixture.invalid/figures/1234567.jpg","label":"Figure fixture","caption":"Fixture caption supplied by local transport.","source":"fixture","filename":"fixture.jpg"},
                {"key":"fig-missing-url","label":"Figure without image","caption":"Fixture caption-only fallback; no image URL is provided.","source":"fixture","filename":"missing.png"}
              ]
            }}
            """
        case "/api/literature/1234568":
            payload = """
            {"id":1234568,"updated":"2026-08-19T12:00:00+00:00","metadata":{
              "titles":[{"title":"Fixture lattice renormalization","source":"fixture"}],
              "abstracts":[{"value":"Fixture local comparison record; the bounded local PDF carries the spacing evidence.","source":"fixture"}],
              "arxiv_eprints":[{"value":"2608.12346","categories":["hep-lat"]}],
              "citation_count":1,"preprint_date":"2026-08-19",
              "documents":[{"key":"fixture-fulltext-1234568","url":"https://fixture.invalid/fulltext/1234568.pdf","source":"arXiv fixture","filename":"fixture-1234568.pdf","fulltext":true}],
              "figures":[]
            }}
            """
        default:
            throw LatticeLensError.invalidResponse
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            throw LatticeLensError.invalidResponse
        }
        return (Data(payload.utf8), response)
    }
}

enum AppLaunchConfiguration {
    /// A production-dependency test run may need a fresh, disposable store
    /// while still talking to the real read-only metadata endpoint.  `HOME`
    /// is not a reliable isolation mechanism for AppKit/Foundation on macOS:
    /// Application Support can remain bound to the logged-in user's home.
    /// Require two explicit process-owned keys so an ordinary launch cannot
    /// redirect its library, and keep this distinct from UI fixture mode.
    static var productionIsolationStoreRoot: String? {
        productionIsolationStoreRoot(environment: ProcessInfo.processInfo.environment)
    }

    static func productionIsolationStoreRoot(environment: [String: String]) -> String? {
        guard environment["LATTICELENS_ALLOW_PRODUCTION_ISOLATION"] == "1",
              let root = environment["LATTICELENS_PRODUCTION_STORE_ROOT"],
              root.hasPrefix("/") else {
            return nil
        }
        return root
    }

    static var usesFixtureDependencies: Bool {
        #if LATTICELENS_UI_FIXTURE_TARGET
        // The dedicated Xcode UI fixture configuration is compiled solely
        // for the AUT.  This avoids relying on macOS runner propagation of
        // launch arguments and makes a production dependency graph
        // impossible in that executable.
        true
        #else
        usesFixtureDependencies(
            environment: ProcessInfo.processInfo.environment,
            arguments: CommandLine.arguments,
            argumentDomain: launchArgumentDomain
        )
        #endif
    }

    /// Fixture activation is deliberately derived only from process-owned
    /// XCTest launch inputs.  The final test-root fallback is required for
    /// macOS Xcode GUI runners: some runner versions retain the TestAction
    /// environment but drop per-`XCUIApplication` overrides while starting
    /// the AUT.  A non-empty absolute test root is already a fail-closed
    /// contract -- persistence would otherwise be redirected away from the
    /// user's Application Support library -- so it must select the fully
    /// in-memory fixture graph as well.
    static func usesFixtureDependencies(
        environment: [String: String],
        arguments: [String],
        argumentDomain: [String: Any] = [:]
    ) -> Bool {
        if environment["LATTICELENS_USE_FIXTURES"] == "1" {
            return true
        }
        // XCTest forwards launch arguments in their command-line form
        // (including the leading dash). Supporting the bare spelling retains
        // compatibility with direct fixture launches.
        if arguments.contains("-LatticeLensUseFixtures") || arguments.contains("LatticeLensUseFixtures") {
            return true
        }
        // macOS XCUIApplication exposes `-key value` through the volatile
        // NSArgumentDomain.  Do not consult persistent UserDefaults here.
        if enabledArgument(named: "LatticeLensUseFixtures", in: argumentDomain) {
            return true
        }
        guard let testRoot = environment["LATTICELENS_TEST_STORE_ROOT"],
              testRoot.hasPrefix("/") else {
            return false
        }
        return true
    }

    static var fixtureAutomaticAnalysisEnabled: Bool {
        ProcessInfo.processInfo.environment["LATTICELENS_FIXTURE_AUTOMATIC_ANALYSIS"] == "1" ||
            CommandLine.arguments.contains("-LatticeLensFixtureAutomaticAnalysis") ||
            CommandLine.arguments.contains("LatticeLensFixtureAutomaticAnalysis") ||
            enabledArgument(named: "LatticeLensFixtureAutomaticAnalysis", in: launchArgumentDomain)
    }

    /// Large UI data is an *additional* isolation gate.  In particular, an
    /// accidental `LATTICELENS_LARGE_UI_FIXTURE=1` on a normal app launch must
    /// never replace the user's library with generated records.
    static var usesLargeFixture: Bool {
        usesFixtureDependencies &&
            (ProcessInfo.processInfo.environment["LATTICELENS_LARGE_UI_FIXTURE"] == "1" ||
             CommandLine.arguments.contains("-LatticeLensLargeUIFixture") ||
             CommandLine.arguments.contains("LatticeLensLargeUIFixture") ||
             enabledArgument(named: "LatticeLensLargeUIFixture", in: launchArgumentDomain))
    }

    /// UI automation may request only the three release acceptance sizes.  A
    /// normal launch ignores this environment key entirely, and an arbitrary
    /// value never becomes a layout input.
    static var fixtureWindowSize: CGSize? {
        guard usesFixtureDependencies else { return nil }
        switch ProcessInfo.processInfo.environment["LATTICELENS_FIXTURE_WINDOW_SIZE"] ??
            stringArgument(named: "LatticeLensFixtureWindowSize", in: launchArgumentDomain) {
        case "820x640": return CGSize(width: 820, height: 640)
        case "1120x700": return CGSize(width: 1_120, height: 700)
        case "1440x900": return CGSize(width: 1_440, height: 900)
        default: return nil
        }
    }

    /// In the dedicated UI-fixture binary the build configuration injects a
    /// project-local cache root into Info.plist.  This is intentionally not
    /// present in production bundles, and keeps fixture PDFs out of both the
    /// user cache and system temporary directories even if AUT environment
    /// overrides are lost.
    static var fixtureCacheRoot: String? {
        if let value = ProcessInfo.processInfo.environment["LATTICELENS_FIXTURE_CACHE_ROOT"], value.hasPrefix("/") {
            return value
        }
        #if LATTICELENS_UI_FIXTURE_TARGET
        if let value = Bundle.main.object(forInfoDictionaryKey: "LatticeLensFixtureCacheRoot") as? String,
           value.hasPrefix("/") {
            return value
        }
        #endif
        return nil
    }

    /// Only a process already in fixture mode may select an initial Paper Lens
    /// tab.  This lets UI automation reach deterministic fixture content
    /// without clicking through unrelated, host-owned notification banners.
    static var fixtureInitialPaperLensTab: String? {
        guard usesFixtureDependencies else { return nil }
        if let value = ProcessInfo.processInfo.environment["LATTICELENS_FIXTURE_INITIAL_PAPER_LENS_TAB"], !value.isEmpty {
            return value
        }
        if let value = stringArgument(named: "LatticeLensFixtureInitialPaperLensTab", in: launchArgumentDomain), !value.isEmpty {
            return value
        }
        guard let index = CommandLine.arguments.firstIndex(of: "-LatticeLensFixtureInitialPaperLensTab"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    /// A fixture-only initial query keeps the large-list UI contract
    /// independent from whichever macOS input method happens to be active in
    /// the XCTest host.  It never applies outside an already-isolated fixture
    /// process, and is not a production search persistence mechanism.
    static var fixtureInitialAuthorSearch: String? {
        guard usesFixtureDependencies else { return nil }
        let requested = ProcessInfo.processInfo.environment["LATTICELENS_FIXTURE_INITIAL_AUTHOR_SEARCH"] ??
            stringArgument(named: "LatticeLensFixtureInitialAuthorSearch", in: launchArgumentDomain)
        guard let requested else { return nil }
        let query = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              query.count <= 160,
              !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return query
    }

    /// These two inputs are limited to the already-isolated large UI fixture.
    /// macOS XCTest synthesizes text through the host's active input method;
    /// it can transliterate an ASCII tag query before the native search field
    /// receives it.  Seeding the same query lets the UI suite verify the real
    /// searchable manager and its Cancel transaction without treating an IME
    /// choice as product state.  Manual acceptance retains keyboard/IME
    /// observation on the actual app surface.
    static var fixtureInitialTagManagerSearch: String? {
        fixtureInitialReferenceManagerSearch(
            environmentKey: "LATTICELENS_FIXTURE_INITIAL_TAG_MANAGER_SEARCH",
            argumentName: "LatticeLensFixtureInitialTagManagerSearch"
        )
    }

    static var fixtureInitialCollectionManagerSearch: String? {
        fixtureInitialReferenceManagerSearch(
            environmentKey: "LATTICELENS_FIXTURE_INITIAL_COLLECTION_MANAGER_SEARCH",
            argumentName: "LatticeLensFixtureInitialCollectionManagerSearch"
        )
    }

    private static func fixtureInitialReferenceManagerSearch(environmentKey: String, argumentName: String) -> String? {
        guard usesLargeFixture else { return nil }
        let requested = ProcessInfo.processInfo.environment[environmentKey] ??
            stringArgument(named: argumentName, in: launchArgumentDomain)
        guard let requested else { return nil }
        let query = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              query.count <= 160,
              !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return query
    }

    /// This is deliberately a fixture-only input for an XCUIApplication
    /// editor test.  It avoids treating the host's current input method as a
    /// product dependency while still requiring the native TextField to show
    /// the seeded value.  A normal launch cannot use it to prefill a user's
    /// notebook draft.
    static var fixtureInitialNotebookEntryTitle: String? {
        guard usesFixtureDependencies else { return nil }
        let requested = ProcessInfo.processInfo.environment["LATTICELENS_FIXTURE_INITIAL_NOTEBOOK_TITLE"] ??
            stringArgument(named: "LatticeLensFixtureInitialNotebookTitle", in: launchArgumentDomain)
        guard let requested else { return nil }
        let title = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              title.count <= 160,
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return title
    }

    static var fixtureInitialWorkbenchTab: String? {
        guard usesFixtureDependencies else { return nil }
        if let value = ProcessInfo.processInfo.environment["LATTICELENS_FIXTURE_INITIAL_WORKBENCH_TAB"], !value.isEmpty {
            return value
        }
        if let value = stringArgument(named: "LatticeLensFixtureInitialWorkbenchTab", in: launchArgumentDomain), !value.isEmpty {
            return value
        }
        guard let index = CommandLine.arguments.firstIndex(of: "-LatticeLensFixtureInitialWorkbenchTab"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    static func fixtureSettings() -> LLMSettings {
        // Fixture capability is explicitly configured rather than inferred
        // from a model name.  It permits the isolated UI suite to verify the
        // separate vision disclosure without asserting anything about a live
        // provider.
        let profile = ProviderProfile(baseURL: "https://fixture.invalid/v1",
                                      selectedModel: usesLargeFixture ? "fixture-model-200" : "",
                                      manualModel: usesLargeFixture ? "" : "fixture-text-model",
                                      usesStreaming: false,
                                      supportsVision: true)
        // The UI fixture may explicitly exercise the no-pixel branch.  Keep
        // the value allowlisted so an XCTest launch cannot smuggle an
        // arbitrary production setting into the process.
        let requestedMaximum = Int(
            ProcessInfo.processInfo.environment["LATTICELENS_FIXTURE_MAXIMUM_FIGURES"] ??
                stringArgument(named: "LatticeLensFixtureMaximumFigures", in: launchArgumentDomain) ?? ""
        )
        let maximumFigures = [0, 3, 5].contains(requestedMaximum) ? requestedMaximum! : 3
        let terminology: [TerminologyEntry]
        if usesLargeFixture {
            terminology = (1...500).map { index in
                TerminologyEntry(id: AppFixtureLargeData.fixtureUUID(scope: 9, index: index),
                                 source: String(format: "fixture term %03d", index),
                                 preferredZH: String(format: "测试术语 %03d", index),
                                 note: "process-local large UI fixture")
            }
        } else {
            terminology = []
        }
        return LLMSettings(activeProvider: .localOpenAICompatible,
                           profiles: [LLMProvider.localOpenAICompatible.rawValue: profile],
                           automaticAnalysis: fixtureAutomaticAnalysisEnabled,
                           mode: .fast,
                           detailLevel: .standard,
                           maximumFigures: maximumFigures,
                           terminology: terminology)
    }

    private static var launchArgumentDomain: [String: Any] {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }

    private static func enabledArgument(named key: String, in domain: [String: Any]) -> Bool {
        guard let value = domain[key] else { return false }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        guard let string = value as? String else { return false }
        return ["1", "yes", "true"].contains(string.lowercased())
    }

    private static func stringArgument(named key: String, in domain: [String: Any]) -> String? {
        if let value = domain[key] as? String { return value }
        if let number = domain[key] as? NSNumber { return number.stringValue }
        return nil
    }
}

/// Process-local, deterministic records used exclusively by the large UI
/// suite.  This deliberately uses the public `LibraryStoring` mutations
/// instead of a hidden snapshot assignment: a test exercises the same
/// projection paths that the app uses after a real local write, while the
/// fixture-mode dependency graph still guarantees an `InMemoryLibraryStore`.
///
/// No user/library bytes, live INSPIRE responses, PDFs, images, credentials,
/// or model output are read here.  `AppFixturePDF` and
/// `AppFixtureVisionImageLoader` remain bounded local substitutes only when a
/// UI case explicitly requests a download/vision preflight.
enum AppFixtureLargeData {
    static let authorCount = 301 // one pinned self + 300 ordinary authors
    static let paperCount = 1_000
    static let tagCount = 100
    static let collectionCount = 100
    static let terminologyCount = 500
    static let jobCount = 50
    static let radarQueryCount = 100
    static let radarEventCount = 500
    static let workspaceCount = 100
    static let evidenceAnchorCount = 200
    static let figureCount = 100

    static func seed(into store: any LibraryStoring, now: Date = Date()) async throws {
        // All IDs and text are deterministic.  `now` only represents the
        // local fixture launch time so stale-data scheduling cannot start a
        // fixture transport request after the initial local projection.
        let hIndex = HIndexSnapshot(authorRecid: ProductContract.selfAuthorRecid,
                                    all: 42,
                                    published: 40,
                                    excludesSelfCitations: false,
                                    source: "large-fixture",
                                    query: "fixture-only",
                                    fetchedAt: now,
                                    rawSchemaHash: "fixture-large-v1")
        let selfAuthor = Author(recid: ProductContract.selfAuthorRecid,
                                preferredName: "Zhao, Dian-Jun",
                                nativeNames: ["Fixture User"],
                                bai: "D.Zhao.1",
                                arxivCategories: ["hep-lat"],
                                hIndex: hIndex,
                                hIndexState: .qualified,
                                isTracked: true,
                                lastSyncedAt: now,
                                lastCheckpointAt: now,
                                lastSuccessfulSyncAt: now)
        var authors = [selfAuthor]
        authors.reserveCapacity(authorCount)
        for index in 1...300 {
            let letter = UnicodeScalar(65 + ((index - 1) % 26)).map(Character.init) ?? "A"
            let recid = 2_100_000 + index
            let value = HIndexSnapshot(authorRecid: recid,
                                       all: 21 + (index % 17),
                                       published: 20 + (index % 17),
                                       excludesSelfCitations: false,
                                       source: "large-fixture",
                                       query: "fixture-only",
                                       fetchedAt: now,
                                       rawSchemaHash: "fixture-large-v1")
            authors.append(Author(recid: recid,
                                  preferredName: "\(letter)uthor, Fixture \(String(format: "%03d", index))",
                                  nativeNames: ["Fixture Native \(String(format: "%03d", index))"],
                                  bai: "F.\(letter).\(index)",
                                  arxivCategories: ["hep-lat"],
                                  hIndex: value,
                                  hIndexState: .qualified,
                                  isTracked: index.isMultiple(of: 25),
                                  lastSyncedAt: now,
                                  lastCheckpointAt: now,
                                  lastSuccessfulSyncAt: now))
        }
        try await store.upsert(authors: authors)

        let largeFigures = (1...figureCount).map { index in
            PaperFigure(key: String(format: "fig-large-%03d", index),
                        url: URL(string: "https://fixture.invalid/figures/large-\(index).jpg"),
                        label: "Fixture Figure \(index)",
                        caption: "Large process-local fixture caption \(index). This is not a scientific claim.",
                        source: "fixture",
                        filename: "large-\(index).jpg")
        }
        let firstPaperID = 9_100_000
        let largeAbstract = String(repeating: "Large local fixture abstract text is display-only and does not support a physics conclusion. ", count: 250)
        let papers = (0..<paperCount).map { offset -> Paper in
            let paperID = firstPaperID + offset
            return Paper(literatureID: paperID,
                         titles: [PaperTitle(value: String(format: "Large Fixture Lattice Paper %04d", offset), source: "fixture")],
                         abstracts: [PaperAbstract(value: offset == 0 ? largeAbstract : "Process-local fixture abstract \(offset).", source: "fixture")],
                         preprintDate: now.addingTimeInterval(-Double(offset) * 86_400),
                         earliestDate: nil,
                         arxivID: String(format: "2608.%05d", offset),
                         arxivCategories: ["hep-lat"],
                         doi: nil,
                         citationCount: offset % 71,
                         publicationStatus: offset.isMultiple(of: 3) ? "published" : nil,
                         updated: now.addingTimeInterval(-Double(offset) * 3_600),
                         figures: offset == 0 ? largeFigures : [],
                         contributors: [PaperContributor(recid: ProductContract.selfAuthorRecid, fullName: "Zhao, Dian-Jun", position: 0)],
                         documents: offset == 0 ? [PaperDocument(key: "fixture-large-fulltext",
                                                                  url: URL(string: "https://fixture.invalid/fulltext/large.pdf"),
                                                                  source: "arXiv fixture",
                                                                  filename: "fixture-large.pdf",
                                                                  isFullText: true)] : [],
                         firstSeenAt: now,
                         isRead: offset.isMultiple(of: 4),
                         readAt: offset.isMultiple(of: 4) ? now : nil,
                         isFavorite: offset.isMultiple(of: 19))
        }
        _ = try await store.upsert(papers: papers, for: ProductContract.selfAuthorRecid)

        let tags = (1...tagCount).map { index in
            LibraryTag(id: fixtureUUID(scope: 1, index: index),
                       name: String(format: "Fixture tag %03d", index),
                       colorName: index.isMultiple(of: 2) ? "blue" : "orange",
                       createdAt: now)
        }
        for tag in tags { try await store.applyReferenceMutation(.upsertTag(tag)) }
        try await store.applyReferenceMutation(.setTags(paperID: firstPaperID, tagIDs: Set(tags.map(\.id))))

        let collections = (1...collectionCount).map { index in
            PaperCollection(id: fixtureUUID(scope: 2, index: index),
                            name: String(format: "Fixture collection %03d", index),
                            createdAt: now)
        }
        for (zeroBasedIndex, collection) in collections.enumerated() {
            try await store.applyReferenceMutation(.upsertCollection(collection))
            try await store.applyReferenceMutation(.setCollectionPapers(collectionID: collection.id,
                                                                          paperIDs: [firstPaperID + (zeroBasedIndex % paperCount)],
                                                                          at: now))
        }

        for index in 1...jobCount {
            try await store.save(checkpoint: SyncCheckpoint(jobID: String(format: "fixture-job-%03d", index),
                                                             jobKind: "fixture",
                                                             query: "fixture query \(index)",
                                                             nextURL: URL(string: "https://fixture.invalid/jobs/\(index)"),
                                                             completedPages: index,
                                                             successfulRecords: index * 2,
                                                             failedRecords: index.isMultiple(of: 7) ? 1 : 0,
                                                             failedIDs: index.isMultiple(of: 7) ? [index] : [],
                                                             pendingIDs: [index],
                                                             startedAt: now,
                                                             updatedAt: now,
                                                             lastCheckpointAt: now,
                                                             activeMembership: [],
                                                             stagingMembership: [],
                                                             state: index.isMultiple(of: 2) ? .paused : .active))
        }

        let batchID = fixtureUUID(scope: 3, index: 1)
        for index in 1...radarQueryCount {
            try await store.applyV3(.saveQuery(SavedInspireQuery(id: fixtureUUID(scope: 4, index: index),
                                                                  name: String(format: "Fixture Radar Query %03d", index),
                                                                  query: "arxiv_categories:hep-lat and fixture:\(index)",
                                                                  refreshPolicy: .manual,
                                                                  isPaused: false,
                                                                  lastRunAt: nil,
                                                                  nextRunAt: nil,
                                                                  createdAt: now)))
        }
        for index in 1...radarEventCount {
            try await store.applyV3(.saveRadarEvent(RadarEvent(id: fixtureUUID(scope: 5, index: index),
                                                                paperID: firstPaperID + (index % paperCount),
                                                                authorRecids: [ProductContract.selfAuthorRecid],
                                                                eventKind: index.isMultiple(of: 2) ? .fieldModified : .fieldAdded,
                                                                beforeHash: "fixture-before-\(index)",
                                                                afterHash: "fixture-after-\(index)",
                                                                changedFields: ["citation_count", "abstract"],
                                                                syncBatchID: batchID,
                                                                observedAt: now,
                                                                sourceURL: URL(string: "https://fixture.invalid/radar/\(index)")!,
                                                                isAcknowledged: index.isMultiple(of: 5))))
        }
        for index in 1...workspaceCount {
            try await store.applyV3(.saveWorkspace(PaperWorkspace(id: fixtureUUID(scope: 6, index: index),
                                                                   name: String(format: "Fixture Workspace %03d", index),
                                                                   createdAt: now,
                                                                   updatedAt: now,
                                                                   sortOrder: [firstPaperID + (index % paperCount)],
                                                                   note: "process-local workspace fixture \(index)",
                                                                   frozenExportHash: nil)))
        }
        let anchors = (1...evidenceAnchorCount).map { index in
            let quote = "Large fixture anchor \(index); display-only local evidence placeholder."
            return EvidenceAnchor(id: String(format: "fixture-large-anchor-%03d", index),
                                  paperID: firstPaperID,
                                  sourceKind: .abstract,
                                  page: nil,
                                  section: "fixture",
                                  quote: quote,
                                  quoteHash: StableHash.sha256(quote),
                                  figureKey: nil)
        }
        try await store.saveEvidenceAnchors(anchors)
    }

    /// Keeps fixture IDs stable across launches without using process-random
    /// UUIDs; scopes keep independently generated entity sets disjoint.
    static func fixtureUUID(scope: Int, index: Int) -> UUID {
        let value = String(format: "00000000-%04X-4000-8000-%012X", scope, index)
        guard let uuid = UUID(uuidString: value) else { preconditionFailure("invalid deterministic fixture UUID") }
        return uuid
    }
}
