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
    private let emitsUnanchoredEvidenceClaims: Bool
    private let emitsMissingArrayComma: Bool

    init(
        emitsUnanchoredEvidenceClaims: Bool = ProcessInfo.processInfo.environment["LATTICELENS_FIXTURE_UNANCHORED_EVIDENCE_CLAIMS"] == "1",
        emitsMissingArrayComma: Bool = ProcessInfo.processInfo.environment["LATTICELENS_FIXTURE_MISSING_ARRAY_COMMA"] == "1"
    ) {
        self.emitsUnanchoredEvidenceClaims = emitsUnanchoredEvidenceClaims
        self.emitsMissingArrayComma = emitsMissingArrayComma
    }

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
        } else if system == EvidenceInsightPrompt.systemInstruction || system == FormulaDerivationPrompt.systemInstruction {
            response = try Self.evidenceResponse(
                for: userPayload,
                emitsUnanchoredEvidenceClaims: emitsUnanchoredEvidenceClaims,
                emitsMissingArrayComma: emitsMissingArrayComma
            )
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
        requestTimeout: TimeInterval,
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

    private static func evidenceResponse(
        for payload: String,
        emitsUnanchoredEvidenceClaims: Bool,
        emitsMissingArrayComma: Bool
    ) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let source = root["source"] as? [String: Any],
              let anchors = source["anchors"] as? [[String: Any]],
              let sourceDocumentHash = source["documentHash"] as? String else {
            throw LatticeLensError.schemaViolation("fixture evidence payload 缺少 PDF anchor")
        }
        let continuation = root["continuation_context"] as? [String: Any]
        let continuationEquationID = continuation?["equation_id"] as? String
        let continuationIndex = continuation?["segment_index"] as? Int
        let continuationOrdinal = continuation?["starting_ordinal"] as? Int
        let continuationBeforeTeX = continuation?["preceding_tex"] as? String
        if continuation != nil,
           (continuationEquationID == nil || continuationIndex == nil ||
            continuationOrdinal == nil || continuationBeforeTeX == nil) {
            throw LatticeLensError.schemaViolation("fixture continuation_context 不完整")
        }
        let anchor = anchors.first(where: { ($0["sourceKind"] as? String) == "pdf" || ($0["source_kind"] as? String) == "pdf" }) ?? anchors.first
        let anchorID = anchor?["id"] as? String
        let hasAnchor = anchorID.map { !$0.isEmpty } ?? false
        let direct: [String: Any] = ["text_zh": "fixture 全文含有可回查的局部证据。", "epistemic_status": "direct", "evidence_ids": [anchorID ?? ""]]
        let unanchoredDirect: [String: Any] = ["text_zh": "fixture 故意省略了当前 evidence anchor 的直接声明。", "epistemic_status": "direct", "evidence_ids": []]
        let unanchoredInference: [String: Any] = ["text_zh": "fixture 故意省略了当前 evidence anchor 的推断。", "epistemic_status": "inference", "evidence_ids": []]
        // This deliberate malformed provider reply is available only to the
        // process-local UI fixture.  It exercises the production parser's
        // fail-closed fallback without reading a user library, Keychain, or
        // contacting any provider.
        let researchQuestion: Any = !hasAnchor
            ? ["text_zh": "fixture prose 沒有可回查 anchor。", "epistemic_status": "missing", "evidence_ids": []]
            : ProcessInfo.processInfo.environment["LATTICELENS_FIXTURE_LEGACY_RESEARCH_QUESTION"] == "1"
            ? "fixture provider returned this research question without an anchor object"
            : (emitsUnanchoredEvidenceClaims ? unanchoredDirect : direct)
        let numberedEquations = source["numbered_equations"] as? [[String: Any]] ?? []
        // Generate from the same supplied inventory rather than a hard-coded
        // count. The fixture therefore exercises the production bijection
        // check for each labelled ar5iv equation.
        let formulas: [[String: Any]] = try numberedEquations.map { equation in
            guard let equationID = equation["equation_id"] as? String,
                  let label = equation["label"] as? String,
                  let tex = equation["tex"] as? String,
                  let evidenceID = equation["evidence_id"] as? String,
                  !equationID.isEmpty, !label.isEmpty, !tex.isEmpty, !evidenceID.isEmpty else {
                throw LatticeLensError.schemaViolation("fixture 编号公式 inventory 不完整")
            }
            if let continuationEquationID, continuationEquationID != equationID {
                throw LatticeLensError.schemaViolation("fixture continuation equation ID 与 inventory 不匹配")
            }
            let stepTexts = continuation == nil ? [
                "读取当前 inventory 条目并保留原文表达式。",
                "将解释限定在该来源片段，不声称额外的代数等价。"
            ] : ["从已经校验的前段末式继续，保持来源限定。"]
            let typedSteps: [[String: Any]] = stepTexts.enumerated().map { offset, text in
                let ordinal = continuationOrdinal.map { $0 + offset } ?? (offset + 1)
                let beforeTeX = continuationBeforeTeX ?? tex
                return [
                    "step_id": "\(equationID):step:\(ordinal)",
                    "ordinal": ordinal,
                    "text_zh": text,
                    "before_tex": beforeTeX,
                    "after_tex": continuationBeforeTeX ?? tex,
                    "rule_or_assumption": "仅使用当前 ar5iv 公式锚点。",
                    "referenced_equation_ids": [],
                    "evidence_anchor_ids": [evidenceID],
                    "source_document_hashes": [sourceDocumentHash],
                    "epistemic_status": "inference"
                ]
            }
            let segment: [String: Any] = [
                "index": continuationIndex ?? 0,
                "is_final": true
            ]
            return [
                "text_zh": "原文直接给出编号公式 \(label)。",
                "equation_id": equationID,
                "formula_tex": tex,
                "derivation_steps": stepTexts,
                "derivation_step_contract": typedSteps,
                "derivation_segment": segment,
                "conclusion_zh": "该受限 HTML 片段给出编号公式 \(label) 的定义或关系。",
                "epistemic_status": "direct",
                "evidence_ids": [evidenceID]
            ]
        }
        let inference: [String: Any] = !hasAnchor
            ? ["text_zh": "fixture prose 沒有可回查 anchor。", "epistemic_status": "missing", "evidence_ids": []]
            : emitsUnanchoredEvidenceClaims
            ? unanchoredInference
            : ["text_zh": "fixture 仅用于验证证据流，不构成物理推断。", "epistemic_status": "inference", "evidence_ids": [anchorID ?? ""]]
        let missing: [String: Any] = ["text_zh": "真实格点参数未在 fixture 中提供。", "epistemic_status": "missing", "evidence_ids": []]
        let envelope: [String: Any] = [
            "schema_version": PaperInsightV2Validator.schemaVersion,
            "source_scope": PaperInsightV2Validator.sourceScope,
            "title_zh": "fixture 全文证据",
            "abstract_zh": "fixture 本地 PDF 提取的受限证据摘要。",
            "physics": [
                "research_question": researchQuestion,
                "method_and_data_flow": hasAnchor ? [emitsUnanchoredEvidenceClaims ? unanchoredDirect : direct] : [],
                "main_results": hasAnchor ? [emitsUnanchoredEvidenceClaims ? unanchoredDirect : direct] : [],
                "important_formula_derivations": formulas,
                "reasonable_inferences": [inference],
                "missing_information": [missing],
                "caveats": hasAnchor ? [emitsUnanchoredEvidenceClaims ? unanchoredInference : missing] : [missing]
            ],
            "important_figures": [],
            "terminology": []
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        guard var response = String(data: data, encoding: .utf8) else { throw LatticeLensError.malformedPayload }
        if emitsMissingArrayComma, !formulas.isEmpty {
            // Test only: emulate the precise model typo `"step one" "step
            // two"` inside an otherwise strict, anchored formula artifact.
            // The production normalizer may add only this array separator; it
            // cannot repair source content, claim shape, IDs or provenance.
            guard let steps = response.range(of: "\"derivation_steps\":["),
                  let separator = response.range(of: "\",\"", range: steps.upperBound..<response.endIndex) else {
                throw LatticeLensError.schemaViolation("fixture 无法构造缺失数组逗号的公式响应")
            }
            response.remove(at: response.index(after: separator.lowerBound))
        }
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
        "https://ar5iv.labs.arxiv.org/html/2608.12345",
        // `AppFixtureLargeData` assigns 2608.00000 to paper 9100000. This
        // exact URL maps to the deterministic in-process HTML fixture below;
        // it is never fetched by URLSession in the UIFixture dependency graph.
        "https://ar5iv.labs.arxiv.org/html/2608.00000",
        "https://ar5iv.labs.arxiv.org/html/2509.09367",
        "https://ar5iv.labs.arxiv.org/html/2608.12346",
        "https://ar5iv.labs.arxiv.org/html/2608.12347"
    ]

    func preflight(request: URLRequest) async throws -> HTTPURLResponse {
        guard let url = request.url, Self.allowedURLs.contains(url.absoluteString) else {
            throw FullTextServiceError.invalidSource
        }
        let data = url.host == "ar5iv.labs.arxiv.org" ? AppFixtureHTML.data(path: url.path) : try AppFixturePDF.data()
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
        let data = url.host == "ar5iv.labs.arxiv.org" ? AppFixtureHTML.data(path: url.path) : try AppFixturePDF.data()
        guard data.count <= maximumBytes,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": url.host == "ar5iv.labs.arxiv.org" ? "text/html" : "application/pdf"]) else {
            throw FullTextServiceError.fileTooLarge
        }
        return FullTextDownload(data: data, response: response)
    }
}

private enum AppFixtureHTML {
    static func data(path: String) -> Data {
        switch path {
        case "/html/2608.12346":
            return equationGroupData()
        case "/html/2608.12347":
            return incompleteEquationData()
        default:
            return ordinaryData()
        }
    }

    private static func ordinaryData() -> Data {
        Data("""
        <!doctype html><html><head><title>Fixture ar5iv paper</title></head><body>
        <main><h1>Fixture lattice paper</h1><p>We define a reduced correlator.</p>
        <table class="ltx_equation ltx_eqn_table"><tr><td><math alttext="C(t)=A exp(-m t)"><semantics><mrow><mi>C</mi></mrow><annotation encoding="application/x-tex">C(t)=A e^{-mt}</annotation></semantics></math></td><td><span class="ltx_tag ltx_tag_equation">(1)</span></td></tr></table>
        <h2>Renormalization</h2>
        <table class="ltx_equation ltx_eqn_table"><tr><td><math><semantics><mrow><mi>Z</mi></mrow><annotation encoding="application/x-tex">Z_O(\\mu) O^{\\mathrm{bare}}</annotation></semantics></math></td><td><span class="ltx_tag ltx_tag_equation">(2.3)</span></td></tr></table>
        <h2>Appendix</h2>
        <table class="ltx_equation ltx_eqn_table"><tr><td><math><semantics><mrow><mi>R</mi></mrow><annotation encoding="application/x-tex">R=\\frac{C_3}{C_2}</annotation></semantics></math></td><td><span class="ltx_tag ltx_tag_equation">(A.1)</span></td></tr></table>
        <p>The fit parameter is constrained by the displayed equations.</p></main></body></html>
        """.utf8)
    }

    /// Matches the row-level shape ar5iv uses inside an equation group. The
    /// group itself is not labelled; each `tr.ltx_equation` is.
    private static func equationGroupData() -> Data {
        Data("""
        <!doctype html><html><body><main><h2>Grouped equations</h2>
        <table class="ltx_equationgroup ltx_eqnarray"><tbody>
        <tr class="ltx_equation ltx_eqn_row"><td><math><semantics><annotation encoding="application/x-tex">G_1 = C_2/C_0</annotation></semantics></math></td><td><span class="ltx_tag ltx_tag_equation">(4a)</span></td></tr>
        <tr class="ltx_equation ltx_eqn_row"><td><math alttext="G_2 = C_3/C_0"><semantics><annotation encoding="application/x-tex">G_2 = C_3/C_0</annotation></semantics></math></td><td><span class="ltx_tag ltx_tag_equation">(4b)</span></td></tr>
        </tbody></table></main></body></html>
        """.utf8)
    }

    /// A visible numbered tag with no semantic TeX must not be silently
    /// omitted from an all-numbered-equations request.
    private static func incompleteEquationData() -> Data {
        Data("""
        <!doctype html><html><body><main><h2>Incomplete equation fixture</h2>
        <table class="ltx_equation ltx_eqn_table"><tr><td><math><semantics><annotation encoding="application/x-tex">M = A+B</annotation></semantics></math></td><td><span class="ltx_tag ltx_tag_equation">(5)</span></td></tr></table>
        <div class="ltx_equation"><span class="ltx_tag ltx_tag_equation">(6)</span><p>Renderer lost the MathML annotation.</p></div>
        </main></body></html>
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

/// Layout-only synthetic content. The view requires both fixture mode and
/// an explicit process flag; no library, provider or cached artifact is used.
enum FormulaReaderLayoutFixture {
    static let claims: [EvidenceClaim] = (1...3).map { index in
        EvidenceClaim(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)")!,
            textZH: #"排版测试（合成资料）：局域双线性算符 $\mathcal{O}_{\Gamma}(x)$，其中 \(\Gamma\) 表示 Dirac 结构；无分隔符写法 \bar{\psi}(x)\Gamma\psi(x) 应保持在句中。"#,
            epistemicStatus: .inference, evidenceIDs: [],
            formulaTeX: index == 2
                ? #"\begin{aligned} C(t)&=A e^{-mt}\\ m_{\mathrm{eff}}(t)&=\log\frac{C(t)}{C(t+a)}\end{aligned}"#
                : #"\mathcal{C}_{\Gamma}^{(3)}(\mathbf{p}',\mathbf{p};t,\tau)=\sum_{\mathbf{x},\mathbf{y}}e^{-i\mathbf{p}'\cdot\mathbf{x}}e^{i(\mathbf{p}'-\mathbf{p})\cdot\mathbf{y}}\langle 0|\chi(\mathbf{x},t)\bar{\psi}(\mathbf{y},\tau)\Gamma\psi(\mathbf{y},\tau)\bar{\chi}(0)|0\rangle"#,
            derivationSteps: [
                #"定义算符 $\mathcal O_\Gamma=\bar\psi\Gamma\psi$，并保留句末标点。此处只检查排版，不声称验证物理推导。"#,
                #"插入完备关系：$$\mathbb{1}=\sum_n |n\rangle\langle n|$$然后继续同一推导步骤的文字说明。"#,
                #"无分隔符的比值 \frac{C(t)}{C(t+a)} 与带分隔符的 $\frac{C(t)}{C(t+a)}$ 应使用相同字形。"#,
                #"矩阵和多行公式：\[\begin{pmatrix}a&b\\c&d\end{pmatrix}\begin{pmatrix}x\\y\end{pmatrix}=\begin{pmatrix}ax+by\\cx+dy\end{pmatrix}\]"#
            ] + (5...12).map { step in
                #"长列表步骤 "# + String(step) + #"：在 $t\gg a$ 下展示 $\sum_{n=0}^{N}A_n e^{-E_n t}$，核对上下标、段落间距及滚动可达性。测试资料不代表任何论文结论。"#
            },
            conclusionZH: #"最终检查点：$\mathcal{O}_{\Gamma}$、\frac{a}{b} 和 $C(t)$ 均可阅读。"#)
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

    /// A separate, explicitly opted-in large fixture may use a real local
    /// SwiftData store so UI tests can verify quit/relaunch durability. Its
    /// directory must be a fresh child of the scheme's disposable test root,
    /// and that root must remain beneath the project root embedded only in
    /// the UIFixture build configuration. No production/default store path is
    /// ever consulted for this mode.
    static var requestsDiskBackedLargeFixture: Bool {
        requestsDiskBackedLargeFixture(environment: ProcessInfo.processInfo.environment,
                                       arguments: CommandLine.arguments,
                                       argumentDomain: launchArgumentDomain)
    }

    static func requestsDiskBackedLargeFixture(environment: [String: String],
                                                arguments: [String],
                                                argumentDomain: [String: Any] = [:]) -> Bool {
        let fixtureEnabled = usesFixtureDependencies(environment: environment,
                                                      arguments: arguments,
                                                      argumentDomain: argumentDomain)
        let largeFixtureEnabled = fixtureEnabled &&
            (environment["LATTICELENS_LARGE_UI_FIXTURE"] == "1" ||
             arguments.contains("-LatticeLensLargeUIFixture") ||
             arguments.contains("LatticeLensLargeUIFixture") ||
             enabledArgument(named: "LatticeLensLargeUIFixture", in: argumentDomain))
        let diskModeEnabled = environment["LATTICELENS_DISK_BACKED_UI_FIXTURE"] == "1" ||
            arguments.contains("-LatticeLensDiskBackedUIFixture") ||
            arguments.contains("LatticeLensDiskBackedUIFixture") ||
            enabledArgument(named: "LatticeLensDiskBackedUIFixture", in: argumentDomain)
        return largeFixtureEnabled && diskModeEnabled
    }

    static var diskBackedLargeFixtureStoreURL: URL? {
        diskBackedLargeFixtureStoreURL(environment: ProcessInfo.processInfo.environment,
                                       arguments: CommandLine.arguments,
                                       argumentDomain: launchArgumentDomain,
                                       infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    static func diskBackedLargeFixtureStoreURL(environment: [String: String],
                                                arguments: [String],
                                                argumentDomain: [String: Any] = [:],
                                                infoDictionary: [String: Any]) -> URL? {
        guard requestsDiskBackedLargeFixture(environment: environment,
                                              arguments: arguments,
                                              argumentDomain: argumentDomain),
              let rawProjectRoot = (infoDictionary["LatticeLensProjectLocalRoot"] as? String)
                ?? projectLocalRoot(),
              rawProjectRoot.hasPrefix("/"),
              let rawTestStoreRoot = environment["LATTICELENS_TEST_STORE_ROOT"],
              rawTestStoreRoot.hasPrefix("/"),
              let rawFixtureRoot = environment["LATTICELENS_DISK_UI_FIXTURE_STORE_ROOT"] ??
                stringArgument(named: "LatticeLensDiskUIFixtureStoreRoot", in: argumentDomain) ??
                commandLineValue(named: "-LatticeLensDiskUIFixtureStoreRoot", in: arguments),
              rawFixtureRoot.hasPrefix("/") else {
            return nil
        }

        let projectRoot = canonicalPath(rawProjectRoot)
        let testStoreRoot = canonicalPath(rawTestStoreRoot)
        let fixtureRoot = canonicalPath(rawFixtureRoot)
        guard isStrictDescendant(testStoreRoot, of: projectRoot),
              isStrictDescendant(fixtureRoot, of: testStoreRoot) else {
            return nil
        }
        return URL(fileURLWithPath: fixtureRoot, isDirectory: true)
            .appending(path: "LatticeLens-v11.store")
    }

    /// Resolve the task boundary from the compiled fixture source location.
    /// This avoids relying on custom Info.plist keys, which Xcode may omit
    /// from a generated plist even when a matching INFOPLIST_KEY build
    /// setting is present. The disk-fixture app is built from Sources inside
    /// the user-authorized Reference_manager tree.
    static func projectLocalRoot(sourceFilePath: String = #filePath) -> String? {
        let sourceURL = URL(fileURLWithPath: sourceFilePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        var directory = sourceURL.deletingLastPathComponent()
        while directory.path != directory.deletingLastPathComponent().path {
            if directory.lastPathComponent == "Reference_manager" {
                return directory.standardizedFileURL.resolvingSymlinksInPath().path
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    private static func commandLineValue(named key: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isStrictDescendant(_ path: String, of root: String) -> Bool {
        path != root && path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// UI automation may request only the three release acceptance sizes.  A
    /// normal launch ignores this environment key entirely, and an arbitrary
    /// value never becomes a layout input.
    static var fixtureWindowSize: CGSize? {
        guard usesFixtureDependencies else { return nil }
        switch ProcessInfo.processInfo.environment["LATTICELENS_FIXTURE_WINDOW_SIZE"] ??
            stringArgument(named: "LatticeLensFixtureWindowSize", in: launchArgumentDomain) {
        case "820x640": return CGSize(width: 820, height: 640)
        case "1280x820": return CGSize(width: 1_280, height: 820)
        case "1440x900": return CGSize(width: 1_440, height: 900)
        default: return nil
        }
    }

    /// Fixture caches are rooted beside the isolated test store.  The UI
    /// fixture build also embeds this value in Info.plist so the AUT remains
    /// project-local when XCTest drops per-launch environment overrides.
    static var fixtureCacheRoot: String? {
        fixtureCacheRoot(environment: ProcessInfo.processInfo.environment,
                         infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    static func fixtureCacheRoot(environment: [String: String],
                                 infoDictionary: [String: Any]) -> String? {
        if let value = environment["LATTICELENS_FIXTURE_CACHE_ROOT"], value.hasPrefix("/") {
            return value
        }
        if let value = infoDictionary["LatticeLensFixtureCacheRoot"] as? String,
           value.hasPrefix("/") {
            return value
        }
        guard let testStoreRoot = environment["LATTICELENS_TEST_STORE_ROOT"],
              testStoreRoot.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: testStoreRoot, isDirectory: true)
            .appending(path: "FixtureCache").path
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

/// Deterministic records used exclusively by the large UI suite. The default
/// fixture remains process-local and in-memory; the separately gated disk mode
/// uses these same public mutations to exercise the production repository and
/// preserve user actions across an app relaunch.
///
/// No user/library bytes, live INSPIRE responses, PDFs, images, credentials,
/// or model output are read here.  `AppFixturePDF` and
/// `AppFixtureVisionImageLoader` remain bounded local substitutes only when a
/// UI case explicitly requests a download/vision preflight.
struct AppFixtureLargeSeed: Sendable {
    let authorRecid: Int
    let authors: [Author]
    let papers: [Paper]
    let tags: [LibraryTag]
    let tagLinks: [PaperTagLink]
    let collections: [PaperCollection]
    let collectionLinks: [CollectionPaperLink]
    let checkpoints: [SyncCheckpoint]
    let savedQueries: [SavedInspireQuery]
    let radarEvents: [RadarEvent]
    let workspaces: [PaperWorkspace]
    let evidenceAnchors: [EvidenceAnchor]
}

protocol AppFixtureLargeSeedCommitting: Sendable {
    func commitLargeFixtureSeed(_ seed: AppFixtureLargeSeed) async throws
}

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
    static let firstPaperID = 9_100_000
    static let formulaRelaunchJobID = "fixture-disk-relaunch-formula-job-v1"

    static func formulaRelaunchCheckpoint(now: Date = Date()) throws -> FormulaDerivationCheckpoint {
        let jobID = formulaRelaunchJobID
        let equationID = "fixture-equation-1"
        let documentHash = "fixture-formula-document-v1"
        let sourceTeX = "x=y"
        let step = FormulaDerivationStep(
            stepID: "\(equationID):step:1", ordinal: 1,
            textZH: "fixture 只驗證持久化鏈結，不代表物理推導已審查。",
            beforeTeX: sourceTeX, afterTeX: sourceTeX,
            ruleOrAssumption: "synthetic identity fixture",
            evidenceAnchorIDs: ["fixture-large-anchor-001"],
            sourceDocumentHashes: [documentHash], epistemicStatus: .inference)
        var segment = FormulaDerivationSegmentCheckpoint(equationID: equationID, sourceTeX: sourceTeX)
        try segment.appendSegment(index: 0, steps: [step], isFinal: true,
            continuationSummary: nil, conclusionZH: "fixture checkpoint complete",
            requestID: "fixture-request-\(equationID)",
            requestPayloadHash: String(repeating: "a", count: 64),
            responseHash: String(repeating: "b", count: 64), receivedBytes: 96,
            receivedCharacters: 72, firstContentAt: now, lastContentAt: now.addingTimeInterval(1))
        let completedClaim = EvidenceClaim(textZH: "合成 checkpoint 原文公式",
            epistemicStatus: .direct, evidenceIDs: ["fixture-large-anchor-001"],
            formulaTeX: sourceTeX, equationID: equationID,
            derivationSteps: [step.textZH], formulaDerivationSteps: [step],
            conclusionZH: segment.conclusionZH,
            derivationSegmentProvenanceHash: try segment.provenanceHash())
        let batches = [
            FormulaBatchCheckpoint(jobID: jobID, batchIndex: 0, batchTotal: 2,
                equationIDs: [equationID], payloadHash: "fixture-payload-1",
                requestID: "fixture-request-1", attemptCount: 1,
                receivedBytes: 96, receivedCharacters: 72, status: .completed, updatedAt: now),
            FormulaBatchCheckpoint(jobID: jobID, batchIndex: 1, batchTotal: 2,
                equationIDs: ["fixture-equation-2"], payloadHash: "fixture-payload-2",
                requestID: "fixture-request-2", attemptCount: 1,
                receivedBytes: 24, receivedCharacters: 18, status: .retryable,
                errorCategory: "fixture_interrupted", updatedAt: now),
        ]
        let job = FormulaDerivationJob(jobID: jobID, paperID: firstPaperID,
            documentHash: documentHash, inventoryHash: "fixture-formula-inventory-v1",
            equationIDs: [equationID, "fixture-equation-2"], state: .retryable,
            batches: batches, startedAt: now, updatedAt: now)
        return FormulaDerivationCheckpoint(job: job, completedClaimsByBatch: [0: [completedClaim]],
            derivationSegmentsByEquation: [equationID: segment],
            promptVersion: FormulaDerivationPrompt.version,
            schemaVersion: PaperInsightV2Validator.schemaVersion,
            contextFingerprint: "fixture-disk-relaunch-v1", updatedAt: now)
    }

    /// Deterministic category sets exercise the enabled union, hep-ph-only,
    /// multi-category, and legacy hep-th projections without live INSPIRE.
    /// The large fixture has exactly 60 ordinary authors and 200 papers in
    /// each group; the pinned self author is an additional hep-lat record.
    private static let categoryGroups = [
        ["hep-lat"],
        ["hep-ph"],
        ["hep-lat", "hep-ph"],
        ["hep-th"],
        ["hep-ph", "hep-th"],
    ]

    private static func categoryGroup(for index: Int) -> [String] {
        categoryGroups[index % categoryGroups.count]
    }

    private static func hasExpectedCategoryMatrix(_ snapshot: LibrarySnapshot) -> Bool {
        func key<C: Collection>(_ categories: C) -> String where C.Element == String {
            categories.sorted().joined(separator: "|")
        }
        let ordinaryAuthors = snapshot.authors.values.filter { !$0.isSelf }
        let authorCounts = Dictionary(grouping: ordinaryAuthors, by: { key($0.arxivCategories) })
            .mapValues { $0.count }
        let paperCounts = Dictionary(grouping: snapshot.papers.values, by: { key($0.arxivCategories) })
            .mapValues { $0.count }
        let expectedAuthorCounts = Dictionary(uniqueKeysWithValues: categoryGroups.map { (key($0), 60) })
        let expectedPaperCounts = Dictionary(uniqueKeysWithValues: categoryGroups.map { (key($0), 200) })
        return authorCounts == expectedAuthorCounts && paperCounts == expectedPaperCounts &&
            snapshot.authors[ProductContract.selfAuthorRecid]?.arxivCategories == Set(["hep-lat"])
    }

    /// A fresh V11 store has no domain rows. Unknown, partial, or read-error
    /// contents are intentionally not classified as fresh: disk fixture mode
    /// must never erase a previous test's evidence or silently repair an
    /// arbitrary store.
    static func isPristineStore(_ snapshot: LibrarySnapshot) -> Bool {
        snapshot.readErrorMessage == nil &&
            snapshot.authors.isEmpty && snapshot.papers.isEmpty && snapshot.paperAuthorLinks.isEmpty &&
            snapshot.insights.isEmpty && snapshot.evidenceInsights.isEmpty && snapshot.checkpoints.isEmpty &&
            snapshot.readingStates.isEmpty && snapshot.notes.isEmpty && snapshot.tags.isEmpty &&
            snapshot.paperTags.isEmpty && snapshot.collections.isEmpty && snapshot.collectionPapers.isEmpty &&
            snapshot.citationSnapshots.isEmpty && snapshot.bibTeXRecords.isEmpty &&
            snapshot.fullTextDocuments.isEmpty && snapshot.evidenceChunks.isEmpty && snapshot.evidenceAnchors.isEmpty &&
            snapshot.visionArtifacts.isEmpty && snapshot.syncBatches.isEmpty &&
            snapshot.authorIndexGenerations.isEmpty && snapshot.paperRevisionSnapshots.isEmpty &&
            snapshot.radarEvents.isEmpty && snapshot.savedInspireQueries.isEmpty &&
            snapshot.syncBatchesV3.isEmpty && snapshot.syncJobEvents.isEmpty && snapshot.contentBlobs.isEmpty &&
            snapshot.orphanedBlobDeletions.isEmpty && snapshot.documentReferences.isEmpty &&
            snapshot.userEvidenceAnchors.isEmpty && snapshot.notebookEntries.isEmpty &&
            snapshot.notebookAnchorLinks.isEmpty && snapshot.workspaces.isEmpty &&
            snapshot.workspacePaperLinks.isEmpty && snapshot.physicsContracts.isEmpty &&
            snapshot.physicsContractCells.isEmpty && snapshot.citationEdges.isEmpty && snapshot.coauthorEdges.isEmpty &&
            snapshot.exportRecords.isEmpty && snapshot.cloudSyncStates.isEmpty && snapshot.conflictCopies.isEmpty &&
            snapshot.importedBibliographies.isEmpty && snapshot.importConflicts.isEmpty && snapshot.migrationJournal.isEmpty &&
            snapshot.quarantinedEvidenceIDs.isEmpty
    }

    /// Structural sentinel for the immutable baseline. Additional notes,
    /// favorites, tags, or other user-driven fixture mutations are permitted;
    /// only the baseline's unique rows/counts are required on relaunch.
    static func isCompleteFixture(_ snapshot: LibrarySnapshot) -> Bool {
        guard snapshot.readErrorMessage == nil,
              snapshot.authors.count == authorCount,
              snapshot.authors[ProductContract.selfAuthorRecid]?.preferredName == "Zhao, Dian-Jun",
              snapshot.papers.count == paperCount,
              (0..<paperCount).allSatisfy({ snapshot.papers[firstPaperID + $0] != nil }),
              snapshot.paperAuthorLinks.count >= paperCount,
              snapshot.checkpoints.count >= jobCount,
              snapshot.tags.count >= tagCount,
              snapshot.paperTags.count >= tagCount,
              snapshot.collections.count >= collectionCount,
              snapshot.collectionPapers.count >= collectionCount,
              snapshot.savedInspireQueries.count >= radarQueryCount,
              snapshot.radarEvents.count >= radarEventCount,
              snapshot.workspaces.count >= workspaceCount,
              snapshot.evidenceAnchors.values.filter({ $0.paperID == firstPaperID }).count >= evidenceAnchorCount,
              snapshot.papers[firstPaperID]?.figures.count == figureCount,
              hasExpectedCategoryMatrix(snapshot) else {
            return false
        }
        return true
    }

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
                                  arxivCategories: Set(categoryGroup(for: index)),
                                  hIndex: value,
                                  hIndexState: .qualified,
                                  isTracked: index.isMultiple(of: 25),
                                  lastSyncedAt: now,
                                  lastCheckpointAt: now,
                                  lastSuccessfulSyncAt: now))
        }
        let largeFigures = (1...figureCount).map { index in
            PaperFigure(key: String(format: "fig-large-%03d", index),
                        url: URL(string: "https://fixture.invalid/figures/large-\(index).jpg"),
                        label: "Fixture Figure \(index)",
                        caption: "Large process-local fixture caption \(index). This is not a scientific claim.",
                        source: "fixture",
                        filename: "large-\(index).jpg")
        }
        let largeAbstract = String(repeating: "Large local fixture abstract text is display-only and does not support a physics conclusion. ", count: 250)
        let papers = (0..<paperCount).map { offset -> Paper in
            let paperID = firstPaperID + offset
            return Paper(literatureID: paperID,
                         titles: [PaperTitle(value: String(format: "Large Fixture Lattice Paper %04d", offset), source: "fixture")],
                         abstracts: [PaperAbstract(value: offset == 0 ? largeAbstract : "Process-local fixture abstract \(offset).", source: "fixture")],
                         preprintDate: now.addingTimeInterval(-Double(offset) * 86_400),
                         earliestDate: nil,
                         arxivID: String(format: "2608.%05d", offset),
                         arxivCategories: categoryGroup(for: offset),
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
        let tags = (1...tagCount).map { index in
            LibraryTag(id: fixtureUUID(scope: 1, index: index),
                       name: String(format: "Fixture tag %03d", index),
                       colorName: index.isMultiple(of: 2) ? "blue" : "orange",
                       createdAt: now)
        }
        let tagLinks = tags.map { PaperTagLink(paperID: firstPaperID, tagID: $0.id) }

        let collections = (1...collectionCount).map { index in
            PaperCollection(id: fixtureUUID(scope: 2, index: index),
                            name: String(format: "Fixture collection %03d", index),
                            createdAt: now)
        }
        let collectionLinks = collections.enumerated().map { zeroBasedIndex, collection in
            CollectionPaperLink(collectionID: collection.id,
                                 paperID: firstPaperID + (zeroBasedIndex % paperCount),
                                 addedAt: now)
        }
        let checkpoints = (1...jobCount).map { index in
            SyncCheckpoint(jobID: String(format: "fixture-job-%03d", index),
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
                           state: index.isMultiple(of: 2) ? .paused : .active)
        }

        let batchID = fixtureUUID(scope: 3, index: 1)
        let savedQueries = (1...radarQueryCount).map { index in
            SavedInspireQuery(id: fixtureUUID(scope: 4, index: index),
                              name: String(format: "Fixture Radar Query %03d", index),
                              query: "arxiv_categories:hep-lat and fixture:\(index)",
                              refreshPolicy: .manual,
                              isPaused: false,
                              lastRunAt: nil,
                              nextRunAt: nil,
                              createdAt: now)
        }
        let radarEvents = (1...radarEventCount).map { index in
            RadarEvent(id: fixtureUUID(scope: 5, index: index),
                       paperID: firstPaperID + (index % paperCount),
                       authorRecids: [ProductContract.selfAuthorRecid],
                       eventKind: index.isMultiple(of: 2) ? .fieldModified : .fieldAdded,
                       beforeHash: "fixture-before-\(index)",
                       afterHash: "fixture-after-\(index)",
                       changedFields: ["citation_count", "abstract"],
                       syncBatchID: batchID,
                       observedAt: now,
                       sourceURL: URL(string: "https://fixture.invalid/radar/\(index)")!,
                       isAcknowledged: index.isMultiple(of: 5))
        }
        let workspaces = (1...workspaceCount).map { index in
            PaperWorkspace(id: fixtureUUID(scope: 6, index: index),
                           name: String(format: "Fixture Workspace %03d", index),
                           createdAt: now,
                           updatedAt: now,
                           sortOrder: [firstPaperID + (index % paperCount)],
                           note: "process-local workspace fixture \(index)",
                           frozenExportHash: nil)
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
        let seed = AppFixtureLargeSeed(authorRecid: ProductContract.selfAuthorRecid,
                                       authors: authors,
                                       papers: papers,
                                       tags: tags,
                                       tagLinks: tagLinks,
                                       collections: collections,
                                       collectionLinks: collectionLinks,
                                       checkpoints: checkpoints,
                                       savedQueries: savedQueries,
                                       radarEvents: radarEvents,
                                       workspaces: workspaces,
                                       evidenceAnchors: anchors)
        if let batchStore = store as? any AppFixtureLargeSeedCommitting {
            try await batchStore.commitLargeFixtureSeed(seed)
            return
        }

        // Compatibility stores preserve the same semantic operations. The
        // disk-backed V8 repository commits these rows together and rebuilds
        // its derived search projection once for a fresh fixture.
        try await store.upsert(authors: seed.authors)
        _ = try await store.upsert(papers: seed.papers, for: seed.authorRecid)
        for tag in seed.tags { try await store.applyReferenceMutation(.upsertTag(tag)) }
        try await store.applyReferenceMutation(.setTags(paperID: firstPaperID,
                                                         tagIDs: Set(seed.tagLinks.map(\.tagID))))
        for collection in seed.collections {
            try await store.applyReferenceMutation(.upsertCollection(collection))
        }
        for link in seed.collectionLinks {
            try await store.applyReferenceMutation(.setCollectionPapers(collectionID: link.collectionID,
                                                                          paperIDs: [link.paperID],
                                                                          at: link.addedAt))
        }
        for checkpoint in seed.checkpoints { try await store.save(checkpoint: checkpoint) }
        for query in seed.savedQueries { try await store.applyV3(.saveQuery(query)) }
        for event in seed.radarEvents { try await store.applyV3(.saveRadarEvent(event)) }
        for workspace in seed.workspaces { try await store.applyV3(.saveWorkspace(workspace)) }
        try await store.saveEvidenceAnchors(seed.evidenceAnchors)
    }

    /// Keeps fixture IDs stable across launches without using process-random
    /// UUIDs; scopes keep independently generated entity sets disjoint.
    static func fixtureUUID(scope: Int, index: Int) -> UUID {
        let value = String(format: "00000000-%04X-4000-8000-%012X", scope, index)
        guard let uuid = UUID(uuidString: value) else { preconditionFailure("invalid deterministic fixture UUID") }
        return uuid
    }
}
