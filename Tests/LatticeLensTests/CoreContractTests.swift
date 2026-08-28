import XCTest
@testable import LatticeLens

final class CoreContractTests: XCTestCase {
    func testFixtureLaunchConfigurationFailsClosedForProductionAndProtectsXCTestStoreRoot() {
        XCTAssertFalse(AppLaunchConfiguration.usesFixtureDependencies(environment: [:], arguments: []))
        XCTAssertTrue(AppLaunchConfiguration.usesFixtureDependencies(
            environment: ["LATTICELENS_USE_FIXTURES": "1"], arguments: []
        ))
        XCTAssertTrue(AppLaunchConfiguration.usesFixtureDependencies(
            environment: [:], arguments: ["LatticeLens", "-LatticeLensUseFixtures", "YES"]
        ))
        XCTAssertTrue(AppLaunchConfiguration.usesFixtureDependencies(
            environment: [:], arguments: [], argumentDomain: ["LatticeLensUseFixtures": "YES"]
        ))
        XCTAssertTrue(AppLaunchConfiguration.usesFixtureDependencies(
            environment: ["LATTICELENS_TEST_STORE_ROOT": "/tmp/latticelens-ui-test"], arguments: []
        ))
        XCTAssertFalse(AppLaunchConfiguration.usesFixtureDependencies(
            environment: ["LATTICELENS_TEST_STORE_ROOT": "relative-test-root"], arguments: []
        ))
    }

    @MainActor
    func testUIFixtureNeverUsesInjectedPersistentKeychain() {
        let persistentKeychain = RecordingKeychain()
        let viewModel = AppViewModel(keychain: persistentKeychain, useFixtureDependencies: true)
        let revisionBeforeClear = viewModel.settings.credentialRevision
        var values = viewModel.settings
        values.automaticAnalysis = false
        viewModel.saveSettings(values, apiKey: "fixture-only-key")
        XCTAssertTrue(viewModel.apiKeyIsSaved(for: .openAI))
        XCTAssertTrue(viewModel.clearAPIKey(for: .openAI))
        XCTAssertFalse(viewModel.apiKeyIsSaved(for: .openAI), "fixture Keychain 删除必须立即反映为未保存")
        XCTAssertEqual(viewModel.settings.credentialRevision, revisionBeforeClear + 2,
                       "成功保存和成功清除都必须通过完整 settings value 更新发布新的 credential revision")
        XCTAssertEqual(persistentKeychain.operationCount, 0)
    }

    @MainActor
    func testUIFixtureModelDiscoveryIsProcessLocal() async throws {
        let viewModel = AppViewModel(useFixtureDependencies: true)
        XCTAssertTrue(viewModel.apiKeyIsSaved(for: .openAI), "fixture 可有进程内测试 key，但不得读取真实 Keychain")
        let models = try await viewModel.discoverModels(profile: viewModel.settings.activeProfile, provider: .openAI)
        XCTAssertEqual(models, ["fixture-text-model"])
    }

    func testUIFixtureFullTextAndVisionDependenciesAreAllowlistedAndOffline() async throws {
        let downloader = AppFixtureFullTextDownloader()
        let allowedURL = try XCTUnwrap(URL(string: "https://fixture.invalid/fulltext/1234567.pdf"))
        let allowed = try await downloader.download(
            request: URLRequest(url: allowedURL),
            maximumBytes: FullTextService.maximumBytes
        )
        XCTAssertEqual(allowed.response.value(forHTTPHeaderField: "Content-Type"), "application/pdf")
        XCTAssertGreaterThan(allowed.data.count, 100)

        let sharedFixtureURL = try XCTUnwrap(URL(string: "https://fixture.invalid/fulltext/1234568.pdf"))
        let shared = try await downloader.download(
            request: URLRequest(url: sharedFixtureURL),
            maximumBytes: FullTextService.maximumBytes
        )
        XCTAssertEqual(StableHash.sha256(shared.data), StableHash.sha256(allowed.data),
                       "两个 fixture paper 必须使用相同 bytes 以测试 content-addressed shared PDF lifecycle")

        let rejectedURL = try XCTUnwrap(URL(string: "https://fixture.invalid/other.pdf"))
        await XCTAssertThrowsErrorAsync {
            _ = try await downloader.download(request: URLRequest(url: rejectedURL), maximumBytes: FullTextService.maximumBytes)
        }

        let figure = PaperFigure(key: "fig-fixture-local", url: URL(string: "https://fixture.invalid/figures/1234567.jpg"),
                                 label: "fixture", caption: "fixture", source: "fixture", filename: "fixture.jpg")
        let image = try await AppFixtureVisionImageLoader().load(figure: figure)
        XCTAssertEqual(image.figureKey, figure.key)
        XCTAssertEqual(image.mimeType, "image/jpeg")
        XCTAssertGreaterThan(image.byteCount, 0)

        let rejectedFigure = PaperFigure(key: "fig-fixture-local", url: URL(string: "https://example.invalid/figure.jpg"),
                                         label: "fixture", caption: "fixture", source: "fixture", filename: "fixture.jpg")
        await XCTAssertThrowsErrorAsync { _ = try await AppFixtureVisionImageLoader().load(figure: rejectedFigure) }
    }

    @MainActor
    func testModelDiscoveryUsesSavedKeychainKeyForTheSelectedProvider() async throws {
        let keychain = FixedKeychain(value: "saved-provider-key")
        let discoverer = ModelDiscovererSpy()
        let viewModel = AppViewModel(keychain: keychain, modelDiscoverer: discoverer, useFixtureDependencies: false)

        let models = try await viewModel.discoverModels(profile: viewModel.settings.activeProfile, provider: .openAI)

        XCTAssertEqual(models, ["model-from-saved-key"])
        let provider = await discoverer.lastProvider
        let apiKey = await discoverer.lastAPIKey
        XCTAssertEqual(provider, .openAI)
        XCTAssertEqual(apiKey, "saved-provider-key")
    }

    func testHIndexThresholdIsStrictAndSelfIsAlwaysVisible() {
        let rejected = hIndex(author: 9, all: 20)
        let qualified = hIndex(author: 10, all: 21)
        XCTAssertFalse(rejected.isQualified)
        XCTAssertTrue(qualified.isQualified)

        var ordinary = author(recid: 9, name: "Aoki, Sinya")
        ordinary.hIndex = rejected
        ordinary.hIndexState = .rejected
        XCTAssertFalse(ordinary.isVisibleInQualifiedList)

        var selfAuthor = author(recid: ProductContract.selfAuthorRecid, name: "Zhao, Dian-Jun")
        selfAuthor.hIndexState = .unknown
        XCTAssertTrue(selfAuthor.isVisibleInQualifiedList)
    }

    func testNameSearchNormalizesDiacriticsHyphenAndNativeName() {
        let candidate = Author(recid: 3, preferredName: "Álvarez, Ana-Maria", nativeNames: ["阿娜"], bai: "A.Alvarez.1",
                               arxivCategories: ["hep-lat"], hIndex: nil, hIndexState: .unknown, isTracked: false, lastSyncedAt: nil)
        XCTAssertTrue(candidate.matches(search: "alvarez ana maria"))
        XCTAssertTrue(candidate.matches(search: "阿娜"))
        XCTAssertTrue(candidate.matches(search: "a.alvarez"))
        XCTAssertEqual(candidate.sectionKey, "A")
    }

    func testHIndexFixtureMapsAllAndPublished() throws {
        let payload = try JSONDecoder().decode(JSONValue.self, from: fixtureData("h-index"))
        let snapshot = try InspireMapper.hIndex(from: payload, authorRecid: 21, query: "authors.recid:21", now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(snapshot.all, 21)
        XCTAssertEqual(snapshot.published, 19)
        XCTAssertFalse(snapshot.excludesSelfCitations)
    }

    func testAuthorPaginationFollowsTrustedNextWithoutDuplicates() async throws {
        let slashTerminatedNext = try String(decoding: fixtureData("authors-page-1"), as: UTF8.self)
            .replacingOccurrences(of: "/api/authors?page=2", with: "/api/authors/?page=2")
        let transport = SequentialTransport([Data(slashTerminatedNext.utf8), try fixtureData("authors-page-2")])
        let client = InspireClient(transport: transport)
        let first = try await client.authorCandidatesPage()
        let second = try await client.authorCandidatesPage(nextURL: first.nextURL)
        XCTAssertEqual(first.authors.map(\.recid), [2_010_363, 21])
        XCTAssertEqual(second.authors.map(\.recid), [22])
        XCTAssertEqual(first.total, 3)
        XCTAssertNil(second.nextURL)
    }

    func testLiteratureDetailUsesSingleRecordShapeAndMapsMetadata() async throws {
        let payload = Data("""
        {"id":123,"updated":"2026-08-23T00:00:00Z","metadata":{"titles":[{"title":"Detail lattice paper","source":"fixture"}],"abstracts":[{"value":"A local detail fixture.","source":"fixture"}],"arxiv_eprints":[{"value":"2608.00123","categories":["hep-lat"]}],"citation_count":7,"authors":[{"recid":8,"full_name":"Author, First"}],"documents":[{"key":"paper.pdf","url":"https://inspirehep.net/files/paper.pdf","fulltext":true}]}}
        """.utf8)
        let client = InspireClient(transport: SequentialTransport([payload]))

        let paper = try await client.literatureDetail(for: 123, now: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(paper.literatureID, 123)
        XCTAssertEqual(paper.displayTitle, "Detail lattice paper")
        XCTAssertEqual(paper.contributors.map(\.fullName), ["Author, First"])
        XCTAssertEqual(paper.documents.first?.isFullText, true)
    }

    func testLocalMarkdownTeXPreservesRawSourceAndUsesOnlyNativePreview() {
        let source = "before $\\alpha$ then $$\\frac{a}{b}$$ after"
        XCTAssertEqual(LocalMarkdownTeX.segments(in: source), [
            .markdown("before "),
            .inlineTeX("\\alpha"),
            .markdown(" then "),
            .displayTeX("\\frac{a}{b}"),
            .markdown(" after")
        ])
        XCTAssertEqual(LocalMarkdownTeX.nativeTeXPreview("\\alpha + \\frac{a}{b}"), "α + (a)/(b)")
        XCTAssertEqual(LocalMarkdownTeX.segments(in: "price \\$100"), [.markdown("price \\$100")])
    }

    func testInspireGETRetriesOnlyBoundedRetryableResponsesAndHonorsRetryAfter() async throws {
        let transport = ScriptedHTTPTransport([
            .init(data: Data("busy".utf8), statusCode: 503, headers: ["Retry-After": "1"]),
            .init(data: try fixtureData("authors-page-1"), statusCode: 200, headers: nil)
        ])
        let delays = RetryDelayRecorder()
        let client = InspireClient(transport: transport, retrySleeper: { delay in await delays.append(delay) })

        let page = try await client.authorCandidatesPage()

        XCTAssertEqual(page.total, 3)
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 2)
        let observed = await delays.values
        XCTAssertEqual(observed, [.seconds(1)])
    }

    func testInspireGETRejectsOversizedResponseWithoutRetryingPayload() async throws {
        let transport = ScriptedHTTPTransport([
            .init(data: Data(repeating: 0x7B, count: 32), statusCode: 200, headers: nil)
        ])
        let client = InspireClient(transport: transport, maximumResponseBytes: 16)

        do {
            _ = try await client.authorCandidatesPage()
            XCTFail("超过本地响应上限的 INSPIRE payload 必须被拒绝")
        } catch {}
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testInspireConditionalGETUsesETagAndSafelyReusesCachedBodyOn304() async throws {
        let transport = ScriptedHTTPTransport([
            .init(data: try fixtureData("authors-page-1"), statusCode: 200, headers: ["ETag": "\"fixture-v1\""]),
            .init(data: Data(), statusCode: 304, headers: nil)
        ])
        let client = InspireClient(transport: transport)

        let first = try await client.authorCandidatesPage()
        let second = try await client.authorCandidatesPage()

        XCTAssertEqual(first.authors.map(\.recid), second.authors.map(\.recid))
        let firstETag = await transport.header(at: 0, named: "If-None-Match")
        let secondETag = await transport.header(at: 1, named: "If-None-Match")
        XCTAssertEqual(firstETag, nil)
        XCTAssertEqual(secondETag, "\"fixture-v1\"")
    }

    func testInspireConditionalGETRejectsBodyless304WithoutPriorValidatedCache() async throws {
        let transport = ScriptedHTTPTransport([.init(data: Data(), statusCode: 304, headers: nil)])
        let client = InspireClient(transport: transport)

        await XCTAssertThrowsErrorAsync { _ = try await client.authorCandidatesPage() }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testRetryAfterHTTPDateIsParsedWithinTheBoundedBudget() throws {
        let url = try XCTUnwrap(URL(string: "https://inspirehep.net/api/authors"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil,
                                                       headerFields: ["Retry-After": "Thu, 01 Jan 2026 00:00:05 GMT"]))
        let delay = InspireClient.retryDelay(response: response, attempt: 1, now: Date(timeIntervalSince1970: 1_767_225_600))
        XCTAssertEqual(delay, .seconds(5))

        let stale = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil,
                                                    headerFields: ["Retry-After": "Thu, 01 Jan 2026 00:00:00 GMT"]))
        XCTAssertEqual(InspireClient.retryDelay(response: stale, attempt: 1, now: Date(timeIntervalSince1970: 1_767_225_600)), .zero)
    }

    func testPaperUpsertIsRecordIDBasedAndPreservesFirstSeen() async throws {
        let hit = try JSONDecoder().decode(InspireSearchPage<InspireLiteratureHit>.self, from: fixtureData("literature-page")).hits.hits[0]
        let first = try InspireMapper.paper(from: hit, now: Date(timeIntervalSince1970: 100))
        var refreshed = try InspireMapper.paper(from: hit, now: Date(timeIntervalSince1970: 200))
        refreshed.citationCount = 5
        let store = InMemoryLibraryStore()
        _ = try await store.upsert(papers: [first], for: 21)
        _ = try await store.upsert(papers: [refreshed], for: 21)
        let value = await store.snapshot()
        XCTAssertEqual(value.papers.count, 1)
        XCTAssertEqual(value.papers[first.literatureID]?.citationCount, 5)
        XCTAssertEqual(value.papers[first.literatureID]?.firstSeenAt, first.firstSeenAt)
    }

    func testInsightValidatorFailsClosedForUnknownFigureAndDuplicateKey() throws {
        let source = insightSource()
        let valid = """
        {"schema_version":"paper-insight-v1","source_scope":"title_abstract_figure_captions","title_zh":"标题","abstract_zh":"摘要","physics":{"research_question":"问题","background":"背景","method_and_data_flow":["相关函数"],"main_results":["摘要未给出数值结论"],"lattice_conventions_reported":[],"missing_information":["体积"],"caveats":["仅摘要级"]},"important_figures":[{"figure_key":"fig1","caption_zh":"图","why_important":"caption 支持","evidence_mode":"caption_only"}],"terminology":[]}
        """
        XCTAssertNoThrow(try PaperInsightValidator.decode(Data(valid.utf8), source: source, maximumFigures: 3))

        let unknown = valid.replacingOccurrences(of: "\"fig1\"", with: "\"outside\"")
        XCTAssertThrowsError(try PaperInsightValidator.decode(Data(unknown.utf8), source: source, maximumFigures: 3))

        let duplicate = valid.replacingOccurrences(of: "\"title_zh\":\"标题\"", with: "\"title_zh\":\"标题\",\"title_zh\":\"重复\"")
        XCTAssertThrowsError(try PaperInsightValidator.decode(Data(duplicate.utf8), source: source, maximumFigures: 3))
    }

    func testInsightValidatorRejectsTrailingControlOverlongAndUnanchoredNumericClaims() throws {
        let paper = Paper(literatureID: 8, titles: [PaperTitle(value: "A 2024 study", source: "fixture")],
                          abstracts: [PaperAbstract(value: "The record was deposited in 2024.", source: "fixture")],
                          preprintDate: nil, earliestDate: nil, arxivID: nil, arxivCategories: [], doi: nil,
                          citationCount: nil, publicationStatus: nil, updated: nil, figures: [], firstSeenAt: Date(), isRead: false)
        let source = InsightSourcePayload(paper: paper)
        let valid = strictInsightJSON()
        XCTAssertNoThrow(try PaperInsightValidator.decode(Data(valid.utf8), source: source, maximumFigures: 0))

        let trailing = valid + " trailing"
        XCTAssertThrowsError(try PaperInsightValidator.decode(Data(trailing.utf8), source: source, maximumFigures: 0))

        let control = valid.replacingOccurrences(of: "标题", with: "标\u{0001}题")
        XCTAssertThrowsError(try PaperInsightValidator.decode(Data(control.utf8), source: source, maximumFigures: 0))

        let tooLongTitle = String(repeating: "甲", count: 16_001)
        let overlong = valid.replacingOccurrences(of: "\"title_zh\":\"标题\"", with: "\"title_zh\":\"\(tooLongTitle)\"")
        XCTAssertThrowsError(try PaperInsightValidator.decode(Data(overlong.utf8), source: source, maximumFigures: 0))

        let numeric = valid.replacingOccurrences(of: "主要结论", with: "主要结论为 2")
        XCTAssertThrowsError(try PaperInsightValidator.decode(Data(numeric.utf8), source: source, maximumFigures: 0),
                             "数值 2 不能被 source 中的 2024 误锚定")
    }

    func testTitleOnlyTranslationAndCacheKeyAreStrictlyScoped() throws {
        XCTAssertEqual(try PaperInsightPrompt.decodeTitleTranslation(Data("{\"title_zh\":\"标题\"}".utf8)), "标题")
        XCTAssertThrowsError(try PaperInsightPrompt.decodeTitleTranslation(Data("{\"title_zh\":\"标题\",\"extra\":\"x\"}".utf8)))

        let baseline = InsightCacheKey(paperID: 1, paperUpdated: nil, promptVersion: "p", insightSchemaVersion: "s",
                                       sourceScope: "title_abstract_figure_captions", provider: "openAI", normalizedBaseURL: "https://example.test/v1",
                                       model: "m", credentialRevision: 1, mode: .fast, detailLevel: .standard, figureSetHash: "f",
                                       maximumFigures: 3, terminologyHash: "t", providerCapabilityHash: "stream=true|vision=false")
        let changedScope = InsightCacheKey(paperID: 1, paperUpdated: nil, promptVersion: "p", insightSchemaVersion: "s",
                                           sourceScope: "fulltext_with_anchors", provider: "openAI", normalizedBaseURL: "https://example.test/v1",
                                           model: "m", credentialRevision: 1, mode: .fast, detailLevel: .standard, figureSetHash: "f",
                                           maximumFigures: 3, terminologyHash: "t", providerCapabilityHash: "stream=true|vision=false")
        let changedCapability = InsightCacheKey(paperID: 1, paperUpdated: nil, promptVersion: "p", insightSchemaVersion: "s",
                                                sourceScope: "title_abstract_figure_captions", provider: "openAI", normalizedBaseURL: "https://example.test/v1",
                                                model: "m", credentialRevision: 1, mode: .fast, detailLevel: .standard, figureSetHash: "f",
                                                maximumFigures: 0, terminologyHash: "different", providerCapabilityHash: "stream=true|vision=true")
        XCTAssertNotEqual(baseline.value, changedScope.value)
        XCTAssertNotEqual(baseline.value, changedCapability.value)
    }

    func testEndpointPolicyAndSSEContract() throws {
        XCTAssertThrowsError(try APIEndpointBuilder.normalizedBaseURL(from: "https://u:p@example.test/v1"))
        XCTAssertThrowsError(try APIEndpointBuilder.normalizedBaseURL(from: "http://example.test/v1", provider: .localOpenAICompatible))
        XCTAssertThrowsError(try APIEndpointBuilder.normalizedBaseURL(from: "https://Example.TEST/v1/?x=1#frag"))
        XCTAssertEqual(try APIEndpointBuilder.normalizedBaseURL(from: "https://Example.TEST/v1/").absoluteString, "https://example.test/v1")

        var parser = OpenAICompatibleSSEParser()
        let payload = "data: {\"choices\":[{\"delta\":{\"content\":\"格点\"}}]}\r\n\r\ndata: [DONE]\r\n\r\n"
        XCTAssertEqual(try parser.consume(Data(payload.utf8)), ["格点"])
        XCTAssertNoThrow(try parser.finish())
    }

    private func author(recid: Int, name: String) -> Author {
        Author(recid: recid, preferredName: name, nativeNames: [], bai: nil, arxivCategories: ["hep-lat"], hIndex: nil,
               hIndexState: .unknown, isTracked: false, lastSyncedAt: nil)
    }

    private func hIndex(author: Int, all: Int) -> HIndexSnapshot {
        HIndexSnapshot(authorRecid: author, all: all, published: nil, excludesSelfCitations: false, source: "INSPIRE",
                       query: "authors.recid:\(author)", fetchedAt: Date(), rawSchemaHash: "fixture")
    }

    private func insightSource() -> InsightSourcePayload {
        let paper = Paper(literatureID: 5, titles: [PaperTitle(value: "title", source: "fixture")],
                          abstracts: [PaperAbstract(value: "abstract", source: "fixture")], preprintDate: nil, earliestDate: nil,
                          arxivID: nil, arxivCategories: ["hep-lat"], doi: nil, citationCount: nil, publicationStatus: nil,
                          updated: nil, figures: [PaperFigure(key: "fig1", url: nil, label: "Figure 1", caption: "caption", source: "fixture", filename: nil)],
                          firstSeenAt: Date(), isRead: false)
        return InsightSourcePayload(paper: paper)
    }

    private func strictInsightJSON() -> String {
        """
        {"schema_version":"paper-insight-v1","source_scope":"title_abstract_figure_captions","title_zh":"标题","abstract_zh":"摘要","physics":{"research_question":"研究问题","background":"物理背景","method_and_data_flow":["方法"],"main_results":["主要结论"],"lattice_conventions_reported":[],"missing_information":["缺失资料"],"caveats":["摘要级限制"]},"important_figures":[],"terminology":[]}
        """
    }
}

private final class RecordingKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var operations = 0
    var operationCount: Int { lock.lock(); defer { lock.unlock() }; return operations }
    func save(_ value: String, service: String, account: String) throws { lock.lock(); operations += 1; lock.unlock() }
    func read(service: String, account: String) throws -> String? { lock.lock(); operations += 1; lock.unlock(); return nil }
    func delete(service: String, account: String) throws { lock.lock(); operations += 1; lock.unlock() }
}

private final class FixedKeychain: KeychainStoring, @unchecked Sendable {
    private let value: String
    init(value: String) { self.value = value }
    func save(_ value: String, service: String, account: String) throws {}
    func read(service: String, account: String) throws -> String? { value }
    func delete(service: String, account: String) throws {}
}

private actor ModelDiscovererSpy: ModelDiscovering {
    private(set) var lastProvider: LLMProvider?
    private(set) var lastAPIKey: String?

    func discoverModels(profile: ProviderProfile, provider: LLMProvider, apiKey: String) async throws -> [String] {
        lastProvider = provider
        lastAPIKey = apiKey
        return ["model-from-saved-key"]
    }
}

private actor RetryDelayRecorder {
    private(set) var values: [Duration] = []
    func append(_ duration: Duration) { values.append(duration) }
}

private actor ScriptedHTTPTransport: HTTPTransport {
    struct Response: Sendable {
        let data: Data
        let statusCode: Int
        let headers: [String: String]?
    }

    private var responses: [Response]
    private var count = 0
    private var requests: [URLRequest] = []

    init(_ responses: [Response]) { self.responses = responses }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !responses.isEmpty, let url = request.url else { throw LatticeLensError.invalidResponse }
        let next = responses.removeFirst()
        count += 1
        requests.append(request)
        guard let response = HTTPURLResponse(url: url, statusCode: next.statusCode, httpVersion: nil, headerFields: next.headers) else {
            throw LatticeLensError.invalidResponse
        }
        return (next.data, response)
    }

    func requestCount() -> Int { count }
    func header(at index: Int, named name: String) -> String? {
        guard requests.indices.contains(index) else { return nil }
        return requests[index].value(forHTTPHeaderField: name)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error but the operation succeeded", file: file, line: line)
    } catch {}
}
