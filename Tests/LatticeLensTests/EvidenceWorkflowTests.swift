import Foundation
import CoreGraphics
import CoreText
import SwiftData
import XCTest
@testable import LatticeLens

private struct FormulaBatchRequestBodyFixture: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
    }

    let model: String
    let messages: [Message]
    let stream: Bool
    let maxTokens: Int?
    let maxCompletionTokens: Int?
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case responseFormat = "response_format"
    }

    init(system: String, userPayload: String, profile: ProviderProfile) {
        model = profile.effectiveModel
        messages = [Message(role: "system", content: system), Message(role: "user", content: userPayload)]
        stream = profile.usesStreaming
        if profile.provider == .openAI {
            maxTokens = nil
            maxCompletionTokens = profile.maxOutputTokens
        } else {
            maxTokens = profile.maxOutputTokens
            maxCompletionTokens = nil
        }
        responseFormat = profile.provider == .deepSeek ? ResponseFormat(type: "json_object") : nil
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

private struct NetworkForbiddenFullTextDownloader: FullTextDownloading {
    func preflight(request: URLRequest) async throws -> HTTPURLResponse {
        throw URLError(.unsupportedURL)
    }

    func download(request: URLRequest, maximumBytes: Int) async throws -> FullTextDownload {
        throw URLError(.unsupportedURL)
    }
}

final class EvidenceWorkflowTests: XCTestCase {
    func testFormulaInventoryParserRecoversNestedGroupedRowsAndSplitAnnotations() {
        let html = #"""
        <p>前置文字</p><main><table class="ltx_eqn_table"><tbody>
          <tr class="ltx_equation"><td><math><semantics><annotation encoding="application/x-tex">\alpha &amp; <mtext>\beta</mtext> = \gamma</annotation></semantics></math></td><td><span class="ltx_tag ltx_tag_equation">(4a)</span></td></tr>
          <tr class="ltx_equation"><td><math alttext="x_{i+1}=x_i"></math></td><td><span class="ltx_tag_equation">(4b)</span></td></tr>
        </tbody></table></main>
        """#

        let inventory = FormulaInventoryParser.parse(html: html, documentHash: "grouped-document")

        XCTAssertTrue(inventory.isComplete, inventory.failureReason ?? "")
        XCTAssertEqual(inventory.labels, ["(4a)", "(4b)"])
        XCTAssertEqual(inventory.items.map(\.sourceTeX), [#"\alpha & \beta = \gamma"#, "x_{i+1}=x_i"])
        XCTAssertEqual(inventory.items.map(\.ordinal), [1, 2])
        XCTAssertTrue(inventory.items.allSatisfy { $0.sourceByteEnd > $0.sourceByteStart && $0.evidenceID != nil })
        let sourceBytes = Array(html.utf8)
        let firstContainer = String(decoding: sourceBytes[inventory.items[0].sourceByteStart..<inventory.items[0].sourceByteEnd], as: UTF8.self)
        XCTAssertTrue(firstContainer.contains(#"<tr class="ltx_equation">"#), "DOM ranges are UTF-8 byte offsets despite multibyte text before the equation")
    }

    func testFormulaInventoryParserFailsClosedForDuplicateLabelsMissingTexAndMalformedMarkup() {
        let duplicate = #"""
        <div class="ltx_equation"><math alttext="a=b"></math><span class="ltx_tag_equation">(1)</span></div>
        <div class="ltx_equation"><math alttext="c=d"></math><span class="ltx_tag_equation">(1)</span></div>
        """#
        let missingTeX = #"<div class="ltx_equation"><math><mi>x</mi></math><span class="ltx_tag_equation">(2)</span></div>"#
        let malformed = #"<div class="ltx_equation"><math alttext="x=y"><span class="ltx_tag_equation">(3)</span></div>"#

        for html in [duplicate, missingTeX, malformed] {
            let inventory = FormulaInventoryParser.parse(html: html, documentHash: "invalid-document")
            XCTAssertFalse(inventory.isComplete, "invalid source markup must not produce a complete inventory")
            XCTAssertNotNil(inventory.failureReason)
        }
        XCTAssertTrue(FormulaInventoryParser.parse(html: duplicate, documentHash: "invalid-document").failureReason?.contains("重复") == true)
        XCTAssertTrue(FormulaInventoryParser.parse(html: missingTeX, documentHash: "invalid-document").failureReason?.contains("缺少") == true)
    }

    func testFormulaInventoryParserRefusesMoreThanConfiguredEquationLimit() {
        let rows = (1...257).map { index in
            #"<div class="ltx_equation"><math alttext="x_\#(index)=0"></math><span class="ltx_tag_equation">(\#(index))</span></div>"#
        }.joined()

        let inventory = FormulaInventoryParser.parse(html: rows, documentHash: "oversized-document")

        XCTAssertEqual(inventory.labelledEquationCount, 257)
        XCTAssertTrue(inventory.items.isEmpty)
        XCTAssertFalse(inventory.isComplete)
        XCTAssertTrue(inventory.failureReason?.contains("超过本地上限") == true)
    }

    func testFormulaInventoryParserAcceptsZeroAndExactlyConfiguredEquationLimit() {
        let empty = FormulaInventoryParser.parse(html: "<html><body>No numbered equations</body></html>",
                                                 documentHash: "empty-equation-document")
        XCTAssertTrue(empty.isComplete, empty.failureReason ?? "")
        XCTAssertEqual(empty.labelledEquationCount, 0)
        XCTAssertTrue(empty.items.isEmpty)

        let rows = (1...FormulaInventory.maximumItems).map { index in
            #"<div class="ltx_equation"><math alttext="x_\#(index)=0"></math><span class="ltx_tag_equation">(\#(index))</span></div>"#
        }.joined()
        let inventory = FormulaInventoryParser.parse(html: rows, documentHash: "maximum-equation-document")

        XCTAssertTrue(inventory.isComplete, inventory.failureReason ?? "")
        XCTAssertEqual(inventory.labelledEquationCount, FormulaInventory.maximumItems)
        XCTAssertEqual(inventory.items.count, FormulaInventory.maximumItems)
        XCTAssertEqual(inventory.items.map(\.ordinal), Array(1...FormulaInventory.maximumItems))
    }

    func testFormulaInventoryParserRejectsAmbiguousMathPairingAndHandlesQuotedGreaterThan() {
        let ambiguousGroup = #"""
        <div class="ltx_equation"><math alttext="a=b"></math><span class="ltx_tag_equation">(1)</span><span class="ltx_tag_equation">(2)</span></div>
        """#
        let extraMath = #"""
        <div class="ltx_equation"><math alttext="a=b"></math><math alttext="u+v"></math><span class="ltx_tag_equation">(3)</span></div>
        """#
        let quotedGreaterThan = #"<div class="ltx_equation"><math alttext="q_{x>y}=1"></math><span class="ltx_tag_equation">(4)</span></div>"#

        for html in [ambiguousGroup, extraMath] {
            let inventory = FormulaInventoryParser.parse(html: html, documentHash: "ambiguous-document")
            XCTAssertFalse(inventory.isComplete, "one-to-many or many-to-one source pairing must fail closed")
            XCTAssertNotNil(inventory.failureReason)
        }

        let quotedInventory = FormulaInventoryParser.parse(html: quotedGreaterThan, documentHash: "quoted-attribute-document")
        XCTAssertTrue(quotedInventory.isComplete, quotedInventory.failureReason ?? "")
        XCTAssertEqual(quotedInventory.items.map(\.sourceTeX), ["q_{x>y}=1"])
    }

    func testFormulaInventoryParserIgnoresRawTextMarkupAndHandlesVoidTags() {
        let html = #"""
        <!doctype html>
        <script>const fake = '<div class="ltx_equation"><math alttext="fake=1"></math><span class="ltx_tag_equation">(9)</span></div>';</script>
        <style>.fake::after { content: "<span class='ltx_tag_equation'>(8)</span>"; }</style>
        <textarea><span class="ltx_tag_equation">(7)</span></textarea>
        <div class="ltx_equation">
          <img src="fixture.png"><br><input disabled><wbr>
          <math alttext="x_{i}>0"></math><span class="ltx_tag_equation">(1)</span>
        </div>
        """#

        let inventory = FormulaInventoryParser.parse(html: html, documentHash: "raw-text-void-document")

        XCTAssertTrue(inventory.isComplete, inventory.failureReason ?? "")
        XCTAssertEqual(inventory.labels, ["(1)"], "markup-like text inside raw-text elements is not document math")
        XCTAssertEqual(inventory.items.map(\.sourceTeX), ["x_{i}>0"])

        let unterminatedRawText = #"<script><div class="ltx_equation"><math alttext="fake=1"></math><span class="ltx_tag_equation">(9)</span></div>"#
        let incomplete = FormulaInventoryParser.parse(html: unterminatedRawText, documentHash: "unterminated-raw-text")
        XCTAssertFalse(incomplete.isComplete, "an unclosed raw-text element cannot certify a complete snapshot")
        XCTAssertNotNil(incomplete.failureReason)
    }

    func testFormulaInventoryParserPreservesMixedAnnotationOrderAndRejectsUnsupportedVisibleLabels() {
        let interleavedAnnotation = #"""
        <div class="ltx_equation"><math><semantics><annotation encoding="application/x-tex">a<mtext>b</mtext>c</annotation></semantics></math><span class="ltx_tag_equation">(1)</span></div>
        <div class="ltx_equation"><math alttext="not indexed"></math><span class="ltx_tag_equation">(*)</span></div>
        """#

        let inventory = FormulaInventoryParser.parse(html: interleavedAnnotation, documentHash: "mixed-annotation-document")

        XCTAssertEqual(inventory.labelledEquationCount, 2,
                       "every visible equation tag must participate in completeness accounting")
        XCTAssertEqual(inventory.items.map(\.sourceTeX), ["abc"],
                       "text before, inside, and after child elements must retain source order")
        XCTAssertFalse(inventory.isComplete, "an unsupported visible equation label cannot disappear into an empty complete inventory")
        XCTAssertTrue(inventory.failureReason?.contains("不支持") == true)
    }

    func testFormulaInventoryParserPairsNestedAlignRowsAndMultlineEquations() {
        let html = #"""
        <div class="ltx_align">
          <div class="ltx_equation"><math alttext="x+y=1"></math><span class="ltx_tag_equation">(2a)</span></div>
          <div class="ltx_equation"><math alttext="x-y=0"></math><span class="ltx_tag_equation">(2b)</span></div>
        </div>
        <div class="ltx_multline"><div class="ltx_equation"><math alttext="z=2"></math><span class="ltx_tag_equation">(3)</span></div></div>
        """#

        let inventory = FormulaInventoryParser.parse(html: html, documentHash: "align-multline-document")

        XCTAssertTrue(inventory.isComplete, inventory.failureReason ?? "")
        XCTAssertEqual(inventory.labels, ["(2a)", "(2b)", "(3)"])
        XCTAssertEqual(inventory.items.map(\.sourceTeX), ["x+y=1", "x-y=0", "z=2"])
    }

    func testFormulaInventoryParserRequiresMathAndLabelToShareAnEquationRow() {
        let pairedRows = #"""
        <table class="ltx_eqn_table">
          <tr><td><math alttext="x=1"></math></td><td><span class="ltx_tag_equation">(1)</span></td></tr>
          <tr><td><math alttext="y=2"></math></td><td><span class="ltx_tag_equation">(2)</span></td></tr>
        </table>
        """#
        let detachedRows = #"""
        <table class="ltx_eqn_table">
          <tr><td><math alttext="x=1"></math></td></tr>
          <tr><td><math alttext="y=2"></math><span class="ltx_tag_equation">(1)</span><span class="ltx_tag_equation">(2)</span></td></tr>
        </table>
        """#

        let paired = FormulaInventoryParser.parse(html: pairedRows, documentHash: "equation-row-pairing")
        XCTAssertTrue(paired.isComplete, paired.failureReason ?? "")
        XCTAssertEqual(paired.items.map(\.sourceTeX), ["x=1", "y=2"])

        let detached = FormulaInventoryParser.parse(html: detachedRows, documentHash: "equation-row-pairing")
        XCTAssertFalse(detached.isComplete, "matching global counts cannot prove labels belong to equations in sibling rows")
        XCTAssertNotNil(detached.failureReason)
    }

    func testExplicitPDFDownloadExtractAnchorsAndDeleteUseOnlyLocalFixtureTransport() async throws {
        let root = try makeProjectLocalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("fulltext-cache", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixturePDFURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let store = InMemoryLibraryStore()
        let service = FullTextService(store: store, cacheDirectory: cache, session: session)
        // `fixture.invalid` is reserved for the isolated transport contract;
        // it is allowlisted by the production URL policy and cannot resolve
        // to a live endpoint during this integration test.
        let sourceURL = try XCTUnwrap(URL(string: "https://fixture.invalid/paper.pdf"))

        let document = try await service.downloadAndExtract(paperID: 314, sourceURL: sourceURL, sourceKind: .arxivPDF)
        XCTAssertEqual(document.extractionState, .extracted)
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.sourceURL, sourceURL)
        XCTAssertGreaterThan(document.byteCount, 100)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent(try XCTUnwrap(document.localFilename)).path))

        let afterExtraction = await store.snapshot()
        let chunks = afterExtraction.evidenceChunks.values.filter { $0.documentHash == document.sha256 }
        let anchors = afterExtraction.evidenceAnchors.values.filter { $0.sourceKind == .pdf && $0.paperID == 314 }
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(anchors.count, 2)
        XCTAssertEqual(Set(anchors.compactMap(\.page)), [1, 2])
        XCTAssertTrue(chunks.contains { $0.text.contains("renormalization scale is 2 GeV") })
        XCTAssertTrue(chunks.allSatisfy { $0.characterRangeStart < $0.characterRangeEnd && $0.textHash == StableHash.sha256($0.text) })
        let actualPaper = Paper(literatureID: 314, titles: [PaperTitle(value: "PDF integration fixture", source: "fixture")], abstracts: [],
                                preprintDate: nil, earliestDate: nil, arxivID: nil, arxivCategories: ["hep-lat"], doi: nil,
                                citationCount: nil, publicationStatus: nil, updated: nil, figures: [], firstSeenAt: Date(), isRead: false)
        let pageOneAnchor = try XCTUnwrap(anchors.first(where: { $0.page == 1 }))
        let payload = EvidenceInputPayload(paper: actualPaper, document: document, chunks: chunks.sorted { $0.id < $1.id }, anchors: anchors.sorted { $0.id < $1.id })
        XCTAssertNoThrow(try PaperInsightV2Validator.decode(Data(validInsightJSON(anchorID: pageOneAnchor.id).utf8), source: payload, maximumFigures: 0),
                        "direct numeric claim 必须能用这个实际 PDF 的页级 anchor 回查")

        try await service.delete(document: document)
        let afterDelete = await store.snapshot()
        XCTAssertNil(afterDelete.fullTextDocuments[document.id])
        XCTAssertFalse(afterDelete.evidenceChunks.values.contains { $0.documentHash == document.sha256 })
        XCTAssertFalse(afterDelete.evidenceAnchors.values.contains { $0.sourceKind == .pdf && $0.paperID == 314 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent(try XCTUnwrap(document.localFilename)).path))
    }

    func testAppFixtureDownloaderProducesExtractablePDFWithoutClaimingNumberedEquationCoverage() async throws {
        let root = try makeProjectLocalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InMemoryLibraryStore()
        let service = FullTextService(store: store, cacheDirectory: root, downloader: AppFixtureFullTextDownloader())
        let sourceURL = try XCTUnwrap(URL(string: "https://fixture.invalid/fulltext/1234567.pdf"))
        let document = try await service.downloadAndExtract(paperID: 1234567, sourceURL: sourceURL, sourceKind: .arxivPDF)
        XCTAssertEqual(document.extractionState, .extracted)
        XCTAssertEqual(document.pageCount, 1)
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.evidenceAnchors.values.contains { $0.sourceKind == .pdf && $0.paperID == 1234567 })

        let payload = EvidenceInputPayload(
            paper: Paper(literatureID: 1234567, titles: [PaperTitle(value: "fixture full text", source: "fixture")],
                         abstracts: [PaperAbstract(value: "fixture abstract", source: "fixture")], preprintDate: nil,
                         earliestDate: nil, arxivID: nil, arxivCategories: ["hep-lat"], doi: nil, citationCount: nil,
                         publicationStatus: nil, updated: nil, figures: [], firstSeenAt: Date(), isRead: false),
            document: document,
            chunks: snapshot.evidenceChunks.values.sorted { $0.id < $1.id },
            anchors: snapshot.evidenceAnchors.values.sorted { $0.id < $1.id }
        )
        XCTAssertFalse(payload.numberedEquationCoverageComplete)
        XCTAssertTrue(payload.numberedEquationCoverageFailure?.contains("PDF") == true)
    }

    /// Regression for a real ar5iv-shaped source: the extractor intentionally
    /// has no PDF page coordinate for HTML, but its quote/hash/anchor ID must
    /// remain usable by the exact formula-generation workflow.
    func testArxivHTMLFormulaDerivationWorkflowAcceptsCurrentDocumentAnchors() async throws {
        let root = try makeProjectLocalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InMemoryLibraryStore()
        let service = FullTextService(store: store, cacheDirectory: root, downloader: AppFixtureFullTextDownloader())
        let sourceURL = try XCTUnwrap(URL(string: "https://ar5iv.labs.arxiv.org/html/2509.09367"))
        let paper = Paper(literatureID: 2_509_093_67,
                          titles: [PaperTitle(value: "HTML formula fixture", source: "fixture")],
                          abstracts: [PaperAbstract(value: "Fixture ar5iv abstract.", source: "fixture")],
                          preprintDate: nil, earliestDate: nil, arxivID: "2509.09367", arxivCategories: ["hep-lat"],
                          doi: nil, citationCount: nil, publicationStatus: nil, updated: nil, figures: [],
                          firstSeenAt: Date(), isRead: false)
        _ = try await store.upsert(papers: [paper], for: 21)
        let document = try await service.downloadAndExtract(paperID: paper.literatureID, sourceURL: sourceURL, sourceKind: .arxivHTML)
        XCTAssertEqual(document.sourceKind, .arxivHTML)

        let snapshot = await store.snapshot()
        let htmlAnchors = snapshot.evidenceAnchors.values.filter { $0.paperID == paper.literatureID && $0.sourceKind == .pdf }
        XCTAssertFalse(htmlAnchors.isEmpty)
        XCTAssertTrue(htmlAnchors.allSatisfy { $0.page == nil }, "ar5iv HTML 不能伪造 PDF 页码")
        let numberedChunks = snapshot.evidenceChunks.values.filter { $0.paperID == paper.literatureID && $0.equationID != nil }
            .sorted { ($0.equationOrdinal ?? 0) < ($1.equationOrdinal ?? 0) }
        XCTAssertEqual(numberedChunks.map(\.equationLabel), ["(1)", "(2.3)", "(A.1)"])
        XCTAssertEqual(numberedChunks.map(\.equationTeX), ["C(t)=A e^{-mt}", #"Z_O(\mu) O^{\mathrm{bare}}"#, #"R=\frac{C_3}{C_2}"#])
        XCTAssertTrue(numberedChunks.allSatisfy { $0.documentHash == document.sha256 && $0.textHash == StableHash.sha256($0.text) })
        XCTAssertEqual(document.numberedEquationIndexVersion, FullTextService.numberedEquationIndexVersion)
        XCTAssertEqual(document.numberedEquationCount, 3)
        XCTAssertEqual(document.numberedEquationIndexComplete, true)
        XCTAssertNil(document.numberedEquationIndexFailure)

        let workflow = EvidenceInsightWorkflow(
            store: store,
            client: AppFixtureLLMClient(emitsUnanchoredEvidenceClaims: true, emitsMissingArrayComma: true)
        )
        let settings = LLMSettings(profiles: ["openAI": ProviderProfile(baseURL: "https://fixture.invalid/v1", manualModel: "fixture-text-model")],
                                   automaticAnalysis: false, mode: .fast, maximumFigures: 0)
        let artifact = try await workflow.generate(for: paper, settings: settings, apiKey: "fixture") { _ in }
        XCTAssertEqual(artifact.insight.physics.importantFormulaDerivations.count, 3)
        XCTAssertEqual(Set(artifact.insight.physics.importantFormulaDerivations.compactMap(\.equationID)), Set(numberedChunks.compactMap(\.equationID)))
        XCTAssertEqual(artifact.insight.physics.importantFormulaDerivations.map(\.formulaTeX), numberedChunks.compactMap(\.equationTeX))
        XCTAssertTrue(artifact.numberedEquationCoverageComplete)
        XCTAssertEqual(artifact.numberedEquationIDs, numberedChunks.compactMap(\.equationID))
        XCTAssertEqual(artifact.insight.physics.importantFormulaDerivations[0].derivationSteps.count, 2,
                       "缺失逗号的两个完整 formula steps 必须被恢复为两个独立数组项")
        XCTAssertEqual(artifact.insight.physics.researchQuestion.epistemicStatus, .missing)
        XCTAssertTrue(artifact.insight.physics.methodAndDataFlow.isEmpty)
        XCTAssertTrue(artifact.insight.physics.mainResults.isEmpty)
        XCTAssertTrue(artifact.insight.physics.reasonableInferences.isEmpty)
        XCTAssertTrue(artifact.insight.physics.caveats.isEmpty)
        XCTAssertTrue(artifact.insight.physics.missingInformation.contains {
            $0.textZH.contains("已丢弃且未作为论文结论保存") && $0.epistemicStatus == .missing && $0.evidenceIDs.isEmpty
        })
    }

    @MainActor
    func testRecreatedFullTextServiceReindexesCachedArxivHTMLWithoutNetwork() async throws {
        let root = try makeProjectLocalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheDirectory = root.appending(path: "FullText", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let sourceURL = try XCTUnwrap(URL(string: "https://ar5iv.labs.arxiv.org/html/2608.00000"))
        let localFixture = try await AppFixtureFullTextDownloader().download(
            request: URLRequest(url: sourceURL), maximumBytes: FullTextService.maximumBytes
        )
        let sourceHash = StableHash.sha256(localFixture.data)
        let filename = "\(sourceHash).html"
        try localFixture.data.write(to: cacheDirectory.appendingPathComponent(filename), options: .atomic)

        let storeURL = root.appendingPathComponent("LatticeLens-v11.store")
        let schema = Schema(versionedSchema: LatticeLensSchemaV11.self)
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV11.self,
                                           configurations: configuration)
        try V8TypedStoreCodec.materialize(LibrarySnapshot(schemaVersion: 8, v3SchemaVersion: 3),
                                          in: container.mainContext, sourceSchemaVersion: 8)
        try V9TypedSearchIndex.rebuild(in: container.mainContext)
        let store = V8TypedLibraryStore(modelContainer: container)
        let oldDocument = FullTextDocument(
            paperID: 9_100_000, sourceURL: sourceURL, sourceKind: .arxivHTML,
            sha256: sourceHash, byteCount: localFixture.data.count, localFilename: filename,
            pageCount: nil, extractionState: .downloaded,
            downloadedAt: Date(timeIntervalSince1970: 1_760_000_000), lastErrorCategory: nil
        )
        try await store.saveFullText(document: oldDocument, chunks: [], anchors: [])
        let restoredContext = await store.paperContext(paperID: oldDocument.paperID, insightCacheKey: nil)
        let restoredDocument = try XCTUnwrap(restoredContext.fullTextDocuments.first)

        // A new service instance represents the post-relaunch reader. Its
        // downloader deliberately rejects all requests: successful indexing
        // must come from the content-addressed file under the stable cache.
        let relaunchedService = FullTextService(
            store: store, cacheDirectory: cacheDirectory,
            downloader: NetworkForbiddenFullTextDownloader()
        )
        let indexed = try await relaunchedService.reindexNumberedEquations(document: restoredDocument)

        XCTAssertEqual(indexed.sha256, sourceHash)
        XCTAssertEqual(indexed.localFilename, filename)
        XCTAssertEqual(indexed.numberedEquationIndexVersion, FullTextService.numberedEquationIndexVersion)
        XCTAssertEqual(indexed.numberedEquationCount, 3)
        XCTAssertEqual(indexed.numberedEquationIndexComplete, true)
        let inventory = try await store.formulaInventory(paperID: oldDocument.paperID,
                                                         documentHash: sourceHash)
        XCTAssertEqual(inventory?.labels, ["(1)", "(2.3)", "(A.1)"])
        XCTAssertEqual(inventory?.isComplete, true)
        XCTAssertEqual(indexed.numberedEquationInventoryHash, inventory?.inventoryHash,
                       "the domain projection must use the canonical persisted inventory identity")

        let savedContext = await store.paperContext(paperID: oldDocument.paperID, insightCacheKey: nil)
        XCTAssertEqual(savedContext.fullTextDocuments.first, indexed,
                       "the locally rebuilt inventory receipt must be committed with the restored document")
        XCTAssertEqual(try Data(contentsOf: cacheDirectory.appendingPathComponent(filename)), localFixture.data,
                       "reindexing must preserve the original content-addressed bytes")
    }

    func testArxivEquationGroupIndexesEveryNumberedRow() async throws {
        let root = try makeProjectLocalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InMemoryLibraryStore()
        let service = FullTextService(store: store, cacheDirectory: root, downloader: AppFixtureFullTextDownloader())
        let paper = Paper(literatureID: 26_081_234_6,
                          titles: [PaperTitle(value: "Grouped equation fixture", source: "fixture")], abstracts: [],
                          preprintDate: nil, earliestDate: nil, arxivID: "2608.12346", arxivCategories: ["hep-lat"],
                          doi: nil, citationCount: nil, publicationStatus: nil, updated: nil, figures: [],
                          firstSeenAt: Date(), isRead: false)
        let document = try await service.downloadAndExtract(
            paperID: paper.literatureID,
            sourceURL: try XCTUnwrap(URL(string: "https://ar5iv.labs.arxiv.org/html/2608.12346")),
            sourceKind: .arxivHTML
        )
        let snapshot = await store.snapshot()
        let formulas = snapshot.evidenceChunks.values.filter { $0.paperID == paper.literatureID && $0.equationID != nil }
            .sorted { ($0.equationOrdinal ?? 0) < ($1.equationOrdinal ?? 0) }
        XCTAssertEqual(formulas.map(\.equationLabel), ["(4a)", "(4b)"])
        XCTAssertEqual(formulas.map(\.equationTeX), ["G_1 = C_2/C_0", "G_2 = C_3/C_0"])
        XCTAssertEqual(document.numberedEquationCount, 2)
        XCTAssertEqual(document.numberedEquationIndexComplete, true)
        XCTAssertNil(document.numberedEquationIndexFailure)
        XCTAssertTrue(EvidenceInputPayload(paper: paper, document: document, chunks: Array(snapshot.evidenceChunks.values),
                                            anchors: Array(snapshot.evidenceAnchors.values)).numberedEquationCoverageComplete)
    }

    func testArxivIndexRefusesVisibleNumberWithoutTeXInsteadOfGeneratingPartialCoverage() async throws {
        let root = try makeProjectLocalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InMemoryLibraryStore()
        let service = FullTextService(store: store, cacheDirectory: root, downloader: AppFixtureFullTextDownloader())
        let paper = Paper(literatureID: 26_081_234_7,
                          titles: [PaperTitle(value: "Incomplete equation fixture", source: "fixture")], abstracts: [],
                          preprintDate: nil, earliestDate: nil, arxivID: "2608.12347", arxivCategories: ["hep-lat"],
                          doi: nil, citationCount: nil, publicationStatus: nil, updated: nil, figures: [],
                          firstSeenAt: Date(), isRead: false)
        let document = try await service.downloadAndExtract(
            paperID: paper.literatureID,
            sourceURL: try XCTUnwrap(URL(string: "https://ar5iv.labs.arxiv.org/html/2608.12347")),
            sourceKind: .arxivHTML
        )
        let snapshot = await store.snapshot()
        let payload = EvidenceInputPayload(paper: paper, document: document, chunks: Array(snapshot.evidenceChunks.values),
                                           anchors: Array(snapshot.evidenceAnchors.values))
        XCTAssertEqual(document.numberedEquationCount, 1)
        XCTAssertEqual(document.numberedEquationIndexComplete, false)
        XCTAssertTrue(document.numberedEquationIndexFailure?.contains("2 条带编号公式") == true)
        XCTAssertFalse(payload.numberedEquationCoverageComplete)
        XCTAssertTrue(payload.numberedEquationCoverageFailure?.contains("不会生成部分覆盖") == true)
    }

    func testMetadataAnchorsAreDeterministicAndSurviveFullTextDeletion() async throws {
        var paper = fixturePaper()
        paper.figures = [PaperFigure(key: "fig1", url: URL(string: "https://example.test/fig1.png"), label: "Figure 1",
                                     caption: "A synthetic caption.", source: "fixture", filename: "fig1.png")]
        let metadata = EvidenceAnchorFactory.metadataAnchors(for: paper)
        XCTAssertEqual(metadata, EvidenceAnchorFactory.metadataAnchors(for: paper))
        XCTAssertEqual(Set(metadata.map(\.sourceKind)), [.abstract, .caption])

        let store = InMemoryLibraryStore()
        try await store.saveEvidenceAnchors(metadata)
        let document = fixtureDocument()
        let chunk = fixtureChunk(document: document)
        let pdfAnchor = fixturePDFAnchor(chunk: chunk)
        try await store.saveFullText(document: document, chunks: [chunk], anchors: [pdfAnchor])
        try await store.deleteFullText(documentID: document.id)
        let remaining = await store.snapshot().evidenceAnchors.values
        XCTAssertEqual(Set(remaining.map(\.sourceKind)), [.abstract, .caption])
    }

    func testChunkRangesRetainRepeatedFragmentOffsets() {
        let source = String(repeating: "repeat fragment. ", count: 400)
        let ranges = FullTextService.chunkRanges(source)
        XCTAssertGreaterThan(ranges.count, 1)
        XCTAssertEqual(ranges.first?.start, 0)
        for (left, right) in zip(ranges, ranges.dropFirst()) {
            XCTAssertLessThanOrEqual(left.end, right.start)
            XCTAssertEqual(String(source.dropFirst(left.start).prefix(left.end - left.start)), left.text)
        }
    }

    func testEvidenceValidatorDropsWellFormedUnanchoredClaimsAndFailsClosedForMalformedEvidenceIDs() throws {
        let source = makeEvidencePayload()
        let valid = validInsightJSON(anchorID: source.anchors[0].id)
        XCTAssertNoThrow(try PaperInsightV2Validator.decode(Data(valid.utf8), source: source, maximumFigures: 0))
        let unanchored = valid.replacingOccurrences(of: source.anchors[0].id, with: "pdf:p9:q9:outside")
        let normalized = try PaperInsightV2Validator.decode(Data(unanchored.utf8), source: source, maximumFigures: 0)
        XCTAssertEqual(normalized.physics.researchQuestion.epistemicStatus, .missing)
        XCTAssertTrue(normalized.physics.mainResults.isEmpty)
        XCTAssertTrue(normalized.physics.missingInformation.contains { $0.textZH.contains("已丢弃且未作为论文结论保存") })

        let anchoredIDs = "\"evidence_ids\":[\"\(source.anchors[0].id)\"]"
        let malformedEvidenceIDs = valid.replacingOccurrences(of: anchoredIDs, with: "\"evidence_ids\":[42]")
        XCTAssertThrowsError(try PaperInsightV2Validator.decode(Data(malformedEvidenceIDs.utf8), source: source, maximumFigures: 0))
        let missingWithAnchor = valid.replacingOccurrences(of: "\"missing_information\":[{\"text_zh\":\"缺少体积\",\"epistemic_status\":\"missing\",\"evidence_ids\":[]}]", with: "\"missing_information\":[{\"text_zh\":\"缺少体积\",\"epistemic_status\":\"missing\",\"evidence_ids\":[\"\(source.anchors[0].id)\"]}]")
        XCTAssertThrowsError(try PaperInsightV2Validator.decode(Data(missingWithAnchor.utf8), source: source, maximumFigures: 0))
    }

    func testLegacyEvidenceClaimMissingIDDecodesDeterministicallyAndPreservesExplicitID() throws {
        let legacyClaim = #"{"text_zh":"原文给出方程。","epistemic_status":"direct","evidence_ids":["anchor:1"]}"#
        let payload = Data(legacyClaim.utf8)
        let first = try JSONDecoder().decode(EvidenceClaim.self, from: payload)
        let second = try JSONDecoder().decode(EvidenceClaim.self, from: payload)
        XCTAssertEqual(first.id, second.id)

        let duplicateClaimsPayload = Data("[\(legacyClaim),\(legacyClaim)]".utf8)
        let duplicates = try JSONDecoder().decode([EvidenceClaim].self, from: duplicateClaimsPayload)
        let repeatedDuplicates = try JSONDecoder().decode([EvidenceClaim].self, from: duplicateClaimsPayload)
        XCTAssertEqual(duplicates.map(\.id), repeatedDuplicates.map(\.id))
        XCTAssertNotEqual(duplicates[0].id, duplicates[1].id,
                          "identical legacy claims at distinct array positions need distinct stable identities")

        let explicitID = try XCTUnwrap(UUID(uuidString: "8D8C76B1-2AF6-4EC2-996D-6EA1542CB411"))
        let explicitPayload = Data(#"{"id":"8D8C76B1-2AF6-4EC2-996D-6EA1542CB411","text_zh":"原文给出方程。","epistemic_status":"direct","evidence_ids":["anchor:1"]}"#.utf8)
        let explicitlyIdentified = try JSONDecoder().decode(EvidenceClaim.self, from: explicitPayload)
        XCTAssertEqual(explicitlyIdentified.id, explicitID)
    }

    func testEvidenceValidatorPermitsOnlyExplicitEmptyAbstractSentinelAndRepairsBareTeXCommandEscapes() throws {
        let source = makeEvidencePayload()
        let valid = validInsightJSON(anchorID: source.anchors[0].id)
        let noSourceAbstract = valid.replacingOccurrences(of: #""abstract_zh":"受限摘要""#, with: #""abstract_zh":"""#)
        let insight = try PaperInsightV2Validator.decode(Data(noSourceAbstract.utf8), source: source, maximumFigures: 0)
        XCTAssertEqual(insight.abstractZH, "")

        let whitespaceAbstract = valid.replacingOccurrences(of: #""abstract_zh":"受限摘要""#, with: #""abstract_zh":"   ""#)
        XCTAssertThrowsError(try PaperInsightV2Validator.decode(Data(whitespaceAbstract.utf8), source: source, maximumFigures: 0))

        // This is intentionally invalid JSON as emitted by a model that
        // writes TeX's command marker directly.  The Evidence-only
        // normalizer must preserve it as a literal backslash after decoding.
        let bareTeXCommand = valid.replacingOccurrences(of: "受限摘要", with: #"\alpha 受限摘要"#)
        let repaired = try PaperInsightV2Validator.decode(Data(bareTeXCommand.utf8), source: source, maximumFigures: 0)
        XCTAssertEqual(repaired.abstractZH, #"\alpha 受限摘要"#)

        // `\\u` remains strict JSON syntax: a malformed unicode escape must
        // not be reclassified as a TeX command and accepted.
        let malformedUnicodeEscape = valid.replacingOccurrences(of: "受限摘要", with: #"\u12"#)
        XCTAssertThrowsError(try PaperInsightV2Validator.decode(Data(malformedUnicodeEscape.utf8), source: source, maximumFigures: 0))

        // A missing object-member comma remains invalid. The compatibility
        // path is limited to two already-complete values in an array and must
        // not become a general JSON repairer.
        let missingObjectComma = valid.replacingOccurrences(
            of: #""title_zh":"格点测试","abstract_zh":"受限摘要""#,
            with: #""title_zh":"格点测试" "abstract_zh":"受限摘要""#
        )
        XCTAssertThrowsError(try PaperInsightV2Validator.decode(Data(missingObjectComma.utf8), source: source, maximumFigures: 0))
    }

    func testEvidenceValidatorDropsLegacyUnanchoredResearchQuestionStringInsteadOfPromotingIt() throws {
        let source = makeEvidencePayload()
        let valid = validInsightJSON(anchorID: source.anchors[0].id)
        let fieldStart = try XCTUnwrap(valid.range(of: "\"research_question\":"))
        let nextField = try XCTUnwrap(valid.range(of: ",\"method_and_data_flow\":", range: fieldStart.upperBound..<valid.endIndex))
        let legacy = valid.replacingCharacters(in: fieldStart.lowerBound..<nextField.lowerBound,
                                               with: "\"research_question\":\"模型未附 evidence anchor 的研究问题\"")

        let insight = try PaperInsightV2Validator.decode(Data(legacy.utf8), source: source, maximumFigures: 0)
        XCTAssertEqual(insight.physics.researchQuestion.epistemicStatus, .missing)
        XCTAssertEqual(insight.physics.researchQuestion.evidenceIDs, [])
        XCTAssertEqual(insight.physics.researchQuestion.textZH, "模型未将研究问题返回为可回查的当前证据；未采纳未锚定的原始文本。")
        XCTAssertFalse(insight.physics.researchQuestion.textZH.contains("模型未附 evidence anchor"),
                       "未锚定的 provider 文本不得作为可持久化物理结论进入 artifact")
    }

    func testEvidenceValidatorIgnoresGatewayMetadataAndUnwrapsOneKnownEnvelope() throws {
        let source = makeEvidencePayload()
        let valid = validInsightJSON(anchorID: source.anchors[0].id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let withRootMetadata = String(valid.dropLast()) + #","provider_trace":{"request_id":"opaque"}}"#
        XCTAssertNoThrow(try PaperInsightV2Validator.decode(
            Data(withRootMetadata.utf8), source: source, maximumFigures: 0
        ), "未持久化的 provider 元数据不应掩盖已完成的 anchor-bound response")

        let wrapped = #"{"request_id":"opaque","result":\#(valid)}"#
        XCTAssertNoThrow(try PaperInsightV2Validator.decode(
            Data(wrapped.utf8), source: source, maximumFigures: 0
        ), "应能从唯一的 OpenAI-compatible result envelope 取出完整 schema")

        let missingScope = valid.replacingOccurrences(of: #""source_scope":"fulltext_with_anchors","#, with: "")
        XCTAssertThrowsError(try PaperInsightV2Validator.decode(
            Data(missingScope.utf8), source: source, maximumFigures: 0
        ), "兼容解析仍不得接受缺少 source scope 的资料")
    }

    func testEvidenceValidatorRejectsCrossPaperAndCrossDocumentPayloadAnchors() throws {
        let source = makeEvidencePayload()
        let original = try XCTUnwrap(source.anchors.first)
        let crossPaper = EvidenceAnchor(id: original.id, paperID: original.paperID + 1, sourceKind: original.sourceKind,
                                        page: original.page, section: original.section, quote: original.quote,
                                        quoteHash: original.quoteHash, figureKey: original.figureKey)
        let malformedPaper = EvidenceInputPayload(paper: fixturePaper(), document: fixtureDocument(), chunks: source.chunks, anchors: [crossPaper])
        XCTAssertThrowsError(try PaperInsightV2Validator.decode(Data(validInsightJSON(anchorID: crossPaper.id).utf8), source: malformedPaper, maximumFigures: 0))

        let otherDocumentChunk = EvidenceChunk(id: original.id, paperID: fixturePaper().literatureID, documentHash: "other-document",
                                               page: 1, section: "Results", characterRangeStart: 0, characterRangeEnd: original.quote.count,
                                               text: original.quote, textHash: original.quoteHash)
        let malformedDocument = EvidenceInputPayload(paper: fixturePaper(), document: fixtureDocument(), chunks: [otherDocumentChunk], anchors: [original])
        XCTAssertTrue(malformedDocument.chunks.isEmpty)
        XCTAssertTrue(malformedDocument.anchors.isEmpty,
                      "构造受限 payload 时必须在模型边界之前排除跨 document chunk/anchor。")
    }

    func testEvidenceWorkflowValidatesSavesAndHitsIsolatedCache() async throws {
        let paper = fixturePaper()
        let store = InMemoryLibraryStore()
        _ = try await store.upsert(papers: [paper], for: 21)
        let document = fixtureNumberedDocument()
        let chunk = fixtureNumberedChunk(document: document)
        let htmlAnchor = fixtureHTMLAnchor(chunk: chunk)
        try await store.saveFullText(document: document, chunks: [chunk], anchors: [htmlAnchor])
        try await store.saveEvidenceAnchors(EvidenceAnchorFactory.metadataAnchors(for: paper))
        let source = EvidenceInputPayload(paper: paper, document: document, chunks: [chunk],
                                          anchors: [htmlAnchor] + EvidenceAnchorFactory.metadataAnchors(for: paper))
        let proseResponse = validNumberedInsightJSON(source: source.proseOnly())
        let formulaSource = try source.batch(for: source.numberedEquations.map(\.equationID), index: 0, total: 1)
        let formulaResponse = validNumberedInsightJSON(source: formulaSource)
        let client = EvidenceMockClient(responses: [proseResponse, formulaResponse])
        let workflow = EvidenceInsightWorkflow(store: store, client: client)
        let settings = LLMSettings(
            profiles: ["openAI": ProviderProfile(baseURL: "https://example.test/v1", selectedModel: "fixture", usesStreaming: false)],
            automaticAnalysis: false,
            mode: .fast,
            detailLevel: .standard,
            maximumFigures: 0
        )
        let first = try await workflow.generate(for: paper, settings: settings, apiKey: "fixture") { _ in }
        let second = try await workflow.generate(for: paper, settings: settings, apiKey: "fixture") { _ in }
        XCTAssertEqual(first, second)
        let requestCount = await client.requestCount()
        let saved = await store.snapshot().evidenceInsights[first.cacheKey]
        XCTAssertEqual(requestCount, 2, "prose analysis and the separately validated formula batch are distinct bounded requests")
        XCTAssertEqual(saved, first)

        let changed = EvidenceInsightCacheKey(paperID: paper.literatureID, paperUpdated: paper.updated, documentHash: document.sha256,
                                              chunkIDs: [chunk.id], promptVersion: EvidenceInsightPrompt.version,
                                              schemaVersion: PaperInsightV2Validator.schemaVersion, sourceScope: PaperInsightV2Validator.sourceScope,
                                              provider: "openAI", normalizedBaseURL: "https://example.test/v1", model: "fixture", credentialRevision: 0,
                                              mode: .fast, detailLevel: .standard, maxOutputTokens: ProviderProfile.defaultMaximumOutputTokens,
                                              maximumFigures: 3, terminologyHash: StableHash.sha256(""),
                                              providerCapabilityHash: StableHash.sha256("stream=false|vision=false"))
        XCTAssertNotEqual(first.cacheKey, changed.value)
    }

    func testEvidenceArtifactSaveFailurePublishesCompletedFormulaJobWithoutProviderRetry() async throws {
        let paper = fixturePaper()
        let store = InMemoryLibraryStore()
        _ = try await store.upsert(papers: [paper], for: 21)
        let document = fixtureNumberedDocument()
        let chunk = fixtureNumberedChunk(document: document)
        let anchor = fixtureHTMLAnchor(chunk: chunk)
        try await store.saveFullText(document: document, chunks: [chunk], anchors: [anchor])
        try await store.saveEvidenceAnchors(EvidenceAnchorFactory.metadataAnchors(for: paper))
        let source = EvidenceInputPayload(paper: paper, document: document, chunks: [chunk],
            anchors: [anchor] + EvidenceAnchorFactory.metadataAnchors(for: paper))
        let prose = validNumberedInsightJSON(source: source.proseOnly())
        let formulaSource = try source.batch(for: source.numberedEquations.map(\.equationID), index: 0, total: 1)
        let formula = validNumberedInsightJSON(source: formulaSource)
        let jobs = InMemoryFormulaJobStore()
        let firstClient = EvidenceMockClient(responses: [prose, formula])
        await store.failNextEvidenceInsightSave()
        let firstWorkflow = EvidenceInsightWorkflow(
            store: store, client: firstClient, formulaJobs: jobs
        )

        do {
            _ = try await firstWorkflow.generate(
                for: paper, settings: fixtureEvidenceSettings(), apiKey: "fixture"
            ) { _ in }
            XCTFail("the injected final artifact write failure must be surfaced")
        } catch let error as LatticeLensError {
            guard case .persistenceUnavailable = error else {
                return XCTFail("unexpected first-run error: \(error)")
            }
        }

        let firstRequestCount = await firstClient.requestCount()
        let failedSnapshot = await store.snapshot()
        XCTAssertEqual(firstRequestCount, 2, "the first run sends one prose and one formula request")
        XCTAssertTrue(failedSnapshot.evidenceInsights.isEmpty,
                      "the failed final write must not appear as a published artifact")
        let savedPublications = await jobs.readyEvidenceInsightPublicationsForTesting()
        let readyPublication = try XCTUnwrap(savedPublications.first)
        XCTAssertEqual(savedPublications.count, 1,
                       "the completed artifact must be durably staged before the normal artifact write")

        let staleContext = EvidenceInsightPublicationContext(
            cacheKey: readyPublication.context.cacheKey,
            paperID: readyPublication.context.paperID,
            documentHash: readyPublication.context.documentHash,
            inventoryHash: readyPublication.context.inventoryHash,
            sourcePayloadHash: readyPublication.context.sourcePayloadHash,
            provider: readyPublication.context.provider,
            providerProfileFingerprint: "different-profile-fingerprint",
            modelID: readyPublication.context.modelID,
            promptVersion: readyPublication.context.promptVersion,
            schemaVersion: readyPublication.context.schemaVersion,
            sourceScope: readyPublication.context.sourceScope
        )
        try await jobs.saveReadyEvidenceInsightPublication(
            ReadyEvidenceInsightPublication(context: staleContext, artifact: readyPublication.artifact)
        )
        let staleContextClient = EvidenceMockClient(responses: [])
        let staleContextWorkflow = EvidenceInsightWorkflow(
            store: store, client: staleContextClient, formulaJobs: jobs
        )
        do {
            _ = try await staleContextWorkflow.generate(
                for: paper, settings: fixtureEvidenceSettings(), apiKey: "fixture"
            ) { _ in }
            XCTFail("a ready publication from another provider profile must fail closed")
        } catch let error as LatticeLensError {
            guard case .schemaViolation = error else {
                return XCTFail("unexpected stale-publication error: \(error)")
            }
        }
        let staleRequestCount = await staleContextClient.requestCount()
        XCTAssertEqual(staleRequestCount, 0, "a context mismatch must not fall through to provider generation")
        try await jobs.saveReadyEvidenceInsightPublication(readyPublication)

        let retryClient = EvidenceMockClient(responses: [])
        let resumedWorkflow = EvidenceInsightWorkflow(
            store: store, client: retryClient, formulaJobs: jobs
        )
        let published: EvidenceInsightArtifact
        do {
            published = try await resumedWorkflow.generate(
                for: paper, settings: fixtureEvidenceSettings(), apiKey: "fixture"
            ) { _ in }
        } catch {
            let retryRequestCount = await retryClient.requestCount()
            XCTFail("expected persisted ready-to-publish artifact, got \(error) after \(retryRequestCount) provider request(s)")
            return
        }
        let retryRequestCount = await retryClient.requestCount()
        let saved = await store.snapshot().evidenceInsights[published.cacheKey]
        XCTAssertEqual(retryRequestCount, 0,
                       "a ready-to-publish artifact must be committed after relaunch without another provider POST")
        XCTAssertEqual(saved, published)
        let remainingPublications = await jobs.readyEvidenceInsightPublicationsForTesting()
        XCTAssertTrue(remainingPublications.isEmpty, "a published artifact must retire its pending AnalysisRun")
    }

    func testFormulaBatchWorkflowPersistsSuccessfulBatchesAndResumesOnlyPending() async throws {
        let root = try makeProjectLocalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = InMemoryLibraryStore()
        let service = FullTextService(store: library, cacheDirectory: root, downloader: AppFixtureFullTextDownloader())
        let paper = Paper(literatureID: 260812348, titles: [PaperTitle(value: "Resume formula fixture", source: "fixture")],
                          abstracts: [], preprintDate: nil, earliestDate: nil, arxivID: "2608.12345",
                          arxivCategories: ["hep-lat"], doi: nil, citationCount: nil, publicationStatus: nil,
                          updated: nil, figures: [], firstSeenAt: Date(), isRead: false)
        let document = try await service.downloadAndExtract(paperID: paper.literatureID,
            sourceURL: try XCTUnwrap(URL(string: "https://ar5iv.labs.arxiv.org/html/2608.12345")), sourceKind: .arxivHTML)
        let snapshot = await library.snapshot()
        let chunks = snapshot.evidenceChunks.values.filter { $0.paperID == paper.literatureID }.sorted { ($0.equationOrdinal ?? 0) < ($1.equationOrdinal ?? 0) }
        let anchors = snapshot.evidenceAnchors.values.filter { $0.paperID == paper.literatureID }
        let source = EvidenceInputPayload(paper: paper, document: document, chunks: chunks, anchors: anchors)
        XCTAssertEqual(source.numberedEquations.count, 3)

        let jobID = "formula-resume-fixture"
        let profile = ProviderProfile(provider: .deepSeek, baseURL: "https://fixture.invalid/v1",
                                      selectedModel: "fixture", usesStreaming: false)
        let batches = try FormulaBatchPlanner.plan(source: source, jobID: jobID, batchSize: 1, profile: profile)
        for batch in batches {
            let batchSource = try source.batch(for: batch.equationIDs, index: batch.index, total: batch.total)
            let userPayload = try FormulaDerivationPrompt.userPayload(source: batchSource)
            let requestBody = FormulaBatchRequestBodyFixture(
                system: FormulaDerivationPrompt.systemInstruction, userPayload: userPayload, profile: profile
            )
            let serializedRequest = try requestBody.encoded()
            let productionRequest = try OpenAICompatibleCompletionRequestBody(
                system: FormulaDerivationPrompt.systemInstruction, userPayload: userPayload, profile: profile
            ).encoded()
            XCTAssertEqual(productionRequest, serializedRequest,
                           "planner fixture bytes must match the HTTP client's canonical request body")
            XCTAssertEqual(try OpenAICompatibleCompletionRequestBody(
                system: FormulaDerivationPrompt.systemInstruction, userPayload: userPayload, profile: profile
            ).encoded(), productionRequest, "repeated request encoding must be byte-deterministic")
            XCTAssertEqual(batch.payloadHash, StableHash.sha256(serializedRequest),
                           "a resumable batch identity must hash the exact system/user/model request body")
            XCTAssertEqual(batch.estimatedBytes, serializedRequest.count)
            XCTAssertEqual(batch.estimatedScalars,
                           String(decoding: serializedRequest, as: UTF8.self).unicodeScalars.count)
            XCTAssertEqual(batch.estimatedTokens, serializedRequest.count,
                           "the byte-count token estimate is deliberately conservative")
        }
        let singleFormulaByteLimit = try XCTUnwrap(batches.map(\.estimatedBytes).max())
        let allFormulaSource = try source.batch(
            for: source.numberedEquations.map(\.equationID), index: 0, total: 1
        )
        let allFormulaPayload = try FormulaDerivationPrompt.userPayload(source: allFormulaSource)
        let allFormulaBody = try FormulaBatchRequestBodyFixture(
            system: FormulaDerivationPrompt.systemInstruction, userPayload: allFormulaPayload, profile: profile
        ).encoded()
        XCTAssertGreaterThan(allFormulaBody.count, singleFormulaByteLimit,
                             "fixture must force splitting on the serialized request envelope")
        let envelopeBoundedBatches = try FormulaBatchPlanner.plan(
            source: source, jobID: "formula-envelope-split", batchSize: source.numberedEquations.count,
            profile: profile, maximumPayloadBytes: singleFormulaByteLimit,
            maximumPayloadTokens: singleFormulaByteLimit
        )
        XCTAssertGreaterThan(envelopeBoundedBatches.count, 1)
        XCTAssertEqual(envelopeBoundedBatches.flatMap(\.equationIDs), source.numberedEquations.map(\.equationID))
        XCTAssertTrue(envelopeBoundedBatches.allSatisfy {
            $0.estimatedBytes <= singleFormulaByteLimit && $0.estimatedTokens <= singleFormulaByteLimit
        })
        let responses = try batches.map { batch in
            validNumberedInsightJSON(source: try source.batch(for: batch.equationIDs, index: batch.index, total: batch.total))
        }
        let checkpoints = InMemoryFormulaJobStore()
        let firstClient = EvidenceMockClient(responses: [responses[0], "not-json"])
        let firstWorkflow = FormulaDerivationWorkflow(client: firstClient, store: checkpoints)
        do {
            _ = try await firstWorkflow.run(source: source, profile: profile, apiKey: "fixture", jobID: jobID, batchSize: 1)
            XCTFail("the malformed second batch must not yield a complete artifact")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        let storedAfterFailure = await checkpoints.formulaJob(id: jobID)
        let paused = try XCTUnwrap(storedAfterFailure)
        XCTAssertEqual(paused.job.batches.map(\.status), [.completed, .retryable, .prepared])
        XCTAssertEqual(paused.completedClaimsByBatch[0]?.count, 1)
        XCTAssertEqual(paused.job.batches.map(\.payloadHash), batches.map(\.payloadHash),
                       "the typed durable checkpoint must retain the exact frozen request-body digests")

        let resumedClient = EvidenceMockClient(responses: Array(responses.dropFirst()))
        let resumedWorkflow = FormulaDerivationWorkflow(client: resumedClient, store: checkpoints)
        let result = try await resumedWorkflow.run(source: source, profile: profile, apiKey: "fixture", jobID: jobID, batchSize: 1)
        XCTAssertEqual(result.job.state, .complete)
        XCTAssertEqual(result.coverage.inventoryIDs.count, 3)
        XCTAssertTrue(result.coverage.isComplete)
        XCTAssertEqual(result.job.batches.map(\.attemptCount), [1, 2, 1])
        XCTAssertEqual(result.attemptedRequestsThisRun, 2)
        XCTAssertEqual(result.reusedValidatedBatches, 1)
        let resumedRequestCount = await resumedClient.requestCount()
        XCTAssertEqual(resumedRequestCount, 2, "completed batch zero must not be resent after resume")

        let cacheClient = EvidenceMockClient(responses: [])
        let cacheWorkflow = FormulaDerivationWorkflow(client: cacheClient, store: checkpoints)
        let cachedResult = try await cacheWorkflow.run(source: source, profile: profile, apiKey: "fixture",
                                                       jobID: jobID, batchSize: 1)
        XCTAssertEqual(cachedResult.job.state, .complete)
        XCTAssertEqual(cachedResult.coverage, result.coverage)
        XCTAssertEqual(cachedResult.attemptedRequestsThisRun, 0)
        XCTAssertEqual(cachedResult.reusedValidatedBatches, 3)
        let cacheRequestCount = await cacheClient.requestCount()
        XCTAssertEqual(cacheRequestCount, 0, "a completed checkpoint must be revalidated and reused without another POST")

        // A process can stop after persisting the validating state but before
        // the final coverage report is committed. Validated batches must be
        // rechecked and published after relaunch without another provider POST.
        let storedCompleteCheckpoint = await checkpoints.formulaJob(id: jobID)
        var interruptedValidation = try XCTUnwrap(storedCompleteCheckpoint)
        interruptedValidation.job.state = .validating
        await checkpoints.saveFormulaJob(interruptedValidation)
        let finalizeClient = EvidenceMockClient(responses: [])
        let finalizeWorkflow = FormulaDerivationWorkflow(client: finalizeClient, store: checkpoints)
        let finalizedAfterValidationRestart = try await finalizeWorkflow.run(
            source: source, profile: profile, apiKey: "fixture", jobID: jobID, batchSize: 1
        )
        XCTAssertEqual(finalizedAfterValidationRestart.job.state, .complete)
        XCTAssertEqual(finalizedAfterValidationRestart.reusedValidatedBatches, 3)
        let finalizeRequestCount = await finalizeClient.requestCount()
        XCTAssertEqual(finalizeRequestCount, 0,
                       "relaunch from validating must not resend already validated formula batches")

        let storedDamagedCheckpoint = await checkpoints.formulaJob(id: jobID)
        var damagedCheckpoint = try XCTUnwrap(storedDamagedCheckpoint)
        let originalClaim = try XCTUnwrap(damagedCheckpoint.completedClaimsByBatch[0]?.first)
        damagedCheckpoint.completedClaimsByBatch[0] = [EvidenceClaim(
            id: originalClaim.id,
            textZH: originalClaim.textZH,
            epistemicStatus: originalClaim.epistemicStatus,
            evidenceIDs: originalClaim.evidenceIDs,
            formulaTeX: "x = corrupted",
            equationID: originalClaim.equationID,
            derivationSteps: originalClaim.derivationSteps,
            formulaDerivationSteps: originalClaim.formulaDerivationSteps,
            conclusionZH: originalClaim.conclusionZH
        )]
        await checkpoints.saveFormulaJob(damagedCheckpoint)

        let tamperClient = EvidenceMockClient(responses: [])
        let tamperWorkflow = FormulaDerivationWorkflow(client: tamperClient, store: checkpoints)
        do {
            _ = try await tamperWorkflow.run(source: source, profile: profile, apiKey: "fixture", jobID: jobID, batchSize: 1)
            XCTFail("a damaged completed checkpoint must be rejected before reuse")
        } catch FormulaDerivationWorkflowError.staleCheckpoint {
            // Corrupt persisted claims are not a valid reason to issue a hidden retry.
        } catch {
            XCTFail("unexpected damaged-checkpoint failure: \(error)")
        }
        let tamperRequestCount = await tamperClient.requestCount()
        XCTAssertEqual(tamperRequestCount, 0, "checkpoint corruption must be detected before sending another POST")

        do {
            _ = try await cacheWorkflow.run(source: source,
                profile: ProviderProfile(baseURL: "https://fixture.invalid/v1", selectedModel: "different-model", usesStreaming: false),
                apiKey: "fixture", jobID: jobID, batchSize: 1)
            XCTFail("a checkpoint cannot be reused under a different provider model")
        } catch FormulaDerivationWorkflowError.staleCheckpoint {
            // The caller must use a new context-bound job ID for changed settings.
        } catch {
            XCTFail("unexpected checkpoint failure: \(error)")
        }
    }

    func testFormulaJobCanOutlastFinitePerRequestDeadlineAcrossBatches() async throws {
        let root = try makeProjectLocalTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = InMemoryLibraryStore()
        let service = FullTextService(store: library, cacheDirectory: root, downloader: AppFixtureFullTextDownloader())
        let paper = Paper(literatureID: 260812349, titles: [PaperTitle(value: "Finite request fixture", source: "fixture")],
                          abstracts: [], preprintDate: nil, earliestDate: nil, arxivID: "2608.12346",
                          arxivCategories: ["hep-lat"], doi: nil, citationCount: nil, publicationStatus: nil,
                          updated: nil, figures: [], firstSeenAt: Date(), isRead: false)
        let document = try await service.downloadAndExtract(
            paperID: paper.literatureID,
            sourceURL: try XCTUnwrap(URL(string: "https://ar5iv.labs.arxiv.org/html/2608.12346")),
            sourceKind: .arxivHTML
        )
        let snapshot = await library.snapshot()
        let chunks = snapshot.evidenceChunks.values.filter { $0.paperID == paper.literatureID }
        let anchors = snapshot.evidenceAnchors.values.filter { $0.paperID == paper.literatureID }
        let source = EvidenceInputPayload(paper: paper, document: document, chunks: Array(chunks), anchors: Array(anchors))
        let jobID = "finite-request-multi-batch-job"
        let profile = ProviderProfile(baseURL: "https://fixture.invalid/v1", selectedModel: "fixture", usesStreaming: false)
        let batches = try FormulaBatchPlanner.plan(source: source, jobID: jobID, batchSize: 1, profile: profile)
        let responses = try batches.map { batch in
            validNumberedInsightJSON(source: try source.batch(for: batch.equationIDs, index: batch.index, total: batch.total))
        }
        XCTAssertEqual(batches.count, 2)

        let requestBudget = V4AnalysisTimeouts(connect: 1, firstContent: 1.2, idle: 1.2, hard: 1.5)
        let client = EvidenceMockClient(responses: responses, responseDelay: .milliseconds(900))
        let workflow = FormulaDerivationWorkflow(client: client, store: InMemoryFormulaJobStore(), timeouts: requestBudget)
        let startedAt = Date()
        let result = try await workflow.run(source: source,
            profile: profile,
            apiKey: "fixture", jobID: jobID, batchSize: 1)
        let elapsed = Date().timeIntervalSince(startedAt)
        let requestCount = await client.requestCount()

        XCTAssertGreaterThan(elapsed, requestBudget.hard, "the formula job has no aggregate timeout across validated batches")
        XCTAssertEqual(requestCount, batches.count)
        XCTAssertEqual(result.job.state, .complete)
        XCTAssertTrue(result.coverage.isComplete)
    }

    func testDurableFormulaJobIdentityIsStableAcrossRelaunchAndVersionScoped() {
        let profile = ProviderProfile(provider: .openAI, baseURL: "https://fixture.invalid/v1",
                                      selectedModel: "fixture", usesStreaming: false)
        let expectedFingerprint = StableHash.sha256([
            profile.provider.rawValue, "https://fixture.invalid/v1", profile.effectiveModel,
            String(profile.usesStreaming), String(profile.supportsVision),
            String(profile.maxOutputTokens),
            String(profile.discoveryCredentialRevision),
            OpenAICompatibleCompletionRequestBody.serializationContractVersion, "fixture-settings"
        ].joined(separator: "|"))
        XCTAssertEqual(FormulaDerivationWorkflow.executionFingerprint(profile: profile,
                                                                      settingsFingerprint: "fixture-settings"),
                       expectedFingerprint,
                       "durable formula identities must version the canonical request-byte contract")

        let first = FormulaDerivationWorkflow.durableJobID(
            paperID: 42, documentHash: "document", inventoryHash: "inventory",
            promptVersion: "prompt-v1", schemaVersion: "schema-v1", executionFingerprint: "profile-a"
        )
        let relaunched = FormulaDerivationWorkflow.durableJobID(
            paperID: 42, documentHash: "document", inventoryHash: "inventory",
            promptVersion: "prompt-v1", schemaVersion: "schema-v1", executionFingerprint: "profile-a"
        )
        let changedPrompt = FormulaDerivationWorkflow.durableJobID(
            paperID: 42, documentHash: "document", inventoryHash: "inventory",
            promptVersion: "prompt-v2", schemaVersion: "schema-v1", executionFingerprint: "profile-a"
        )
        let changedProfile = FormulaDerivationWorkflow.durableJobID(
            paperID: 42, documentHash: "document", inventoryHash: "inventory",
            promptVersion: "prompt-v1", schemaVersion: "schema-v1", executionFingerprint: "profile-b"
        )
        XCTAssertEqual(first, relaunched)
        XCTAssertNotEqual(first, changedPrompt)
        XCTAssertNotEqual(first, changedProfile)
    }

    func testValidatedFormulaBatchesCanPublishAfterReceiptSaveFailureWithoutAnotherPOST() async throws {
        let document = fixtureNumberedDocument()
        let chunk = fixtureNumberedChunk(document: document)
        let source = EvidenceInputPayload(
            paper: fixturePaper(), document: document,
            chunks: [chunk], anchors: [fixtureHTMLAnchor(chunk: chunk)]
        )
        let jobID = "formula-report-save-retry"
        let response = validNumberedInsightJSON(source: source)
        let store = FailOnceFormulaValidationStore()
        let profile = ProviderProfile(baseURL: "https://fixture.invalid/v1", selectedModel: "fixture", usesStreaming: false)

        do {
            _ = try await FormulaDerivationWorkflow(
                client: EvidenceMockClient(responses: [response]), store: store
            ).run(source: source, profile: profile, apiKey: "fixture", jobID: jobID)
            XCTFail("the injected final validation-receipt persistence failure must be surfaced")
        } catch let error as LatticeLensError {
            guard case .persistenceUnavailable = error else {
                return XCTFail("unexpected first-run error: \(error)")
            }
        }

        let interruptedValue = await store.formulaJob(id: jobID)
        let interrupted = try XCTUnwrap(interruptedValue)
        XCTAssertEqual(interrupted.job.state, .incomplete)
        XCTAssertEqual(interrupted.job.batches.map(\.status), [.completed])
        XCTAssertEqual(interrupted.completedClaimsByBatch[0]?.count, 1)
        let failedReport = await store.formulaValidationReport(jobID: jobID)
        XCTAssertNil(failedReport)

        let retryClient = EvidenceMockClient(responses: [])
        let republished = try await FormulaDerivationWorkflow(client: retryClient, store: store)
            .run(source: source, profile: profile, apiKey: "fixture", jobID: jobID)
        XCTAssertEqual(republished.job.state, .complete)
        XCTAssertTrue(republished.coverage.isComplete)
        XCTAssertEqual(republished.attemptedRequestsThisRun, 0)
        XCTAssertEqual(republished.reusedValidatedBatches, 1)
        let storedReport = await store.formulaValidationReport(jobID: jobID)
        let retryRequestCount = await retryClient.requestCount()
        XCTAssertNotNil(storedReport)
        XCTAssertEqual(retryRequestCount, 0,
                       "validated successful response must survive receipt persistence failure without another provider POST")
    }

    func testAllNumberedEquationWorkflowRejectsMissingOrAlteredFormulaWithoutSaving() async throws {
        let paper = fixturePaper()
        let document = fixtureNumberedDocument()
        let chunk = fixtureNumberedChunk(document: document)
        let anchor = fixtureHTMLAnchor(chunk: chunk)
        let source = EvidenceInputPayload(paper: paper, document: document, chunks: [chunk], anchors: [anchor])
        let incomplete = validNumberedInsightJSON(source: source, includeFormula: false)
        XCTAssertThrowsError(try PaperInsightV2Validator.decode(Data(incomplete.utf8), source: source, maximumFigures: 0)) { error in
            XCTAssertTrue(error.localizedDescription.contains("编号公式覆盖不完整"))
        }

        let altered = validNumberedInsightJSON(source: source, formulaTeX: "C(t)=A e^{-Et}")
        XCTAssertThrowsError(try PaperInsightV2Validator.decode(Data(altered.utf8), source: source, maximumFigures: 0)) { error in
            XCTAssertTrue(error.localizedDescription.contains("formula_tex"))
        }

        let store = InMemoryLibraryStore()
        _ = try await store.upsert(papers: [paper], for: 21)
        try await store.saveFullText(document: document, chunks: [chunk], anchors: [anchor])
        let missingFormula = incomplete
        let client = EvidenceMockClient(responses: [missingFormula])
        let workflow = EvidenceInsightWorkflow(store: store, client: client)
        do {
            _ = try await workflow.generate(for: paper, settings: fixtureEvidenceSettings(), apiKey: "fixture") { _ in }
            XCTFail("编号公式缺失时不得保存部分 artifact")
        } catch {}
        let afterFailure = await store.snapshot()
        XCTAssertTrue(afterFailure.evidenceInsights.isEmpty)
    }

    func testNumberedFormulaRequiresTypedStepContractInsteadOfLegacyStrings() throws {
        let paper = fixturePaper()
        let document = fixtureNumberedDocument()
        let chunk = fixtureNumberedChunk(document: document)
        let source = EvidenceInputPayload(paper: paper, document: document, chunks: [chunk],
                                          anchors: [fixtureHTMLAnchor(chunk: chunk)])
        let legacy = validNumberedInsightJSON(source: source, includeTypedSteps: false)

        XCTAssertThrowsError(
            try PaperInsightV2Validator.decode(Data(legacy.utf8), source: source, maximumFigures: 0),
            "Legacy [String] derivation_steps must not satisfy the typed v1 step contract"
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("derivation_step_contract"))
        }

        let current = validNumberedInsightJSON(source: source)
        let decoded = try PaperInsightV2Validator.decode(Data(current.utf8), source: source, maximumFigures: 0)
        let step = try XCTUnwrap(decoded.physics.importantFormulaDerivations.first?.formulaDerivationSteps.first)
        XCTAssertEqual(step.ordinal, 1)
        XCTAssertEqual(step.stepID, "\(try XCTUnwrap(source.numberedEquations.first?.equationID)):step:1")
        XCTAssertEqual(step.epistemicStatus, .inference)
        XCTAssertEqual(step.physicsReview, .needsManualPhysics,
                       "模型輸出不能把物理推導升級為人工核驗")

        let unanchoredConclusion = validNumberedInsightJSON(
            source: source, typedConclusion: "结果为 3 GeV，但当前公式来源没有给出这个数值。"
        )
        XCTAssertThrowsError(
            try PaperInsightV2Validator.decode(Data(unanchoredConclusion.utf8), source: source, maximumFigures: 0),
            "带单位的结论数值必须由当前来源 anchor 支持"
        )
        let unanchoredIntermediate = validNumberedInsightJSON(
            source: source, typedStepAfterTeX: #"E=3\,\mathrm{GeV}"#
        )
        XCTAssertThrowsError(
            try PaperInsightV2Validator.decode(Data(unanchoredIntermediate.utf8), source: source, maximumFigures: 0),
            "中间 TeX 中新增的物理数值不能绕过来源检查"
        )

        let wrongDocument = current.replacingOccurrences(of: source.documentHash, with: "stale-document-hash")
        XCTAssertThrowsError(try PaperInsightV2Validator.decode(Data(wrongDocument.utf8), source: source, maximumFigures: 0))

        let claimedDirect = validNumberedInsightJSON(source: source, typedStepStatus: "direct")
        XCTAssertThrowsError(try PaperInsightV2Validator.decode(Data(claimedDirect.utf8), source: source, maximumFigures: 0),
                             "模型生成的推导步骤不能自称为原文 direct claim")

        let equationID = try XCTUnwrap(source.numberedEquations.first?.equationID)
        let selfDependency = current.replacingOccurrences(
            of: "\"referenced_equation_ids\":[]",
            with: "\"referenced_equation_ids\":[\"\(equationID)\"]"
        )
        XCTAssertThrowsError(try PaperInsightV2Validator.decode(Data(selfDependency.utf8), source: source, maximumFigures: 0))
    }

    func testNumberedFormulaDerivationRequiresSourceBoundContinuousStepsAndConclusion() throws {
        let paper = fixturePaper()
        let document = fixtureNumberedDocument()
        let chunk = fixtureNumberedChunk(document: document)
        let source = EvidenceInputPayload(paper: paper, document: document, chunks: [chunk],
                                          anchors: [fixtureHTMLAnchor(chunk: chunk)])

        let noConclusion = validNumberedInsightJSON(source: source, includeConclusion: false)
        XCTAssertThrowsError(
            try PaperInsightV2Validator.decode(Data(noConclusion.utf8), source: source, maximumFigures: 0),
            "A numbered-formula derivation without an explicit conclusion must not be complete"
        )

        let wrongOrigin = validNumberedInsightJSON(source: source,
                                                   typedStepBeforeTeX: #"C(t)=A e^{-Et}"#)
        XCTAssertThrowsError(
            try PaperInsightV2Validator.decode(Data(wrongOrigin.utf8), source: source, maximumFigures: 0),
            "The first derivation step must begin at the immutable source equation"
        )

        let current = validNumberedInsightJSON(source: source)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any])
        var physics = try XCTUnwrap(root["physics"] as? [String: Any])
        var claims = try XCTUnwrap(physics["important_formula_derivations"] as? [[String: Any]])
        var claim = try XCTUnwrap(claims.first)
        var steps = try XCTUnwrap(claim["derivation_step_contract"] as? [[String: Any]])
        var first = try XCTUnwrap(steps.first)
        first["after_tex"] = #"C(t)=A e^{-mt}+M"#
        var second = first
        second["step_id"] = "\(source.numberedEquations[0].equationID):step:2"
        second["ordinal"] = 2
        second["text_zh"] = "继续处理同一公式，但从不相同的中间表达式开始。"
        second["before_tex"] = #"C(t)=A e^{-mt}-M"#
        second["after_tex"] = source.numberedEquations[0].tex
        second["rule_or_assumption"] = "检查中间式连续性。"
        steps = [first, second]
        claim["derivation_step_contract"] = steps
        claim["derivation_steps"] = steps.compactMap { $0["text_zh"] as? String }
        claims[0] = claim
        physics["important_formula_derivations"] = claims
        root["physics"] = physics
        let disconnectedData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])

        XCTAssertThrowsError(
            try PaperInsightV2Validator.decode(disconnectedData, source: source, maximumFigures: 0),
            "Adjacent derivation steps must share the exact intermediate TeX"
        )
    }

    func testLongFormulaDerivationUsesBoundedValidatedSegmentsAndCheckpoint() throws {
        let equationID = "eq-long-chain"
        let sourceTeX = "F_0 = 0"
        func makeSteps(startingAt ordinal: Int, count: Int, from initialTeX: String) -> [FormulaDerivationStep] {
            var before = initialTeX
            return (ordinal..<(ordinal + count)).map { value in
                let after = "F_\(value) = 0"
                defer { before = after }
                return FormulaDerivationStep(
                    stepID: "\(equationID):step:\(value)", ordinal: value,
                    textZH: "受限的形式變換步驟 \(value)。", beforeTeX: before, afterTeX: after,
                    ruleOrAssumption: "僅檢查鏈結；不主張物理正確性。",
                    evidenceAnchorIDs: ["anchor-long-chain"],
                    sourceDocumentHashes: ["document-hash"], epistemicStatus: .inference
                )
            }
        }

        let firstSegment = makeSteps(startingAt: 1, count: 32, from: sourceTeX)
        let firstEnd = try XCTUnwrap(firstSegment.last?.afterTeX)
        var checkpoint = FormulaDerivationSegmentCheckpoint(equationID: equationID, sourceTeX: sourceTeX)
        try checkpoint.appendSegment(index: 0, steps: firstSegment, isFinal: false,
                                     continuationSummary: "從上一段末式繼續。", conclusionZH: nil,
                                     requestID: "segment-request-0",
                                     requestPayloadHash: String(repeating: "a", count: 64),
                                     responseHash: String(repeating: "b", count: 64),
                                     receivedBytes: 0, receivedCharacters: 0,
                                     firstContentAt: nil, lastContentAt: nil)

        let finalSegment = makeSteps(startingAt: 33, count: 1, from: firstEnd)
        try checkpoint.appendSegment(index: 1, steps: finalSegment, isFinal: true,
                                     continuationSummary: nil, conclusionZH: "形式鏈在此結束。",
                                     requestID: "segment-request-1",
                                     requestPayloadHash: String(repeating: "c", count: 64),
                                     responseHash: String(repeating: "d", count: 64),
                                     receivedBytes: 0, receivedCharacters: 0,
                                     firstContentAt: nil, lastContentAt: nil)

        XCTAssertTrue(checkpoint.isComplete)
        XCTAssertEqual(checkpoint.completedSteps.map(\.ordinal), Array(1...33))
        XCTAssertEqual(checkpoint.segments.map(\.index), [0, 1])
        XCTAssertEqual(checkpoint.segments.map(\.requestID), ["segment-request-0", "segment-request-1"])
        let encoded = try JSONEncoder().encode(checkpoint)
        let restored = try JSONDecoder().decode(FormulaDerivationSegmentCheckpoint.self, from: encoded)
        XCTAssertEqual(restored, checkpoint, "a relaunch checkpoint must retain validated segment boundaries and hashes")
        XCTAssertEqual(try checkpoint.provenanceHash(), try restored.provenanceHash())

        var overLimit = FormulaDerivationSegmentCheckpoint(equationID: equationID, sourceTeX: sourceTeX)
        for segmentIndex in 0..<(FormulaDerivationSegmentCheckpoint.maximumSegmentsPerEquation - 1) {
            let start = segmentIndex * FormulaDerivationStep.maximumStepsPerSegment + 1
            let prior = segmentIndex == 0
                ? sourceTeX
                : "F_\(start - 1) = 0"
            try overLimit.appendSegment(
                index: segmentIndex,
                steps: makeSteps(startingAt: start,
                                 count: FormulaDerivationStep.maximumStepsPerSegment,
                                 from: prior),
                isFinal: false, continuationSummary: "bounded continuation",
                conclusionZH: nil, requestID: "segment-request-\(segmentIndex)",
                requestPayloadHash: String(repeating: "e", count: 64),
                responseHash: String(repeating: "f", count: 64),
                receivedBytes: 0, receivedCharacters: 0, firstContentAt: nil, lastContentAt: nil
            )
        }
        XCTAssertThrowsError(
            try overLimit.appendSegment(index: FormulaDerivationSegmentCheckpoint.maximumSegmentsPerEquation - 1,
                                        steps: makeSteps(startingAt: 225, count: 32, from: "F_224 = 0"),
                                        isFinal: false, continuationSummary: "尚需續寫。",
                                        conclusionZH: nil,
                                        requestID: "segment-request-overflow",
                                        requestPayloadHash: String(repeating: "1", count: 64),
                                        responseHash: String(repeating: "2", count: 64),
                                        receivedBytes: 0, receivedCharacters: 0,
                                        firstContentAt: nil, lastContentAt: nil),
            "a continuation must be explicitly rejected at the configured step/segment resource bound"
        )
    }

    func testFormulaInsightDecoderAcceptsOnlyExpectedBoundedContinuationSegment() throws {
        let document = fixtureNumberedDocument()
        let chunk = fixtureNumberedChunk(document: document)
        let source = EvidenceInputPayload(paper: fixturePaper(), document: document, chunks: [chunk],
                                          anchors: [fixtureHTMLAnchor(chunk: chunk)])
        let equation = try XCTUnwrap(source.numberedEquations.first)
        let precedingTeX = "C(t)=A"
        let partial = validNumberedInsightJSON(
            source: source, includeConclusion: false, typedStepOrdinal: 2,
            typedStepBeforeTeX: precedingTeX, typedStepAfterTeX: "C(t)=A+B",
            segmentIndex: 1, segmentIsFinal: false, continuationSummary: "繼續處理剩餘項。"
        )
        let expectation = FormulaDerivationSegmentExpectation(index: 1, startingOrdinal: 2,
                                                              precedingTeX: precedingTeX)
        let decoded = try PaperInsightV2Validator.decode(Data(partial.utf8), source: source,
            maximumFigures: 0, expectedFormulaSegments: [equation.equationID: expectation])
        XCTAssertEqual(decoded.physics.importantFormulaDerivations.first?.derivationSegment?.index, 1)
        XCTAssertNil(decoded.physics.importantFormulaDerivations.first?.conclusionZH,
                     "an intermediate segment is not a completed derivation")
        XCTAssertThrowsError(
            try PaperInsightV2Validator.decode(Data(partial.utf8), source: source, maximumFigures: 0),
            "a non-final segment must never pass as a complete formula claim"
        )
    }

    func testLongFormulaWorkflowResumesFromLastValidatedSegmentWithoutRepostingIt() async throws {
        let document = fixtureNumberedDocument()
        let chunk = fixtureNumberedChunk(document: document)
        let source = EvidenceInputPayload(paper: fixturePaper(), document: document, chunks: [chunk],
                                          anchors: [fixtureHTMLAnchor(chunk: chunk)])
        let equation = try XCTUnwrap(source.numberedEquations.first)
        let jobID = "formula-long-segment-resume"
        let profile = ProviderProfile(baseURL: "https://fixture.invalid/v1", selectedModel: "fixture", usesStreaming: false)
        let firstSegment = validNumberedInsightJSON(
            source: source, includeConclusion: false,
            segmentIsFinal: false, continuationSummary: "從同一個末式繼續。",
            typedStepCount: 32
        )
        let interruptedClient = EvidenceMockClient(responses: [firstSegment, "not-json"])
        let store = InMemoryFormulaJobStore()
        do {
            _ = try await FormulaDerivationWorkflow(client: interruptedClient, store: store)
                .run(source: source, profile: profile, apiKey: "fixture", jobID: jobID)
            XCTFail("the malformed second segment must leave an explicit resumable partial checkpoint")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        let interruptedRequests = await interruptedClient.requestCount()
        XCTAssertEqual(interruptedRequests, 2, "one initial segment and one failed continuation were attempted")
        let storedValue = await store.formulaJob(id: jobID)
        let interrupted = try XCTUnwrap(storedValue)
        XCTAssertEqual(interrupted.job.state, .retryable)
        XCTAssertEqual(interrupted.job.batches[0].status, .retryable)
        XCTAssertEqual(interrupted.job.batches[0].attemptCount, 2)
        let partialValue = interrupted.derivationSegmentsByEquation?[equation.equationID]
        let partial = try XCTUnwrap(partialValue)
        XCTAssertFalse(partial.isComplete)
        XCTAssertEqual(partial.completedSteps.count, 32)
        XCTAssertEqual(partial.segments.count, 1)

        let finalSegment = validNumberedInsightJSON(
            source: source, typedStepOrdinal: 33,
            typedStepBeforeTeX: equation.tex, typedStepAfterTeX: equation.tex,
            segmentIndex: 1, segmentIsFinal: true, typedStepCount: 1
        )
        let resumedClient = EvidenceMockClient(responses: [finalSegment])
        let result = try await FormulaDerivationWorkflow(client: resumedClient, store: store)
            .run(source: source, profile: profile, apiKey: "fixture", jobID: jobID)
        let resumedRequests = await resumedClient.requestCount()
        XCTAssertEqual(resumedRequests, 1, "resume must request only the missing segment")
        XCTAssertEqual(result.attemptedRequestsThisRun, 1)
        XCTAssertTrue(result.coverage.isComplete)
        XCTAssertEqual(result.claims.first?.formulaDerivationSteps.map { $0.ordinal }, Array(1...33))
        let completedValue = await store.formulaJob(id: jobID)
        let completed = try XCTUnwrap(completedValue)
        let completedSegments = try XCTUnwrap(completed.derivationSegmentsByEquation?[equation.equationID])
        XCTAssertTrue(completedSegments.isComplete)
        XCTAssertEqual(completedSegments.segments.count, 2)
        XCTAssertEqual(completedSegments.segments.map(\.index), [0, 1])
        XCTAssertEqual(completedSegments.segments.map(\.requestPayloadHash).count, 2)
    }

    @MainActor
    func testLongFormulaWorkflowResumesAfterV12TypedStoreRelaunchWithoutRepostingValidatedSegment() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v12-long-formula-relaunch")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("Library-v12.store")
        let schema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let document = fixtureNumberedDocument()
        let chunk = fixtureNumberedChunk(document: document)
        let source = EvidenceInputPayload(paper: fixturePaper(), document: document, chunks: [chunk],
                                          anchors: [fixtureHTMLAnchor(chunk: chunk)])
        let equation = try XCTUnwrap(source.numberedEquations.first)
        let jobID = "formula-v12-durable-segment-relaunch"
        let profile = ProviderProfile(baseURL: "https://fixture.invalid/v1", selectedModel: "fixture", usesStreaming: false)
        let firstSegment = validNumberedInsightJSON(
            source: source, includeConclusion: false,
            segmentIsFinal: false, continuationSummary: "從同一個末式繼續。",
            typedStepCount: 32
        )
        let interruptedClient = EvidenceMockClient(responses: [firstSegment, "not-json"])
        var expectedPartialHash: String?

        do {
            let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
                configurations: ModelConfiguration(schema: schema, url: storeURL))
            let inventoryHash = source.inventoryHash ?? FormulaInventory.payloadHash(
                documentHash: source.documentHash, equations: source.numberedEquations)
            let inventory = FormulaInventory(documentHash: source.documentHash,
                items: source.numberedEquations.enumerated().map { index, item in
                    FormulaInventoryItem(equationID: item.equationID, label: item.label,
                        sourceTeX: item.tex, ordinal: index + 1, documentHash: source.documentHash,
                        evidenceID: item.evidenceID)
                }, declaredInventoryHash: inventoryHash)
            try await V10FormulaInventoryStore(modelContainer: container)
                .saveFormulaInventory(inventory, paperID: source.paperID)
            try await V8TypedLibraryStore(modelContainer: container).saveEvidenceAnchors(source.anchors)
            let store = V10FormulaJobStore(modelContainer: container)
            do {
                _ = try await FormulaDerivationWorkflow(client: interruptedClient, store: store)
                    .run(source: source, profile: profile, apiKey: "fixture", jobID: jobID)
                XCTFail("the malformed continuation must leave a typed, resumable checkpoint")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }

            let interruptedRequestCount = await interruptedClient.requestCount()
            XCTAssertEqual(interruptedRequestCount, 2)
            let partialValue = try await store.formulaJob(id: jobID)
            let partial = try XCTUnwrap(partialValue)
            XCTAssertEqual(partial.job.state, .retryable)
            let segmentState = try XCTUnwrap(partial.derivationSegmentsByEquation?[equation.equationID])
            expectedPartialHash = try segmentState.provenanceHash()
            XCTAssertEqual(segmentState.completedSteps.count, 32)
            XCTAssertEqual(segmentState.segments.count, 1)
            let segmentRows = try container.mainContext.fetch(FetchDescriptor<StoredV12FormulaDerivationSegment>())
            let stepRows = try container.mainContext.fetch(FetchDescriptor<StoredV12FormulaDerivationSegmentStep>())
            let storedSegment = try XCTUnwrap(segmentRows.first)
            XCTAssertEqual(segmentRows.count, 1)
            XCTAssertEqual(stepRows.count, 32)
            XCTAssertEqual(storedSegment.paperID, source.paperID)
            XCTAssertEqual(storedSegment.documentHash, source.documentHash)
            XCTAssertEqual(storedSegment.inventoryHash, source.inventoryHash)
            XCTAssertFalse(storedSegment.requestID.isEmpty)
            XCTAssertEqual(storedSegment.requestPayloadHash, segmentState.segments[0].requestPayloadHash)
            XCTAssertEqual(storedSegment.responseHash, segmentState.segments[0].responseHash)
            XCTAssertGreaterThan(storedSegment.receivedBytes, 0)
            XCTAssertGreaterThan(storedSegment.receivedCharacters, 0)
            XCTAssertNotNil(storedSegment.firstContentAt)
            XCTAssertNotNil(storedSegment.lastContentAt)
            XCTAssertEqual(storedSegment.receiptHash,
                           try FormulaDerivationSegmentCheckpoint.provenanceHash(for: segmentState.segments[0]))
            XCTAssertEqual(storedSegment.chainHash, try segmentState.provenanceHash())
        }

        let reopened = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
            configurations: ModelConfiguration(schema: schema, url: storeURL))
        let restoredStore = V10FormulaJobStore(modelContainer: reopened)
        let restoredValue = try await restoredStore.formulaJob(id: jobID)
        let restored = try XCTUnwrap(restoredValue)
        let restoredSegment = try XCTUnwrap(restored.derivationSegmentsByEquation?[equation.equationID])
        XCTAssertEqual(restoredSegment.segments.count, 1)
        XCTAssertEqual(try restoredSegment.provenanceHash(), try XCTUnwrap(expectedPartialHash))

        let finalSegment = validNumberedInsightJSON(
            source: source, typedStepOrdinal: 33,
            typedStepBeforeTeX: equation.tex, typedStepAfterTeX: equation.tex,
            segmentIndex: 1, segmentIsFinal: true, typedStepCount: 1
        )
        let resumedClient = EvidenceMockClient(responses: [finalSegment])
        let result = try await FormulaDerivationWorkflow(client: resumedClient, store: restoredStore)
            .run(source: source, profile: profile, apiKey: "fixture", jobID: jobID)
        let resumedRequestCount = await resumedClient.requestCount()
        XCTAssertEqual(resumedRequestCount, 1, "relaunch must request only the missing continuation segment")
        XCTAssertEqual(result.attemptedRequestsThisRun, 1)
        XCTAssertTrue(result.coverage.isComplete)
        XCTAssertEqual(result.claims.first?.formulaDerivationSteps.map(\.ordinal), Array(1...33))
        let completedValue = try await restoredStore.formulaJob(id: jobID)
        let completed = try XCTUnwrap(completedValue)
        let completedSegments = try XCTUnwrap(completed.derivationSegmentsByEquation?[equation.equationID])
        XCTAssertTrue(completedSegments.isComplete)
        XCTAssertEqual(completedSegments.segments.map(\.index), [0, 1])
        XCTAssertEqual(completedSegments.segments.map(\.requestID).count, 2)

        var bundleSnapshot = LibrarySnapshot(papers: [source.paperID: fixturePaper()], schemaVersion: 12)
        bundleSnapshot.evidenceAnchors = Dictionary(uniqueKeysWithValues: source.anchors.map { ($0.id, $0) })
        let bundleURL = root.appendingPathComponent("v12-formula.latticelensbundle", isDirectory: true)
        let manifest = try V4ResearchBundle.exportV2(snapshot: bundleSnapshot,
            typedContext: reopened.mainContext, to: bundleURL)
        XCTAssertEqual(manifest.schemaVersion, 7)
        XCTAssertEqual(manifest.recordCounts["formulaDerivationSegments"], 2)
        XCTAssertEqual(manifest.recordCounts["formulaDerivationSegmentSteps"], 33)

        let restoredBundleURL = root.appendingPathComponent("v12-bundle-restored.store")
        _ = try await V4ResearchBundle.restoreToNewTypedStoreV2(bundleURL, targetStoreURL: restoredBundleURL)
        let restoredBundleContainer = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
            configurations: ModelConfiguration(schema: schema, url: restoredBundleURL))
        let restoredBundleStore = V10FormulaJobStore(modelContainer: restoredBundleContainer)
        let bundleJobValue = try await restoredBundleStore.formulaJob(id: jobID)
        let bundleJob = try XCTUnwrap(bundleJobValue)
        let bundleSegments = try XCTUnwrap(bundleJob.derivationSegmentsByEquation?[equation.equationID])
        XCTAssertEqual(try bundleSegments.provenanceHash(), try completedSegments.provenanceHash())
        XCTAssertEqual(bundleSegments.completedSteps, completedSegments.completedSteps)
        XCTAssertEqual(try restoredBundleContainer.mainContext
            .fetch(FetchDescriptor<StoredV12FormulaDerivationSegment>()).count, 2)
        XCTAssertEqual(try restoredBundleContainer.mainContext
            .fetch(FetchDescriptor<StoredV12FormulaDerivationSegmentStep>()).count, 33)
    }

    func testFormulaNumericProvenanceNormalizesTeXUnitCommandsAgainstSourceAnchor() throws {
        let paper = fixturePaper()
        let document = fixtureNumberedDocument()
        let equationID = "ar5iv:\(document.sha256):1"
        let anchorID = "ar5iv-equation:unit-provenance-fixture"
        let tex = #"E=3\,\mathrm{GeV}"#
        let quote = "编号公式 (1)\n$$\(tex)$$"
        let chunk = EvidenceChunk(id: anchorID, paperID: paper.literatureID,
            documentHash: document.sha256, page: 1, section: "Results",
            characterRangeStart: 0, characterRangeEnd: quote.count, text: quote,
            textHash: StableHash.sha256(quote), equationID: equationID,
            equationLabel: "(1)", equationTeX: tex, equationOrdinal: 1)
        let anchor = EvidenceAnchor(id: anchorID, paperID: paper.literatureID,
            sourceKind: .pdf, page: nil, section: "Results", quote: quote,
            quoteHash: StableHash.sha256(quote), figureKey: nil)
        let source = EvidenceInputPayload(paper: paper, document: document, chunks: [chunk], anchors: [anchor])

        let supported = validNumberedInsightJSON(
            source: source, typedStepAfterTeX: tex, typedConclusion: "该来源公式给出 3 GeV。"
        )
        XCTAssertNoThrow(try PaperInsightV2Validator.decode(Data(supported.utf8), source: source, maximumFigures: 0))

        let unsupported = validNumberedInsightJSON(
            source: source,
            typedStepAfterTeX: #"E=4\,\mathrm{GeV}"#,
            typedConclusion: "该来源公式给出 4 GeV。"
        )
        XCTAssertThrowsError(try PaperInsightV2Validator.decode(
            Data(unsupported.utf8), source: source, maximumFigures: 0
        ))
    }

    func testFormulaCoverageValidatorRejectsDependencyCyclesAndAcceptsKnownAcyclicReferences() throws {
        let documentHash = "formula-document-hash"
        let inventory = FormulaInventory(documentHash: documentHash, items: [
            FormulaInventoryItem(equationID: "eq-1", label: "(1)", sourceTeX: "x=1", ordinal: 1,
                                 documentHash: documentHash, evidenceID: "anchor-1"),
            FormulaInventoryItem(equationID: "eq-2", label: "(2)", sourceTeX: "y=2", ordinal: 2,
                                 documentHash: documentHash, evidenceID: "anchor-2")
        ])
        let anchors = [
            "anchor-1": EvidenceAnchor(id: "anchor-1", paperID: 42, sourceKind: .pdf, page: 1, section: nil,
                                       quote: "编号公式 (1)\n$$x=1$$", quoteHash: StableHash.sha256("编号公式 (1)\n$$x=1$$"), figureKey: nil),
            "anchor-2": EvidenceAnchor(id: "anchor-2", paperID: 42, sourceKind: .pdf, page: 2, section: nil,
                                       quote: "编号公式 (2)\n$$y=2$$", quoteHash: StableHash.sha256("编号公式 (2)\n$$y=2$$"), figureKey: nil)
        ]
        func claim(_ id: String, _ tex: String, _ label: String, _ anchorID: String, dependsOn: [String]) -> EvidenceClaim {
            let step = FormulaDerivationStep(stepID: "\(id):step:1", ordinal: 1,
                textZH: "從目前來源公式建立有界解釋。", beforeTeX: tex, afterTeX: tex,
                ruleOrAssumption: "只使用已列出的公式與 anchor。",
                referencedEquationIDs: dependsOn, evidenceAnchorIDs: [anchorID],
                sourceDocumentHashes: [documentHash], epistemicStatus: .inference)
            return EvidenceClaim(textZH: "原文公式 \(label)。", epistemicStatus: .direct,
                evidenceIDs: [anchorID], formulaTeX: tex, equationID: id,
                formulaDerivationSteps: [step], conclusionZH: "该来源式作为当前受限结论。")
        }
        let cyclic = [claim("eq-1", "x=1", "(1)", "anchor-1", dependsOn: ["eq-2"]),
                      claim("eq-2", "y=2", "(2)", "anchor-2", dependsOn: ["eq-1"])]
        let cyclicReport = FormulaCoverageValidator.report(inventory: inventory, claims: cyclic, anchors: anchors)
        XCTAssertFalse(cyclicReport.isComplete)
        XCTAssertEqual(Set(cyclicReport.derivationIncompleteEquationIDs), Set(["eq-1", "eq-2"]))

        let acyclic = [claim("eq-1", "x=1", "(1)", "anchor-1", dependsOn: ["eq-2"]),
                       claim("eq-2", "y=2", "(2)", "anchor-2", dependsOn: [])]
        XCTAssertTrue(try FormulaCoverageValidator.validate(inventory: inventory, claims: acyclic, anchors: anchors).isComplete)
    }

    func testFormulaCoverageClaimHashBindsClaimTextStatusConclusionStepsAndAnchorPayload() {
        let documentHash = "proof-hash-document"
        let anchorID = "proof-anchor"
        let inventory = FormulaInventory(documentHash: documentHash, items: [
            FormulaInventoryItem(equationID: "proof-eq", label: "(1)", sourceTeX: "x=1", ordinal: 1,
                                 documentHash: documentHash, evidenceID: anchorID)
        ])
        let anchor = EvidenceAnchor(id: anchorID, paperID: 42, sourceKind: .pdf, page: nil,
            section: "Results", quote: "编号公式 (1)\n$$x=1$$",
            quoteHash: StableHash.sha256("编号公式 (1)\n$$x=1$$"), figureKey: nil)
        let anchors = [anchorID: anchor]
        let claimID = UUID(uuidString: "A3D2E2A2-5730-4CEB-A412-4A69479B8B75")!

        func makeClaim(text: String = "原文公式 (1)。", status: EpistemicStatus = .direct,
                       conclusion: String? = "由来源公式得到结论。", stepText: String = "保持来源可追溯。",
                       segmentProvenanceHash: String? = nil) -> EvidenceClaim {
            let step = FormulaDerivationStep(stepID: "proof-eq:step:1", ordinal: 1, textZH: stepText,
                beforeTeX: "x=1", afterTeX: "x=1", ruleOrAssumption: "不引入额外物理输入。",
                evidenceAnchorIDs: [anchorID], sourceDocumentHashes: [documentHash], epistemicStatus: .inference)
            return EvidenceClaim(id: claimID, textZH: text, epistemicStatus: status, evidenceIDs: [anchorID],
                formulaTeX: "x=1", equationID: "proof-eq", formulaDerivationSteps: [step],
                conclusionZH: conclusion,
                derivationSegmentProvenanceHash: segmentProvenanceHash)
        }
        func hash(_ claim: EvidenceClaim, anchorsOverride: [String: EvidenceAnchor]? = nil) -> String {
            FormulaCoverageValidator.report(inventory: inventory, claims: [claim],
                                            anchors: anchorsOverride ?? anchors).claimHash
        }

        let original = makeClaim()
        let originalHash = hash(original)
        let originalReport = FormulaCoverageValidator.report(inventory: inventory, claims: [original], anchors: anchors)
        XCTAssertTrue(originalReport.sourceCoverageComplete)
        XCTAssertTrue(originalReport.derivationCoverageComplete)
        XCTAssertTrue(originalReport.structuralValidationPassed)
        XCTAssertFalse(originalReport.physicsReviewComplete,
                       "a source/derivation-complete result must not imply human physics review")
        XCTAssertTrue(originalReport.isComplete,
                      "completion is coverage plus derivation structure, independent of the manual physics-review dimension")
        let manualStructureStep = FormulaDerivationStep(stepID: "proof-eq:step:1", ordinal: 1,
            textZH: "保留原式并标出尚未解析的宏。", beforeTeX: "x=1", afterTeX: #"\customphysics{x}"#,
            ruleOrAssumption: "自定义宏未在本地支持子集内。", evidenceAnchorIDs: [anchorID],
            sourceDocumentHashes: [documentHash], epistemicStatus: .inference)
        let manualStructureClaim = EvidenceClaim(id: claimID, textZH: "原文公式 (1)。", epistemicStatus: .direct,
            evidenceIDs: [anchorID], formulaTeX: "x=1", equationID: "proof-eq",
            formulaDerivationSteps: [manualStructureStep], conclusionZH: "保留原文定义，不判定宏的物理含义。")
        let manualStructureReport = FormulaCoverageValidator.report(
            inventory: inventory, claims: [manualStructureClaim], anchors: anchors)
        XCTAssertTrue(manualStructureReport.isComplete,
                      "unsupported macros remain visible as needs_manual rather than being called malformed")
        XCTAssertEqual(manualStructureReport.structuralNeedsManualEquationIDs, ["proof-eq"])
        XCTAssertEqual(manualStructureReport.physicsNeedsManualEquationIDs, ["proof-eq"])
        XCTAssertEqual(originalHash, hash(makeClaim()), "canonical proof encoding must be deterministic")
        XCTAssertNotEqual(originalHash, hash(makeClaim(text: "改動後的 claim 文本。")))
        XCTAssertNotEqual(originalHash, hash(makeClaim(status: .inference)))
        XCTAssertNotEqual(originalHash, hash(makeClaim(conclusion: "改動後的結論。")))
        XCTAssertNotEqual(originalHash, hash(makeClaim(stepText: "改動後的推導步驟。")))
        XCTAssertNotEqual(originalHash, hash(makeClaim(segmentProvenanceHash: String(repeating: "a", count: 64))),
                          "the final proof must bind segment request/response provenance")

        let changedAnchor = EvidenceAnchor(id: anchorID, paperID: 42, sourceKind: .pdf, page: nil,
            section: "Methods", quote: anchor.quote, quoteHash: anchor.quoteHash, figureKey: nil)
        XCTAssertNotEqual(originalHash, hash(original, anchorsOverride: [anchorID: changedAnchor]),
                          "the proof hash must bind the referenced source anchor, not only its ID")
        XCTAssertEqual(FormulaCoverageValidator.version, "formula-coverage-v4-segment-provenance")
    }

    func testVisionValidatorAndWorkflowKeepVisionSeparateFromCaptionOnly() async throws {
        var paper = fixturePaper()
        paper.figures = [PaperFigure(key: "fig1", url: URL(string: "https://example.test/fig1.png"), label: "Figure 1",
                                     caption: "A synthetic caption.", source: "fixture", filename: "fig1.png")]
        let valid = """
        {"schema_version":"paper-vision-v1","evidence_mode":"vision","figures":[{"figure_key":"fig1","text_zh":"缩放图像显示一条合成曲线。","evidence_mode":"vision"}]}
        """
        XCTAssertNoThrow(try VisionInsightValidator.decode(Data(valid.utf8), allowedFigureKeys: ["fig1"]))
        let wrongKey = valid.replacingOccurrences(of: "\"fig1\"", with: "\"outside\"")
        let captionOnly = valid.replacingOccurrences(of: "\"vision\"}", with: "\"caption_only\"}")
        XCTAssertThrowsError(try VisionInsightValidator.decode(Data(wrongKey.utf8), allowedFigureKeys: ["fig1"]))
        XCTAssertThrowsError(try VisionInsightValidator.decode(Data(captionOnly.utf8), allowedFigureKeys: ["fig1"]))

        let store = InMemoryLibraryStore()
        let client = VisionMockClient(response: valid)
        let loader = FixtureVisionLoader()
        let workflow = VisionWorkflow(store: store, client: client, loader: loader)
        var settings = LLMSettings(profiles: ["openAI": ProviderProfile(baseURL: "https://example.test/v1", selectedModel: "vision-fixture", usesStreaming: false, supportsVision: true)],
                                   automaticAnalysis: false, maximumFigures: 3)
        let first = try await workflow.generate(for: paper, settings: settings, apiKey: "fixture") { _ in }
        let second = try await workflow.generate(for: paper, settings: settings, apiKey: "fixture") { _ in }
        XCTAssertEqual(first, second)
        let visionRequestCount = await client.requestCount()
        XCTAssertEqual(visionRequestCount, 1)
        XCTAssertEqual(first.insights.first?.evidenceMode, "vision")
        XCTAssertEqual(first.figureKeys, ["fig1"])
        settings.profiles["openAI"]?.supportsVision = false
        do {
            _ = try await workflow.generate(for: paper, settings: settings, apiKey: "fixture") { _ in }
            XCTFail("未确认 capability 的 Vision request 必须被拒绝")
        } catch {}
    }

    func testEvidenceAndVisionDeadlinesRejectOneRequestWithoutRetry() async throws {
        let timeout = V4AnalysisTimeouts(connect: 0.010, firstContent: 0.030, idle: 0.030, hard: 0.060)
        let paper = fixturePaper()
        let document = fixtureNumberedDocument()
        let chunk = fixtureNumberedChunk(document: document)
        let anchor = fixtureHTMLAnchor(chunk: chunk)
        let store = InMemoryLibraryStore()
        _ = try await store.upsert(papers: [paper], for: 21)
        try await store.saveFullText(document: document, chunks: [chunk], anchors: [anchor])
        let evidenceClient = DelayedEvidenceClient()
        let evidenceWorkflow = EvidenceInsightWorkflow(store: store, client: evidenceClient, timeouts: timeout)
        let textSettings = LLMSettings(
            profiles: ["openAI": ProviderProfile(baseURL: "https://example.test/v1", selectedModel: "fixture", usesStreaming: true)],
            automaticAnalysis: false, mode: .fast, maximumFigures: 0
        )
        do {
            _ = try await evidenceWorkflow.generate(for: paper, settings: textSettings, apiKey: "fixture") { _ in }
            XCTFail("connect deadline must reject the evidence request")
        } catch let error as V4AnalysisDeadlineError {
            XCTAssertEqual(error, .connect)
        }
        let evidenceRequestCount = await evidenceClient.requestCount()
        let afterEvidenceTimeout = await store.snapshot()
        XCTAssertEqual(evidenceRequestCount, 1, "evidence timeout must not retry a disclosure")
        XCTAssertTrue(afterEvidenceTimeout.evidenceInsights.isEmpty)

        var visionPaper = paper
        visionPaper.figures = [PaperFigure(key: "fig1", url: URL(string: "https://example.test/fig1.png"), label: "Figure 1",
                                            caption: "fixture", source: "fixture", filename: "fig1.png")]
        let visionClient = DelayedVisionClient()
        let visionWorkflow = VisionWorkflow(store: store, client: visionClient, loader: FixtureVisionLoader(), timeouts: timeout)
        let visionSettings = LLMSettings(
            profiles: ["openAI": ProviderProfile(baseURL: "https://example.test/v1", selectedModel: "fixture-vision", usesStreaming: true, supportsVision: true)],
            automaticAnalysis: false, mode: .fast, maximumFigures: 1
        )
        do {
            _ = try await visionWorkflow.generate(for: visionPaper, settings: visionSettings, apiKey: "fixture") { _ in }
            XCTFail("connect deadline must reject the vision request")
        } catch let error as V4AnalysisDeadlineError {
            XCTAssertEqual(error, .connect)
        }
        let visionRequestCount = await visionClient.requestCount()
        let afterVisionTimeout = await store.snapshot()
        XCTAssertEqual(visionRequestCount, 1, "vision timeout must not retry frozen image bytes")
        XCTAssertTrue(afterVisionTimeout.visionArtifacts.isEmpty)
    }

    func testEvidenceProductionClientEnforcesConnectAndFirstContentDeadlines() async throws {
        let paper = fixturePaper()
        let document = fixtureNumberedDocument()
        let chunk = fixtureNumberedChunk(document: document)
        let anchor = fixtureHTMLAnchor(chunk: chunk)
        let store = InMemoryLibraryStore()
        _ = try await store.upsert(papers: [paper], for: 21)
        try await store.saveFullText(document: document, chunks: [chunk], anchors: [anchor])

        let timeouts = V4AnalysisTimeouts(connect: 0.060, firstContent: 0.060, idle: 0.060, hard: 0.200)
        XCTAssertTrue(V4AnalysisTimeouts.evidence.isValidRequestBudget,
                      "the default Evidence profile must have finite, positive per-request deadlines")
        XCTAssertEqual(V4AnalysisTimeouts.evidence, .default)
        let profile = ProviderProfile(provider: .openAI, baseURL: "https://fixture.invalid/v1",
                                      selectedModel: "slow-fixture", usesStreaming: true)
        let settings = LLMSettings(
            profiles: [LLMProvider.openAI.rawValue: profile],
            automaticAnalysis: false, mode: .fast, maximumFigures: 0
        )

        let cases: [(SlowLLMRequestMode, V4AnalysisDeadlineError)] = [
            (.noHeaders, .connect),
            (.headersWithoutContent, .firstContent),
        ]
        for (mode, expectedError) in cases {
            SlowEvidenceURLProtocol.reset(mode: mode)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SlowEvidenceURLProtocol.self]
            let client = OpenAICompatibleClient(session: URLSession(configuration: configuration))
            let workflow = EvidenceInsightWorkflow(store: store, client: client, timeouts: timeouts)
            let startedAt = Date()
            var observedError: V4AnalysisDeadlineError?
            do {
                _ = try await workflow.generate(for: paper, settings: settings, apiKey: "fixture") { _ in }
                XCTFail("the production Evidence entry must terminate a stalled request")
            } catch let error as V4AnalysisDeadlineError {
                observedError = error
            } catch {
                XCTFail("expected a classified per-request deadline, got \(error)")
            }

            XCTAssertEqual(observedError, expectedError)
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.0,
                              "the request deadline must return without waiting for an aggregate job timeout")
            for _ in 0..<25 where SlowEvidenceURLProtocol.metrics().stops == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            let metrics = SlowEvidenceURLProtocol.metrics()
            XCTAssertEqual(metrics.requests, 1, "a timed-out evidence disclosure must not be retried")
            XCTAssertEqual(metrics.method, "POST", "the intercepted production request must use the expected completion method")
            XCTAssertGreaterThan(metrics.stops, 0, "timing out must cancel the underlying URLSession request")
            XCTAssertEqual(try XCTUnwrap(metrics.requestTimeout), timeouts.hard, accuracy: 0.01,
                           "the production client must receive the finite max-resource request budget")
        }
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.evidenceInsights.isEmpty,
                      "a late or timed-out production response must not publish an evidence artifact")
    }

    func testEvidenceProductionClientCancelsActiveRequestWithoutRetryOrArtifact() async throws {
        let paper = fixturePaper()
        let document = fixtureNumberedDocument()
        let chunk = fixtureNumberedChunk(document: document)
        let anchor = fixtureHTMLAnchor(chunk: chunk)
        let store = InMemoryLibraryStore()
        _ = try await store.upsert(papers: [paper], for: 21)
        try await store.saveFullText(document: document, chunks: [chunk], anchors: [anchor])

        SlowEvidenceURLProtocol.reset(mode: .headersWithoutContent)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowEvidenceURLProtocol.self]
        let client = OpenAICompatibleClient(session: URLSession(configuration: configuration))
        let workflow = EvidenceInsightWorkflow(
            store: store,
            client: client,
            timeouts: V4AnalysisTimeouts(connect: 1, firstContent: 1, idle: 1, hard: 2)
        )
        let profile = ProviderProfile(provider: .openAI, baseURL: "https://fixture.invalid/v1",
                                      selectedModel: "slow-fixture", usesStreaming: true)
        let settings = LLMSettings(
            profiles: [LLMProvider.openAI.rawValue: profile],
            automaticAnalysis: false, mode: .fast, maximumFigures: 0
        )
        let requestTask = Task {
            try await workflow.generate(for: paper, settings: settings, apiKey: "fixture") { _ in }
        }
        for _ in 0..<100 where SlowEvidenceURLProtocol.metrics().requests == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(SlowEvidenceURLProtocol.metrics().requests, 1,
                       "the production request must be active before the user cancels it")
        try await Task.sleep(for: .milliseconds(20))

        let cancellationStartedAt = Date()
        requestTask.cancel()
        var cancellationObserved = false
        do {
            _ = try await requestTask.value
            XCTFail("cancelling the Evidence task must not return a completed artifact")
        } catch let error as LatticeLensError {
            if case .cancelled = error { cancellationObserved = true }
            else { XCTFail("expected a user-cancellation result, got \(error)") }
        } catch {
            XCTFail("expected LatticeLensError.cancelled, got \(error)")
        }
        XCTAssertTrue(cancellationObserved)
        XCTAssertLessThan(Date().timeIntervalSince(cancellationStartedAt), 0.5,
                          "user cancellation must not wait for the per-request timeout")
        for _ in 0..<25 where SlowEvidenceURLProtocol.metrics().stops == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let metrics = SlowEvidenceURLProtocol.metrics()
        XCTAssertEqual(metrics.requests, 1, "cancellation must not trigger an implicit POST retry")
        XCTAssertEqual(metrics.method, "POST")
        XCTAssertGreaterThan(metrics.stops, 0, "cancellation must stop the underlying URLSession request")
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.evidenceInsights.isEmpty,
                      "a cancelled production request must not publish an Evidence artifact")
    }

    func testEvidenceProductionFormulaRequestReceivesFiniteDeadlineAfterProseSucceeds() async throws {
        let paper = fixturePaper()
        let document = fixtureNumberedDocument()
        let chunk = fixtureNumberedChunk(document: document)
        let anchor = fixtureHTMLAnchor(chunk: chunk)
        let metadataAnchors = EvidenceAnchorFactory.metadataAnchors(for: paper)
        let store = InMemoryLibraryStore()
        _ = try await store.upsert(papers: [paper], for: 21)
        try await store.saveFullText(document: document, chunks: [chunk], anchors: [anchor])
        try await store.saveEvidenceAnchors(metadataAnchors)

        let source = EvidenceInputPayload(paper: paper, document: document, chunks: [chunk],
                                          anchors: [anchor] + metadataAnchors)
        let proseResponse = validNumberedInsightJSON(source: source.proseOnly())
        let timeouts = V4AnalysisTimeouts(connect: 0.100, firstContent: 0.100, idle: 0.100, hard: 0.500)
        let profile = ProviderProfile(provider: .openAI, baseURL: "https://fixture.invalid/v1",
                                      selectedModel: "formula-deadline-fixture", usesStreaming: true)
        let settings = LLMSettings(
            profiles: [LLMProvider.openAI.rawValue: profile],
            automaticAnalysis: false, mode: .fast, maximumFigures: 0
        )
        let jobs = InMemoryFormulaJobStore()

        EvidenceFormulaDeadlineURLProtocol.reset(proseResponse: proseResponse)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EvidenceFormulaDeadlineURLProtocol.self]
        let client = OpenAICompatibleClient(session: URLSession(configuration: configuration))
        let workflow = EvidenceInsightWorkflow(store: store, client: client, timeouts: timeouts, formulaJobs: jobs)
        let workflowTask = Task {
            try await workflow.generate(for: paper, settings: settings, apiKey: "fixture") { _ in }
        }
        let watchdog = Task {
            do {
                try await Task.sleep(for: .seconds(2))
                workflowTask.cancel()
            } catch {
                // The production request should finish well before this guard.
            }
        }
        defer { watchdog.cancel() }

        let startedAt = Date()
        do {
            _ = try await workflowTask.value
            XCTFail("a stalled formula POST must fail after the valid prose POST")
        } catch let error as V4AnalysisDeadlineError {
            XCTAssertEqual(error, .firstContent,
                           "the formula request must use its own finite first-content deadline")
        } catch {
            XCTFail("expected the formula request's classified deadline, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.0,
                          "one formula request deadline must not wait for a job-wide timeout")

        for _ in 0..<25 where !EvidenceFormulaDeadlineURLProtocol.metrics().stoppedRequestIndices.contains(2) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let metrics = EvidenceFormulaDeadlineURLProtocol.metrics()
        XCTAssertEqual(metrics.requests.count, 2,
                       "the production path must send one prose POST and one formula POST, with no retry")
        XCTAssertEqual(metrics.requests.map(\.method), ["POST", "POST"])
        XCTAssertEqual(metrics.requests.compactMap(\.systemPrompt),
                       [EvidenceInsightPrompt.systemInstruction, FormulaDerivationPrompt.systemInstruction],
                       "the second timed request must be the formula batch, not another prose attempt")
        XCTAssertTrue(metrics.requests.allSatisfy { $0.requestTimeout.isFinite && $0.requestTimeout > 0 })
        for request in metrics.requests {
            XCTAssertEqual(request.requestTimeout, timeouts.hard, accuracy: 0.01,
                           "both real-client requests must receive the finite per-request resource deadline")
        }
        XCTAssertTrue(metrics.stoppedRequestIndices.contains(2),
                      "the timed-out formula request must stop its underlying URLSession task")

        let executionFingerprint = FormulaDerivationWorkflow.executionFingerprint(
            profile: profile, settingsFingerprint: settings.sessionFingerprint
        )
        let formulaJobID = FormulaDerivationWorkflow.durableJobID(
            paperID: paper.literatureID,
            documentHash: source.documentHash,
            inventoryHash: source.inventoryHash ?? FormulaInventory.payloadHash(
                documentHash: source.documentHash, equations: source.numberedEquations
            ),
            executionFingerprint: executionFingerprint
        )
        let checkpoint = await jobs.formulaJob(id: formulaJobID)
        XCTAssertEqual(checkpoint?.job.state, .retryable)
        let batch = try XCTUnwrap(checkpoint?.job.batches.first)
        XCTAssertEqual(batch.status, .retryable)
        XCTAssertEqual(batch.errorCategory, "first_content_timeout")
        XCTAssertTrue(checkpoint?.completedClaimsByBatch.isEmpty == true,
                      "a timed-out batch must not be recorded as successfully validated")

        let snapshot = await store.snapshot()
        let publications = await jobs.readyEvidenceInsightPublicationsForTesting()
        XCTAssertTrue(snapshot.evidenceInsights.isEmpty,
                      "failed formula coverage must not publish an Evidence artifact")
        XCTAssertTrue(publications.isEmpty,
                      "failed formula coverage must not leave a ready-to-publish artifact")
    }

    func testEvidenceProductionFormulaRequestCanBeCancelledWithoutRetryOrPublication() async throws {
        let paper = fixturePaper()
        let document = fixtureNumberedDocument()
        let chunk = fixtureNumberedChunk(document: document)
        let anchor = fixtureHTMLAnchor(chunk: chunk)
        let metadataAnchors = EvidenceAnchorFactory.metadataAnchors(for: paper)
        let store = InMemoryLibraryStore()
        _ = try await store.upsert(papers: [paper], for: 21)
        try await store.saveFullText(document: document, chunks: [chunk], anchors: [anchor])
        try await store.saveEvidenceAnchors(metadataAnchors)

        let source = EvidenceInputPayload(paper: paper, document: document, chunks: [chunk],
                                          anchors: [anchor] + metadataAnchors)
        let proseResponse = validNumberedInsightJSON(source: source.proseOnly())
        let timeouts = V4AnalysisTimeouts(connect: 1, firstContent: 1, idle: 1, hard: 3)
        let profile = ProviderProfile(provider: .openAI, baseURL: "https://fixture.invalid/v1",
                                      selectedModel: "formula-cancel-fixture", usesStreaming: true)
        let settings = LLMSettings(
            profiles: [LLMProvider.openAI.rawValue: profile],
            automaticAnalysis: false, mode: .fast, maximumFigures: 0
        )
        let jobs = InMemoryFormulaJobStore()

        EvidenceFormulaDeadlineURLProtocol.reset(proseResponse: proseResponse)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EvidenceFormulaDeadlineURLProtocol.self]
        let client = OpenAICompatibleClient(session: URLSession(configuration: configuration))
        let workflow = EvidenceInsightWorkflow(store: store, client: client, timeouts: timeouts, formulaJobs: jobs)
        let workflowTask = Task {
            try await workflow.generate(for: paper, settings: settings, apiKey: "fixture") { _ in }
        }
        for _ in 0..<100 where EvidenceFormulaDeadlineURLProtocol.metrics().requests.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let activeMetrics = EvidenceFormulaDeadlineURLProtocol.metrics()
        XCTAssertEqual(activeMetrics.requests.count, 2,
                       "the valid prose request must finish before cancellation targets the active formula POST")
        XCTAssertEqual(activeMetrics.requests.compactMap(\.systemPrompt),
                       [EvidenceInsightPrompt.systemInstruction, FormulaDerivationPrompt.systemInstruction])

        let cancellationStartedAt = Date()
        workflowTask.cancel()
        var cancellationObserved = false
        do {
            _ = try await workflowTask.value
            XCTFail("cancelling the active formula request must not publish a completed artifact")
        } catch let error as LatticeLensError {
            if case .cancelled = error { cancellationObserved = true }
            else { XCTFail("expected a user-cancellation result, got \(error)") }
        } catch {
            XCTFail("expected LatticeLensError.cancelled, got \(error)")
        }
        XCTAssertTrue(cancellationObserved)
        XCTAssertLessThan(Date().timeIntervalSince(cancellationStartedAt), 0.5,
                          "user cancellation must stop the formula POST before its request deadline")

        for _ in 0..<25 where !EvidenceFormulaDeadlineURLProtocol.metrics().stoppedRequestIndices.contains(2) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let metrics = EvidenceFormulaDeadlineURLProtocol.metrics()
        XCTAssertEqual(metrics.requests.count, 2, "formula cancellation must not cause an implicit retry")
        XCTAssertEqual(metrics.requests.map(\.method), ["POST", "POST"])
        XCTAssertTrue(metrics.stoppedRequestIndices.contains(2),
                      "cancelling the workflow must stop the active formula URLSession request")
        for request in metrics.requests {
            XCTAssertTrue(request.requestTimeout.isFinite && request.requestTimeout > 0)
            XCTAssertEqual(request.requestTimeout, timeouts.hard, accuracy: 0.01)
        }

        let executionFingerprint = FormulaDerivationWorkflow.executionFingerprint(
            profile: profile, settingsFingerprint: settings.sessionFingerprint
        )
        let formulaJobID = FormulaDerivationWorkflow.durableJobID(
            paperID: paper.literatureID,
            documentHash: source.documentHash,
            inventoryHash: source.inventoryHash ?? FormulaInventory.payloadHash(
                documentHash: source.documentHash, equations: source.numberedEquations
            ),
            executionFingerprint: executionFingerprint
        )
        let checkpoint = await jobs.formulaJob(id: formulaJobID)
        XCTAssertEqual(checkpoint?.job.state, .cancelled)
        let batch = try XCTUnwrap(checkpoint?.job.batches.first)
        XCTAssertEqual(batch.status, .cancelled)
        XCTAssertEqual(batch.errorCategory, "cancelled")
        XCTAssertTrue(checkpoint?.completedClaimsByBatch.isEmpty == true)

        let snapshot = await store.snapshot()
        let publications = await jobs.readyEvidenceInsightPublicationsForTesting()
        XCTAssertTrue(snapshot.evidenceInsights.isEmpty,
                      "a cancelled formula request must not publish an Evidence artifact")
        XCTAssertTrue(publications.isEmpty,
                      "a cancelled formula request must not leave a ready-to-publish artifact")
    }

    func testReferenceManagerPersistsReadFavoriteTagCollectionNoteAndSafeExport() async throws {
        let paper = fixturePaper()
        let store = InMemoryLibraryStore()
        _ = try await store.upsert(papers: [paper], for: 21)
        let manager = ReferenceManagerService(store: store)
        try await store.markRead(true, paperID: paper.literatureID, at: Date(timeIntervalSince1970: 4))
        try await manager.toggleFavorite(paperID: paper.literatureID, current: false)
        try await manager.saveNote(paperID: paper.literatureID, body: "check RI/MOM convention")
        try await manager.createTag(named: "renormalization")
        try await manager.createCollection(named: "to read")
        let snapshot = await store.snapshot()
        let tag = try XCTUnwrap(snapshot.tags.values.first)
        let collection = try XCTUnwrap(snapshot.collections.values.first)
        try await manager.setTags([tag.id], paperID: paper.literatureID)
        try await manager.setCollection([paper.literatureID], collectionID: collection.id)
        let restored = await store.snapshot()
        let noteMatches = await manager.searchPapers("RI MOM").map(\.literatureID)
        let collectionMatches = await manager.searchPapers("to read").map(\.literatureID)
        XCTAssertTrue(restored.papers[paper.literatureID]?.isRead == true)
        XCTAssertTrue(restored.papers[paper.literatureID]?.isFavorite == true)
        XCTAssertEqual(noteMatches, [paper.literatureID])
        XCTAssertEqual(collectionMatches, [paper.literatureID])
        let markdown = try await manager.markdownNote(for: paper.literatureID)
        XCTAssertTrue(markdown.contains("check RI/MOM convention"))
        XCTAssertFalse(markdown.localizedCaseInsensitiveContains("api key"))
        XCTAssertEqual(manager.bibTeXURL(for: paper.literatureID)?.host, "inspirehep.net")
    }

    func testBibTeXEndpointResponseIsCachedWithSourceTimeAndFailurePreservesPriorRecord() async throws {
        let paper = fixturePaper()
        let store = InMemoryLibraryStore()
        _ = try await store.upsert(papers: [paper], for: 21)
        let timestamp = Date(timeIntervalSince1970: 42)
        let success = ReferenceManagerService(store: store, bibTeXRequester: FixtureBibTeXRequester())
        let record = try await success.fetchAndCacheBibTeX(for: paper.literatureID, now: timestamp)
        XCTAssertEqual(record.sourceFetchedAt, timestamp)
        XCTAssertEqual(record.contents, "@article{fixture, title={A fixture}}\n")
        let afterSuccess = await store.snapshot()
        XCTAssertEqual(afterSuccess.bibTeXRecords[paper.literatureID], record)

        let failed = ReferenceManagerService(store: store, bibTeXRequester: FailingBibTeXRequester())
        do {
            _ = try await failed.fetchAndCacheBibTeX(for: paper.literatureID, now: Date(timeIntervalSince1970: 43))
            XCTFail("BibTeX endpoint failure 不能触发本地伪造或覆盖")
        } catch {}
        let afterFailure = await store.snapshot()
        XCTAssertEqual(afterFailure.bibTeXRecords[paper.literatureID], record)
    }

    private func fixturePaper() -> Paper {
        Paper(literatureID: 901, titles: [PaperTitle(value: "Lattice fixture", source: "fixture")],
              abstracts: [PaperAbstract(value: "A synthetic abstract with a constrained method.", source: "fixture")],
              preprintDate: nil, earliestDate: nil, arxivID: "2601.00001", arxivCategories: ["hep-lat"], doi: nil,
              citationCount: nil, publicationStatus: nil, updated: Date(timeIntervalSince1970: 1),
              figures: [PaperFigure(key: "fig1", url: nil, label: "Figure 1", caption: "A synthetic caption.", source: "fixture", filename: "fig1.pdf")],
              firstSeenAt: Date(timeIntervalSince1970: 1), isRead: false)
    }

    private func fixtureDocument() -> FullTextDocument {
        FullTextDocument(paperID: 901, sourceURL: URL(string: "https://example.test/paper.pdf")!, sourceKind: .inspireDocument,
                         sha256: "document-hash", byteCount: 32, localFilename: "fixture.pdf", pageCount: 1,
                         extractionState: .extracted, downloadedAt: Date(timeIntervalSince1970: 2), lastErrorCategory: nil)
    }

    private func fixtureChunk(document: FullTextDocument) -> EvidenceChunk {
        let text = "The renormalization scale is 2 GeV."
        return EvidenceChunk(id: "pdf:p1:q1:fixture", paperID: 901, documentHash: document.sha256, page: 1, section: "Results",
                             characterRangeStart: 0, characterRangeEnd: text.count, text: text, textHash: StableHash.sha256(text))
    }

    private func fixtureNumberedDocument() -> FullTextDocument {
        FullTextDocument(paperID: 901, sourceURL: URL(string: "https://ar5iv.labs.arxiv.org/html/2601.00001")!, sourceKind: .arxivHTML,
                         sha256: "numbered-document-hash", byteCount: 96, localFilename: "fixture.html", pageCount: nil,
                         extractionState: .extracted, downloadedAt: Date(timeIntervalSince1970: 2), lastErrorCategory: nil,
                         numberedEquationIndexVersion: FullTextService.numberedEquationIndexVersion,
                         numberedEquationCount: 1, numberedEquationIndexComplete: true)
    }

    private func fixtureNumberedChunk(document: FullTextDocument) -> EvidenceChunk {
        let tex = "C(t)=A e^{-mt}"
        let text = "编号公式 (1)\n$$\(tex)$$"
        return EvidenceChunk(id: "ar5iv-equation:901:numbered-document-hash:q1:fixture", paperID: 901,
                             documentHash: document.sha256, page: 1, section: "Results",
                             characterRangeStart: 1, characterRangeEnd: 1 + text.count, text: text,
                             textHash: StableHash.sha256(text), equationID: "ar5iv:numbered-document-hash:1",
                             equationLabel: "(1)", equationTeX: tex, equationOrdinal: 1)
    }

    private func fixturePDFAnchor(chunk: EvidenceChunk) -> EvidenceAnchor {
        EvidenceAnchor(id: chunk.id, paperID: chunk.paperID, sourceKind: .pdf, page: chunk.page, section: chunk.section,
                       quote: chunk.text, quoteHash: chunk.textHash, figureKey: nil)
    }

    private func fixtureHTMLAnchor(chunk: EvidenceChunk) -> EvidenceAnchor {
        EvidenceAnchor(id: chunk.id, paperID: chunk.paperID, sourceKind: .pdf, page: nil, section: chunk.section,
                       quote: chunk.text, quoteHash: chunk.textHash, figureKey: nil)
    }

    private func makeEvidencePayload() -> EvidenceInputPayload {
        let paper = fixturePaper()
        let document = fixtureDocument()
        let chunk = fixtureChunk(document: document)
        return EvidenceInputPayload(paper: paper, document: document, chunks: [chunk], anchors: [fixturePDFAnchor(chunk: chunk)])
    }

    private func validInsightJSON(anchorID: String) -> String {
        """
        {"schema_version":"paper-insight-v2","source_scope":"fulltext_with_anchors","title_zh":"格点测试","abstract_zh":"受限摘要","physics":{"research_question":{"text_zh":"论文给出一个受限的研究问题","epistemic_status":"direct","evidence_ids":["\(anchorID)"]},"method_and_data_flow":[],"main_results":[{"text_zh":"重整化尺度为 2 GeV","epistemic_status":"direct","evidence_ids":["\(anchorID)"]}],"reasonable_inferences":[],"missing_information":[{"text_zh":"缺少体积","epistemic_status":"missing","evidence_ids":[]}],"caveats":[]},"important_figures":[],"terminology":[]}
        """
    }

    private func validNumberedInsightJSON(
        source: EvidenceInputPayload,
        includeFormula: Bool = true,
        formulaTeX: String? = nil,
        includeTypedSteps: Bool = true,
        includeConclusion: Bool = true,
        typedStepStatus: String = "inference",
        typedStepOrdinal: Int = 1,
        typedStepBeforeTeX: String? = nil,
        typedStepAfterTeX: String? = nil,
        typedConclusion: String? = nil,
        segmentIndex: Int = 0,
        segmentIsFinal: Bool = true,
        continuationSummary: String? = nil,
        typedStepCount: Int = 1
    ) -> String {
        let anchorID = source.anchors[0].id
        let formulas: [[String: Any]] = includeFormula ? source.numberedEquations.map { equation in
            let stepText = "仅将编号公式作为本步骤的原文起点。"
            let stepTexts = Array(repeating: stepText, count: typedStepCount)
            var claim: [String: Any] = [
                "text_zh": "原文直接给出编号公式 \(equation.label)。",
                "equation_id": equation.equationID,
                "formula_tex": formulaTeX ?? equation.tex,
                "derivation_steps": stepTexts,
                "epistemic_status": "direct",
                "evidence_ids": [equation.evidenceID]
            ]
            if includeConclusion {
                claim["conclusion_zh"] = typedConclusion ?? "该片段给出 \(equation.label) 的受限定义。"
            }
            var segment: [String: Any] = ["index": segmentIndex, "is_final": segmentIsFinal]
            if let continuationSummary { segment["continuation_summary"] = continuationSummary }
            claim["derivation_segment"] = segment
            if includeTypedSteps {
                claim["derivation_step_contract"] = stepTexts.enumerated().map { offset, text in
                    let ordinal = typedStepOrdinal + offset
                    return [
                        "step_id": "\(equation.equationID):step:\(ordinal)",
                        "ordinal": ordinal,
                        "text_zh": text,
                        "before_tex": typedStepBeforeTeX ?? equation.tex,
                        "after_tex": typedStepAfterTeX ?? equation.tex,
                        "rule_or_assumption": "读取原式，不主张额外的代数等价。",
                        "referenced_equation_ids": [],
                        "evidence_anchor_ids": [equation.evidenceID],
                        "source_document_hashes": [source.documentHash],
                        "epistemic_status": typedStepStatus
                    ] as [String: Any]
                }
            }
            return claim
        } : []
        let envelope: [String: Any] = [
            "schema_version": PaperInsightV2Validator.schemaVersion,
            "source_scope": PaperInsightV2Validator.sourceScope,
            "title_zh": "格点测试",
            "abstract_zh": "受限摘要",
            "physics": [
                "research_question": ["text_zh": "论文给出一个受限的研究问题", "epistemic_status": "direct", "evidence_ids": [anchorID]],
                "method_and_data_flow": [],
                "main_results": [],
                "important_formula_derivations": formulas,
                "reasonable_inferences": [],
                "missing_information": [],
                "caveats": []
            ],
            "important_figures": [],
            "terminology": []
        ]
        let data = try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func fixtureEvidenceSettings() -> LLMSettings {
        LLMSettings(
            profiles: ["openAI": ProviderProfile(baseURL: "https://example.test/v1", selectedModel: "fixture", usesStreaming: false)],
            automaticAnalysis: false,
            mode: .fast,
            detailLevel: .standard,
            maximumFigures: 0
        )
    }

    private func makeProjectLocalTemporaryDirectory() throws -> URL {
        try makeProjectLocalTestDirectory(prefix: "evidence")
    }
}

private final class FixturePDFURLProtocol: URLProtocol, @unchecked Sendable {
    private static let payload = FixturePDFData.makeTwoPageTextPDF()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "fixture.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/pdf"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private enum FixturePDFData {
    static func makeTwoPageTextPDF() -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { fatalError("无法创建本地 PDF fixture consumer") }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { fatalError("无法创建本地 PDF fixture") }
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let pages = [
            "Abstract\\nThe renormalization scale is 2 GeV.",
            "Methods\\nThe lattice volume is 32^3 x 64."
        ]
        for pageText in pages {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 42, y: 740)
            context.scaleBy(x: 1, y: -1)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: pageText,
                attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
            ))
            CTLineDraw(line, context)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

private actor EvidenceMockClient: LLMCompleting {
    private var responses: [String]
    private var count = 0
    private let responseDelay: Duration

    init(responses: [String], responseDelay: Duration = .zero) {
        self.responses = responses
        self.responseDelay = responseDelay
    }

    func complete(system: String, userPayload: String, profile: ProviderProfile, apiKey: String, maximumResponseBytes: Int,
                  onTransportState: @escaping @Sendable (LLMTransportState) async -> Void,
                  onDelta: @escaping @Sendable (String) async -> Void) async throws -> String {
        count += 1
        await onTransportState(.connected)
        await onTransportState(.waitingFirstContent)
        if responseDelay != .zero { try await Task.sleep(for: responseDelay) }
        guard !responses.isEmpty else { throw LLMClientError.invalidResponse }
        let response = responses.removeFirst()
        await onDelta(response)
        return response
    }

    func requestCount() -> Int { count }
}

private actor FailOnceFormulaValidationStore: FormulaJobStoring {
    private var jobs: [String: FormulaDerivationCheckpoint] = [:]
    private var reports: [String: FormulaCoverageReport] = [:]
    private var shouldFailValidationSave = true

    func formulaJob(id: String) -> FormulaDerivationCheckpoint? { jobs[id] }

    func saveFormulaJob(_ checkpoint: FormulaDerivationCheckpoint) {
        jobs[checkpoint.job.jobID] = checkpoint
        if checkpoint.job.state != .complete { reports.removeValue(forKey: checkpoint.job.jobID) }
    }

    func saveFormulaJobWithValidation(_ checkpoint: FormulaDerivationCheckpoint,
                                     report: FormulaCoverageReport) throws {
        if shouldFailValidationSave {
            shouldFailValidationSave = false
            throw LatticeLensError.persistenceUnavailable("synthetic one-shot validation-receipt write failure")
        }
        jobs[checkpoint.job.jobID] = checkpoint
        reports[checkpoint.job.jobID] = report
    }

    func formulaValidationReport(jobID: String) -> FormulaCoverageReport? { reports[jobID] }
}

private struct FixtureVisionLoader: VisionImageLoading {
    func load(figure: PaperFigure) async throws -> VisionInputImage {
        VisionInputImage(figureKey: figure.key, originalHash: "hash-\(figure.key)", mimeType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]))
    }
}

private actor VisionMockClient: VisionCompleting {
    private let response: String
    private var count = 0
    init(response: String) { self.response = response }
    func completeVision(system: String, userPayload: String, images: [VisionInputImage], profile: ProviderProfile, apiKey: String,
                        maximumResponseBytes: Int, onTransportState: @escaping @Sendable (LLMTransportState) async -> Void,
                        onDelta: @escaping @Sendable (String) async -> Void) async throws -> String {
        count += 1
        await onTransportState(.waitingFirstContent)
        await onDelta(response)
        return response
    }
    func requestCount() -> Int { count }
}

private actor DelayedEvidenceClient: LLMCompleting {
    private var count = 0

    func complete(system: String, userPayload: String, profile: ProviderProfile, apiKey: String, maximumResponseBytes: Int,
                  onTransportState: @escaping @Sendable (LLMTransportState) async -> Void,
                  onDelta: @escaping @Sendable (String) async -> Void) async throws -> String {
        count += 1
        try await Task.sleep(for: .milliseconds(100))
        return "{}"
    }

    func requestCount() -> Int { count }
}

private enum SlowLLMRequestMode {
    case noHeaders
    case headersWithoutContent
}

private final class SlowLLMRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var mode = SlowLLMRequestMode.noHeaders
    private var requests = 0
    private var stops = 0
    private var requestTimeout: TimeInterval?
    private var method: String?

    func reset(mode: SlowLLMRequestMode) {
        lock.lock()
        defer { lock.unlock() }
        self.mode = mode
        requests = 0
        stops = 0
        requestTimeout = nil
        method = nil
    }

    func beginRequest(timeout: TimeInterval, method: String?) -> SlowLLMRequestMode {
        lock.lock()
        defer { lock.unlock() }
        requests += 1
        requestTimeout = timeout
        self.method = method
        return mode
    }

    func recordStop() {
        lock.lock()
        defer { lock.unlock() }
        stops += 1
    }

    func metrics() -> (requests: Int, stops: Int, requestTimeout: TimeInterval?, method: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (requests, stops, requestTimeout, method)
    }
}

private final class SlowEvidenceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let recorder = SlowLLMRequestRecorder()

    static func reset(mode: SlowLLMRequestMode) { recorder.reset(mode: mode) }
    static func metrics() -> (requests: Int, stops: Int, requestTimeout: TimeInterval?, method: String?) { recorder.metrics() }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "fixture.invalid" && request.url?.path == "/v1/chat/completions"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.recorder.beginRequest(timeout: request.timeoutInterval, method: request.httpMethod) {
        case .noHeaders:
            return
        case .headersWithoutContent:
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": "text/event-stream"]) else {
                client?.urlProtocol(self, didFailWithError: LLMClientError.invalidResponse)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
    }

    override func stopLoading() { Self.recorder.recordStop() }
}

private struct EvidenceFormulaDeadlineRequestRecord: Sendable {
    let method: String?
    let requestTimeout: TimeInterval
    let systemPrompt: String?
}

private struct EvidenceFormulaDeadlineMetrics: Sendable {
    let requests: [EvidenceFormulaDeadlineRequestRecord]
    let stoppedRequestIndices: Set<Int>
}

private final class EvidenceFormulaDeadlineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var proseResponse = ""
    private var requests = [EvidenceFormulaDeadlineRequestRecord]()
    private var stoppedRequestIndices = Set<Int>()

    func reset(proseResponse: String) {
        lock.lock()
        defer { lock.unlock() }
        self.proseResponse = proseResponse
        requests.removeAll(keepingCapacity: true)
        stoppedRequestIndices.removeAll(keepingCapacity: true)
    }

    func beginRequest(_ request: URLRequest) -> (index: Int, proseResponse: String) {
        let systemPrompt = Self.systemPrompt(in: request)
        lock.lock()
        defer { lock.unlock() }
        requests.append(EvidenceFormulaDeadlineRequestRecord(
            method: request.httpMethod,
            requestTimeout: request.timeoutInterval,
            systemPrompt: systemPrompt
        ))
        return (requests.count, proseResponse)
    }

    func recordStop(requestIndex: Int?) {
        guard let requestIndex else { return }
        lock.lock()
        defer { lock.unlock() }
        stoppedRequestIndices.insert(requestIndex)
    }

    func metrics() -> EvidenceFormulaDeadlineMetrics {
        lock.lock()
        defer { lock.unlock() }
        return EvidenceFormulaDeadlineMetrics(requests: requests, stoppedRequestIndices: stoppedRequestIndices)
    }

    private static func systemPrompt(in request: URLRequest) -> String? {
        guard let body = requestBody(from: request),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]] else { return nil }
        return messages.first(where: { $0["role"] as? String == "system" })?["content"] as? String
    }

    private static func requestBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { pointer in
                guard let baseAddress = pointer.baseAddress else { return 0 }
                return stream.read(baseAddress, maxLength: pointer.count)
            }
            if count < 0 { return nil }
            if count == 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body.isEmpty ? nil : body
    }
}

private final class EvidenceFormulaDeadlineURLProtocol: URLProtocol, @unchecked Sendable {
    private static let recorder = EvidenceFormulaDeadlineRecorder()
    private let requestIndexLock = NSLock()
    private var activeRequestIndex: Int?

    static func reset(proseResponse: String) { recorder.reset(proseResponse: proseResponse) }
    static func metrics() -> EvidenceFormulaDeadlineMetrics { recorder.metrics() }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "fixture.invalid" && request.url?.path == "/v1/chat/completions"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let ticket = Self.recorder.beginRequest(request)
        requestIndexLock.lock()
        activeRequestIndex = ticket.index
        requestIndexLock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: LLMClientError.invalidResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        // The first real production request receives valid prose JSON. The
        // subsequent formula request receives headers but deliberately no SSE
        // content, so only its per-request first-content deadline can finish it.
        guard ticket.index == 1 else { return }
        do {
            let payload: [String: Any] = ["choices": [["delta": ["content": ticket.proseResponse]]]]
            let json = try JSONSerialization.data(withJSONObject: payload)
            var eventStream = Data("data: ".utf8)
            eventStream.append(json)
            eventStream.append(Data("\n\ndata: [DONE]\n\n".utf8))
            client?.urlProtocol(self, didLoad: eventStream)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        requestIndexLock.lock()
        let requestIndex = activeRequestIndex
        requestIndexLock.unlock()
        Self.recorder.recordStop(requestIndex: requestIndex)
    }
}

private actor DelayedVisionClient: VisionCompleting {
    private var count = 0

    func completeVision(system: String, userPayload: String, images: [VisionInputImage], profile: ProviderProfile, apiKey: String,
                        maximumResponseBytes: Int, onTransportState: @escaping @Sendable (LLMTransportState) async -> Void,
                        onDelta: @escaping @Sendable (String) async -> Void) async throws -> String {
        count += 1
        try await Task.sleep(for: .milliseconds(100))
        return "{}"
    }

    func requestCount() -> Int { count }
}

private struct FixtureBibTeXRequester: BibTeXRequesting {
    func fetchBibTeX(at url: URL) async throws -> BibTeXHTTPResponse {
        BibTeXHTTPResponse(data: Data("@article{fixture, title={A fixture}}".utf8), statusCode: 200,
                           finalURL: url, contentType: "application/x-bibtex")
    }
}

private struct FailingBibTeXRequester: BibTeXRequesting {
    func fetchBibTeX(at url: URL) async throws -> BibTeXHTTPResponse {
        BibTeXHTTPResponse(data: Data("endpoint failure".utf8), statusCode: 503, finalURL: url, contentType: "text/plain")
    }
}
