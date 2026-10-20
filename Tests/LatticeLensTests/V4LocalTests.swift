import Foundation
import CoreData
import SwiftData
import XCTest
import Darwin
@testable import LatticeLens

private final class ModelContextSaveChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var updatedIdentifiers = Set<PersistentIdentifier>()

    func record(_ notification: Notification) {
        let rawIdentifiers = notification.userInfo?["updated"] ?? notification.userInfo?[
            ModelContext.NotificationKey.updatedIdentifiers.rawValue
        ]
        let identifiers = (rawIdentifiers as? Set<PersistentIdentifier>) ??
            Set(rawIdentifiers as? [PersistentIdentifier] ?? [])
        lock.lock()
        updatedIdentifiers.formUnion(identifiers)
        lock.unlock()
    }

    func snapshot() -> Set<PersistentIdentifier> {
        lock.lock()
        defer { lock.unlock() }
        return updatedIdentifiers
    }
}

final class V4LocalTests: XCTestCase {
#if SWIFT_PACKAGE
    private func copyLegacyV9StoreFixture(to destination: URL) throws {
        guard let resourceRoot = Bundle.module.resourceURL else {
            throw NSError(domain: "LatticeLensLegacyV9Fixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "SwiftPM test resources are unavailable"])
        }
        // SwiftPM's `.process("Fixtures")` places this binary at the bundle
        // resource root rather than preserving the source subdirectory.
        let source = resourceRoot.appending(path: "LatticeLens-v8.store")
        let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
            throw NSError(domain: "LatticeLensLegacyV9Fixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "the checked-in 1.0.11 V9 schema fixture is unavailable"])
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
#endif

    private struct V10DisposableMigrationDrillReceipt: Codable {
        let schemaVersion: String
        let runID: String
        let createdAtUTC: String
        let sourceOrigin: String
        let inputManifestSHA256: String
        let successfulMigration: V10DisposableMigrationLeg
        let postActivationRestore: V10DisposablePostActivationRestoreLeg
        let rollback: V10DisposableRollbackLeg
    }

    private struct V10DisposableMigrationLeg: Codable {
        let sourceSchemaVersion: Int
        let targetSchemaVersion: Int
        let journalPhase: String
        let sourceFamilyHashes: [String: String]
        let sourceRecordCounts: [String: Int]
        let targetRecordCounts: [String: Int]
        let legacyCategoryCheckpointCount: Int
        let sourceLegacyCheckpointInvalidationCount: Int?
        let targetLegacyCheckpointInvalidationCount: Int?
        let sourceLibraryHashFormatVersion: Int
        let targetLibraryHashFormatVersion: Int
        let sourceStableIDHash: String
        let targetStableIDHash: String
        let backupManifestHash: String
        let backupVerified: Bool
        let semanticReconciliationPassed: Bool
        let sourceFamilyUnchanged: Bool
        let descriptorSchemaVersion: Int
        let descriptorSemanticHash: String
    }

    private struct V10DisposablePostActivationRestoreLeg: Codable {
        let sourceSchemaVersion: Int
        let restoredSchemaVersion: Int
        let productionSchemaVersion: Int
        let productionMigrationPhase: String
        let sourceRecordCounts: [String: Int]
        let restoredRecordCounts: [String: Int]
        let productionRecordCounts: [String: Int]
        let sourceLibraryHashFormatVersion: Int
        let restoredLibraryHashFormatVersion: Int
        let productionLibraryHashFormatVersion: Int
        let sourceStableIDHash: String
        let restoredStableIDHash: String
        let productionStableIDHash: String
        let productionDescriptorSemanticHash: String
        let backupManifestHash: String
        let restoredFamilyHashes: [String: String]
        let restoreTargetWasAbsent: Bool
        let backupVerified: Bool
        let restoredFamilyMatchesManifest: Bool
        let semanticReconciliationPassed: Bool
        let productionStoreOpenPassed: Bool
    }

    private struct V10DisposableRollbackLeg: Codable {
        let sourceSchemaVersion: Int
        let targetSchemaVersion: Int
        let journalPhaseBeforeRecovery: String
        let recoveredJournalPhase: String
        let sourceFamilyHashes: [String: String]
        let sourceLibraryHashFormatVersion: Int
        let recoveredLibraryHashFormatVersion: Int
        let sourceStableIDHash: String
        let recoveredSourceStableIDHash: String
        let backupVerified: Bool
        let sourceFamilyUnchanged: Bool
        let sourceSemanticUnchanged: Bool
        let activeDescriptorAbsent: Bool
        let stagingRemoved: Bool
    }

    private func makePaper(_ id: Int) -> Paper {
        Paper(literatureID: id, titles: [PaperTitle(value: "Paper \(id)", source: "fixture")],
              abstracts: [PaperAbstract(value: "abstract", source: "fixture")], preprintDate: nil, earliestDate: nil,
              arxivID: nil, arxivCategories: ["hep-lat"], doi: nil, citationCount: nil, publicationStatus: nil,
              updated: Date(timeIntervalSince1970: TimeInterval(id)), figures: [], firstSeenAt: Date(), isRead: false)
    }

    private func makeValidatedSegmentCheckpoint(equationID: String, sourceTeX: String,
                                                anchorID: String, documentHash: String,
                                                stepText: String,
                                                referencedEquationIDs: [String] = []) throws -> FormulaDerivationSegmentCheckpoint {
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000)
        let step = FormulaDerivationStep(stepID: "\(equationID):step:1", ordinal: 1,
            textZH: stepText, beforeTeX: sourceTeX, afterTeX: sourceTeX,
            ruleOrAssumption: "synthetic identity fixture", referencedEquationIDs: referencedEquationIDs,
            evidenceAnchorIDs: [anchorID],
            sourceDocumentHashes: [documentHash], epistemicStatus: .inference)
        var checkpoint = FormulaDerivationSegmentCheckpoint(equationID: equationID, sourceTeX: sourceTeX)
        try checkpoint.appendSegment(index: 0, steps: [step], isFinal: true,
            continuationSummary: nil, conclusionZH: "synthetic conclusion for \(equationID)",
            requestID: "fixture-request-\(equationID)", requestPayloadHash: String(repeating: "a", count: 64),
            responseHash: String(repeating: "b", count: 64), receivedBytes: 64, receivedCharacters: 32,
            firstContentAt: timestamp, lastContentAt: timestamp.addingTimeInterval(1))
        return checkpoint
    }

    private func semanticFingerprintFixture(paperID: Int, reverseSetInsertion: Bool,
                                            addMembership: Bool = false) -> LibrarySnapshot {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let paper = Paper(literatureID: paperID,
            titles: [PaperTitle(value: "Canonical fixture \(paperID)", source: "fixture")],
            abstracts: [PaperAbstract(value: "stable abstract", source: "fixture")],
            preprintDate: nil, earliestDate: nil, arxivID: "2401.00001",
            arxivCategories: ["hep-lat", "hep-ph"], doi: nil, citationCount: 3,
            publicationStatus: "published", updated: timestamp, figures: [],
            firstSeenAt: timestamp, isRead: false)
        let author = Author(recid: 91001, preferredName: "Canonical, Author", nativeNames: ["作者"],
            bai: nil, arxivCategories: Set(reverseSetInsertion ? ["hep-ph", "hep-lat"] : ["hep-lat", "hep-ph"]),
            hIndex: nil, hIndexState: .unknown, isTracked: false, lastSyncedAt: timestamp)
        let coauthor = Author(recid: 91002, preferredName: "Second, Author", nativeNames: [], bai: nil,
            arxivCategories: ["hep-ph"], hIndex: nil, hIndexState: .unknown,
            isTracked: false, lastSyncedAt: timestamp)
        let tagA = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let tagB = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let collectionA = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let collectionB = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        let notebookID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        let workspaceID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!

        var activeMembership = [91001, 91002]
        var stagingMembership = [91003, 91004]
        var checkpointActiveMembership = Array(92001...93024)
        var checkpointStagingMembership = Array(94001...95024)
        if reverseSetInsertion {
            activeMembership.reverse()
            stagingMembership.reverse()
            checkpointActiveMembership.reverse()
            checkpointStagingMembership.reverse()
        }
        if addMembership { activeMembership.append(91005) }
        var authorLinks = [PaperAuthorLink(paperID: paperID, authorRecid: 91001, position: 0),
                           PaperAuthorLink(paperID: paperID, authorRecid: 91002, position: 1)]
        var paperTags = [PaperTagLink(paperID: paperID, tagID: tagA), PaperTagLink(paperID: paperID, tagID: tagB)]
        var collectionLinks = [CollectionPaperLink(collectionID: collectionA, paperID: paperID, addedAt: timestamp),
                               CollectionPaperLink(collectionID: collectionB, paperID: paperID, addedAt: timestamp)]
        var notebookLinks = [NotebookAnchorLink(entryID: notebookID, anchorID: "anchor-a", sortIndex: 0),
                             NotebookAnchorLink(entryID: notebookID, anchorID: "anchor-b", sortIndex: 1)]
        var workspaceLinks = [WorkspacePaperLink(workspaceID: workspaceID, paperID: paperID,
                                addedAt: timestamp, sortIndex: 0),
                              WorkspacePaperLink(workspaceID: workspaceID, paperID: paperID + 1,
                                addedAt: timestamp, sortIndex: 1)]
        var quarantinedIDs = ["quarantine-a", "quarantine-b"]
        if reverseSetInsertion {
            authorLinks.reverse()
            paperTags.reverse()
            collectionLinks.reverse()
            notebookLinks.reverse()
            workspaceLinks.reverse()
            quarantinedIDs.reverse()
        }

        let generation = AuthorIndexGeneration(id: "generation-\(paperID)", query: "canonical-query",
            startedAt: timestamp, completedAt: timestamp, state: .completed,
            activeMembership: Set(activeMembership), stagingMembership: Set(stagingMembership),
            pageCount: 2, hQueueCompleted: 2, hQueuePending: 0, hQueueFailed: 0,
            hQueueCancelled: 0, lastCheckpointAt: timestamp)
        let checkpoint = SyncCheckpoint(jobID: "author-candidates:hep-lat-or-hep-th",
            jobKind: "author-candidates", query: "arxiv_categories:hep-lat OR arxiv_categories:hep-th",
            generationID: "checkpoint-\(paperID)",
            startedAt: timestamp, updatedAt: timestamp,
            activeMembership: Set(checkpointActiveMembership),
            stagingMembership: Set(checkpointStagingMembership))
        let notebook = NotebookEntry(id: notebookID, paperID: paperID, title: "Notebook",
            body: "stable body", createdAt: timestamp, updatedAt: timestamp)
        let workspace = PaperWorkspace(id: workspaceID, name: "Workspace", createdAt: timestamp,
            updatedAt: timestamp, sortOrder: [paperID, paperID + 1], note: "stable note", frozenExportHash: nil)
        return LibrarySnapshot(authors: [author.recid: author, coauthor.recid: coauthor],
            papers: [paperID: paper], paperAuthorLinks: Set(authorLinks),
            checkpoints: [checkpoint.id: checkpoint],
            tags: [tagA: LibraryTag(id: tagA, name: "A", colorName: nil, createdAt: timestamp),
                   tagB: LibraryTag(id: tagB, name: "B", colorName: nil, createdAt: timestamp)],
            paperTags: Set(paperTags),
            collections: [collectionA: PaperCollection(id: collectionA, name: "A", createdAt: timestamp),
                          collectionB: PaperCollection(id: collectionB, name: "B", createdAt: timestamp)],
            collectionPapers: Set(collectionLinks),
            authorIndexGenerations: [generation.id: generation],
            notebookEntries: [notebook.id: notebook], notebookAnchorLinks: Set(notebookLinks),
            workspaces: [workspace.id: workspace], workspacePaperLinks: Set(workspaceLinks),
            quarantinedEvidenceIDs: Set(quarantinedIDs), schemaVersion: 10)
    }

    private func legacySemanticSummary(counts: [String: Int], stableIDHash: String,
                                       serializedLibraryHash: String = "legacy-library-hash",
                                       serializedLibraryHashFormatVersion: Int = 1) -> V10StoreSemanticSummary {
        V10StoreSemanticSummary(
            domainSummary: V8StoreSemanticSummary(counts: counts, stableIDHash: stableIDHash),
            serializedLibraryHash: serializedLibraryHash,
            serializedLibraryHashFormatVersion: serializedLibraryHashFormatVersion,
            typedRowCounts: [:],
            typedIdentityHash: StableHash.sha256(""),
            typedContentHash: StableHash.sha256(""),
            categoryProfileCategories: CategoryProfile().rawValues,
            hasLegacyCategoryCheckpoint: false,
            legacyCheckpointInvalidationCount: nil
        )
    }

    private func stagedSemanticSummary(preserving source: V10StoreSemanticSummary) -> V10StoreSemanticSummary {
        V10StoreSemanticSummary(
            domainSummary: source.domainSummary,
            serializedLibraryHash: source.serializedLibraryHash,
            serializedLibraryHashFormatVersion: source.serializedLibraryHashFormatVersion,
            typedRowCounts: ["categoryProfiles": 1],
            typedIdentityHash: StableHash.sha256("category-profile:active"),
            typedContentHash: StableHash.sha256("category-profile:hep-lat,hep-ph"),
            categoryProfileCategories: CategoryProfile().rawValues,
            hasLegacyCategoryCheckpoint: false,
            legacyCheckpointInvalidationCount: nil
        )
    }

    private func readyEvidencePublicationFixture(
        paperID: Int,
        documentHash: String,
        inventoryHash: String,
        items: [FormulaInventoryItem],
        formulaClaims: [EvidenceClaim]? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_750_000_100)
    ) -> ReadyEvidenceInsightPublication {
        let cacheKey = StableHash.sha256("ready-publication|\(paperID)|\(inventoryHash)")
        let sourcePayloadHash = StableHash.sha256("source-payload|\(paperID)|\(documentHash)|\(inventoryHash)")
        let generatedClaims = items.map { item in
            let anchorID = item.evidenceID ?? "anchor-\(item.equationID)"
            let step = FormulaDerivationStep(
                stepID: "\(item.equationID):ready-step", ordinal: 1,
                textZH: "fixture 推導", beforeTeX: item.sourceTeX, afterTeX: item.sourceTeX,
                ruleOrAssumption: "identity fixture", evidenceAnchorIDs: [anchorID],
                sourceDocumentHashes: [documentHash], epistemicStatus: .inference
            )
            return EvidenceClaim(textZH: "fixture 公式", epistemicStatus: .direct,
                                 evidenceIDs: [anchorID], formulaTeX: item.sourceTeX,
                                 equationID: item.equationID, formulaDerivationSteps: [step])
        }
        let claims = formulaClaims ?? generatedClaims
        let researchQuestion = EvidenceClaim(textZH: "fixture question", epistemicStatus: .direct,
                                             evidenceIDs: [items.first?.evidenceID ?? "metadata-\(paperID)"])
        let insight = PaperInsightV2(
            schemaVersion: PaperInsightV2Validator.schemaVersion,
            sourceScope: PaperInsightV2Validator.sourceScope,
            titleZH: "fixture title", abstractZH: "fixture abstract",
            physics: InsightPhysicsV2(researchQuestion: researchQuestion, methodAndDataFlow: [],
                mainResults: [], reasonableInferences: [], missingInformation: [], caveats: [],
                importantFormulaDerivations: claims),
            importantFigures: [], terminology: []
        )
        let promptVersion = "\(EvidenceInsightPrompt.version)|\(FormulaDerivationPrompt.version)|\(inventoryHash)"
        let artifact = EvidenceInsightArtifact(
            cacheKey: cacheKey, paperID: paperID, documentHash: documentHash,
            chunkIDs: ["chunk-\(paperID)"], insight: insight, createdAt: createdAt,
            selectedChunkIDs: ["chunk-\(paperID)"], promptVersion: promptVersion,
            schemaVersion: PaperInsightV2Validator.schemaVersion, payloadHash: sourcePayloadHash,
            numberedEquationIDs: items.map(\.equationID), numberedEquationCoverageComplete: true
        )
        let context = EvidenceInsightPublicationContext(
            cacheKey: cacheKey, paperID: paperID, documentHash: documentHash,
            inventoryHash: inventoryHash, sourcePayloadHash: sourcePayloadHash,
            provider: "openAI", providerProfileFingerprint: StableHash.sha256("fixture-profile"),
            modelID: "fixture-model", promptVersion: promptVersion,
            schemaVersion: PaperInsightV2Validator.schemaVersion,
            sourceScope: PaperInsightV2Validator.sourceScope
        )
        return ReadyEvidenceInsightPublication(context: context, artifact: artifact)
    }

    func testCategoryProfileDefaultsLegacySelectionCanonicalIdentityAndCheckpointInvalidation() {
        let fresh = CategoryProfile()
        XCTAssertEqual(Set(fresh.rawValues), Set(["hep-lat", "hep-ph"]))
        XCTAssertFalse(fresh.contains(.hepTh))

        let legacy = CategoryProfile.migratingLegacy(categories: ["hep-lat", "hep-th"])
        XCTAssertEqual(Set(legacy.rawValues), Set(["hep-lat", "hep-th"]))
        XCTAssertFalse(legacy.contains(.hepPh), "migration must not silently change the old query union")

        let firstSet: Set<SupportedArxivCategory> = [.hepLat, .hepPh, .hepTh]
        let sameSet: Set<SupportedArxivCategory> = [.hepTh, .hepLat, .hepPh]
        XCTAssertEqual(fresh.queryIdentity,
                       "author-candidates:hep-lat-hep-ph-profile-v3-query-v3-pagination-v7",
                       "profile, query-contract and pagination revisions must be separate identity components")
        XCTAssertEqual(fresh.profileRevision, fresh.revision)
        XCTAssertEqual(fresh.queryContractRevision, ArxivCategoryQueryBuilder.revision)
        XCTAssertEqual(fresh.paginationRevision, AuthorCandidatePaginationContract.revision)
        XCTAssertEqual(fresh.id, fresh.queryIdentity)
        XCTAssertNotEqual(fresh.queryIdentity,
                          CategoryProfile(categories: fresh.categories, revision: fresh.revision + 1).queryIdentity)
        XCTAssertFalse(ArxivCategoryQueryBuilder.checkpointMatches(fresh.query, categories: fresh.categories),
                       "raw queries do not carry the frozen contract revisions")
        XCTAssertTrue(ArxivCategoryQueryBuilder.checkpointMatches(fresh.checkpointIdentity, categories: fresh.categories))
        let editedProfile = CategoryProfile(categories: fresh.categories, revision: fresh.revision + 1)
        XCTAssertFalse(ArxivCategoryQueryBuilder.checkpointMatches(fresh.checkpointIdentity, profile: editedProfile))
        XCTAssertEqual(CategoryProfile(categories: firstSet).query, CategoryProfile(categories: sameSet).query)
        XCTAssertEqual(ArxivCategoryQueryBuilder.checkpointJobID(categories: firstSet),
                       ArxivCategoryQueryBuilder.checkpointJobID(categories: sameSet))

        let old = CategoryCheckpointMigration.evaluate(
            query: "arxiv_categories:hep-lat OR arxiv_categories:hep-th", categories: fresh.categories)
        let current = CategoryCheckpointMigration.evaluate(query: fresh.checkpointIdentity, categories: fresh.categories)
        XCTAssertEqual(old.status, .invalidatedByQueryRevision)
        XCTAssertEqual(old.replacementQuery, fresh.checkpointIdentity)
        XCTAssertEqual(current.status, .compatible)
    }

    func testCategoryFacetsFilterWithoutMutatingEnabledProfile() {
        let profile = CategoryProfile(categories: [.hepLat, .hepPh, .hepTh])
        let enabledBefore = profile.categories

        XCTAssertTrue(CategoryFacet.hepPh.matches(categories: ["hep-lat", "hep-ph"], enabled: profile.categories))
        XCTAssertFalse(CategoryFacet.hepPh.matches(categories: ["hep-lat"], enabled: profile.categories))
        XCTAssertTrue(CategoryFacet.multiCategory.matches(categories: ["hep-lat", "hep-ph"], enabled: profile.categories))
        XCTAssertFalse(CategoryFacet.multiCategory.matches(categories: ["hep-th"], enabled: profile.categories))
        XCTAssertEqual(profile.categories, enabledBefore, "view facets must not mutate durable enabled categories")
    }

    @MainActor
    func testV10MigrationCoordinatorCopiesSQLiteFamilyVerifiesAndAtomicallyActivates() throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-migration-coordinator")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        let sourceURL = root.appendingPathComponent("Library-v9.store")
        let descriptorURL = root.appendingPathComponent("active-library.json")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let sourceFamily: [(String, Data)] = [
            ("", Data("sqlite-source-v9".utf8)),
            ("-wal", Data("wal-checkpoint".utf8)),
            ("-shm", Data("shared-memory-state".utf8))
        ]
        for (suffix, data) in sourceFamily {
            try data.write(to: URL(fileURLWithPath: sourceURL.path + suffix), options: .atomic)
        }
        let sourceSummary = legacySemanticSummary(counts: ["authors": 1, "papers": 1], stableIDHash: "stable-v9-ids")
        let targetSummary = stagedSemanticSummary(preserving: sourceSummary)

        let outcome = try V10StoreMigrationCoordinator.migrate(
            sourceURL: sourceURL,
            descriptorURL: descriptorURL,
            backupRoot: backupRoot,
            fileManager: fileManager,
            readBackupSchemaVersion: { _ in 9 },
            inspectBackupCopy: { _, _ in sourceSummary }
        ) { stagingURL, reportProgress in
            let stagedPrimary = try Data(contentsOf: stagingURL)
            XCTAssertEqual(stagedPrimary, sourceFamily[0].1)
            for (suffix, expected) in sourceFamily.dropFirst() {
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: stagingURL.path + suffix)), expected)
            }
            try Data("sqlite-target-v10".utf8).write(to: stagingURL, options: .atomic)
            try reportProgress(.categoryMigrated)
            try reportProgress(.searchIndexReady)
            return targetSummary
        }

        XCTAssertEqual(outcome.journal.phase, .activated)
        XCTAssertEqual(outcome.journal.sourceSchemaVersion, 9)
        XCTAssertEqual(outcome.journal.targetSchemaVersion, 11)
        XCTAssertEqual(outcome.journal.sourceSummary, sourceSummary)
        XCTAssertEqual(outcome.journal.targetSummary, targetSummary)
        XCTAssertTrue(sourceSummary.preservesDomainAndTypedRows(in: targetSummary, sourceSchemaVersion: 9))
        XCTAssertTrue(fileManager.fileExists(atPath: descriptorURL.path))
        let descriptor = try JSONDecoder.latticeLens.decode(V10ActiveStoreDescriptor.self, from: Data(contentsOf: descriptorURL))
        XCTAssertEqual(descriptor.runID, outcome.journal.id)
        XCTAssertEqual(descriptor.schemaVersion, 11)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceFamily[0].1,
                       "the active V9 source must remain byte-identical")
        for (suffix, expected) in sourceFamily.dropFirst() {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sourceURL.path + suffix)), expected,
                           "SQLite sidecars must remain unchanged as one source family")
        }

        let manifestURL = backupRoot.appendingPathComponent(outcome.backupManifest.id.uuidString, isDirectory: true)
            .appendingPathComponent("migration-manifest.json")
        let manifest = try JSONDecoder.latticeLens.decode(V10MigrationBackupManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(manifest.sourceSchemaVersion, 9)
        XCTAssertEqual(manifest.recordCounts, sourceSummary.recordCounts)
        XCTAssertEqual(manifest.semanticSummary, sourceSummary)
        XCTAssertTrue(try V4StoreBackupCoordinator.verify(manifest.storeFamilyManifest, in: backupRoot))
        XCTAssertEqual(outcome.journal.backupManifestHash, manifest.manifestHash)
        XCTAssertFalse(String(decoding: try JSONEncoder.latticeLens.encode(manifest), as: UTF8.self).contains(root.path),
                       "migration receipts must not serialize a private absolute library path")

        let recovered = try V10StoreMigrationCoordinator.recover(
            journalURL: outcome.journalURL,
            parent: root,
            descriptorURL: descriptorURL,
            backupRoot: backupRoot,
            fileManager: fileManager,
            verifyActive: { _ in targetSummary }
        )
        XCTAssertEqual(recovered.phase, .activated)
    }

    @MainActor
    func testV10MigrationCrashRecoveryNeverPublishesUnverifiedStaging() throws {
        let sourceSchemaVersions = [8, 9, 10]
        let crashPoints: [V10StoreMigrationCrashPoint] = [
            .afterBackup, .duringCopy, .categoryMigration, .searchIndexReady,
            .afterSemanticVerification, .beforeActivation, .afterActivation
        ]
        for sourceSchemaVersion in sourceSchemaVersions {
            let summary = legacySemanticSummary(
                counts: ["papers": 2], stableIDHash: "stable-crash-ids-v\(sourceSchemaVersion)")
            let targetSummary = stagedSemanticSummary(preserving: summary)
            for (index, crashPoint) in crashPoints.enumerated() {
                let root = try makeProjectLocalTestDirectory(
                    prefix: "v\(sourceSchemaVersion)-to-v11-migration-crash-\(index)")
                defer { try? FileManager.default.removeItem(at: root) }
                let fileManager = FileManager.default
                let sourceURL = root.appendingPathComponent("Library-v\(sourceSchemaVersion).store")
                let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(for: sourceURL)
                let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
                let sourceFamily: [(String, Data)] = [
                    ("", Data("untouched-v\(sourceSchemaVersion)-source".utf8)),
                    ("-wal", Data("untouched-v\(sourceSchemaVersion)-wal".utf8)),
                    ("-shm", Data("untouched-v\(sourceSchemaVersion)-shm".utf8))
                ]
                for (suffix, bytes) in sourceFamily {
                    try bytes.write(to: URL(fileURLWithPath: sourceURL.path + suffix), options: .atomic)
                }

                XCTAssertThrowsError(try V10StoreMigrationCoordinator.migrate(
                    sourceURL: sourceURL,
                    descriptorURL: descriptorURL,
                    backupRoot: backupRoot,
                    crashAt: crashPoint,
                    fileManager: fileManager,
                    readBackupSchemaVersion: { _ in sourceSchemaVersion },
                    inspectBackupCopy: { _, _ in summary }
                ) { stagingURL, reportProgress in
                    try Data("verified-v11-staging".utf8).write(to: stagingURL, options: .atomic)
                    try reportProgress(.categoryMigrated)
                    try reportProgress(.searchIndexReady)
                    return targetSummary
                })

                let journalURL = try XCTUnwrap(fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasPrefix(".latticelens-v11-migration-") })
                let journal = try JSONDecoder.latticeLens.decode(
                    V10StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
                XCTAssertEqual(journal.sourceSchemaVersion, sourceSchemaVersion)
                for (suffix, expectedBytes) in sourceFamily {
                    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sourceURL.path + suffix)), expectedBytes,
                                   "migration must preserve the complete V\(sourceSchemaVersion) SQLite family")
                }

                let backupManifestURL = backupRoot
                    .appendingPathComponent(journal.backupManifestID.uuidString, isDirectory: true)
                    .appendingPathComponent("manifest.json")
                let backupManifest = try JSONDecoder.latticeLens.decode(
                    V4StoreBackupManifest.self, from: Data(contentsOf: backupManifestURL))
                XCTAssertEqual(backupManifest.schemaVersion, sourceSchemaVersion)
                XCTAssertEqual(Set(backupManifest.files.map(\.relativePath)),
                               Set(sourceFamily.map { sourceURL.lastPathComponent + $0.0 }))
                XCTAssertTrue(try V4StoreBackupCoordinator.verify(backupManifest, in: backupRoot),
                              "the backup manifest must cover every source-family member")

                XCTAssertEqual(fileManager.fileExists(atPath: descriptorURL.path), crashPoint == .afterActivation,
                               "only a fully verified target may be selected by the active descriptor")
                let recovered = try V10StoreMigrationCoordinator.recover(
                    journalURL: journalURL,
                    parent: root,
                    descriptorURL: descriptorURL,
                    backupRoot: backupRoot,
                    fileManager: fileManager,
                    verifyActive: { _ in targetSummary }
                )
                if crashPoint == .afterActivation {
                    XCTAssertEqual(recovered.phase, .activated)
                    XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent(recovered.stagingStoreName).path))
                    let descriptor = try JSONDecoder.latticeLens.decode(
                        V10ActiveStoreDescriptor.self, from: Data(contentsOf: descriptorURL))
                    XCTAssertEqual(descriptor.schemaVersion, 11)
                } else {
                    XCTAssertEqual(recovered.phase, .rolledBack)
                    XCTAssertFalse(fileManager.fileExists(atPath: descriptorURL.path))
                    XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent(journal.stagingStoreName).path))
                }
                for (suffix, expectedBytes) in sourceFamily {
                    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sourceURL.path + suffix)), expectedBytes,
                                   "recovery must leave the original V\(sourceSchemaVersion) family byte-stable")
                }
            }
        }
    }

    @MainActor
    func testV10RecoveryUpgradesLegacySetOrderFingerprintAfterActivationCrash() throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-legacy-fingerprint-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Library-v10.store")
        let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(
            for: sourceURL, targetSchemaVersion: 12)
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try Data("synthetic-v10-source".utf8).write(to: sourceURL, options: .atomic)
        let sourceSummary = legacySemanticSummary(counts: ["papers": 1], stableIDHash: "legacy-source",
                                                 serializedLibraryHashFormatVersion: 2)
        let oldTargetSummary = stagedSemanticSummary(preserving: sourceSummary)
        let currentTargetSummary = V10StoreSemanticSummary(
            domainSummary: oldTargetSummary.domainSummary,
            serializedLibraryHash: "canonical-library-fingerprint-v3",
            serializedLibraryHashFormatVersion: 3,
            typedRowCounts: oldTargetSummary.typedRowCounts,
            typedIdentityHash: oldTargetSummary.typedIdentityHash,
            typedContentHash: oldTargetSummary.typedContentHash,
            typedFamilyIdentityHashes: oldTargetSummary.typedFamilyIdentityHashes,
            typedFamilyContentHashes: oldTargetSummary.typedFamilyContentHashes,
            categoryProfileCategories: oldTargetSummary.categoryProfileCategories,
            hasLegacyCategoryCheckpoint: oldTargetSummary.hasLegacyCategoryCheckpoint,
            legacyCategoryCheckpointCount: oldTargetSummary.legacyCategoryCheckpointCount,
            legacyCheckpointInvalidationCount: oldTargetSummary.legacyCheckpointInvalidationCount)

        XCTAssertThrowsError(try V10StoreMigrationCoordinator.migrate(
            sourceURL: sourceURL, descriptorURL: descriptorURL, backupRoot: backupRoot,
            crashAt: .afterActivation, readBackupSchemaVersion: { _ in 10 },
            inspectBackupCopy: { _, _ in sourceSummary }
        ) { stagingURL, _ in
            try Data("synthetic-v11-target".utf8).write(to: stagingURL, options: .atomic)
            return oldTargetSummary
        })

        let journalURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".latticelens-v11-migration-") })
        let recovered = try V10StoreMigrationCoordinator.recover(
            journalURL: journalURL, parent: root, descriptorURL: descriptorURL, backupRoot: backupRoot,
            verifyActive: { _ in currentTargetSummary })
        XCTAssertEqual(recovered.phase, .activated)
        XCTAssertEqual(recovered.targetSummary, currentTargetSummary)
        let descriptor = try JSONDecoder.latticeLens.decode(
            V10ActiveStoreDescriptor.self, from: Data(contentsOf: descriptorURL))
        XCTAssertEqual(descriptor.semanticHash, currentTargetSummary.stableIDHash)
        XCTAssertEqual(try V10StoreMigrationCoordinator.validateActiveDescriptorEvidence(
            descriptorURL: descriptorURL, backupRoot: backupRoot).targetSummary, currentTargetSummary)
    }

    @MainActor
    func testV10MigrationRecoveryRejectsTamperedBackupWithoutChangingActiveDescriptor() throws {
        let sourceSchemaVersions = [8, 9, 10]
        let familySuffixes = ["", "-wal", "-shm"]
        for sourceSchemaVersion in sourceSchemaVersions {
            for corruptedSuffix in familySuffixes {
                let root = try makeProjectLocalTestDirectory(
                    prefix: "v\(sourceSchemaVersion)-migration-corrupt-backup\(corruptedSuffix.isEmpty ? "-main" : corruptedSuffix)")
                defer { try? FileManager.default.removeItem(at: root) }
                let fileManager = FileManager.default
                let sourceURL = root.appendingPathComponent("Library-v\(sourceSchemaVersion).store")
                let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(for: sourceURL)
                let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
                let sourceFamily = familySuffixes.map { suffix in
                    (suffix, Data("v\(sourceSchemaVersion)-source\(suffix)".utf8))
                }
                for (suffix, bytes) in sourceFamily {
                    try bytes.write(to: URL(fileURLWithPath: sourceURL.path + suffix), options: .atomic)
                }
                let summary = legacySemanticSummary(
                    counts: ["papers": 1], stableIDHash: "v\(sourceSchemaVersion)-stable-id")
                XCTAssertThrowsError(try V10StoreMigrationCoordinator.migrate(
                    sourceURL: sourceURL,
                    descriptorURL: descriptorURL,
                    backupRoot: backupRoot,
                    crashAt: .afterBackup,
                    fileManager: fileManager,
                    readBackupSchemaVersion: { _ in sourceSchemaVersion },
                    inspectBackupCopy: { _, _ in summary }
                ) { _, _ in stagedSemanticSummary(preserving: summary) })

                let journalURL = try XCTUnwrap(fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasPrefix(".latticelens-v11-migration-") })
                let journal = try JSONDecoder.latticeLens.decode(
                    V10StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
                XCTAssertEqual(journal.sourceSchemaVersion, sourceSchemaVersion)
                let backupManifestURL = backupRoot
                    .appendingPathComponent(journal.backupManifestID.uuidString, isDirectory: true)
                    .appendingPathComponent("manifest.json")
                let backupManifest = try JSONDecoder.latticeLens.decode(
                    V4StoreBackupManifest.self, from: Data(contentsOf: backupManifestURL))
                let familyFileName = sourceURL.lastPathComponent + corruptedSuffix
                let familyFile = try XCTUnwrap(backupManifest.files.first { $0.relativePath == familyFileName })
                let backupFileURL = backupRoot.appendingPathComponent(backupManifest.id.uuidString, isDirectory: true)
                    .appendingPathComponent(familyFile.relativePath)
                try Data("tampered-v\(sourceSchemaVersion)\(corruptedSuffix)".utf8)
                    .write(to: backupFileURL, options: .atomic)

                XCTAssertThrowsError(try V10StoreMigrationCoordinator.recover(
                    journalURL: journalURL,
                    parent: root,
                    descriptorURL: descriptorURL,
                    backupRoot: backupRoot,
                    fileManager: fileManager,
                    verifyActive: { _ in stagedSemanticSummary(preserving: summary) }
                ), "recovery must reject a modified V\(sourceSchemaVersion) SQLite family member")
                XCTAssertFalse(fileManager.fileExists(atPath: descriptorURL.path))
                for (suffix, expectedBytes) in sourceFamily {
                    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sourceURL.path + suffix)), expectedBytes,
                                   "tampering with a backup must not alter the V\(sourceSchemaVersion) source family")
                }
            }
        }
    }

    @MainActor
    func testV10MigrationRejectsSemanticMismatchAndCancellationBeforeActivation() throws {
        let sourceSchemaVersions = [8, 9, 10]
        let failures = ["semantic-mismatch", "cancelled", "storage-exhaustion"]
        for sourceSchemaVersion in sourceSchemaVersions {
            for failure in failures {
                let root = try makeProjectLocalTestDirectory(
                    prefix: "v\(sourceSchemaVersion)-migration-\(failure)")
                defer { try? FileManager.default.removeItem(at: root) }
                let sourceURL = root.appendingPathComponent("Library-v\(sourceSchemaVersion).store")
                let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(for: sourceURL)
                let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
                let sourceFamily: [(String, Data)] = [
                    ("", Data("untouched-v\(sourceSchemaVersion)-\(failure)".utf8)),
                    ("-wal", Data("untouched-v\(sourceSchemaVersion)-wal-\(failure)".utf8)),
                    ("-shm", Data("untouched-v\(sourceSchemaVersion)-shm-\(failure)".utf8))
                ]
                for (suffix, bytes) in sourceFamily {
                    try bytes.write(to: URL(fileURLWithPath: sourceURL.path + suffix), options: .atomic)
                }
                let sourceSummary = legacySemanticSummary(
                    counts: ["papers": 1], stableIDHash: "v\(sourceSchemaVersion)-\(failure)-source")

                XCTAssertThrowsError(try V10StoreMigrationCoordinator.migrate(
                    sourceURL: sourceURL,
                    descriptorURL: descriptorURL,
                    backupRoot: backupRoot,
                    fileManager: .default,
                    readBackupSchemaVersion: { _ in sourceSchemaVersion },
                    inspectBackupCopy: { _, _ in sourceSummary }
                ) { stagingURL, _ in
                    if failure == "cancelled" { throw CancellationError() }
                    if failure == "storage-exhaustion" { throw CocoaError(.fileWriteOutOfSpace) }
                    try Data("staged-but-wrong".utf8).write(to: stagingURL, options: .atomic)
                    return V10StoreSemanticSummary(
                        domainSummary: sourceSummary.domainSummary,
                        serializedLibraryHash: "different-library-hash",
                        typedRowCounts: ["categoryProfiles": 1],
                        typedIdentityHash: StableHash.sha256("wrong-profile"),
                        typedContentHash: StableHash.sha256("wrong-profile"),
                        categoryProfileCategories: CategoryProfile().rawValues,
                        hasLegacyCategoryCheckpoint: false,
                        legacyCheckpointInvalidationCount: nil
                    )
                })
                XCTAssertFalse(FileManager.default.fileExists(atPath: descriptorURL.path))
                for (suffix, expectedBytes) in sourceFamily {
                    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sourceURL.path + suffix)), expectedBytes)
                }

                let journalURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasPrefix(".latticelens-v11-migration-") })
                let journal = try JSONDecoder.latticeLens.decode(
                    V10StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
                XCTAssertEqual(journal.sourceSchemaVersion, sourceSchemaVersion)
                let recovered = try V10StoreMigrationCoordinator.recover(
                    journalURL: journalURL,
                    parent: root,
                    descriptorURL: descriptorURL,
                    backupRoot: backupRoot,
                    verifyActive: { _ in sourceSummary }
                )
                XCTAssertEqual(recovered.phase, .rolledBack)
                XCTAssertFalse(FileManager.default.fileExists(atPath: descriptorURL.path))
                for (suffix, expectedBytes) in sourceFamily {
                    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sourceURL.path + suffix)), expectedBytes,
                                   "failed V\(sourceSchemaVersion) recovery must leave source data byte-stable")
                }
            }
        }
    }

    /// Opt-in end-to-end disk-capacity test.  The sparse HFS+ image is created
    /// and mounted below project-local XCTest scratch; no host volume is filled.
    @MainActor
    func testV10MigrationPhysicalDiskExhaustionOnDisposableImage() throws {
        guard ProcessInfo.processInfo.environment["LATTICELENS_V10_PHYSICAL_ENOSPC_DRILL"] == "1" else {
            throw XCTSkip("opt-in bounded HFS+ disk-image drill; run through Scripts/v10_physical_enospc_drill.sh")
        }

        let fileManager = FileManager.default
        let root = try makeProjectLocalTestDirectory(prefix: "v10-physical-enospc")
        defer { try? fileManager.removeItem(at: root) }

        func runHdiutil(_ arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: Data) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let error = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, output, error)
        }

        let imageURL = root.appendingPathComponent("v10-physical-enospc.sparseimage")
        let mountURL = root.appendingPathComponent("mounted", isDirectory: true)
        try fileManager.createDirectory(at: mountURL, withIntermediateDirectories: false)
        let create = try runHdiutil([
            "create", "-size", "64m", "-type", "SPARSE", "-fs", "Journaled HFS+",
            "-volname", "LLG02Physical", "-nospotlight", imageURL.path
        ])
        guard create.status == 0 else {
            XCTFail("hdiutil create failed: \(String(decoding: create.stderr, as: UTF8.self))")
            return
        }

        var attachedDevice: String?
        defer {
            if let attachedDevice {
                _ = try? runHdiutil(["detach", attachedDevice])
            }
        }
        let attach = try runHdiutil([
            "attach", "-plist", "-nobrowse", "-owners", "off", "-mountpoint", mountURL.path, imageURL.path
        ])
        guard attach.status == 0 else {
            XCTFail("hdiutil attach failed: \(String(decoding: attach.stderr, as: UTF8.self))")
            return
        }
        let attachPlist = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: attach.stdout, options: [], format: nil) as? [String: Any])
        let entities = try XCTUnwrap(attachPlist["system-entities"] as? [[String: Any]])
        let mountPath = mountURL.standardizedFileURL.path
        attachedDevice = entities.first {
            ($0["mount-point"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path == mountPath } ?? false
        }?["dev-entry"] as? String
        guard attachedDevice != nil else {
            XCTFail("attached image did not report the requested project-local mount point")
            return
        }

        let fileSystemAttributes = try fileManager.attributesOfFileSystem(forPath: mountURL.path)
        let volumeSize = (fileSystemAttributes[.systemSize] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(volumeSize, 0)
        XCTAssertLessThanOrEqual(volumeSize, 64 * 1024 * 1024,
                                 "the test must remain on its bounded disk image")

        let sourceURL = mountURL.appendingPathComponent("synthetic-v10.store")
        let sourceFamily: [(String, Data)] = [
            ("", Data(repeating: 0x51, count: 4 * 1024 * 1024)),
            ("-wal", Data(repeating: 0x52, count: 512 * 1024)),
            ("-shm", Data(repeating: 0x53, count: 256 * 1024))
        ]
        for (suffix, bytes) in sourceFamily {
            try bytes.write(to: URL(fileURLWithPath: sourceURL.path + suffix))
        }
        let totalSourceBytes = Int64(sourceFamily.reduce(0) { $0 + $1.1.count })
        let targetFreeBytes = totalSourceBytes * 2 + 2 * 1024 * 1024
        let fillerURL = mountURL.appendingPathComponent("capacity-reservation.bin")
        guard fileManager.createFile(atPath: fillerURL.path, contents: Data()) else {
            XCTFail("could not create the image-local capacity reservation")
            return
        }
        let filler = try FileHandle(forWritingTo: fillerURL)
        let chunk = Data(repeating: 0xA5, count: 256 * 1024)
        while true {
            let attributes = try fileManager.attributesOfFileSystem(forPath: mountURL.path)
            let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            if available <= targetFreeBytes { break }
            let writeCount = Int(min(Int64(chunk.count), available - targetFreeBytes))
            try filler.write(contentsOf: chunk.prefix(writeCount))
        }
        try filler.close()
        let finalFileSystemAttributes = try fileManager.attributesOfFileSystem(forPath: mountURL.path)
        let freeBeforeMigration = (finalFileSystemAttributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThanOrEqual(freeBeforeMigration, totalSourceBytes * 2 + 1024 * 1024,
                                    "the image must have room for backup and probe before staging-copy")
        XCTAssertLessThan(freeBeforeMigration, totalSourceBytes * 2 + 3 * 1024 * 1024,
                          "after backup and probe the staging copy must not fit")
        print("G02_PHYSICAL_IMAGE bytes=\(volumeSize) source_family_bytes=\(totalSourceBytes) free_before_migration=\(freeBeforeMigration) filesystem=Journaled_HFS+")

        let sourceHashes = try sourceFamily.map { suffix, _ in
            (suffix, StableHash.sha256(try Data(contentsOf: URL(fileURLWithPath: sourceURL.path + suffix))))
        }
        let backupRoot = mountURL.appendingPathComponent("backups", isDirectory: true)
        let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(for: sourceURL)
        let sourceSummary = legacySemanticSummary(counts: ["papers": 1], stableIDHash: "physical-enospc-v10")
        var observedError: Error?
        do {
            _ = try V10StoreMigrationCoordinator.migrate(
                sourceURL: sourceURL,
                descriptorURL: descriptorURL,
                backupRoot: backupRoot,
                fileManager: fileManager,
                targetSchemaVersion: 12,
                readBackupSchemaVersion: { _ in 10 },
                inspectBackupCopy: { _, _ in sourceSummary }
            ) { _, _ in
                XCTFail("the migration must exhaust image capacity before schema work starts")
                return sourceSummary
            }
        } catch {
            observedError = error
        }

        guard let observedError else {
            XCTFail("migration unexpectedly completed on the deliberately capacity-limited image")
            return
        }
        let fileWriteOutOfSpaceCode = (CocoaError(.fileWriteOutOfSpace) as NSError).code
        func isDiskFull(_ error: Error) -> Bool {
            var current: NSError? = error as NSError
            while let value = current {
                if value.domain == NSCocoaErrorDomain && value.code == fileWriteOutOfSpaceCode {
                    return true
                }
                if value.domain == NSPOSIXErrorDomain && value.code == Int(ENOSPC) {
                    return true
                }
                current = value.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            return false
        }
        guard isDiskFull(observedError) else {
            XCTFail("expected a real ENOSPC/fileWriteOutOfSpace from the image, got: \(observedError)")
            return
        }
        print("G02_PHYSICAL_ENOSPC observed_error=\(String(reflecting: observedError))")
        XCTAssertFalse(fileManager.fileExists(atPath: descriptorURL.path),
                       "an out-of-space staging copy must not publish an active descriptor")
        for (suffix, hash) in sourceHashes {
            let actual = StableHash.sha256(try Data(contentsOf: URL(fileURLWithPath: sourceURL.path + suffix)))
            XCTAssertEqual(actual, hash, "source family member \(suffix) must remain byte-stable")
        }

        let journalURL = try XCTUnwrap(fileManager.contentsOfDirectory(at: mountURL, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".latticelens-v12-migration-") })
        let failedJournal = try JSONDecoder.latticeLens.decode(
            V10StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
        XCTAssertTrue([V10StoreMigrationPhase.failed, .backedUp].contains(failedJournal.phase),
                      "when the disk is full, the last durable journal phase may remain backedUp")
        XCTAssertEqual(failedJournal.sourceSchemaVersion, 10)
        print("G02_PHYSICAL_JOURNAL phase_before_recovery=\(failedJournal.phase.rawValue) descriptor=absent source_family=unchanged")

        try fileManager.removeItem(at: fillerURL)
        let recovered = try V10StoreMigrationCoordinator.recover(
            journalURL: journalURL,
            parent: mountURL,
            descriptorURL: descriptorURL,
            backupRoot: backupRoot,
            fileManager: fileManager,
            verifyActive: { _ in sourceSummary }
        )
        XCTAssertEqual(recovered.phase, .rolledBack)
        XCTAssertFalse(fileManager.fileExists(atPath: descriptorURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: mountURL.appendingPathComponent(recovered.stagingStoreName).path))
        for (suffix, hash) in sourceHashes {
            let actual = StableHash.sha256(try Data(contentsOf: URL(fileURLWithPath: sourceURL.path + suffix)))
            XCTAssertEqual(actual, hash, "recovery must leave source family member \(suffix) unchanged")
        }
        print("G02_PHYSICAL_RECOVERY phase=\(recovered.phase.rawValue) descriptor=absent source_family=unchanged")
    }

    @MainActor
    func testV10MigrationCategoryBootstrapCrashOnRealV9StoreRollsBackStaging() throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-real-category-crash")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        let sourceURL = root.appendingPathComponent("Library-v9.store")
        let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(for: sourceURL)
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        do {
            let schema = Schema(versionedSchema: LatticeLensSchemaV9.self)
            let source = try ModelContainer(for: schema, configurations: ModelConfiguration(url: sourceURL))
            try V8TypedStoreCodec.materialize(
                LibrarySnapshot(papers: [17: makePaper(17)], schemaVersion: 9),
                in: source.mainContext, sourceSchemaVersion: 9)
        }
        let sourceFamily = try ["", "-wal", "-shm"].compactMap { suffix -> (String, Data)? in
            let member = URL(fileURLWithPath: sourceURL.path + suffix)
            guard fileManager.fileExists(atPath: member.path) else { return nil }
            return (suffix, try Data(contentsOf: member))
        }
        XCTAssertFalse(sourceFamily.isEmpty)

        XCTAssertThrowsError(try V10StoreMigrationCoordinator.migrate(
            sourceURL: sourceURL,
            descriptorURL: descriptorURL,
            backupRoot: backupRoot,
            crashAt: .categoryMigration,
            fileManager: fileManager,
            inspectBackupCopy: { probeURL, version in
                try Self.inspectStoreForV10Summary(at: probeURL, schemaVersion: version)
            }
        ) { stagingURL, reportProgress in
            let schema = Schema(versionedSchema: LatticeLensSchemaV11.self)
            let configuration = ModelConfiguration(schema: schema, url: stagingURL)
            let staged = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV11.self,
                                            configurations: configuration)
            try V10CategoryProfileBootstrap.migrateOrCreate(in: staged.mainContext)
            try reportProgress(.categoryMigrated)
            XCTFail("injected crash must stop before search-index work")
            return try V10StoreSemanticSummary.make(from: staged.mainContext, schemaVersion: 11)
        })

        XCTAssertFalse(fileManager.fileExists(atPath: descriptorURL.path))
        let journalURL = try XCTUnwrap(fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".latticelens-v11-migration-") })
        let journal = try JSONDecoder.latticeLens.decode(V10StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
        let recovered = try V10StoreMigrationCoordinator.recover(
            journalURL: journalURL,
            parent: root,
            descriptorURL: descriptorURL,
            backupRoot: backupRoot,
            fileManager: fileManager,
            verifyActive: { try Self.inspectStoreForV10Summary(at: $0, schemaVersion: 11) }
        )
        XCTAssertEqual(recovered.phase, .rolledBack)
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent(journal.stagingStoreName).path))
        XCTAssertFalse(fileManager.fileExists(atPath: descriptorURL.path))
        for (suffix, expected) in sourceFamily {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sourceURL.path + suffix)), expected)
        }
    }

    @MainActor
    func testProductionFactoryStagesV11StoreIntoV12AndPreservesTheV11Source() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "factory-v11-to-v12")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Library-v11.store")
        let paper = makePaper(12001)
        try autoreleasepool {
            let schema = Schema(versionedSchema: LatticeLensSchemaV11.self)
            let source = try ModelContainer(for: schema, configurations: ModelConfiguration(url: sourceURL))
            try V8TypedStoreCodec.materialize(
                LibrarySnapshot(papers: [paper.literatureID: paper], schemaVersion: 11),
                in: source.mainContext, sourceSchemaVersion: 11)
        }
        let sourceMembers = try ["", "-wal", "-shm"].compactMap { suffix -> (String, Data)? in
            let member = URL(fileURLWithPath: sourceURL.path + suffix)
            guard FileManager.default.fileExists(atPath: member.path) else { return nil }
            return (suffix, try Data(contentsOf: member))
        }
        XCTAssertFalse(sourceMembers.isEmpty)

        do {
            let migratedStore = LibraryStoreFactory.makeDefault(storeURLOverride: sourceURL)
            XCTAssertFalse(migratedStore is V8MigrationBlockedStore)
            let migratedSnapshot = await migratedStore.snapshot()
            XCTAssertEqual(migratedSnapshot.papers[paper.literatureID]?.displayTitle, paper.displayTitle)
        }

        let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(
            for: sourceURL, targetSchemaVersion: 12)
        let descriptor = try JSONDecoder.latticeLens.decode(
            V10ActiveStoreDescriptor.self, from: Data(contentsOf: descriptorURL))
        XCTAssertEqual(descriptor.schemaVersion, 12)
        let activeURL = root.appendingPathComponent(descriptor.storeName)
        let schema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let active = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
            configurations: ModelConfiguration(schema: schema, url: activeURL))
        XCTAssertEqual(try active.mainContext.fetch(FetchDescriptor<StoredV8Paper>()).map(\.literatureID),
                       [paper.literatureID])
        XCTAssertEqual(try active.mainContext.fetchCount(FetchDescriptor<StoredV12FormulaDerivationSegment>()), 0)
        let targetSummary = try V10StoreSemanticSummary.make(from: active.mainContext, schemaVersion: 12)
        let journalURL = root.appendingPathComponent(
            ".latticelens-v12-migration-\(descriptor.runID.uuidString).json")
        let journal = try JSONDecoder.latticeLens.decode(V10StoreMigrationJournal.self,
            from: Data(contentsOf: journalURL))
        XCTAssertEqual(journal.sourceSchemaVersion, 11)
        XCTAssertEqual(journal.targetSchemaVersion, 12)
        XCTAssertEqual(journal.phase, .activated)
        XCTAssertTrue(journal.sourceSummary.preservesDomainAndTypedRows(
            in: targetSummary, sourceSchemaVersion: 11))
        for (suffix, expected) in sourceMembers {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sourceURL.path + suffix)), expected,
                           "V11 source family member '\(suffix)' must remain byte-stable after staged V12 activation")
        }

        let reopenedStore = LibraryStoreFactory.makeDefault(storeURLOverride: sourceURL)
        XCTAssertFalse(reopenedStore is V8MigrationBlockedStore)
        let reopenedSnapshot = await reopenedStore.snapshot()
        XCTAssertEqual(reopenedSnapshot.papers[paper.literatureID]?.displayTitle, paper.displayTitle)
    }

    @MainActor
    func testDefaultFactoryKeepsLegacyCategorySelectionAndInvalidatesOnlyLegacyQuery() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "factory-v9-legacy-category")
        defer { try? FileManager.default.removeItem(at: root) }
        let baseURL = root.appendingPathComponent("Library-v9.store")
        let checkpoint = SyncCheckpoint(jobID: "author-candidates:hep-lat-or-hep-th",
            jobKind: "author-candidates", query: "arxiv_categories:hep-lat OR arxiv_categories:hep-th",
            generationID: "legacy-category-generation")
        let snapshot = LibrarySnapshot(papers: [23: makePaper(23)],
            checkpoints: [checkpoint.id: checkpoint], schemaVersion: 9)
        do {
            let schema = Schema(versionedSchema: LatticeLensSchemaV9.self)
            let source = try ModelContainer(for: schema, configurations: ModelConfiguration(url: baseURL))
            try V8TypedStoreCodec.materialize(snapshot, in: source.mainContext, sourceSchemaVersion: 9)
        }

        let store = LibraryStoreFactory.makeDefault(storeURLOverride: baseURL)
        let migratedSnapshot = await store.snapshot()
        XCTAssertEqual(migratedSnapshot.checkpoints[checkpoint.id]?.query, checkpoint.query)
        XCTAssertEqual(migratedSnapshot.papers[23]?.displayTitle, "Paper 23")

        let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(for: baseURL, targetSchemaVersion: 12)
        let descriptor = try JSONDecoder.latticeLens.decode(V10ActiveStoreDescriptor.self, from: Data(contentsOf: descriptorURL))
        let activeURL = root.appendingPathComponent(descriptor.storeName)
        let activeSchema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let active = try ModelContainer(for: activeSchema, migrationPlan: LatticeLensMigrationPlanV12.self,
            configurations: ModelConfiguration(schema: activeSchema, url: activeURL))
        let profile = try XCTUnwrap(active.mainContext.fetch(FetchDescriptor<StoredV10CategoryProfile>()).first)
        XCTAssertEqual(try JSONDecoder.latticeLens.decode([String].self, from: profile.categoriesData),
                       ["hep-lat", "hep-th"])
        let invalidation = try XCTUnwrap(active.mainContext.fetch(FetchDescriptor<StoredV10SearchIndexState>())
            .first { $0.indexName == "legacy-author-category-checkpoints" })
        XCTAssertEqual(invalidation.state, "invalidated_by_query_revision")
        XCTAssertEqual(invalidation.indexedRecordCount, 1)

        let journalURL = root.appendingPathComponent(".latticelens-v12-migration-\(descriptor.runID.uuidString).json")
        let journal = try JSONDecoder.latticeLens.decode(V10StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
        let activeSummary = try V10StoreSemanticSummary.make(from: active.mainContext, schemaVersion: 12)
        XCTAssertTrue(journal.sourceSummary.preservesDomainAndTypedRows(in: activeSummary, sourceSchemaVersion: 9))
        XCTAssertEqual(activeSummary.legacyCategoryCheckpointCount, 1)
    }

    @MainActor
    func testDefaultFactoryRepairsMissingV10ProfileWithoutChangingExistingTypedRows() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "factory-v10-missing-profile")
        defer { try? FileManager.default.removeItem(at: root) }
        let baseURL = root.appendingPathComponent("Library-v10.store")
        let paper = makePaper(31)
        try autoreleasepool {
            let schema = Schema(versionedSchema: LatticeLensSchemaV10.self)
            let source = try ModelContainer(for: schema, configurations: ModelConfiguration(url: baseURL))
            try V8TypedStoreCodec.materialize(
                LibrarySnapshot(papers: [paper.literatureID: paper], schemaVersion: 10),
                in: source.mainContext, sourceSchemaVersion: 10)
            source.mainContext.insert(StoredV10FormulaInventory(id: "preserve-inventory", paperID: 31,
                documentID: "document", documentHash: "document-hash", inventoryHash: "inventory-hash",
                parserVersion: 2, status: "partial", payload: Data("preserve-me".utf8)))
            try source.mainContext.save()
        }
        let store = LibraryStoreFactory.makeDefault(storeURLOverride: baseURL)
        let migratedSnapshot = await store.snapshot()
        XCTAssertEqual(migratedSnapshot.papers[31]?.displayTitle, paper.displayTitle)
        let descriptor = try JSONDecoder.latticeLens.decode(V10ActiveStoreDescriptor.self,
            from: Data(contentsOf: V10StoreMigrationCoordinator.descriptorURL(
                for: baseURL, targetSchemaVersion: 12)))
        let activeURL = root.appendingPathComponent(descriptor.storeName)
        let activeSchema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let active = try ModelContainer(for: activeSchema, migrationPlan: LatticeLensMigrationPlanV12.self,
            configurations: ModelConfiguration(schema: activeSchema, url: activeURL))
        XCTAssertEqual(try active.mainContext.fetchCount(FetchDescriptor<StoredV10CategoryProfile>()), 1)
        let migratedInventory = try XCTUnwrap(try active.mainContext.fetch(
            FetchDescriptor<StoredV10FormulaInventory>(predicate: #Predicate { $0.id == "preserve-inventory" })).first)
        XCTAssertEqual(migratedInventory.payload, Data("preserve-me".utf8),
                       "repairing the missing category profile must preserve existing typed formula payloads")
        let journalURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".latticelens-v12-migration-") })
        let journal = try JSONDecoder.latticeLens.decode(V10StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
        let summary = try V10StoreSemanticSummary.make(from: active.mainContext, schemaVersion: 12)
        XCTAssertTrue(journal.sourceSummary.preservesDomainAndTypedRows(in: summary, sourceSchemaVersion: 10))

        XCTAssertEqual(try V10StoreSQLiteSchemaProbe.schemaVersion(at: baseURL), 10,
                       "the original source must remain an independently readable V10 store")
        let sourceSchema = Schema(versionedSchema: LatticeLensSchemaV10.self)
        let source = try ModelContainer(for: sourceSchema,
            configurations: ModelConfiguration(schema: sourceSchema, url: baseURL, allowsSave: false))
        let sourceInventory = try XCTUnwrap(try source.mainContext.fetch(
            FetchDescriptor<StoredV10FormulaInventory>(predicate: #Predicate { $0.id == "preserve-inventory" })).first)
        XCTAssertEqual(sourceInventory.payload, Data("preserve-me".utf8),
                       "the V10 source must retain its existing typed formula payload")
        XCTAssertEqual(try source.mainContext.fetchCount(FetchDescriptor<StoredV10CategoryProfile>()), 0,
                       "the V12 category repair belongs to staging, not the original V10 source")
    }

    @MainActor
    func testV10FormulaCheckpointSurvivesStagedV12UpgradeAndBackfillsCanonicalRows() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-to-v11-formula-checkpoint")
        defer { try? FileManager.default.removeItem(at: root) }
        let baseURL = root.appendingPathComponent("Library-v10.store")
        let jobID = "legacy-v10-formula-job"
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000)
        let batch = FormulaBatchCheckpoint(jobID: jobID, batchIndex: 0, batchTotal: 1,
            equationIDs: ["eq-v10"], payloadHash: "legacy-payload", requestID: "legacy-request",
            attemptCount: 1, receivedBytes: 32, receivedCharacters: 24, status: .completed,
            updatedAt: timestamp)
        let job = FormulaDerivationJob(jobID: jobID, paperID: 71, documentHash: "doc-v10",
            inventoryHash: "inventory-v10", equationIDs: ["eq-v10"], state: .complete,
            batches: [batch], startedAt: timestamp, updatedAt: timestamp)
        let claim = EvidenceClaim(textZH: "legacy source claim", epistemicStatus: .direct,
            evidenceIDs: ["anchor-v10"], formulaTeX: "x=1", equationID: "eq-v10",
            derivationSteps: ["legacy derivation"])
        let checkpoint = FormulaDerivationCheckpoint(job: job, completedClaimsByBatch: [0: [claim]],
            promptVersion: FormulaDerivationPrompt.version, schemaVersion: PaperInsightV2Validator.schemaVersion,
            contextFingerprint: "legacy-context", updatedAt: timestamp)
        let sourceProjection = try JSONEncoder.latticeLens.encode(checkpoint)
        do {
            let schema = Schema(versionedSchema: LatticeLensSchemaV10.self)
            let source = try ModelContainer(for: schema, configurations: ModelConfiguration(url: baseURL))
            try V8TypedStoreCodec.materialize(LibrarySnapshot(schemaVersion: 10),
                in: source.mainContext, sourceSchemaVersion: 10)
            source.mainContext.insert(StoredV10FormulaDerivationJob(id: jobID, paperID: job.paperID,
                documentID: "71:doc-v10", documentHash: job.documentHash, inventoryHash: job.inventoryHash,
                state: job.state.rawValue, promptVersion: checkpoint.promptVersion,
                schemaVersion: checkpoint.schemaVersion, createdAt: timestamp, updatedAt: timestamp,
                payload: sourceProjection))
            source.mainContext.insert(StoredV10FormulaBatchCheckpoint(id: batch.id, jobID: jobID,
                inventoryHash: job.inventoryHash, batchIndex: 0, batchTotal: 1,
                equationIDsData: try JSONEncoder.latticeLens.encode(batch.equationIDs),
                requestID: batch.requestID, attemptCount: batch.attemptCount, payloadHash: batch.payloadHash,
                receivedBytes: batch.receivedBytes, receivedCharacters: batch.receivedCharacters,
                firstContentAt: batch.firstContentAt, lastContentAt: batch.lastContentAt,
                status: batch.status.rawValue, errorCategory: nil, updatedAt: timestamp))
            source.mainContext.insert(StoredV10FormulaDerivationStep(id: "\(jobID):eq-v10:0",
                jobID: jobID, equationID: "eq-v10", ordinal: 0, text: "legacy derivation",
                anchorID: "anchor-v10", status: "validated_batch_0"))
            try source.mainContext.save()
        }
        let sourceFamily = try ["", "-wal", "-shm"].compactMap { suffix -> (String, Data)? in
            let member = URL(fileURLWithPath: baseURL.path + suffix)
            guard FileManager.default.fileExists(atPath: member.path) else { return nil }
            return (suffix, try Data(contentsOf: member))
        }

        let library = LibraryStoreFactory.makeDefault(storeURLOverride: baseURL)
        guard let formulaStore = library as? any FormulaJobStoring else {
            XCTFail("the V12 production store must expose the durable formula-job repository")
            return
        }
        let restored = try await formulaStore.formulaJob(id: jobID)
        XCTAssertEqual(restored?.completedClaimsByBatch[0], [claim])
        XCTAssertEqual(restored?.contextFingerprint, "legacy-context")

        let descriptor = try JSONDecoder.latticeLens.decode(V10ActiveStoreDescriptor.self,
            from: Data(contentsOf: V10StoreMigrationCoordinator.descriptorURL(
                for: baseURL, targetSchemaVersion: 12)))
        XCTAssertEqual(descriptor.schemaVersion, 12)
        let activeURL = root.appendingPathComponent(descriptor.storeName)
        let activeSchema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let active = try ModelContainer(for: activeSchema, migrationPlan: LatticeLensMigrationPlanV12.self,
            configurations: ModelConfiguration(schema: activeSchema, url: activeURL))
        XCTAssertEqual(try active.mainContext.fetch(FetchDescriptor<StoredV11FormulaDerivationJob>()).count, 1)
        XCTAssertEqual(try active.mainContext.fetch(FetchDescriptor<StoredV11FormulaClaim>()).count, 1)
        let compatibilityRow = try XCTUnwrap(try active.mainContext.fetch(
            FetchDescriptor<StoredV10FormulaDerivationJob>(predicate: #Predicate { $0.id == jobID })).first)
        XCTAssertEqual(compatibilityRow.payload, sourceProjection,
                       "the V10 projection remains unchanged while the V11 canonical rows are backfilled")
        for (suffix, expected) in sourceFamily {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: baseURL.path + suffix)), expected,
                           "staged V10-to-V11 migration and lazy row backfill must not mutate the source family")
        }
    }

    /// This separately sealed drill creates all V10 source stores itself. It
    /// checks production activation, post-activation restore from the verified
    /// backup into a fresh target, and pre-activation crash recovery. No leg
    /// accepts a caller-provided library path.
    @MainActor
    func testAuthorizedDisposableV10ToV12MigrationDrill() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawOutputRoot = environment["LATTICELENS_V10_DISPOSABLE_DRILL_ROOT"],
              let inputManifestSHA256 = environment["LATTICELENS_V10_DISPOSABLE_INPUT_MANIFEST_SHA256"] else {
            throw XCTSkip("set only by the project-local final verifier with an isolated scratch root")
        }
        guard inputManifestSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            XCTFail("the migration drill must be bound to a SHA-256 input manifest")
            return
        }

        let testSourceURL = URL(fileURLWithPath: #filePath).standardizedFileURL.resolvingSymlinksInPath()
        let projectRoot = testSourceURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let suppliedRoot = URL(fileURLWithPath: rawOutputRoot, isDirectory: true).standardizedFileURL
        let outputRoot = suppliedRoot.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        let rootValues = try suppliedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rawOutputRoot.hasPrefix("/"), rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true, outputRoot == suppliedRoot,
              outputRoot.path.hasPrefix(projectRoot.path + "/") else {
            XCTFail("the disposable V10 drill root must be a real, non-symlink directory inside this project")
            return
        }
        guard try fileManager.contentsOfDirectory(at: outputRoot, includingPropertiesForKeys: nil).isEmpty else {
            XCTFail("the disposable V10 drill root must start empty")
            return
        }

        let runID = UUID().uuidString
        let runRoot = outputRoot.appendingPathComponent("V10-Migration-\(runID)", isDirectory: true)
        try fileManager.createDirectory(at: runRoot, withIntermediateDirectories: false)

        let successDirectory = runRoot.appendingPathComponent("success", isDirectory: true)
        try fileManager.createDirectory(at: successDirectory, withIntermediateDirectories: false)
        let successSource = successDirectory.appendingPathComponent("synthetic-v10-success.store")
        let successSourceSummary = try seedSyntheticV10Store(at: successSource, paperID: 81001)
        let successSourceHashes = try v10DisposableStoreFamilyHashes(at: successSource)

        let migratedStore = LibraryStoreFactory.makeDefault(storeURLOverride: successSource)
        let migratedSnapshot = await migratedStore.snapshot()
        guard migratedSnapshot.readErrorMessage == nil else {
            let semanticDiagnostic: String
            do {
                let journalURL = try XCTUnwrap(fileManager.contentsOfDirectory(
                    at: successDirectory, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasPrefix(".latticelens-v12-migration-") })
                let journal = try JSONDecoder.latticeLens.decode(
                    V10StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
                let stagingURL = successDirectory.appendingPathComponent(journal.stagingStoreName)
                let targetSummary = try Self.inspectStoreForV10Summary(at: stagingURL, schemaVersion: 12)
                let sourceSummary = successSourceSummary
                let families = Set(sourceSummary.typedRowCounts.keys).union(targetSummary.typedRowCounts.keys)
                let changedFamilies = families.sorted().filter { family in
                    sourceSummary.typedRowCounts[family] != targetSummary.typedRowCounts[family] ||
                        sourceSummary.typedFamilyIdentityHashes[family] != targetSummary.typedFamilyIdentityHashes[family] ||
                        sourceSummary.typedFamilyContentHashes[family] != targetSummary.typedFamilyContentHashes[family]
                }
                let familyDifferenceDescriptions = changedFamilies.map { family in
                    let sourceCount = sourceSummary.typedRowCounts[family, default: 0]
                    let targetCount = targetSummary.typedRowCounts[family, default: 0]
                    return "\(family):\(sourceCount)->\(targetCount)"
                }
                semanticDiagnostic = "domainEqual=\(sourceSummary.domainSummary == targetSummary.domainSummary), " +
                    "libraryHashEqual=\(sourceSummary.serializedLibraryHash == targetSummary.serializedLibraryHash), " +
                    "hashFormats=\(sourceSummary.serializedLibraryHashFormatVersion)/\(targetSummary.serializedLibraryHashFormatVersion), " +
                    "typedFamilyDiffs=\(familyDifferenceDescriptions.joined(separator: ",")), " +
                    "categoryProfiles=\(String(describing: sourceSummary.categoryProfileCategories))->\(String(describing: targetSummary.categoryProfileCategories)), " +
                    "legacyCheckpoint=\(sourceSummary.hasLegacyCategoryCheckpoint)/\(sourceSummary.legacyCategoryCheckpointCount)->\(targetSummary.hasLegacyCategoryCheckpoint)/\(targetSummary.legacyCategoryCheckpointCount)"
            } catch {
                semanticDiagnostic = "could not inspect synthetic staging summary: \(error)"
            }
            XCTFail("production V10 migration was blocked: \(migratedSnapshot.readErrorMessage ?? "unknown persistence error"); \(semanticDiagnostic)")
            return
        }
        XCTAssertNil(migratedSnapshot.readErrorMessage, "the production factory must not return a blocked/empty store")
        XCTAssertEqual(migratedSnapshot.papers[81001]?.displayTitle, "Canonical fixture 81001")
        XCTAssertEqual(migratedSnapshot.authors[91001]?.preferredName, "Canonical, Author")
        XCTAssertTrue(migratedSnapshot.paperAuthorLinks.contains(PaperAuthorLink(
            paperID: 81001, authorRecid: 91001, position: 0)))

        let successDescriptorURL = V10StoreMigrationCoordinator.descriptorURL(
            for: successSource, targetSchemaVersion: 12)
        let successDescriptor = try JSONDecoder.latticeLens.decode(
            V10ActiveStoreDescriptor.self, from: Data(contentsOf: successDescriptorURL))
        XCTAssertEqual(successDescriptor.schemaVersion, 12)
        let successActiveURL = successDirectory.appendingPathComponent(successDescriptor.storeName)
        let successTargetSummary = try Self.inspectStoreForV10Summary(at: successActiveURL, schemaVersion: 12)
        let successJournalURL = successDirectory
            .appendingPathComponent(".latticelens-v12-migration-\(successDescriptor.runID.uuidString).json")
        let successJournal = try JSONDecoder.latticeLens.decode(
            V10StoreMigrationJournal.self, from: Data(contentsOf: successJournalURL))
        XCTAssertEqual(successJournal.phase, .activated)
        XCTAssertEqual(successJournal.sourceSchemaVersion, 10)
        XCTAssertEqual(successJournal.targetSchemaVersion, 12)
        XCTAssertEqual(successJournal.targetSummary, successTargetSummary)
        XCTAssertEqual(successDescriptor.semanticHash, successTargetSummary.stableIDHash)
        XCTAssertTrue(successSourceSummary.preservesDomainAndTypedRows(
            in: successTargetSummary, sourceSchemaVersion: 10))
        let invalidationMarker = "legacy-author-category-checkpoints"
        XCTAssertNil(successSourceSummary.searchIndexStateRowHashes[invalidationMarker])
        XCTAssertNotNil(successTargetSummary.searchIndexStateRowHashes[invalidationMarker])
        XCTAssertEqual(successTargetSummary.typedRowCounts["searchIndexStates", default: 0],
                       successSourceSummary.typedRowCounts["searchIndexStates", default: 0] + 1)
        XCTAssertEqual(successSourceSummary.legacyCheckpointInvalidationCount, nil)
        XCTAssertEqual(successTargetSummary.legacyCheckpointInvalidationCount,
                       successSourceSummary.legacyCategoryCheckpointCount)
        XCTAssertNotEqual(successSourceSummary.stableIDHash, successTargetSummary.stableIDHash,
                          "the activated descriptor must bind the migration's derived invalidation row")
        var tamperedSearchStateRows = successTargetSummary.searchIndexStateRowHashes
        tamperedSearchStateRows["synthetic-search"] = StableHash.sha256("tampered synthetic search state")
        let tamperedTargetSummary = V10StoreSemanticSummary(
            domainSummary: successTargetSummary.domainSummary,
            serializedLibraryHash: successTargetSummary.serializedLibraryHash,
            serializedLibraryHashFormatVersion: successTargetSummary.serializedLibraryHashFormatVersion,
            typedRowCounts: successTargetSummary.typedRowCounts,
            typedIdentityHash: successTargetSummary.typedIdentityHash,
            typedContentHash: successTargetSummary.typedContentHash,
            typedFamilyIdentityHashes: successTargetSummary.typedFamilyIdentityHashes,
            typedFamilyContentHashes: successTargetSummary.typedFamilyContentHashes,
            searchIndexStateRowHashes: tamperedSearchStateRows,
            categoryProfileCategories: successTargetSummary.categoryProfileCategories,
            hasLegacyCategoryCheckpoint: successTargetSummary.hasLegacyCategoryCheckpoint,
            legacyCategoryCheckpointCount: successTargetSummary.legacyCategoryCheckpointCount,
            legacyCheckpointInvalidationCount: successTargetSummary.legacyCheckpointInvalidationCount)
        XCTAssertFalse(successSourceSummary.preservesDomainAndTypedRows(
            in: tamperedTargetSummary, sourceSchemaVersion: 10),
            "adding the derived invalidation marker must not mask a changed pre-existing index row")
        XCTAssertEqual(successTargetSummary.categoryProfileCategories, ["hep-lat", "hep-th"])
        let successSourceHashesAfter = try v10DisposableStoreFamilyHashes(at: successSource)
        XCTAssertEqual(successSourceHashesAfter, successSourceHashes,
                       "the pre-upgrade V10 SQLite family must remain byte-identical")

        let successBackupRoot = successDirectory.appendingPathComponent("LatticeLens-StoreBackups", isDirectory: true)
        let successBackupDirectory = successBackupRoot
            .appendingPathComponent(successJournal.backupManifestID.uuidString, isDirectory: true)
        let successBackupManifest = try JSONDecoder.latticeLens.decode(V10MigrationBackupManifest.self,
            from: Data(contentsOf: successBackupDirectory.appendingPathComponent("migration-manifest.json")))
        XCTAssertEqual(successBackupManifest.sourceSchemaVersion, 10)
        XCTAssertEqual(successBackupManifest.targetSchemaVersion, 12)
        XCTAssertEqual(successBackupManifest.manifestHash, successJournal.backupManifestHash)
        XCTAssertEqual(successBackupManifest.semanticSummary, successSourceSummary)
        XCTAssertEqual(successBackupManifest.recordCounts, successSourceSummary.recordCounts)
        let successBackupVerified = try V4StoreBackupCoordinator.verify(
            successBackupManifest.storeFamilyManifest, in: successBackupRoot)
        XCTAssertTrue(successBackupVerified)

        // Exercise the v5 rollback contract after activation: restore the
        // verified pre-migration V10 backup into a fresh location, reconcile
        // its bytes and semantics, then reopen it through the production
        // factory so the restored library is usable again as V12.
        let restoreTargetDirectory = runRoot.appendingPathComponent("post-activation-restore", isDirectory: true)
        let restoreTargetWasAbsent = !fileManager.fileExists(atPath: restoreTargetDirectory.path)
        XCTAssertTrue(restoreTargetWasAbsent)
        try V4StoreBackupCoordinator.restore(successBackupManifest.storeFamilyManifest,
            from: successBackupRoot, to: restoreTargetDirectory)
        let restoredV10StoreURL = restoreTargetDirectory.appendingPathComponent(successSource.lastPathComponent)
        let restoredFamilyHashes = try v10DisposableStoreFamilyHashes(at: restoredV10StoreURL)
        let manifestFamilyHashes = Dictionary(uniqueKeysWithValues:
            successBackupManifest.storeFamilyManifest.files.map { ($0.relativePath, $0.sha256) })
        let restoredFamilyMatchesManifest = restoredFamilyHashes == manifestFamilyHashes
        XCTAssertTrue(restoredFamilyMatchesManifest,
                      "the fresh restore must match every SQLite family hash recorded by the verified backup")
        let restoredSchemaVersion = try V10StoreSQLiteSchemaProbe.schemaVersion(at: restoredV10StoreURL)
        XCTAssertEqual(restoredSchemaVersion, 10,
                       "a pre-migration backup must restore as V10 before the production factory opens it")
        let restoredV10Summary = try Self.inspectStoreForV10Summary(at: restoredV10StoreURL,
                                                                   schemaVersion: restoredSchemaVersion)
        XCTAssertEqual(restoredV10Summary, successSourceSummary,
                       "the restored V10 library must match the original source's complete semantic summary")
        let postActivationBackupVerified = try V4StoreBackupCoordinator.verify(
            successBackupManifest.storeFamilyManifest, in: successBackupRoot)
        XCTAssertTrue(postActivationBackupVerified)

        let restoredProductionStore = LibraryStoreFactory.makeDefault(storeURLOverride: restoredV10StoreURL)
        let restoredProductionSnapshot = await restoredProductionStore.snapshot()
        let restoredProductionOpenPassed = restoredProductionSnapshot.readErrorMessage == nil &&
            restoredProductionSnapshot.papers[81001]?.displayTitle == "Canonical fixture 81001" &&
            restoredProductionSnapshot.authors[91001]?.preferredName == "Canonical, Author" &&
            restoredProductionSnapshot.paperAuthorLinks.contains(PaperAuthorLink(
                paperID: 81001, authorRecid: 91001, position: 0))
        XCTAssertTrue(restoredProductionOpenPassed,
                      "the restored library must reopen through LibraryStoreFactory with its domain rows available")
        let restoredDescriptorURL = V10StoreMigrationCoordinator.descriptorURL(
            for: restoredV10StoreURL, targetSchemaVersion: 12)
        let restoredDescriptor = try JSONDecoder.latticeLens.decode(V10ActiveStoreDescriptor.self,
            from: Data(contentsOf: restoredDescriptorURL))
        XCTAssertEqual(restoredDescriptor.schemaVersion, 12)
        let restoredActiveURL = restoreTargetDirectory.appendingPathComponent(restoredDescriptor.storeName)
        let restoredProductionSummary = try Self.inspectStoreForV10Summary(at: restoredActiveURL, schemaVersion: 12)
        XCTAssertEqual(restoredDescriptor.semanticHash, restoredProductionSummary.stableIDHash)
        let restoredJournalURL = restoreTargetDirectory
            .appendingPathComponent(".latticelens-v12-migration-\(restoredDescriptor.runID.uuidString).json")
        let restoredJournal = try JSONDecoder.latticeLens.decode(V10StoreMigrationJournal.self,
            from: Data(contentsOf: restoredJournalURL))
        XCTAssertEqual(restoredJournal.phase, .activated)
        let postActivationSemanticReconciliationPassed =
            successSourceSummary.preservesDomainAndTypedRows(in: restoredProductionSummary, sourceSchemaVersion: 10) &&
            successSourceSummary.recordCounts == restoredV10Summary.recordCounts &&
            successTargetSummary.recordCounts == restoredProductionSummary.recordCounts &&
            successSourceSummary.stableIDHash == restoredV10Summary.stableIDHash &&
            restoredDescriptor.semanticHash == restoredProductionSummary.stableIDHash
        XCTAssertTrue(postActivationSemanticReconciliationPassed,
                      "V10 restore and its production V12 reactivation must preserve IDs, rows, and semantics")

        let rollbackDirectory = runRoot.appendingPathComponent("rollback", isDirectory: true)
        try fileManager.createDirectory(at: rollbackDirectory, withIntermediateDirectories: false)
        let rollbackSource = rollbackDirectory.appendingPathComponent("synthetic-v10-rollback.store")
        let rollbackSourceSummary = try seedSyntheticV10Store(at: rollbackSource, paperID: 81002)
        let rollbackSourceHashes = try v10DisposableStoreFamilyHashes(at: rollbackSource)
        let rollbackDescriptorURL = V10StoreMigrationCoordinator.descriptorURL(
            for: rollbackSource, targetSchemaVersion: 12)
        let rollbackBackupRoot = rollbackDirectory.appendingPathComponent("LatticeLens-StoreBackups", isDirectory: true)
        let schemaV12 = Schema(versionedSchema: LatticeLensSchemaV12.self)
        var rollbackSourceSnapshotDebug: Data?
        var rollbackTargetSnapshotDebug: Data?

        XCTAssertThrowsError(try V10StoreMigrationCoordinator.migrate(
            sourceURL: rollbackSource,
            descriptorURL: rollbackDescriptorURL,
            backupRoot: rollbackBackupRoot,
            crashAt: .beforeActivation,
            targetSchemaVersion: 12,
            inspectBackupCopy: { probeURL, schemaVersion in
                try Self.inspectStoreForV10Summary(at: probeURL, schemaVersion: schemaVersion)
            },
            migrateAndVerify: { stagingURL, reportProgress in
                let configuration = ModelConfiguration(schema: schemaV12, url: stagingURL)
                let staged = try ModelContainer(for: schemaV12, migrationPlan: LatticeLensMigrationPlanV12.self,
                                                configurations: configuration)
                let context = ModelContext(staged)
                guard try !context.fetch(FetchDescriptor<StoredV8StoreMarker>()).isEmpty else {
                    throw V10StoreMigrationError.semanticMismatch
                }
                try V10CategoryProfileBootstrap.migrateOrCreate(in: context)
                try reportProgress(.categoryMigrated)
                if try !V9TypedSearchIndex.isCurrent(in: context) {
                    try V9TypedSearchIndex.rebuild(in: context)
                }
                try reportProgress(.searchIndexReady)
                let targetSummary = try V10StoreSemanticSummary.make(from: context, schemaVersion: 12)
                if !rollbackSourceSummary.preservesDomainAndTypedRows(in: targetSummary, sourceSchemaVersion: 10) {
                    let sourceSchema = Schema(versionedSchema: LatticeLensSchemaV10.self)
                    let sourceContainer = try ModelContainer(for: sourceSchema,
                        configurations: ModelConfiguration(schema: sourceSchema, url: rollbackSource, allowsSave: false))
                    let encoder = JSONEncoder.latticeLens
                    encoder.outputFormatting.insert(.sortedKeys)
                    rollbackSourceSnapshotDebug = try encoder.encode(
                        V8TypedStoreCodec.snapshot(from: sourceContainer.mainContext))
                    rollbackTargetSnapshotDebug = try encoder.encode(V8TypedStoreCodec.snapshot(from: context))
                }
                return targetSummary
            })) { error in
                XCTAssertEqual(error as? V10StoreMigrationError, .injectedCrash(.beforeActivation))
            }

        if let rollbackSourceSnapshotDebug, let rollbackTargetSnapshotDebug {
            try rollbackSourceSnapshotDebug.write(to: runRoot.appendingPathComponent("rollback-source-snapshot.json"),
                                                  options: .atomic)
            try rollbackTargetSnapshotDebug.write(to: runRoot.appendingPathComponent("rollback-target-snapshot.json"),
                                                  options: .atomic)
        }

        let rollbackJournalURL = try XCTUnwrap(fileManager.contentsOfDirectory(
            at: rollbackDirectory, includingPropertiesForKeys: nil).first {
                $0.lastPathComponent.hasPrefix(".latticelens-v12-migration-") && $0.pathExtension == "json"
            })
        let verifiedJournal = try JSONDecoder.latticeLens.decode(
            V10StoreMigrationJournal.self, from: Data(contentsOf: rollbackJournalURL))
        XCTAssertEqual(verifiedJournal.phase, .verified,
                       "the injected failure must occur after semantic reconciliation")
        XCTAssertNotNil(verifiedJournal.targetSummary)
        let recoveredJournal = try V10StoreMigrationCoordinator.recover(
            journalURL: rollbackJournalURL,
            parent: rollbackDirectory,
            descriptorURL: rollbackDescriptorURL,
            backupRoot: rollbackBackupRoot,
            verifyActive: { try Self.inspectStoreForV10Summary(at: $0, schemaVersion: 12) })
        XCTAssertEqual(recoveredJournal.phase, .rolledBack)
        XCTAssertFalse(fileManager.fileExists(atPath: rollbackDescriptorURL.path),
                       "unactivated staging must never become the active library")
        let rollbackStagingURL = rollbackDirectory.appendingPathComponent(recoveredJournal.stagingStoreName)
        XCTAssertFalse(fileManager.fileExists(atPath: rollbackStagingURL.path))
        let rollbackSourceHashesAfterRecovery = try v10DisposableStoreFamilyHashes(at: rollbackSource)
        XCTAssertEqual(rollbackSourceHashesAfterRecovery, rollbackSourceHashes,
                       "measure source-family stability before opening the source for test inspection")
        XCTAssertEqual(try V10StoreSQLiteSchemaProbe.schemaVersion(at: rollbackSource), 10)
        let rollbackBackupDirectory = rollbackBackupRoot
            .appendingPathComponent(recoveredJournal.backupManifestID.uuidString, isDirectory: true)
        let rollbackBackupManifest = try JSONDecoder.latticeLens.decode(V10MigrationBackupManifest.self,
            from: Data(contentsOf: rollbackBackupDirectory.appendingPathComponent("migration-manifest.json")))
        let rollbackBackupVerified = try V4StoreBackupCoordinator.verify(
            rollbackBackupManifest.storeFamilyManifest, in: rollbackBackupRoot)
        XCTAssertTrue(rollbackBackupVerified)

        let receipt = V10DisposableMigrationDrillReceipt(
            schemaVersion: "latticelens-v10-disposable-migration-drill-v5",
            runID: runID,
            createdAtUTC: ISO8601DateFormatter().string(from: Date()),
            sourceOrigin: "synthetic_generated",
            inputManifestSHA256: inputManifestSHA256,
            successfulMigration: V10DisposableMigrationLeg(
                sourceSchemaVersion: 10,
                targetSchemaVersion: 12,
                journalPhase: successJournal.phase.rawValue,
                sourceFamilyHashes: successSourceHashes,
                sourceRecordCounts: successSourceSummary.recordCounts,
                targetRecordCounts: successTargetSummary.recordCounts,
                legacyCategoryCheckpointCount: successSourceSummary.legacyCategoryCheckpointCount,
                sourceLegacyCheckpointInvalidationCount: successSourceSummary.legacyCheckpointInvalidationCount,
                targetLegacyCheckpointInvalidationCount: successTargetSummary.legacyCheckpointInvalidationCount,
                sourceLibraryHashFormatVersion: successSourceSummary.serializedLibraryHashFormatVersion,
                targetLibraryHashFormatVersion: successTargetSummary.serializedLibraryHashFormatVersion,
                sourceStableIDHash: successSourceSummary.stableIDHash,
                targetStableIDHash: successTargetSummary.stableIDHash,
                backupManifestHash: successBackupManifest.manifestHash,
                backupVerified: successBackupVerified,
                semanticReconciliationPassed: successSourceSummary.preservesDomainAndTypedRows(
                    in: successTargetSummary, sourceSchemaVersion: 10),
                sourceFamilyUnchanged: successSourceHashesAfter == successSourceHashes,
                descriptorSchemaVersion: successDescriptor.schemaVersion,
                descriptorSemanticHash: successDescriptor.semanticHash),
            postActivationRestore: V10DisposablePostActivationRestoreLeg(
                sourceSchemaVersion: 10,
                restoredSchemaVersion: restoredSchemaVersion,
                productionSchemaVersion: restoredDescriptor.schemaVersion,
                productionMigrationPhase: restoredJournal.phase.rawValue,
                sourceRecordCounts: successSourceSummary.recordCounts,
                restoredRecordCounts: restoredV10Summary.recordCounts,
                productionRecordCounts: restoredProductionSummary.recordCounts,
                sourceLibraryHashFormatVersion: successSourceSummary.serializedLibraryHashFormatVersion,
                restoredLibraryHashFormatVersion: restoredV10Summary.serializedLibraryHashFormatVersion,
                productionLibraryHashFormatVersion: restoredProductionSummary.serializedLibraryHashFormatVersion,
                sourceStableIDHash: successSourceSummary.stableIDHash,
                restoredStableIDHash: restoredV10Summary.stableIDHash,
                productionStableIDHash: restoredProductionSummary.stableIDHash,
                productionDescriptorSemanticHash: restoredDescriptor.semanticHash,
                backupManifestHash: successBackupManifest.manifestHash,
                restoredFamilyHashes: restoredFamilyHashes,
                restoreTargetWasAbsent: restoreTargetWasAbsent,
                backupVerified: postActivationBackupVerified,
                restoredFamilyMatchesManifest: restoredFamilyMatchesManifest,
                semanticReconciliationPassed: postActivationSemanticReconciliationPassed,
                productionStoreOpenPassed: restoredProductionOpenPassed),
            rollback: V10DisposableRollbackLeg(
                sourceSchemaVersion: 10,
                targetSchemaVersion: 12,
                journalPhaseBeforeRecovery: verifiedJournal.phase.rawValue,
                recoveredJournalPhase: recoveredJournal.phase.rawValue,
                sourceFamilyHashes: rollbackSourceHashes,
                sourceLibraryHashFormatVersion: rollbackSourceSummary.serializedLibraryHashFormatVersion,
                recoveredLibraryHashFormatVersion: rollbackSourceSummary.serializedLibraryHashFormatVersion,
                sourceStableIDHash: rollbackSourceSummary.stableIDHash,
                recoveredSourceStableIDHash: rollbackSourceSummary.stableIDHash,
                backupVerified: rollbackBackupVerified,
                sourceFamilyUnchanged: rollbackSourceHashesAfterRecovery == rollbackSourceHashes,
                sourceSemanticUnchanged: rollbackSourceHashesAfterRecovery == rollbackSourceHashes &&
                    rollbackBackupManifest.semanticSummary == rollbackSourceSummary,
                activeDescriptorAbsent: !fileManager.fileExists(atPath: rollbackDescriptorURL.path),
                stagingRemoved: !fileManager.fileExists(atPath: rollbackStagingURL.path)))
        let receiptData = try JSONEncoder.latticeLens.encode(receipt)
        XCTAssertFalse(String(decoding: receiptData, as: UTF8.self).contains(outputRoot.path),
                       "the sanitized receipt must not serialize project-absolute paths")
        try receiptData.write(to: outputRoot.appendingPathComponent("migration-v10-to-v12.json"), options: .atomic)

        try await migratedStore.markRead(true, paperID: 81001, at: Date(timeIntervalSince1970: 1_750_002_000))
        let reopenedStore = LibraryStoreFactory.makeDefault(storeURLOverride: successSource)
        let reopenedSnapshot = await reopenedStore.snapshot()
        XCTAssertNil(reopenedSnapshot.readErrorMessage,
                     "an activated migration receipt must remain valid after ordinary user data changes")
        XCTAssertEqual(reopenedSnapshot.readingStates[81001]?.isRead, true)
    }

    @MainActor
    private func seedSyntheticV10Store(at url: URL, paperID: Int) throws -> V10StoreSemanticSummary {
        let schema = Schema(versionedSchema: LatticeLensSchemaV10.self)
        let snapshot = semanticFingerprintFixture(paperID: paperID, reverseSetInsertion: false)
        do {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
            let context = container.mainContext
            try V8TypedStoreCodec.materialize(snapshot, in: context, sourceSchemaVersion: 10)
            let timestamp = Date(timeIntervalSince1970: 1_750_001_000 + TimeInterval(paperID % 100))
            let profile = CategoryProfile(categories: [.hepLat, .hepTh])
            context.insert(StoredV10CategoryProfile(revision: profile.revision,
                categoriesData: try JSONEncoder.latticeLens.encode(profile.rawValues), updatedAt: timestamp))
            context.insert(StoredV10AuthorCategoryMembership(id: "synthetic-membership-\(paperID)",
                authorID: 91001, category: "hep-ph", generationID: "synthetic-generation-\(paperID)",
                isCurrent: true, updatedAt: timestamp))
            context.insert(StoredV10FormulaInventory(id: "synthetic-inventory-\(paperID)", paperID: paperID,
                documentID: "synthetic-document-\(paperID)", documentHash: "synthetic-document-hash",
                inventoryHash: "synthetic-inventory-hash", parserVersion: 2, status: "partial",
                payload: Data("synthetic inventory payload".utf8), updatedAt: timestamp))
            context.insert(StoredV10FormulaInventoryItem(id: "synthetic-item-\(paperID)", paperID: paperID,
                documentID: "synthetic-document-\(paperID)", documentHash: "synthetic-document-hash",
                inventoryHash: "synthetic-inventory-hash", equationID: "synthetic-equation-1", label: "(1)",
                ordinal: 0, sourceByteStart: 0, sourceByteEnd: 3, sourceTeXHash: StableHash.sha256("x=1"),
                anchorID: "synthetic-anchor-1", status: "numbered", payload: Data("x=1".utf8)))
            context.insert(StoredV10FormulaDerivationJob(id: "synthetic-job-\(paperID)", paperID: paperID,
                documentID: "synthetic-document-\(paperID)", documentHash: "synthetic-document-hash",
                inventoryHash: "synthetic-inventory-hash", state: "retryable", promptVersion: "synthetic-prompt",
                schemaVersion: "synthetic-schema", createdAt: timestamp, updatedAt: timestamp,
                payload: Data("synthetic job payload".utf8)))
            context.insert(StoredV10FormulaBatch(id: "synthetic-batch-\(paperID)",
                jobID: "synthetic-job-\(paperID)", ordinal: 0,
                equationIDsData: try JSONEncoder.latticeLens.encode(["synthetic-equation-1"]),
                payloadHash: StableHash.sha256("synthetic-batch"), status: "retryable", updatedAt: timestamp))
            context.insert(StoredV10FormulaBatchCheckpoint(id: "synthetic-checkpoint-\(paperID)",
                jobID: "synthetic-job-\(paperID)", inventoryHash: "synthetic-inventory-hash",
                batchIndex: 0, batchTotal: 1,
                equationIDsData: try JSONEncoder.latticeLens.encode(["synthetic-equation-1"]),
                requestID: "synthetic-request-1", attemptCount: 1,
                payloadHash: StableHash.sha256("synthetic-request-payload"), receivedBytes: 0,
                receivedCharacters: 0, firstContentAt: nil, lastContentAt: nil, status: "retryable",
                errorCategory: "synthetic_fixture", updatedAt: timestamp))
            context.insert(StoredV10FormulaDerivationStep(id: "synthetic-step-\(paperID)",
                jobID: "synthetic-job-\(paperID)", equationID: "synthetic-equation-1", ordinal: 0,
                text: "synthetic step", anchorID: "synthetic-anchor-1", status: "needs_manual"))
            context.insert(StoredV10EquationDependency(id: "synthetic-dependency-\(paperID)",
                jobID: "synthetic-job-\(paperID)", equationID: "synthetic-equation-1",
                dependsOnEquationID: "synthetic-context-equation", status: "needs_manual"))
            context.insert(StoredV10FormulaValidationReport(id: "synthetic-report-\(paperID)",
                jobID: "synthetic-job-\(paperID)", inventoryHash: "synthetic-inventory-hash",
                claimHash: StableHash.sha256("synthetic-claim"), validatorVersion: "synthetic-validator",
                status: "partial", payload: Data("synthetic report".utf8), createdAt: timestamp))
            context.insert(StoredV10AnalysisRun(id: "synthetic-run-\(paperID)", workflowKind: "formula",
                phase: "paused", providerRevision: "synthetic-provider", modelID: "synthetic-model",
                promptVersion: "synthetic-prompt", schemaVersion: "synthetic-schema",
                payloadHash: StableHash.sha256("synthetic-analysis-run"),
                sourceDocumentHashesData: try JSONEncoder.latticeLens.encode(["synthetic-document-hash"]),
                inventoryHash: "synthetic-inventory-hash", updatedAt: timestamp,
                payload: Data("synthetic analysis run".utf8)))
            context.insert(StoredV10AnalysisAttempt(id: "synthetic-attempt-\(paperID)",
                runID: "synthetic-run-\(paperID)", requestIndex: 0, batchIndex: 0,
                requestID: "synthetic-request-1", attempt: 1, status: "retryable", receivedBytes: 0,
                receivedCharacters: 0, errorCategory: "synthetic_fixture", updatedAt: timestamp))
            context.insert(StoredV10ReadingWorkflowState(paperID: paperID, state: "reading",
                selectedAnchorID: "synthetic-anchor-1", updatedAt: timestamp))
            context.insert(StoredV10SearchIndexState(indexName: "synthetic-search", version: 1,
                state: "ready", indexedRecordCount: 1, updatedAt: timestamp))
            try context.save()
            return try V10StoreSemanticSummary.make(from: context, schemaVersion: 10)
        }
    }

    private func v10DisposableStoreFamilyHashes(at storeURL: URL) throws -> [String: String] {
        var hashes = [String: String]()
        for member in [storeURL, URL(fileURLWithPath: storeURL.path + "-wal"),
                       URL(fileURLWithPath: storeURL.path + "-shm")] {
            guard FileManager.default.fileExists(atPath: member.path) else { continue }
            let values = try member.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw LatticeLensError.persistenceUnavailable("synthetic V10 SQLite family contains a non-regular or symlink member")
            }
            hashes[member.lastPathComponent] = StableHash.sha256(try Data(contentsOf: member))
        }
        guard hashes[storeURL.lastPathComponent] != nil else {
            throw LatticeLensError.persistenceUnavailable("synthetic V10 SQLite main store is missing")
        }
        return hashes
    }

    @MainActor
    private static func inspectStoreForV10Summary(at url: URL, schemaVersion: Int) throws -> V10StoreSemanticSummary {
        let schema: Schema
        switch schemaVersion {
        case 8: schema = Schema(versionedSchema: LatticeLensSchemaV8.self)
        case 9: schema = Schema(versionedSchema: LatticeLensSchemaV9.self)
        case 10: schema = Schema(versionedSchema: LatticeLensSchemaV10.self)
        case 11: schema = Schema(versionedSchema: LatticeLensSchemaV11.self)
        case 12: schema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        default: throw V10StoreMigrationError.invalidSource
        }
        let configuration = ModelConfiguration(schema: schema, url: url, allowsSave: false)
        let container = try ModelContainer(for: schema, configurations: configuration)
        return try V10StoreSemanticSummary.make(from: container.mainContext, schemaVersion: schemaVersion)
    }

    @MainActor
    func testDefaultFactoryMigratesV9ThroughV12StagingAndPreservesSourceFamily() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "factory-v9-staging")
        defer { try? FileManager.default.removeItem(at: root) }
        let baseURL = root.appendingPathComponent("LatticeLens-v8.store")
        let paper = makePaper(11)
        do {
            let schema = Schema(versionedSchema: LatticeLensSchemaV9.self)
            let source = try ModelContainer(for: schema, configurations: ModelConfiguration(url: baseURL))
            let snapshot = LibrarySnapshot(papers: [paper.literatureID: paper], schemaVersion: 9)
            try V8TypedStoreCodec.materialize(snapshot, in: source.mainContext, sourceSchemaVersion: 9)
        }
        let familySuffixes = ["", "-wal", "-shm"]
        var sourceBytes = [String: Data]()
        for suffix in familySuffixes {
            let member = URL(fileURLWithPath: baseURL.path + suffix)
            if FileManager.default.fileExists(atPath: member.path) {
                sourceBytes[suffix] = try Data(contentsOf: member)
            }
        }
        XCTAssertNotNil(sourceBytes[""])

        let store = LibraryStoreFactory.makeDefault(storeURLOverride: baseURL)
        let migratedSnapshot = await store.snapshot()
        XCTAssertEqual(migratedSnapshot.papers[paper.literatureID]?.displayTitle, paper.displayTitle)

        let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(for: baseURL, targetSchemaVersion: 12)
        let descriptor = try JSONDecoder.latticeLens.decode(V10ActiveStoreDescriptor.self, from: Data(contentsOf: descriptorURL))
        XCTAssertEqual(descriptor.schemaVersion, 12)
        XCTAssertNotEqual(descriptor.storeName, baseURL.lastPathComponent)
        for (suffix, expected) in sourceBytes {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: baseURL.path + suffix)), expected,
                           "the old V9 source family must remain byte-identical after active selection")
        }
        let activeURL = root.appendingPathComponent(descriptor.storeName)
        let activeSchema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let active = try ModelContainer(for: activeSchema, migrationPlan: LatticeLensMigrationPlanV12.self,
                                        configurations: ModelConfiguration(schema: activeSchema, url: activeURL))
        XCTAssertEqual(try active.mainContext.fetchCount(FetchDescriptor<StoredV8Paper>()), 1)
        XCTAssertEqual(try active.mainContext.fetchCount(FetchDescriptor<StoredV10CategoryProfile>()), 1)
        let activeSummary = try V10StoreSemanticSummary.make(from: active.mainContext, schemaVersion: 12)
        let journalURL = root.appendingPathComponent(".latticelens-v12-migration-\(descriptor.runID.uuidString).json")
        let journal = try JSONDecoder.latticeLens.decode(V10StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
        XCTAssertEqual(journal.targetSummary, activeSummary)
        XCTAssertTrue(journal.sourceSummary.preservesDomainAndTypedRows(in: activeSummary, sourceSchemaVersion: 9))
        let backupManifestURL = root.appendingPathComponent("LatticeLens-StoreBackups", isDirectory: true)
            .appendingPathComponent(descriptor.backupManifestID.uuidString, isDirectory: true)
            .appendingPathComponent("migration-manifest.json")
        let backupManifest = try JSONDecoder.latticeLens.decode(
            V10MigrationBackupManifest.self, from: Data(contentsOf: backupManifestURL))
        XCTAssertEqual(backupManifest.semanticSummary, journal.sourceSummary)
        XCTAssertEqual(backupManifest.recordCounts, journal.sourceSummary.recordCounts)
    }

    @MainActor
    func testLegacyV9SchemaRejectsV12StoreWithoutChangingMainOrWAL() throws {
        let root = try makeProjectLocalTestDirectory(prefix: "g02-legacy-v9-reject-v12")
        defer { try? FileManager.default.removeItem(at: root) }

        let fileManager = FileManager.default
        let storeURL = root.appendingPathComponent("swiftdata/LatticeLens-v8.store")
        try fileManager.createDirectory(at: storeURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let v12Schema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let paper = makePaper(18)
        do {
            let configuration = ModelConfiguration(schema: v12Schema, url: storeURL)
            let container = try ModelContainer(for: v12Schema,
                                               migrationPlan: LatticeLensMigrationPlanV12.self,
                                               configurations: configuration)
            try V8TypedStoreCodec.materialize(
                LibrarySnapshot(papers: [paper.literatureID: paper], schemaVersion: 8, v3SchemaVersion: 3),
                in: container.mainContext, sourceSchemaVersion: 8)
            try V9TypedSearchIndex.rebuild(in: container.mainContext)
            try container.mainContext.save()
        }

        let familySuffixes = ["", "-wal", "-shm"]
        var before = [String: Data]()
        for suffix in familySuffixes {
            let member = URL(fileURLWithPath: storeURL.path + suffix)
            if fileManager.fileExists(atPath: member.path) {
                before[suffix] = try Data(contentsOf: member)
            }
        }
        XCTAssertNotNil(before[""], "the disposable V12 store must exist at the legacy app path")

        let v9Schema = Schema(versionedSchema: LatticeLensSchemaV9.self)
        let v9Configuration = ModelConfiguration(schema: v9Schema, url: storeURL, allowsSave: false)
        XCTAssertThrowsError(try ModelContainer(for: v9Schema,
                                                migrationPlan: LatticeLensMigrationPlanV9.self,
                                                configurations: v9Configuration),
                             "the pre-2.0 V9 schema must not open the active V12 store")

        var after = [String: Data]()
        for suffix in familySuffixes {
            let member = URL(fileURLWithPath: storeURL.path + suffix)
            if fileManager.fileExists(atPath: member.path) {
                after[suffix] = try Data(contentsOf: member)
            }
        }
        for suffix in ["", "-wal"] {
            XCTAssertEqual(after[suffix], before[suffix],
                           "a refused legacy open must leave the persistent SQLite member \(suffix) unchanged")
        }
        let changedSHM = before["-shm"] != after["-shm"]
        print("G02_LEGACY_V9_REFUSAL main_sha256=\(before[""] .map(StableHash.sha256) ?? "absent") " +
              "wal_sha256=\(before["-wal"].map(StableHash.sha256) ?? "absent") " +
              "shm_before=\(before["-shm"].map(StableHash.sha256) ?? "absent") " +
              "shm_after=\(after["-shm"].map(StableHash.sha256) ?? "absent") shm_changed=\(changedSHM)")

        let reopenedConfiguration = ModelConfiguration(schema: v12Schema, url: storeURL, allowsSave: false)
        let reopened = try ModelContainer(for: v12Schema,
                                          migrationPlan: LatticeLensMigrationPlanV12.self,
                                          configurations: reopenedConfiguration)
        let papers = try reopened.mainContext.fetch(FetchDescriptor<StoredV8Paper>())
        XCTAssertEqual(papers.map(\.literatureID), [paper.literatureID],
                       "the active V12 schema must still read the synthetic row after refusal")
    }

    @MainActor
    func testDefaultFactoryMigratesV8ThroughStagingToV12AndPreservesSourceFamily() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "factory-v8-staging")
        defer { try? FileManager.default.removeItem(at: root) }
        let baseURL = root.appending(path: "swiftdata/LatticeLens-v8.store")
        try FileManager.default.createDirectory(at: baseURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let paper = makePaper(17)
        let checkpoint = SyncCheckpoint(jobID: "author-candidates:hep-lat-or-hep-th",
            jobKind: "author-candidates", query: "arxiv_categories:hep-lat OR arxiv_categories:hep-th",
            generationID: "legacy-v8-category-generation",
            activeMembership: Set([17, 18, 19]), stagingMembership: Set([20, 21]))
        let schema = Schema(versionedSchema: LatticeLensSchemaV8.self)
        let source = try ModelContainer(for: schema, configurations: ModelConfiguration(url: baseURL))
        try V8TypedStoreCodec.materialize(
            LibrarySnapshot(papers: [paper.literatureID: paper],
                            checkpoints: [checkpoint.id: checkpoint], schemaVersion: 8),
            in: source.mainContext, sourceSchemaVersion: 8)
        try source.mainContext.save()
        let sourceBytes = try Data(contentsOf: baseURL)

        let store = LibraryStoreFactory.makeDefault(environment: [
            "LATTICELENS_ALLOW_PRODUCTION_ISOLATION": "1",
            "LATTICELENS_PRODUCTION_STORE_ROOT": root.path,
        ])
        let migrated = await store.snapshot()
        XCTAssertFalse(store is V8MigrationBlockedStore)
        XCTAssertEqual(migrated.papers[paper.literatureID]?.displayTitle, paper.displayTitle)
        XCTAssertEqual(try Data(contentsOf: baseURL), sourceBytes,
                       "the V8 source file must remain byte-identical after staged activation")

        let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(for: baseURL, targetSchemaVersion: 12)
        let descriptor = try JSONDecoder.latticeLens.decode(
            V10ActiveStoreDescriptor.self, from: Data(contentsOf: descriptorURL))
        XCTAssertEqual(descriptor.schemaVersion, 12)
        let journalURL = baseURL.deletingLastPathComponent().appendingPathComponent(
            ".latticelens-v12-migration-\(descriptor.runID.uuidString).json")
        let journal = try JSONDecoder.latticeLens.decode(
            V10StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
        XCTAssertEqual(journal.sourceSchemaVersion, 8)
        XCTAssertEqual(journal.targetSchemaVersion, 12)
        let activeURL = baseURL.deletingLastPathComponent().appendingPathComponent(descriptor.storeName)
        let activeSchema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let active = try ModelContainer(for: activeSchema, migrationPlan: LatticeLensMigrationPlanV12.self,
            configurations: ModelConfiguration(schema: activeSchema, url: activeURL))
        let profile = try XCTUnwrap(active.mainContext.fetch(FetchDescriptor<StoredV10CategoryProfile>()).first)
        XCTAssertEqual(try JSONDecoder.latticeLens.decode([String].self, from: profile.categoriesData),
                       ["hep-lat", "hep-th"])
        let invalidation = try XCTUnwrap(active.mainContext.fetch(FetchDescriptor<StoredV10SearchIndexState>())
            .first { $0.indexName == "legacy-author-category-checkpoints" })
        XCTAssertEqual(invalidation.state, "invalidated_by_query_revision")
        XCTAssertEqual(invalidation.indexedRecordCount, 1)
        let activeSummary = try V10StoreSemanticSummary.make(from: active.mainContext, schemaVersion: 12)
        XCTAssertTrue(journal.sourceSummary.preservesDomainAndTypedRows(
            in: activeSummary, sourceSchemaVersion: 8))
    }

    #if SWIFT_PACKAGE
    @MainActor
    func testLegacyV9SchemaOpensThePreserved1011StoreFixture() throws {
        let root = try makeProjectLocalTestDirectory(prefix: "legacy-v9-schema-compatibility")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appending(path: "swiftdata/LatticeLens-v8.store")
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try copyLegacyV9StoreFixture(to: storeURL)

        let schema = Schema(versionedSchema: LatticeLensSchemaV9.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: storeURL))
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: storeURL, options: nil)
        let hashes = try XCTUnwrap(metadata["NSStoreModelVersionHashes"] as? [String: Data])
        let fullTextHash = try XCTUnwrap(hashes["StoredV8FullTextDocument"])
        XCTAssertEqual(fullTextHash.map { String(format: "%02x", $0) }.joined(),
                       "3274a16d14e9093b44cb490e237fc8e12f7a0f0ac8ffbf7e3831d937019f8cfc",
                       "V9 must retain the exact 1.0.11 entity hash; later inventory metadata belongs in typed V10 rows")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredV8StoreMarker>()), 1)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredV8SearchIndexState>()), 1)
    }
    #endif

    @MainActor
    func testDefaultFactoryMigratesV9ThroughStagingToV12AndPreservesSourceFamily() async throws {
        let rollbackFixturePath = ProcessInfo.processInfo.environment[
            "LATTICELENS_G02_OLD_APP_ROLLBACK_FIXTURE_ROOT"]
        let root = try makeProjectLocalTestDirectory(
            prefix: "factory-v9-staging", explicitRoot: rollbackFixturePath)
        defer {
            if rollbackFixturePath == nil { try? FileManager.default.removeItem(at: root) }
        }
        let baseURL = root.appending(path: "swiftdata/LatticeLens-v8.store")
        try FileManager.default.createDirectory(at: baseURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        #if SWIFT_PACKAGE
        if rollbackFixturePath != nil {
            try copyLegacyV9StoreFixture(to: baseURL)
        }
        #endif
        var paper = makePaper(18)
        paper.titles = [PaperTitle(value: "G02 Old-App Rollback Fixture Paper 18", source: "fixture")]
        let author = Author(recid: ProductContract.selfAuthorRecid, preferredName: "G02 Fixture, Author",
                            nativeNames: [], bai: nil, arxivCategories: ["hep-lat"], hIndex: nil,
                            hIndexState: .unknown, isTracked: true, lastSyncedAt: Date(timeIntervalSince1970: 18))
        let authorLink = PaperAuthorLink(paperID: paper.literatureID, authorRecid: author.recid, position: 0)
        do {
            let schema = Schema(versionedSchema: LatticeLensSchemaV9.self)
            let source = try ModelContainer(for: schema, configurations: ModelConfiguration(url: baseURL))
            try V8TypedStoreCodec.materialize(
                LibrarySnapshot(authors: [author.recid: author], papers: [paper.literatureID: paper],
                                paperAuthorLinks: [authorLink], schemaVersion: 9),
                in: source.mainContext, sourceSchemaVersion: 9)
        }
        let familySuffixes = ["", "-wal", "-shm"]
        var sourceBytes = [String: Data]()
        for suffix in familySuffixes {
            let member = URL(fileURLWithPath: baseURL.path + suffix)
            if FileManager.default.fileExists(atPath: member.path) {
                sourceBytes[suffix] = try Data(contentsOf: member)
            }
        }
        XCTAssertNotNil(sourceBytes[""])
        let isolationEnvironment = [
            "LATTICELENS_ALLOW_PRODUCTION_ISOLATION": "1",
            "LATTICELENS_PRODUCTION_STORE_ROOT": root.path
        ]
        XCTAssertEqual(LibraryStoreFactory.productionIsolationDefaultStoreURL(isolationRoot: root), baseURL,
                       "an existing compatible V9 source must remain the 2.0 migration base")
        let store = LibraryStoreFactory.makeDefault(environment: isolationEnvironment)
        let migratedSnapshot = await store.snapshot()
        XCTAssertEqual(migratedSnapshot.papers[paper.literatureID]?.displayTitle, paper.displayTitle)

        let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(for: baseURL, targetSchemaVersion: 12)
        let descriptor = try JSONDecoder.latticeLens.decode(
            V10ActiveStoreDescriptor.self, from: Data(contentsOf: descriptorURL))
        XCTAssertEqual(descriptor.schemaVersion, 12)
        XCTAssertNotEqual(descriptor.storeName, baseURL.lastPathComponent)
        for (suffix, expected) in sourceBytes {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: baseURL.path + suffix)), expected,
                           "the pre-upgrade V9 source family must remain byte-identical")
        }

        let activeURL = baseURL.deletingLastPathComponent().appendingPathComponent(descriptor.storeName)
        let activeSchema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let active = try ModelContainer(for: activeSchema, migrationPlan: LatticeLensMigrationPlanV12.self,
                                        configurations: ModelConfiguration(schema: activeSchema, url: activeURL))
        XCTAssertEqual(try active.mainContext.fetchCount(FetchDescriptor<StoredV8Paper>()), 1)
        let profile = try XCTUnwrap(active.mainContext.fetch(FetchDescriptor<StoredV10CategoryProfile>()).first)
        let expectedCategories = CategoryProfile().rawValues
        XCTAssertEqual(try JSONDecoder.latticeLens.decode([String].self, from: profile.categoriesData),
                       expectedCategories)

        let journalURL = baseURL.deletingLastPathComponent().appendingPathComponent(
            ".latticelens-v12-migration-\(descriptor.runID.uuidString).json")
        let journal = try JSONDecoder.latticeLens.decode(
            V10StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
        XCTAssertEqual(journal.sourceSchemaVersion, 9)
        XCTAssertEqual(journal.targetSchemaVersion, 12)
        let activeSummary = try V10StoreSemanticSummary.make(from: active.mainContext, schemaVersion: 12)
        XCTAssertEqual(journal.targetSummary, activeSummary)
        XCTAssertTrue(journal.sourceSummary.preservesDomainAndTypedRows(
            in: activeSummary, sourceSchemaVersion: 9))
        XCTAssertEqual(activeSummary.typedRowCounts["categoryProfiles"], 1)

        let backupRoot = baseURL.deletingLastPathComponent()
            .appendingPathComponent("LatticeLens-StoreBackups", isDirectory: true)
        let backupManifestURL = backupRoot
            .appendingPathComponent(descriptor.backupManifestID.uuidString, isDirectory: true)
            .appendingPathComponent("migration-manifest.json")
        let backupManifest = try JSONDecoder.latticeLens.decode(
            V10MigrationBackupManifest.self, from: Data(contentsOf: backupManifestURL))
        XCTAssertEqual(backupManifest.sourceSchemaVersion, 9)
        XCTAssertEqual(backupManifest.semanticSummary, journal.sourceSummary)
        XCTAssertTrue(try V4StoreBackupCoordinator.verify(backupManifest.storeFamilyManifest, in: backupRoot))

        if rollbackFixturePath != nil {
            let rollbackRoot = root.appendingPathComponent("old-app-rollback", isDirectory: true)
            let rollbackStoreDirectory = rollbackRoot.appendingPathComponent("swiftdata", isDirectory: true)
            try V4StoreBackupCoordinator.restore(backupManifest.storeFamilyManifest,
                                                 from: backupRoot, to: rollbackStoreDirectory)

            var v12Family: [(String, String)] = []
            for suffix in familySuffixes {
                let source = URL(fileURLWithPath: activeURL.path + suffix)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let data = try Data(contentsOf: source)
                v12Family.append((suffix, StableHash.sha256(data)))
            }
            XCTAssertFalse(v12Family.isEmpty, "the verified V12 activation must have a SQLite main file")
            for (suffix, _) in v12Family {
                let source = URL(fileURLWithPath: activeURL.path + suffix)
                let destination = URL(fileURLWithPath: rollbackStoreDirectory
                    .appendingPathComponent(descriptor.storeName).path + suffix)
                try FileManager.default.copyItem(at: source, to: destination)
            }
            let descriptorTarget = rollbackStoreDirectory.appendingPathComponent(descriptorURL.lastPathComponent)
            try FileManager.default.copyItem(at: descriptorURL, to: descriptorTarget)
            let journalTarget = rollbackStoreDirectory.appendingPathComponent(journalURL.lastPathComponent)
            try FileManager.default.copyItem(at: journalURL, to: journalTarget)
            try FileManager.default.copyItem(at: backupRoot,
                to: rollbackStoreDirectory.appendingPathComponent(backupRoot.lastPathComponent,
                                                                  isDirectory: true))

            let restoredV9URL = rollbackStoreDirectory.appendingPathComponent(baseURL.lastPathComponent)
            let restoredSchema = Schema(versionedSchema: LatticeLensSchemaV9.self)
            let restoredPaperCount = try autoreleasepool {
                let restoredV9 = try ModelContainer(for: restoredSchema,
                    configurations: ModelConfiguration(schema: restoredSchema, url: restoredV9URL))
                return try restoredV9.mainContext.fetchCount(FetchDescriptor<StoredV8Paper>())
            }
            XCTAssertEqual(restoredPaperCount, 1,
                           "the verified pre-upgrade backup must restore to a V9-compatible target")

            let rollbackStore = LibraryStoreFactory.makeDefault(environment: [
                "LATTICELENS_ALLOW_PRODUCTION_ISOLATION": "1",
                "LATTICELENS_PRODUCTION_STORE_ROOT": rollbackRoot.path
            ])
            let rollbackSnapshot = await rollbackStore.snapshot()
            XCTAssertEqual(rollbackSnapshot.papers[paper.literatureID]?.displayTitle, paper.displayTitle,
                           "the copied V12 active descriptor must remain readable beside the V9 rollback target")

            var v12HashesAfterRestore: [String: String] = [:]
            for (suffix, _) in v12Family {
                let data = try Data(contentsOf: URL(fileURLWithPath:
                    rollbackStoreDirectory.appendingPathComponent(descriptor.storeName).path + suffix))
                v12HashesAfterRestore[suffix.isEmpty ? "main" : String(suffix.dropFirst())] = StableHash.sha256(data)
            }
            let backupEntries = backupManifest.storeFamilyManifest.files.map { file in
                ["relative_path": file.relativePath,
                 "byte_count": file.byteCount,
                 "sha256": file.sha256] as [String: Any]
            }
            let fixtureReceipt: [String: Any] = [
                "schema_version": "latticelens-g02-old-app-rollback-fixture-v1",
                "input_manifest_sha256": ProcessInfo.processInfo.environment[
                    "LATTICELENS_G02_INPUT_MANIFEST_SHA256"] ?? "",
                "source_schema_version": 9,
                "target_schema_version": 12,
                "paper_id": paper.literatureID,
                "paper_title": paper.displayTitle,
                "author_recid": author.recid,
                "rollback_root_relative": "old-app-rollback",
                "legacy_store_relative": "old-app-rollback/swiftdata/\(baseURL.lastPathComponent)",
                "active_v12_store_relative": "old-app-rollback/swiftdata/\(descriptor.storeName)",
                "active_v12_descriptor_relative": "old-app-rollback/swiftdata/\(descriptorURL.lastPathComponent)",
                "backup_root_relative": "old-app-rollback/swiftdata/\(backupRoot.lastPathComponent)",
                "backup_id": descriptor.backupManifestID.uuidString,
                "backup_entries": backupEntries,
                "active_v12_family_sha256": v12HashesAfterRestore,
                "active_v12_schema_version": descriptor.schemaVersion,
                "source_family_unchanged": true,
                "backup_verified": try V4StoreBackupCoordinator.verify(
                    backupManifest.storeFamilyManifest,
                    in: rollbackStoreDirectory.appendingPathComponent(backupRoot.lastPathComponent,
                                                                       isDirectory: true))
            ]
            let receiptData = try JSONSerialization.data(withJSONObject: fixtureReceipt,
                                                          options: [.sortedKeys])
            try receiptData.write(to: root.appendingPathComponent("old-app-rollback-fixture.json"),
                                  options: .atomic)
        }
    }

    @MainActor
    func testV10MigrationInvalidSchemaAndBackupFailureFailClosed() throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-invalid-source")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Library-v9.store")
        let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(for: sourceURL)
        let sourceBytes = Data("not-a-sqlite-store".utf8)
        try sourceBytes.write(to: sourceURL, options: .atomic)
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try Data("not-a-directory".utf8).write(to: backupRoot, options: .atomic)
        let summary = legacySemanticSummary(counts: ["papers": 0], stableIDHash: "empty")

        XCTAssertThrowsError(try V10StoreMigrationCoordinator.migrate(
            sourceURL: sourceURL,
            descriptorURL: descriptorURL,
            backupRoot: backupRoot,
            readBackupSchemaVersion: { _ in 9 },
            inspectBackupCopy: { _, _ in summary }
        ) { _, _ in stagedSemanticSummary(preserving: summary) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: descriptorURL.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)

        try FileManager.default.removeItem(at: backupRoot)
        let invalidStore = LibraryStoreFactory.makeDefault(storeURLOverride: sourceURL)
        XCTAssertTrue(invalidStore is V8MigrationBlockedStore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: descriptorURL.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
    }

    func testV10MigrationJournalDecodesLegacyV8SummaryAndFormulaPhase() throws {
        struct LegacyJournalPayload: Encodable {
            let id: UUID
            let sourceStoreName: String
            let stagingStoreName: String
            let descriptorName: String
            let sourceSchemaVersion: Int
            let targetSchemaVersion: Int
            let backupManifestID: UUID
            let backupManifestHash: String
            let sourceSummary: V8StoreSemanticSummary
            let startedAt: Date
            let updatedAt: Date
            let completedAt: Date?
            let phase: String
            let targetSummary: V8StoreSemanticSummary?
            let errorCategory: String?
        }
        let legacy = V8StoreSemanticSummary(counts: ["papers": 3], stableIDHash: "legacy-domain-hash")
        let id = UUID()
        let payload = LegacyJournalPayload(id: id, sourceStoreName: "Library.store",
            stagingStoreName: ".latticelens-v10-stage-\(id.uuidString).store",
            descriptorName: ".Library.store.active.json", sourceSchemaVersion: 9, targetSchemaVersion: 10,
            backupManifestID: UUID(), backupManifestHash: "legacy-manifest-hash", sourceSummary: legacy,
            startedAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
            completedAt: nil, phase: "formulaIndexBuilt", targetSummary: legacy, errorCategory: nil)
        let data = try JSONEncoder.latticeLens.encode(payload)
        let journal = try JSONDecoder.latticeLens.decode(V10StoreMigrationJournal.self, from: data)
        XCTAssertEqual(journal.semanticFormatVersion, 1)
        XCTAssertEqual(journal.legacySourceSummary, legacy)
        XCTAssertEqual(journal.legacyTargetSummary, legacy)
        XCTAssertEqual(journal.sourceSummary.domainSummary, legacy)
        XCTAssertEqual(journal.phase, .legacyFormulaIndexBuilt)
    }

    @MainActor
    func testV10RecoveryUpgradesLegacyV8DescriptorAfterVerifyingActiveStore() async throws {
        struct LegacyManifestHashPayload: Encodable {
            let id: UUID
            let sourceSchemaVersion: Int
            let targetSchemaVersion: Int
            let createdAt: Date
            let recordCounts: [String: Int]
            let stableIDHash: String
            let storeFamilyManifest: V4StoreBackupManifest
        }
        struct LegacyManifest: Encodable {
            let id: UUID
            let sourceSchemaVersion: Int
            let targetSchemaVersion: Int
            let createdAt: Date
            let recordCounts: [String: Int]
            let stableIDHash: String
            let storeFamilyManifest: V4StoreBackupManifest
            let manifestHash: String
        }
        struct LegacyJournal: Encodable {
            let id: UUID
            let sourceStoreName: String
            let stagingStoreName: String
            let descriptorName: String
            let sourceSchemaVersion: Int
            let targetSchemaVersion: Int
            let backupManifestID: UUID
            let backupManifestHash: String
            let sourceSummary: V8StoreSemanticSummary
            let startedAt: Date
            let updatedAt: Date
            let completedAt: Date?
            let phase: String
            let targetSummary: V8StoreSemanticSummary?
            let errorCategory: String?
        }

        let root = try makeProjectLocalTestDirectory(prefix: "v10-legacy-journal-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Library-v9.store")
        do {
            let source = try ModelContainer(for: Schema(versionedSchema: LatticeLensSchemaV9.self),
                configurations: ModelConfiguration(url: sourceURL))
            try V8TypedStoreCodec.materialize(LibrarySnapshot(papers: [41: makePaper(41)], schemaVersion: 9),
                in: source.mainContext, sourceSchemaVersion: 9)
        }
        let store = LibraryStoreFactory.makeDefault(storeURLOverride: sourceURL)
        _ = await store.snapshot()
        let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(for: sourceURL, targetSchemaVersion: 12)
        var descriptor = try JSONDecoder.latticeLens.decode(V10ActiveStoreDescriptor.self,
            from: Data(contentsOf: descriptorURL))
        let journalURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".latticelens-v12-migration-") })
        let currentJournal = try JSONDecoder.latticeLens.decode(V10StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
        let sourceSummary = currentJournal.sourceSummary.domainSummary
        let targetSummary = try XCTUnwrap(currentJournal.targetSummary).domainSummary
        let backupDirectory = root.appendingPathComponent("LatticeLens-StoreBackups", isDirectory: true)
            .appendingPathComponent(currentJournal.backupManifestID.uuidString, isDirectory: true)
        let familyManifest = try JSONDecoder.latticeLens.decode(V4StoreBackupManifest.self,
            from: Data(contentsOf: backupDirectory.appendingPathComponent("manifest.json")))
        let createdAt = currentJournal.startedAt
        let oldPayload = LegacyManifestHashPayload(id: currentJournal.backupManifestID,
            sourceSchemaVersion: currentJournal.sourceSchemaVersion, targetSchemaVersion: currentJournal.targetSchemaVersion,
            createdAt: createdAt, recordCounts: sourceSummary.counts, stableIDHash: sourceSummary.stableIDHash,
            storeFamilyManifest: familyManifest)
        let oldManifestHash = StableHash.sha256(try JSONEncoder.latticeLens.encode(oldPayload))
        let oldManifest = LegacyManifest(id: currentJournal.backupManifestID,
            sourceSchemaVersion: currentJournal.sourceSchemaVersion, targetSchemaVersion: currentJournal.targetSchemaVersion,
            createdAt: createdAt, recordCounts: sourceSummary.counts, stableIDHash: sourceSummary.stableIDHash,
            storeFamilyManifest: familyManifest, manifestHash: oldManifestHash)
        try JSONEncoder.latticeLens.encode(oldManifest)
            .write(to: backupDirectory.appendingPathComponent("migration-manifest.json"), options: .atomic)

        descriptor = V10ActiveStoreDescriptor(runID: descriptor.runID, storeName: descriptor.storeName,
            schemaVersion: descriptor.schemaVersion, backupManifestID: descriptor.backupManifestID,
            backupManifestHash: oldManifestHash, semanticHash: targetSummary.stableIDHash,
            activatedAt: descriptor.activatedAt)
        try JSONEncoder.latticeLens.encode(descriptor).write(to: descriptorURL, options: .atomic)
        let oldJournal = LegacyJournal(id: currentJournal.id, sourceStoreName: currentJournal.sourceStoreName,
            stagingStoreName: currentJournal.stagingStoreName, descriptorName: currentJournal.descriptorName,
            sourceSchemaVersion: currentJournal.sourceSchemaVersion, targetSchemaVersion: currentJournal.targetSchemaVersion,
            backupManifestID: currentJournal.backupManifestID, backupManifestHash: oldManifestHash,
            sourceSummary: sourceSummary, startedAt: currentJournal.startedAt, updatedAt: currentJournal.updatedAt,
            completedAt: nil, phase: "verified", targetSummary: targetSummary, errorCategory: nil)
        try JSONEncoder.latticeLens.encode(oldJournal).write(to: journalURL, options: .atomic)

        let activeURL = root.appendingPathComponent(descriptor.storeName)
        let recovered = try V10StoreMigrationCoordinator.recover(journalURL: journalURL, parent: root,
            descriptorURL: descriptorURL,
            backupRoot: root.appendingPathComponent("LatticeLens-StoreBackups", isDirectory: true),
            verifyActive: { try Self.inspectStoreForV10Summary(at: $0, schemaVersion: 12) })
        let upgradedDescriptor = try JSONDecoder.latticeLens.decode(V10ActiveStoreDescriptor.self,
            from: Data(contentsOf: descriptorURL))
        let activeSummary = try Self.inspectStoreForV10Summary(at: activeURL, schemaVersion: 12)
        XCTAssertEqual(recovered.phase, .activated)
        XCTAssertEqual(recovered.semanticFormatVersion, 1)
        XCTAssertEqual(upgradedDescriptor.semanticHash, activeSummary.stableIDHash)
    }

    @MainActor
    func testV10BackupRefusesSymlinkedSQLiteSidecar() throws {
        for suffix in ["-wal", "-shm"] {
            let root = try makeProjectLocalTestDirectory(prefix: "v10-sidecar-symlink\(suffix)")
            defer { try? FileManager.default.removeItem(at: root) }
            let sourceURL = root.appendingPathComponent("Library-v9.store")
            let sidecarURL = URL(fileURLWithPath: sourceURL.path + suffix)
            let sentinelURL = root.appendingPathComponent("unrelated-sentinel.txt")
            let originalSource = Data("synthetic-sqlite-main".utf8)
            let sentinel = Data("must-not-be-followed-\(suffix)".utf8)
            try originalSource.write(to: sourceURL, options: .atomic)
            try sentinel.write(to: sentinelURL, options: .atomic)
            try FileManager.default.createSymbolicLink(at: sidecarURL, withDestinationURL: sentinelURL)
            let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(for: sourceURL)
            let backupRoot = root.appendingPathComponent("backups", isDirectory: true)

            XCTAssertThrowsError(try V10StoreMigrationCoordinator.migrate(
                sourceURL: sourceURL,
                descriptorURL: descriptorURL,
                backupRoot: backupRoot,
                inspectBackupCopy: { _, _ in legacySemanticSummary(counts: [:], stableIDHash: "unused") }
            ) { _, _ in stagedSemanticSummary(preserving: legacySemanticSummary(counts: [:], stableIDHash: "unused")) })
            XCTAssertFalse(FileManager.default.fileExists(atPath: descriptorURL.path))
            XCTAssertEqual(try Data(contentsOf: sourceURL), originalSource)
            XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
            XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path),
                          "the migration must reject rather than follow the (suffix) sidecar symlink")
        }
    }

    @MainActor
    func testV10MigrationRejectsDuplicateFormulaEquationIdentityBeforeActivation() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-duplicate-formula-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Library-v10.store")
        let schema = Schema(versionedSchema: LatticeLensSchemaV10.self)
        var sourceContainer: ModelContainer?
        do {
            let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV10.self,
                configurations: ModelConfiguration(schema: schema, url: sourceURL))
            sourceContainer = container
            try V8TypedStoreCodec.materialize(LibrarySnapshot(schemaVersion: 8, v3SchemaVersion: 3),
                in: container.mainContext, sourceSchemaVersion: 8)
            let item = FormulaInventoryItem(equationID: "eq-duplicate", label: "(1)", sourceTeX: "x=1",
                ordinal: 1, documentHash: "duplicate-id-document")
            let inventory = FormulaInventory(documentHash: item.documentHash, items: [item])
            try await V10FormulaInventoryStore(modelContainer: container).saveFormulaInventory(inventory, paperID: 42)

            let stored = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<StoredV10FormulaInventoryItem>())
                .first { $0.equationID == item.equationID })
            container.mainContext.insert(StoredV10FormulaInventoryItem(
                id: "corrupt-second-row-for-same-equation",
                paperID: stored.paperID,
                documentID: stored.documentID,
                documentHash: stored.documentHash,
                inventoryHash: stored.inventoryHash,
                equationID: stored.equationID,
                label: stored.label,
                ordinal: stored.ordinal,
                sourceByteStart: stored.sourceByteStart,
                sourceByteEnd: stored.sourceByteEnd,
                sourceTeXHash: stored.sourceTeXHash,
                anchorID: stored.anchorID,
                status: stored.status,
                payload: stored.payload))
            try container.mainContext.save()
        }

        // Finish the disposable SwiftData owner's teardown before taking the
        // byte-level baseline. Its final WAL checkpoint must not race the
        // migration whose source-family immutability this test is checking.
        XCTAssertNotNil(sourceContainer, "the fixture owner must remain alive through the final save")
        sourceContainer = nil
        XCTAssertNil(sourceContainer, "release the fixture owner before hashing the source family")
        autoreleasepool {}

        let sourceHashes = try v10DisposableStoreFamilyHashes(at: sourceURL)
        let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(for: sourceURL)
        do {
            _ = try V10StoreMigrationCoordinator.migrate(
                sourceURL: sourceURL,
                descriptorURL: descriptorURL,
                backupRoot: root.appendingPathComponent("backups", isDirectory: true),
                readBackupSchemaVersion: { _ in 10 },
                inspectBackupCopy: { copyURL, version in
                    try Self.inspectStoreForV10Summary(at: copyURL, schemaVersion: version)
                }
            ) { _, _ in
                XCTFail("migration must reject duplicate logical formula IDs before staging")
                throw V10StoreMigrationError.invalidSource
            }
            XCTFail("a duplicate logical equation identity must block migration")
        } catch let error as V10StoreMigrationError {
            XCTAssertEqual(error, .semanticMismatch)
        } catch {
            XCTFail("unexpected migration error: \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: descriptorURL.path),
                       "corrupt source rows must never be published as the active 2.0 store")
        XCTAssertEqual(try v10DisposableStoreFamilyHashes(at: sourceURL), sourceHashes,
                       "inspection and rejected migration must leave the source SQLite family byte-stable")
    }

    @MainActor
    func testV10FormulaInventoryProductionFullTextPathPersistsTypedRows() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-formula-inventory-production")
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema(versionedSchema: LatticeLensSchemaV10.self)
        let storeURL = root.appendingPathComponent("Library-v10.store")
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV10.self,
                                           configurations: ModelConfiguration(schema: schema, url: storeURL))
        try V8TypedStoreCodec.materialize(LibrarySnapshot(schemaVersion: 8, v3SchemaVersion: 3),
                                          in: container.mainContext, sourceSchemaVersion: 8)
        let store = V8TypedLibraryStore(modelContainer: container)
        let service = FullTextService(store: store,
            cacheDirectory: root.appendingPathComponent("fulltext-cache", isDirectory: true),
            downloader: AppFixtureFullTextDownloader())
        let source = try XCTUnwrap(URL(string: "https://ar5iv.labs.arxiv.org/html/2509.09367"))

        let document = try await service.downloadAndExtract(paperID: 2_509_093_67, sourceURL: source, sourceKind: .arxivHTML)

        XCTAssertEqual(document.numberedEquationIndexComplete, true)
        let inventories = try container.mainContext.fetch(FetchDescriptor<StoredV10FormulaInventory>())
        XCTAssertEqual(inventories.count, 1, "the production HTML extraction must persist its typed inventory")
        let stored = try XCTUnwrap(inventories.first)
        XCTAssertEqual(stored.documentID, document.id)
        XCTAssertEqual(stored.documentHash, document.sha256)
        XCTAssertEqual(stored.inventoryHash, document.numberedEquationInventoryHash)
        XCTAssertEqual(stored.status, "complete")
        let inventory = try JSONDecoder.latticeLens.decode(FormulaInventory.self, from: stored.payload)
        XCTAssertEqual(inventory.labels, ["(1)", "(2.3)", "(A.1)"])
        let items = try container.mainContext.fetch(FetchDescriptor<StoredV10FormulaInventoryItem>())
            .sorted { $0.ordinal < $1.ordinal }
        XCTAssertEqual(items.count, inventory.items.count)
        XCTAssertEqual(items.map(\.equationID), inventory.items.map(\.equationID))
        XCTAssertEqual(items.map(\.sourceTeXHash), inventory.items.map(\.normalizedTeXHash))
        XCTAssertTrue(items.allSatisfy { $0.paperID == document.paperID && $0.documentHash == document.sha256 })

        let roundTripped = try await store.formulaInventory(paperID: document.paperID,
                                                            documentHash: document.sha256)
        XCTAssertEqual(roundTripped, inventory, "the production repository must read back the exact source-bound inventory")
        let originalUpdatedAt = stored.updatedAt
        try await store.saveFormulaInventory(inventory, paperID: document.paperID)
        let upsertedHeaders = try container.mainContext.fetch(FetchDescriptor<StoredV10FormulaInventory>())
        XCTAssertEqual(upsertedHeaders.count, 1, "replaying the same extraction must not add a duplicate header")
        XCTAssertEqual(upsertedHeaders.first?.updatedAt, originalUpdatedAt,
                       "an identical inventory upsert must not look like a content mutation")
    }

    @MainActor
    func testV10FormulaInventoryReadRejectsTamperingAndKeepsIncompleteState() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-formula-inventory-integrity")
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema(versionedSchema: LatticeLensSchemaV10.self)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV10.self,
                                           configurations: ModelConfiguration(schema: schema,
                                               url: root.appendingPathComponent("Library-v10.store")))
        try V8TypedStoreCodec.materialize(LibrarySnapshot(schemaVersion: 8, v3SchemaVersion: 3),
                                          in: container.mainContext, sourceSchemaVersion: 8)
        let repository = V10FormulaInventoryStore(modelContainer: container)
        let first = FormulaInventoryItem(equationID: "eq-1", label: "(1)", sourceTeX: "x=1",
                                         ordinal: 1, documentHash: "doc-hash")
        let second = FormulaInventoryItem(equationID: "eq-2", label: "(2)", sourceTeX: "y=2",
                                          ordinal: 2, documentHash: "doc-hash")
        let inventory = FormulaInventory(documentHash: "doc-hash", items: [first, second])
        try await repository.saveFormulaInventory(inventory, paperID: 42)

        let header = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<StoredV10FormulaInventory>())
            .first { $0.documentHash == "doc-hash" })
        header.inventoryHash = "tampered-header-hash"
        try container.mainContext.save()
        do {
            _ = try await V10FormulaInventoryStore(modelContainer: container)
                .formulaInventory(paperID: 42, documentHash: "doc-hash")
            XCTFail("a header/hash mismatch must be rejected")
        } catch { }

        header.inventoryHash = inventory.inventoryHash
        try container.mainContext.save()
        let itemRows = try container.mainContext.fetch(FetchDescriptor<StoredV10FormulaInventoryItem>())
            .filter { $0.documentHash == "doc-hash" }
        let secondRow = try XCTUnwrap(itemRows.first { $0.equationID == "eq-2" })
        secondRow.equationID = "eq-1"
        try container.mainContext.save()
        do {
            _ = try await V10FormulaInventoryStore(modelContainer: container)
                .formulaInventory(paperID: 42, documentHash: "doc-hash")
            XCTFail("duplicate equation IDs in typed rows must fail closed")
        } catch { }
        do {
            try await V10FormulaInventoryStore(modelContainer: container)
                .saveFormulaInventory(inventory, paperID: 42)
            XCTFail("upsert must report duplicate typed rows instead of trapping while constructing its row map")
        } catch { }

        secondRow.equationID = "eq-2"
        secondRow.label = "tampered label"
        try container.mainContext.save()
        do {
            _ = try await V10FormulaInventoryStore(modelContainer: container)
                .formulaInventory(paperID: 42, documentHash: "doc-hash")
            XCTFail("row/payload disagreement must be rejected")
        } catch { }

        let incompleteHash = "incomplete-doc-hash"
        let incompleteItem = FormulaInventoryItem(equationID: "eq-incomplete", label: "(3)",
            sourceTeX: "z=3", ordinal: 1, documentHash: incompleteHash)
        let incomplete = FormulaInventory(documentHash: incompleteHash, items: [incompleteItem],
            labelledEquationCount: 2, failureReason: "one numbered formula could not be paired")
        try await repository.saveFormulaInventory(incomplete, paperID: 42)
        let recoveredIncomplete = try await repository.formulaInventory(paperID: 42, documentHash: incompleteHash)
        XCTAssertEqual(recoveredIncomplete, incomplete)
        XCTAssertFalse(try XCTUnwrap(recoveredIncomplete).isComplete)
        let incompleteHeader = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<StoredV10FormulaInventory>())
            .first { $0.documentHash == incompleteHash })
        XCTAssertEqual(incompleteHeader.status, "incomplete")

        let staleHash = "stale-parser-doc-hash"
        let staleItem = FormulaInventoryItem(equationID: "eq-stale", label: "(4)", sourceTeX: "w=4",
            ordinal: 1, documentHash: staleHash)
        let stale = FormulaInventory(documentHash: staleHash, items: [staleItem],
            parserVersion: FormulaInventoryParser.parserVersion - 1)
        try await repository.saveFormulaInventory(stale, paperID: 42)
        do {
            _ = try await V10FormulaInventoryStore(modelContainer: container)
                .formulaInventory(paperID: 42, documentHash: staleHash)
            XCTFail("an inventory from an obsolete parser must be rebuilt before reuse")
        } catch { }
    }

    @MainActor
    func testV10CategoryProfileAndFormulaCheckpointSurviveStoreReopen() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-durable")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Library-v10.store")
        let schema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let profile = CategoryProfile(categories: [.hepLat, .hepPh, .hepTh], revision: 4)
        let completedBatch = FormulaBatchCheckpoint(jobID: "durable-formula-job", batchIndex: 0,
            batchTotal: 2, equationIDs: ["eq-1"], payloadHash: "payload-hash-1", requestID: "request-1",
            attemptCount: 1, receivedBytes: 128, receivedCharacters: 96, status: .completed)
        let pendingBatch = FormulaBatchCheckpoint(jobID: "durable-formula-job", batchIndex: 1,
            batchTotal: 2, equationIDs: ["eq-2"], payloadHash: "payload-hash-2", requestID: "request-2",
            attemptCount: 1, receivedBytes: 64, receivedCharacters: 48, status: .retryable,
            errorCategory: "idle_timeout")
        let job = FormulaDerivationJob(jobID: "durable-formula-job", paperID: 42,
            documentHash: "doc-hash", inventoryHash: "inventory-hash", equationIDs: ["eq-1", "eq-2"],
            state: .retryable, batches: [completedBatch, pendingBatch])
        let segment = try makeValidatedSegmentCheckpoint(equationID: "eq-1", sourceTeX: "x=y",
            anchorID: "anchor-1", documentHash: "doc-hash", stepText: "original step")
        let completedClaim = EvidenceClaim(textZH: "source equation", epistemicStatus: .direct,
            evidenceIDs: ["anchor-1"], formulaTeX: "x=y", equationID: "eq-1",
            derivationSteps: segment.completedSteps.map(\.textZH), formulaDerivationSteps: segment.completedSteps,
            conclusionZH: segment.conclusionZH, derivationSegmentProvenanceHash: try segment.provenanceHash())
        let checkpoint = FormulaDerivationCheckpoint(job: job, completedClaimsByBatch: [0: [completedClaim]],
            derivationSegmentsByEquation: ["eq-1": segment],
            promptVersion: FormulaDerivationPrompt.version, schemaVersion: PaperInsightV2Validator.schemaVersion,
            updatedAt: Date(timeIntervalSince1970: 10))

        do {
            let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
                configurations: ModelConfiguration(schema: schema, url: url))
            let jobs = V10FormulaJobStore(modelContainer: container)
            let profiles = V10CategoryProfileStore(modelContainer: container)
            try await jobs.saveFormulaJob(checkpoint)
            try await profiles.saveCategoryProfile(profile)

            let initialBatchRow = try XCTUnwrap(ModelContext(container)
                .fetch(FetchDescriptor<StoredV10FormulaBatchCheckpoint>(predicate: #Predicate { $0.id == completedBatch.id })).first)
            let initialStepRow = try XCTUnwrap(ModelContext(container)
                .fetch(FetchDescriptor<StoredV10FormulaDerivationStep>(predicate: #Predicate { $0.id == "durable-formula-job:eq-1:0" })).first)
            let initialClaimRow = try XCTUnwrap(ModelContext(container)
                .fetch(FetchDescriptor<StoredV11FormulaClaim>(predicate: #Predicate { $0.equationID == "eq-1" })).first)
            var updatedCheckpoint = checkpoint
            updatedCheckpoint.job.batches[0].receivedBytes = 256
            updatedCheckpoint.completedClaimsByBatch[0] = [EvidenceClaim(id: completedClaim.id,
                textZH: "updated source equation", epistemicStatus: .direct, evidenceIDs: ["anchor-1"],
                formulaTeX: "x=y", equationID: "eq-1", derivationSteps: completedClaim.derivationSteps,
                formulaDerivationSteps: completedClaim.formulaDerivationSteps,
                conclusionZH: completedClaim.conclusionZH,
                derivationSegmentProvenanceHash: completedClaim.derivationSegmentProvenanceHash)]
            updatedCheckpoint.updatedAt = Date(timeIntervalSince1970: 11)
            try await jobs.saveFormulaJob(updatedCheckpoint)
            let updatedBatchRow = try XCTUnwrap(ModelContext(container)
                .fetch(FetchDescriptor<StoredV10FormulaBatchCheckpoint>(predicate: #Predicate { $0.id == completedBatch.id })).first)
            let updatedStepRow = try XCTUnwrap(ModelContext(container)
                .fetch(FetchDescriptor<StoredV10FormulaDerivationStep>(predicate: #Predicate { $0.id == "durable-formula-job:eq-1:0" })).first)
            let updatedClaimRow = try XCTUnwrap(ModelContext(container)
                .fetch(FetchDescriptor<StoredV11FormulaClaim>(predicate: #Predicate { $0.equationID == "eq-1" })).first)
            XCTAssertEqual(updatedBatchRow.persistentModelID, initialBatchRow.persistentModelID,
                           "a changed batch row is updated by stable ID, not deleted and recreated")
            XCTAssertEqual(updatedBatchRow.receivedBytes, 256)
            XCTAssertEqual(updatedStepRow.persistentModelID, initialStepRow.persistentModelID,
                           "a validated segment step remains stable while unrelated job metadata changes")
            XCTAssertEqual(updatedStepRow.text, "original step")
            XCTAssertEqual(updatedClaimRow.persistentModelID, initialClaimRow.persistentModelID,
                           "a changed claim row is updated by stable ID, not deleted and recreated")
            XCTAssertEqual(updatedClaimRow.textZH, "updated source equation")
        }
        let reopened = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
            configurations: ModelConfiguration(schema: schema, url: url))
        let jobs = V10FormulaJobStore(modelContainer: reopened)
        let profiles = V10CategoryProfileStore(modelContainer: reopened)
        let restoredJob = try await jobs.formulaJob(id: job.jobID)
        let restoredProfile = try await profiles.loadCategoryProfile()
        XCTAssertEqual(restoredJob?.job.jobID, checkpoint.job.jobID)
        XCTAssertEqual(restoredJob?.job.inventoryHash, checkpoint.job.inventoryHash)
        XCTAssertEqual(restoredJob?.job.state, .retryable)
        XCTAssertEqual(restoredJob?.promptVersion, checkpoint.promptVersion)
        XCTAssertEqual(restoredJob?.schemaVersion, checkpoint.schemaVersion)
        XCTAssertEqual(restoredJob?.job.batches.first?.requestID, "request-1")
        XCTAssertEqual(restoredJob?.job.batches.first?.receivedBytes, 256)
        XCTAssertEqual(restoredJob?.completedClaimsByBatch[0]?.first?.textZH, "updated source equation")
        XCTAssertEqual(restoredJob?.completedClaimsByBatch[0]?.first?.derivationSteps, ["original step"])
        XCTAssertEqual(restoredJob?.job.batches.last?.errorCategory, "idle_timeout")
        XCTAssertEqual(restoredProfile, profile)
    }

    @MainActor
    func testFormulaCheckpointSaveDoesNotMarkUnchangedValidatedRowsUpdated() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-formula-row-delta")
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
            configurations: ModelConfiguration(schema: schema, url: root.appendingPathComponent("Library-v10.store")))
        let batches = [
            FormulaBatchCheckpoint(jobID: "row-delta-job", batchIndex: 0, batchTotal: 3,
                equationIDs: ["eq-1"], payloadHash: "payload-1", requestID: "request-1",
                attemptCount: 1, receivedBytes: 64, receivedCharacters: 48, status: .completed,
                updatedAt: Date(timeIntervalSince1970: 20)),
            FormulaBatchCheckpoint(jobID: "row-delta-job", batchIndex: 1, batchTotal: 3,
                equationIDs: ["eq-2"], payloadHash: "payload-2", requestID: "request-2",
                attemptCount: 1, receivedBytes: 96, receivedCharacters: 72, status: .completed,
                updatedAt: Date(timeIntervalSince1970: 20)),
            FormulaBatchCheckpoint(jobID: "row-delta-job", batchIndex: 2, batchTotal: 3,
                equationIDs: ["eq-3"], payloadHash: "payload-3", requestID: "request-3",
                attemptCount: 1, receivedBytes: 32, receivedCharacters: 24, status: .retryable,
                errorCategory: "idle_timeout", updatedAt: Date(timeIntervalSince1970: 20))
        ]
        let job = FormulaDerivationJob(jobID: "row-delta-job", paperID: 42,
            documentHash: "doc-hash", inventoryHash: "inventory-hash",
            equationIDs: ["eq-1", "eq-2", "eq-3"], state: .retryable, batches: batches,
            startedAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 20))
        let firstSegment = try makeValidatedSegmentCheckpoint(equationID: "eq-1", sourceTeX: "x=y",
            anchorID: "anchor-1", documentHash: "doc-hash", stepText: "first step")
        let secondSegment = try makeValidatedSegmentCheckpoint(equationID: "eq-2", sourceTeX: "y=z",
            anchorID: "anchor-2", documentHash: "doc-hash", stepText: "保持此已驗證步驟")
        let firstStep = try XCTUnwrap(firstSegment.completedSteps.first)
        let untouchedStructuredStep = try XCTUnwrap(secondSegment.completedSteps.first)
        let claims = [
            EvidenceClaim(textZH: "第一個已驗證公式", epistemicStatus: .direct,
                evidenceIDs: ["anchor-1"], formulaTeX: "x=y", equationID: "eq-1",
                derivationSteps: [firstStep.textZH], formulaDerivationSteps: [firstStep],
                conclusionZH: firstSegment.conclusionZH,
                derivationSegmentProvenanceHash: try firstSegment.provenanceHash()),
            EvidenceClaim(textZH: "第二個已驗證公式", epistemicStatus: .direct,
                evidenceIDs: ["anchor-2"], formulaTeX: "y=z", equationID: "eq-2",
                derivationSteps: [untouchedStructuredStep.textZH], formulaDerivationSteps: [untouchedStructuredStep],
                conclusionZH: secondSegment.conclusionZH,
                derivationSegmentProvenanceHash: try secondSegment.provenanceHash())
        ]
        let checkpoint = FormulaDerivationCheckpoint(job: job,
            completedClaimsByBatch: [0: [claims[0]], 1: [claims[1]]],
            derivationSegmentsByEquation: ["eq-1": firstSegment, "eq-2": secondSegment],
            promptVersion: FormulaDerivationPrompt.version,
            schemaVersion: PaperInsightV2Validator.schemaVersion,
            updatedAt: Date(timeIntervalSince1970: 20))
        let repository = V10FormulaJobStore(modelContainer: container)
        try await repository.saveFormulaJob(checkpoint)

        let readContext = ModelContext(container)
        let changedBatchRow = try XCTUnwrap(try readContext.fetch(
            FetchDescriptor<StoredV10FormulaBatchCheckpoint>()).first { $0.batchIndex == 0 })
        let untouchedBatchRow = try XCTUnwrap(try readContext.fetch(
            FetchDescriptor<StoredV10FormulaBatchCheckpoint>()).first { $0.batchIndex == 1 })
        let untouchedLegacyStepRow = try XCTUnwrap(try readContext.fetch(
            FetchDescriptor<StoredV10FormulaDerivationStep>()).first { $0.equationID == "eq-2" })
        let untouchedClaimRow = try XCTUnwrap(try readContext.fetch(
            FetchDescriptor<StoredV11FormulaClaim>()).first { $0.equationID == "eq-2" })
        let untouchedStructuredStepRow = try XCTUnwrap(try readContext.fetch(
            FetchDescriptor<StoredV11FormulaDerivationStep>()).first { $0.equationID == "eq-2" })

        let changeRecorder = ModelContextSaveChangeRecorder()
        let saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: nil
        ) { [changeRecorder] notification in
            changeRecorder.record(notification)
        }
        defer { NotificationCenter.default.removeObserver(saveObserver) }

        var updated = checkpoint
        updated.job.batches[0].receivedBytes = 128
        updated.updatedAt = Date(timeIntervalSince1970: 21)
        try await repository.saveFormulaJob(updated)

        let updatedIDs = changeRecorder.snapshot()
        XCTAssertTrue(updatedIDs.contains(changedBatchRow.persistentModelID),
                      "the changed batch checkpoint must be included in the save")
        XCTAssertFalse(updatedIDs.contains(untouchedBatchRow.persistentModelID),
                       "an unchanged validated batch checkpoint must not be marked updated")
        XCTAssertFalse(updatedIDs.contains(untouchedLegacyStepRow.persistentModelID),
                       "an unchanged legacy step projection must not be marked updated")
        XCTAssertFalse(updatedIDs.contains(untouchedClaimRow.persistentModelID),
                       "an unchanged canonical claim must not be marked updated")
        XCTAssertFalse(updatedIDs.contains(untouchedStructuredStepRow.persistentModelID),
                       "an unchanged canonical derivation step must not be marked updated")

        XCTAssertEqual(untouchedBatchRow.receivedBytes, 96)
        XCTAssertEqual(untouchedLegacyStepRow.text, "保持此已驗證步驟")
        XCTAssertEqual(untouchedClaimRow.textZH, "第二個已驗證公式")
        XCTAssertEqual(untouchedStructuredStepRow.textZH, "保持此已驗證步驟")
        let restored = try await repository.formulaJob(id: job.jobID)
        XCTAssertEqual(restored?.completedClaimsByBatch[1], [claims[1]])
    }

    @MainActor
    func testV10FormulaJobReadsMutableStateFromTypedRowsAndRejectsDamagedProjection() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-formula-typed-source")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Library-v10.store")
        let schema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
            configurations: ModelConfiguration(schema: schema, url: url))
        let batches = [
            FormulaBatchCheckpoint(jobID: "typed-source-job", batchIndex: 0, batchTotal: 2,
                equationIDs: ["eq-1"], payloadHash: "payload-1", requestID: "request-1",
                attemptCount: 2, receivedBytes: 128, receivedCharacters: 96, status: .completed),
            FormulaBatchCheckpoint(jobID: "typed-source-job", batchIndex: 1, batchTotal: 2,
                equationIDs: ["eq-2"], payloadHash: "payload-2", requestID: "request-2",
                attemptCount: 1, receivedBytes: 64, receivedCharacters: 48, status: .retryable,
                errorCategory: "idle_timeout")
        ]
        let job = FormulaDerivationJob(jobID: "typed-source-job", paperID: 42,
            documentHash: "doc-hash", inventoryHash: "inventory-hash", equationIDs: ["eq-1", "eq-2"],
            state: .retryable, batches: batches, startedAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20))
        let segment = try makeValidatedSegmentCheckpoint(equationID: "eq-1", sourceTeX: "x=y",
            anchorID: "anchor-1", documentHash: "doc-hash", stepText: "逐步推導",
            referencedEquationIDs: ["eq-2"])
        let derivationStep = try XCTUnwrap(segment.completedSteps.first)
        let claim = EvidenceClaim(textZH: "原文公式", epistemicStatus: .direct,
            evidenceIDs: ["anchor-1"], formulaTeX: "x=y", equationID: "eq-1",
            derivationSteps: [derivationStep.textZH], formulaDerivationSteps: [derivationStep],
            conclusionZH: segment.conclusionZH,
            derivationSegmentProvenanceHash: try segment.provenanceHash())
        let checkpoint = FormulaDerivationCheckpoint(job: job, completedClaimsByBatch: [0: [claim]],
            derivationSegmentsByEquation: ["eq-1": segment],
            promptVersion: FormulaDerivationPrompt.version, schemaVersion: PaperInsightV2Validator.schemaVersion,
            contextFingerprint: "profile-fingerprint", updatedAt: job.updatedAt)
        let repository = V10FormulaJobStore(modelContainer: container)
        try await repository.saveFormulaJob(checkpoint)

        let projectionRow = try XCTUnwrap(try container.mainContext.fetch(
            FetchDescriptor<StoredV10FormulaDerivationJob>(predicate: #Predicate { $0.id == job.jobID })).first)
        var staleProjection = checkpoint
        staleProjection.job.state = .prepared
        staleProjection.job.batches[0].receivedBytes = 1
        staleProjection.updatedAt = Date(timeIntervalSince1970: 1)
        projectionRow.payload = try JSONEncoder.latticeLens.encode(staleProjection)
        try container.mainContext.save()

        let restoredResult = try await repository.formulaJob(id: job.jobID)
        let restored = try XCTUnwrap(restoredResult)
        XCTAssertEqual(restored.job.state, .retryable,
                       "the typed job row, not its compatibility payload, owns mutable job state")
        XCTAssertEqual(restored.job.batches[0].receivedBytes, 128,
                       "typed batch checkpoint rows own request counters and status")
        XCTAssertEqual(restored.updatedAt, job.updatedAt)
        XCTAssertEqual(restored.completedClaimsByBatch[0], [claim],
                       "canonical V11 claim rows must restore claims independently of the damaged projection")

        let dependencyRow = try XCTUnwrap(try container.mainContext.fetch(
            FetchDescriptor<StoredV10EquationDependency>(predicate: #Predicate { $0.jobID == job.jobID })).first)
        XCTAssertEqual(dependencyRow.equationID, "eq-1")
        XCTAssertEqual(dependencyRow.dependsOnEquationID, "eq-2")
        dependencyRow.dependsOnEquationID = "eq-1"
        try container.mainContext.save()
        do {
            _ = try await repository.formulaJob(id: job.jobID)
            XCTFail("typed dependency tampering must invalidate completed claims")
        } catch { }
        dependencyRow.dependsOnEquationID = "eq-2"
        try container.mainContext.save()

        let stepRow = try XCTUnwrap(try container.mainContext.fetch(
            FetchDescriptor<StoredV10FormulaDerivationStep>(predicate: #Predicate { $0.jobID == job.jobID })).first)
        stepRow.text = "tampered typed step"
        try container.mainContext.save()
        do {
            _ = try await repository.formulaJob(id: job.jobID)
            XCTFail("typed derivation rows that disagree with completed claims must be rejected")
        } catch { }
        stepRow.text = "逐步推導"
        try container.mainContext.save()

        let attemptRow = try XCTUnwrap(try container.mainContext.fetch(
            FetchDescriptor<StoredV10AnalysisAttempt>()).first)
        let originalAttemptBytes = attemptRow.receivedBytes
        attemptRow.receivedBytes += 1
        try container.mainContext.save()
        do {
            _ = try await repository.formulaJob(id: job.jobID)
            XCTFail("typed attempt telemetry that disagrees with the batch checkpoint must be rejected")
        } catch { }
        attemptRow.receivedBytes = originalAttemptBytes
        try container.mainContext.save()

        var conflictingProjection = checkpoint
        conflictingProjection.derivationSegmentsByEquation = nil
        projectionRow.payload = try JSONEncoder.latticeLens.encode(conflictingProjection)
        try container.mainContext.save()
        do {
            _ = try await repository.formulaJob(id: job.jobID)
            XCTFail("a decodable compatibility projection that conflicts with canonical V12 segment rows must fail closed")
        } catch V10FormulaJobStoreError.inconsistent(let reason) {
            XCTAssertTrue(reason.contains("V12 canonical segment rows"))
        } catch {
            XCTFail("unexpected error for a conflicting compatibility projection: \(error)")
        }

        projectionRow.payload = Data("not a checkpoint".utf8)
        try container.mainContext.save()
        let restoredFromTypedRows = try await repository.formulaJob(id: job.jobID)
        XCTAssertEqual(restoredFromTypedRows?.completedClaimsByBatch[0], [claim],
                       "V12 canonical claim/segment rows, not a malformed compatibility blob, own claim content")
        let canonicalClaim = try XCTUnwrap(try container.mainContext.fetch(
            FetchDescriptor<StoredV11FormulaClaim>(predicate: #Predicate { $0.jobID == job.jobID })).first)
        canonicalClaim.textZH = "tampered typed claim"
        try container.mainContext.save()
        do {
            _ = try await repository.formulaJob(id: job.jobID)
            XCTFail("tampered canonical claim content must fail its row hash check")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    @MainActor
    func testV10FormulaJobBackfillsLegacyBatchDefinitionRowsOnce() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-formula-legacy-batch")
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema(versionedSchema: LatticeLensSchemaV11.self)
        let container = try ModelContainer(for: schema,
            configurations: ModelConfiguration(url: root.appendingPathComponent("Library-v10.store")))
        let batch = FormulaBatchCheckpoint(jobID: "legacy-typed-job", batchIndex: 0, batchTotal: 1,
            equationIDs: ["eq-1"], payloadHash: "batch-hash", requestID: "request-1",
            attemptCount: 1, receivedBytes: 32, receivedCharacters: 28, status: .completed,
            updatedAt: Date(timeIntervalSince1970: 20))
        let job = FormulaDerivationJob(jobID: "legacy-typed-job", paperID: 42, documentHash: "doc-hash",
            inventoryHash: "inventory-hash", equationIDs: ["eq-1"], state: .complete,
            batches: [batch], startedAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 20))
        let claim = EvidenceClaim(textZH: "原文公式", epistemicStatus: .direct,
            evidenceIDs: ["anchor-1"], formulaTeX: "x=y", equationID: "eq-1", derivationSteps: ["推導"])
        let checkpoint = FormulaDerivationCheckpoint(job: job, completedClaimsByBatch: [0: [claim]],
            promptVersion: FormulaDerivationPrompt.version, schemaVersion: PaperInsightV2Validator.schemaVersion,
            contextFingerprint: "legacy-profile", updatedAt: job.updatedAt)
        container.mainContext.insert(StoredV10FormulaDerivationJob(id: job.jobID, paperID: job.paperID,
            documentID: "42:doc-hash", documentHash: job.documentHash, inventoryHash: job.inventoryHash,
            state: job.state.rawValue, promptVersion: checkpoint.promptVersion,
            schemaVersion: checkpoint.schemaVersion, createdAt: job.startedAt, updatedAt: job.updatedAt,
            payload: try JSONEncoder.latticeLens.encode(checkpoint)))
        container.mainContext.insert(StoredV10FormulaBatchCheckpoint(id: batch.id, jobID: job.jobID,
            inventoryHash: job.inventoryHash, batchIndex: batch.batchIndex, batchTotal: batch.batchTotal,
            equationIDsData: try JSONEncoder.latticeLens.encode(batch.equationIDs), requestID: batch.requestID,
            attemptCount: batch.attemptCount, payloadHash: batch.payloadHash,
            receivedBytes: batch.receivedBytes, receivedCharacters: batch.receivedCharacters,
            firstContentAt: batch.firstContentAt, lastContentAt: batch.lastContentAt,
            status: batch.status.rawValue, errorCategory: batch.errorCategory, updatedAt: batch.updatedAt))
        container.mainContext.insert(StoredV10FormulaDerivationStep(id: "legacy-typed-job:eq-1:0",
            jobID: job.jobID, equationID: "eq-1", ordinal: 0, text: "推導", anchorID: "anchor-1",
            status: "validated_batch_0"))
        try container.mainContext.save()

        let repository = V10FormulaJobStore(modelContainer: container)
        let restored = try await repository.formulaJob(id: job.jobID)
        XCTAssertEqual(restored?.job.state, .complete)
        XCTAssertEqual(restored?.completedClaimsByBatch[0], [claim])
        let migratedDefinitions = try container.mainContext.fetch(
            FetchDescriptor<StoredV10FormulaBatch>(predicate: #Predicate { $0.jobID == job.jobID }))
        XCTAssertEqual(migratedDefinitions.count, 1,
                       "a complete legacy checkpoint is lazily normalized exactly once into the typed batch table")
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<StoredV10AnalysisRun>()).count, 1,
                       "a validated legacy checkpoint is lazily given its missing typed analysis-run row")
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<StoredV10AnalysisAttempt>()).count, 1,
                       "the latest legacy request attempt is reconstructed from its typed batch checkpoint")
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<StoredV11FormulaDerivationJob>()).count, 1,
                       "a V10 checkpoint is imported once into the additive V11 canonical job rows")
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<StoredV11FormulaClaim>()).count, 1)
    }

    @MainActor
    func testV10FormulaJobPersistsTypedRunAttemptsAndValidationReceiptAtomically() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-formula-audit-rows")
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
            configurations: ModelConfiguration(schema: schema, url: root.appendingPathComponent("Library-v10.store")))
        let item = FormulaInventoryItem(equationID: "eq-1", label: "(1)", sourceTeX: "x=1",
            ordinal: 1, documentHash: "doc-hash", evidenceID: "anchor-1")
        let inventory = FormulaInventory(documentHash: "doc-hash", items: [item])
        try await V10FormulaInventoryStore(modelContainer: container)
            .saveFormulaInventory(inventory, paperID: 42)
        let batch = FormulaBatchCheckpoint(jobID: "audit-row-job", batchIndex: 0, batchTotal: 1,
            equationIDs: ["eq-1"], payloadHash: "batch-hash", requestID: "request-1",
            attemptCount: 1, receivedBytes: 64, receivedCharacters: 48, status: .completed,
            updatedAt: Date(timeIntervalSince1970: 20))
        let job = FormulaDerivationJob(jobID: batch.jobID, paperID: 42, documentHash: "doc-hash",
            inventoryHash: inventory.inventoryHash, equationIDs: ["eq-1"], state: .incomplete,
            batches: [batch], startedAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 20))
        let segment = try makeValidatedSegmentCheckpoint(equationID: "eq-1", sourceTeX: "x=1",
            anchorID: "anchor-1", documentHash: "doc-hash", stepText: "結構步驟但缺少來源錨點")
        let step = try XCTUnwrap(segment.completedSteps.first)
        let claim = EvidenceClaim(textZH: "原文公式", epistemicStatus: .direct,
            evidenceIDs: ["anchor-1"], formulaTeX: "x=1", equationID: "eq-1",
            derivationSteps: [step.textZH], formulaDerivationSteps: [step],
            conclusionZH: segment.conclusionZH,
            derivationSegmentProvenanceHash: try segment.provenanceHash())
        let checkpoint = FormulaDerivationCheckpoint(job: job, completedClaimsByBatch: [0: [claim]],
            derivationSegmentsByEquation: ["eq-1": segment],
            promptVersion: FormulaDerivationPrompt.version, schemaVersion: PaperInsightV2Validator.schemaVersion,
            contextFingerprint: "audit-context", updatedAt: job.updatedAt)
        let report = FormulaCoverageValidator.report(inventory: inventory, claims: [claim])
        XCTAssertFalse(report.isComplete, "the fixture intentionally omits the source-bound EvidenceAnchor payload")

        let repository = V10FormulaJobStore(modelContainer: container)
        try await repository.saveFormulaJobWithValidation(checkpoint, report: report)
        let restoredReport = try await repository.formulaValidationReport(jobID: job.jobID)
        XCTAssertEqual(restoredReport, report)
        let firstReadback = ModelContext(container)
        let runs = try firstReadback.fetch(FetchDescriptor<StoredV10AnalysisRun>())
        let attempts = try firstReadback.fetch(FetchDescriptor<StoredV10AnalysisAttempt>())
        let reports = try firstReadback.fetch(FetchDescriptor<StoredV10FormulaValidationReport>())
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.workflowKind, "formula_derivation")
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.first?.requestID, "request-1")
        XCTAssertEqual(attempts.first?.status, "completed")
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.status, "incomplete")

        var interruptedValidation = checkpoint
        interruptedValidation.job.state = .validating
        interruptedValidation.job.updatedAt = Date(timeIntervalSince1970: 20.5)
        interruptedValidation.updatedAt = interruptedValidation.job.updatedAt
        try await repository.saveFormulaJob(interruptedValidation)
        let validatingReadback = try await repository.formulaJob(id: job.jobID)
        XCTAssertEqual(validatingReadback?.job.state, .validating,
                       "the typed production store must preserve a re-entrant validation phase")
        XCTAssertEqual(validatingReadback?.completedClaimsByBatch[0], [claim],
                       "a validation restart must retain the already committed claims")

        var resumed = checkpoint
        resumed.job.state = .retryable
        resumed.job.batches[0].status = .retryable
        resumed.job.batches[0].errorCategory = "idle_timeout"
        resumed.updatedAt = Date(timeIntervalSince1970: 21)
        resumed.completedClaimsByBatch = [:]
        try await repository.saveFormulaJob(resumed)
        let staleReport = try await repository.formulaValidationReport(jobID: job.jobID)
        XCTAssertNil(staleReport,
                     "a resumed job cannot expose an earlier validation receipt as current")
        let resumedReadback = ModelContext(container)
        XCTAssertEqual(try resumedReadback.fetch(FetchDescriptor<StoredV10FormulaValidationReport>()).first?.status,
                       "stale", "stale receipt remains auditable but is no longer authoritative")
        XCTAssertEqual(try resumedReadback.fetch(FetchDescriptor<StoredV10AnalysisAttempt>()).first?.errorCategory,
                       "idle_timeout")
    }

    @MainActor
    func testV10SemanticSummaryCanonicalizesEverySnapshotSetAcrossReopen() throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-canonical-semantic-summary")
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema(versionedSchema: LatticeLensSchemaV10.self)
        let firstURL = root.appendingPathComponent("canonical-first.store")
        let reverseURL = root.appendingPathComponent("canonical-reverse.store")
        let changedURL = root.appendingPathComponent("canonical-membership-changed.store")

        let initial: V10StoreSemanticSummary
        do {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: firstURL))
            try V8TypedStoreCodec.materialize(semanticFingerprintFixture(paperID: 82001,
                reverseSetInsertion: false), in: container.mainContext, sourceSchemaVersion: 10)
            initial = try V10StoreSemanticSummary.make(from: container.mainContext, schemaVersion: 10)
        }

        let reopened: V10StoreSemanticSummary
        do {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: firstURL))
            reopened = try V10StoreSemanticSummary.make(from: container.mainContext, schemaVersion: 10)
            XCTAssertEqual(try V10StoreSemanticSummary.make(from: container.mainContext, schemaVersion: 10), reopened)
        }
        XCTAssertEqual(initial, reopened,
                       "authors, author generations, and every snapshot relationship Set must hash identically after SQLite reopen")
        XCTAssertEqual(initial.serializedLibraryHashFormatVersion, 3)

        let reverseInsertion: V10StoreSemanticSummary
        do {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: reverseURL))
            try V8TypedStoreCodec.materialize(semanticFingerprintFixture(paperID: 82001,
                reverseSetInsertion: true), in: container.mainContext, sourceSchemaVersion: 10)
            reverseInsertion = try V10StoreSemanticSummary.make(from: container.mainContext, schemaVersion: 10)
        }
        XCTAssertEqual(initial.serializedLibraryHash, reverseInsertion.serializedLibraryHash,
                       "Set insertion order must not affect the persisted-library fingerprint")

        let changedMembership: V10StoreSemanticSummary
        do {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: changedURL))
            try V8TypedStoreCodec.materialize(semanticFingerprintFixture(paperID: 82001,
                reverseSetInsertion: true, addMembership: true), in: container.mainContext, sourceSchemaVersion: 10)
            changedMembership = try V10StoreSemanticSummary.make(from: container.mainContext, schemaVersion: 10)
        }
        XCTAssertEqual(initial.domainSummary, changedMembership.domainSummary)
        XCTAssertNotEqual(initial.serializedLibraryHash, changedMembership.serializedLibraryHash,
                          "a real author-generation membership change remains visible to semantic reconciliation")
    }

    func testV10SemanticSummaryDecodesLegacyFingerprintWithoutChangingItsReceiptHash() throws {
        let typedEmptyHash = StableHash.sha256("")
        let legacyData = Data("""
        {"domainSummary":{"counts":{"papers":1},"stableIDHash":"legacy-domain"},
         "serializedLibraryHash":"legacy-json-hash","typedRowCounts":{},
         "typedIdentityHash":"\(typedEmptyHash)","typedContentHash":"\(typedEmptyHash)",
         "hasLegacyCategoryCheckpoint":false,"legacyCategoryCheckpointCount":0}
        """.utf8)
        let legacy = try JSONDecoder.latticeLens.decode(V10StoreSemanticSummary.self, from: legacyData)
        let legacyComponents = ["legacy-domain", "legacy-json-hash", typedEmptyHash, typedEmptyHash,
            StableHash.sha256(""), StableHash.sha256(""), "no-category-profile", "false", "0", "no-invalidation-count"]
        XCTAssertEqual(legacy.serializedLibraryHashFormatVersion, 1)
        XCTAssertEqual(legacy.stableIDHash, StableHash.sha256(legacyComponents.joined(separator: "|")))

        let reencoded = try JSONEncoder.latticeLens.encode(legacy)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        XCTAssertNil(object["serializedLibraryHashFormatVersion"],
                     "legacy summary encoding must preserve hashes embedded in pre-canonicalization backup manifests")
    }

    @MainActor
    func testV10SemanticSummaryCoversEveryTypedRowFamilyAndRowContent() throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-semantic-summary")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Library-v10.store")
        let container = try ModelContainer(for: Schema(versionedSchema: LatticeLensSchemaV10.self),
                                           configurations: ModelConfiguration(url: url))
        let context = container.mainContext
        try V8TypedStoreCodec.materialize(LibrarySnapshot(schemaVersion: 10), in: context, sourceSchemaVersion: 10)
        try V10CategoryProfileBootstrap.migrateOrCreate(in: context)
        let timestamp = Date(timeIntervalSince1970: 123)
        let inventory = StoredV10FormulaInventory(id: "inventory-1", paperID: 1, documentID: "doc-1",
            documentHash: "document-hash", inventoryHash: "inventory-hash", parserVersion: 2,
            status: "complete", payload: Data("inventory-payload-v1".utf8), updatedAt: timestamp)
        context.insert(StoredV10AuthorCategoryMembership(id: "membership-1", authorID: 9,
            category: "hep-ph", generationID: "generation-1", isCurrent: true, updatedAt: timestamp))
        context.insert(inventory)
        context.insert(StoredV10FormulaInventoryItem(id: "item-1", paperID: 1, documentID: "doc-1",
            documentHash: "document-hash", inventoryHash: "inventory-hash", equationID: "eq-1", label: "(1)",
            ordinal: 0, sourceByteStart: 10, sourceByteEnd: 20, sourceTeXHash: "tex-hash", anchorID: "anchor-1",
            status: "numbered", payload: Data("item".utf8)))
        context.insert(StoredV10FormulaDerivationJob(id: "job-1", paperID: 1, documentID: "doc-1",
            documentHash: "document-hash", inventoryHash: "inventory-hash", state: "retryable",
            promptVersion: "prompt-v2", schemaVersion: "schema-v2", createdAt: timestamp, updatedAt: timestamp,
            payload: Data("job".utf8)))
        context.insert(StoredV10FormulaBatch(id: "batch-1", jobID: "job-1", ordinal: 0,
            equationIDsData: Data("[eq-1]".utf8), payloadHash: "batch-hash", status: "completed", updatedAt: timestamp))
        context.insert(StoredV10FormulaBatchCheckpoint(id: "checkpoint-1", jobID: "job-1",
            inventoryHash: "inventory-hash", batchIndex: 0, batchTotal: 1, equationIDsData: Data("[eq-1]".utf8),
            requestID: "request-1", attemptCount: 1, payloadHash: "payload-hash", receivedBytes: 12,
            receivedCharacters: 10, firstContentAt: timestamp, lastContentAt: timestamp, status: "completed",
            errorCategory: nil, updatedAt: timestamp))
        context.insert(StoredV10FormulaDerivationStep(id: "step-1", jobID: "job-1", equationID: "eq-1",
            ordinal: 0, text: "derive", anchorID: "anchor-1", status: "inference"))
        context.insert(StoredV10EquationDependency(id: "dependency-1", jobID: "job-1", equationID: "eq-1",
            dependsOnEquationID: "eq-0", status: "known"))
        context.insert(StoredV10FormulaValidationReport(id: "report-1", jobID: "job-1",
            inventoryHash: "inventory-hash", claimHash: "claim-hash", validatorVersion: "validator-v1",
            status: "incomplete", payload: Data("report".utf8), createdAt: timestamp))
        context.insert(StoredV10AnalysisRun(id: "run-1", workflowKind: "formula", phase: "paused",
            providerRevision: "provider-r1", modelID: "local-model", promptVersion: "prompt-v2",
            schemaVersion: "schema-v2", payloadHash: "run-hash", sourceDocumentHashesData: Data("[]".utf8),
            inventoryHash: "inventory-hash", updatedAt: timestamp, payload: Data("run".utf8)))
        context.insert(StoredV10AnalysisAttempt(id: "attempt-1", runID: "run-1", requestIndex: 0,
            batchIndex: 0, requestID: "request-1", attempt: 1, status: "retryable", receivedBytes: 10,
            receivedCharacters: 8, errorCategory: "idle_timeout", updatedAt: timestamp))
        context.insert(StoredV10ReadingWorkflowState(paperID: 1, state: "reading", selectedAnchorID: "anchor-1",
            updatedAt: timestamp))
        context.insert(StoredV10SearchIndexState(indexName: "local-search", version: 1, state: "ready",
            indexedRecordCount: 1, updatedAt: timestamp))
        try context.save()

        let initial = try V10StoreSemanticSummary.make(from: context, schemaVersion: 10)
        XCTAssertEqual(initial.typedRowCounts, [
            "categoryMemberships": 1, "categoryProfiles": 1, "formulaInventories": 1, "formulaItems": 1,
            "formulaJobs": 1, "formulaBatches": 1, "formulaBatchCheckpoints": 1, "formulaSteps": 1,
            "equationDependencies": 1, "formulaValidationReports": 1, "analysisRuns": 1,
            "analysisAttempts": 1, "readingWorkflowStates": 1, "searchIndexStates": 1
        ])
        inventory.payload = Data("inventory-payload-v2".utf8)
        try context.save()
        let changed = try V10StoreSemanticSummary.make(from: context, schemaVersion: 10)
        XCTAssertEqual(changed.domainSummary, initial.domainSummary)
        XCTAssertNotEqual(changed.typedContentHash, initial.typedContentHash)
        XCTAssertNotEqual(changed.stableIDHash, initial.stableIDHash)
    }

    @MainActor
    func testV10CategoryProfileStoreDoesNotReplaceMalformedStoredChoiceWithDefaults() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-profile-malformed")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: Schema(versionedSchema: LatticeLensSchemaV10.self),
            configurations: ModelConfiguration(url: root.appendingPathComponent("Library.store")))
        container.mainContext.insert(StoredV10CategoryProfile(revision: CategoryProfile.currentRevision,
            categoriesData: try JSONEncoder.latticeLens.encode(["hep-lat", "unknown-category"])))
        try container.mainContext.save()
        let profiles = V10CategoryProfileStore(modelContainer: container)
        do {
            _ = try await profiles.loadCategoryProfile()
            XCTFail("unknown durable category values must not be mistaken for an absent profile")
        } catch let error as LatticeLensError {
            guard case .persistenceUnavailable(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("未支持分类"))
        }
    }

    @MainActor
    func testV9StoreOpensThroughV10LightweightSchemaStageAndKeepsTypedRows() throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v9-to-v10")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Legacy-v9.store")
        do {
            let schema = Schema(versionedSchema: LatticeLensSchemaV9.self)
            let legacy = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
            legacy.mainContext.insert(StoredV8StoreMarker(semanticHash: "retained-v9-domain-marker"))
            let oldCheckpoint = SyncCheckpoint(jobID: "author-candidates:hep-lat-or-hep-th",
                jobKind: "author-candidates", query: "arxiv_categories:hep-lat OR arxiv_categories:hep-th")
            legacy.mainContext.insert(try StoredV8SyncCheckpoint(oldCheckpoint))
            try legacy.mainContext.save()
        }
        let schema = Schema(versionedSchema: LatticeLensSchemaV10.self)
        let upgraded = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV10.self,
                                          configurations: ModelConfiguration(url: url))
        let markers = try upgraded.mainContext.fetch(FetchDescriptor<StoredV8StoreMarker>())
        let marker = try XCTUnwrap(markers.first)
        XCTAssertEqual(marker.semanticHash, "retained-v9-domain-marker")
        try V10CategoryProfileBootstrap.migrateOrCreate(in: upgraded.mainContext)
        let profileRows = try upgraded.mainContext.fetch(FetchDescriptor<StoredV10CategoryProfile>())
        let profileRow = try XCTUnwrap(profileRows.first)
        let values = try JSONDecoder.latticeLens.decode([String].self, from: profileRow.categoriesData)
        XCTAssertEqual(Set(values), Set(SupportedArxivCategory.legacyV1.map(\.rawValue)))
        let invalidation = try upgraded.mainContext.fetch(FetchDescriptor<StoredV10SearchIndexState>()).first
        XCTAssertEqual(invalidation?.state, "invalidated_by_query_revision")
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

    func testArxivHTMLFallbackExtractsBoundedTextAndFormulaSource() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v4-arxiv-html")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InMemoryLibraryStore()
        let service = FullTextService(store: store, cacheDirectory: root, downloader: AppFixtureFullTextDownloader())
        let source = try XCTUnwrap(URL(string: "https://ar5iv.labs.arxiv.org/html/2509.09367"))
        let preflight = try await service.preflight(sourceURL: source, sourceKind: .arxivHTML)
        XCTAssertEqual(preflight.sourceKind, .arxivHTML)
        XCTAssertEqual(preflight.expectedMIME, "text/html")
        XCTAssertEqual(preflight.finalURL, source)
        let document = try await service.downloadAndExtract(paperID: 2_509_093_67, sourceURL: source, sourceKind: .arxivHTML)
        XCTAssertEqual(document.sourceKind, .arxivHTML)
        XCTAssertNil(document.pageCount)
        let snapshot = await store.snapshot()
        let anchors = snapshot.evidenceAnchors.values.filter { $0.paperID == 2_509_093_67 }
        XCTAssertFalse(anchors.isEmpty)
        XCTAssertTrue(anchors.contains { $0.quote.contains("$C(t)=A e^{-mt}$") })
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

    func testProductionStorePathKeepsFreshV12DataAwayFromLegacyDirectOpenPath() throws {
        let applicationSupport = try makeProjectLocalTestDirectory(prefix: "production-store-path")
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let fileManager = FileManager.default
        let legacyV8 = applicationSupport.appending(path: "LatticeLens/Library-v8.store")
        let currentV12 = applicationSupport.appending(path: "LatticeLens/Library-v12.store")

        XCTAssertEqual(
            LibraryStoreFactory.productionDefaultStoreURL(applicationSupportRoot: applicationSupport),
            currentV12,
            "a fresh 2.0 library must not occupy the direct store path used by 1.0.11"
        )

        try fileManager.createDirectory(at: legacyV8.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try Data("synthetic legacy source".utf8).write(to: legacyV8)
        XCTAssertEqual(
            LibraryStoreFactory.productionDefaultStoreURL(applicationSupportRoot: applicationSupport),
            legacyV8,
            "an existing V8 source remains the migration base and rollback-compatible legacy path"
        )

        try fileManager.removeItem(at: legacyV8)
        let legacySignals = [
            V10StoreMigrationCoordinator.descriptorURL(for: legacyV8),
            V10StoreMigrationCoordinator.descriptorURL(for: legacyV8, targetSchemaVersion: 12),
            LibraryStoreFactory.legacyV7StoreCandidates(applicationSupportRoot: applicationSupport)[0],
            LibraryStoreFactory.legacyV7StoreCandidates(applicationSupportRoot: applicationSupport)[1]
        ]
        for (index, signalURL) in legacySignals.enumerated() {
            try fileManager.createDirectory(at: signalURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try Data("synthetic legacy marker \(index)".utf8).write(to: signalURL)
            XCTAssertEqual(
                LibraryStoreFactory.productionDefaultStoreURL(applicationSupportRoot: applicationSupport),
                legacyV8,
                "legacy descriptors and V7 candidates must keep the migration base on the V8 path"
            )
            try fileManager.removeItem(at: signalURL)
        }

        try fileManager.createDirectory(at: legacyV8.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try Data("synthetic legacy source".utf8).write(to: legacyV8)

        try Data("synthetic current V12 store".utf8).write(to: currentV12)
        XCTAssertEqual(
            LibraryStoreFactory.productionDefaultStoreURL(applicationSupportRoot: applicationSupport),
            currentV12,
            "an existing direct V12 store takes precedence over an older V8 source"
        )
        try fileManager.removeItem(at: currentV12)

        let currentDescriptor = V10StoreMigrationCoordinator.descriptorURL(
            for: currentV12, targetSchemaVersion: 12)
        try Data("synthetic active descriptor".utf8).write(to: currentDescriptor)
        XCTAssertEqual(
            LibraryStoreFactory.productionDefaultStoreURL(applicationSupportRoot: applicationSupport),
            currentV12,
            "an established 2.0 path remains authoritative if an older app later creates a separate V8 store"
        )

        let isolatedRoot = applicationSupport.appending(path: "isolated-production")
        let isolatedCurrent = isolatedRoot.appending(path: "swiftdata/LatticeLens-v12.store")
        let isolatedLegacy = isolatedRoot.appending(path: "swiftdata/LatticeLens-v8.store")
        XCTAssertEqual(
            LibraryStoreFactory.productionIsolationDefaultStoreURL(isolationRoot: isolatedRoot),
            isolatedCurrent,
            "production-isolation smoke roots use a distinct V12 direct-open path"
        )
        try fileManager.createDirectory(at: isolatedLegacy.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try Data("synthetic isolated legacy source".utf8).write(to: isolatedLegacy)
        XCTAssertEqual(
            LibraryStoreFactory.productionIsolationDefaultStoreURL(isolationRoot: isolatedRoot),
            isolatedLegacy,
            "an isolated legacy store remains discoverable for migration"
        )
    }

    func testDirectV12StoreAtLegacyPathIsStagedOnlyForProductionDefaults() throws {
        let applicationSupport = try makeProjectLocalTestDirectory(prefix: "production-direct-v12-path")
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let legacyV8 = applicationSupport.appending(path: "LatticeLens/Library-v8.store")
        let currentV12 = applicationSupport.appending(path: "LatticeLens/Library-v12.store")

        XCTAssertTrue(LibraryStoreFactory.shouldMigrateDirectV12StoreFromLegacyPath(
            at: legacyV8, environment: [:], applicationSupportRoot: applicationSupport))
        XCTAssertFalse(LibraryStoreFactory.shouldMigrateDirectV12StoreFromLegacyPath(
            at: currentV12, environment: [:], applicationSupportRoot: applicationSupport))
        XCTAssertFalse(LibraryStoreFactory.shouldMigrateDirectV12StoreFromLegacyPath(
            at: legacyV8, storeURLOverride: legacyV8, environment: [:],
            applicationSupportRoot: applicationSupport))
        XCTAssertFalse(LibraryStoreFactory.shouldMigrateDirectV12StoreFromLegacyPath(
            at: legacyV8,
            environment: ["LATTICELENS_TEST_STORE_ROOT": applicationSupport.path],
            applicationSupportRoot: applicationSupport),
            "explicit project-local test roots retain their closed-world V8 layout")

        let isolatedRoot = applicationSupport.appending(path: "isolated-production")
        let isolatedLegacy = isolatedRoot.appending(path: "swiftdata/LatticeLens-v8.store")
        XCTAssertTrue(LibraryStoreFactory.shouldMigrateDirectV12StoreFromLegacyPath(
            at: isolatedLegacy,
            environment: ["LATTICELENS_ALLOW_PRODUCTION_ISOLATION": "1",
                          "LATTICELENS_PRODUCTION_STORE_ROOT": isolatedRoot.path]))
    }

    @MainActor
    func testDefaultFactoryStagesPriorDirectV12StoreAwayFromLegacyPath() async throws {
        let taskRoot = try makeProjectLocalTestDirectory(prefix: "direct-v12-production-stage")
        defer { try? FileManager.default.removeItem(at: taskRoot) }
        let isolationRoot = taskRoot.appending(path: "production-isolation")
        let sourceURL = isolationRoot.appending(path: "swiftdata/LatticeLens-v8.store")
        let paper = makePaper(981_201)
        let schema = Schema(versionedSchema: LatticeLensSchemaV12.self)

        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try autoreleasepool {
            let source = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
                configurations: ModelConfiguration(schema: schema, url: sourceURL))
            let context = source.mainContext
            try V8TypedStoreCodec.materialize(
                LibrarySnapshot(papers: [paper.literatureID: paper], schemaVersion: 12),
                in: context, sourceSchemaVersion: 12)
            try V10CategoryProfileBootstrap.migrateOrCreate(in: context)
            try V9TypedSearchIndex.rebuild(in: context)
        }

        let sourceFamilyBefore = try v10DisposableStoreFamilyHashes(at: sourceURL)
        let environment = [
            "LATTICELENS_ALLOW_PRODUCTION_ISOLATION": "1",
            "LATTICELENS_PRODUCTION_STORE_ROOT": isolationRoot.path
        ]
        let store = LibraryStoreFactory.makeDefault(environment: environment)
        let snapshot = await store.snapshot()
        XCTAssertNil(snapshot.readErrorMessage)
        XCTAssertEqual(snapshot.papers[paper.literatureID]?.displayTitle, paper.displayTitle)

        let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(
            for: sourceURL, targetSchemaVersion: 12)
        let descriptor = try JSONDecoder.latticeLens.decode(
            V10ActiveStoreDescriptor.self, from: Data(contentsOf: descriptorURL))
        let activeURL = try XCTUnwrap(V10StoreMigrationCoordinator.resolveActiveStoreURL(
            for: sourceURL, targetSchemaVersion: 12))
        XCTAssertNotEqual(activeURL.standardizedFileURL, sourceURL.standardizedFileURL)
        XCTAssertTrue(descriptor.storeName.hasPrefix(".latticelens-v12-stage-"))
        XCTAssertEqual(try v10DisposableStoreFamilyHashes(at: sourceURL), sourceFamilyBefore,
                       "the prior direct V12 source family must remain byte-identical")

        let journalURL = sourceURL.deletingLastPathComponent()
            .appending(path: ".latticelens-v12-migration-\(descriptor.runID.uuidString).json")
        let journal = try JSONDecoder.latticeLens.decode(
            V10StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
        XCTAssertEqual(journal.sourceSchemaVersion, 12)
        XCTAssertEqual(journal.targetSchemaVersion, 12)
        XCTAssertEqual(journal.phase, .activated)

        let reopened = LibraryStoreFactory.makeDefault(environment: environment)
        let reopenedSnapshot = await reopened.snapshot()
        XCTAssertNil(reopenedSnapshot.readErrorMessage,
                     "a V12 store activated from the legacy path must reopen through the production factory")
        XCTAssertEqual(reopenedSnapshot.papers[paper.literatureID]?.displayTitle, paper.displayTitle)
    }

    @MainActor
    func testActiveV12StoreOpensDespiteStaleFailedMigrationJournalWithDamagedBackupReceipt() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "active-v12-stale-failed-journal")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Library-v10.store")
        let paper = makePaper(981_202)
        let sourceSchema = Schema(versionedSchema: LatticeLensSchemaV10.self)
        let source = try ModelContainer(for: sourceSchema, configurations: ModelConfiguration(url: sourceURL))
        try V8TypedStoreCodec.materialize(
            LibrarySnapshot(papers: [paper.literatureID: paper], schemaVersion: 10),
            in: source.mainContext, sourceSchemaVersion: 10)
        try source.mainContext.save()
        let sourceFamilyBefore = try v10DisposableStoreFamilyHashes(at: sourceURL)

        let firstOpen = LibraryStoreFactory.makeDefault(storeURLOverride: sourceURL)
        let firstSnapshot = await firstOpen.snapshot()
        XCTAssertNil(firstSnapshot.readErrorMessage)
        XCTAssertEqual(firstSnapshot.papers[paper.literatureID]?.displayTitle, paper.displayTitle)

        let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(
            for: sourceURL, targetSchemaVersion: 12)
        let descriptor = try JSONDecoder.latticeLens.decode(
            V10ActiveStoreDescriptor.self, from: Data(contentsOf: descriptorURL))
        let journalURL = root.appendingPathComponent(
            ".latticelens-v12-migration-\(descriptor.runID.uuidString).json")
        let activatedJournal = try JSONDecoder.latticeLens.decode(
            V10StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
        let staleID = UUID()
        let staleJournal = V10StoreMigrationJournal(
            id: staleID,
            sourceStoreName: sourceURL.lastPathComponent,
            stagingStoreName: ".latticelens-v12-stage-\(staleID.uuidString).store",
            descriptorName: descriptorURL.lastPathComponent,
            sourceSchemaVersion: activatedJournal.sourceSchemaVersion,
            targetSchemaVersion: 12,
            backupManifestID: activatedJournal.backupManifestID,
            backupManifestHash: String(repeating: "0", count: 64),
            sourceSummary: activatedJournal.sourceSummary,
            startedAt: Date(timeIntervalSince1970: 1_750_003_000),
            updatedAt: Date(timeIntervalSince1970: 1_750_003_001),
            completedAt: nil,
            phase: .failed,
            targetSummary: nil,
            errorCategory: "simulated_previous_attempt")
        let staleJournalURL = root.appendingPathComponent(
            ".latticelens-v12-migration-\(staleID.uuidString).json")
        try JSONEncoder.latticeLens.encode(staleJournal).write(to: staleJournalURL, options: .atomic)

        let reopened = LibraryStoreFactory.makeDefault(storeURLOverride: sourceURL)
        let reopenedSnapshot = await reopened.snapshot()
        XCTAssertNil(reopenedSnapshot.readErrorMessage,
                     "a stale failed migration must not block a separately verified active V12 store")
        XCTAssertEqual(reopenedSnapshot.papers[paper.literatureID]?.displayTitle, paper.displayTitle)
        XCTAssertEqual(try v10DisposableStoreFamilyHashes(at: sourceURL), sourceFamilyBefore,
                       "ignoring an unrelated failed journal must not mutate the preserved source family")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleJournalURL.path),
                      "the failed migration record must be retained for later diagnosis/recovery")
    }

    @MainActor
    func testInterruptedV12ActivationRecoversItsOwnJournalBeforeIgnoringStaleFailures() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "active-v12-recover-own-journal")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Library-v10.store")
        let sourceSummary = try seedSyntheticV10Store(at: sourceURL, paperID: 981_203)

        let firstOpen = LibraryStoreFactory.makeDefault(storeURLOverride: sourceURL)
        let firstSnapshot = await firstOpen.snapshot()
        XCTAssertNil(firstSnapshot.readErrorMessage)

        let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(
            for: sourceURL, targetSchemaVersion: 12)
        let descriptor = try JSONDecoder.latticeLens.decode(
            V10ActiveStoreDescriptor.self, from: Data(contentsOf: descriptorURL))
        let journalURL = root.appendingPathComponent(
            ".latticelens-v12-migration-\(descriptor.runID.uuidString).json")
        var interruptedJournal = try JSONDecoder.latticeLens.decode(
            V10StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
        interruptedJournal.phase = .verified
        interruptedJournal.completedAt = nil
        interruptedJournal.updatedAt = Date(timeIntervalSince1970: 1_750_003_100)
        try JSONEncoder.latticeLens.encode(interruptedJournal).write(to: journalURL, options: .atomic)

        let staleID = UUID()
        let staleJournal = V10StoreMigrationJournal(
            id: staleID,
            sourceStoreName: sourceURL.lastPathComponent,
            stagingStoreName: ".latticelens-v12-stage-\(staleID.uuidString).store",
            descriptorName: descriptorURL.lastPathComponent,
            sourceSchemaVersion: 10,
            targetSchemaVersion: 12,
            backupManifestID: descriptor.backupManifestID,
            backupManifestHash: String(repeating: "0", count: 64),
            sourceSummary: sourceSummary,
            startedAt: Date(timeIntervalSince1970: 1_750_003_200),
            updatedAt: Date(timeIntervalSince1970: 1_750_003_201),
            completedAt: nil,
            phase: .failed,
            targetSummary: nil,
            errorCategory: "simulated_previous_attempt")
        let staleJournalURL = root.appendingPathComponent(
            ".latticelens-v12-migration-\(staleID.uuidString).json")
        try JSONEncoder.latticeLens.encode(staleJournal).write(to: staleJournalURL, options: .atomic)

        let recovered = LibraryStoreFactory.makeDefault(storeURLOverride: sourceURL)
        let recoveredSnapshot = await recovered.snapshot()
        XCTAssertNil(recoveredSnapshot.readErrorMessage,
                     "recovery must prioritize the journal named by the active descriptor")
        XCTAssertEqual(recoveredSnapshot.papers[981_203]?.displayTitle, "Canonical fixture 981203")
        let recoveredJournal = try JSONDecoder.latticeLens.decode(
            V10StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
        XCTAssertEqual(recoveredJournal.phase, .activated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleJournalURL.path),
                      "unrelated failed migration evidence must remain available")
    }

    @MainActor
    func testBlockedV12FactoryReportsMigrationStageAndSpecificErrorCase() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "active-v12-error-diagnostic")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Library-v10.store")
        _ = try seedSyntheticV10Store(at: sourceURL, paperID: 981_204)
        let firstOpen = LibraryStoreFactory.makeDefault(storeURLOverride: sourceURL)
        let firstSnapshot = await firstOpen.snapshot()
        XCTAssertNil(firstSnapshot.readErrorMessage)

        let descriptorURL = V10StoreMigrationCoordinator.descriptorURL(
            for: sourceURL, targetSchemaVersion: 12)
        let descriptor = try JSONDecoder.latticeLens.decode(
            V10ActiveStoreDescriptor.self, from: Data(contentsOf: descriptorURL))
        let backupManifestURL = root
            .appendingPathComponent("LatticeLens-StoreBackups", isDirectory: true)
            .appendingPathComponent(descriptor.backupManifestID.uuidString, isDirectory: true)
            .appendingPathComponent("migration-manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: backupManifestURL)) as? [String: Any])
        manifest["manifestHash"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: backupManifestURL, options: .atomic)

        let blocked = LibraryStoreFactory.makeDefault(storeURLOverride: sourceURL)
        let blockedSnapshot = await blocked.snapshot()
        let reason = try XCTUnwrap(blockedSnapshot.readErrorMessage)
        XCTAssertTrue(reason.contains("recover the active migration"), reason)
        XCTAssertTrue(reason.contains("backupMismatch"), reason)
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

    @MainActor
    func testLegacyRootMigrationRepairsPreviouslyActivatedEmptyV8Placeholder() throws {
        // A prior release could leave an empty, marker-bearing V8 target after
        // failing to discover the old root family.  The next launch must
        // quarantine that placeholder and migrate the readable legacy source,
        // otherwise the UI remains permanently blank even though the source
        // library is still present.
        let root = try makeProjectLocalTestDirectory(prefix: "v8-empty-placeholder")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("LatticeLens.store")
        let activeURL = root.appendingPathComponent("LatticeLens/Library-v8.store")
        let sourceSchema = Schema(versionedSchema: LatticeLensSchemaV7.self)
        let sourceContainer = try ModelContainer(for: sourceSchema, migrationPlan: LatticeLensMigrationPlanV7.self,
                                                  configurations: ModelConfiguration(url: sourceURL))
        let author = Author(recid: 77, preferredName: "Legacy, Placeholder", nativeNames: [], bai: nil,
                            arxivCategories: ["hep-lat"], hIndex: nil, hIndexState: .qualified,
                            isTracked: false, lastSyncedAt: Date(timeIntervalSince1970: 1))
        let paper = makePaper(11)
        let snapshot = LibrarySnapshot(authors: [author.recid: author], papers: [paper.literatureID: paper],
                                       paperAuthorLinks: [PaperAuthorLink(paperID: paper.literatureID, authorRecid: author.recid, position: 0)],
                                       schemaVersion: 6)
        sourceContainer.mainContext.insert(StoredLibraryDocument(schemaVersion: 6,
                                                                 snapshotData: try JSONEncoder.latticeLens.encode(snapshot)))
        try sourceContainer.mainContext.save()

        // Simulate the bad first launch: a valid V8 marker but no domain rows.
        let activeSchema = Schema(versionedSchema: LatticeLensSchemaV8.self)
        let placeholder = try ModelContainer(for: activeSchema, configurations: ModelConfiguration(url: activeURL))
        try V8TypedStoreCodec.materialize(LibrarySnapshot(schemaVersion: 8, v3SchemaVersion: 3), in: placeholder.mainContext, sourceSchemaVersion: 8)

        try LibraryStoreFactory.recoverLegacyStoreIfNeeded(storeURL: activeURL, applicationSupportRoot: root)

        let migrated = try ModelContainer(for: activeSchema, configurations: ModelConfiguration(url: activeURL))
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<StoredV8Author>()), 1)
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<StoredV8Paper>()), 1)
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("LatticeLens/LatticeLens-StoreBackups"), includingPropertiesForKeys: nil)
        XCTAssertTrue(backups.contains { $0.lastPathComponent.hasPrefix("preexisting-empty-v8-") })
    }

    @MainActor
    func testLegacyRecoverySkipsEmptyNestedV7SourceWhenRootFamilyHasData() throws {
        // A failed staged upgrade may leave a marker-bearing but empty nested
        // V7 family next to the real pre-V7 root store.  Recovery must inspect
        // both candidates and migrate the one that actually contains domain
        // rows; path ordering alone would recreate a blank active library.
        let root = try makeProjectLocalTestDirectory(prefix: "v8-empty-nested-source")
        defer { try? FileManager.default.removeItem(at: root) }
        let nestedSourceURL = root.appendingPathComponent("LatticeLens/Library-v7.store")
        let rootSourceURL = root.appendingPathComponent("LatticeLens.store")
        let activeURL = root.appendingPathComponent("LatticeLens/Library-v8.store")

        let v7Schema = Schema(versionedSchema: LatticeLensSchemaV7.self)
        let nested = try ModelContainer(for: v7Schema, migrationPlan: LatticeLensMigrationPlanV7.self,
                                        configurations: ModelConfiguration(url: nestedSourceURL))
        nested.mainContext.insert(StoredV7StoreMarker(schemaVersion: 71, importedLegacyDocument: false))
        try nested.mainContext.save()

        let rootStore = try ModelContainer(for: v7Schema, migrationPlan: LatticeLensMigrationPlanV7.self,
                                            configurations: ModelConfiguration(url: rootSourceURL))
        let author = Author(recid: 77, preferredName: "Legacy, Root With Data", nativeNames: [], bai: nil,
                            arxivCategories: ["hep-th"], hIndex: nil, hIndexState: .qualified,
                            isTracked: false, lastSyncedAt: Date(timeIntervalSince1970: 1))
        let paper = makePaper(12)
        let snapshot = LibrarySnapshot(authors: [author.recid: author], papers: [paper.literatureID: paper],
                                       paperAuthorLinks: [PaperAuthorLink(paperID: paper.literatureID, authorRecid: author.recid, position: 0)],
                                       schemaVersion: 6)
        rootStore.mainContext.insert(StoredLibraryDocument(schemaVersion: 6,
                                                           snapshotData: try JSONEncoder.latticeLens.encode(snapshot)))
        try rootStore.mainContext.save()

        try LibraryStoreFactory.recoverLegacyStoreIfNeeded(storeURL: activeURL, applicationSupportRoot: root)

        let activeSchema = Schema(versionedSchema: LatticeLensSchemaV8.self)
        let active = try ModelContainer(for: activeSchema, configurations: ModelConfiguration(url: activeURL))
        XCTAssertEqual(try active.mainContext.fetchCount(FetchDescriptor<StoredV8Author>()), 1)
        XCTAssertEqual(try active.mainContext.fetchCount(FetchDescriptor<StoredV8Paper>()), 1)
        XCTAssertEqual(try active.mainContext.fetch(FetchDescriptor<StoredV8Author>()).first?.recid, author.recid)
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

        var titlePaper = makePaper(12)
        titlePaper.titles = [PaperTitle(value: "Fixture lattice renormalization", source: "fixture")]
        var abstractPaper = makePaper(13)
        abstractPaper.abstracts = [PaperAbstract(value: "The renormalization scale is 2 GeV.", source: "fixture")]
        let provenanceHits = V4LocalSearchIndex.bibliographicHits(
            query: "renormalization", papers: [titlePaper, abstractPaper]
        )
        XCTAssertEqual(Set(provenanceHits.map(\.source)), Set(["title", "abstract"]))
        XCTAssertEqual(Set(provenanceHits.map(\.paperID)), Set([12, 13]))
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

    @MainActor
    func testResearchBundleSchema5ImportsIntoV12TypedStagingStore() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v12-bundle-legacy-import")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("legacy-v5.latticelensbundle", isDirectory: true)
        let target = root.appendingPathComponent("restored-v12.store")
        let paper = makePaper(1805)
        let noteTime = Date(timeIntervalSince1970: 1_700_000_000)
        let note = UserNote(id: UUID(), paperID: paper.literatureID, body: "legacy bundle note",
            createdAt: noteTime, updatedAt: noteTime)
        let snapshot = LibrarySnapshot(papers: [paper.literatureID: paper], notes: [note.id: note], schemaVersion: 8)
        let manifest = try V4ResearchBundle.export(snapshot: snapshot, to: bundle)
        XCTAssertEqual(manifest.schemaVersion, V4ResearchBundle.legacySchemaVersion)

        let dryRun = try await V4ResearchBundle.restoreToNewTypedStoreV2(
            bundle, targetStoreURL: target, activeSnapshot: LibrarySnapshot())
        XCTAssertEqual(dryRun.schemaVersion, V4ResearchBundle.legacySchemaVersion)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))

        let schema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let restored = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
            configurations: ModelConfiguration(schema: schema, url: target))
        let context = restored.mainContext
        let restoredSnapshot = try V8TypedStoreCodec.snapshot(from: context)
        XCTAssertEqual(restoredSnapshot.papers[paper.literatureID]?.displayTitle, paper.displayTitle)
        XCTAssertEqual(restoredSnapshot.notes[note.id], note)
        XCTAssertTrue(try V9TypedSearchIndex.isCurrent(in: context))
        XCTAssertTrue(try context.fetch(FetchDescriptor<StoredV10CategoryProfile>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<StoredV10FormulaInventory>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<StoredV10FormulaDerivationJob>()).isEmpty)
    }

    @MainActor
    func testResearchBundleActivationUsesRelativeDescriptorAndRollbackKeepsBothStores() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v12-bundle-activation")
        defer { try? FileManager.default.removeItem(at: root) }
        let baseStore = root.appendingPathComponent("LatticeLens-v12.store")
        let priorBundle = root.appendingPathComponent("prior.latticelensbundle", isDirectory: true)
        let incomingBundle = root.appendingPathComponent("incoming.latticelensbundle", isDirectory: true)
        let priorPaper = makePaper(18_510)
        let incomingPaper = makePaper(18_511)
        _ = try V4ResearchBundle.export(
            snapshot: LibrarySnapshot(papers: [priorPaper.literatureID: priorPaper], schemaVersion: 8),
            to: priorBundle)
        _ = try await V4ResearchBundle.restoreToNewTypedStoreV2(
            priorBundle, targetStoreURL: baseStore, activeSnapshot: LibrarySnapshot())

        let incomingSnapshot = LibrarySnapshot(papers: [incomingPaper.literatureID: incomingPaper], schemaVersion: 8)
        let incomingManifest = try V4ResearchBundle.export(snapshot: incomingSnapshot, to: incomingBundle)
        let stagedURL = root.appendingPathComponent(".latticelens-bundle-stage-\(UUID().uuidString).store")
        _ = try await V4ResearchBundle.restoreToNewTypedStoreV2(
            incomingBundle, targetStoreURL: stagedURL, activeSnapshot: LibrarySnapshot(papers: [priorPaper.literatureID: priorPaper]))
        XCTAssertNil(try V4BundleActivationCoordinator.resolveActiveStoreURL(for: baseStore),
                     "completed staging is not active until the user confirms")

        let activated = try V4BundleActivationCoordinator.activate(
            stagingStoreURL: stagedURL, baseStoreURL: baseStore,
            bundleManifestHash: incomingManifest.manifestHash)
        XCTAssertEqual(activated.storeName, stagedURL.lastPathComponent)
        XCTAssertEqual(activated.previousStoreName, baseStore.lastPathComponent)
        XCTAssertEqual(try V4BundleActivationCoordinator.resolveActiveStoreURL(for: baseStore), stagedURL)

        let imported = LibraryStoreFactory.makeDefault(storeURLOverride: baseStore)
        let importedSnapshot = await imported.snapshot()
        XCTAssertEqual(importedSnapshot.papers[incomingPaper.literatureID]?.displayTitle, incomingPaper.displayTitle)

        let rolledBack = try V4BundleActivationCoordinator.rollback(for: baseStore)
        XCTAssertEqual(rolledBack.storeName, baseStore.lastPathComponent)
        XCTAssertEqual(try V4BundleActivationCoordinator.resolveActiveStoreURL(for: baseStore), baseStore)
        let prior = LibraryStoreFactory.makeDefault(storeURLOverride: baseStore)
        let priorSnapshot = await prior.snapshot()
        XCTAssertEqual(priorSnapshot.papers[priorPaper.literatureID]?.displayTitle, priorPaper.displayTitle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path),
                      "rollback changes only the pointer; both store files remain available")
    }

    @MainActor
    func testAppViewModelResearchBundleOrchestrationStaysOnSyntheticProjectStore() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v12-app-bundle-orchestration")
        defer { try? FileManager.default.removeItem(at: root) }
        let baseStoreURL = root.appendingPathComponent("LatticeLens-v12.store")
        let sourcePaper = makePaper(18_519)
        let seedBundle = root.appendingPathComponent("seed.latticelensbundle", isDirectory: true)
        _ = try V4ResearchBundle.export(
            snapshot: LibrarySnapshot(papers: [sourcePaper.literatureID: sourcePaper], schemaVersion: 8),
            to: seedBundle)
        _ = try await V4ResearchBundle.restoreToNewTypedStoreV2(
            seedBundle, targetStoreURL: baseStoreURL, activeSnapshot: LibrarySnapshot())

        let schema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
            configurations: ModelConfiguration(schema: schema, url: baseStoreURL))
        let store = V8TypedLibraryStore(modelContainer: container)

        let parentFolderURL = root.deletingLastPathComponent()
            .appendingPathComponent("must-not-be-created.store")
        let rejectedViewModel = AppViewModel(store: store, categoryProfile: CategoryProfile(),
            researchBundleBaseStoreURLForTesting: parentFolderURL)
        XCTAssertFalse(rejectedViewModel.supportsResearchBundle,
                       "the integration seam must fail closed outside the current checkout")

        let viewModel = AppViewModel(store: store,
            categoryProfile: CategoryProfile(),
            researchBundleBaseStoreURLForTesting: baseStoreURL)
        XCTAssertTrue(viewModel.supportsResearchBundle)

        let bundleURL = root.appendingPathComponent("synthetic.latticelensbundle", isDirectory: true)
        let manifest = try await viewModel.exportResearchBundle(to: bundleURL, includePDFBytes: false)
        XCTAssertEqual(manifest.schemaVersion, V4ResearchBundle.schemaVersion)
        XCTAssertFalse(manifest.includesPDFBytes)

        let preview = try await viewModel.previewResearchBundle(at: bundleURL)
        XCTAssertEqual(preview.dryRun.paperCount, 1)
        XCTAssertEqual(preview.dryRun.conflictPaperIDs, [sourcePaper.literatureID])
        XCTAssertNil(try V4BundleActivationCoordinator.resolveActiveStoreURL(for: baseStoreURL))

        try await viewModel.stageResearchBundleImport(preview)
        XCTAssertNil(try V4BundleActivationCoordinator.resolveActiveStoreURL(for: baseStoreURL),
                     "staging alone must not change the active-library descriptor")
        let stagedBeforeCancel = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".latticelens-bundle-stage-") }
        XCTAssertTrue(stagedBeforeCancel.contains { $0.hasSuffix(".store") },
                      "staging must create a store file; SQLite sidecars may also be present")

        viewModel.cancelStagedResearchBundleImport()
        XCTAssertNil(try V4BundleActivationCoordinator.resolveActiveStoreURL(for: baseStoreURL))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains { $0.hasPrefix(".latticelens-bundle-stage-") },
            "cancelling must remove the isolated staging store")

        try await viewModel.stageResearchBundleImport(preview)
        let stagedForActivation = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .first { $0.hasPrefix(".latticelens-bundle-stage-") && $0.hasSuffix(".store") }
        )
        try viewModel.activateStagedResearchBundleForNextLaunch()
        let activatedDescriptor = try XCTUnwrap(
            V4BundleActivationCoordinator.resolveActiveStoreURL(for: baseStoreURL))
        XCTAssertEqual(activatedDescriptor.lastPathComponent, stagedForActivation)
        XCTAssertEqual(viewModel.researchBundleCanRollback, true)

        try viewModel.rollbackResearchBundleActivationForNextLaunch()
        XCTAssertEqual(try V4BundleActivationCoordinator.resolveActiveStoreURL(for: baseStoreURL), baseStoreURL)
        let activeSnapshotAfterRollback = await store.snapshot()
        XCTAssertEqual(activeSnapshotAfterRollback.papers[sourcePaper.literatureID]?.displayTitle,
                       sourcePaper.displayTitle,
                       "activation and rollback are next-launch pointer changes; the running store stays intact")
        XCTAssertTrue(FileManager.default.fileExists(atPath: activatedDescriptor.path),
                      "rollback retains the imported store for recovery")
    }

    func testResearchBundlePDFBytesAreOptInHashVerifiedAndStagedWithoutOverwrite() throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v7-bundle-pdf-stage")
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfRoot = root.appendingPathComponent("pdf-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: pdfRoot, withIntermediateDirectories: true)
        let bytes = Data("synthetic PDF bytes".utf8)
        let hash = StableHash.sha256(bytes)
        let filename = "\(hash).pdf"
        try bytes.write(to: pdfRoot.appendingPathComponent(filename))
        var snapshot = LibrarySnapshot()
        snapshot.contentBlobs[hash] = ContentBlob(hash: hash, byteCount: bytes.count,
            localFilename: filename, referenceCount: 1, createdAt: Date(timeIntervalSince1970: 1_700_000_000))

        let bundle = root.appendingPathComponent("with-pdf.latticelensbundle", isDirectory: true)
        let manifest = try V4ResearchBundle.export(snapshot: snapshot, to: bundle,
            includePDFBytes: true, pdfRoot: pdfRoot)
        XCTAssertTrue(manifest.includesPDFBytes)
        XCTAssertTrue(manifest.files.contains { $0.relativePath == "pdf/\(filename)" })

        let stageURL = root.appendingPathComponent(".latticelens-bundle-pdf-stage-\(UUID().uuidString)", isDirectory: true)
        let stage = try V4ResearchBundle.stagePDFAssets(from: bundle, into: stageURL)
        XCTAssertEqual(stage.assets, [V4BundlePDFAsset(filename: filename, sha256: hash, byteCount: bytes.count)])
        let cache = root.appendingPathComponent("import-cache", isDirectory: true)
        let installed = try V4ResearchBundle.installStagedPDFAssets(stage, into: cache)
        XCTAssertEqual(installed, [cache.appendingPathComponent(filename)])
        XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent(filename)), bytes)
        XCTAssertTrue(try V4ResearchBundle.installStagedPDFAssets(stage, into: cache).isEmpty,
                      "matching content-addressed cache entries are reused")

        let conflictingCache = root.appendingPathComponent("conflicting-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: conflictingCache, withIntermediateDirectories: true)
        let conflictingFile = conflictingCache.appendingPathComponent(filename)
        let priorBytes = Data("different prior content".utf8)
        try priorBytes.write(to: conflictingFile)
        XCTAssertThrowsError(try V4ResearchBundle.installStagedPDFAssets(stage, into: conflictingCache))
        XCTAssertEqual(try Data(contentsOf: conflictingFile), priorBytes,
                       "a conflicting existing cache file must never be overwritten")

        let defaultBundle = root.appendingPathComponent("without-pdf.latticelensbundle", isDirectory: true)
        _ = try V4ResearchBundle.export(snapshot: snapshot, to: defaultBundle)
        let defaultLibrary = try JSONDecoder.latticeLens.decode(
            LibrarySnapshot.self, from: Data(contentsOf: defaultBundle.appendingPathComponent("library.json")))
        XCTAssertNil(defaultLibrary.contentBlobs[hash]?.localFilename,
                     "the default export must omit local cache paths")
        V4ResearchBundle.discardPDFStage(stage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stageURL.path))
    }

    func testResearchBundleActiveDescriptorRejectsPathTraversal() throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v7-bundle-descriptor-path")
        defer { try? FileManager.default.removeItem(at: root) }
        let baseStore = root.appendingPathComponent("LatticeLens-v12.store")
        let invalid = V4BundleActiveLibraryDescriptor(schemaVersion: V4BundleActivationCoordinator.schemaVersion,
            runID: UUID(), storeName: "../outside.store", previousStoreName: "LatticeLens-v12.store",
            bundleManifestHash: "manifest", previousBundleManifestHash: nil, activatedAt: Date())
        try JSONEncoder.latticeLens.encode(invalid).write(
            to: V4BundleActivationCoordinator.descriptorURL(for: baseStore), options: .atomic)
        XCTAssertThrowsError(try V4BundleActivationCoordinator.resolveActiveStoreURL(for: baseStore)) { error in
            guard case V4ResearchBundleError.invalidActiveLibraryDescriptor = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testResearchBundleTypedRestoreHonorsPreCancelledImportWithoutCreatingTarget() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v11-bundle-pre-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("legacy-v5.latticelensbundle", isDirectory: true)
        let target = root.appendingPathComponent("cancelled-v11.store")
        let paper = makePaper(1806)
        _ = try V4ResearchBundle.export(
            snapshot: LibrarySnapshot(papers: [paper.literatureID: paper], schemaVersion: 8),
            to: bundle)
        let sourceLibraryURL = bundle.appendingPathComponent("library.json")
        let sourceLibraryBefore = try Data(contentsOf: sourceLibraryURL)

        let restoreTask = Task { @MainActor in
            try await V4ResearchBundle.restoreToNewTypedStoreV2(
                bundle, targetStoreURL: target, activeSnapshot: LibrarySnapshot())
        }
        restoreTask.cancel()
        do {
            _ = try await restoreTask.value
            XCTFail("a cancelled Bundle restore must not publish a staging store")
        } catch is CancellationError {
            // Expected: cancellation is observed before Bundle staging begins.
        } catch {
            XCTFail("expected CancellationError, received \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                       "a pre-cancelled restore must leave no target store behind")
        XCTAssertEqual(try Data(contentsOf: sourceLibraryURL), sourceLibraryBefore,
                       "cancellation must leave the source Bundle byte-stable")
    }

    @MainActor
    func testResearchBundleTypedRestoreCancelsAfterStagingAndRemovesTargetFamily() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v11-bundle-mid-stage-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("legacy-v5.latticelensbundle", isDirectory: true)
        let target = root.appendingPathComponent("cancelled-mid-stage-v11.store")
        let papers = Dictionary(uniqueKeysWithValues: (0..<2_000).map { offset in
            let paper = makePaper(20_000 + offset)
            return (paper.literatureID, paper)
        })
        _ = try V4ResearchBundle.export(
            snapshot: LibrarySnapshot(papers: papers, schemaVersion: 8), to: bundle)
        let sourceFiles = ["library.json", "manifest.json"]
        let sourceBytesBefore = try Dictionary(uniqueKeysWithValues: sourceFiles.map { name in
            (name, try Data(contentsOf: bundle.appendingPathComponent(name)))
        })

        let restoreTask = Task { @MainActor in
            try await V4ResearchBundle.restoreToNewTypedStoreV2(
                bundle, targetStoreURL: target, activeSnapshot: LibrarySnapshot())
        }
        let targetPath = target.path
        let watcher = Task.detached(priority: .userInitiated) {
            for _ in 0..<4_000 {
                if FileManager.default.fileExists(atPath: targetPath) {
                    restoreTask.cancel()
                    return true
                }
                try? await Task.sleep(nanoseconds: 500_000)
            }
            return false
        }

        let stagingWasObserved = await watcher.value
        XCTAssertTrue(stagingWasObserved, "the cancellation must be requested only after the staging store exists")
        do {
            _ = try await restoreTask.value
            XCTFail("a cancelled in-progress Bundle restore must not publish its staging store")
        } catch is CancellationError {
            // Expected: the coordinator observes cancellation and removes its exact new target family.
        } catch {
            XCTFail("expected CancellationError, received \(error)")
        }

        for suffix in ["", "-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path + suffix),
                           "cancelled restore must remove the new SQLite family member \(suffix)")
        }
        for name in sourceFiles {
            XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent(name)), sourceBytesBefore[name],
                           "cancellation must leave source Bundle file \(name) byte-stable")
        }
    }

    @MainActor
    func testResearchBundlePostStageFailuresRemoveNewStoreFamily() async throws {
        struct InjectedPostStageFailure: Error {}
        let root = try makeProjectLocalTestDirectory(prefix: "v11-bundle-post-stage-faults")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("source.latticelensbundle", isDirectory: true)
        let schema = Schema(versionedSchema: LatticeLensSchemaV11.self)
        let sourceContainer = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV11.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let paper = makePaper(1807)
        _ = try V4ResearchBundle.exportV2(
            snapshot: LibrarySnapshot(papers: [paper.literatureID: paper], schemaVersion: 8),
            typedContext: sourceContainer.mainContext, to: bundle)
        let sourceFiles = ["library.json", "manifest.json", "v10-state.json"]
        let sourceBytesBefore = try Dictionary(uniqueKeysWithValues: sourceFiles.map { name in
            (name, try Data(contentsOf: bundle.appendingPathComponent(name)))
        })

        for checkpoint in V4BundleRestoreCheckpoint.allCases {
            let target = root.appendingPathComponent("rejected-\(checkpoint.rawValue).store")
            var injected = false
            do {
                _ = try await V4ResearchBundle.restoreToNewTypedStoreV2(
                    bundle, targetStoreURL: target, activeSnapshot: LibrarySnapshot(),
                    faultInjector: { observed in
                        guard observed == checkpoint else { return }
                        injected = true
                        throw InjectedPostStageFailure()
                    })
                XCTFail("post-stage failure at \(checkpoint.rawValue) must reject the Bundle restore")
            } catch is InjectedPostStageFailure {
                // Each checkpoint is deliberately failed after the target store has been opened.
            } catch {
                XCTFail("unexpected error at \(checkpoint.rawValue): \(error)")
            }
            XCTAssertTrue(injected, "restore did not reach \(checkpoint.rawValue)")
            for suffix in ["", "-wal", "-shm", "-journal"] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: target.path + suffix),
                               "\(checkpoint.rawValue) rejection must remove SQLite family member \(suffix)")
            }
            for name in sourceFiles {
                XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent(name)), sourceBytesBefore[name],
                               "\(checkpoint.rawValue) rejection must leave source Bundle file \(name) unchanged")
            }
        }
    }

    @MainActor
    func testV10FormulaStoreReopensAndRemovesReadyEvidencePublication() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-ready-publication-reopen")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("Library-v10.store")
        let schema = Schema(versionedSchema: LatticeLensSchemaV11.self)
        let item = FormulaInventoryItem(equationID: "eq-ready-1", label: "(1)", sourceTeX: "x=1",
            ordinal: 1, documentHash: "ready-document", evidenceID: "anchor-ready-1")
        let inventory = FormulaInventory(documentHash: "ready-document", items: [item])
        let publication = readyEvidencePublicationFixture(paperID: 1902, documentHash: inventory.documentHash,
            inventoryHash: inventory.inventoryHash, items: inventory.items)

        do {
            let container = try ModelContainer(for: schema,
                configurations: ModelConfiguration(schema: schema, url: storeURL))
            let repository = V8TypedLibraryStore(modelContainer: container)
            try await repository.saveReadyEvidenceInsightPublication(publication)
            let run = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<StoredV10AnalysisRun>()).first)
            XCTAssertEqual(run.workflowKind, "evidence_insight")
            XCTAssertEqual(run.phase, "ready_to_publish")
            XCTAssertEqual(run.inventoryHash, inventory.inventoryHash)
            XCTAssertEqual(run.payloadHash, StableHash.sha256(run.payload))
        }

        let reopened = try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, url: storeURL))
        let repository = V8TypedLibraryStore(modelContainer: reopened)
        let reopenedPublication = try await repository.readyEvidenceInsightPublication(cacheKey: publication.context.cacheKey)
        XCTAssertEqual(reopenedPublication, publication,
                       "the completed artifact and its source/model context survive a SwiftData reopen")
        try await repository.removeReadyEvidenceInsightPublication(cacheKey: publication.context.cacheKey)
        let removedPublication = try await repository.readyEvidenceInsightPublication(cacheKey: publication.context.cacheKey)
        XCTAssertNil(removedPublication)
        XCTAssertTrue(try reopened.mainContext.fetch(FetchDescriptor<StoredV10AnalysisRun>()).isEmpty)
    }

    @MainActor
    func testResearchBundleV10RoundTripsCategoryFormulaInventoryAndJobCheckpoint() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-bundle-roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let sourceContainer = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
                                                 configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = sourceContainer.mainContext
        let paper = makePaper(1901)
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000)
        let profile = CategoryProfile(categories: [.hepLat, .hepPh], revision: 17)
        context.insert(StoredV10CategoryProfile(revision: profile.revision,
            categoriesData: try JSONEncoder.latticeLens.encode(profile.rawValues), updatedAt: timestamp))

        let firstItem = FormulaInventoryItem(equationID: "eq-1901-1", label: "(1)", sourceTeX: "x=1",
            ordinal: 1, documentHash: "document-hash", evidenceID: "anchor-1901-1")
        let secondItem = FormulaInventoryItem(equationID: "eq-1901-2", label: "(2)", sourceTeX: "y=2",
            ordinal: 2, documentHash: "document-hash", evidenceID: "anchor-1901-2")
        let inventory = FormulaInventory(documentHash: "document-hash", items: [firstItem, secondItem])
        let inventoryData = try JSONEncoder.latticeLens.encode(inventory)
        context.insert(StoredV10FormulaInventory(id: "1901:document-hash", paperID: paper.literatureID,
            documentID: "1901:document-hash", documentHash: inventory.documentHash,
            inventoryHash: inventory.inventoryHash, parserVersion: inventory.parserVersion,
            status: "complete", payload: inventoryData, updatedAt: timestamp))
        for item in [firstItem, secondItem] {
            context.insert(StoredV10FormulaInventoryItem(id: "1901:document-hash:\(item.equationID)",
                paperID: paper.literatureID, documentID: "1901:document-hash", documentHash: inventory.documentHash,
                inventoryHash: inventory.inventoryHash, equationID: item.equationID, label: item.label,
                ordinal: item.ordinal, sourceByteStart: item.sourceByteStart, sourceByteEnd: item.sourceByteEnd,
                sourceTeXHash: item.normalizedTeXHash, anchorID: item.evidenceID, status: "indexed",
                payload: try JSONEncoder.latticeLens.encode(item)))
        }

        let anchor1Quote = "编号公式 (1)\n$$x=1$$"
        let anchor2Quote = "编号公式 (2)\n$$y=2$$"
        let anchor1 = EvidenceAnchor(id: "anchor-1901-1", paperID: paper.literatureID, sourceKind: .abstract,
            page: nil, section: nil, quote: anchor1Quote, quoteHash: StableHash.sha256(anchor1Quote), figureKey: nil)
        let anchor2 = EvidenceAnchor(id: "anchor-1901-2", paperID: paper.literatureID, sourceKind: .abstract,
            page: nil, section: nil, quote: anchor2Quote, quoteHash: StableHash.sha256(anchor2Quote), figureKey: nil)
        let firstStep = FormulaDerivationStep(stepID: "eq-1901-1:step:1", ordinal: 1, textZH: "保留第一個等式",
            beforeTeX: firstItem.sourceTeX, afterTeX: firstItem.sourceTeX,
            ruleOrAssumption: "fixture rule", evidenceAnchorIDs: [anchor1.id],
            sourceDocumentHashes: [inventory.documentHash], epistemicStatus: .inference)
        let secondStep = FormulaDerivationStep(stepID: "eq-1901-2:step:1", ordinal: 1, textZH: "保留第二個等式",
            beforeTeX: secondItem.sourceTeX, afterTeX: secondItem.sourceTeX,
            ruleOrAssumption: "fixture rule", evidenceAnchorIDs: [anchor2.id],
            sourceDocumentHashes: [inventory.documentHash], epistemicStatus: .inference)
        var firstSegmentState = FormulaDerivationSegmentCheckpoint(
            equationID: firstItem.equationID, sourceTeX: firstItem.sourceTeX)
        try firstSegmentState.appendSegment(index: 0, steps: [firstStep], isFinal: true,
            continuationSummary: nil, conclusionZH: "第一個公式保留其原文定义。",
            requestID: "19010000-0000-4000-8000-000000000011",
            requestPayloadHash: String(repeating: "a", count: 64),
            responseHash: String(repeating: "b", count: 64), receivedBytes: 64,
            receivedCharacters: 48, firstContentAt: timestamp,
            lastContentAt: timestamp.addingTimeInterval(1))
        var secondSegmentState = FormulaDerivationSegmentCheckpoint(
            equationID: secondItem.equationID, sourceTeX: secondItem.sourceTeX)
        try secondSegmentState.appendSegment(index: 0, steps: [secondStep], isFinal: true,
            continuationSummary: nil, conclusionZH: "第二個公式保留其原文定义。",
            requestID: "19010000-0000-4000-8000-000000000012",
            requestPayloadHash: String(repeating: "c", count: 64),
            responseHash: String(repeating: "d", count: 64), receivedBytes: 64,
            receivedCharacters: 48, firstContentAt: timestamp,
            lastContentAt: timestamp.addingTimeInterval(1))
        let firstClaim = EvidenceClaim(textZH: "第一個公式", epistemicStatus: .direct, evidenceIDs: [anchor1.id],
            formulaTeX: firstItem.sourceTeX, equationID: firstItem.equationID, formulaDerivationSteps: [firstStep],
            conclusionZH: "第一個公式保留其原文定义。",
            derivationSegmentProvenanceHash: try firstSegmentState.provenanceHash())
        let secondClaim = EvidenceClaim(textZH: "第二個公式", epistemicStatus: .direct, evidenceIDs: [anchor2.id],
            formulaTeX: secondItem.sourceTeX, equationID: secondItem.equationID, formulaDerivationSteps: [secondStep],
            conclusionZH: "第二個公式保留其原文定义。",
            derivationSegmentProvenanceHash: try secondSegmentState.provenanceHash())
        let requestID = "19010000-0000-4000-8000-000000000001"
        let batch = FormulaBatchCheckpoint(jobID: "bundle-job-1901", batchIndex: 0, batchTotal: 1,
            equationIDs: [firstItem.equationID, secondItem.equationID], payloadHash: "batch-payload-hash",
            requestID: requestID, attemptCount: 1, receivedBytes: 420, receivedCharacters: 400,
            status: .completed, updatedAt: timestamp)
        let job = FormulaDerivationJob(jobID: "bundle-job-1901", paperID: paper.literatureID,
            documentHash: inventory.documentHash, inventoryHash: inventory.inventoryHash,
            equationIDs: [firstItem.equationID, secondItem.equationID], batchSize: 2, state: .complete, batches: [batch],
            startedAt: timestamp, updatedAt: timestamp)
        let checkpoint = FormulaDerivationCheckpoint(job: job, completedClaimsByBatch: [0: [firstClaim, secondClaim]],
            derivationSegmentsByEquation: [firstItem.equationID: firstSegmentState,
                                           secondItem.equationID: secondSegmentState],
            promptVersion: FormulaDerivationPrompt.version, schemaVersion: PaperInsightV2Validator.schemaVersion,
            contextFingerprint: "fixture-profile", updatedAt: timestamp)
        context.insert(StoredV8EvidenceAnchor(anchor1))
        context.insert(StoredV8EvidenceAnchor(anchor2))
        try context.save()
        let expectedReport = FormulaCoverageValidator.report(inventory: inventory,
            claims: [firstClaim, secondClaim], anchors: [anchor1.id: anchor1, anchor2.id: anchor2])
        try await V10FormulaJobStore(modelContainer: sourceContainer)
            .saveFormulaJobWithValidation(checkpoint, report: expectedReport)
        let readyPublication = readyEvidencePublicationFixture(
            paperID: paper.literatureID, documentHash: inventory.documentHash,
            inventoryHash: inventory.inventoryHash, items: inventory.items,
            formulaClaims: [firstClaim, secondClaim], createdAt: timestamp
        )
        try await V10FormulaJobStore(modelContainer: sourceContainer)
            .saveReadyEvidenceInsightPublication(readyPublication)

        let bundle = root.appendingPathComponent("library-v10.latticelensbundle", isDirectory: true)
        let target = root.appendingPathComponent("restored-v10.store")
        var snapshot = LibrarySnapshot(papers: [paper.literatureID: paper], schemaVersion: 10)
        snapshot.evidenceAnchors = [anchor1.id: anchor1, anchor2.id: anchor2]
        let manifest = try V4ResearchBundle.exportV2(snapshot: snapshot, typedContext: context, to: bundle)
        XCTAssertEqual(manifest.schemaVersion, 7)
        XCTAssertEqual(manifest.recordCounts["formulaInventories"], 1)
        XCTAssertEqual(manifest.recordCounts["formulaJobs"], 1)
        XCTAssertEqual(manifest.recordCounts["formulaClaims"], 2)
        XCTAssertEqual(manifest.recordCounts["formulaAnalysisRuns"], 1)
        XCTAssertEqual(manifest.recordCounts["analysisAttempts"], 1)
        XCTAssertEqual(manifest.recordCounts["formulaValidationReports"], 1)
        XCTAssertEqual(manifest.recordCounts["readyEvidenceInsightPublications"], 1)
        XCTAssertEqual(try V4ResearchBundle.verify(bundle).manifestHash, manifest.manifestHash)

        let restoredDryRun = try await V4ResearchBundle.restoreToNewTypedStoreV2(
            bundle, targetStoreURL: target, activeSnapshot: LibrarySnapshot())
        XCTAssertEqual(restoredDryRun.paperCount, 1)
        let restored = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
                                          configurations: ModelConfiguration(schema: schema, url: target))
        let restoredContext = restored.mainContext
        let restoredProfile = try XCTUnwrap(try restoredContext.fetch(FetchDescriptor<StoredV10CategoryProfile>()).first)
        XCTAssertEqual(try JSONDecoder.latticeLens.decode([String].self, from: restoredProfile.categoriesData),
                       profile.rawValues)
        let restoredInventoryRow = try XCTUnwrap(try restoredContext.fetch(FetchDescriptor<StoredV10FormulaInventory>()).first)
        XCTAssertEqual(try JSONDecoder.latticeLens.decode(FormulaInventory.self, from: restoredInventoryRow.payload), inventory)
        let restoredJob = try await V10FormulaJobStore(modelContainer: restored).formulaJob(id: job.jobID)
        XCTAssertEqual(restoredJob, checkpoint)
        XCTAssertEqual(restoredJob?.job.batches.first?.status, .completed)
        XCTAssertEqual(restoredJob?.completedClaimsByBatch[0], [firstClaim, secondClaim])
        let restoredRun = try XCTUnwrap(try restoredContext.fetch(FetchDescriptor<StoredV10AnalysisRun>())
            .first(where: { $0.id == "formula:\(job.jobID)" }))
        XCTAssertEqual(restoredRun.workflowKind, "formula_derivation")
        XCTAssertEqual(restoredRun.phase, FormulaJobState.complete.rawValue)
        XCTAssertEqual(restoredRun.sourceDocumentHashesData,
                       try JSONEncoder.latticeLens.encode([job.documentHash]))
        XCTAssertTrue(restoredRun.payload.isEmpty, "formula telemetry must not include raw model payloads")
        let restoredAttempt = try XCTUnwrap(try restoredContext.fetch(FetchDescriptor<StoredV10AnalysisAttempt>())
            .first(where: { $0.runID == "formula:\(job.jobID)" }))
        XCTAssertEqual(restoredAttempt.requestID, requestID)
        XCTAssertEqual(restoredAttempt.attempt, 1)
        XCTAssertEqual(restoredAttempt.status, FormulaBatchStatus.completed.rawValue)
        XCTAssertEqual(restoredAttempt.receivedBytes, 420)
        XCTAssertEqual(restoredAttempt.receivedCharacters, 400)
        let restoredReportRow = try XCTUnwrap(try restoredContext.fetch(FetchDescriptor<StoredV10FormulaValidationReport>()).first)
        XCTAssertEqual(try JSONDecoder.latticeLens.decode(FormulaCoverageReport.self, from: restoredReportRow.payload), expectedReport)
        let restoredReport = try await V10FormulaJobStore(modelContainer: restored).formulaValidationReport(jobID: job.jobID)
        XCTAssertEqual(restoredReport, expectedReport)
        let restoredPublication = try await V10FormulaJobStore(modelContainer: restored)
            .readyEvidenceInsightPublication(cacheKey: readyPublication.context.cacheKey)
        XCTAssertEqual(restoredPublication, readyPublication)
        let restoredSteps = try restoredContext.fetch(FetchDescriptor<StoredV10FormulaDerivationStep>())
            .sorted { $0.equationID < $1.equationID }
        XCTAssertEqual(restoredSteps.count, 2)
        XCTAssertEqual(restoredSteps.map(\.ordinal), [0, 0], "each formula's step ordinal starts independently")
        XCTAssertEqual(restoredSteps.map(\.id), ["bundle-job-1901:eq-1901-1:0", "bundle-job-1901:eq-1901-2:0"])

        let legacyBundle = root.appendingPathComponent("legacy-validator-v2.latticelensbundle", isDirectory: true)
        try FileManager.default.copyItem(at: bundle, to: legacyBundle)
        let legacyStateURL = legacyBundle.appendingPathComponent("v10-state.json")
        var legacyState = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: legacyStateURL)) as? [String: Any]
        )
        var legacyJobs = try XCTUnwrap(legacyState["formulaJobs"] as? [[String: Any]])
        var legacyJob = try XCTUnwrap(legacyJobs.first)
        var legacyCheckpoint = try XCTUnwrap(legacyJob["checkpoint"] as? [String: Any])
        legacyCheckpoint["promptVersion"] = FormulaDerivationPrompt.legacyTypedStepVersion
        legacyJob["checkpoint"] = legacyCheckpoint
        legacyJobs[0] = legacyJob
        legacyState["formulaJobs"] = legacyJobs
        var legacyRuns = try XCTUnwrap(legacyState["formulaAnalysisRuns"] as? [[String: Any]])
        var legacyRun = try XCTUnwrap(legacyRuns.first)
        legacyRun["promptVersion"] = FormulaDerivationPrompt.legacyTypedStepVersion
        legacyRuns[0] = legacyRun
        legacyState["formulaAnalysisRuns"] = legacyRuns
        var legacyReports = try XCTUnwrap(legacyState["formulaValidationReports"] as? [[String: Any]])
        var legacyReport = try XCTUnwrap(legacyReports.first)
        var legacyReportPayload = try XCTUnwrap(legacyReport["report"] as? [String: Any])
        for key in ["derivationIncompleteEquationIDs", "structuralNeedsManualEquationIDs",
                    "structuralRejectedEquationIDs", "physicsNeedsManualEquationIDs"] {
            legacyReportPayload.removeValue(forKey: key)
        }
        let legacyReportData = try JSONSerialization.data(withJSONObject: legacyReportPayload, options: [.sortedKeys])
        let decodedLegacyReport = try JSONDecoder.latticeLens.decode(FormulaCoverageReport.self, from: legacyReportData)
        legacyReport["report"] = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder.latticeLens.encode(decodedLegacyReport)) as? [String: Any]
        )
        legacyReport["payloadHash"] = StableHash.sha256(try JSONEncoder.latticeLens.encode(decodedLegacyReport))
        legacyReport["id"] = "\(job.jobID):\(FormulaCoverageValidator.legacyVersion)"
        legacyReport["validatorVersion"] = FormulaCoverageValidator.legacyVersion
        legacyReport["status"] = "complete"
        legacyReports[0] = legacyReport
        legacyState["formulaValidationReports"] = legacyReports
        let legacyStateData = try JSONSerialization.data(withJSONObject: legacyState, options: [.sortedKeys])
        try legacyStateData.write(to: legacyStateURL, options: .atomic)
        let legacyManifest = try JSONDecoder.latticeLens.decode(V4BundleManifest.self,
            from: Data(contentsOf: legacyBundle.appendingPathComponent("manifest.json")))
        var legacyFiles = [String: Data]()
        for file in legacyManifest.files {
            let url = legacyBundle.appendingPathComponent(file.relativePath)
            legacyFiles[file.relativePath] = file.relativePath == "v10-state.json"
                ? legacyStateData : try Data(contentsOf: url)
        }
        let rehashedLegacyManifest = V4BundleManifest.make(
            schemaVersion: legacyManifest.schemaVersion, files: legacyFiles,
            recordCounts: legacyManifest.recordCounts, includesPDFBytes: legacyManifest.includesPDFBytes,
            appVersion: legacyManifest.appVersion, createdAt: legacyManifest.createdAt)
        try JSONEncoder.latticeLens.encode(rehashedLegacyManifest)
            .write(to: legacyBundle.appendingPathComponent("manifest.json"), options: .atomic)
        let legacyTarget = root.appendingPathComponent("legacy-validator-v2-restored.store")
        _ = try await V4ResearchBundle.restoreToNewTypedStoreV2(
            legacyBundle, targetStoreURL: legacyTarget, activeSnapshot: LibrarySnapshot())
        let legacyContainer = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
            configurations: ModelConfiguration(schema: schema, url: legacyTarget))
        let legacyStore = V10FormulaJobStore(modelContainer: legacyContainer)
        let legacyJobState = try await legacyStore.formulaJob(id: job.jobID)
        XCTAssertEqual(legacyJobState?.job.state, .incomplete,
                       "a superseded validator receipt must not keep an old job green")
        XCTAssertEqual(legacyJobState?.completedClaimsByBatch[0]?.count, 2,
                       "legacy claims remain readable even when their completion proof is stale")
        let staleLegacyReport = try XCTUnwrap(legacyContainer.mainContext
            .fetch(FetchDescriptor<StoredV10FormulaValidationReport>())
            .first(where: { $0.validatorVersion == FormulaCoverageValidator.legacyVersion }))
        XCTAssertEqual(staleLegacyReport.status, "stale")
        let legacyRunRow = try XCTUnwrap(legacyContainer.mainContext
            .fetch(FetchDescriptor<StoredV10AnalysisRun>())
            .first(where: { $0.id == "formula:\(job.jobID)" }))
        XCTAssertEqual(legacyRunRow.phase, FormulaJobState.incomplete.rawValue)
        let currentLegacyJobReport = try await legacyStore.formulaValidationReport(jobID: job.jobID)
        XCTAssertNil(currentLegacyJobReport)

        do {
            _ = try await V4ResearchBundle.restoreToNewTypedStoreV2(
                bundle, targetStoreURL: target, activeSnapshot: LibrarySnapshot())
            XCTFail("V10 typed restore must refuse an existing target")
        } catch V4ResearchBundleError.activeTargetExists {
            // A failed second import cannot replace the already-restored store.
        }

        let rejectedBundle = root.appendingPathComponent("tampered-v10-telemetry.latticelensbundle", isDirectory: true)
        _ = try V4ResearchBundle.exportV2(snapshot: snapshot, typedContext: context, to: rejectedBundle)
        let rejectedStateURL = rejectedBundle.appendingPathComponent("v10-state.json")
        var rejectedState = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: rejectedStateURL)) as? [String: Any])
        var reportRows = try XCTUnwrap(rejectedState["formulaValidationReports"] as? [[String: Any]])
        var reportRow = try XCTUnwrap(reportRows.first)
        var reportPayload = try XCTUnwrap(reportRow["report"] as? [String: Any])
        reportPayload["claimHash"] = "tampered-claim-hash"
        reportRow["report"] = reportPayload
        reportRows[0] = reportRow
        rejectedState["formulaValidationReports"] = reportRows
        let rejectedStateData = try JSONSerialization.data(withJSONObject: rejectedState, options: [.sortedKeys])
        try rejectedStateData.write(to: rejectedStateURL, options: .atomic)
        let rejectedManifestURL = rejectedBundle.appendingPathComponent("manifest.json")
        let rejectedManifest = try JSONDecoder.latticeLens.decode(V4BundleManifest.self, from: Data(contentsOf: rejectedManifestURL))
        var rejectedBundleFiles = [String: Data]()
        for file in rejectedManifest.files {
            let url = rejectedBundle.appendingPathComponent(file.relativePath)
            rejectedBundleFiles[file.relativePath] = file.relativePath == "v10-state.json"
                ? rejectedStateData : try Data(contentsOf: url)
        }
        let rehashedRejectedManifest = V4BundleManifest.make(
            schemaVersion: rejectedManifest.schemaVersion, files: rejectedBundleFiles,
            recordCounts: rejectedManifest.recordCounts, includesPDFBytes: rejectedManifest.includesPDFBytes,
            appVersion: rejectedManifest.appVersion, createdAt: rejectedManifest.createdAt)
        try JSONEncoder.latticeLens.encode(rehashedRejectedManifest)
            .write(to: rejectedManifestURL, options: .atomic)
        let rejectedTarget = root.appendingPathComponent("rejected-v10.store")
        do {
            _ = try await V4ResearchBundle.restoreToNewTypedStoreV2(
                rejectedBundle, targetStoreURL: rejectedTarget, activeSnapshot: LibrarySnapshot())
            XCTFail("semantic report tampering must be rejected before a staging store is created")
        } catch V4ResearchBundleError.malformedTypedState(_) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedTarget.path))
        }

        try await V10FormulaJobStore(modelContainer: sourceContainer)
            .removeReadyEvidenceInsightPublication(cacheKey: readyPublication.context.cacheKey)
        let oldSchema6Bundle = root.appendingPathComponent("old-schema6.latticelensbundle", isDirectory: true)
        let oldManifest = try V4ResearchBundle.exportV2(snapshot: snapshot, typedContext: context, to: oldSchema6Bundle)
        XCTAssertNil(oldManifest.recordCounts["readyEvidenceInsightPublications"],
                     "empty additive state must not introduce a new zero-count manifest key")
        let stateURL = oldSchema6Bundle.appendingPathComponent("v10-state.json")
        var oldStateObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        for key in ["readyEvidenceInsightPublications", "formulaAnalysisRuns", "analysisAttempts", "formulaValidationReports"] {
            oldStateObject.removeValue(forKey: key)
        }
        let oldStateData = try JSONSerialization.data(withJSONObject: oldStateObject, options: [.sortedKeys])
        try oldStateData.write(to: stateURL, options: .atomic)
        var oldBundleFiles = [String: Data]()
        for file in oldManifest.files {
            let url = oldSchema6Bundle.appendingPathComponent(file.relativePath)
            oldBundleFiles[file.relativePath] = file.relativePath == "v10-state.json"
                ? oldStateData : try Data(contentsOf: url)
        }
        var oldRecordCounts = oldManifest.recordCounts
        for key in ["readyEvidenceInsightPublications", "formulaAnalysisRuns", "analysisAttempts", "formulaValidationReports"] {
            oldRecordCounts.removeValue(forKey: key)
        }
        let compatibleOldManifest = V4BundleManifest.make(
            schemaVersion: V4ResearchBundle.firstTypedSchemaVersion, files: oldBundleFiles,
            recordCounts: oldRecordCounts, includesPDFBytes: oldManifest.includesPDFBytes,
            appVersion: oldManifest.appVersion, createdAt: oldManifest.createdAt
        )
        try JSONEncoder.latticeLens.encode(compatibleOldManifest)
            .write(to: oldSchema6Bundle.appendingPathComponent("manifest.json"), options: .atomic)
        XCTAssertEqual(try V4ResearchBundle.verify(oldSchema6Bundle).schemaVersion,
                       V4ResearchBundle.firstTypedSchemaVersion)
        let oldStateTarget = root.appendingPathComponent("old-schema6-restored.store")
        _ = try await V4ResearchBundle.restoreToNewTypedStoreV2(
            oldSchema6Bundle, targetStoreURL: oldStateTarget, activeSnapshot: LibrarySnapshot()
        )
        let oldStateContainer = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
            configurations: ModelConfiguration(schema: schema, url: oldStateTarget))
        XCTAssertTrue(try oldStateContainer.mainContext.fetch(FetchDescriptor<StoredV10AnalysisRun>()).isEmpty,
                      "a schema-6 state without the additive field defaults to an empty publication list")
    }

    @MainActor
    func testResearchBundleSchema7OmitsEmptyAuditRecordCounts() throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v10-bundle-empty-audit-counts")
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let bundle = root.appendingPathComponent("empty-audit.latticelensbundle", isDirectory: true)

        let manifest = try V4ResearchBundle.exportV2(snapshot: LibrarySnapshot(),
            typedContext: container.mainContext, to: bundle)

        XCTAssertEqual(manifest.schemaVersion, 7)
        XCTAssertNil(manifest.recordCounts["formulaAnalysisRuns"])
        XCTAssertNil(manifest.recordCounts["analysisAttempts"])
        XCTAssertNil(manifest.recordCounts["formulaValidationReports"])
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

    /// Exercise the workbench against the current disk-backed schema rather
    /// than only an in-memory V8 context. Successful Radar, Compare, Notebook,
    /// and Search rows must survive a reopen; a rejected Compare proposal must
    /// leave the previously committed matrix unchanged.
    @MainActor
    func testV11WorkbenchRowsSurviveRelaunchAndRejectedCompareKeepsPriorMatrix() async throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v11-workbench-rows")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("library-v11.store")
        let schema = Schema(versionedSchema: LatticeLensSchemaV11.self)
        let firstPaper = makePaper(3411)
        var secondPaper = makePaper(3412)
        secondPaper.titles = [PaperTitle(value: "RareScale proton structure", source: "fixture")]
        let firstAnchor = EvidenceAnchor(id: "abstract:3411:setup", paperID: firstPaper.literatureID,
            sourceKind: .abstract, page: nil, section: "Setup", quote: "We use a=0.09 fm.",
            quoteHash: StableHash.sha256("We use a=0.09 fm."), figureKey: nil)
        let secondAnchor = EvidenceAnchor(id: "abstract:3411:tsep", paperID: firstPaper.literatureID,
            sourceKind: .abstract, page: nil, section: "Correlator", quote: "The source-sink separation is 1.0 fm.",
            quoteHash: StableHash.sha256("The source-sink separation is 1.0 fm."), figureKey: nil)
        let initialSnapshot = LibrarySnapshot(
            papers: [firstPaper.literatureID: firstPaper, secondPaper.literatureID: secondPaper],
            evidenceAnchors: [firstAnchor.id: firstAnchor, secondAnchor.id: secondAnchor], schemaVersion: 8)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let radar = RadarEvent(id: UUID(), paperID: firstPaper.literatureID, authorRecids: [],
            eventKind: .fieldModified, beforeHash: "before", afterHash: "after",
            changedFields: ["citationCount"], syncBatchID: UUID(), observedAt: now,
            sourceURL: URL(string: "https://fixture.invalid/radar")!, isAcknowledged: false)
        let workspaceID = UUID()
        let workspace = PaperWorkspace(id: workspaceID, name: "typed compare", createdAt: now,
            updatedAt: now, sortOrder: [firstPaper.literatureID, secondPaper.literatureID],
            note: "fixture", frozenExportHash: nil)
        let contract = PhysicsContract(id: UUID(), workspaceID: workspaceID,
            rowKeys: ["lattice_spacing"], createdAt: now, updatedAt: now)
        let committedCells = workspace.sortOrder.map { paperID in
            PhysicsContractCell(id: UUID(), workspaceID: workspaceID, rowKey: "lattice_spacing",
                paperID: paperID, value: nil, unit: nil, status: .missing, evidenceAnchorIDs: [],
                extractionVersion: "v11-workbench-fixture", sourceDocumentHash: nil, updatedAt: now)
        }
        let notebookID = UUID()

        do {
            let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV11.self,
                configurations: ModelConfiguration(schema: schema, url: storeURL))
            try V8TypedStoreCodec.materialize(initialSnapshot, in: container.mainContext, sourceSchemaVersion: 8)
            try V9TypedSearchIndex.rebuild(in: container.mainContext, at: now)
            let store = V8TypedLibraryStore(modelContainer: container)
            let service = V3WorkbenchService(store: store)

            try await store.applyV3(.saveRadarEvent(radar))
            try await service.acknowledgeRadarEvent(radar.id)
            try await store.applyV3(.saveWorkspace(workspace))
            for (index, paperID) in workspace.sortOrder.enumerated() {
                try await store.applyV3(.saveWorkspaceLink(WorkspacePaperLink(
                    workspaceID: workspaceID, paperID: paperID, addedAt: now, sortIndex: index)))
            }
            try await store.applyV3(.savePhysicsContract(contract))
            try await service.replacePhysicsMatrix(workspaceID: workspaceID, proposed: committedCells)

            let entry = try await service.saveNotebookEntry(id: notebookID, paperID: firstPaper.literatureID,
                title: "tsep and scale", body: "Keep both source anchors in order.",
                anchorIDs: [firstAnchor.id, secondAnchor.id])
            XCTAssertEqual(entry.id, notebookID)

            var rejectedCells = committedCells
            rejectedCells[0].value = "0.09"
            rejectedCells[0].unit = "fm"
            do {
                try await service.replacePhysicsMatrix(workspaceID: workspaceID, proposed: rejectedCells)
                XCTFail("a missing Compare cell cannot carry an unsupported value")
            } catch V4LocalError.invalidEvidence(_) {
                // The validation rejection must happen before the typed store mutation.
            }

            let committedSnapshot = await store.snapshot()
            XCTAssertEqual(committedSnapshot.physicsContractCells,
                           Dictionary(uniqueKeysWithValues: committedCells.map { ($0.id, $0) }))
            XCTAssertTrue(committedSnapshot.radarEvents[radar.id]?.isAcknowledged == true)
            XCTAssertEqual(committedSnapshot.notebookAnchorLinks
                .filter { $0.entryID == notebookID }
                .sorted { $0.sortIndex < $1.sortIndex }
                .map(\.anchorID), [firstAnchor.id, secondAnchor.id])
            let committedSearch = await store.searchPapers("RareScale", limit: 5)
            XCTAssertEqual(committedSearch.map(\.literatureID), [secondPaper.literatureID])
        }

        let reopened = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV11.self,
            configurations: ModelConfiguration(schema: schema, url: storeURL))
        let reopenedStore = V8TypedLibraryStore(modelContainer: reopened)
        let reopenedSnapshot = await reopenedStore.snapshot()
        XCTAssertTrue(reopenedSnapshot.radarEvents[radar.id]?.isAcknowledged == true)
        XCTAssertEqual(reopenedSnapshot.workspaces[workspaceID], workspace)
        XCTAssertEqual(reopenedSnapshot.workspacePaperLinks.count, 2)
        XCTAssertEqual(reopenedSnapshot.physicsContractCells,
                       Dictionary(uniqueKeysWithValues: committedCells.map { ($0.id, $0) }))
        XCTAssertEqual(reopenedSnapshot.notebookEntries[notebookID]?.title, "tsep and scale")
        XCTAssertEqual(reopenedSnapshot.notebookAnchorLinks
            .filter { $0.entryID == notebookID }
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(\.anchorID), [firstAnchor.id, secondAnchor.id])
        let reopenedSearch = await reopenedStore.searchPapers("RareScale", limit: 5)
        XCTAssertEqual(reopenedSearch.map(\.literatureID), [secondPaper.literatureID])
        XCTAssertTrue(try V9TypedSearchIndex.isCurrent(in: reopened.mainContext))
        XCTAssertGreaterThan(try reopened.mainContext.fetchCount(FetchDescriptor<StoredV9SearchToken>()), 0)
        XCTAssertGreaterThan(try reopened.mainContext.fetchCount(FetchDescriptor<StoredV9PaperSearchTerm>()), 0)
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

    func testStoreBackupTreatsAbsentSidecarsAsOptionalButRejectsMissingRecordedSidecars() throws {
        let root = try makeProjectLocalTestDirectory(prefix: "v4-sidecar-absence")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default

        let mainOnlyStore = root.appendingPathComponent("main-only.store")
        try Data("main-only-store".utf8).write(to: mainOnlyStore, options: .atomic)
        let mainOnlyBackupRoot = root.appendingPathComponent("main-only-backups", isDirectory: true)
        let mainOnlyManifest = try V4StoreBackupCoordinator.createBackup(
            source: mainOnlyStore, destinationRoot: mainOnlyBackupRoot, schemaVersion: 10)
        XCTAssertEqual(mainOnlyManifest.files.map(\.relativePath), ["main-only.store"],
                       "sidecars absent at the quiesced source are not invented in the backup")
        XCTAssertTrue(try V4StoreBackupCoordinator.verify(mainOnlyManifest, in: mainOnlyBackupRoot))

        for missingSuffix in ["-wal", "-shm"] {
            let store = root.appendingPathComponent("with-sidecars\(missingSuffix).store")
            try Data("main".utf8).write(to: store, options: .atomic)
            for suffix in ["-wal", "-shm"] {
                try Data("\(suffix)-bytes".utf8)
                    .write(to: URL(fileURLWithPath: store.path + suffix), options: .atomic)
            }
            let backupRoot = root.appendingPathComponent("backups\(missingSuffix)", isDirectory: true)
            let manifest = try V4StoreBackupCoordinator.createBackup(
                source: store, destinationRoot: backupRoot, schemaVersion: 10)
            let missingBackupMember = backupRoot.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
                .appendingPathComponent(store.lastPathComponent + missingSuffix)
            try fileManager.removeItem(at: missingBackupMember)

            XCTAssertFalse(try V4StoreBackupCoordinator.verify(manifest, in: backupRoot),
                           "a sidecar listed in the frozen manifest is required even though sidecars are optional at source")
            let restoreTarget = root.appendingPathComponent("restore-rejected\(missingSuffix)", isDirectory: true)
            XCTAssertThrowsError(try V4StoreBackupCoordinator.restore(
                manifest, from: backupRoot, to: restoreTarget))
            XCTAssertFalse(fileManager.fileExists(atPath: restoreTarget.path),
                           "a failed family verification must not create a partial restore target")
        }
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

    func testEvidenceRequestBudgetsAreFiniteAndKeepTheLongJobBoundarySeparate() {
        XCTAssertEqual(V4AnalysisTimeouts.evidence, V4AnalysisTimeouts.default)
        XCTAssertTrue([V4AnalysisTimeouts.evidence.connect, V4AnalysisTimeouts.evidence.firstContent,
                       V4AnalysisTimeouts.evidence.idle, V4AnalysisTimeouts.evidence.hard].allSatisfy(\.isFinite))
    }

    func testAnalysisRequestRejectsNonFiniteOrNonPositiveBudgetsBeforeStartingTransport() async {
        let invalidBudgets = [
            V4AnalysisTimeouts(connect: .infinity, firstContent: 1, idle: 1, hard: 5),
            V4AnalysisTimeouts(connect: 1, firstContent: .infinity, idle: 1, hard: 5),
            V4AnalysisTimeouts(connect: 1, firstContent: 1, idle: .infinity, hard: 5),
            V4AnalysisTimeouts(connect: 1, firstContent: 1, idle: 1, hard: .infinity),
            V4AnalysisTimeouts(connect: 0, firstContent: 1, idle: 1, hard: 5)
        ]

        for timeouts in invalidBudgets {
            let invocations = V4DeadlineInvocationCounter()
            do {
                _ = try await V4AnalysisDeadlineEnforcer.perform(
                    timeouts: timeouts,
                    maximumResponseBytes: 1_024,
                    onTransportState: { _ in },
                    onDelta: { _ in }
                ) { _, _ in
                    await invocations.increment()
                    return "{}"
                }
                XCTFail("invalid per-request timeout configuration must fail before transport starts")
            } catch {
                XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("timeout"))
            }
            let requestCount = await invocations.currentValue()
            XCTAssertEqual(requestCount, 0, "invalid budgets must not disclose a request")
        }
    }

    func testTransportHeartbeatCannotSatisfyFirstContentDeadline() async {
        let timeouts = V4AnalysisTimeouts(connect: 0.2, firstContent: 0.05, idle: 0.04, hard: 0.5)
        await assertDeadline(.firstContent, timeouts: timeouts) { transport, _ in
            await transport(.connected)
            await transport(.waitingFirstContent)
            for _ in 0..<6 {
                try await Task.sleep(nanoseconds: 10_000_000)
                await transport(.receivedTransportActivity)
            }
            return "no decoded content"
        }
    }

    func testTransportHeartbeatKeepsActiveStreamAliveAfterPartialContent() async throws {
        let timeouts = V4AnalysisTimeouts(connect: 0.2, firstContent: 0.2, idle: 0.08, hard: 1.0)
        let recorder = V4DeadlineCallbackRecorder()
        let response = try await V4AnalysisDeadlineEnforcer.perform(
            timeouts: timeouts,
            maximumResponseBytes: 100,
            onTransportState: { _ in },
            onDelta: { value in await recorder.record(value) }
        ) { transport, delta in
            await transport(.connected)
            await transport(.waitingFirstContent)
            await delta("{")
            for _ in 0..<8 {
                try await Task.sleep(nanoseconds: 20_000_000)
                await transport(.receivedTransportActivity)
            }
            await delta("}")
            return "{}"
        }
        let callbacks = await recorder.snapshot()
        XCTAssertEqual(response, "{}")
        XCTAssertEqual(callbacks, ["{", "}"])
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
