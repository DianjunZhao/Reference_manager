import Foundation
import SwiftData
import XCTest
@testable import LatticeLens

/// Release-context contracts introduced by the 1.0 plan. These tests exercise
/// policy objects only; they never create a network connection or read a real
/// Keychain/library.
final class V5FinalTests: XCTestCase {
    func testLocalOpenAICompatibleProfileIsDefaultAndKeyOptional() throws {
        let settings = LLMSettings()
        XCTAssertEqual(settings.activeProvider, .localOpenAICompatible)
        XCTAssertEqual(settings.activeProfile.baseURL, "http://127.0.0.1:11434/v1")
        XCTAssertFalse(LLMProvider.localOpenAICompatible.apiKeyIsRequired)
        XCTAssertTrue(LLMProvider.openAI.apiKeyIsRequired)
        XCTAssertTrue(LLMProvider.allCases.contains(.localOpenAICompatible))
    }

    func testLegacySingleOpenAIProfileDoesNotSilentlySwitchToLocal() {
        let legacy = ProviderProfile(baseURL: "https://api.openai.com/v1", manualModel: "legacy-model", supportsVision: true)
        let values = LLMSettings(profiles: [LLMProvider.openAI.rawValue: legacy])
        XCTAssertEqual(values.activeProvider, .openAI)
        XCTAssertEqual(values.activeProfile.effectiveModel, "legacy-model")
    }

    func testOnlyTheExplicitLocalProviderGetsLoopbackHTTP() throws {
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            let url = try APIEndpointBuilder.normalizedBaseURL(from: "http://\(host):11434/v1/", provider: .localOpenAICompatible)
            XCTAssertEqual(url.scheme, "http")
        }
        XCTAssertThrowsError(try APIEndpointBuilder.normalizedBaseURL(from: "http://127.0.0.1/v1", provider: .customOpenAICompatible))
        XCTAssertThrowsError(try APIEndpointBuilder.normalizedBaseURL(from: "http://example.test/v1", provider: .localOpenAICompatible))
        XCTAssertThrowsError(try APIEndpointBuilder.normalizedBaseURL(from: "http://u:p@127.0.0.1/v1", provider: .localOpenAICompatible))
        XCTAssertThrowsError(try APIEndpointBuilder.normalizedBaseURL(from: "http://127.0.0.1/v1?x=1", provider: .localOpenAICompatible))
        XCTAssertThrowsError(try APIEndpointBuilder.normalizedBaseURL(from: "http://127.0.0.1/v1#fragment", provider: .localOpenAICompatible))
    }

    func testLocalNoKeyRequestOmitsAuthorizationButTokenIsStillSupported() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:11434/v1/models"))
        let noKey = OpenAICompatibleClient.authorizedRequest(url: url, apiKey: " ", provider: .localOpenAICompatible)
        XCTAssertNil(noKey.value(forHTTPHeaderField: "Authorization"))
        let withKey = OpenAICompatibleClient.authorizedRequest(url: url, apiKey: "local-token", provider: .localOpenAICompatible)
        XCTAssertEqual(withKey.value(forHTTPHeaderField: "Authorization"), "Bearer local-token")
    }

    @MainActor
    func testLocalNoKeyModelDiscoveryCanReachInjectedDiscoverer() async throws {
        let discoverer = V5Discoverer()
        let viewModel = AppViewModel(keychain: V5EmptyKeychain(), modelDiscoverer: discoverer, useFixtureDependencies: false)
        let profile = ProviderProfile(provider: .localOpenAICompatible, baseURL: "http://127.0.0.1:11434/v1", manualModel: "fixture-local")
        let values = LLMSettings(activeProvider: .localOpenAICompatible, profiles: [LLMProvider.localOpenAICompatible.rawValue: profile])
        viewModel.saveSettings(values, apiKey: nil)
        let models = try await viewModel.discoverModels(profile: viewModel.settings.activeProfile, provider: .localOpenAICompatible)
        XCTAssertEqual(models, ["fixture-local"])
        let receivedKey = await discoverer.apiKey()
        XCTAssertEqual(receivedKey, "")
    }

    func testSavedModelStaysVisibleWhenSearchFiltersDiscovery() {
        let profile = ProviderProfile(provider: .localOpenAICompatible, baseURL: "http://127.0.0.1:11434/v1", selectedModel: "saved-model")
        let values = LLMSettings(activeProvider: .localOpenAICompatible, profiles: [LLMProvider.localOpenAICompatible.rawValue: profile])
        XCTAssertTrue(values.modelOptions(discovered: ["other-model"], query: "saved").contains("saved-model (saved / currently undiscovered)"))
    }

    @MainActor
    func testCancellingSettingsRetiresOnlyTheOwningPresentationBinding() {
        let viewModel = AppViewModel(store: InMemoryLibraryStore(), keychain: V5EmptyKeychain(), useFixtureDependencies: false)
        XCTAssertFalse(viewModel.presentSettings)
        let initialPresentationID = viewModel.settingsPresentationID

        viewModel.openSettings()
        XCTAssertTrue(viewModel.presentSettings)
        XCTAssertNotEqual(viewModel.settingsPresentationID, initialPresentationID,
                          "每次打开 Settings 都必须得到新的 draft presentation identity")

        viewModel.cancelSettings()
        XCTAssertFalse(viewModel.presentSettings,
                       "Cancel 只能撤销 owning sheet binding，不得依赖环境 dismiss 或写入 settings")
    }

    @MainActor
    func testLocalNoKeyConnectionProbeIsSeparateFromModelDiscovery() async throws {
        let tester = V5ConnectionTester()
        let viewModel = AppViewModel(store: InMemoryLibraryStore(), keychain: V5EmptyKeychain(), connectionTester: tester,
                                     useFixtureDependencies: false)
        let profile = ProviderProfile(provider: .localOpenAICompatible, baseURL: "http://127.0.0.1:11434/v1", manualModel: "fixture-local")
        let probe = try await viewModel.testProviderConnection(profile: profile, provider: .localOpenAICompatible)
        let receivedKey = await tester.apiKey()
        let calls = await tester.calls()
        XCTAssertEqual(probe.normalizedEndpoint, "http://127.0.0.1:11434/v1")
        XCTAssertEqual(receivedKey, "")
        XCTAssertEqual(calls, 1)
    }

    func testBlobMutationPlanRetiresOnlyAnUnsharedSupersededBlob() async throws {
        let store = InMemoryLibraryStore()
        let source = try XCTUnwrap(URL(string: "https://fixture.invalid/fulltext/1234567.pdf"))
        let old = FullTextDocument(paperID: 7, sourceURL: source, sourceKind: .arxivPDF,
                                   sha256: "old-hash", byteCount: 3, localFilename: "old-hash.pdf", pageCount: 1,
                                   extractionState: .extracted, downloadedAt: Date(), lastErrorCategory: nil)
        try await store.saveFullText(document: old, chunks: [], anchors: [])
        let replacement = FullTextDocument(paperID: 7, sourceURL: source, sourceKind: .arxivPDF,
                                           sha256: "new-hash", byteCount: 3, localFilename: "new-hash.pdf", pageCount: 1,
                                           extractionState: .extracted, downloadedAt: Date(), lastErrorCategory: nil)
        let plan = try await store.saveFullTextAndPlan(document: replacement, chunks: [], anchors: [])
        XCTAssertEqual(plan.retiredBlobHashes, ["old-hash"])
        XCTAssertEqual(plan.retiredLocalFilenames, ["old-hash.pdf"])
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.contentBlobs["old-hash"]?.referenceCount, 0)
        XCTAssertEqual(snapshot.contentBlobs["new-hash"]?.referenceCount, 1)
    }

    func testGenerationCannotPromoteWhileRetryableIDsRemain() {
        var checkpoint = SyncCheckpoint(jobID: "h", jobKind: "h-index", query: "fixture", nextURL: nil,
                                        pendingIDs: [], retryableIDs: [11, 12, 11])
        XCTAssertFalse(checkpoint.isCompletionEligible)
        XCTAssertEqual(checkpoint.resumableIDs, [11, 12])
        checkpoint.retryableIDs = []
        XCTAssertTrue(checkpoint.isCompletionEligible)
    }

    func testPDFKitSelectionLocatorRequiresOneExactPageOccurrence() {
        let exact = PDFTextSelectionLocator.locate(pageText: "Introduction\nThe lattice spacing is a=0.09 fm.\nConclusion",
                                                    quote: "The lattice spacing is a=0.09 fm.", page: 3)
        XCTAssertEqual(exact?.page, 3)
        XCTAssertEqual(exact?.characterRangeStart, 13)
        XCTAssertEqual(exact?.characterRangeEnd, 46)
        XCTAssertEqual(exact?.quoteHash, StableHash.sha256("The lattice spacing is a=0.09 fm."))
        XCTAssertNil(PDFTextSelectionLocator.locate(pageText: "same quote; same quote", quote: "same quote", page: 1),
                     "ambiguous page text must not get a fuzzy annotation range")
        XCTAssertNil(PDFTextSelectionLocator.locate(pageText: "text", quote: "", page: 1))
    }

    func testCrossPaperPhysicsCellNeedsCurrentContextAndForeignValueAnchor() throws {
        let current = EvidenceAnchor(id: "current", paperID: 11, sourceKind: .abstract, page: nil, section: nil,
                                     quote: "This paper studies the continuum limit.", quoteHash: StableHash.sha256("This paper studies the continuum limit."), figureKey: nil)
        let foreign = EvidenceAnchor(id: "foreign", paperID: 12, sourceKind: .abstract, page: nil, section: nil,
                                     quote: "The measured spacing is a=0.09 fm.", quoteHash: StableHash.sha256("The measured spacing is a=0.09 fm."), figureKey: nil)
        let cell = PhysicsContractCell(id: UUID(), workspaceID: UUID(), rowKey: "lattice_spacing", paperID: 11,
                                       value: "0.09", unit: "fm", status: .crossPaperInference,
                                       evidenceAnchorIDs: [foreign.id], extractionVersion: "physics-contract-v1",
                                       sourceDocumentHash: nil, updatedAt: Date())
        var snapshot = LibrarySnapshot(evidenceAnchors: [current.id: current, foreign.id: foreign])
        XCTAssertThrowsError(try V4PhysicsValidator.validate(cell, snapshot: snapshot))
        var accepted = cell; accepted.evidenceAnchorIDs = [current.id, foreign.id]
        XCTAssertNoThrow(try V4PhysicsValidator.validate(accepted, snapshot: snapshot))
        snapshot.quarantinedEvidenceIDs.insert(foreign.id)
        XCTAssertThrowsError(try V4PhysicsValidator.validate(accepted, snapshot: snapshot))
    }

    func testPhysicsTruthTableDoesNotFabricateCaveatEvidence() throws {
        let current = EvidenceAnchor(id: "current", paperID: 11, sourceKind: .abstract, page: nil, section: nil,
                                     quote: "This paper notes a caveat: a=0.09 fm is preliminary.",
                                     quoteHash: StableHash.sha256("This paper notes a caveat: a=0.09 fm is preliminary."), figureKey: nil)
        let foreign = EvidenceAnchor(id: "foreign", paperID: 12, sourceKind: .abstract, page: nil, section: nil,
                                     quote: "Another paper quotes a=0.09 fm.",
                                     quoteHash: StableHash.sha256("Another paper quotes a=0.09 fm."), figureKey: nil)
        let snapshot = LibrarySnapshot(evidenceAnchors: [current.id: current, foreign.id: foreign])
        let workspaceID = UUID()

        func cell(status: PhysicsCellStatus, value: String? = "0.09", unit: String? = "fm", anchors: [String]) -> PhysicsContractCell {
            PhysicsContractCell(id: UUID(), workspaceID: workspaceID, rowKey: "lattice_spacing", paperID: 11,
                                value: value, unit: unit, status: status, evidenceAnchorIDs: anchors,
                                extractionVersion: "physics-contract-v1", sourceDocumentHash: nil, updatedAt: Date())
        }

        XCTAssertNoThrow(try V4PhysicsValidator.validate(cell(status: .direct, anchors: [current.id]), snapshot: snapshot))
        XCTAssertNoThrow(try V4PhysicsValidator.validate(cell(status: .inference, anchors: [current.id]), snapshot: snapshot))
        XCTAssertNoThrow(try V4PhysicsValidator.validate(cell(status: .crossPaperInference, anchors: [current.id, foreign.id]), snapshot: snapshot))
        XCTAssertNoThrow(try V4PhysicsValidator.validate(cell(status: .missing, value: nil, unit: nil, anchors: []), snapshot: snapshot))

        // A caveat that makes no numeric claim must not receive a fabricated
        // anchor merely to satisfy a UI enum.  Once a caveat does claim a
        // value, however, it is a factual assertion and follows the ordinary
        // same-paper value-plus-unit rule.
        XCTAssertNoThrow(try V4PhysicsValidator.validate(cell(status: .caveat, value: nil, unit: nil, anchors: []), snapshot: snapshot))
        XCTAssertNoThrow(try V4PhysicsValidator.validate(cell(status: .caveat, anchors: [current.id]), snapshot: snapshot))
        XCTAssertThrowsError(try V4PhysicsValidator.validate(cell(status: .caveat, anchors: []), snapshot: snapshot))
        XCTAssertThrowsError(try V4PhysicsValidator.validate(cell(status: .caveat, anchors: [foreign.id]), snapshot: snapshot))
    }

    func testLargeFixtureSeedsBoundedProcessLocalReachabilityCorpus() async throws {
        let store = InMemoryLibraryStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await AppFixtureLargeData.seed(into: store, now: now)
        var snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.authors.count, AppFixtureLargeData.authorCount)
        XCTAssertEqual(snapshot.papers.count, AppFixtureLargeData.paperCount)
        XCTAssertEqual(snapshot.paperAuthorLinks.count, AppFixtureLargeData.paperCount)
        XCTAssertEqual(snapshot.tags.count, AppFixtureLargeData.tagCount)
        XCTAssertEqual(snapshot.collections.count, AppFixtureLargeData.collectionCount)
        XCTAssertEqual(snapshot.checkpoints.count, AppFixtureLargeData.jobCount)
        XCTAssertEqual(snapshot.savedInspireQueries.count, AppFixtureLargeData.radarQueryCount)
        XCTAssertEqual(snapshot.radarEvents.count, AppFixtureLargeData.radarEventCount)
        XCTAssertEqual(snapshot.workspaces.count, AppFixtureLargeData.workspaceCount)
        XCTAssertEqual(snapshot.evidenceAnchors.count, AppFixtureLargeData.evidenceAnchorCount)
        XCTAssertEqual(snapshot.papers[9_100_000]?.figures.count, AppFixtureLargeData.figureCount)
        XCTAssertEqual(snapshot.authors[ProductContract.selfAuthorRecid]?.lastSyncedAt, now)

        // Seed retries must remain idempotent: an interrupted fixture launch
        // may be restarted, but it may not create duplicate durable links or
        // inflate the reachability corpus before its ready sentinel appears.
        try await AppFixtureLargeData.seed(into: store, now: now)
        snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.papers.count, AppFixtureLargeData.paperCount)
        XCTAssertEqual(snapshot.paperAuthorLinks.count, AppFixtureLargeData.paperCount)
        XCTAssertEqual(snapshot.radarEvents.count, AppFixtureLargeData.radarEventCount)

        let terms = (1...AppFixtureLargeData.terminologyCount).map { index in
            TerminologyEntry(id: AppFixtureLargeData.fixtureUUID(scope: 10, index: index),
                             source: "fixture term \(index)", preferredZH: "测试术语 \(index)")
        }
        XCTAssertEqual(LLMSettings(terminology: terms).terminology.count, AppFixtureLargeData.terminologyCount)
    }

    @MainActor
    func testV9TypedStoreSearchUsesDurableIncrementalPaperTokenRows() async throws {
        func paper(_ id: Int, title: String) -> Paper {
            Paper(literatureID: id, titles: [PaperTitle(value: title, source: "fixture")],
                  abstracts: [PaperAbstract(value: "local lattice QCD fixture", source: "fixture")],
                  preprintDate: nil, earliestDate: nil, arxivID: "2401.0\(id)", arxivCategories: ["hep-lat"], doi: nil,
                  citationCount: nil, publicationStatus: nil, updated: Date(timeIntervalSince1970: TimeInterval(id)),
                  figures: [], firstSeenAt: Date(), isRead: false)
        }

        let tag = LibraryTag(id: UUID(), name: "Wilson loop", colorName: nil, createdAt: Date())
        let first = paper(101, title: "Gluon helicity from lattice QCD")
        let second = paper(202, title: "Hadron structure fixture")
        let snapshot = LibrarySnapshot(papers: [first.literatureID: first, second.literatureID: second],
                                       tags: [tag.id: tag],
                                       paperTags: [PaperTagLink(paperID: second.literatureID, tagID: tag.id)])
        let schema = Schema(versionedSchema: LatticeLensSchemaV9.self)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV9.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        try V8TypedStoreCodec.materialize(snapshot, in: container.mainContext, sourceSchemaVersion: 8)
        try V9TypedSearchIndex.rebuild(in: container.mainContext)
        XCTAssertTrue(try V9TypedSearchIndex.isCurrent(in: container.mainContext))
        XCTAssertGreaterThan(try container.mainContext.fetchCount(FetchDescriptor<StoredV9PaperSearchTerm>()), 0)
        XCTAssertGreaterThan(try container.mainContext.fetchCount(FetchDescriptor<StoredV9SearchToken>()), 0)

        let store = V8TypedLibraryStore(modelContainer: container)
        let gluonResults = await store.searchPapers("gluo", limit: 10)
        let wilsonResults = await store.searchPapers("wil", limit: 10)
        XCTAssertEqual(gluonResults.map(\.literatureID), [first.literatureID])
        XCTAssertEqual(wilsonResults.map(\.literatureID), [second.literatureID])

        try await store.applyReferenceMutation(.upsertNote(UserNote(id: UUID(), paperID: second.literatureID,
                                                                      body: "renormalization cache", createdAt: Date(), updatedAt: Date())))
        let noteResults = await store.searchPapers("renorm", limit: 10)
        XCTAssertEqual(noteResults.map(\.literatureID), [second.literatureID])

        var replacement = first
        replacement.titles = [PaperTitle(value: "Quark momentum fraction", source: "fixture")]
        try await store.upsert(detail: replacement)
        let oldTitleResults = await store.searchPapers("gluo", limit: 10)
        let replacementResults = await store.searchPapers("quar", limit: 10)
        XCTAssertTrue(oldTitleResults.isEmpty)
        XCTAssertEqual(replacementResults.map(\.literatureID), [first.literatureID])
    }

    /// This test is deliberately opt-in.  The companion script refuses to run
    /// it until the user provides both a disposable V7 source family and an
    /// empty, explicitly disposable output directory.  A normal test run must
    /// never probe a real library merely because it happens to be nearby.
    @MainActor
    func testAuthorizedDisposableV7MigrationDrill() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["LATTICELENS_V5_DISPOSABLE_V7_STORE"],
              let outputPath = environment["LATTICELENS_V5_DISPOSABLE_DRILL_ROOT"],
              let sourceOrigin = environment["LATTICELENS_V5_DISPOSABLE_SOURCE_ORIGIN"],
              ["synthetic_v7_benchmark", "user_provided_disposable_copy"].contains(sourceOrigin) else {
            throw XCTSkip("set only through Scripts/migration_v7_disposable_drill.sh with user-authorized disposable paths")
        }
        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let outputRoot = URL(fileURLWithPath: outputPath).standardizedFileURL
        let fileManager = FileManager.default
        let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        XCTAssertEqual(source.pathExtension, "store")
        XCTAssertTrue(sourceValues.isRegularFile == true)
        XCTAssertFalse(sourceValues.isSymbolicLink == true)
        XCTAssertTrue(try fileManager.contentsOfDirectory(at: outputRoot, includingPropertiesForKeys: nil).isEmpty,
                      "the explicitly disposable drill root must start empty")

        let beforeHashes = try v5StoreFamilyHashes(at: source)
        let runRoot = outputRoot.appendingPathComponent("LatticeLens-V9-Disposable-Drill-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: runRoot, withIntermediateDirectories: false)
        let activeURL = runRoot.appendingPathComponent("active-v8.store")
        let backupRoot = runRoot.appendingPathComponent("backups", isDirectory: true)
        let outcome = try V8MigrationCoordinator.migrateV7ToV8(sourceURL: source, activeV8URL: activeURL, backupRoot: backupRoot)
        XCTAssertEqual(outcome.journal.phase, .activated)
        XCTAssertEqual(outcome.journal.preSummary, outcome.journal.postSummary)
        XCTAssertEqual(try v5StoreFamilyHashes(at: source), beforeHashes,
                       "the caller-provided V7 family must remain byte-identical after staged migration")

        let manifestURL = backupRoot
            .appendingPathComponent(outcome.journal.backupManifestID.uuidString, isDirectory: true)
            .appendingPathComponent("manifest.json")
        let backupManifest = try JSONDecoder.latticeLens.decode(V4StoreBackupManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(backupManifest.manifestHash, outcome.journal.backupManifestHash)
        XCTAssertTrue(try V4StoreBackupCoordinator.verify(backupManifest, in: backupRoot))
        let backupManifestText = String(decoding: try JSONEncoder.latticeLens.encode(backupManifest), as: UTF8.self)
        XCTAssertFalse(backupManifestText.contains(source.path))

        let recovered = try V8MigrationCoordinator.recover(journalURL: outcome.journalURL, parent: runRoot)
        XCTAssertEqual(recovered.phase, .activated)
        let schema = Schema(versionedSchema: LatticeLensSchemaV9.self)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV9.self,
                                           configurations: ModelConfiguration(schema: schema, url: activeURL))
        if try !V9TypedSearchIndex.isCurrent(in: container.mainContext) {
            try V9TypedSearchIndex.rebuild(in: container.mainContext)
        }
        XCTAssertTrue(try V9TypedSearchIndex.isCurrent(in: container.mainContext))
        let semanticSummary = try V8TypedStoreCodec.verifyMigrationSemanticIntegrity(from: container.mainContext)
        XCTAssertEqual(semanticSummary, outcome.journal.postSummary)
        let evidence = V5DisposableMigrationEvidence(sourceStoreName: source.lastPathComponent, sourceOrigin: sourceOrigin,
                                                      sourceFamilyHashes: beforeHashes,
                                                      backupManifestHash: backupManifest.manifestHash,
                                                      backupSourceCategory: backupManifest.sourcePathCategory,
                                                      journal: recovered, finalSchemaVersion: 9,
                                                      searchIndexCurrent: true, semanticSummary: semanticSummary)
        let evidenceURL = runRoot.appendingPathComponent("migration-v7-disposable-drill.json")
        try JSONEncoder.latticeLens.encode(evidence).write(to: evidenceURL, options: .atomic)
        let evidenceText = String(decoding: try Data(contentsOf: evidenceURL), as: UTF8.self)
        XCTAssertFalse(evidenceText.contains(source.path))
    }
}

private struct V5DisposableMigrationEvidence: Codable, Sendable {
    let sourceStoreName: String
    /// A generated benchmark source proves the disk migration mechanics but
    /// must never be promoted into a claim about a user's actual library.
    let sourceOrigin: String
    let sourceFamilyHashes: [String: String]
    let backupManifestHash: String
    let backupSourceCategory: String
    let journal: V8MigrationJournal
    let finalSchemaVersion: Int
    let searchIndexCurrent: Bool
    let semanticSummary: V8StoreSemanticSummary
}

private func v5StoreFamilyHashes(at source: URL, fileManager: FileManager = .default) throws -> [String: String] {
    var hashes = [String: String]()
    for member in [source, URL(fileURLWithPath: source.path + "-wal"), URL(fileURLWithPath: source.path + "-shm")] {
        guard fileManager.fileExists(atPath: member.path) else { continue }
        let values = try member.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LatticeLensError.persistenceUnavailable("可丢弃 V7 store family 含非 regular/symlink member")
        }
        hashes[member.lastPathComponent] = StableHash.sha256(try Data(contentsOf: member))
    }
    guard !hashes.isEmpty else { throw LatticeLensError.persistenceUnavailable("可丢弃 V7 store family 为空") }
    return hashes
}

private actor V5Discoverer: ModelDiscovering {
    private(set) var lastAPIKey: String?
    func discoverModels(profile: ProviderProfile, provider: LLMProvider, apiKey: String) async throws -> [String] {
        lastAPIKey = apiKey
        return ["fixture-local"]
    }
    func apiKey() -> String? { lastAPIKey }
}

private actor V5ConnectionTester: ProviderConnectionTesting {
    private var receivedAPIKey: String?
    private var callCount = 0

    func testConnection(profile: ProviderProfile, provider: LLMProvider, apiKey: String) async throws -> ProviderConnectionProbe {
        receivedAPIKey = apiKey
        callCount += 1
        let endpoint = try APIEndpointBuilder.normalizedBaseURL(from: profile.baseURL, provider: provider)
        return ProviderConnectionProbe(normalizedEndpoint: endpoint.absoluteString)
    }

    func apiKey() -> String? { receivedAPIKey }
    func calls() -> Int { callCount }
}

private final class V5EmptyKeychain: KeychainStoring, @unchecked Sendable {
    func save(_ value: String, service: String, account: String) throws {}
    func read(service: String, account: String) throws -> String? { nil }
    func delete(service: String, account: String) throws {}
}
