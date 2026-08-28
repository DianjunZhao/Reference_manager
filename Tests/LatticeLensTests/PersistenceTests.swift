import Foundation
import SwiftData
import XCTest
@testable import LatticeLens

final class PersistenceTests: XCTestCase {
    func testJSONStoreSurvivesRestartAndRotatesLastKnownGoodBackup() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("library.json")
        let first = JSONLibraryStore(fileURL: fileURL)
        try await first.upsert(authors: [fixtureAuthor(recid: 21, name: "Bali, Gunnar")])
        try await first.upsert(authors: [fixtureAuthor(recid: 22, name: "Aoki, Sinya")])

        let restored = JSONLibraryStore(fileURL: fileURL)
        let snapshot = await restored.snapshot()
        XCTAssertEqual(Set(snapshot.authors.keys), [21, 22])
        let backupData = try Data(contentsOf: fileURL.appendingPathExtension("backup"))
        let backupSnapshot = try JSONDecoder.latticeLens.decode(LibrarySnapshot.self, from: backupData)
        XCTAssertEqual(Set(backupSnapshot.authors.keys), [21], "backup 必须是本次写入之前的完整资料库")
    }

    func testJSONV1MigrationCreatesChecksumBackup() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("library.json")
        let legacy = """
        {"schemaVersion":1,"authors":{},"papers":{},"paperAuthorLinks":[],"insights":{},"checkpoints":{}}
        """
        try Data(legacy.utf8).write(to: fileURL, options: .atomic)

        let migrated = JSONLibraryStore(fileURL: fileURL)
        let migrationState = await migrated.initializationState()
        XCTAssertEqual(migrationState, .migrated)
        let current = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(current.contains("\"schemaVersion\":2"))
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".v1-") && $0.pathExtension == "backup" }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: backups[0], encoding: .utf8), legacy)
    }

    func testCorruptJSONBecomesReadOnlyAndIsNeverOverwritten() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("library.json")
        let original = Data("not valid JSON".utf8)
        try original.write(to: fileURL, options: .atomic)

        let store = JSONLibraryStore(fileURL: fileURL)
        guard case .readOnlyFailure = await store.initializationState() else {
            return XCTFail("corrupt input 应进入只读失败状态")
        }
        await XCTAssertThrowsErrorAsync(try await store.upsert(authors: [fixtureAuthor(recid: 23, name: "No overwrite, N.")]))
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testConcurrentJSONUpsertsRemainActorSerializedAndRetainEveryAuthor() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONLibraryStore(fileURL: directory.appendingPathComponent("library.json"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for recid in 1...32 {
                group.addTask {
                    try await store.upsert(authors: [Author(recid: recid, preferredName: "Author, \(recid)", nativeNames: [], bai: nil,
                                                               arxivCategories: ["hep-lat"], hIndex: nil, hIndexState: .unknown,
                                                               isTracked: false, lastSyncedAt: nil)])
                }
            }
            try await group.waitForAll()
        }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.authors.count, 32)
        XCTAssertEqual(Set(snapshot.authors.keys), Set(1...32))
    }

    @MainActor
    func testSwiftDataV1ToV2MigrationPreservesSnapshotAndWritesNormalizedProjection() async throws {
        let directory = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("swiftdata.store")
        let legacyPaper = Paper(literatureID: 991, titles: [PaperTitle(value: "legacy", source: "fixture")], abstracts: [],
                                preprintDate: nil, earliestDate: nil, arxivID: nil, arxivCategories: [], doi: nil,
                                citationCount: nil, publicationStatus: nil, updated: nil, figures: [],
                                firstSeenAt: Date(timeIntervalSince1970: 1), isRead: false)
        let legacySnapshot = LibrarySnapshot(papers: [legacyPaper.literatureID: legacyPaper], schemaVersion: 1)
        let v1Schema = Schema(versionedSchema: LatticeLensSchemaV1.self)
        let v1Config = ModelConfiguration(schema: v1Schema, url: storeURL)
        let v1Container = try ModelContainer(for: v1Schema, configurations: v1Config)
        v1Container.mainContext.insert(StoredLibraryDocument(schemaVersion: 1, snapshotData: try JSONEncoder.latticeLens.encode(legacySnapshot)))
        try v1Container.mainContext.save()

        let v2Schema = Schema(versionedSchema: LatticeLensSchemaV2.self)
        let v2Config = ModelConfiguration(schema: v2Schema, url: storeURL)
        let v2Container = try ModelContainer(for: v2Schema, migrationPlan: LatticeLensMigrationPlan.self, configurations: v2Config)
        let store = SwiftDataLibraryStore(modelContainer: v2Container)
        let restored = await store.snapshot()
        XCTAssertEqual(restored.papers[legacyPaper.literatureID]?.displayTitle, "legacy")

        let backups = try v2Container.mainContext.fetch(FetchDescriptor<StoredV1SnapshotBackupV2>())
        let backup = try XCTUnwrap(backups.first, "首次以 V2 打开 V1 document 必须保留完整 rollback snapshot")
        XCTAssertEqual(backup.sourceSchemaVersion, 1)
        let rollbackURL = directory.appendingPathComponent("rollback-v1.store")
        let rollbackConfig = ModelConfiguration(schema: v1Schema, url: rollbackURL)
        let rollbackContainer = try ModelContainer(for: v1Schema, configurations: rollbackConfig)
        try SwiftDataV1Rollback.restore(backup, into: rollbackContainer)
        let rollbackDocument = try XCTUnwrap(rollbackContainer.mainContext.fetch(FetchDescriptor<StoredLibraryDocument>()).first)
        XCTAssertEqual(rollbackDocument.schemaVersion, 1)
        let rollbackSnapshot = try JSONDecoder.latticeLens.decode(LibrarySnapshot.self, from: rollbackDocument.snapshotData)
        XCTAssertEqual(rollbackSnapshot.papers[legacyPaper.literatureID]?.displayTitle, "legacy")

        try await store.markRead(true, paperID: legacyPaper.literatureID, at: Date(timeIntervalSince1970: 2))
        let manager = ReferenceManagerService(store: store)
        try await manager.toggleFavorite(paperID: legacyPaper.literatureID, current: false)
        try await manager.saveNote(paperID: legacyPaper.literatureID, body: "persistent RI/MOM note")
        try await manager.createTag(named: "renormalization")
        try await manager.createCollection(named: "to read")
        let referenceSnapshot = await store.snapshot()
        let tag = try XCTUnwrap(referenceSnapshot.tags.values.first)
        let collection = try XCTUnwrap(referenceSnapshot.collections.values.first)
        try await manager.setTags([tag.id], paperID: legacyPaper.literatureID)
        try await manager.setCollection([legacyPaper.literatureID], collectionID: collection.id)

        let fullText = FullTextDocument(paperID: legacyPaper.literatureID, sourceURL: try XCTUnwrap(URL(string: "https://fixture.latticelens.test/paper.pdf")),
                                        sourceKind: .arxivPDF, sha256: "fixture-pdf-sha", byteCount: 512, localFilename: "fixture.pdf",
                                        pageCount: 1, extractionState: .extracted, downloadedAt: Date(timeIntervalSince1970: 3), lastErrorCategory: nil)
        let chunk = EvidenceChunk(id: "pdf:p1:q1:fixture", paperID: legacyPaper.literatureID, documentHash: fullText.sha256, page: 1,
                                  section: "Methods", characterRangeStart: 0, characterRangeEnd: 31,
                                  text: "The renormalization scale is 2 GeV.", textHash: "fixture-text-sha")
        let anchor = EvidenceAnchor(id: chunk.id, paperID: chunk.paperID, sourceKind: .pdf, page: 1, section: chunk.section,
                                    quote: chunk.text, quoteHash: chunk.textHash, figureKey: nil)
        try await store.saveFullText(document: fullText, chunks: [chunk], anchors: [anchor])

        let states = try v2Container.mainContext.fetch(FetchDescriptor<StoredReadingStateV2>())
        XCTAssertEqual(states.first(where: { $0.paperID == legacyPaper.literatureID })?.isRead, true)
        XCTAssertEqual(states.first(where: { $0.paperID == legacyPaper.literatureID })?.isFavorite, true)
        XCTAssertEqual(try v2Container.mainContext.fetch(FetchDescriptor<StoredUserNoteV2>()).count, 1)
        XCTAssertEqual(try v2Container.mainContext.fetch(FetchDescriptor<StoredTagV2>()).count, 1)
        XCTAssertEqual(try v2Container.mainContext.fetch(FetchDescriptor<StoredPaperTagLinkV2>()).count, 1)
        XCTAssertEqual(try v2Container.mainContext.fetch(FetchDescriptor<StoredCollectionV2>()).count, 1)
        XCTAssertEqual(try v2Container.mainContext.fetch(FetchDescriptor<StoredCollectionPaperLinkV2>()).count, 1)
        XCTAssertEqual(try v2Container.mainContext.fetch(FetchDescriptor<StoredFullTextDocumentV2>()).count, 1)
        XCTAssertEqual(try v2Container.mainContext.fetch(FetchDescriptor<StoredEvidenceChunkV2>()).count, 1)
        XCTAssertEqual(try v2Container.mainContext.fetch(FetchDescriptor<StoredEvidenceAnchorV2>()).count, 1)
    }

    private func makeTestDirectory() throws -> URL {
        try makeProjectLocalTestDirectory(prefix: "persistence")
    }

    private func fixtureAuthor(recid: Int, name: String) -> Author {
        Author(recid: recid, preferredName: name, nativeNames: [], bai: nil, arxivCategories: ["hep-lat"], hIndex: nil,
               hIndexState: .unknown, isTracked: false, lastSyncedAt: nil)
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
