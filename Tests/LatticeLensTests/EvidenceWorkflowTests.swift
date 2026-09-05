import Foundation
import CoreGraphics
import CoreText
import XCTest
@testable import LatticeLens

final class EvidenceWorkflowTests: XCTestCase {
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

    func testAppFixtureDownloaderProducesExtractablePDFAndEvidenceResponse() async throws {
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

        let paper = Paper(literatureID: 1234567, titles: [PaperTitle(value: "fixture full text", source: "fixture")],
                          abstracts: [PaperAbstract(value: "fixture abstract", source: "fixture")], preprintDate: nil,
                          earliestDate: nil, arxivID: nil, arxivCategories: ["hep-lat"], doi: nil, citationCount: nil,
                          publicationStatus: nil, updated: nil, figures: [], firstSeenAt: Date(), isRead: false)
        _ = try await store.upsert(papers: [paper], for: 21)
        let workflow = EvidenceInsightWorkflow(store: store, client: AppFixtureLLMClient())
        let settings = LLMSettings(profiles: ["openAI": ProviderProfile(baseURL: "https://fixture.invalid/v1", manualModel: "fixture-text-model")],
                                   automaticAnalysis: false, mode: .fast, maximumFigures: 0)
        let artifact = try await workflow.generate(for: paper, settings: settings, apiKey: "fixture") { _ in }
        XCTAssertEqual(artifact.insight.sourceScope, PaperInsightV2Validator.sourceScope)
        XCTAssertFalse(artifact.insight.physics.mainResults.isEmpty)
        XCTAssertEqual(artifact.insight.physics.importantFormulaDerivations.count, 1)
        XCTAssertTrue(artifact.insight.physics.importantFormulaDerivations[0].textZH.contains("0.09"))
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

    func testEvidenceValidatorFailsClosedForUnknownAnchorAndMissingWithAnchor() throws {
        let source = makeEvidencePayload()
        let valid = validInsightJSON(anchorID: source.anchors[0].id)
        XCTAssertNoThrow(try PaperInsightV2Validator.decode(Data(valid.utf8), source: source, maximumFigures: 0))
        XCTAssertThrowsError(try PaperInsightV2Validator.decode(Data(valid.replacingOccurrences(of: source.anchors[0].id, with: "pdf:p9:q9:outside").utf8), source: source, maximumFigures: 0))
        let missingWithAnchor = valid.replacingOccurrences(of: "\"missing_information\":[{\"text_zh\":\"缺少体积\",\"epistemic_status\":\"missing\",\"evidence_ids\":[]}]", with: "\"missing_information\":[{\"text_zh\":\"缺少体积\",\"epistemic_status\":\"missing\",\"evidence_ids\":[\"\(source.anchors[0].id)\"]}]")
        XCTAssertThrowsError(try PaperInsightV2Validator.decode(Data(missingWithAnchor.utf8), source: source, maximumFigures: 0))
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
        XCTAssertEqual(insight.physics.researchQuestion.textZH, "模型未将研究问题返回为可回查对象；未采纳未锚定的原始文本。")
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
        XCTAssertThrowsError(try PaperInsightV2Validator.decode(Data(validInsightJSON(anchorID: original.id).utf8), source: malformedDocument, maximumFigures: 0))
    }

    func testEvidenceWorkflowValidatesSavesAndHitsIsolatedCache() async throws {
        let paper = fixturePaper()
        let store = InMemoryLibraryStore()
        _ = try await store.upsert(papers: [paper], for: 21)
        let document = fixtureDocument()
        let chunk = fixtureChunk(document: document)
        let pdfAnchor = fixturePDFAnchor(chunk: chunk)
        try await store.saveFullText(document: document, chunks: [chunk], anchors: [pdfAnchor])
        try await store.saveEvidenceAnchors(EvidenceAnchorFactory.metadataAnchors(for: paper))
        let response = validInsightJSON(anchorID: pdfAnchor.id)
        let client = EvidenceMockClient(responses: [response])
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
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(saved, first)

        let changed = EvidenceInsightCacheKey(paperID: paper.literatureID, paperUpdated: paper.updated, documentHash: document.sha256,
                                              chunkIDs: [chunk.id], promptVersion: EvidenceInsightPrompt.version,
                                              schemaVersion: PaperInsightV2Validator.schemaVersion, sourceScope: PaperInsightV2Validator.sourceScope,
                                              provider: "openAI", normalizedBaseURL: "https://example.test/v1", model: "fixture", credentialRevision: 0,
                                              mode: .fast, detailLevel: .standard, maximumFigures: 3, terminologyHash: StableHash.sha256(""),
                                              providerCapabilityHash: StableHash.sha256("stream=false|vision=false"))
        XCTAssertNotEqual(first.cacheKey, changed.value)
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
        let document = fixtureDocument()
        let chunk = fixtureChunk(document: document)
        let anchor = fixturePDFAnchor(chunk: chunk)
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

    private func fixturePDFAnchor(chunk: EvidenceChunk) -> EvidenceAnchor {
        EvidenceAnchor(id: chunk.id, paperID: chunk.paperID, sourceKind: .pdf, page: chunk.page, section: chunk.section,
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

    init(responses: [String]) { self.responses = responses }

    func complete(system: String, userPayload: String, profile: ProviderProfile, apiKey: String, maximumResponseBytes: Int,
                  onTransportState: @escaping @Sendable (LLMTransportState) async -> Void,
                  onDelta: @escaping @Sendable (String) async -> Void) async throws -> String {
        count += 1
        await onTransportState(.waitingFirstContent)
        guard !responses.isEmpty else { throw LLMClientError.invalidResponse }
        let response = responses.removeFirst()
        await onDelta(response)
        return response
    }

    func requestCount() -> Int { count }
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
