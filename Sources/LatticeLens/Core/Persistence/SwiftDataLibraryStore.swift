import Foundation
import SwiftData

/// A versioned local document. The encoded value is a normalized LibrarySnapshot
/// (authors, h-index snapshots, papers, links, insights and checkpoints), never
/// a raw INSPIRE response or a credential-bearing LLM payload.
@Model
final class StoredLibraryDocument {
    @Attribute(.unique) var key: String
    var schemaVersion: Int
    var snapshotData: Data
    var updatedAt: Date

    init(key: String = "library", schemaVersion: Int, snapshotData: Data, updatedAt: Date = Date()) {
        self.key = key
        self.schemaVersion = schemaVersion
        self.snapshotData = snapshotData
        self.updatedAt = updatedAt
    }
}

/// Normalized v2 projections. The v1 snapshot remains the compatibility
/// source during migration, while new queries and integrity checks have
/// first-class rows rather than requiring every UI action to decode a blob.
@Model
final class StoredReadingStateV2 {
    @Attribute(.unique) var paperID: Int
    var isRead: Bool
    var readAt: Date?
    var isFavorite: Bool
    var updatedAt: Date
    init(paperID: Int, isRead: Bool, readAt: Date?, isFavorite: Bool, updatedAt: Date) {
        self.paperID = paperID; self.isRead = isRead; self.readAt = readAt; self.isFavorite = isFavorite; self.updatedAt = updatedAt
    }
}

@Model
final class StoredTagV2 {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorName: String?
    var createdAt: Date
    init(_ value: LibraryTag) { id = value.id; name = value.name; colorName = value.colorName; createdAt = value.createdAt }
}

@Model
final class StoredCollectionV2 {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    init(_ value: PaperCollection) { id = value.id; name = value.name; createdAt = value.createdAt }
}

@Model
final class StoredUserNoteV2 {
    @Attribute(.unique) var id: UUID
    var paperID: Int
    var body: String
    var createdAt: Date
    var updatedAt: Date
    init(_ value: UserNote) { id = value.id; paperID = value.paperID; body = value.body; createdAt = value.createdAt; updatedAt = value.updatedAt }
}

@Model
final class StoredPaperTagLinkV2 {
    @Attribute(.unique) var key: String
    var paperID: Int
    var tagID: UUID
    init(_ value: PaperTagLink) { key = "\(value.paperID):\(value.tagID.uuidString)"; paperID = value.paperID; tagID = value.tagID }
}

@Model
final class StoredCollectionPaperLinkV2 {
    @Attribute(.unique) var key: String
    var collectionID: UUID
    var paperID: Int
    var addedAt: Date
    init(_ value: CollectionPaperLink) { key = "\(value.collectionID.uuidString):\(value.paperID)"; collectionID = value.collectionID; paperID = value.paperID; addedAt = value.addedAt }
}

@Model
final class StoredCitationSnapshotV2 {
    @Attribute(.unique) var key: String
    var paperID: Int
    var citationCount: Int
    var fetchedAt: Date
    init(_ value: CitationSnapshot) { key = value.id; paperID = value.paperID; citationCount = value.citationCount; fetchedAt = value.fetchedAt }
}

@Model
final class StoredBibTeXRecordV2 {
    @Attribute(.unique) var paperID: Int
    var sourceURL: String
    var sourceFetchedAt: Date
    var contents: String
    init(_ value: BibTeXRecord) {
        paperID = value.paperID; sourceURL = value.sourceURL.absoluteString; sourceFetchedAt = value.sourceFetchedAt; contents = value.contents
    }
}

@Model
final class StoredFullTextDocumentV2 {
    @Attribute(.unique) var documentID: String
    var paperID: Int
    var sourceURL: String
    var sourceKind: String
    var sha256: String
    var byteCount: Int
    var localFilename: String?
    var pageCount: Int
    var extractionState: String
    var downloadedAt: Date?
    var lastErrorCategory: String?
    init(_ value: FullTextDocument) {
        documentID = value.id; paperID = value.paperID; sourceURL = value.sourceURL.absoluteString; sourceKind = value.sourceKind.rawValue
        sha256 = value.sha256; byteCount = value.byteCount; localFilename = value.localFilename; pageCount = value.pageCount ?? 0
        extractionState = value.extractionState.rawValue; downloadedAt = value.downloadedAt; lastErrorCategory = value.lastErrorCategory
    }
}

@Model
final class StoredEvidenceChunkV2 {
    @Attribute(.unique) var id: String
    var paperID: Int
    var documentHash: String
    var page: Int
    var section: String?
    var characterRangeStart: Int
    var characterRangeEnd: Int
    var text: String
    var textHash: String
    init(_ value: EvidenceChunk) {
        id = value.id; paperID = value.paperID; documentHash = value.documentHash; page = value.page; section = value.section
        characterRangeStart = value.characterRangeStart; characterRangeEnd = value.characterRangeEnd; text = value.text; textHash = value.textHash
    }
}

@Model
final class StoredEvidenceAnchorV2 {
    @Attribute(.unique) var id: String
    var paperID: Int
    var sourceKind: String
    var page: Int
    var section: String?
    var quote: String
    var quoteHash: String
    var figureKey: String?
    init(_ value: EvidenceAnchor) {
        id = value.id; paperID = value.paperID; sourceKind = value.sourceKind.rawValue; page = value.page ?? 0
        section = value.section; quote = value.quote; quoteHash = value.quoteHash; figureKey = value.figureKey
    }
}

@Model
final class StoredEvidenceInsightArtifactV2 {
    @Attribute(.unique) var cacheKey: String
    var paperID: Int
    var documentHash: String
    var createdAt: Date
    var payload: Data
    init(_ value: EvidenceInsightArtifact) throws {
        cacheKey = value.cacheKey; paperID = value.paperID; documentHash = value.documentHash; createdAt = value.createdAt
        payload = try JSONEncoder.latticeLens.encode(value)
    }
}

@Model
final class StoredVisionArtifactV2 {
    @Attribute(.unique) var cacheKey: String
    var paperID: Int
    var createdAt: Date
    var provider: String
    var model: String
    var payload: Data
    init(_ value: VisionArtifact) throws {
        cacheKey = value.cacheKey; paperID = value.paperID; createdAt = value.createdAt; provider = value.provider; model = value.model
        payload = try JSONEncoder.latticeLens.encode(value)
    }
}

@Model
final class StoredSyncBatchV2 {
    @Attribute(.unique) var id: UUID
    var jobID: String
    var startedAt: Date
    var completedAt: Date?
    var state: String
    var newRecords: Int
    var metadataUpdatedRecords: Int
    var citationChangedRecords: Int
    var failureCount: Int
    init(_ value: SyncBatch) {
        id = value.id; jobID = value.jobID; startedAt = value.startedAt; completedAt = value.completedAt; state = value.state.rawValue
        newRecords = value.newRecords; metadataUpdatedRecords = value.metadataUpdatedRecords
        citationChangedRecords = value.citationChangedRecords; failureCount = value.failureCount
    }
}

/// The raw v1 snapshot is retained exactly once when a V1 store is first read
/// through the V2 schema.  It is not a second active library: it is an auditable
/// rollback source and is never overwritten by later V2 mutations.
@Model
final class StoredV1SnapshotBackupV2 {
    @Attribute(.unique) var key: String
    var sourceSchemaVersion: Int
    var snapshotData: Data
    var checksum: String
    var capturedAt: Date
    init(sourceSchemaVersion: Int, snapshotData: Data, capturedAt: Date = Date()) {
        key = "v1-library-snapshot"; self.sourceSchemaVersion = sourceSchemaVersion; self.snapshotData = snapshotData
        checksum = StableHash.sha256(snapshotData); self.capturedAt = capturedAt
    }
}

@Model
final class StoredV3SchemaMarker {
    @Attribute(.unique) var key: String
    var schemaVersion: Int
    var capturedAt: Date
    init(schemaVersion: Int = 3, capturedAt: Date = Date()) {
        key = "v3-schema-marker"; self.schemaVersion = schemaVersion; self.capturedAt = capturedAt
    }
}

/// V3 audit projections. The complete Codable payload remains the rollback
/// source, while these rows make Radar/Compare/Notebook queries inspectable in
/// SwiftData without decoding the whole library blob for every list view.
@Model final class StoredV3Workspace {
    @Attribute(.unique) var id: UUID
    var name: String; var updatedAt: Date; var paperCount: Int; var payload: Data
    init(_ value: PaperWorkspace) { id = value.id; name = value.name; updatedAt = value.updatedAt; paperCount = value.sortOrder.count; payload = (try? JSONEncoder.latticeLens.encode(value)) ?? Data() }
}
@Model final class StoredV3PhysicsCell {
    @Attribute(.unique) var id: UUID
    var workspaceID: UUID; var paperID: Int; var rowKey: String; var status: String; var payload: Data
    init(_ value: PhysicsContractCell) { id = value.id; workspaceID = value.workspaceID; paperID = value.paperID; rowKey = value.rowKey; status = value.status.rawValue; payload = (try? JSONEncoder.latticeLens.encode(value)) ?? Data() }
}
@Model final class StoredV3RadarEvent {
    @Attribute(.unique) var id: UUID
    var paperID: Int; var eventKind: String; var observedAt: Date; var payload: Data
    init(_ value: RadarEvent) { id = value.id; paperID = value.paperID; eventKind = value.eventKind.rawValue; observedAt = value.observedAt; payload = (try? JSONEncoder.latticeLens.encode(value)) ?? Data() }
}
@Model final class StoredV3SavedQuery {
    @Attribute(.unique) var id: UUID
    var name: String; var query: String; var paused: Bool; var payload: Data
    init(_ value: SavedInspireQuery) { id = value.id; name = value.name; query = value.query; paused = value.isPaused; payload = (try? JSONEncoder.latticeLens.encode(value)) ?? Data() }
}
@Model final class StoredV3Annotation {
    @Attribute(.unique) var id: UUID
    var paperID: Int; var status: String; var payload: Data
    init(_ value: UserEvidenceAnchor) { id = value.id; paperID = value.paperID; status = value.status.rawValue; payload = (try? JSONEncoder.latticeLens.encode(value)) ?? Data() }
}
@Model final class StoredV3Export {
    @Attribute(.unique) var id: UUID
    var format: String; var createdAt: Date; var succeeded: Bool; var payload: Data
    init(_ value: ExportRecord) { id = value.id; format = value.format.rawValue; createdAt = value.createdAt; succeeded = value.succeeded; payload = (try? JSONEncoder.latticeLens.encode(value)) ?? Data() }
}
@Model final class StoredV3Import {
    @Attribute(.unique) var id: UUID
    var format: String; var importedAt: Date; var matchedPaperID: Int?; var payload: Data
    init(_ value: V3ImportedBibliography) { id = value.id; format = value.format.rawValue; importedAt = value.importedAt; matchedPaperID = value.matchedPaperID; payload = (try? JSONEncoder.latticeLens.encode(value)) ?? Data() }
}
@Model final class StoredV3ImportConflict {
    @Attribute(.unique) var id: UUID
    var paperID: Int; var status: String; var payload: Data
    init(_ value: V3ImportConflict) { id = value.importedID; paperID = value.paperID; status = value.status.rawValue; payload = (try? JSONEncoder.latticeLens.encode(value)) ?? Data() }
}
@Model final class StoredV3MigrationJournal {
    @Attribute(.unique) var id: UUID
    var phase: String; var startedAt: Date; var completedAt: Date?; var preCount: Int; var postCount: Int?; var payload: Data
    init(_ value: V3MigrationJournalEntry) { id = value.id; phase = value.phase; startedAt = value.startedAt; completedAt = value.completedAt; preCount = value.preCount; postCount = value.postCount; payload = (try? JSONEncoder.latticeLens.encode(value)) ?? Data() }
}

enum LatticeLensSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [StoredLibraryDocument.self] }
}

enum LatticeLensSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [StoredLibraryDocument.self, StoredReadingStateV2.self, StoredTagV2.self, StoredCollectionV2.self,
         StoredUserNoteV2.self, StoredPaperTagLinkV2.self, StoredCollectionPaperLinkV2.self, StoredCitationSnapshotV2.self, StoredBibTeXRecordV2.self,
         StoredFullTextDocumentV2.self, StoredEvidenceChunkV2.self, StoredEvidenceAnchorV2.self,
         StoredEvidenceInsightArtifactV2.self, StoredVisionArtifactV2.self, StoredSyncBatchV2.self,
         StoredV1SnapshotBackupV2.self]
    }
}

enum LatticeLensSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] {
        LatticeLensSchemaV2.models + [StoredV3SchemaMarker.self]
    }
}

enum LatticeLensSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }
    static var models: [any PersistentModel.Type] {
        LatticeLensSchemaV3.models + [StoredV3Workspace.self, StoredV3PhysicsCell.self, StoredV3RadarEvent.self,
                                      StoredV3SavedQuery.self, StoredV3Annotation.self, StoredV3Export.self,
                                      StoredV3Import.self, StoredV3ImportConflict.self, StoredV3MigrationJournal.self]
    }
}

enum LatticeLensMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LatticeLensSchemaV1.self, LatticeLensSchemaV2.self, LatticeLensSchemaV3.self, LatticeLensSchemaV4.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: LatticeLensSchemaV1.self, toVersion: LatticeLensSchemaV2.self),
         .lightweight(fromVersion: LatticeLensSchemaV2.self, toVersion: LatticeLensSchemaV3.self),
         .lightweight(fromVersion: LatticeLensSchemaV3.self, toVersion: LatticeLensSchemaV4.self)]
    }
}

// MARK: - V7 normalized active-record codec

/// These record kinds intentionally mirror `LibrarySnapshot` fields one
/// object at a time.  They are not a serialized snapshot: a row is replaced
/// only when that object changes, which makes a single note/read mutation
/// independent of the number of papers in the library.
enum V7DomainKind: String, CaseIterable {
    case author, paper, paperAuthorLink, insight, evidenceInsight, checkpoint
    case readingState, note, tag, paperTagLink, collection, collectionPaperLink
    case citationSnapshot, bibTeX, fullTextDocument, evidenceChunk, evidenceAnchor
    case visionArtifact, syncBatch, authorIndexGeneration, paperRevision, radarEvent
    case savedQuery, syncBatchV3, syncJobEvent, contentBlob, documentReference
    case userAnnotation, workspace, workspacePaperLink, physicsContract, physicsCell
    case citationEdge, coauthorEdge, exportRecord, cloudState, conflictCopy
    case importedBibliography, importConflict, migrationJournal, quarantinedEvidence
}

struct V7EncodedDomainRecord {
    let kind: V7DomainKind
    let recordID: String
    let payload: Data
    var key: String { "\(kind.rawValue)|\(recordID)" }
}

enum V7DomainRecordCodec {
    private static func encode<T: Encodable>(_ kind: V7DomainKind, _ id: String, _ value: T) throws -> V7EncodedDomainRecord {
        V7EncodedDomainRecord(kind: kind, recordID: id, payload: try JSONEncoder.latticeLens.encode(value))
    }

    static func encode(snapshot: LibrarySnapshot) throws -> [String: V7EncodedDomainRecord] {
        var values: [V7EncodedDomainRecord] = []
        func append<T: Encodable>(_ kind: V7DomainKind, _ id: String, _ value: T) throws { values.append(try encode(kind, id, value)) }

        for value in snapshot.authors.values { try append(.author, String(value.recid), value) }
        for value in snapshot.papers.values { try append(.paper, String(value.literatureID), value) }
        for value in snapshot.paperAuthorLinks { try append(.paperAuthorLink, "\(value.paperID):\(value.authorRecid)", value) }
        for value in snapshot.insights.values { try append(.insight, value.cacheKey, value) }
        for value in snapshot.evidenceInsights.values { try append(.evidenceInsight, value.cacheKey, value) }
        for value in snapshot.checkpoints.values { try append(.checkpoint, value.jobID, value) }
        for value in snapshot.readingStates.values { try append(.readingState, String(value.paperID), value) }
        for value in snapshot.notes.values { try append(.note, value.id.uuidString, value) }
        for value in snapshot.tags.values { try append(.tag, value.id.uuidString, value) }
        for value in snapshot.paperTags { try append(.paperTagLink, "\(value.paperID):\(value.tagID.uuidString)", value) }
        for value in snapshot.collections.values { try append(.collection, value.id.uuidString, value) }
        for value in snapshot.collectionPapers { try append(.collectionPaperLink, "\(value.collectionID.uuidString):\(value.paperID)", value) }
        for value in snapshot.citationSnapshots.values { try append(.citationSnapshot, value.id, value) }
        for value in snapshot.bibTeXRecords.values { try append(.bibTeX, String(value.paperID), value) }
        for value in snapshot.fullTextDocuments.values { try append(.fullTextDocument, value.id, value) }
        for value in snapshot.evidenceChunks.values { try append(.evidenceChunk, value.id, value) }
        for value in snapshot.evidenceAnchors.values { try append(.evidenceAnchor, value.id, value) }
        for value in snapshot.visionArtifacts.values { try append(.visionArtifact, value.cacheKey, value) }
        for value in snapshot.syncBatches.values { try append(.syncBatch, value.id.uuidString, value) }
        for value in snapshot.authorIndexGenerations.values { try append(.authorIndexGeneration, value.id, value) }
        for value in snapshot.paperRevisionSnapshots.values { try append(.paperRevision, value.id, value) }
        for value in snapshot.radarEvents.values { try append(.radarEvent, value.id.uuidString, value) }
        for value in snapshot.savedInspireQueries.values { try append(.savedQuery, value.id.uuidString, value) }
        for value in snapshot.syncBatchesV3.values { try append(.syncBatchV3, value.id.uuidString, value) }
        for value in snapshot.syncJobEvents.values { try append(.syncJobEvent, value.id.uuidString, value) }
        for value in snapshot.contentBlobs.values { try append(.contentBlob, value.hash, value) }
        for value in snapshot.documentReferences.values { try append(.documentReference, value.id, value) }
        for value in snapshot.userEvidenceAnchors.values { try append(.userAnnotation, value.id.uuidString, value) }
        for value in snapshot.workspaces.values { try append(.workspace, value.id.uuidString, value) }
        for value in snapshot.workspacePaperLinks { try append(.workspacePaperLink, "\(value.workspaceID.uuidString):\(value.paperID)", value) }
        for value in snapshot.physicsContracts.values { try append(.physicsContract, value.id.uuidString, value) }
        for value in snapshot.physicsContractCells.values { try append(.physicsCell, value.id.uuidString, value) }
        for value in snapshot.citationEdges.values { try append(.citationEdge, value.id, value) }
        for value in snapshot.coauthorEdges.values { try append(.coauthorEdge, value.id, value) }
        for value in snapshot.exportRecords.values { try append(.exportRecord, value.id.uuidString, value) }
        for value in snapshot.cloudSyncStates.values { try append(.cloudState, value.recordID, value) }
        for value in snapshot.conflictCopies.values { try append(.conflictCopy, value.id.uuidString, value) }
        for value in snapshot.importedBibliographies.values { try append(.importedBibliography, value.id.uuidString, value) }
        for value in snapshot.importConflicts.values { try append(.importConflict, value.importedID.uuidString, value) }
        for value in snapshot.migrationJournal.values { try append(.migrationJournal, value.id.uuidString, value) }
        for value in snapshot.quarantinedEvidenceIDs { values.append(V7EncodedDomainRecord(kind: .quarantinedEvidence, recordID: value, payload: Data())) }
        return Dictionary(uniqueKeysWithValues: values.map { ($0.key, $0) })
    }

    private static func decode<T: Decodable>(_ row: StoredV7DomainRecord, as type: T.Type) throws -> T {
        try JSONDecoder.latticeLens.decode(T.self, from: row.payload)
    }

    static func decode(rows: [StoredV7DomainRecord]) throws -> LibrarySnapshot {
        var snapshot = LibrarySnapshot(schemaVersion: 7, v3SchemaVersion: 3)
        for row in rows {
            guard let kind = V7DomainKind(rawValue: row.kind) else { continue }
            switch kind {
            case .author: let value: Author = try decode(row, as: Author.self); snapshot.authors[value.recid] = value
            case .paper: let value: Paper = try decode(row, as: Paper.self); snapshot.papers[value.literatureID] = value
            case .paperAuthorLink: snapshot.paperAuthorLinks.insert(try decode(row, as: PaperAuthorLink.self))
            case .insight: let value: InsightArtifact = try decode(row, as: InsightArtifact.self); snapshot.insights[value.cacheKey] = value
            case .evidenceInsight: let value: EvidenceInsightArtifact = try decode(row, as: EvidenceInsightArtifact.self); snapshot.evidenceInsights[value.cacheKey] = value
            case .checkpoint: let value: SyncCheckpoint = try decode(row, as: SyncCheckpoint.self); snapshot.checkpoints[value.jobID] = value
            case .readingState: let value: ReadingState = try decode(row, as: ReadingState.self); snapshot.readingStates[value.paperID] = value
            case .note: let value: UserNote = try decode(row, as: UserNote.self); snapshot.notes[value.id] = value
            case .tag: let value: LibraryTag = try decode(row, as: LibraryTag.self); snapshot.tags[value.id] = value
            case .paperTagLink: snapshot.paperTags.insert(try decode(row, as: PaperTagLink.self))
            case .collection: let value: PaperCollection = try decode(row, as: PaperCollection.self); snapshot.collections[value.id] = value
            case .collectionPaperLink: snapshot.collectionPapers.insert(try decode(row, as: CollectionPaperLink.self))
            case .citationSnapshot: let value: CitationSnapshot = try decode(row, as: CitationSnapshot.self); snapshot.citationSnapshots[value.id] = value
            case .bibTeX: let value: BibTeXRecord = try decode(row, as: BibTeXRecord.self); snapshot.bibTeXRecords[value.paperID] = value
            case .fullTextDocument: let value: FullTextDocument = try decode(row, as: FullTextDocument.self); snapshot.fullTextDocuments[value.id] = value
            case .evidenceChunk: let value: EvidenceChunk = try decode(row, as: EvidenceChunk.self); snapshot.evidenceChunks[value.id] = value
            case .evidenceAnchor: let value: EvidenceAnchor = try decode(row, as: EvidenceAnchor.self); snapshot.evidenceAnchors[value.id] = value
            case .visionArtifact: let value: VisionArtifact = try decode(row, as: VisionArtifact.self); snapshot.visionArtifacts[value.cacheKey] = value
            case .syncBatch: let value: SyncBatch = try decode(row, as: SyncBatch.self); snapshot.syncBatches[value.id] = value
            case .authorIndexGeneration: let value: AuthorIndexGeneration = try decode(row, as: AuthorIndexGeneration.self); snapshot.authorIndexGenerations[value.id] = value
            case .paperRevision: let value: PaperRevisionSnapshot = try decode(row, as: PaperRevisionSnapshot.self); snapshot.paperRevisionSnapshots[value.id] = value
            case .radarEvent: let value: RadarEvent = try decode(row, as: RadarEvent.self); snapshot.radarEvents[value.id] = value
            case .savedQuery: let value: SavedInspireQuery = try decode(row, as: SavedInspireQuery.self); snapshot.savedInspireQueries[value.id] = value
            case .syncBatchV3: let value: SyncBatchV3 = try decode(row, as: SyncBatchV3.self); snapshot.syncBatchesV3[value.id] = value
            case .syncJobEvent: let value: SyncJobEvent = try decode(row, as: SyncJobEvent.self); snapshot.syncJobEvents[value.id] = value
            case .contentBlob: let value: ContentBlob = try decode(row, as: ContentBlob.self); snapshot.contentBlobs[value.hash] = value
            case .documentReference: let value: DocumentReference = try decode(row, as: DocumentReference.self); snapshot.documentReferences[value.id] = value
            case .userAnnotation: let value: UserEvidenceAnchor = try decode(row, as: UserEvidenceAnchor.self); snapshot.userEvidenceAnchors[value.id] = value
            case .workspace: let value: PaperWorkspace = try decode(row, as: PaperWorkspace.self); snapshot.workspaces[value.id] = value
            case .workspacePaperLink: snapshot.workspacePaperLinks.insert(try decode(row, as: WorkspacePaperLink.self))
            case .physicsContract: let value: PhysicsContract = try decode(row, as: PhysicsContract.self); snapshot.physicsContracts[value.id] = value
            case .physicsCell: let value: PhysicsContractCell = try decode(row, as: PhysicsContractCell.self); snapshot.physicsContractCells[value.id] = value
            case .citationEdge: let value: CitationEdge = try decode(row, as: CitationEdge.self); snapshot.citationEdges[value.id] = value
            case .coauthorEdge: let value: CoauthorEdge = try decode(row, as: CoauthorEdge.self); snapshot.coauthorEdges[value.id] = value
            case .exportRecord: let value: ExportRecord = try decode(row, as: ExportRecord.self); snapshot.exportRecords[value.id] = value
            case .cloudState: let value: CloudSyncRecordState = try decode(row, as: CloudSyncRecordState.self); snapshot.cloudSyncStates[value.recordID] = value
            case .conflictCopy: let value: ConflictCopy = try decode(row, as: ConflictCopy.self); snapshot.conflictCopies[value.id] = value
            case .importedBibliography: let value: V3ImportedBibliography = try decode(row, as: V3ImportedBibliography.self); snapshot.importedBibliographies[value.id] = value
            case .importConflict: let value: V3ImportConflict = try decode(row, as: V3ImportConflict.self); snapshot.importConflicts[value.importedID] = value
            case .migrationJournal: let value: V3MigrationJournalEntry = try decode(row, as: V3MigrationJournalEntry.self); snapshot.migrationJournal[value.id] = value
            case .quarantinedEvidence: snapshot.quarantinedEvidenceIDs.insert(row.recordID)
            }
        }
        return snapshot
    }
}

@ModelActor
actor SwiftDataLibraryStore: LibraryStoring {
    private var availabilityFailure: String?
    private var lastKnownGoodSnapshot: LibrarySnapshot?
    /// `nil` until the explicit V7 activation marker is read. Older V1–V6
    /// containers never receive that marker and retain their compatibility
    /// path; querying an unregistered SwiftData model is not a reliable schema
    /// probe on all macOS releases.
    private var v7NormalizedAvailable: Bool?

    func initializationState() -> LibraryInitializationState {
        if let availabilityFailure { return .readOnlyFailure(availabilityFailure) }
        do {
            _ = try load()
            return .ready
        } catch {
            let reason = "SwiftData 读取/解码失败；原资料库未被覆盖"
            availabilityFailure = reason
            return .readOnlyFailure(reason)
        }
    }

    func snapshot() -> LibrarySnapshot {
        do {
            let snapshot = try readSnapshot().snapshot
            lastKnownGoodSnapshot = snapshot
            return snapshot
        } catch {
            // Keep the last immutable snapshot visible; never turn a decode
            // failure into a silent empty library.
            if let lastKnownGoodSnapshot { return lastKnownGoodSnapshot }
            var failure = LibrarySnapshot()
            failure.readErrorMessage = "SwiftData 读取/解码失败；当前仅提供只读错误占位，原资料库未被覆盖"
            return failure
        }
    }

    func snapshotResult() -> LibrarySnapshotReadResult {
        do {
            let snapshot = try readSnapshot().snapshot
            lastKnownGoodSnapshot = snapshot
            return LibrarySnapshotReadResult(state: .ready, snapshot: snapshot, message: nil)
        } catch {
            let reason = availabilityFailure ?? "SwiftData 读取/解码失败；保留最后一次有效资料库"
            if let lastKnownGoodSnapshot { return LibrarySnapshotReadResult(state: .readOnlyFailure, snapshot: lastKnownGoodSnapshot, message: reason) }
            var failure = LibrarySnapshot(); failure.readErrorMessage = reason
            return LibrarySnapshotReadResult(state: .readOnlyFailure, snapshot: failure, message: reason)
        }
    }

    func upsert(authors: [Author]) throws {
        var loaded = try readSnapshot()
        loaded.snapshot.merge(authors: authors)
        try persist(loaded)
    }

    func upsert(papers: [Paper], for authorRecid: Int) throws -> PaperUpsertReport {
        var loaded = try readSnapshot()
        let report = loaded.snapshot.merge(papers: papers, for: authorRecid)
        try persist(loaded)
        return report
    }

    func upsert(detail paper: Paper) throws {
        var loaded = try readSnapshot()
        var merged = paper
        if let prior = loaded.snapshot.papers[paper.literatureID] {
            merged.firstSeenAt = prior.firstSeenAt
            merged.isRead = prior.isRead
            merged.readAt = prior.readAt
            merged.isFavorite = prior.isFavorite
        }
        loaded.snapshot.papers[paper.literatureID] = merged
        try persist(loaded)
    }

    func save(checkpoint: SyncCheckpoint?) throws {
        guard let checkpoint else { return }
        var loaded = try readSnapshot()
        loaded.snapshot.checkpoints[checkpoint.id] = checkpoint
        try persist(loaded)
    }

    func checkpoint(jobID: String) throws -> SyncCheckpoint? { try readSnapshot().snapshot.checkpoints[jobID] }

    func completeCheckpoint(jobID: String, at: Date) throws {
        var loaded = try readSnapshot()
        guard var checkpoint = loaded.snapshot.checkpoints[jobID] else { return }
        checkpoint.nextURL = nil
        checkpoint.state = .completed
        checkpoint.updatedAt = at
        checkpoint.completedAt = at
        loaded.snapshot.checkpoints[jobID] = checkpoint
        try persist(loaded)
    }

    func deleteCheckpoint(jobID: String) throws {
        var loaded = try readSnapshot()
        loaded.snapshot.checkpoints.removeValue(forKey: jobID)
        try persist(loaded)
    }

    func save(insight: InsightArtifact) throws {
        var loaded = try readSnapshot()
        loaded.snapshot.insights[insight.cacheKey] = insight
        try persist(loaded)
    }

    func removeInsights() throws {
        var loaded = try readSnapshot()
        loaded.snapshot.insights.removeAll()
        try persist(loaded)
    }

    func setTracked(_ tracked: Bool, authorRecid: Int) throws {
        var loaded = try readSnapshot()
        guard var author = loaded.snapshot.authors[authorRecid] else { return }
        author.isTracked = tracked
        loaded.snapshot.authors[authorRecid] = author
        try persist(loaded)
    }

    func markRead(_ read: Bool, paperID: Int, at: Date?) throws {
        if try usesV7NormalizedStore() {
            try updateV7ReadingState(read, paperID: paperID, at: at)
            return
        }
        var loaded = try readSnapshot()
        loaded.snapshot.updateRead(read, paperID: paperID, at: at)
        try persist(loaded)
    }

    func applyReferenceMutation(_ mutation: ReferenceMutation) throws {
        var loaded = try readSnapshot()
        loaded.snapshot.apply(mutation)
        try persist(loaded)
    }

    func saveFullText(document: FullTextDocument, chunks: [EvidenceChunk], anchors: [EvidenceAnchor]) throws {
        var loaded = try readSnapshot()
        loaded.snapshot.storeFullText(document: document, chunks: chunks, anchors: anchors)
        try persist(loaded)
    }

    func saveEvidenceAnchors(_ anchors: [EvidenceAnchor]) throws {
        var loaded = try readSnapshot()
        loaded.snapshot.storeEvidenceAnchors(anchors)
        try persist(loaded)
    }

    func deleteFullText(documentID: String) throws {
        var loaded = try readSnapshot()
        loaded.snapshot.deleteFullText(documentID: documentID)
        try persist(loaded)
    }

    func saveEvidenceInsight(_ artifact: EvidenceInsightArtifact) throws {
        var loaded = try readSnapshot()
        loaded.snapshot.evidenceInsights[artifact.cacheKey] = artifact
        try persist(loaded)
    }

    func saveVisionArtifact(_ artifact: VisionArtifact) throws {
        var loaded = try readSnapshot()
        loaded.snapshot.visionArtifacts[artifact.cacheKey] = artifact
        try persist(loaded)
    }

    func saveBibTeXRecord(_ record: BibTeXRecord) throws {
        var loaded = try readSnapshot()
        loaded.snapshot.bibTeXRecords[record.paperID] = record
        try persist(loaded)
    }

    func applyV3(_ mutation: V3Mutation) throws {
        var loaded = try readSnapshot()
        loaded.snapshot.apply(v3: mutation)
        try persist(loaded)
    }

    private func load() throws -> (snapshot: LibrarySnapshot, document: StoredLibraryDocument?) {
        if try usesV7NormalizedStore() {
            return (try loadV7NormalizedSnapshot(), nil)
        }
        return try loadLegacySnapshot()
    }

    private func loadLegacySnapshot() throws -> (snapshot: LibrarySnapshot, document: StoredLibraryDocument?) {
        let descriptor = FetchDescriptor<StoredLibraryDocument>(predicate: #Predicate { $0.key == "library" })
        guard let document = try modelContext.fetch(descriptor).first else { return (LibrarySnapshot(), nil) }
        do {
            let decoded = try JSONDecoder.latticeLens.decode(LibrarySnapshot.self, from: document.snapshotData)
            try retainV1SnapshotBackupIfNeeded(for: document)
            let needsV3Migration = decoded.evidenceChunks.values.contains { !$0.id.hasPrefix("v3pdf:\($0.paperID):\($0.documentHash):") }
            if needsV3Migration {
                let migrated = V3MigrationService.migrate(decoded).snapshot
                document.snapshotData = try JSONEncoder.latticeLens.encode(migrated)
                document.schemaVersion = 3
                try modelContext.save()
                return (migrated, document)
            }
            return (decoded, document)
        } catch {
            throw LatticeLensError.persistenceUnavailable("SwiftData document 无法解码")
        }
    }

    private func usesV7NormalizedStore() throws -> Bool {
        if let v7NormalizedAvailable { return v7NormalizedAvailable }
        let markers = try modelContext.fetch(FetchDescriptor<StoredV7StoreMarker>())
        v7NormalizedAvailable = !markers.isEmpty
        return !markers.isEmpty
    }

    private func loadV7NormalizedSnapshot() throws -> LibrarySnapshot {
        let markers = try modelContext.fetch(FetchDescriptor<StoredV7StoreMarker>())
        if let marker = markers.first, marker.schemaVersion >= 71 {
            return try V7DomainRecordCodec.decode(rows: modelContext.fetch(FetchDescriptor<StoredV7DomainRecord>()))
        }

        // There is no marker yet.  Import a legacy document once, atomically,
        // then select the individual V7 records as active truth.  If rows are
        // present without a marker, do not guess which partial import is safe:
        // fail visible and leave every source row untouched for recovery.
        guard let marker = markers.first else {
            throw LatticeLensError.persistenceUnavailable("V7 normalized activation marker 缺失；资料库以只读方式保留，需恢复到新 target")
        }
        let existingRows = try modelContext.fetch(FetchDescriptor<StoredV7DomainRecord>())
        // A marker written by the first V7 implementation used schemaVersion
        // 7 and was committed only after the rows. Upgrade that known state in
        // place; a true partial import still fails visible.
        if marker.schemaVersion < 70, !existingRows.isEmpty {
            marker.schemaVersion = 71
            marker.materializedAt = Date()
            try modelContext.save()
            return try V7DomainRecordCodec.decode(rows: existingRows)
        }
        guard existingRows.isEmpty else {
            throw LatticeLensError.persistenceUnavailable("V7 normalized migration marker 缺失；资料库以只读方式保留，需恢复到新 target")
        }
        let legacy = try loadLegacySnapshot()
        try writeV7Records(from: legacy.snapshot)
        try synchronizeV4Normalized(from: legacy.snapshot)
        marker.importedLegacyDocument = legacy.document != nil
        marker.schemaVersion = 71
        marker.materializedAt = Date()
        try modelContext.save()
        return legacy.snapshot
    }

    private func readSnapshot() throws -> (snapshot: LibrarySnapshot, document: StoredLibraryDocument?) {
        if let availabilityFailure { throw LatticeLensError.persistenceUnavailable(availabilityFailure) }
        do { return try load() }
        catch {
            let reason = "SwiftData 读取/解码失败；原资料库未被覆盖"
            availabilityFailure = reason
            throw LatticeLensError.persistenceUnavailable(reason)
        }
    }

    private func persist(_ loaded: (snapshot: LibrarySnapshot, document: StoredLibraryDocument?)) throws {
        if let availabilityFailure { throw LatticeLensError.persistenceUnavailable(availabilityFailure) }
        do {
            if try usesV7NormalizedStore() {
                // V7 does not encode or update StoredLibraryDocument.  It
                // writes only changed domain records, preserving a legacy
                // document (if any) strictly as a migration/rollback source.
                let previous = try loadV7NormalizedSnapshot()
                try writeV7Records(from: loaded.snapshot)
                try synchronizeV4NormalizedIncrementally(from: previous, to: loaded.snapshot)
                try modelContext.save()
                return
            }
            let data = try JSONEncoder.latticeLens.encode(loaded.snapshot)
            if let document = loaded.document {
                document.schemaVersion = loaded.snapshot.schemaVersion
                document.snapshotData = data
                document.updatedAt = Date()
            } else {
                modelContext.insert(StoredLibraryDocument(schemaVersion: loaded.snapshot.schemaVersion, snapshotData: data))
            }
            try synchronizeV2Projections(from: loaded.snapshot)
            try synchronizeV3Projections(from: loaded.snapshot)
            try synchronizeV4Normalized(from: loaded.snapshot)
            let marker = try modelContext.fetch(FetchDescriptor<StoredV3SchemaMarker>()).first
            if let marker { marker.schemaVersion = 3; marker.capturedAt = Date() }
            else { modelContext.insert(StoredV3SchemaMarker()) }
            try modelContext.save()
        } catch {
            let reason = "SwiftData 写入失败；后续写入已停止"
            availabilityFailure = reason
            throw LatticeLensError.persistenceUnavailable(reason)
        }
    }

    /// Diff by stable record key.  This is intentionally the only V7 write
    /// routine: no mutation is allowed to delete/reinsert the full store.
    private func writeV7Records(from snapshot: LibrarySnapshot) throws {
        let desired = try V7DomainRecordCodec.encode(snapshot: snapshot)
        let existing = try modelContext.fetch(FetchDescriptor<StoredV7DomainRecord>())
        var existingByKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.key, $0) })
        for row in existing where desired[row.key] == nil { modelContext.delete(row) }
        for record in desired.values {
            if let row = existingByKey.removeValue(forKey: record.key) {
                guard row.kind != record.kind.rawValue || row.recordID != record.recordID || row.payload != record.payload else { continue }
                row.kind = record.kind.rawValue; row.recordID = record.recordID; row.payload = record.payload; row.updatedAt = Date()
            } else {
                modelContext.insert(StoredV7DomainRecord(key: record.key, kind: record.kind.rawValue,
                                                          recordID: record.recordID, payload: record.payload))
            }
        }
    }

    /// Read-state changes are on the hot path of the Reading Inbox.  Once a
    /// store has selected V7 rows as its active truth, this operation must not
    /// decode the complete paper corpus merely to toggle one paper.  Keep the
    /// denormalized V4 projection in the same SwiftData save so the local
    /// search/Home queries and the authoritative V7 paper/reading-state rows
    /// cannot temporarily disagree after a process interruption.
    private func updateV7ReadingState(_ read: Bool, paperID: Int, at: Date?) throws {
        // `snapshot()` may already have materialized a large reader-side
        // graph in this actor's context.  Use a fresh transaction context for
        // this bounded write so Core Data need not inspect every faulted
        // domain row before committing a single reading-state change.
        let context = ModelContext(modelContainer)
        let recordID = String(paperID)
        let paperKey = "\(V7DomainKind.paper.rawValue)|\(recordID)"
        let paperDescriptor = FetchDescriptor<StoredV7DomainRecord>(predicate: #Predicate { $0.key == paperKey })
        guard let paperRow = try context.fetch(paperDescriptor).first else {
            throw LatticeLensError.persistenceUnavailable("V7 active store 缺少 paper \(paperID)；未写入部分阅读状态")
        }
        var paper = try JSONDecoder.latticeLens.decode(Paper.self, from: paperRow.payload)
        let timestamp = read ? (at ?? Date()) : nil
        paper.isRead = read
        paper.readAt = timestamp
        paperRow.payload = try JSONEncoder.latticeLens.encode(paper)
        paperRow.updatedAt = Date()

        let readingState = ReadingState(paperID: paperID, isRead: read, readAt: timestamp,
                                        isFavorite: paper.isFavorite, updatedAt: Date())
        let stateKey = "\(V7DomainKind.readingState.rawValue)|\(recordID)"
        let stateDescriptor = FetchDescriptor<StoredV7DomainRecord>(predicate: #Predicate { $0.key == stateKey })
        if let row = try context.fetch(stateDescriptor).first {
            row.payload = try JSONEncoder.latticeLens.encode(readingState)
            row.updatedAt = Date()
        } else {
            context.insert(StoredV7DomainRecord(key: stateKey, kind: V7DomainKind.readingState.rawValue,
                                                 recordID: recordID,
                                                 payload: try JSONEncoder.latticeLens.encode(readingState)))
        }

        let projection = FetchDescriptor<StoredV4Paper>(predicate: #Predicate { $0.literatureID == paperID })
        if let row = try context.fetch(projection).first {
            row.isRead = read
            row.readingState = read ? V4ReadingWorkflowState.reading.rawValue : V4ReadingWorkflowState.inbox.rawValue
            row.updatedAt = Date()
        } else {
            // A V7 store created by a caller that deliberately does not keep
            // V4 projections remains authoritative and writable.  Do not
            // synthesize a whole index here; only restore this paper's local
            // projection and leave a later index rebuild to its normal owner.
            context.insert(StoredV4Paper(paper, workflow: nil))
        }
        try context.save()
        if var cached = lastKnownGoodSnapshot, cached.papers[paperID] != nil {
            cached.updateRead(read, paperID: paperID, at: timestamp)
            lastKnownGoodSnapshot = cached
        }
    }

    private func synchronizeV2Projections(from snapshot: LibrarySnapshot) throws {
        for value in try modelContext.fetch(FetchDescriptor<StoredReadingStateV2>()) { modelContext.delete(value) }
        for value in snapshot.readingStates.values {
            modelContext.insert(StoredReadingStateV2(paperID: value.paperID, isRead: value.isRead, readAt: value.readAt,
                                                     isFavorite: value.isFavorite, updatedAt: value.updatedAt))
        }
        for value in try modelContext.fetch(FetchDescriptor<StoredTagV2>()) { modelContext.delete(value) }
        for value in snapshot.tags.values { modelContext.insert(StoredTagV2(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredCollectionV2>()) { modelContext.delete(value) }
        for value in snapshot.collections.values { modelContext.insert(StoredCollectionV2(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredUserNoteV2>()) { modelContext.delete(value) }
        for value in snapshot.notes.values { modelContext.insert(StoredUserNoteV2(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredPaperTagLinkV2>()) { modelContext.delete(value) }
        for value in snapshot.paperTags { modelContext.insert(StoredPaperTagLinkV2(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredCollectionPaperLinkV2>()) { modelContext.delete(value) }
        for value in snapshot.collectionPapers { modelContext.insert(StoredCollectionPaperLinkV2(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredCitationSnapshotV2>()) { modelContext.delete(value) }
        for value in snapshot.citationSnapshots.values { modelContext.insert(StoredCitationSnapshotV2(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredBibTeXRecordV2>()) { modelContext.delete(value) }
        for value in snapshot.bibTeXRecords.values { modelContext.insert(StoredBibTeXRecordV2(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredFullTextDocumentV2>()) { modelContext.delete(value) }
        for value in snapshot.fullTextDocuments.values { modelContext.insert(StoredFullTextDocumentV2(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredEvidenceChunkV2>()) { modelContext.delete(value) }
        for value in snapshot.evidenceChunks.values { modelContext.insert(StoredEvidenceChunkV2(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredEvidenceAnchorV2>()) { modelContext.delete(value) }
        for value in snapshot.evidenceAnchors.values { modelContext.insert(StoredEvidenceAnchorV2(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredEvidenceInsightArtifactV2>()) { modelContext.delete(value) }
        for value in snapshot.evidenceInsights.values { modelContext.insert(try StoredEvidenceInsightArtifactV2(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredVisionArtifactV2>()) { modelContext.delete(value) }
        for value in snapshot.visionArtifacts.values { modelContext.insert(try StoredVisionArtifactV2(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredSyncBatchV2>()) { modelContext.delete(value) }
        for value in snapshot.syncBatches.values { modelContext.insert(StoredSyncBatchV2(value)) }
    }

    private func synchronizeV3Projections(from snapshot: LibrarySnapshot) throws {
        for value in try modelContext.fetch(FetchDescriptor<StoredV3Workspace>()) { modelContext.delete(value) }
        for value in snapshot.workspaces.values { modelContext.insert(StoredV3Workspace(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredV3PhysicsCell>()) { modelContext.delete(value) }
        for value in snapshot.physicsContractCells.values { modelContext.insert(StoredV3PhysicsCell(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredV3RadarEvent>()) { modelContext.delete(value) }
        for value in snapshot.radarEvents.values { modelContext.insert(StoredV3RadarEvent(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredV3SavedQuery>()) { modelContext.delete(value) }
        for value in snapshot.savedInspireQueries.values { modelContext.insert(StoredV3SavedQuery(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredV3Annotation>()) { modelContext.delete(value) }
        for value in snapshot.userEvidenceAnchors.values { modelContext.insert(StoredV3Annotation(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredV3Export>()) { modelContext.delete(value) }
        for value in snapshot.exportRecords.values { modelContext.insert(StoredV3Export(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredV3Import>()) { modelContext.delete(value) }
        for value in snapshot.importedBibliographies.values { modelContext.insert(StoredV3Import(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredV3ImportConflict>()) { modelContext.delete(value) }
        for value in snapshot.importConflicts.values { modelContext.insert(StoredV3ImportConflict(value)) }
        for value in try modelContext.fetch(FetchDescriptor<StoredV3MigrationJournal>()) { modelContext.delete(value) }
        for value in snapshot.migrationJournal.values { modelContext.insert(StoredV3MigrationJournal(value)) }
    }

    /// v4 normalized rows are maintained on every durable mutation.  The
    /// legacy snapshot remains a compatibility/rollback payload, while paper,
    /// author, note, annotation and chunk queries can use first-class rows.
    /// Upserts are keyed by stable IDs; derived search rows are rebuildable.
    private func synchronizeV4Normalized(from snapshot: LibrarySnapshot) throws {
        let papers = try modelContext.fetch(FetchDescriptor<StoredV4Paper>())
        let paperIDs = Set(snapshot.papers.keys)
        for row in papers where !paperIDs.contains(row.literatureID) { modelContext.delete(row) }
        var paperByID = Dictionary(uniqueKeysWithValues: papers.map { ($0.literatureID, $0) })
        for value in snapshot.papers.values {
            let workflow: V4ReadingWorkflow? = nil
            if let row = paperByID[value.literatureID] {
                let updated = StoredV4Paper(value, workflow: workflow)
                row.title = updated.title; row.abstractText = updated.abstractText; row.doi = updated.doi; row.arxivID = updated.arxivID
                row.updatedAt = updated.updatedAt; row.isRead = updated.isRead; row.isFavorite = updated.isFavorite
                row.readingState = updated.readingState; row.priority = updated.priority
            } else {
                let row = StoredV4Paper(value, workflow: workflow); modelContext.insert(row); paperByID[value.literatureID] = row
            }
        }
        let authors = try modelContext.fetch(FetchDescriptor<StoredV4Author>())
        let authorIDs = Set(snapshot.authors.keys)
        for row in authors where !authorIDs.contains(row.recid) { modelContext.delete(row) }
        let authorByID = Dictionary(uniqueKeysWithValues: authors.map { ($0.recid, $0) })
        for value in snapshot.authors.values {
            if let row = authorByID[value.recid] {
                let updated = StoredV4Author(value); row.preferredName = updated.preferredName; row.hIndexAll = updated.hIndexAll
                row.hIndexState = updated.hIndexState; row.isSelf = updated.isSelf; row.updatedAt = updated.updatedAt
            } else { modelContext.insert(StoredV4Author(value)) }
        }
        for row in try modelContext.fetch(FetchDescriptor<StoredV4PaperAuthorLink>()) { modelContext.delete(row) }
        for link in snapshot.paperAuthorLinks { modelContext.insert(StoredV4PaperAuthorLink(paperID: link.paperID, authorRecid: link.authorRecid, position: link.position)) }
        for row in try modelContext.fetch(FetchDescriptor<StoredV4Chunk>()) { modelContext.delete(row) }
        for chunk in snapshot.evidenceChunks.values { modelContext.insert(StoredV4Chunk(chunk)) }
        for row in try modelContext.fetch(FetchDescriptor<StoredV4Note>()) { modelContext.delete(row) }
        for note in snapshot.notes.values { modelContext.insert(StoredV4Note(note)) }
        for row in try modelContext.fetch(FetchDescriptor<StoredV4Annotation>()) { modelContext.delete(row) }
        for annotation in snapshot.userEvidenceAnchors.values { modelContext.insert(StoredV4Annotation(annotation)) }
        for row in try modelContext.fetch(FetchDescriptor<StoredV4SearchIndexEntry>()) { modelContext.delete(row) }
        let index = V4LocalSearchIndex.rebuild(snapshot: snapshot)
        for entry in index.entries.values { modelContext.insert(StoredV4SearchIndexEntry(entry)) }
        // The bounded candidate index is part of the normal SwiftData write
        // path, not a benchmark-only projection.  Rebuildable search rows
        // remain derived data, while the exact posting lists use compact
        // binary IDs and are consulted by `V4NormalizedLibraryStore`.
        for row in try modelContext.fetch(FetchDescriptor<StoredV4SearchToken>()) { modelContext.delete(row) }
        var postings: [String: Set<Int>] = [:]
        for entry in index.entries.values {
            for token in Set(V4SearchTokenTerms.make(entry.text)) {
                postings[token, default: []].insert(entry.paperID)
            }
        }
        for (token, paperIDs) in postings {
            modelContext.insert(StoredV4SearchToken(token: token, paperIDs: Array(paperIDs)))
        }
    }

    /// V7 normal mutations update only the normalized entities and search
    /// postings affected by their stable IDs.  The two complete index values
    /// below are used solely to calculate a deterministic delta; no complete
    /// V4 table is deleted/reinserted after the initial one-time migration.
    private func synchronizeV4NormalizedIncrementally(from previous: LibrarySnapshot, to next: LibrarySnapshot) throws {
        let paperIDs = Set(previous.papers.keys).union(next.papers.keys).filter { previous.papers[$0] != next.papers[$0] }
        for paperID in paperIDs {
            let descriptor = FetchDescriptor<StoredV4Paper>(predicate: #Predicate { $0.literatureID == paperID })
            let existing = try modelContext.fetch(descriptor).first
            guard let value = next.papers[paperID] else {
                if let existing { modelContext.delete(existing) }
                continue
            }
            let updated = StoredV4Paper(value, workflow: nil)
            if let existing {
                existing.title = updated.title; existing.abstractText = updated.abstractText; existing.doi = updated.doi; existing.arxivID = updated.arxivID
                existing.updatedAt = updated.updatedAt; existing.isRead = updated.isRead; existing.isFavorite = updated.isFavorite
                existing.readingState = updated.readingState; existing.priority = updated.priority
            } else { modelContext.insert(updated) }
        }

        let authorIDs = Set(previous.authors.keys).union(next.authors.keys).filter { previous.authors[$0] != next.authors[$0] }
        for recid in authorIDs {
            let descriptor = FetchDescriptor<StoredV4Author>(predicate: #Predicate { $0.recid == recid })
            let existing = try modelContext.fetch(descriptor).first
            guard let value = next.authors[recid] else {
                if let existing { modelContext.delete(existing) }
                continue
            }
            let updated = StoredV4Author(value)
            if let existing {
                existing.preferredName = updated.preferredName; existing.hIndexAll = updated.hIndexAll
                existing.hIndexState = updated.hIndexState; existing.isSelf = updated.isSelf; existing.updatedAt = updated.updatedAt
            } else { modelContext.insert(updated) }
        }

        let changedLinks = previous.paperAuthorLinks.symmetricDifference(next.paperAuthorLinks)
        for link in changedLinks {
            let key = "\(link.paperID):\(link.authorRecid)"
            let descriptor = FetchDescriptor<StoredV4PaperAuthorLink>(predicate: #Predicate { $0.key == key })
            let existing = try modelContext.fetch(descriptor).first
            if next.paperAuthorLinks.contains(link) {
                if let existing { existing.position = link.position } else { modelContext.insert(StoredV4PaperAuthorLink(paperID: link.paperID, authorRecid: link.authorRecid, position: link.position)) }
            } else if let existing { modelContext.delete(existing) }
        }

        let changedChunks = Set(previous.evidenceChunks.keys).union(next.evidenceChunks.keys).filter { previous.evidenceChunks[$0] != next.evidenceChunks[$0] }
        for id in changedChunks {
            let descriptor = FetchDescriptor<StoredV4Chunk>(predicate: #Predicate { $0.id == id })
            let existing = try modelContext.fetch(descriptor).first
            guard let value = next.evidenceChunks[id] else { if let existing { modelContext.delete(existing) }; continue }
            let updated = StoredV4Chunk(value)
            if let existing { existing.paperID = updated.paperID; existing.documentHash = updated.documentHash; existing.page = updated.page; existing.text = updated.text; existing.textHash = updated.textHash }
            else { modelContext.insert(updated) }
        }

        let changedNotes = Set(previous.notes.keys).union(next.notes.keys).filter { previous.notes[$0] != next.notes[$0] }
        for id in changedNotes {
            let descriptor = FetchDescriptor<StoredV4Note>(predicate: #Predicate { $0.id == id })
            let existing = try modelContext.fetch(descriptor).first
            guard let value = next.notes[id] else { if let existing { modelContext.delete(existing) }; continue }
            let updated = StoredV4Note(value)
            if let existing { existing.paperID = updated.paperID; existing.body = updated.body; existing.updatedAt = updated.updatedAt }
            else { modelContext.insert(updated) }
        }

        let changedAnnotations = Set(previous.userEvidenceAnchors.keys).union(next.userEvidenceAnchors.keys).filter { previous.userEvidenceAnchors[$0] != next.userEvidenceAnchors[$0] }
        for id in changedAnnotations {
            let descriptor = FetchDescriptor<StoredV4Annotation>(predicate: #Predicate { $0.id == id })
            let existing = try modelContext.fetch(descriptor).first
            guard let value = next.userEvidenceAnchors[id] else { if let existing { modelContext.delete(existing) }; continue }
            let updated = StoredV4Annotation(value)
            if let existing {
                existing.paperID = updated.paperID; existing.documentHash = updated.documentHash; existing.page = updated.page
                existing.rangeStart = updated.rangeStart; existing.rangeEnd = updated.rangeEnd; existing.quote = updated.quote
                existing.quoteHash = updated.quoteHash; existing.status = updated.status; existing.updatedAt = updated.updatedAt
            } else { modelContext.insert(updated) }
        }

        try synchronizeV4SearchIndexIncrementally(from: previous, to: next)
    }

    private func synchronizeV4SearchIndexIncrementally(from previous: LibrarySnapshot, to next: LibrarySnapshot) throws {
        let oldIndex = V4LocalSearchIndex.rebuild(snapshot: previous)
        let newIndex = V4LocalSearchIndex.rebuild(snapshot: next)
        let entryIDs = Set(oldIndex.entries.keys).union(newIndex.entries.keys)
        var affectedPaperIDs = Set<Int>()
        for id in entryIDs where oldIndex.entries[id] != newIndex.entries[id] {
            if let old = oldIndex.entries[id] { affectedPaperIDs.insert(old.paperID) }
            if let new = newIndex.entries[id] { affectedPaperIDs.insert(new.paperID) }
        }
        guard !affectedPaperIDs.isEmpty else { return }

        for paperID in affectedPaperIDs {
            let descriptor = FetchDescriptor<StoredV4SearchIndexEntry>(predicate: #Predicate { $0.paperID == paperID })
            for row in try modelContext.fetch(descriptor) { modelContext.delete(row) }
            for entry in newIndex.entries.values where entry.paperID == paperID { modelContext.insert(StoredV4SearchIndexEntry(entry)) }
        }

        var affectedTokens = Set<String>()
        for entry in oldIndex.entries.values where affectedPaperIDs.contains(entry.paperID) { affectedTokens.formUnion(V4SearchTokenTerms.make(entry.text)) }
        for entry in newIndex.entries.values where affectedPaperIDs.contains(entry.paperID) { affectedTokens.formUnion(V4SearchTokenTerms.make(entry.text)) }
        for token in affectedTokens {
            let descriptor = FetchDescriptor<StoredV4SearchToken>(predicate: #Predicate { $0.token == token })
            let row = try modelContext.fetch(descriptor).first
            var paperIDs = Set(row?.paperIDs ?? [])
            paperIDs.subtract(affectedPaperIDs)
            for entry in newIndex.entries.values where affectedPaperIDs.contains(entry.paperID) && V4SearchTokenTerms.make(entry.text).contains(token) {
                paperIDs.insert(entry.paperID)
            }
            if paperIDs.isEmpty {
                if let row { modelContext.delete(row) }
            } else {
                let packed = StoredV4SearchToken(token: token, paperIDs: Array(paperIDs)).paperIDsJSON
                if let row { row.paperIDsJSON = packed }
                else { modelContext.insert(StoredV4SearchToken(token: token, paperIDs: Array(paperIDs))) }
            }
        }
    }

    private func retainV1SnapshotBackupIfNeeded(for document: StoredLibraryDocument) throws {
        guard document.schemaVersion < 2 else { return }
        let backups = try modelContext.fetch(FetchDescriptor<StoredV1SnapshotBackupV2>())
        if backups.isEmpty {
            modelContext.insert(StoredV1SnapshotBackupV2(sourceSchemaVersion: document.schemaVersion, snapshotData: document.snapshotData))
        }
        document.schemaVersion = 2
        try modelContext.save()
    }
}

/// Restores only an integrity-checked V1 snapshot into a caller-supplied empty
/// V1 container.  The caller controls the target path, so rollback cannot
/// silently overwrite an active V2 library.
enum SwiftDataV1Rollback {
    @MainActor
    static func restore(_ backup: StoredV1SnapshotBackupV2, into container: ModelContainer) throws {
        guard backup.sourceSchemaVersion == 1,
              StableHash.sha256(backup.snapshotData) == backup.checksum else {
            throw LatticeLensError.persistenceUnavailable("v1 rollback backup 校验失败")
        }
        let context = container.mainContext
        let existing = try context.fetch(FetchDescriptor<StoredLibraryDocument>())
        guard existing.isEmpty else { throw LatticeLensError.persistenceUnavailable("rollback target 必须为空") }
        context.insert(StoredLibraryDocument(schemaVersion: 1, snapshotData: backup.snapshotData))
        try context.save()
    }
}

enum LibraryStoreFactory {
    @MainActor
    static func makeDefault() -> any LibraryStoring {
        let schema = Schema(versionedSchema: LatticeLensSchemaV9.self)
        let storeURL = defaultStoreURL()
        do {
            // Final V8-core/V9-search activation is a distinct target, not
            // an in-place V7 schema open.  The coordinator copies and hashes
            // the complete V7 SQLite family, materializes a staging V8 typed
            // store, checks counts/IDs/link hashes, then V9 opens the
            // rebuildable local-search projection at that verified target.
            // A failed migration returns a read-only recovery store below;
            // it must never create a blank JSON library over user data.
            // Older local releases stored the V4/V7 SQLite family directly as
            // `Application Support/LatticeLens.store`, while the staged V8
            // coordinator uses `LatticeLens/Library-v7.store`.  If we only
            // probe the latter, a first launch after upgrading creates a new
            // empty V8 container and the UI appears to have lost every
            // author/paper.  Keep the current nested path preferred, but
            // explicitly discover the historical root family when the active
            // target does not yet exist.  The coordinator backs up and reads
            // the selected source before activating the new target; no source
            // family is overwritten or deleted by this discovery.
            try recoverLegacyStoreIfNeeded(storeURL: storeURL)
            do {
                let configuration = ModelConfiguration(schema: schema, url: storeURL)
                let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV9.self,
                                                   configurations: configuration)
                let context = ModelContext(container)
                if try context.fetch(FetchDescriptor<StoredV8StoreMarker>()).isEmpty {
                    // No V7 source means this is a genuinely new V8-core/V9
                    // library.  It is initialized from empty typed rows only;
                    // V7 generic rows are never introduced into a new active
                    // store.
                    try V8TypedStoreCodec.materialize(LibrarySnapshot(schemaVersion: 8, v3SchemaVersion: 3), in: context, sourceSchemaVersion: 8)
                }
                // V9 adds only a rebuildable token/reverse-token projection over
                // the active V8 rows.  Do this after a successful lightweight
                // schema migration, never by decoding a legacy store in place.
                if try !V9TypedSearchIndex.isCurrent(in: context) {
                    try V9TypedSearchIndex.rebuild(in: context)
                }
                return V8TypedLibraryStore(modelContainer: container)
            } catch {
                // A V8 store written by an earlier release may be perfectly
                // readable while the V8→V9 lightweight migration is rejected
                // by the installed SwiftData runtime (notably after adding
                // unique token rows).  V9 is only a rebuildable search
                // projection, so retain the verified V8 domain store and use
                // its bounded compatibility search until a later repair can
                // rebuild V9.  Never turn this recoverable case into a blank
                // read-only workspace.
                let compatibilitySchema = Schema(versionedSchema: LatticeLensSchemaV8.self)
                let compatibilityConfiguration = ModelConfiguration(schema: compatibilitySchema, url: storeURL)
                let compatibilityContainer = try ModelContainer(for: compatibilitySchema,
                                                                  configurations: compatibilityConfiguration)
                guard try !compatibilityContainer.mainContext.fetch(FetchDescriptor<StoredV8StoreMarker>()).isEmpty else {
                    throw error
                }
                return V8TypedLibraryStore(modelContainer: compatibilityContainer)
            }
        } catch {
            return V8MigrationBlockedStore(reason: "V9/V8 typed store 无法打开或迁移；原 V7 source 和已验证 backup 未被覆盖。\(type(of: error))")
        }
    }

    private static func defaultStoreURL() -> URL {
        // Every XCTest/fixture invocation supplies an explicitly project-local
        // root.  Never fall through to Application Support in that mode: a
        // host-free contract test must not even attempt to open a user's
        // library, regardless of which view-model initializer it exercises.
        if let testRoot = ProcessInfo.processInfo.environment["LATTICELENS_TEST_STORE_ROOT"], !testRoot.isEmpty {
            return URL(fileURLWithPath: testRoot, isDirectory: true).appending(path: "swiftdata/LatticeLens-v8.store")
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appending(path: "LatticeLens/Library-v8.store")
    }

    /// Candidate compatibility families, ordered from the current staged V7
    /// location to the pre-V7 root file used by early releases.  This helper
    /// is intentionally pure (it performs no filesystem probing) so migration
    /// path selection can be regression-tested without touching a user store.
    static func legacyV7StoreCandidates(applicationSupportRoot: URL? = nil) -> [URL] {
        let root: URL
        if let applicationSupportRoot {
            // An explicit root is used only by deterministic tests/diagnostic
            // callers and must win over a process-wide fixture environment.
            root = applicationSupportRoot
        } else if let testRoot = ProcessInfo.processInfo.environment["LATTICELENS_TEST_STORE_ROOT"], !testRoot.isEmpty {
            return [URL(fileURLWithPath: testRoot, isDirectory: true).appending(path: "swiftdata/LatticeLens-v7.store")]
        } else {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        }
        return [
            root.appending(path: "LatticeLens/Library-v7.store"),
            root.appending(path: "LatticeLens.store")
        ]
    }

    /// Repairs the upgrade state produced by early 1.0 builds.  Those builds
    /// could create and activate an empty V8 target before discovering the
    /// pre-V7 root family (`Application Support/LatticeLens.store`).  Once
    /// that placeholder exists, a simple `fileExists` check incorrectly
    /// suppresses migration forever and every subsequent launch paints an
    /// empty sidebar.  Only a structurally readable target with *no authors
    /// and no papers* is eligible; any non-empty active store is left alone.
    /// The placeholder is moved into the existing backup root before the
    /// staged migration, so neither the old source nor the previous target is
    /// overwritten or deleted.
    @MainActor
    static func recoverLegacyStoreIfNeeded(
        storeURL: URL,
        applicationSupportRoot: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let candidates = legacyV7StoreCandidates(applicationSupportRoot: applicationSupportRoot)
        guard let source = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else { return }
        let backupRoot = storeURL.deletingLastPathComponent()
            .appendingPathComponent("LatticeLens-StoreBackups", isDirectory: true)

        if fileManager.fileExists(atPath: storeURL.path) {
            guard isEmptyV8Placeholder(at: storeURL) else { return }
            try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
            let quarantineURL = backupRoot.appendingPathComponent(
                "preexisting-empty-v8-\(UUID().uuidString).store")
            try moveStoreFamily(from: storeURL, to: quarantineURL, fileManager: fileManager)
        }

        _ = try V8MigrationCoordinator.migrateV7ToV8(sourceURL: source, activeV8URL: storeURL,
                                                      backupRoot: backupRoot, fileManager: fileManager)
    }

    /// Returns false on any schema/open error.  Failing closed is important:
    /// an unknown or malformed target may contain user data and must never be
    /// quarantined merely because its rows cannot be inspected.
    @MainActor
    private static func isEmptyV8Placeholder(at url: URL) -> Bool {
        // A failed first launch may have left either a V8 or a V9 SQLite
        // family.  Opening only the V8 schema is insufficient for a V9
        // placeholder: SwiftData can reject the older model before we get a
        // chance to inspect its (empty) typed rows, which would leave the
        // legacy source permanently shadowed by a blank target.  Probe the
        // current schema first and fall back to V8 for stores created by the
        // migration coordinator.  This is a read-only count probe; no model
        // context is saved and any schema/open error fails closed.
        func probe<Versioned: VersionedSchema>(_ versioned: Versioned.Type) -> Bool {
            do {
                let schema = Schema(versionedSchema: versioned)
                let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
                let context = container.mainContext
                guard try !context.fetch(FetchDescriptor<StoredV8StoreMarker>()).isEmpty else { return false }
                let authors = try context.fetchCount(FetchDescriptor<StoredV8Author>())
                let papers = try context.fetchCount(FetchDescriptor<StoredV8Paper>())
                return authors == 0 && papers == 0
            } catch {
                return false
            }
        }
        return probe(LatticeLensSchemaV9.self) || probe(LatticeLensSchemaV8.self)
    }

    @MainActor
    private static func moveStoreFamily(from source: URL, to destination: URL,
                                        fileManager: FileManager) throws {
        guard !fileManager.fileExists(atPath: destination.path) else { throw V8MigrationCoordinatorError.activeTargetExists }
        for suffix in ["", "-wal", "-shm"] {
            let member = URL(fileURLWithPath: source.path + suffix)
            guard fileManager.fileExists(atPath: member.path) else { continue }
            try fileManager.moveItem(at: member, to: URL(fileURLWithPath: destination.path + suffix))
        }
    }

    private static func fallbackURL() -> URL {
        // The fallback path obeys the same XCTest isolation contract as the
        // SwiftData URL.  A failed test-store bootstrap must never redirect a
        // host-free test into a user's Application Support JSON library.
        if let testRoot = ProcessInfo.processInfo.environment["LATTICELENS_TEST_STORE_ROOT"], !testRoot.isEmpty {
            return URL(fileURLWithPath: testRoot, isDirectory: true).appending(path: "json/LatticeLens-fallback.json")
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appending(path: "LatticeLens/library-v1.json")
    }
}
