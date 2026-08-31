import Foundation
import SwiftData
import XCTest
@testable import LatticeLens

final class V4LocalTests: XCTestCase {
    private func makePaper(_ id: Int) -> Paper {
        Paper(literatureID: id, titles: [PaperTitle(value: "Paper \(id)", source: "fixture")],
              abstracts: [PaperAbstract(value: "abstract", source: "fixture")], preprintDate: nil, earliestDate: nil,
              arxivID: nil, arxivCategories: ["hep-lat"], doi: nil, citationCount: nil, publicationStatus: nil,
              updated: Date(timeIntervalSince1970: TimeInterval(id)), figures: [], firstSeenAt: Date(), isRead: false)
    }
    func testSharedBlobDeleteUsesReferenceCountAndOwnedPath() throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v4-owned")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try V4OwnedPath.canonicalFile(named: "same.pdf", root: root)
        XCTAssertTrue(file.path.hasPrefix(root.path))
        XCTAssertThrowsError(try V4OwnedPath.canonicalFile(named: "../escape.pdf", root: root)) { error in
            XCTAssertEqual(error as? V4LocalError, .pathEscape)
        }
        XCTAssertThrowsError(try V4OwnedPath.canonicalFile(named: "/tmp/escape.pdf", root: root))
    }

    func testSharedBlobServiceDeletesFileOnlyAfterLastReference() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v4-shared")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("shared.pdf")
        try Data("fixture-pdf-bytes".utf8).write(to: file)
        let hash = StableHash.sha256(Data("fixture-pdf-bytes".utf8))
        let store = InMemoryLibraryStore()
        let first = FullTextDocument(paperID: 11, sourceURL: URL(string: "https://inspirehep.net/a.pdf")!, sourceKind: .inspireDocument,
                                     sha256: hash, byteCount: 17, localFilename: "shared.pdf", pageCount: 1,
                                     extractionState: .extracted, downloadedAt: Date(), lastErrorCategory: nil)
        let second = FullTextDocument(paperID: 12, sourceURL: URL(string: "https://inspirehep.net/b.pdf")!, sourceKind: .inspireDocument,
                                      sha256: hash, byteCount: 17, localFilename: "shared.pdf", pageCount: 1,
                                      extractionState: .extracted, downloadedAt: Date(), lastErrorCategory: nil)
        try await store.saveFullText(document: first, chunks: [], anchors: [])
        try await store.saveFullText(document: second, chunks: [], anchors: [])
        let service = FullTextService(store: store, cacheDirectory: root)
        try await service.delete(document: first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let afterFirst = await store.snapshot()
        XCTAssertEqual(afterFirst.contentBlobs[hash]?.referenceCount, 1)
        try await service.delete(document: second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let afterSecond = await store.snapshot()
        XCTAssertEqual(afterSecond.contentBlobs[hash]?.referenceCount, 0)
    }

    func testOrphanRetryRefusesAContentAddressedFilenameWhoseBytesChanged() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v4-orphan-hash")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let expected = Data("expected original PDF bytes".utf8)
        let expectedHash = StableHash.sha256(expected)
        let filename = "\(expectedHash).pdf"
        let target = root.appendingPathComponent(filename)
        // The inode/name is app-owned but its content changed after the
        // durable retirement; retry must preserve it rather than delete it.
        try Data("replacement bytes that do not match the journal".utf8).write(to: target)
        let store = InMemoryLibraryStore()
        try await store.saveOrphanedBlobDeletion(OrphanedBlobDeletion(blobHash: expectedHash, filename: filename,
                                                                       byteCount: expected.count, retryCount: 0,
                                                                       lastErrorCategory: "fixture", createdAt: Date(), updatedAt: Date()))
        let service = FullTextService(store: store, cacheDirectory: root)
        await service.retryOrphanedBlobDeletions()
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let remaining = await store.orphanedBlobDeletions()
        XCTAssertEqual(remaining.first?.retryCount, 1)
    }

    func testPDFPreflightOccursBeforeGETAndKeepsHardLimitAndPortPolicyVisible() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v4-pdf-preflight")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FullTextService(store: InMemoryLibraryStore(), cacheDirectory: root, downloader: AppFixtureFullTextDownloader())
        let source = try XCTUnwrap(URL(string: "https://fixture.invalid/fulltext/1234567.pdf"))
        let preflight = try await service.preflight(sourceURL: source)
        XCTAssertEqual(preflight.sourceURL, source)
        XCTAssertEqual(preflight.finalURL, source)
        XCTAssertNotNil(preflight.advertisedByteCount)
        XCTAssertLessThanOrEqual(preflight.advertisedByteCount ?? .max, FullTextService.maximumBytes)
        XCTAssertEqual(preflight.hardByteLimit, FullTextService.maximumBytes)
        XCTAssertEqual(preflight.cacheCategory, "app-owned full-text cache")
        let nonDefaultPort = try XCTUnwrap(URL(string: "https://fixture.invalid:8443/fulltext/1234567.pdf"))
        do {
            _ = try await service.preflight(sourceURL: nonDefaultPort)
            XCTFail("non-default port must be rejected before HEAD")
        } catch let error as FullTextServiceError {
            XCTAssertEqual(error, .invalidSource)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testFixtureSharedPDFDrivesComparePDFAnchorAndSurvivesFirstDelete() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "fixture-shared-pdf")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = InMemoryLibraryStore()
        let page = try await InspireClient(transport: AppFixtureTransport()).literaturePage(for: 77)
        XCTAssertEqual(Set(page.papers.map(\.literatureID)), [1_234_567, 1_234_568])
        _ = try await store.upsert(papers: page.papers, for: 77)
        for paper in page.papers {
            try await store.saveEvidenceAnchors(EvidenceAnchorFactory.metadataAnchors(for: paper))
        }

        let fullText = FullTextService(store: store, cacheDirectory: root, downloader: AppFixtureFullTextDownloader())
        let first = try XCTUnwrap(page.papers.first { $0.literatureID == 1_234_567 })
        let second = try XCTUnwrap(page.papers.first { $0.literatureID == 1_234_568 })
        let firstDocument = try await fullText.downloadAndExtract(
            paperID: first.literatureID,
            sourceURL: try XCTUnwrap(first.documents.first?.url),
            sourceKind: .arxivPDF
        )
        let secondDocument = try await fullText.downloadAndExtract(
            paperID: second.literatureID,
            sourceURL: try XCTUnwrap(second.documents.first?.url),
            sourceKind: .arxivPDF
        )
        XCTAssertEqual(firstDocument.sha256, secondDocument.sha256)
        let sharedPath = try XCTUnwrap(firstDocument.localFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(sharedPath).path))

        let workbench = V3WorkbenchService(store: store)
        let workspace = try await workbench.createWorkspace(name: "fixture shared PDF", paperIDs: [first.literatureID, second.literatureID])
        let cells = try await workbench.extractLocalCompareMatrix(workspaceID: workspace.id)
        let spacing = try XCTUnwrap(cells.first { $0.paperID == second.literatureID && $0.rowKey == "lattice_spacing" })
        XCTAssertEqual(spacing.value, "0.09")
        XCTAssertEqual(spacing.unit, "fm")
        XCTAssertEqual(spacing.status, .direct)
        let anchorID = try XCTUnwrap(spacing.evidenceAnchorIDs.first)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.evidenceAnchors[anchorID]?.sourceKind, .pdf)
        XCTAssertEqual(snapshot.evidenceAnchors[anchorID]?.page, 1)
        XCTAssertEqual(snapshot.contentBlobs[firstDocument.sha256]?.referenceCount, 2)

        try await fullText.delete(document: firstDocument)
        let afterFirstDelete = await store.snapshot()
        XCTAssertNil(afterFirstDelete.fullTextDocuments[firstDocument.id])
        XCTAssertNotNil(afterFirstDelete.fullTextDocuments[secondDocument.id])
        XCTAssertEqual(afterFirstDelete.contentBlobs[firstDocument.sha256]?.referenceCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(sharedPath).path),
                      "删除第一篇论文的 document row 不得删除第二篇仍引用的同一 PDF blob")
    }

    func testCheckpointResumeIgnoresFreshLastSuccessfulTimestamp() {
        var checkpoint = SyncCheckpoint(jobID: "literature:11", jobKind: "literature", query: "authors.recid:11")
        checkpoint.state = .failed
        checkpoint.completedPages = 1
        checkpoint.nextURL = URL(string: "https://inspirehep.net/api/literature?page=2")
        checkpoint.lastSuccessfulSyncAt = Date()
        XCTAssertTrue(V4CheckpointRecovery.shouldResume(checkpoint))
        checkpoint.state = .completed
        XCTAssertFalse(V4CheckpointRecovery.shouldResume(checkpoint))
    }

    /// A malformed legacy checkpoint is a recoverable row-level problem.  It
    /// must not poison the whole V8 store into read-only mode, otherwise the
    /// next paper refresh cannot repair the bad data and the UI appears blank.
    @MainActor
    func testMalformedAuthorGenerationDoesNotBlockRefreshWrites() async throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV8.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.insert(StoredV8StoreMarker(semanticHash: "fixture"))
        let seedGeneration = AuthorIndexGeneration(id: "bad", query: "fixture", startedAt: Date(), completedAt: Date(),
                                                   state: .completed, activeMembership: [], stagingMembership: [], pageCount: 0,
                                                   hQueueCompleted: 0, hQueuePending: 0, hQueueFailed: 0, hQueueCancelled: 0,
                                                   lastCheckpointAt: nil)
        let malformed = try StoredV8AuthorIndexGeneration(seedGeneration)
        malformed.generationData = Data("not-json".utf8)
        context.insert(malformed)
        try context.save()

        let store = V8TypedLibraryStore(modelContainer: container)
        let projection = await store.authorSidebarProjection()
        XCTAssertTrue(projection.authors.isEmpty)
        let compatibilityRead = await store.snapshotResult()
        XCTAssertEqual(compatibilityRead.state, .readOnlyFailure,
                       "兼容 snapshot 应明确报告坏行，但不能把 typed store 变成不可写")

        let author = Author(recid: 77, preferredName: "Fixture, Researcher", nativeNames: [], bai: nil,
                            arxivCategories: ["hep-lat"], hIndex: nil, hIndexState: .qualified,
                            isTracked: false, lastSyncedAt: nil)
        try await store.upsert(authors: [author])
    }

    @MainActor
    func testLegacyStoreDiscoveryIncludesPreV7RootFamily() {
        let applicationSupport = URL(fileURLWithPath: "/tmp/latticelens-fixture-application-support", isDirectory: true)
        let candidates = LibraryStoreFactory.legacyV7StoreCandidates(applicationSupportRoot: applicationSupport)
        XCTAssertEqual(candidates.map(\.path), [
            applicationSupport.appending(path: "LatticeLens/Library-v7.store").path,
            applicationSupport.appending(path: "LatticeLens.store").path
        ])
    }

    @MainActor
    func testV8MigrationReadsPreV7RootSnapshotFamily() throws {
        // Early releases wrote a V4 snapshot to `LatticeLens.store` at the
        // Application Support root.  The upgrade path must consume that
        // family through the same staged, hash-verified migration used by the
        // nested V7 source instead of silently creating an empty V8 target.
        let root = try makeProjectLocalTestDirectory(prefix: "v8-legacy-root")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("LatticeLens.store")
        let activeURL = root.appendingPathComponent("LatticeLens/Library-v8.store")
        let schema = Schema(versionedSchema: LatticeLensSchemaV7.self)
        let sourceContainer = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV7.self,
                                                  configurations: ModelConfiguration(url: sourceURL))
        let author = Author(recid: 77, preferredName: "Legacy, Root", nativeNames: [], bai: nil,
                            arxivCategories: ["hep-lat"], hIndex: nil, hIndexState: .qualified,
                            isTracked: false, lastSyncedAt: Date(timeIntervalSince1970: 1))
        let paper = makePaper(11)
        let snapshot = LibrarySnapshot(authors: [author.recid: author], papers: [paper.literatureID: paper],
                                       paperAuthorLinks: [PaperAuthorLink(paperID: paper.literatureID, authorRecid: author.recid, position: 0)],
                                       schemaVersion: 6)
        sourceContainer.mainContext.insert(StoredLibraryDocument(schemaVersion: 6,
                                                                 snapshotData: try JSONEncoder.latticeLens.encode(snapshot)))
        try sourceContainer.mainContext.save()

        let outcome = try V8MigrationCoordinator.migrateV7ToV8(sourceURL: sourceURL, activeV8URL: activeURL,
                                                                 backupRoot: root.appendingPathComponent("backups", isDirectory: true))
        XCTAssertEqual(outcome.journal.phase, .activated)
        let activeSchema = Schema(versionedSchema: LatticeLensSchemaV8.self)
        let active = try ModelContainer(for: activeSchema, configurations: ModelConfiguration(url: activeURL))
        XCTAssertEqual(try active.mainContext.fetchCount(FetchDescriptor<StoredV8Author>()), 1)
        XCTAssertEqual(try active.mainContext.fetchCount(FetchDescriptor<StoredV8Paper>()), 1)
        XCTAssertEqual(try active.mainContext.fetchCount(FetchDescriptor<StoredV8PaperAuthorLink>()), 1)
    }

    func testRadarDiffClassifiesAddedRemovedAndModifiedWithFieldHashes() {
        let old = makePaper(11)
        var changed = old
        changed.citationCount = 3
        changed.doi = "10.1234/new"
        let events = V4RadarDiff.diff(before: old, after: changed, batchID: UUID())
        XCTAssertTrue(events.contains { $0.field == "citationCount" && $0.kind == .modified && $0.beforeFieldHash != $0.afterFieldHash })
        XCTAssertTrue(events.contains { $0.field == "doi" && $0.kind == .added })
        let removed = V4RadarDiff.diff(before: changed, after: old, batchID: UUID())
        XCTAssertTrue(removed.contains { $0.field == "doi" && $0.kind == .removed })
        XCTAssertEqual(Set(events.map(\.id)).count, events.count)
        let change = try! XCTUnwrap(events.first { $0.field == "doi" })
        let restored = try! XCTUnwrap(V4RadarFieldChange.decodeStorageMarker(change.storageMarker))
        XCTAssertEqual(restored.semanticKey, change.semanticKey)
        XCTAssertEqual(restored.beforeDisplay, change.beforeDisplay)
        XCTAssertEqual(restored.afterDisplay, change.afterDisplay)

        let firstPipelineRun = V4RadarDiff.events(before: old, after: changed, authorRecids: [8, 3], batchID: UUID(), observedAt: Date(timeIntervalSince1970: 1))
        let retriedPipelineRun = V4RadarDiff.events(before: old, after: changed, authorRecids: [3, 8], batchID: UUID(), observedAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(Set(firstPipelineRun.map(\.id)), Set(retriedPipelineRun.map(\.id)),
                       "same field hashes must deduplicate across a restarted batch")
        let citation = try! XCTUnwrap(firstPipelineRun.first { event in
            event.changedFields.compactMap(V4RadarFieldChange.decodeStorageMarker).contains { $0.field == "citationCount" }
        })
        XCTAssertEqual(citation.eventKind, .fieldModified)
        XCTAssertEqual(citation.authorRecids, [3, 8])
    }

    @MainActor
    func testRadarPausePublishesAndPersistsTheSameDurableQueryState() async throws {
        let store = InMemoryLibraryStore()
        let query = SavedInspireQuery(id: UUID(), name: "fixture", query: "arxiv_categories:hep-lat",
                                      refreshPolicy: .manual, isPaused: false, lastRunAt: nil,
                                      nextRunAt: nil, createdAt: Date())
        try await store.applyV3(.saveQuery(query))
        let viewModel = AppViewModel(store: store, useFixtureDependencies: false)
        await viewModel.refreshWorkbench()

        viewModel.setRadarQueryPaused(query, paused: true)
        for _ in 0..<50 where viewModel.workbenchSnapshot.savedInspireQueries[query.id]?.isPaused != true {
            await Task.yield()
        }

        XCTAssertTrue(viewModel.workbenchSnapshot.savedInspireQueries[query.id]?.isPaused == true)
        var persisted = await store.snapshot()
        for _ in 0..<20 where persisted.savedInspireQueries[query.id]?.isPaused != true {
            try await Task.sleep(for: .milliseconds(20))
            persisted = await store.snapshot()
        }
        XCTAssertTrue(persisted.savedInspireQueries[query.id]?.isPaused == true)
    }

    @MainActor
    func testResearchHomeRefreshesAfterReadAndFavoriteMutations() async throws {
        let store = InMemoryLibraryStore()
        let author = Author(recid: 77, preferredName: "Fixture, Researcher", nativeNames: [], bai: nil,
                            arxivCategories: ["hep-lat"], hIndex: nil, hIndexState: .qualified,
                            isTracked: false, lastSyncedAt: Date())
        try await store.upsert(authors: [author])
        let first = makePaper(701)
        let second = makePaper(702)
        _ = try await store.upsert(papers: [first, second], for: author.recid)

        let viewModel = AppViewModel(store: store, client: InspireClient(transport: AppFixtureTransport()),
                                     useFixtureDependencies: false)
        viewModel.selectAuthor(author.recid)
        for _ in 0..<50 where viewModel.filteredPapers.count != 2 {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.filteredPapers.map(\.literatureID).sorted(), [first.literatureID, second.literatureID])

        viewModel.selectPaper(first.literatureID)
        viewModel.toggleFavoriteSelectedPaper()
        for _ in 0..<50 where viewModel.researchHomeSnapshot.favorites != 1 {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.researchHomeSnapshot.favorites, 1,
                       "Home Favorites must refresh from the durable mutation, not only the detail projection")

        viewModel.toggleReadSelectedPaper()
        for _ in 0..<50 where viewModel.researchHomeSnapshot.unread != 1 {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.researchHomeSnapshot.unread, 1,
                       "Home Inbox must refresh after marking the selected local paper read")
        let persisted = await store.snapshot()
        XCTAssertTrue(persisted.papers[first.literatureID]?.isFavorite == true)
        XCTAssertTrue(persisted.papers[first.literatureID]?.isRead == true)
    }

    func testPhysicsValidatorRequiresValueAndUnitInSameAnchorWindow() throws {
        let paper = makePaper(11)
        let unrelated = EvidenceAnchor(id: "unrelated", paperID: 11, sourceKind: .abstract, page: nil, section: nil,
                                       quote: "The year 2024 was used.", quoteHash: StableHash.sha256("The year 2024 was used."), figureKey: nil)
        var snapshot = LibrarySnapshot(papers: [11: paper], evidenceAnchors: [unrelated.id: unrelated])
        let cell = PhysicsContractCell(id: UUID(), workspaceID: UUID(), rowKey: "lattice_spacing", paperID: 11, value: "0.09", unit: "fm", status: .direct,
                                       evidenceAnchorIDs: [unrelated.id], extractionVersion: "v4", sourceDocumentHash: nil, updatedAt: Date())
        XCTAssertThrowsError(try V4PhysicsValidator.validate(cell, snapshot: snapshot))
        let valid = EvidenceAnchor(id: "valid", paperID: 11, sourceKind: .abstract, page: nil, section: nil,
                                   quote: "We use a=0.09 fm.", quoteHash: StableHash.sha256("We use a=0.09 fm."), figureKey: nil)
        snapshot.evidenceAnchors[valid.id] = valid
        var accepted = cell; accepted.evidenceAnchorIDs = [valid.id]
        XCTAssertNoThrow(try V4PhysicsValidator.validate(accepted, snapshot: snapshot))
        accepted.evidenceAnchorIDs = [valid.id, valid.id]
        XCTAssertThrowsError(try V4PhysicsValidator.validate(accepted, snapshot: snapshot))
    }

    func testNumericCorpusRejectsYearsReferencesEquationsAndPagesWithoutDiscardingLatticeForms() {
        XCTAssertNil(V4NumericParser.parse(value: "2024", unit: nil))
        XCTAssertNil(V4NumericParser.parse(value: "Ref. [17]", unit: nil))
        XCTAssertNil(V4NumericParser.parse(value: "Eq. (3)", unit: nil))
        XCTAssertNil(V4NumericParser.parse(value: "page 12", unit: nil))
        XCTAssertNil(V4NumericParser.parse(value: "0.09", unit: "year"))

        XCTAssertNotNil(V4NumericParser.parse(value: "-1.23e-2", unit: "GeV^2"))
        XCTAssertNotNil(V4NumericParser.parse(value: "0.09(1)", unit: "fm"))
        XCTAssertNotNil(V4NumericParser.parse(value: "2.0 ± 0.1", unit: "GeV"))
        XCTAssertNotNil(V4NumericParser.parse(value: "8–12", unit: "a"))
        XCTAssertNotNil(V4NumericParser.parse(value: "64×64×64×128", unit: nil))
        XCTAssertNotNil(V4NumericParser.parse(value: "1000", unit: "configurations"))
    }

    func testCompareExtractorReturnsMissingInsteadOfGuessing() {
        let paper = makePaper(11)
        let workspace = PaperWorkspace(id: UUID(), name: "compare", createdAt: Date(), updatedAt: Date(), sortOrder: [11, 12], note: "", frozenExportHash: nil)
        var snapshot = LibrarySnapshot(papers: [11: paper, 12: makePaper(12)])
        let anchor = EvidenceAnchor(id: "a", paperID: 11, sourceKind: .abstract, page: nil, section: nil, quote: "a=0.09 fm", quoteHash: StableHash.sha256("a=0.09 fm"), figureKey: nil)
        snapshot.evidenceAnchors[anchor.id] = anchor
        let values = V4CompareExtractor.extract(workspace: workspace, snapshot: snapshot)
        XCTAssertEqual(values.first { $0.paperID == 11 && $0.rowKey == "lattice_spacing" }?.value, "0.09")
        XCTAssertEqual(values.first { $0.paperID == 12 && $0.rowKey == "lattice_spacing" }?.status, .missing)
        XCTAssertTrue(values.filter { $0.status == .missing }.count > 10)
    }

    func testCompareLocalExtractorAtomicallyReplacesOnlyFullyValidatedMatrix() async throws {
        let store = InMemoryLibraryStore()
        let first = makePaper(11)
        let second = makePaper(12)
        _ = try await store.upsert(papers: [first, second], for: 99)
        let anchor = EvidenceAnchor(id: "a", paperID: 11, sourceKind: .abstract, page: nil, section: nil,
                                    quote: "The lattice spacing is a=0.09 fm.", quoteHash: StableHash.sha256("The lattice spacing is a=0.09 fm."), figureKey: nil)
        try await store.saveEvidenceAnchors([anchor])
        let workbench = V3WorkbenchService(store: store)
        let workspace = try await workbench.createWorkspace(name: "fixture compare", paperIDs: [11, 12])
        let accepted = try await workbench.extractLocalCompareMatrix(workspaceID: workspace.id)
        XCTAssertEqual(accepted.first { $0.paperID == 11 && $0.rowKey == "lattice_spacing" }?.value, "0.09")
        let saved = await store.snapshot().physicsContractCells
        var rejected = accepted
        let index = try XCTUnwrap(rejected.firstIndex { $0.paperID == 11 && $0.rowKey == "lattice_spacing" })
        rejected[index].value = "0.10" // no same-anchor match
        await XCTAssertThrowsErrorAsync(try await workbench.replacePhysicsMatrix(workspaceID: workspace.id, proposed: rejected))
        let afterRejected = await store.snapshot().physicsContractCells
        XCTAssertEqual(afterRejected, saved, "one rejected cell must preserve the complete previous matrix")
    }

    func testLocalSearchReportsProvenanceAndFacets() {
        let paper = makePaper(11)
        let note = UserNote(id: UUID(), paperID: 11, body: "renormalization check", createdAt: Date(), updatedAt: Date())
        let snapshot = LibrarySnapshot(papers: [11: paper], notes: [note.id: note])
        let index = V4LocalSearchIndex.rebuild(snapshot: snapshot)
        let hits = index.search("renormalization", snapshot: snapshot)
        XCTAssertEqual(hits.first?.source, "note")
        XCTAssertEqual(hits.first?.paperID, 11)
    }

    func testExportCoordinatorDoesNotMarkCancelledAsSucceeded() async throws {
        let coordinator = V4ExportCoordinator()
        let prepared = await coordinator.prepare(format: .markdownNotebook, paperIDs: [11], contents: "note")
        _ = try await coordinator.markPresenting(prepared.id)
        let cancelled = try await coordinator.finish(prepared.id, result: .failure(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertNil(cancelled.destination)
    }

    func testAIClearPreviewIsScopeBoundedAndNamesAffectedPaperSet() {
        let paper = makePaper(11)
        let physics = InsightPhysics(researchQuestion: "fixture", background: "fixture", methodAndDataFlow: [], mainResults: [],
                                     latticeConventionsReported: [], missingInformation: [], caveats: [])
        let content = PaperInsightV1(schemaVersion: "fixture", sourceScope: "fixture", titleZH: "fixture", abstractZH: "fixture",
                                     physics: physics, importantFigures: [], terminology: [])
        let insight = InsightArtifact(cacheKey: "insight", paperID: 11, insight: content, createdAt: Date())
        let vision = VisionArtifact(cacheKey: "vision", paperID: 12, figureKeys: ["f"], imageHashes: ["hash"], provider: "fixture", model: "fixture", createdAt: Date(), text: "fixture", insights: [])
        let snapshot = LibrarySnapshot(papers: [11: paper], insights: [insight.cacheKey: insight], visionArtifacts: [vision.cacheKey: vision])
        let insightOnly = V4AIClearPreview.make(scope: .insight, snapshot: snapshot)
        XCTAssertEqual(insightOnly.deletionCount, 1)
        XCTAssertEqual(insightOnly.paperIDs, [11])
        let all = V4AIClearPreview.make(scope: .all, snapshot: snapshot)
        XCTAssertEqual(all.deletionCount, 2)
        XCTAssertEqual(all.paperIDs, [11, 12])
    }

    func testWorkbenchExportWritesLedgerOnlyFromCompletionCallback() async throws {
        let store = InMemoryLibraryStore()
        let paper = makePaper(11)
        try await store.upsert(detail: paper)
        let manager = ReferenceManagerService(store: store)
        let contents = try await manager.prepareExportContents(paperIDs: [11], format: .markdownNotebook)
        let beforeCompletion = await store.snapshot()
        XCTAssertTrue(beforeCompletion.exportRecords.isEmpty, "preparing a file must not claim export success")
        try await manager.recordExportOutcome(paperIDs: [11], format: .markdownNotebook, contents: contents,
                                              succeeded: false, destinationCategory: "user-selected", errorCategory: "cancelled")
        let afterCompletion = await store.snapshot()
        let record = try XCTUnwrap(afterCompletion.exportRecords.values.first)
        XCTAssertFalse(record.succeeded)
        XCTAssertEqual(record.errorCategory, "cancelled")
    }

    func testBundleManifestHashAndTamperDetectionContract() throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v4-bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = Data("bundle payload".utf8)
        let file = root.appendingPathComponent("library.json")
        try payload.write(to: file)
        let manifest = V4BundleManifest.make(schemaVersion: 5, files: ["library.json": payload], createdAt: Date())
        XCTAssertEqual(manifest.manifestHash, V4BundleManifest.make(schemaVersion: 5, files: ["library.json": payload], createdAt: manifest.createdAt).manifestHash)
        XCTAssertNotEqual(manifest.manifestHash, V4BundleManifest.make(schemaVersion: 5, files: ["library.json": Data("tampered".utf8)], createdAt: manifest.createdAt).manifestHash)
    }

    func testResearchBundleVerifyDryRunAndRestoreToNewTarget() throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v4-bundle-flow")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("library.latticelensbundle", isDirectory: true)
        let target = root.appendingPathComponent("restored", isDirectory: true)
        let paper = makePaper(11)
        var snapshot = LibrarySnapshot(papers: [11: paper])
        let manifest = try V4ResearchBundle.export(snapshot: snapshot, to: bundle)
        XCTAssertEqual(try V4ResearchBundle.verify(bundle).manifestHash, manifest.manifestHash)
        let dryRun = try V4ResearchBundle.dryRun(bundle, activeSnapshot: LibrarySnapshot())
        XCTAssertEqual(dryRun.paperCount, 1)
        XCTAssertEqual(try V4ResearchBundle.restoreToNewStore(bundle, target: target).paperCount, 1)
        try Data("tampered".utf8).write(to: bundle.appendingPathComponent("library.json"), options: .atomic)
        XCTAssertThrowsError(try V4ResearchBundle.verify(bundle)) { error in
            guard case V4ResearchBundleError.hashMismatch("library.json") = error else { return XCTFail("unexpected error \(error)") }
        }
        snapshot.papers.removeValue(forKey: 11)
    }

    @MainActor
    func testResearchBundleTypedRestoreBuildsVerifiedV9StagingStoreWithoutActiveOverwrite() throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v5-bundle-typed-stage")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("library.latticelensbundle", isDirectory: true)
        let target = root.appendingPathComponent("restored-v9.store")
        let paper = makePaper(17)
        let notedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let note = UserNote(id: UUID(), paperID: paper.literatureID, body: "staging restore", createdAt: notedAt, updatedAt: notedAt)
        let snapshot = LibrarySnapshot(papers: [paper.literatureID: paper], notes: [note.id: note], schemaVersion: 8)
        _ = try V4ResearchBundle.export(snapshot: snapshot, to: bundle)

        let dryRun = try V4ResearchBundle.restoreToNewTypedStore(bundle, targetStoreURL: target, activeSnapshot: LibrarySnapshot())
        XCTAssertEqual(dryRun.paperCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let schema = Schema(versionedSchema: LatticeLensSchemaV9.self)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV9.self,
                                           configurations: ModelConfiguration(schema: schema, url: target))
        let restored = try V8TypedStoreCodec.snapshot(from: container.mainContext)
        XCTAssertEqual(restored.papers[paper.literatureID]?.displayTitle, paper.displayTitle)
        XCTAssertEqual(restored.notes[note.id], note)
        XCTAssertTrue(try V9TypedSearchIndex.isCurrent(in: container.mainContext))
        XCTAssertThrowsError(try V4ResearchBundle.restoreToNewTypedStore(bundle, targetStoreURL: target),
                             "restore must refuse an existing staging target instead of overwriting it")
    }

    func testActualSwiftDataNormalizedRowsMutateWithoutSnapshotBlob() throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV5.self)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV5.self, configurations: configuration)
        let context = ModelContext(container)
        context.insert(StoredV4Paper(literatureID: 11, title: "Paper", abstractText: "local"))
        try context.save()
        let row = try context.fetch(FetchDescriptor<StoredV4Paper>()).first
        XCTAssertEqual(row?.title, "Paper")
        row?.isRead = true
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredV4Paper>()).first?.isRead, true)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredLibraryDocument>()), 0)
    }

    func testNormalizedBatchUpsertUsesOneBoundedCommitAndPreservesIdentity() async throws {
        let store = try V4NormalizedStoreFactory.makeInMemory()
        try await store.insertSynthetic(authorCount: 0, paperCount: 2, linkCount: 0, chunkCount: 0)
        let outcome = try await store.upsertSyntheticBatch(startingAt: 1, count: 3)
        XCTAssertEqual(outcome, V4BatchUpsertOutcome(inserted: 2, updated: 1))
        let paperCount = try await store.paperCount()
        XCTAssertEqual(paperCount, 4,
                       "batch upsert must update existing identity 1 and insert only IDs 2 and 3")
    }

    func testNormalizedSearchTokenIndexReturnsBoundedRealPaperIDs() async throws {
        let store = try V4NormalizedStoreFactory.makeInMemory()
        let entries = [
            V4SearchIndexEntry(id: "a", paperID: 11, field: "title", text: "RI MOM renormalization", normalizedText: SearchNormalizer.normalize("RI MOM renormalization"), page: nil, quote: nil, quoteHash: nil),
            V4SearchIndexEntry(id: "b", paperID: 12, field: "abstract", text: "renormalization and matching", normalizedText: SearchNormalizer.normalize("renormalization and matching"), page: nil, quote: nil, quoteHash: nil),
            V4SearchIndexEntry(id: "c", paperID: 13, field: "title", text: "gluon observable", normalizedText: SearchNormalizer.normalize("gluon observable"), page: nil, quote: nil, quoteHash: nil)
        ]
        try await store.saveIndex(entries)
        let renormalization = try await store.searchPaperIDs("renormalization", limit: 100)
        let matching = try await store.searchPaperIDs("renormalization matching", limit: 100)
        let gluon = try await store.searchPaperIDs("gluon", limit: 1)
        XCTAssertEqual(renormalization, [11, 12])
        XCTAssertEqual(matching, [12])
        XCTAssertEqual(gluon, [13])
    }

    @MainActor
    func testNormalSwiftDataMutationBuildsActualTokenPostings() async throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV7.self)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV7.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.insert(StoredV7StoreMarker())
        try container.mainContext.save()
        let store = SwiftDataLibraryStore(modelContainer: container)
        try await store.upsert(detail: makePaper(11))
        let normalized = V4NormalizedLibraryStore(modelContainer: container)
        let paperIDs = try await normalized.searchPaperIDs("paper", limit: 10)
        XCTAssertEqual(paperIDs, [11])
        let context = ModelContext(container)
        let token = try context.fetch(FetchDescriptor<StoredV4SearchToken>(predicate: #Predicate { $0.token == "paper" })).first
        XCTAssertEqual(token?.paperIDs, [11])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredLibraryDocument>()), 0,
                       "V7 normal mutation must not create an active LibrarySnapshot blob")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredV7DomainRecord>()), 1,
                       "one paper mutation must produce one independently addressable domain row")
    }

    @MainActor
    func testV7NoteMutationKeepsUnchangedPaperDomainRowsByteIdentical() async throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV7.self)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV7.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.insert(StoredV7StoreMarker())
        try container.mainContext.save()
        let store = SwiftDataLibraryStore(modelContainer: container)
        _ = try await store.upsert(papers: [makePaper(11), makePaper(12)], for: 21)
        let context = ModelContext(container)
        let before = try context.fetch(FetchDescriptor<StoredV7DomainRecord>())
        let paperPayloads = Dictionary(uniqueKeysWithValues: before.filter { $0.kind == "paper" }.map { ($0.recordID, $0.payload) })

        try await ReferenceManagerService(store: store).saveNote(paperID: 11, body: "verify RI/MOM projector")

        let after = try context.fetch(FetchDescriptor<StoredV7DomainRecord>())
        let afterPaperPayloads = Dictionary(uniqueKeysWithValues: after.filter { $0.kind == "paper" }.map { ($0.recordID, $0.payload) })
        XCTAssertEqual(afterPaperPayloads, paperPayloads)
        XCTAssertEqual(after.filter { $0.kind == "note" }.count, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredLibraryDocument>()), 0)
    }

    @MainActor
    func testV8StagedMigrationMakesTypedRowsActiveAndKeepsV7SourceByteStable() async throws {
        let finalModelNames = LatticeLensSchemaV8.models.map { String(reflecting: $0) }
        XCTAssertFalse(finalModelNames.contains { $0.hasSuffix(".StoredV7DomainRecord") || $0.hasSuffix(".StoredV8ReferenceRecord") || $0.hasSuffix(".StoredV8SyncJob") },
                       "final active schema must not include a generic kind+payload row")
        XCTAssertTrue(finalModelNames.contains { $0.contains("StoredV8FullTextDocument") })
        XCTAssertTrue(finalModelNames.contains { $0.contains("StoredV8AuthorIndexGeneration") })
        let root = try makeProjectLocalTestDirectory(prefix: "v8-staged-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("legacy-v7.store")
        let activeURL = root.appendingPathComponent("active-v8.store")
        let note = UserNote(id: UUID(), paperID: 11, body: "RI/MOM projector", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
        try makeV7Source(at: sourceURL, note: note)

        let sourceSchema = Schema(versionedSchema: LatticeLensSchemaV7.self)
        let sourceContainer = try ModelContainer(for: sourceSchema, migrationPlan: LatticeLensMigrationPlanV7.self,
                                                 configurations: ModelConfiguration(url: sourceURL))
        let sourceContext = sourceContainer.mainContext
        let sourcePaperBefore = try XCTUnwrap(sourceContext.fetch(FetchDescriptor<StoredV7DomainRecord>(predicate: #Predicate { $0.key == "paper|11" })).first?.payload)

        let outcome = try V8MigrationCoordinator.migrateV7ToV8(sourceURL: sourceURL, activeV8URL: activeURL,
                                                                 backupRoot: root.appendingPathComponent("backups", isDirectory: true))
        XCTAssertEqual(outcome.journal.phase, .activated)
        XCTAssertEqual(outcome.journal.preSummary, outcome.journal.postSummary)
        let journal = try JSONDecoder.latticeLens.decode(V8MigrationJournal.self, from: Data(contentsOf: outcome.journalURL))
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let backupManifestURL = backupRoot.appendingPathComponent(journal.backupManifestID.uuidString, isDirectory: true).appendingPathComponent("manifest.json")
        let backupManifest = try JSONDecoder.latticeLens.decode(V4StoreBackupManifest.self, from: Data(contentsOf: backupManifestURL))
        XCTAssertEqual(backupManifest.manifestHash, journal.backupManifestHash)
        XCTAssertTrue(try V4StoreBackupCoordinator.verify(backupManifest, in: backupRoot))
        let exportedBackupManifest = try String(decoding: JSONEncoder.latticeLens.encode(backupManifest), as: UTF8.self)
        XCTAssertEqual(backupManifest.sourcePathCategory, "sqlite_store_family")
        XCTAssertFalse(exportedBackupManifest.contains(root.path), "backup/export manifest must not leak a private absolute library path")
        let legacyManifestJSON = """
        {"id":"00000000-0000-0000-0000-000000000001","schemaVersion":7,"createdAt":"1970-01-01T00:00:01Z","sourcePath":"/private/legacy/LatticeLens.store","files":[],"manifestHash":"legacy"}
        """
        let legacyManifest = try JSONDecoder.latticeLens.decode(V4StoreBackupManifest.self, from: Data(legacyManifestJSON.utf8))
        XCTAssertEqual(legacyManifest.sourcePathCategory, "legacy_redacted_source")
        let redactedLegacyManifest = String(decoding: try JSONEncoder.latticeLens.encode(legacyManifest), as: UTF8.self)
        XCTAssertFalse(redactedLegacyManifest.contains("/private/legacy"))

        // Source data is reopened with V7 and must retain its original bytes;
        // the final migration reads it as compatibility input, never in-place.
        let sourceAfter = try XCTUnwrap(sourceContext.fetch(FetchDescriptor<StoredV7DomainRecord>(predicate: #Predicate { $0.key == "paper|11" })).first?.payload)
        XCTAssertEqual(sourceAfter, sourcePaperBefore)

        let v8Schema = Schema(versionedSchema: LatticeLensSchemaV8.self)
        let v8Container = try ModelContainer(for: v8Schema, configurations: ModelConfiguration(url: activeURL))
        let v8Context = v8Container.mainContext
        XCTAssertEqual(try XCTUnwrap(v8Context.fetch(FetchDescriptor<StoredV8StoreMarker>()).first).schemaVersion, 80)
        XCTAssertEqual(try v8Context.fetchCount(FetchDescriptor<StoredV8Paper>()), 1)
        XCTAssertEqual(try v8Context.fetchCount(FetchDescriptor<StoredV8Author>()), 1)
        XCTAssertEqual(try v8Context.fetchCount(FetchDescriptor<StoredV8PaperAuthorLink>()), 1)
        XCTAssertEqual(try v8Context.fetchCount(FetchDescriptor<StoredV8ReadingWorkflowState>()), 1,
                       "a V7 source without explicit workflow rows must still open as a final typed store with durable paper state")
        XCTAssertEqual(try V8TypedStoreCodec.verifyMigrationSemanticIntegrity(from: v8Context), outcome.journal.postSummary)

        let activeStore = V8TypedLibraryStore(modelContainer: v8Container)
        let paperBeforeNote = try XCTUnwrap(v8Context.fetch(FetchDescriptor<StoredV8Paper>(predicate: #Predicate { $0.literatureID == 11 })).first?.titlesData)
        try await activeStore.applyReferenceMutation(.upsertNote(UserNote(id: UUID(), paperID: 11, body: "new bounded note", createdAt: Date(), updatedAt: Date())))
        XCTAssertEqual(try v8Context.fetch(FetchDescriptor<StoredV8Paper>(predicate: #Predicate { $0.literatureID == 11 })).first?.titlesData, paperBeforeNote)
        XCTAssertEqual(try v8Context.fetchCount(FetchDescriptor<StoredV8Note>()), 2)

        let tag = LibraryTag(id: UUID(), name: "renormalization", colorName: "blue", createdAt: Date())
        try await activeStore.applyReferenceMutation(.upsertTag(tag))
        try await activeStore.applyReferenceMutation(.setTags(paperID: 11, tagIDs: [tag.id]))
        XCTAssertEqual(try v8Context.fetch(FetchDescriptor<StoredV8Paper>(predicate: #Predicate { $0.literatureID == 11 })).first?.titlesData, paperBeforeNote)
        XCTAssertEqual(try v8Context.fetchCount(FetchDescriptor<StoredV8Tag>()), 1)
        XCTAssertEqual(try v8Context.fetchCount(FetchDescriptor<StoredV8PaperTagLink>()), 1)

        try await activeStore.markRead(true, paperID: 11, at: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(try v8Context.fetch(FetchDescriptor<StoredV8Paper>(predicate: #Predicate { $0.literatureID == 11 })).first?.titlesData, paperBeforeNote)
        XCTAssertTrue(try XCTUnwrap(v8Context.fetch(FetchDescriptor<StoredV8ReadingWorkflowState>(predicate: #Predicate { $0.paperID == 11 })).first).isRead)
        XCTAssertEqual(try v8Context.fetchCount(FetchDescriptor<StoredLibraryDocument>()), 0)
    }

    @MainActor
    func testV8MigrationCrashInjectionFailsClosedOrRecoversOnlyActivatedTarget() throws {
        let points: [(V8MigrationCrashPoint, V8MigrationJournal.Phase)] = [
            (.afterCopied, .copied), (.afterMigrated, .migrated), (.beforeSemanticVerification, .migrated),
            (.beforeActivation, .semanticallyVerified), (.afterActivation, .activated)
        ]
        for (index, item) in points.enumerated() {
            let root = try makeProjectLocalTestDirectory(prefix: "v8-crash-\(index)")
            defer { try? FileManager.default.removeItem(at: root) }
            let sourceURL = root.appendingPathComponent("source-v7.store")
            let activeURL = root.appendingPathComponent("active-v8.store")
            try makeV7Source(at: sourceURL, note: nil)
            XCTAssertThrowsError(try V8MigrationCoordinator.migrateV7ToV8(sourceURL: sourceURL, activeV8URL: activeURL,
                                                                             backupRoot: root.appendingPathComponent("backups", isDirectory: true), crashAt: item.0))
            let journalURL = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".latticelens-v8-migration-") })
            let journal = try JSONDecoder.latticeLens.decode(V8MigrationJournal.self, from: Data(contentsOf: journalURL))
            XCTAssertEqual(journal.phase, item.1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path), "crash injection must preserve V7 source")
            let recovered = try V8MigrationCoordinator.recover(journalURL: journalURL, parent: root)
            if item.0 == .afterActivation {
                XCTAssertEqual(recovered.phase, .activated)
                XCTAssertTrue(FileManager.default.fileExists(atPath: activeURL.path))
            } else {
                XCTAssertEqual(recovered.phase, .rolledBack)
                XCTAssertFalse(FileManager.default.fileExists(atPath: activeURL.path), "unverified staging target must never become active")
            }
        }
    }

    @MainActor
    func testV8AuthorIndexPageAndHOutcomeCommitTypedRowsWithoutSnapshotRewrite() async throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV8.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let paper = makePaper(11)
        try V8TypedStoreCodec.materialize(LibrarySnapshot(papers: [paper.literatureID: paper], schemaVersion: 8),
                                          in: container.mainContext, sourceSchemaVersion: 8)
        let store: any LibraryStoring = V8TypedLibraryStore(modelContainer: container)
        let startedAt = Date(timeIntervalSince1970: 1)
        var author = Author(recid: 52, preferredName: "Typed, Candidate", nativeNames: [], bai: nil,
                            arxivCategories: ["hep-lat"], hIndex: nil, hIndexState: .unknown,
                            isTracked: false, lastSyncedAt: nil)
        var checkpoint = SyncCheckpoint(jobID: AuthorIndexService.hIndexJobID, jobKind: "author-h-index",
                                        query: AuthorIndexService.candidateQuery, generationID: "typed-generation",
                                        pendingIDs: [author.recid], startedAt: startedAt, updatedAt: startedAt,
                                        activeMembership: [], stagingMembership: [author.recid])
        var generation = AuthorIndexGeneration(id: checkpoint.generationID, query: checkpoint.query, startedAt: startedAt,
                                                completedAt: nil, state: .active, activeMembership: [],
                                                stagingMembership: [author.recid], pageCount: 1, hQueueCompleted: 0,
                                                hQueuePending: 1, hQueueFailed: 0, hQueueCancelled: 0,
                                                lastCheckpointAt: startedAt)
        let paperBefore = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<StoredV8Paper>(predicate: #Predicate { $0.literatureID == 11 })).first?.titlesData)
        try await store.commitAuthorIndexPage(authors: [author], checkpoint: checkpoint, generation: generation)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredV8Author>()), 1)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredV8SyncCheckpoint>()), 1)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredV8AuthorIndexGeneration>()), 1)

        let hIndex = HIndexSnapshot(authorRecid: author.recid, all: 27, published: nil, excludesSelfCitations: false,
                                    source: "fixture", query: "fixture", fetchedAt: startedAt, rawSchemaHash: "fixture")
        author.hIndex = hIndex
        author.hIndexState = .qualified
        checkpoint.pendingIDs = []
        checkpoint.successfulRecords = 1
        checkpoint.updatedAt = Date(timeIntervalSince1970: 2)
        generation.hQueueCompleted = 1
        generation.hQueuePending = 0
        generation.lastCheckpointAt = checkpoint.updatedAt
        try await store.commitHIndexOutcome(author: author, checkpoint: checkpoint, generation: generation)
        checkpoint.state = .completed
        checkpoint.completedAt = Date(timeIntervalSince1970: 3)
        checkpoint.lastSuccessfulSyncAt = checkpoint.completedAt
        generation.state = .completed
        generation.activeMembership = generation.stagingMembership
        generation.stagingMembership = []
        generation.completedAt = checkpoint.completedAt
        try await store.commitAuthorIndexCompletion(checkpoint: checkpoint, generation: generation)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.authors[author.recid]?.hIndex, hIndex)
        XCTAssertEqual(snapshot.checkpoints[checkpoint.id]?.state, .completed)
        XCTAssertEqual(snapshot.authorIndexGenerations[generation.id]?.activeMembership, [author.recid])
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<StoredV8Paper>(predicate: #Predicate { $0.literatureID == 11 })).first?.titlesData, paperBefore)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredLibraryDocument>()), 0)
    }

    /// A page checkpoint is the resume boundary.  Persisting the paper first
    /// and the checkpoint/event later creates an unrecoverable ambiguity after
    /// a process death, so this regression opens a real V8 store again and
    /// requires the complete page write-set to appear together.
    @MainActor
    func testV8PaperSyncPageCommitPersistsRowsAndResumeBoundaryTogether() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v8-paper-page")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("library-v8.store")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let paper = makePaper(31)
        let batchID = UUID()
        let checkpoint = SyncCheckpoint(jobID: "literature:77", jobKind: "literature", query: "authors.recid:77",
                                        generationID: "literature-generation", nextURL: URL(string: "https://fixture.invalid/page/2"),
                                        completedPages: 1, successfulRecords: 1, failedRecords: 0,
                                        startedAt: now, updatedAt: now, lastCheckpointAt: now, state: .active)
        let revision = V3RevisionHasher.snapshot(for: paper, syncBatchID: batchID, observedAt: now)
        let radar = RadarEvent(id: UUID(), paperID: paper.literatureID, authorRecids: [77], eventKind: .newPaper,
                               beforeHash: nil, afterHash: revision.recordHash, changedFields: ["record"], syncBatchID: batchID,
                               observedAt: now, sourceURL: revision.sourceURL, isAcknowledged: false)
        let event = SyncJobEvent(id: UUID(), batchID: batchID, jobID: checkpoint.jobID, kind: .pageCompleted,
                                 page: 1, completed: 1, qualified: 0, rejected: 0, failed: 0,
                                 remaining: nil, observedAt: now, message: nil)
        let commit = PaperSyncPageCommit(authorRecid: 77, papers: [paper], revisions: [revision], radarEvents: [radar],
                                         checkpoint: checkpoint, jobEvent: event)

        do {
            let container = try ModelContainer(for: Schema(versionedSchema: LatticeLensSchemaV8.self),
                                               configurations: ModelConfiguration(url: storeURL))
            // Activation happens only through migration/initialization.  The
            // page commit must not manufacture that marker for an arbitrary
            // empty SQLite file.
            try V8TypedStoreCodec.materialize(LibrarySnapshot(schemaVersion: 8), in: container.mainContext, sourceSchemaVersion: 8)
            let store: any LibraryStoring = V8TypedLibraryStore(modelContainer: container)
            let report = try await store.commitPaperSyncPage(commit)
            XCTAssertEqual(report.inserted, 1)
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredV8Paper>()), 1)
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredV8PaperAuthorLink>()), 1)
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredV8RevisionSnapshot>()), 1)
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredV8RadarEvent>()), 1)
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredV8SyncCheckpoint>()), 1)
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredV8SyncJobEvent>()), 1)
            XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredLibraryDocument>()), 0)
        }

        let reopened = try ModelContainer(for: Schema(versionedSchema: LatticeLensSchemaV8.self),
                                          configurations: ModelConfiguration(url: storeURL))
        let recovered = await V8TypedLibraryStore(modelContainer: reopened).snapshot()
        XCTAssertEqual(recovered.papers[paper.literatureID]?.displayTitle, paper.displayTitle)
        XCTAssertEqual(recovered.paperRevisionSnapshots[revision.id], revision)
        XCTAssertEqual(recovered.radarEvents[radar.id], radar)
        XCTAssertEqual(recovered.checkpoints[checkpoint.id], checkpoint)
        XCTAssertEqual(recovered.syncJobEvents[event.id], event)
    }

    @MainActor
    func testV8WorkbenchMutationsUseTypedRowsAndAtomicPhysicsReplacement() async throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV8.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let paper = makePaper(11)
        try V8TypedStoreCodec.materialize(LibrarySnapshot(papers: [paper.literatureID: paper], schemaVersion: 8),
                                          in: container.mainContext, sourceSchemaVersion: 8)
        let store: any LibraryStoring = V8TypedLibraryStore(modelContainer: container)
        let now = Date(timeIntervalSince1970: 1)
        let workspace = PaperWorkspace(id: UUID(), name: "typed workbench", createdAt: now, updatedAt: now,
                                       sortOrder: [paper.literatureID], note: "", frozenExportHash: nil)
        let contract = PhysicsContract(id: UUID(), workspaceID: workspace.id, rowKeys: ["lattice_spacing"], createdAt: now, updatedAt: now)
        let oldCell = PhysicsContractCell(id: UUID(), workspaceID: workspace.id, rowKey: "lattice_spacing", paperID: paper.literatureID,
                                          value: nil, unit: nil, status: .missing, evidenceAnchorIDs: [],
                                          extractionVersion: "physics-contract-v1", sourceDocumentHash: nil, updatedAt: now)
        let replacement = PhysicsContractCell(id: UUID(), workspaceID: workspace.id, rowKey: "lattice_spacing", paperID: paper.literatureID,
                                              value: "0.09", unit: "fm", status: .direct, evidenceAnchorIDs: [],
                                              extractionVersion: "physics-contract-v1", sourceDocumentHash: nil, updatedAt: Date(timeIntervalSince1970: 2))
        let radar = RadarEvent(id: UUID(), paperID: paper.literatureID, authorRecids: [], eventKind: .fieldModified,
                               beforeHash: "before", afterHash: "after", changedFields: ["citationCount"], syncBatchID: UUID(),
                               observedAt: now, sourceURL: URL(string: "https://fixture.invalid/radar")!, isAcknowledged: false)
        let annotation = UserEvidenceAnchor(id: UUID(), paperID: paper.literatureID, documentHash: nil, sourceKind: .abstract,
                                            page: nil, characterRangeStart: nil, characterRangeEnd: nil, quote: "typed quote",
                                            quoteHash: StableHash.sha256("typed quote"), colorName: "yellow", label: "typed",
                                            note: "", status: .valid, createdAt: now, updatedAt: now)
        try await store.applyV3(.saveWorkspace(workspace))
        try await store.applyV3(.saveWorkspaceLink(WorkspacePaperLink(workspaceID: workspace.id, paperID: paper.literatureID, addedAt: now, sortIndex: 0)))
        try await store.applyV3(.savePhysicsContract(contract))
        try await store.applyV3(.savePhysicsCell(oldCell))
        try await store.applyV3(.replacePhysicsMatrix(workspaceID: workspace.id, cells: [replacement]))
        try await store.applyV3(.saveRadarEvent(radar))
        try await store.applyV3(.acknowledgeRadarEvent(radar.id))
        try await store.applyV3(.saveUserAnchor(annotation))
        try await store.applyV3(.quarantineEvidence(id: "typed-evidence"))
        let imported = V3ImportedBibliography(id: UUID(), format: .ris, importedAt: now, sourceCategory: "fixture",
                                               recid: paper.literatureID, doi: "10.1000/typed-accepted", arxivID: nil,
                                               title: "ignored title", authors: [], rawHash: "typed", matchedPaperID: paper.literatureID,
                                               sourceURL: nil)
        let conflict = V3ImportConflict(importedID: imported.id, paperID: paper.literatureID,
                                        fields: ["doi", "title"], status: .accepted, acceptedFields: ["doi"])
        var importedPaper = paper
        importedPaper.doi = try XCTUnwrap(imported.doi)
        try await store.applyV3(.saveImportedBibliography(imported))
        try await store.applyV3(.saveImportConflict(conflict))
        try await store.commitAcceptedImport(paper: importedPaper, conflict: conflict)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.workspaces[workspace.id], workspace)
        XCTAssertEqual(snapshot.workspacePaperLinks, [WorkspacePaperLink(workspaceID: workspace.id, paperID: paper.literatureID, addedAt: now, sortIndex: 0)])
        XCTAssertNil(snapshot.physicsContractCells[oldCell.id])
        XCTAssertEqual(snapshot.physicsContractCells[replacement.id], replacement)
        XCTAssertTrue(snapshot.radarEvents[radar.id]?.isAcknowledged == true)
        XCTAssertEqual(snapshot.userEvidenceAnchors[annotation.id], annotation)
        XCTAssertTrue(snapshot.quarantinedEvidenceIDs.contains("typed-evidence"))
        XCTAssertEqual(snapshot.papers[paper.literatureID]?.doi, imported.doi)
        XCTAssertEqual(snapshot.importConflicts[imported.id]?.acceptedFields, ["doi"])
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredLibraryDocument>()), 0)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredV8PhysicsCell>()), 1)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredV8ImportConflict>()), 1)
    }

    @MainActor
    func testV8TypedDocumentRowsPersistWithScalarFields() throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV8.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let source = try XCTUnwrap(URL(string: "https://fixture.invalid/scalar.pdf"))
        let document = FullTextDocument(paperID: 42, sourceURL: source, sourceKind: .arxivPDF,
                                        sha256: "scalar-hash", byteCount: 9, localFilename: "scalar-hash.pdf",
                                        pageCount: 1, extractionState: .extracted,
                                        downloadedAt: Date(timeIntervalSince1970: 1), lastErrorCategory: nil)
        container.mainContext.insert(StoredV8FullTextDocument(document))
        try container.mainContext.save()
        let row = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<StoredV8FullTextDocument>()).first)
        XCTAssertEqual(try row.decoded(), document)
    }

    @MainActor
    func testV8TypedFullTextPredicatesUseMatchingScalarTypes() throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV8.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let documentID = "42:scalar-hash"
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<StoredV8FullTextDocument>(predicate: #Predicate { $0.paperID == 42 })).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<StoredV8FullTextDocument>(predicate: #Predicate { $0.documentID == documentID })).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<StoredV8DocumentReference>(predicate: #Predicate { $0.id == documentID })).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<StoredV8ContentBlob>(predicate: #Predicate { $0.blobHash == "scalar-hash" })).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<StoredV8EvidenceChunk>(predicate: #Predicate { $0.paperID == 42 && $0.documentHash == "scalar-hash" })).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<StoredV8EvidenceAnchor>(predicate: #Predicate { $0.paperID == 42 && $0.sourceKind == "pdf" })).isEmpty)
    }

    @MainActor
    func testV8TypedFullTextPredicatesCaptureScalarValues() throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV8.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let source = try XCTUnwrap(URL(string: "https://fixture.invalid/captured.pdf"))
        let document = FullTextDocument(paperID: 44, sourceURL: source, sourceKind: .arxivPDF,
                                        sha256: "captured-hash", byteCount: 11, localFilename: "captured-hash.pdf",
                                        pageCount: 1, extractionState: .extracted,
                                        downloadedAt: Date(timeIntervalSince1970: 1), lastErrorCategory: nil)
        let paperID = document.paperID
        let documentID = document.id
        let hash = document.sha256
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<StoredV8FullTextDocument>(predicate: #Predicate { $0.paperID == paperID })).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<StoredV8FullTextDocument>(predicate: #Predicate { $0.documentID == documentID })).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<StoredV8EvidenceChunk>(predicate: #Predicate { $0.paperID == paperID && $0.documentHash == hash })).isEmpty)
    }

    @MainActor
    func testV8TypedBlobAndReferenceRowsPersistWithScalarFields() throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV8.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let source = try XCTUnwrap(URL(string: "https://fixture.invalid/blob-row.pdf"))
        let document = FullTextDocument(paperID: 45, sourceURL: source, sourceKind: .arxivPDF,
                                        sha256: "blob-row-hash", byteCount: 12, localFilename: "blob-row-hash.pdf",
                                        pageCount: 1, extractionState: .extracted,
                                        downloadedAt: Date(timeIntervalSince1970: 1), lastErrorCategory: nil)
        let blob = ContentBlob(hash: document.sha256, byteCount: document.byteCount, localFilename: document.localFilename,
                               referenceCount: 1, createdAt: Date(timeIntervalSince1970: 1))
        let reference = DocumentReference(id: document.id, paperID: document.paperID, documentHash: document.sha256,
                                          sourceURL: document.sourceURL, sourceKind: document.sourceKind,
                                          contentBlobHash: document.sha256, isDeleted: false)
        container.mainContext.insert(StoredV8ContentBlob(blob))
        container.mainContext.insert(StoredV8DocumentReference(reference))
        try container.mainContext.save()
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<StoredV8ContentBlob>()).first?.decoded(), blob)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<StoredV8DocumentReference>()).first?.decoded(), reference)
    }

    @MainActor
    func testV8TypedContentBlobRowPersistsWithScalarFields() throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV8.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let blob = ContentBlob(hash: "blob-only-hash", byteCount: 12, localFilename: "blob-only-hash.pdf",
                               referenceCount: 1, createdAt: Date(timeIntervalSince1970: 1))
        container.mainContext.insert(StoredV8ContentBlob(blob))
        try container.mainContext.save()
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<StoredV8ContentBlob>()).first?.decoded(), blob)
    }

    @MainActor
    func testV8TypedDocumentReferenceRowPersistsWithScalarFields() throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV8.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let source = try XCTUnwrap(URL(string: "https://fixture.invalid/reference-row.pdf"))
        let reference = DocumentReference(id: "46:reference-row-hash", paperID: 46, documentHash: "reference-row-hash",
                                          sourceURL: source, sourceKind: .arxivPDF,
                                          contentBlobHash: "reference-row-hash", isDeleted: false)
        container.mainContext.insert(StoredV8DocumentReference(reference))
        try container.mainContext.save()
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<StoredV8DocumentReference>()).first?.decoded(), reference)
    }

    @MainActor
    func testV8TypedFullTextWriteUsesDocumentAndBlobRowsOnly() async throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV8.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store: any LibraryStoring = V8TypedLibraryStore(modelContainer: container)
        let source = try XCTUnwrap(URL(string: "https://fixture.invalid/store-only.pdf"))
        let document = FullTextDocument(paperID: 43, sourceURL: source, sourceKind: .arxivPDF,
                                        sha256: "store-only-hash", byteCount: 10, localFilename: "store-only-hash.pdf",
                                        pageCount: 1, extractionState: .extracted,
                                        downloadedAt: Date(timeIntervalSince1970: 1), lastErrorCategory: nil)
        let plan = try await store.saveFullTextAndPlan(document: document, chunks: [], anchors: [])
        XCTAssertEqual(plan.documentID, document.id)
        XCTAssertTrue(plan.retiredBlobHashes.isEmpty)
        XCTAssertTrue(plan.retiredLocalFilenames.isEmpty)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredV8FullTextDocument>()), 1)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredV8DocumentReference>()), 1)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<StoredV8ContentBlob>()).first?.referenceCount, 1)
    }

    @MainActor
    func testV8TypedFullTextLifecycleCommitsBlobReferencesBeforeRetirementPlan() async throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV8.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let firstPaper = makePaper(11)
        let secondPaper = makePaper(12)
        try V8TypedStoreCodec.materialize(LibrarySnapshot(papers: [11: firstPaper, 12: secondPaper], schemaVersion: 8), in: container.mainContext, sourceSchemaVersion: 8)
        let store: any LibraryStoring = V8TypedLibraryStore(modelContainer: container)
        let source = try XCTUnwrap(URL(string: "https://fixture.invalid/shared.pdf"))
        let sharedHash = StableHash.sha256("shared-v8-pdf")
        let first = FullTextDocument(paperID: 11, sourceURL: source, sourceKind: .arxivPDF, sha256: sharedHash,
                                     byteCount: 13, localFilename: "\(sharedHash).pdf", pageCount: 1,
                                     extractionState: .extracted, downloadedAt: Date(), lastErrorCategory: nil)
        let second = FullTextDocument(paperID: 12, sourceURL: source, sourceKind: .arxivPDF, sha256: sharedHash,
                                      byteCount: 13, localFilename: "\(sharedHash).pdf", pageCount: 1,
                                      extractionState: .extracted, downloadedAt: Date(), lastErrorCategory: nil)
        let firstPlan = try await store.saveFullTextAndPlan(document: first, chunks: [], anchors: [])
        let secondPlan = try await store.saveFullTextAndPlan(document: second, chunks: [], anchors: [])
        XCTAssertTrue(firstPlan.retiredBlobHashes.isEmpty && firstPlan.retiredLocalFilenames.isEmpty)
        XCTAssertTrue(secondPlan.retiredBlobHashes.isEmpty && secondPlan.retiredLocalFilenames.isEmpty)
        let afterShared = await store.snapshot()
        XCTAssertEqual(afterShared.contentBlobs[sharedHash]?.referenceCount, 2)

        let firstDelete = try await store.deleteFullTextAndPlan(documentID: first.id)
        XCTAssertFalse(firstDelete.shouldDeleteFile)
        XCTAssertEqual(firstDelete.remainingReferenceCount, 1)
        let replacementHash = StableHash.sha256("replacement-v8-pdf")
        let replacement = FullTextDocument(paperID: 12, sourceURL: source, sourceKind: .arxivPDF, sha256: replacementHash,
                                           byteCount: 18, localFilename: "\(replacementHash).pdf", pageCount: 2,
                                           extractionState: .extracted, downloadedAt: Date(), lastErrorCategory: nil)
        let retirement = try await store.saveFullTextAndPlan(document: replacement, chunks: [], anchors: [])
        XCTAssertEqual(retirement.retiredBlobHashes, [sharedHash])
        XCTAssertEqual(retirement.retiredLocalFilenames, ["\(sharedHash).pdf"])
        let afterReplacement = await store.snapshot()
        XCTAssertNil(afterReplacement.fullTextDocuments[second.id])
        XCTAssertNotNil(afterReplacement.fullTextDocuments[replacement.id])
        XCTAssertEqual(afterReplacement.contentBlobs[sharedHash]?.referenceCount, 0)
        XCTAssertEqual(afterReplacement.contentBlobs[replacementHash]?.referenceCount, 1)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredV8FullTextDocument>()), 1)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredLibraryDocument>()), 0)
    }

    @MainActor
    func testV7ReadMutationUsesBoundedPaperAndReadingStateTransaction() async throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV7.self)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV7.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.insert(StoredV7StoreMarker())
        try container.mainContext.save()
        let store = SwiftDataLibraryStore(modelContainer: container)
        _ = try await store.upsert(papers: [makePaper(11), makePaper(12)], for: 21)

        let context = ModelContext(container)
        let unchangedDescriptor = FetchDescriptor<StoredV7DomainRecord>(predicate: #Predicate { $0.key == "paper|12" })
        let unchangedPayload = try XCTUnwrap(context.fetch(unchangedDescriptor).first?.payload)
        try await store.markRead(true, paperID: 11, at: Date(timeIntervalSince1970: 1_700_000_000))

        let changedDescriptor = FetchDescriptor<StoredV7DomainRecord>(predicate: #Predicate { $0.key == "paper|11" })
        let changed = try XCTUnwrap(context.fetch(changedDescriptor).first)
        let changedPaper = try JSONDecoder.latticeLens.decode(Paper.self, from: changed.payload)
        XCTAssertTrue(changedPaper.isRead)
        XCTAssertEqual(changedPaper.readAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(try context.fetch(unchangedDescriptor).first?.payload, unchangedPayload,
                       "read-state mutation must not rewrite an unrelated V7 paper row")

        let readingDescriptor = FetchDescriptor<StoredV7DomainRecord>(predicate: #Predicate { $0.key == "readingState|11" })
        let reading = try XCTUnwrap(context.fetch(readingDescriptor).first)
        XCTAssertEqual(try JSONDecoder.latticeLens.decode(ReadingState.self, from: reading.payload).isRead, true)
        let projection = try XCTUnwrap(context.fetch(FetchDescriptor<StoredV4Paper>(predicate: #Predicate { $0.literatureID == 11 })).first)
        XCTAssertTrue(projection.isRead)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredLibraryDocument>()), 0)
    }

    @MainActor
    func testV7MaterializesLegacySnapshotOnceThenUsesDomainRecordsAsActiveTruth() async throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV7.self)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV7.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let legacy = LibrarySnapshot(papers: [11: makePaper(11)], schemaVersion: 6)
        let legacyData = try JSONEncoder.latticeLens.encode(legacy)
        container.mainContext.insert(StoredLibraryDocument(schemaVersion: 6, snapshotData: legacyData))
        container.mainContext.insert(StoredV7StoreMarker())
        try container.mainContext.save()

        let store = SwiftDataLibraryStore(modelContainer: container)
        let materializedSnapshot = await store.snapshot()
        XCTAssertEqual(materializedSnapshot.papers[11]?.displayTitle, "Paper 11")
        let context = ModelContext(container)
        let marker = try XCTUnwrap(context.fetch(FetchDescriptor<StoredV7StoreMarker>()).first)
        XCTAssertEqual(marker.schemaVersion, 71)
        XCTAssertTrue(marker.importedLegacyDocument)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredV7DomainRecord>()).filter { $0.kind == "paper" }.count, 1)
        let retainedLegacy = try XCTUnwrap(context.fetch(FetchDescriptor<StoredLibraryDocument>()).first)
        XCTAssertEqual(retainedLegacy.snapshotData, legacyData, "legacy snapshot is retained only as rollback material")
    }

    @MainActor
    func testDiskBackedV6ToV7MaterializesWithVerifiedPreOpenBackupAndReopens() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v7-disk-materialization")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("library.store")
        let legacy = LibrarySnapshot(papers: [11: makePaper(11)], schemaVersion: 6)
        let legacyData = try JSONEncoder.latticeLens.encode(legacy)

        do {
            let v6Schema = Schema(versionedSchema: LatticeLensSchemaV6.self)
            let v6Container = try ModelContainer(for: v6Schema, migrationPlan: LatticeLensMigrationPlanV6.self,
                                                 configurations: ModelConfiguration(url: storeURL))
            v6Container.mainContext.insert(StoredLibraryDocument(schemaVersion: 6, snapshotData: legacyData))
            try v6Container.mainContext.save()
        }

        let bootstrap = try V4StoreBootstrapCoordinator.prepare(storeURL: storeURL, targetSchemaVersion: 7)
        var expectedPostRowCount = 0
        do {
            let v7Schema = Schema(versionedSchema: LatticeLensSchemaV7.self)
            let container = try ModelContainer(for: v7Schema, migrationPlan: LatticeLensMigrationPlanV7.self,
                                               configurations: ModelConfiguration(url: storeURL))
            let context = container.mainContext
            context.insert(StoredV7StoreMarker())
            try context.save()
            let store = SwiftDataLibraryStore(modelContainer: container)
            let materialized = await store.snapshot()
            XCTAssertEqual(materialized.papers[11]?.displayTitle, "Paper 11")
            XCTAssertEqual(try context.fetch(FetchDescriptor<StoredV7DomainRecord>()).filter { $0.kind == "paper" }.count, 1)
            XCTAssertEqual(try XCTUnwrap(context.fetch(FetchDescriptor<StoredV7StoreMarker>()).first).schemaVersion, 71)
            XCTAssertEqual(try XCTUnwrap(context.fetch(FetchDescriptor<StoredLibraryDocument>()).first).snapshotData, legacyData)
            expectedPostRowCount = try context.fetchCount(FetchDescriptor<StoredV7DomainRecord>())
            try bootstrap.complete(postRowCount: expectedPostRowCount)
        } catch {
            try? bootstrap.fail(error)
            throw error
        }

        let journals = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".latticelens-migration-library.store-") }
        let journalURL = try XCTUnwrap(journals.first)
        let journal = try JSONDecoder.latticeLens.decode(V4StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
        XCTAssertEqual(journal.targetSchemaVersion, 7)
        XCTAssertEqual(journal.phase, .completed)
        XCTAssertEqual(journal.postRowCount, expectedPostRowCount)
        XCTAssertTrue(try V4StoreBackupCoordinator.verify(journal.backupManifest,
                                                            in: root.appendingPathComponent("LatticeLens-StoreBackups", isDirectory: true)))

        let v7Schema = Schema(versionedSchema: LatticeLensSchemaV7.self)
        let reopenedContainer = try ModelContainer(for: v7Schema, migrationPlan: LatticeLensMigrationPlanV7.self,
                                                   configurations: ModelConfiguration(url: storeURL))
        let reopenedStore = SwiftDataLibraryStore(modelContainer: reopenedContainer)
        let reopenedSnapshot = await reopenedStore.snapshot()
        XCTAssertEqual(reopenedSnapshot.papers[11]?.displayTitle, "Paper 11")
    }

    func testDiskBackedNormalizedStoreBackupVerifyRestoreAndTamperDrill() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v4-disk-drill")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let activeStore = root.appendingPathComponent("active.store")
        do {
            let store = try V4NormalizedStoreFactory.makeDiskBacked(at: activeStore)
            try await store.upsert(paper: StoredV4Paper(literatureID: 11, title: "disk-backed", abstractText: "local migration fixture"))
            let savedPaperCount = try await store.paperCount()
            XCTAssertEqual(savedPaperCount, 1)
        }

        let backups = root.appendingPathComponent("backups", isDirectory: true)
        let manifest = try V4StoreBackupCoordinator.createBackup(source: activeStore, destinationRoot: backups)
        XCTAssertTrue(try V4StoreBackupCoordinator.verify(manifest, in: backups))
        let restoredRoot = root.appendingPathComponent("restored", isDirectory: true)
        try V4StoreBackupCoordinator.restore(manifest, from: backups, to: restoredRoot)
        let restoredStore = try V4NormalizedStoreFactory.makeDiskBacked(at: restoredRoot.appendingPathComponent("active.store"))
        let restoredPaperCount = try await restoredStore.paperCount()
        XCTAssertEqual(restoredPaperCount, 1)

        let backupFile = try XCTUnwrap(manifest.files.first?.relativePath)
        let backupURL = backups.appendingPathComponent(manifest.id.uuidString, isDirectory: true).appendingPathComponent(backupFile)
        try Data("tampered backup".utf8).write(to: backupURL, options: .atomic)
        XCTAssertFalse(try V4StoreBackupCoordinator.verify(manifest, in: backups))
        XCTAssertThrowsError(try V4StoreBackupCoordinator.restore(manifest, from: backups, to: root.appendingPathComponent("rejected", isDirectory: true)))
    }

    func testStoreBackupPreservesSQLiteSidecarsAsOneVerifiedFamily() throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v4-sidecars")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = root.appendingPathComponent("library.store")
        try Data("main".utf8).write(to: store, options: .atomic)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: store.path + "-wal"), options: .atomic)
        try Data("shm".utf8).write(to: URL(fileURLWithPath: store.path + "-shm"), options: .atomic)

        let backups = root.appendingPathComponent("backups", isDirectory: true)
        let manifest = try V4StoreBackupCoordinator.createBackup(source: store, destinationRoot: backups, schemaVersion: 6)
        XCTAssertEqual(Set(manifest.files.map(\.relativePath)), Set(["library.store", "library.store-wal", "library.store-shm"]))
        XCTAssertTrue(try V4StoreBackupCoordinator.verify(manifest, in: backups))
        let restored = root.appendingPathComponent("restored", isDirectory: true)
        try V4StoreBackupCoordinator.restore(manifest, from: backups, to: restored)
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("library.store-wal")), Data("wal".utf8))
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("library.store-shm")), Data("shm".utf8))
    }

    func testPreOpenV5ToV6MigrationWritesVerifiedBackupAndIndependentJournal() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v4-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("library.store")
        do {
            let v5Schema = Schema(versionedSchema: LatticeLensSchemaV5.self)
            let v5Container = try ModelContainer(for: v5Schema, migrationPlan: LatticeLensMigrationPlanV5.self,
                                                 configurations: ModelConfiguration(url: storeURL))
            let context = ModelContext(v5Container)
            context.insert(StoredV4Paper(literatureID: 42, title: "v5 row", abstractText: "must survive migration"))
            try context.save()
        }

        let v6 = try V4NormalizedStoreFactory.makeDiskBacked(at: storeURL)
        let count = try await v6.paperCount()
        XCTAssertEqual(count, 1)
        let journals = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".latticelens-migration-library.store-") }
        let journalURL = try XCTUnwrap(journals.first)
        let journal = try JSONDecoder.latticeLens.decode(V4StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
        XCTAssertEqual(journal.phase, .completed)
        XCTAssertEqual(journal.targetSchemaVersion, 6)
        XCTAssertTrue(try V4StoreBackupCoordinator.verify(journal.backupManifest,
                                                            in: root.appendingPathComponent("LatticeLens-StoreBackups", isDirectory: true)))
    }

    func testAnalysisDeadlineEnforcerSeparatesConnectFirstContentIdleHardAndOversize() async throws {
        let short = V4AnalysisTimeouts(connect: 0.015, firstContent: 0.025, idle: 0.020, hard: 0.040)

        await assertDeadline(.connect, timeouts: short) { _, _ in
            try await Task.sleep(nanoseconds: 35_000_000)
            return "never accepted"
        }
        await assertDeadline(.firstContent, timeouts: short) { transport, _ in
            await transport(.connected)
            await transport(.waitingFirstContent)
            try await Task.sleep(nanoseconds: 40_000_000)
            return "never accepted"
        }
        await assertDeadline(.idle, timeouts: short) { transport, delta in
            await transport(.connected)
            await transport(.waitingFirstContent)
            await delta("{")
            try await Task.sleep(nanoseconds: 35_000_000)
            return "never accepted"
        }
        await assertDeadline(.hard, timeouts: V4AnalysisTimeouts(connect: 0.100, firstContent: 0.100, idle: 0.100, hard: 0.020)) { transport, _ in
            await transport(.connected)
            await transport(.waitingFirstContent)
            try await Task.sleep(nanoseconds: 45_000_000)
            return "never accepted"
        }
        await assertDeadline(.responseTooLarge, timeouts: short, maximumResponseBytes: 4) { transport, delta in
            await transport(.connected)
            await transport(.waitingFirstContent)
            await delta("oversize")
            return "oversize"
        }
    }

    func testTransportHeartbeatPreventsFalseIdleFailureDuringLongSSEGap() async throws {
        let timeouts = V4AnalysisTimeouts(connect: 0.05, firstContent: 0.05, idle: 0.03, hard: 0.20)
        let result = try await V4AnalysisDeadlineEnforcer.perform(
            timeouts: timeouts, maximumResponseBytes: 100,
            onTransportState: { _ in }, onDelta: { _ in }
        ) { transport, delta in
            await transport(.connected)
            await transport(.waitingFirstContent)
            await delta("{")
            // A keep-alive byte arrives before the 30 ms idle budget, but it
            // does not decode to a content delta.
            try await Task.sleep(nanoseconds: 20_000_000)
            await transport(.receivedFirstContent)
            try await Task.sleep(nanoseconds: 20_000_000)
            await delta("}")
            return "{}"
        }
        XCTAssertEqual(result, "{}")
    }

    func testAnalysisDeadlineEnforcerDropsLateCallbacksAndDoesNotRetry() async throws {
        let recorder = V4DeadlineCallbackRecorder()
        let invocations = V4DeadlineInvocationCounter()
        do {
            _ = try await V4AnalysisDeadlineEnforcer.perform(
                timeouts: V4AnalysisTimeouts(connect: 0.010, firstContent: 0.030, idle: 0.030, hard: 0.050),
                maximumResponseBytes: 100,
                onTransportState: { state in await recorder.record(state.rawValue) },
                onDelta: { value in await recorder.record(value) }
            ) { transport, delta in
                await invocations.increment()
                try? await Task.sleep(nanoseconds: 30_000_000) // deliberately survive cancellation
                await transport(.connected)
                await delta("late")
                return "late"
            }
            XCTFail("connect timeout must reject the request")
        } catch let error as V4AnalysisDeadlineError {
            XCTAssertEqual(error, .connect)
        }
        let invocationCount = await invocations.currentValue()
        let callbacks = await recorder.snapshot()
        XCTAssertEqual(invocationCount, 1, "deadline failure must not retry the request")
        XCTAssertTrue(callbacks.isEmpty, "callbacks after terminal deadline must not update UI state")
    }

    /// A notebook entry is a real typed V8 record, not an in-memory editor
    /// draft.  Both its independently auditable anchor links and their user
    /// selected order must survive a complete disk-backed relaunch.
    @MainActor
    func testV8NotebookEntryPersistsOrderedMultiAnchorLinksAcrossRelaunch() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v8-notebook-links")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("library-v8.store")
        let paper = makePaper(41)
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let evidence = EvidenceAnchor(id: "abstract:41:setup", paperID: paper.literatureID, sourceKind: .abstract,
                                      page: nil, section: nil, quote: "We use a=0.09 fm.",
                                      quoteHash: StableHash.sha256("We use a=0.09 fm."), figureKey: nil)
        let annotation = UserEvidenceAnchor(id: UUID(), paperID: paper.literatureID, documentHash: nil, sourceKind: .abstract,
                                            page: nil, characterRangeStart: nil, characterRangeEnd: nil,
                                            quote: "The source-sink separation is 1.0 fm.",
                                            quoteHash: StableHash.sha256("The source-sink separation is 1.0 fm."),
                                            colorName: "yellow", label: "source-sink", note: "fixture", status: .valid,
                                            createdAt: now, updatedAt: now)
        let anchorOrder = [annotation.id.uuidString, evidence.id]
        let entryID: UUID

        do {
            let container = try ModelContainer(for: Schema(versionedSchema: LatticeLensSchemaV8.self),
                                               configurations: ModelConfiguration(url: storeURL))
            let seed = LibrarySnapshot(papers: [paper.literatureID: paper], evidenceAnchors: [evidence.id: evidence],
                                       userEvidenceAnchors: [annotation.id: annotation], schemaVersion: 8)
            try V8TypedStoreCodec.materialize(seed, in: container.mainContext, sourceSchemaVersion: 8)
            let service = V3WorkbenchService(store: V8TypedLibraryStore(modelContainer: container))
            let saved = try await service.saveNotebookEntry(paperID: paper.literatureID, title: "two anchors",
                                                            body: "Do not flatten the anchor order.", anchorIDs: anchorOrder)
            entryID = saved.id
            let context = container.mainContext
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredV8NotebookEntry>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredV8NotebookAnchorLink>()), 2)
        }

        let reopened = try ModelContainer(for: Schema(versionedSchema: LatticeLensSchemaV8.self),
                                          configurations: ModelConfiguration(url: storeURL))
        let snapshot = await V8TypedLibraryStore(modelContainer: reopened).snapshot()
        XCTAssertEqual(snapshot.notebookEntries[entryID]?.title, "two anchors")
        XCTAssertEqual(snapshot.notebookEntries[entryID]?.paperID, paper.literatureID)
        XCTAssertEqual(snapshot.notebookAnchorLinks.filter { $0.entryID == entryID }.sorted { $0.sortIndex < $1.sortIndex }.map(\.anchorID),
                       anchorOrder)
    }

    /// Notebook links are paper scoped.  A foreign anchor, a stale user
    /// annotation, or a deleted entry must not leave a superficially valid
    /// cross-paper citation trail in the local notebook.
    func testNotebookRejectsForeignAndStaleAnchorsAndEntryDeleteCascadesLinks() async throws {
        let store = InMemoryLibraryStore()
        let localPaper = makePaper(51)
        let foreignPaper = makePaper(52)
        _ = try await store.upsert(papers: [localPaper, foreignPaper], for: 7)
        let local = EvidenceAnchor(id: "abstract:51:local", paperID: localPaper.literatureID, sourceKind: .abstract,
                                   page: nil, section: nil, quote: "local evidence", quoteHash: StableHash.sha256("local evidence"), figureKey: nil)
        let foreign = EvidenceAnchor(id: "abstract:52:foreign", paperID: foreignPaper.literatureID, sourceKind: .abstract,
                                     page: nil, section: nil, quote: "foreign evidence", quoteHash: StableHash.sha256("foreign evidence"), figureKey: nil)
        try await store.saveEvidenceAnchors([local, foreign])
        let stale = UserEvidenceAnchor(id: UUID(), paperID: localPaper.literatureID, documentHash: "old-document", sourceKind: .pdf,
                                       page: 2, characterRangeStart: 5, characterRangeEnd: 10, quote: "stale",
                                       quoteHash: StableHash.sha256("stale"), colorName: "red", label: "stale", note: "",
                                       status: .stale, createdAt: Date(), updatedAt: Date())
        try await store.applyV3(.saveUserAnchor(stale))
        let service = V3WorkbenchService(store: store)

        do {
            _ = try await service.saveNotebookEntry(paperID: localPaper.literatureID, title: "invalid foreign", body: "",
                                                    anchorIDs: [foreign.id])
            XCTFail("a foreign-paper anchor must be rejected")
        } catch {}
        do {
            _ = try await service.saveNotebookEntry(paperID: localPaper.literatureID, title: "invalid stale", body: "",
                                                    anchorIDs: [stale.id.uuidString])
            XCTFail("a stale annotation must be rejected")
        } catch {}

        let saved = try await service.saveNotebookEntry(paperID: localPaper.literatureID, title: "local only", body: "",
                                                        anchorIDs: [local.id])
        let beforeDelete = await store.snapshot()
        XCTAssertEqual(beforeDelete.notebookAnchorLinks.filter { $0.entryID == saved.id }.count, 1)
        try await service.deleteNotebookEntry(saved.id)
        let afterDelete = await store.snapshot()
        XCTAssertNil(afterDelete.notebookEntries[saved.id])
        XCTAssertTrue(afterDelete.notebookAnchorLinks.allSatisfy { $0.entryID != saved.id },
                      "entry deletion must remove all of its anchor-link rows in the same local mutation")
    }

    @MainActor
    private func makeV7Source(at url: URL, note: UserNote?) throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV7.self)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV7.self,
                                           configurations: ModelConfiguration(url: url))
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let author = Author(recid: 77, preferredName: "Fixture, V8", nativeNames: [], bai: "V.Fixture.1",
                            arxivCategories: ["hep-lat"], hIndex: nil, hIndexState: .qualified,
                            isTracked: true, lastSyncedAt: now)
        let paper = makePaper(11)
        let link = PaperAuthorLink(paperID: 11, authorRecid: 77, position: 0)
        let state = ReadingState(paperID: 11, isRead: false, readAt: nil, isFavorite: false, updatedAt: now)
        context.insert(StoredV7StoreMarker(schemaVersion: 71, materializedAt: now, importedLegacyDocument: false))
        func insert<T: Encodable>(_ kind: String, id: String, _ value: T) throws {
            context.insert(StoredV7DomainRecord(key: "\(kind)|\(id)", kind: kind, recordID: id,
                                                payload: try JSONEncoder.latticeLens.encode(value), updatedAt: now))
        }
        try insert("author", id: "77", author)
        try insert("paper", id: "11", paper)
        try insert("paperAuthorLink", id: "11:77", link)
        try insert("readingState", id: "11", state)
        if let note { try insert("note", id: note.id.uuidString, note) }
        try context.save()
    }

    private func assertDeadline(
        _ expected: V4AnalysisDeadlineError,
        timeouts: V4AnalysisTimeouts,
        maximumResponseBytes: Int = 100,
        operation: @escaping @Sendable (@escaping @Sendable (LLMTransportState) async -> Void,
                                        @escaping @Sendable (String) async -> Void) async throws -> String
    ) async {
        do {
            _ = try await V4AnalysisDeadlineEnforcer.perform(timeouts: timeouts, maximumResponseBytes: maximumResponseBytes,
                                                              onTransportState: { _ in }, onDelta: { _ in }, operation: operation)
            XCTFail("expected \(expected) deadline failure")
        } catch let error as V4AnalysisDeadlineError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

private actor V4DeadlineCallbackRecorder {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor V4DeadlineInvocationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
    func currentValue() -> Int { value }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                          file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected asynchronous error", file: file, line: line)
    } catch {}
}
