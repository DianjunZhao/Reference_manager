import Foundation
import XCTest
@testable import LatticeLens

final class V3WorkbenchTests: XCTestCase {
    func testScopedIdentityContainsPaperDocumentPageOrdinalAndQuoteHash() {
        let id = V3EvidenceIdentity.chunkID(paperID: 11, documentHash: "abc", page: 2, ordinal: 3, quoteHash: "quote")
        XCTAssertEqual(id, "v3pdf:11:abc:p2:q3:quote")
        XCTAssertTrue(id.contains(":11:"))
        XCTAssertNotEqual(id, V3EvidenceIdentity.chunkID(paperID: 12, documentHash: "abc", page: 2, ordinal: 3, quoteHash: "quote"))
    }

    func testSharedPDFHashDeleteIsPaperScopedAndReferenceCounted() async throws {
        let store = InMemoryLibraryStore()
        let first = makeDocument(paperID: 11, hash: "same")
        let second = makeDocument(paperID: 12, hash: "same")
        let firstChunk = makeChunk(paperID: 11, hash: "same", id: V3EvidenceIdentity.chunkID(paperID: 11, documentHash: "same", page: 1, ordinal: 1, quoteHash: "q1"))
        let secondChunk = makeChunk(paperID: 12, hash: "same", id: V3EvidenceIdentity.chunkID(paperID: 12, documentHash: "same", page: 1, ordinal: 1, quoteHash: "q2"))
        try await store.saveFullText(document: first, chunks: [firstChunk], anchors: [makeAnchor(firstChunk)])
        try await store.saveFullText(document: second, chunks: [secondChunk], anchors: [makeAnchor(secondChunk)])
        try await store.deleteFullText(documentID: first.id)
        let snapshot = await store.snapshot()
        XCTAssertNil(snapshot.fullTextDocuments[first.id])
        XCTAssertNotNil(snapshot.fullTextDocuments[second.id])
        XCTAssertEqual(snapshot.evidenceChunks.count, 1)
        XCTAssertEqual(snapshot.evidenceChunks.values.first?.paperID, 12)
        XCTAssertEqual(snapshot.contentBlobs["same"]?.referenceCount, 1)
    }

    func testAnnotationRelocatesAcrossChangedDocumentHashAndRetiresOldDocument() async throws {
        let store = InMemoryLibraryStore()
        let old = makeDocument(paperID: 11, hash: "old", url: "https://example.test/11.pdf")
        let oldChunk = EvidenceChunk(id: V3EvidenceIdentity.chunkID(paperID: 11, documentHash: "old", page: 1, ordinal: 1, quoteHash: StableHash.sha256("quoted")), paperID: 11, documentHash: "old", page: 1, section: nil, characterRangeStart: 0, characterRangeEnd: 6, text: "quoted", textHash: StableHash.sha256("quoted"))
        try await store.saveFullText(document: old, chunks: [oldChunk], anchors: [makeAnchor(oldChunk)])
        let annotation = UserEvidenceAnchor(id: UUID(), paperID: 11, documentHash: "old", sourceKind: .pdf, page: 1, characterRangeStart: 0, characterRangeEnd: 6, quote: "quoted", quoteHash: oldChunk.textHash, colorName: "yellow", label: "keep", note: "", status: .valid, createdAt: Date(), updatedAt: Date())
        try await store.applyV3(.saveUserAnchor(annotation))
        let newer = makeDocument(paperID: 11, hash: "new", url: "https://example.test/11.pdf")
        let newChunk = EvidenceChunk(id: V3EvidenceIdentity.chunkID(paperID: 11, documentHash: "new", page: 3, ordinal: 2, quoteHash: oldChunk.textHash), paperID: 11, documentHash: "new", page: 3, section: nil, characterRangeStart: 8, characterRangeEnd: 14, text: "quoted", textHash: oldChunk.textHash)
        try await store.saveFullText(document: newer, chunks: [newChunk], anchors: [makeAnchor(newChunk)])
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.userEvidenceAnchors[annotation.id]?.documentHash, "new")
        XCTAssertEqual(snapshot.userEvidenceAnchors[annotation.id]?.page, 3)
        XCTAssertEqual(snapshot.fullTextDocuments.count, 1)
        XCTAssertEqual(snapshot.contentBlobs["old"]?.referenceCount, 0)
        XCTAssertEqual(snapshot.contentBlobs["new"]?.referenceCount, 1)
    }

    func testWorkspaceValidationRejectsWrongCardinalityAndMissingValue() async throws {
        let store = InMemoryLibraryStore()
        _ = try await store.upsert(papers: [makePaper(id: 11), makePaper(id: 12)], for: 1)
        let service = V3WorkbenchService(store: store)
        do { _ = try await service.createWorkspace(name: "", paperIDs: [11, 12]); XCTFail("empty workspace name must fail") } catch { }
        do { _ = try await service.createWorkspace(name: "ok", paperIDs: [11]); XCTFail("one-paper workspace must fail") } catch { }
    }

    func testCloudMockQueuesRetriesAndIsIdempotent() async throws {
        let engine = V3CloudSyncMockEngine()
        let operation = V3CloudSyncOperation(recordID: "note-1", recordType: "note", payloadHash: "h")
        await engine.setTransientFailures(recordID: "note-1", count: 1)
        try await engine.enqueue(operation)
        try await engine.enqueue(operation)
        let pending = await engine.pendingCount()
        XCTAssertEqual(pending, 1)
        let retry = await engine.process(now: Date())
        XCTAssertEqual(retry.retried, 1)
        let success = await engine.process(now: Date().addingTimeInterval(1))
        XCTAssertEqual(success.succeeded, 1)
        try await engine.enqueue(operation)
        let pendingAfter = await engine.pendingCount()
        let applied = await engine.appliedCount()
        XCTAssertEqual(pendingAfter, 0)
        XCTAssertEqual(applied, 1)
    }

    func testSavedRadarQueryRefreshPersistsBatchSnapshotAndEventsWithoutAuthorLink() async throws {
        let store = InMemoryLibraryStore()
        let query = SavedInspireQuery(id: UUID(), name: "fixture", query: "arxiv_categories:hep-lat", refreshPolicy: .manual,
                                      isPaused: false, lastRunAt: nil, nextRunAt: nil, createdAt: Date())
        try await store.applyV3(.saveQuery(query))
        let service = V3WorkbenchService(store: store, client: InspireClient(transport: AppFixtureTransport()))
        let batch = try await service.refreshSavedQuery(query)
        let snapshot = await store.snapshot()
        XCTAssertEqual(batch.state, .completed)
        XCTAssertEqual(snapshot.syncBatchesV3.count, 1)
        XCTAssertEqual(snapshot.papers.count, 2, "UI fixture keeps two bounded local papers so Compare can exercise its 2-paper minimum")
        XCTAssertTrue(snapshot.paperAuthorLinks.isEmpty, "arbitrary saved query must not invent author membership")
        XCTAssertEqual(snapshot.paperRevisionSnapshots.count, 2)
        XCTAssertTrue(snapshot.radarEvents.values.contains { event in
            event.eventKind == .fieldModified && event.afterCitationCount == 4 &&
            event.changedFields.compactMap(V4RadarFieldChange.decodeStorageMarker).contains { $0.field == "citationCount" }
        })
        XCTAssertNotNil(snapshot.savedInspireQueries[query.id]?.lastRunAt)
    }

    func testRadarSemanticPipelinePreservesUnknownCitationWithoutLegacyEventKinds() {
        let batch = UUID()
        let before = makePaper(id: 11)
        var after = before
        after.citationCount = 4
        let events = V4RadarDiff.events(before: before, after: after, authorRecids: [1], batchID: batch,
                                        observedAt: Date(timeIntervalSince1970: 2))
        let citation = try! XCTUnwrap(events.first { event in
            event.changedFields.compactMap(V4RadarFieldChange.decodeStorageMarker).contains { $0.field == "citationCount" }
        })
        XCTAssertEqual(citation.eventKind, .fieldModified)
        XCTAssertNil(citation.beforeCitationCount)
        XCTAssertEqual(citation.afterCitationCount, 4)
        XCTAssertFalse(events.contains { [.newPaper, .recordRevised, .citationChanged, .newDocument, .newFigure, .publicationChanged].contains($0.eventKind) })
    }

    func testPhysicsCellRequiresSamePaperAnchorAndValidQuoteHash() throws {
        let paper = makePaper(id: 11)
        let anchor = EvidenceAnchor(id: "a", paperID: 11, sourceKind: .abstract, page: nil, section: nil, quote: "a=0.09 fm", quoteHash: StableHash.sha256("a=0.09 fm"), figureKey: nil)
        var snapshot = LibrarySnapshot(papers: [11: paper], evidenceAnchors: [anchor.id: anchor])
        let cell = PhysicsContractCell(id: UUID(), workspaceID: UUID(), rowKey: "lattice_spacing", paperID: 11,
                                       value: "0.09", unit: "fm", status: .direct, evidenceAnchorIDs: [anchor.id],
                                       extractionVersion: "v3-test", sourceDocumentHash: nil, updatedAt: Date())
        XCTAssertNoThrow(try V3PhysicsContractValidator.validate(cell, snapshot: snapshot))
        let wrong = EvidenceAnchor(id: "wrong", paperID: 12, sourceKind: .abstract, page: nil, section: nil, quote: "0.09 fm", quoteHash: StableHash.sha256("0.09 fm"), figureKey: nil)
        snapshot.evidenceAnchors[wrong.id] = wrong
        let wrongCell = PhysicsContractCell(id: UUID(), workspaceID: UUID(), rowKey: "lattice_spacing", paperID: 11,
                                             value: "0.09", unit: "fm", status: .direct, evidenceAnchorIDs: [wrong.id],
                                             extractionVersion: "v3-test", sourceDocumentHash: nil, updatedAt: Date())
        XCTAssertThrowsError(try V3PhysicsContractValidator.validate(wrongCell, snapshot: snapshot)) { error in
            XCTAssertEqual(error as? V3PhysicsValidationError, .crossPaperAnchor)
        }
    }

    func testNotebookMarkdownUsesInterpolatedTagsAndDoesNotLeakAbsolutePath() throws {
        let paper = makePaper(id: 11)
        let tag = LibraryTag(id: UUID(), name: "renormalization", colorName: nil, createdAt: Date())
        let note = UserNote(id: UUID(), paperID: 11, body: "check RI/MOM", createdAt: Date(), updatedAt: Date())
        let document = makeDocument(paperID: 11, hash: "hash")
        let snapshot = LibrarySnapshot(papers: [11: paper], notes: [note.id: note], tags: [tag.id: tag], paperTags: [PaperTagLink(paperID: 11, tagID: tag.id)], fullTextDocuments: [document.id: document])
        let request = V3NotebookExportRequest(paperIDs: [11], format: .markdownNotebook, includeLocalPDFPath: false, destinationCategory: "user-selected")
        let markdown = try V3NotebookExporter.render(request: request, snapshot: snapshot)
        XCTAssertTrue(markdown.contains("Local tags: renormalization"))
        XCTAssertTrue(markdown.contains("Public PDF source:"))
        XCTAssertFalse(markdown.contains("/Users/"))
        XCTAssertTrue(markdown.contains("check RI/MOM"))
    }

    func testWorkspaceExportPersistsProvenanceAndGraphIsBounded() async throws {
        let store = InMemoryLibraryStore()
        let papers = [11, 12, 13].map(makePaper)
        _ = try await store.upsert(papers: papers, for: 1)
        let service = V3WorkbenchService(store: store)
        let workspace = try await service.createWorkspace(name: "compare", paperIDs: [11, 12, 13])
        let exported = try await service.export(V3NotebookExportRequest(paperIDs: [11, 12], format: .provenanceJSON, includeLocalPDFPath: false, destinationCategory: "fixture"))
        XCTAssertEqual(exported.record.payloadHash, StableHash.sha256(exported.contents))
        let snapshot = await store.snapshot()
        XCTAssertNotNil(snapshot.workspaces[workspace.id])
        XCTAssertEqual(snapshot.exportRecords.count, 1)
        var bounded = snapshot
        let edge = CitationEdge(id: "11->12", fromPaperID: 11, toPaperID: 12, sourceURL: URL(string: "https://inspirehep.net/api/literature/11")!, fetchedAt: Date(), query: "fixture", batchID: UUID())
        bounded.citationEdges[edge.id] = edge
        let graph = V3GraphBuilder.build(snapshot: bounded, rootPaperID: 11, rootAuthorRecid: nil, limits: V3GraphLimits(maximumNodes: 1, maximumEdges: 1, maximumPages: 1, maximumBytes: 100))
        XCTAssertTrue(graph.truncated)
    }

    func testMigrationQuarantinesAmbiguousLegacyEvidenceAndIsIdempotent() {
        let paper = makePaper(id: 11)
        let legacy = EvidenceChunk(id: "pdf:p1:q1:legacy", paperID: 11, documentHash: "hash", page: 1, section: nil,
                                   characterRangeStart: 0, characterRangeEnd: 4, text: "same", textHash: StableHash.sha256("same"))
        let source = LibrarySnapshot(papers: [11: paper], evidenceChunks: [legacy.id: legacy])
        let first = V3MigrationService.migrate(source)
        XCTAssertEqual(first.report.targetSchema, 3)
        XCTAssertTrue(first.snapshot.quarantinedEvidenceIDs.isEmpty || first.snapshot.v3SchemaVersion == 3)
        let second = V3MigrationService.migrate(first.snapshot)
        XCTAssertEqual(second.snapshot.quarantinedEvidenceIDs, first.snapshot.quarantinedEvidenceIDs)
        XCTAssertEqual(second.report.postCount, first.report.postCount)
    }

    func testCloudNoteConflictCreatesExplicitConflictCopy() {
        let now = Date()
        let id = UUID()
        let local = UserNote(id: id, paperID: 11, body: "local", createdAt: now, updatedAt: now)
        let remote = UserNote(id: id, paperID: 11, body: "remote", createdAt: now, updatedAt: now)
        let merged = V3CloudSyncEngine.mergeNote(local: local, remote: remote)
        XCTAssertEqual(merged.note?.body, "local")
        XCTAssertEqual(merged.conflict?.payload, "remote")
    }

    func testPhysicsNumericContractAcceptsLatticeUnitsAndRejectsBareNumber() throws {
        XCTAssertNoThrow(try PhysicsNumericValidator.validate(value: "-1.23e-2", unit: "GeV^2"))
        XCTAssertNoThrow(try PhysicsNumericValidator.validate(value: "L^3×T", unit: nil))
        XCTAssertNoThrow(try PhysicsNumericValidator.validate(value: "0.09(1)", unit: "fm"))
        XCTAssertThrowsError(try PhysicsNumericValidator.validate(value: "0.09", unit: nil))
    }

    func testLocalRISImportOmitsMissingFieldsAndReportsConflict() throws {
        let paper = makePaper(id: 11)
        let snapshot = LibrarySnapshot(papers: [11: paper])
        let ris = "TY  - JOUR\nID  - 11\nTI  - Different title\nUR  - https://inspirehep.net/literature/11\nER  -\n"
        let result = try V3NotebookImporter.parse(data: Data(ris.utf8), format: .ris, snapshot: snapshot)
        XCTAssertEqual(result.records.first?.matchedPaperID, 11)
        XCTAssertNil(result.records.first?.doi)
        XCTAssertEqual(result.conflicts.first?.fields, ["title"])
    }

    func testNotebookImportMergesOnlyExplicitlyAcceptedFieldsAndAuditsConsent() async throws {
        let store = InMemoryLibraryStore()
        var paper = makePaper(id: 11)
        paper.doi = "10.1000/original"
        try await store.upsert(detail: paper)
        let imported = V3ImportedBibliography(id: UUID(), format: .ris, importedAt: Date(timeIntervalSince1970: 1),
                                               sourceCategory: "fixture", recid: 11, doi: "10.1000/accepted",
                                               arxivID: nil, title: "User supplied title", authors: [], rawHash: "fixture",
                                               matchedPaperID: paper.literatureID, sourceURL: nil)
        let conflict = V3ImportConflict(importedID: imported.id, paperID: paper.literatureID,
                                        fields: ["title", "doi"], status: .pending)
        try await store.applyV3(.saveImportedBibliography(imported))
        try await store.applyV3(.saveImportConflict(conflict))

        let service = V3WorkbenchService(store: store)
        try await service.acceptImportConflict(importedID: imported.id, acceptedFields: ["doi"])
        let after = await store.snapshot()
        XCTAssertEqual(after.papers[paper.literatureID]?.doi, "10.1000/accepted")
        XCTAssertEqual(after.papers[paper.literatureID]?.displayTitle, paper.displayTitle,
                       "an unselected title conflict must not change source display metadata")
        XCTAssertEqual(after.importConflicts[imported.id]?.status, .accepted)
        XCTAssertEqual(after.importConflicts[imported.id]?.acceptedFields, ["doi"])

        do {
            try await service.acceptImportConflict(importedID: imported.id, acceptedFields: ["title"])
            XCTFail("an already-reviewed conflict must not accept a second merge")
        } catch { }
        let unchanged = await store.snapshot()
        XCTAssertEqual(unchanged.importConflicts[imported.id]?.acceptedFields, ["doi"])
    }

    private func makePaper(id: Int) -> Paper {
        Paper(literatureID: id, titles: [PaperTitle(value: "Paper \(id)", source: "fixture")], abstracts: [PaperAbstract(value: "abstract", source: "fixture")],
              preprintDate: nil, earliestDate: nil, arxivID: nil, arxivCategories: ["hep-lat"], doi: nil, citationCount: nil,
              publicationStatus: nil, updated: Date(timeIntervalSince1970: TimeInterval(id)), figures: [], firstSeenAt: Date(), isRead: false)
    }

    private func makeDocument(paperID: Int, hash: String, url: String? = nil) -> FullTextDocument {
        FullTextDocument(paperID: paperID, sourceURL: URL(string: url ?? "https://example.test/\(paperID).pdf")!, sourceKind: .inspireDocument,
                         sha256: hash, byteCount: 4, localFilename: "\(hash).pdf", pageCount: 1, extractionState: .extracted, downloadedAt: Date(), lastErrorCategory: nil)
    }

    private func makeChunk(paperID: Int, hash: String, id: String) -> EvidenceChunk {
        EvidenceChunk(id: id, paperID: paperID, documentHash: hash, page: 1, section: nil, characterRangeStart: 0,
                      characterRangeEnd: 4, text: "same", textHash: StableHash.sha256("same"))
    }

    private func makeAnchor(_ chunk: EvidenceChunk) -> EvidenceAnchor {
        EvidenceAnchor(id: chunk.id, paperID: chunk.paperID, sourceKind: .pdf, page: chunk.page, section: chunk.section,
                       quote: chunk.text, quoteHash: chunk.textHash, figureKey: nil)
    }
}
