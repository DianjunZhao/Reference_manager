import Foundation
import SwiftData

enum V4SearchTokenTerms {
    static func make(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map(SearchNormalizer.normalize)
            .filter { !$0.isEmpty }
    }
}

// v4 keeps normalized rows authoritative for local product operations. The
// Codable LibrarySnapshot remains a compatibility/export format only.

@Model final class StoredV4Author {
    @Attribute(.unique) var recid: Int
    var preferredName: String
    var hIndexAll: Int?
    var hIndexState: String
    var isSelf: Bool
    var updatedAt: Date
    init(recid: Int, preferredName: String, hIndexAll: Int?, hIndexState: String, isSelf: Bool, updatedAt: Date) {
        self.recid = recid; self.preferredName = preferredName; self.hIndexAll = hIndexAll; self.hIndexState = hIndexState; self.isSelf = isSelf; self.updatedAt = updatedAt
    }
    init(_ value: Author) {
        recid = value.recid; preferredName = value.preferredName; hIndexAll = value.hIndex?.all
        hIndexState = value.hIndexState.rawValue; isSelf = value.isSelf; updatedAt = Date()
    }
}

@Model final class StoredV4Paper {
    @Attribute(.unique) var literatureID: Int
    var title: String
    var abstractText: String
    var doi: String?
    var arxivID: String?
    var updatedAt: Date?
    var isRead: Bool
    var isFavorite: Bool
    var readingState: String
    var priority: Int
    init(_ value: Paper, workflow: V4ReadingWorkflow? = nil) {
        literatureID = value.literatureID; title = value.displayTitle; abstractText = value.preferredAbstract ?? ""
        doi = value.doi; arxivID = value.arxivID; updatedAt = value.updated; isRead = value.isRead; isFavorite = value.isFavorite
        readingState = (workflow?.state ?? (value.isRead ? .reading : .inbox)).rawValue; priority = workflow?.priority ?? 0
    }
    init(literatureID: Int, title: String, abstractText: String = "", updatedAt: Date? = nil) {
        self.literatureID = literatureID; self.title = title; self.abstractText = abstractText; self.doi = nil; self.arxivID = nil
        self.updatedAt = updatedAt; self.isRead = false; self.isFavorite = false; self.readingState = V4ReadingWorkflowState.inbox.rawValue; self.priority = 0
    }
}

@Model final class StoredV4PaperAuthorLink {
    @Attribute(.unique) var key: String
    var paperID: Int
    var authorRecid: Int
    var position: Int
    init(paperID: Int, authorRecid: Int, position: Int) {
        key = "\(paperID):\(authorRecid)"; self.paperID = paperID; self.authorRecid = authorRecid; self.position = position
    }
}

@Model final class StoredV4Chunk {
    @Attribute(.unique) var id: String
    var paperID: Int
    var documentHash: String
    var page: Int
    var text: String
    var textHash: String
    init(id: String, paperID: Int, documentHash: String, page: Int, text: String, textHash: String) {
        self.id = id; self.paperID = paperID; self.documentHash = documentHash; self.page = page; self.text = text; self.textHash = textHash
    }
    init(_ value: EvidenceChunk) {
        id = value.id; paperID = value.paperID; documentHash = value.documentHash; page = value.page; text = value.text; textHash = value.textHash
    }
}

@Model final class StoredV4Note {
    @Attribute(.unique) var id: UUID
    var paperID: Int
    var body: String
    var updatedAt: Date
    init(_ value: UserNote) { id = value.id; paperID = value.paperID; body = value.body; updatedAt = value.updatedAt }
}

@Model final class StoredV4Annotation {
    @Attribute(.unique) var id: UUID
    var paperID: Int
    var documentHash: String?
    var page: Int?
    var rangeStart: Int?
    var rangeEnd: Int?
    var quote: String
    var quoteHash: String
    var status: String
    var updatedAt: Date
    init(_ value: UserEvidenceAnchor) {
        id = value.id; paperID = value.paperID; documentHash = value.documentHash; page = value.page; rangeStart = value.characterRangeStart
        rangeEnd = value.characterRangeEnd; quote = value.quote; quoteHash = value.quoteHash; status = value.status.rawValue; updatedAt = value.updatedAt
    }
}

@Model final class StoredV4SearchIndexEntry {
    @Attribute(.unique) var id: String
    var paperID: Int
    var field: String
    var normalizedText: String
    var page: Int?
    var quoteHash: String?
    init(_ value: V4SearchIndexEntry) {
        id = value.id; paperID = value.paperID; field = value.field; normalizedText = value.normalizedText; page = value.page; quoteHash = value.quoteHash
    }
}

/// An equality-indexed local term dictionary.  SwiftData does not expose a
/// portable FTS API across the supported macOS versions, so this compact token
/// table is the authoritative bounded candidate index for ⌘K.  The complete
/// source/snippet rows stay in `StoredV4SearchIndexEntry`; this model only
/// maps normalized terms to candidate paper IDs and is fully rebuildable.
@Model final class StoredV4SearchToken {
    @Attribute(.unique) var token: String
    var paperIDsJSON: Data

    init(token: String, paperIDs: [Int]) {
        self.token = token
        // A token such as "local" can legitimately have 20k postings.  JSON
        // decoding that list dominated warm-query time; a fixed-width local
        // posting encoding keeps all IDs exact while avoiding a JSON parser on
        // every keystroke.  The data is rebuildable from search-index rows.
        var packed = Data()
        packed.reserveCapacity(paperIDs.count * 4)
        for value in paperIDs.sorted() {
            let word = UInt32(bitPattern: Int32(clamping: value))
            packed.append(UInt8(word & 0xff))
            packed.append(UInt8((word >> 8) & 0xff))
            packed.append(UInt8((word >> 16) & 0xff))
            packed.append(UInt8((word >> 24) & 0xff))
        }
        self.paperIDsJSON = packed
    }

    var paperIDs: [Int] {
        let bytes = [UInt8](paperIDsJSON)
        guard bytes.count.isMultiple(of: 4) else { return [] }
        return stride(from: 0, to: bytes.count, by: 4).map { offset in
            let word = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) |
                (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
            return Int(Int32(bitPattern: word))
        }
    }
}

@Model final class StoredV4BackupManifest {
    @Attribute(.unique) var id: UUID
    var sourcePath: String
    var createdAt: Date
    var schemaVersion: Int
    var manifestJSON: Data
    init(id: UUID = UUID(), sourcePath: String, createdAt: Date = Date(), schemaVersion: Int, manifestJSON: Data) {
        self.id = id; self.sourcePath = sourcePath; self.createdAt = createdAt; self.schemaVersion = schemaVersion; self.manifestJSON = manifestJSON
    }
}

@Model final class StoredV4MigrationJournal {
    @Attribute(.unique) var id: UUID
    var phase: String
    var startedAt: Date
    var completedAt: Date?
    var preCount: Int
    var postCount: Int?
    var quarantinedCount: Int
    var preHash: String
    var postHash: String?
    var errorCategory: String?
    init(id: UUID = UUID(), phase: String, startedAt: Date = Date(), completedAt: Date? = nil, preCount: Int, postCount: Int? = nil,
         quarantinedCount: Int = 0, preHash: String, postHash: String? = nil, errorCategory: String? = nil) {
        self.id = id; self.phase = phase; self.startedAt = startedAt; self.completedAt = completedAt; self.preCount = preCount; self.postCount = postCount
        self.quarantinedCount = quarantinedCount; self.preHash = preHash; self.postHash = postHash; self.errorCategory = errorCategory
    }
}

enum LatticeLensSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }
    static var models: [any PersistentModel.Type] {
        LatticeLensSchemaV4.models + [StoredV4Author.self, StoredV4Paper.self, StoredV4PaperAuthorLink.self, StoredV4Chunk.self,
                                      StoredV4Note.self, StoredV4Annotation.self, StoredV4SearchIndexEntry.self,
                                      StoredV4BackupManifest.self, StoredV4MigrationJournal.self]
    }
}

enum LatticeLensMigrationPlanV5: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LatticeLensSchemaV1.self, LatticeLensSchemaV2.self, LatticeLensSchemaV3.self, LatticeLensSchemaV4.self, LatticeLensSchemaV5.self] }
    static var stages: [MigrationStage] {
        LatticeLensMigrationPlan.stages + [.lightweight(fromVersion: LatticeLensSchemaV4.self, toVersion: LatticeLensSchemaV5.self)]
    }
}

enum LatticeLensSchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }
    static var models: [any PersistentModel.Type] { LatticeLensSchemaV5.models + [StoredV4SearchToken.self] }
}

enum LatticeLensMigrationPlanV6: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LatticeLensSchemaV1.self, LatticeLensSchemaV2.self, LatticeLensSchemaV3.self, LatticeLensSchemaV4.self,
         LatticeLensSchemaV5.self, LatticeLensSchemaV6.self]
    }
    static var stages: [MigrationStage] {
        LatticeLensMigrationPlanV5.stages + [.lightweight(fromVersion: LatticeLensSchemaV5.self, toVersion: LatticeLensSchemaV6.self)]
    }
}

/// V7 removes the last active `LibrarySnapshot` blob from the production
/// SwiftData path.  Each record is stored independently, keyed by its stable
/// domain identity, so a note/read/tag mutation never rewrites the paper
/// corpus.  The Codable payload is deliberately per-entity rather than a
/// library-wide document: it preserves source compatibility for the rich v1–v4
/// value types while the surrounding columns and key make the row queryable,
/// incrementally replaceable and independently recoverable.
@Model final class StoredV7DomainRecord {
    @Attribute(.unique) var key: String
    var kind: String
    var recordID: String
    var payload: Data
    var updatedAt: Date

    init(key: String, kind: String, recordID: String, payload: Data, updatedAt: Date = Date()) {
        self.key = key; self.kind = kind; self.recordID = recordID; self.payload = payload; self.updatedAt = updatedAt
    }
}

/// A marker is written only after a complete legacy-snapshot import has been
/// committed.  Its absence means the V7 store has not yet selected normalized
/// records as active truth; it never means an empty user library.
@Model final class StoredV7StoreMarker {
    @Attribute(.unique) var key: String
    var schemaVersion: Int
    var materializedAt: Date
    var importedLegacyDocument: Bool

    /// `70` is prepared but not materialized; `71` is normalized active truth.
    /// Reusing the existing integer avoids changing the V7 model shape after
    /// it may already have been opened on this Mac.
    init(schemaVersion: Int = 70, materializedAt: Date = Date(), importedLegacyDocument: Bool = false) {
        key = "v7-normalized-active-store"; self.schemaVersion = schemaVersion
        self.materializedAt = materializedAt; self.importedLegacyDocument = importedLegacyDocument
    }
}

enum LatticeLensSchemaV7: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(7, 0, 0) }
    static var models: [any PersistentModel.Type] {
        LatticeLensSchemaV6.models + [StoredV7DomainRecord.self, StoredV7StoreMarker.self]
    }
}

enum LatticeLensMigrationPlanV7: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LatticeLensSchemaV1.self, LatticeLensSchemaV2.self, LatticeLensSchemaV3.self, LatticeLensSchemaV4.self,
         LatticeLensSchemaV5.self, LatticeLensSchemaV6.self, LatticeLensSchemaV7.self]
    }
    static var stages: [MigrationStage] {
        LatticeLensMigrationPlanV6.stages + [.lightweight(fromVersion: LatticeLensSchemaV6.self, toVersion: LatticeLensSchemaV7.self)]
    }
}

// MARK: - V8 final typed store

/// V8 deliberately has one SwiftData entity for each active domain family.
/// It must never be collapsed back into a `kind + payload` table: the
/// compatibility-only V7 rows remain readable as an import/rollback source,
/// while V8 owns the live rows used by the product.  A few domain-specific
/// `...Data` columns encode nested value arrays (titles, authors, anchor IDs,
/// etc.); they are not a generic cross-domain payload and every row remains
/// queryable by its stable identity and its primary scalar fields.
@Model final class StoredV8Author {
    @Attribute(.unique) var recid: Int
    var preferredName: String; var nativeNamesData: Data; var bai: String?; var categoriesData: Data
    var hIndexData: Data?; var hIndexState: String; var isTracked: Bool; var lastSyncedAt: Date?
    var lastCheckpointAt: Date?; var lastSuccessfulSyncAt: Date?
    init(_ value: Author) throws {
        recid = value.recid; preferredName = value.preferredName; nativeNamesData = try JSONEncoder.latticeLens.encode(value.nativeNames)
        bai = value.bai; categoriesData = try JSONEncoder.latticeLens.encode(value.arxivCategories)
        hIndexData = try value.hIndex.map { try JSONEncoder.latticeLens.encode($0) }; hIndexState = value.hIndexState.rawValue
        isTracked = value.isTracked; lastSyncedAt = value.lastSyncedAt; lastCheckpointAt = value.lastCheckpointAt; lastSuccessfulSyncAt = value.lastSuccessfulSyncAt
    }
    func decoded() throws -> Author {
        Author(recid: recid, preferredName: preferredName, nativeNames: try JSONDecoder.latticeLens.decode([String].self, from: nativeNamesData), bai: bai,
               arxivCategories: try JSONDecoder.latticeLens.decode(Set<String>.self, from: categoriesData),
               hIndex: try hIndexData.map { try JSONDecoder.latticeLens.decode(HIndexSnapshot.self, from: $0) },
               hIndexState: HIndexState(rawValue: hIndexState) ?? .unknown, isTracked: isTracked, lastSyncedAt: lastSyncedAt,
               lastCheckpointAt: lastCheckpointAt, lastSuccessfulSyncAt: lastSuccessfulSyncAt)
    }
}

@Model final class StoredV8Paper {
    @Attribute(.unique) var literatureID: Int
    var title: String; var abstractText: String; var titlesData: Data; var abstractsData: Data; var figuresData: Data
    var contributorsData: Data; var documentsData: Data; var preprintDate: Date?; var earliestDate: Date?; var publicationYear: Int?; var arxivID: String?
    var categoriesData: Data; var doi: String?; var citationCount: Int?; var publicationStatus: String?; var updated: Date?
    var firstSeenAt: Date; var isRead: Bool; var readAt: Date?; var isFavorite: Bool
    init(_ value: Paper) throws {
        literatureID = value.literatureID; title = value.displayTitle; abstractText = value.preferredAbstract ?? ""
        titlesData = try JSONEncoder.latticeLens.encode(value.titles); abstractsData = try JSONEncoder.latticeLens.encode(value.abstracts)
        figuresData = try JSONEncoder.latticeLens.encode(value.figures); contributorsData = try JSONEncoder.latticeLens.encode(value.contributors)
        documentsData = try JSONEncoder.latticeLens.encode(value.documents); preprintDate = value.preprintDate; earliestDate = value.earliestDate; publicationYear = value.publicationYear
        arxivID = value.arxivID; categoriesData = try JSONEncoder.latticeLens.encode(value.arxivCategories); doi = value.doi
        citationCount = value.citationCount; publicationStatus = value.publicationStatus; updated = value.updated; firstSeenAt = value.firstSeenAt
        isRead = value.isRead; readAt = value.readAt; isFavorite = value.isFavorite
    }
    func decoded() throws -> Paper {
        Paper(literatureID: literatureID, titles: try JSONDecoder.latticeLens.decode([PaperTitle].self, from: titlesData),
              abstracts: try JSONDecoder.latticeLens.decode([PaperAbstract].self, from: abstractsData), preprintDate: preprintDate,
              earliestDate: earliestDate, publicationYear: publicationYear, arxivID: arxivID, arxivCategories: try JSONDecoder.latticeLens.decode([String].self, from: categoriesData),
              doi: doi, citationCount: citationCount, publicationStatus: publicationStatus, updated: updated,
              figures: try JSONDecoder.latticeLens.decode([PaperFigure].self, from: figuresData),
              contributors: try JSONDecoder.latticeLens.decode([PaperContributor].self, from: contributorsData),
              documents: try JSONDecoder.latticeLens.decode([PaperDocument].self, from: documentsData), firstSeenAt: firstSeenAt,
              isRead: isRead, readAt: readAt, isFavorite: isFavorite)
    }
}

@Model final class StoredV8PaperAuthorLink {
    @Attribute(.unique) var key: String; var paperID: Int; var authorRecid: Int; var position: Int
    init(_ value: PaperAuthorLink) { key = "\(value.paperID):\(value.authorRecid)"; paperID = value.paperID; authorRecid = value.authorRecid; position = value.position }
    func decoded() -> PaperAuthorLink { PaperAuthorLink(paperID: paperID, authorRecid: authorRecid, position: position) }
}

@Model final class StoredV8HIndexSnapshot {
    @Attribute(.unique) var authorRecid: Int; var all: Int; var payloadData: Data
    init(_ value: HIndexSnapshot) throws { authorRecid = value.authorRecid; all = value.all; payloadData = try JSONEncoder.latticeLens.encode(value) }
    func decoded() throws -> HIndexSnapshot { try JSONDecoder.latticeLens.decode(HIndexSnapshot.self, from: payloadData) }
}

@Model final class StoredV8SyncCheckpoint {
    @Attribute(.unique) var jobID: String; var jobKind: String; var generationID: String; var state: String; var updatedAt: Date; var checkpointData: Data
    init(_ value: SyncCheckpoint) throws { jobID = value.jobID; jobKind = value.jobKind; generationID = value.generationID; state = value.state.rawValue; updatedAt = value.updatedAt; checkpointData = try JSONEncoder.latticeLens.encode(value) }
    func decoded() throws -> SyncCheckpoint { try JSONDecoder.latticeLens.decode(SyncCheckpoint.self, from: checkpointData) }
}

@Model final class StoredV8ReadingWorkflowState {
    @Attribute(.unique) var paperID: Int; var isRead: Bool; var isFavorite: Bool; var readAt: Date?; var updatedAt: Date
    init(_ value: ReadingState) { paperID = value.paperID; isRead = value.isRead; isFavorite = value.isFavorite; readAt = value.readAt; updatedAt = value.updatedAt }
    func decoded() -> ReadingState { ReadingState(paperID: paperID, isRead: isRead, readAt: readAt, isFavorite: isFavorite, updatedAt: updatedAt) }
}

@Model final class StoredV8Note {
    @Attribute(.unique) var id: UUID; var paperID: Int; var body: String; var createdAt: Date; var updatedAt: Date
    init(_ value: UserNote) { id = value.id; paperID = value.paperID; body = value.body; createdAt = value.createdAt; updatedAt = value.updatedAt }
    func decoded() -> UserNote { UserNote(id: id, paperID: paperID, body: body, createdAt: createdAt, updatedAt: updatedAt) }
}

@Model final class StoredV8Tag {
    @Attribute(.unique) var id: UUID; var name: String; var colorName: String?; var createdAt: Date
    init(_ value: LibraryTag) { id = value.id; name = value.name; colorName = value.colorName; createdAt = value.createdAt }
    func decoded() -> LibraryTag { LibraryTag(id: id, name: name, colorName: colorName, createdAt: createdAt) }
}

@Model final class StoredV8PaperTagLink {
    @Attribute(.unique) var key: String; var paperID: Int; var tagID: UUID
    init(_ value: PaperTagLink) { key = "\(value.paperID):\(value.tagID.uuidString)"; paperID = value.paperID; tagID = value.tagID }
    func decoded() -> PaperTagLink { PaperTagLink(paperID: paperID, tagID: tagID) }
}

@Model final class StoredV8Collection {
    @Attribute(.unique) var id: UUID; var name: String; var createdAt: Date
    init(_ value: PaperCollection) { id = value.id; name = value.name; createdAt = value.createdAt }
    func decoded() -> PaperCollection { PaperCollection(id: id, name: name, createdAt: createdAt) }
}

@Model final class StoredV8PaperCollectionLink {
    @Attribute(.unique) var key: String; var collectionID: UUID; var paperID: Int; var addedAt: Date
    init(_ value: CollectionPaperLink) { key = "\(value.collectionID.uuidString):\(value.paperID)"; collectionID = value.collectionID; paperID = value.paperID; addedAt = value.addedAt }
    func decoded() -> CollectionPaperLink { CollectionPaperLink(collectionID: collectionID, paperID: paperID, addedAt: addedAt) }
}

/// A bounded, typed family for AI-derived artifacts. `workflowKind` is an AI
/// artifact discriminator, not a generic library-domain discriminator.
@Model final class StoredV8AIArtifact {
    @Attribute(.unique) var cacheKey: String; var paperID: Int; var workflowKind: String; var createdAt: Date; var artifactData: Data
    init(cacheKey: String, paperID: Int, workflowKind: String, createdAt: Date, artifactData: Data) { self.cacheKey = cacheKey; self.paperID = paperID; self.workflowKind = workflowKind; self.createdAt = createdAt; self.artifactData = artifactData }
}

@Model final class StoredV8CitationSnapshot {
    @Attribute(.unique) var id: String; var paperID: Int; var citationCount: Int; var fetchedAt: Date
    init(_ value: CitationSnapshot) { id = value.id; paperID = value.paperID; citationCount = value.citationCount; fetchedAt = value.fetchedAt }
    func decoded() -> CitationSnapshot { CitationSnapshot(paperID: paperID, citationCount: citationCount, fetchedAt: fetchedAt) }
}

@Model final class StoredV8BibTeXRecord {
    @Attribute(.unique) var paperID: Int; var sourceURL: String; var sourceFetchedAt: Date; var contents: String
    init(_ value: BibTeXRecord) { paperID = value.paperID; sourceURL = value.sourceURL.absoluteString; sourceFetchedAt = value.sourceFetchedAt; contents = value.contents }
    func decoded() throws -> BibTeXRecord { guard let url = URL(string: sourceURL) else { throw LatticeLensError.persistenceUnavailable("V8 BibTeX URL 无法解码") }; return BibTeXRecord(paperID: paperID, sourceURL: url, sourceFetchedAt: sourceFetchedAt, contents: contents) }
}

@Model final class StoredV8FullTextDocument {
    @Attribute(.unique) var documentID: String; var paperID: Int; var sourceURL: String; var sourceKind: String; var sha256: String; var byteCount: Int
    var localFilename: String?; var pageCount: Int?; var extractionState: String; var downloadedAt: Date?; var lastErrorCategory: String?
    init(_ value: FullTextDocument) { documentID = value.id; paperID = value.paperID; sourceURL = value.sourceURL.absoluteString; sourceKind = value.sourceKind.rawValue; sha256 = value.sha256; byteCount = value.byteCount; localFilename = value.localFilename; pageCount = value.pageCount; extractionState = value.extractionState.rawValue; downloadedAt = value.downloadedAt; lastErrorCategory = value.lastErrorCategory }
    func decoded() throws -> FullTextDocument { guard let url = URL(string: sourceURL), let kind = FullTextSourceKind(rawValue: sourceKind), let state = FullTextExtractionState(rawValue: extractionState) else { throw LatticeLensError.persistenceUnavailable("V8 full-text document 无法解码") }; return FullTextDocument(paperID: paperID, sourceURL: url, sourceKind: kind, sha256: sha256, byteCount: byteCount, localFilename: localFilename, pageCount: pageCount, extractionState: state, downloadedAt: downloadedAt, lastErrorCategory: lastErrorCategory) }
}

@Model final class StoredV8CitationEdge {
    @Attribute(.unique) var id: String; var fromPaperID: Int; var toPaperID: Int; var sourceURL: String; var fetchedAt: Date; var query: String; var batchID: UUID
    init(_ value: CitationEdge) { id = value.id; fromPaperID = value.fromPaperID; toPaperID = value.toPaperID; sourceURL = value.sourceURL.absoluteString; fetchedAt = value.fetchedAt; query = value.query; batchID = value.batchID }
    func decoded() throws -> CitationEdge { guard let url = URL(string: sourceURL) else { throw LatticeLensError.persistenceUnavailable("V8 citation edge URL 无法解码") }; return CitationEdge(id: id, fromPaperID: fromPaperID, toPaperID: toPaperID, sourceURL: url, fetchedAt: fetchedAt, query: query, batchID: batchID) }
}

@Model final class StoredV8CoauthorEdge {
    @Attribute(.unique) var id: String; var authorRecid: Int; var coauthorRecid: Int; var sourcePaperID: Int; var sourceURL: String; var fetchedAt: Date; var query: String; var batchID: UUID
    init(_ value: CoauthorEdge) { id = value.id; authorRecid = value.authorRecid; coauthorRecid = value.coauthorRecid; sourcePaperID = value.sourcePaperID; sourceURL = value.sourceURL.absoluteString; fetchedAt = value.fetchedAt; query = value.query; batchID = value.batchID }
    func decoded() throws -> CoauthorEdge { guard let url = URL(string: sourceURL) else { throw LatticeLensError.persistenceUnavailable("V8 coauthor edge URL 无法解码") }; return CoauthorEdge(id: id, authorRecid: authorRecid, coauthorRecid: coauthorRecid, sourcePaperID: sourcePaperID, sourceURL: url, fetchedAt: fetchedAt, query: query, batchID: batchID) }
}

@Model final class StoredV8CloudRecordState {
    @Attribute(.unique) var recordID: String; var recordType: String; var fieldHash: String; var pushedAt: Date?; var pulledAt: Date?
    init(_ value: CloudSyncRecordState) { recordID = value.recordID; recordType = value.recordType; fieldHash = value.fieldHash; pushedAt = value.pushedAt; pulledAt = value.pulledAt }
    func decoded() -> CloudSyncRecordState { CloudSyncRecordState(recordID: recordID, recordType: recordType, fieldHash: fieldHash, pushedAt: pushedAt, pulledAt: pulledAt) }
}

@Model final class StoredV8ConflictCopy {
    @Attribute(.unique) var id: UUID; var recordID: String; var originalFieldHash: String; var conflictingFieldHash: String; var payload: String; var createdAt: Date
    init(_ value: ConflictCopy) { id = value.id; recordID = value.recordID; originalFieldHash = value.originalFieldHash; conflictingFieldHash = value.conflictingFieldHash; payload = value.payload; createdAt = value.createdAt }
    func decoded() -> ConflictCopy { ConflictCopy(id: id, recordID: recordID, originalFieldHash: originalFieldHash, conflictingFieldHash: conflictingFieldHash, payload: payload, createdAt: createdAt) }
}

@Model final class StoredV8ContentBlob {
    // `hash` is an NSObject/KVC selector whose value is an NSNumber.  Using it
    // as a String-backed SwiftData field produces a runtime NSNumber→NSString
    // cast abort, so the persistence name must differ from `ContentBlob.hash`.
    @Attribute(.unique) var blobHash: String; var byteCount: Int; var localFilename: String?; var referenceCount: Int; var createdAt: Date
    init(_ value: ContentBlob) { blobHash = value.hash; byteCount = value.byteCount; localFilename = value.localFilename; referenceCount = value.referenceCount; createdAt = value.createdAt }
    func decoded() -> ContentBlob { ContentBlob(hash: blobHash, byteCount: byteCount, localFilename: localFilename, referenceCount: referenceCount, createdAt: createdAt) }
}

@Model final class StoredV8OrphanedBlobDeletion {
    @Attribute(.unique) var blobHash: String; var filename: String; var byteCount: Int; var retryCount: Int
    var lastErrorCategory: String; var createdAt: Date; var updatedAt: Date
    init(_ value: OrphanedBlobDeletion) {
        blobHash = value.blobHash; filename = value.filename; byteCount = value.byteCount; retryCount = value.retryCount
        lastErrorCategory = value.lastErrorCategory; createdAt = value.createdAt; updatedAt = value.updatedAt
    }
    func decoded() -> OrphanedBlobDeletion {
        OrphanedBlobDeletion(blobHash: blobHash, filename: filename, byteCount: byteCount, retryCount: retryCount,
                             lastErrorCategory: lastErrorCategory, createdAt: createdAt, updatedAt: updatedAt)
    }
}

@Model final class StoredV8DocumentReference {
    @Attribute(.unique) var id: String; var paperID: Int; var documentHash: String; var sourceURL: String; var sourceKind: String; var contentBlobHash: String; var isDeleted: Bool
    init(_ value: DocumentReference) { id = value.id; paperID = value.paperID; documentHash = value.documentHash; sourceURL = value.sourceURL.absoluteString; sourceKind = value.sourceKind.rawValue; contentBlobHash = value.contentBlobHash; isDeleted = value.isDeleted }
    func decoded() throws -> DocumentReference { guard let url = URL(string: sourceURL), let kind = FullTextSourceKind(rawValue: sourceKind) else { throw LatticeLensError.persistenceUnavailable("V8 document reference 无法解码") }; return DocumentReference(id: id, paperID: paperID, documentHash: documentHash, sourceURL: url, sourceKind: kind, contentBlobHash: contentBlobHash, isDeleted: isDeleted) }
}

@Model final class StoredV8EvidenceChunk {
    @Attribute(.unique) var id: String; var paperID: Int; var documentHash: String; var page: Int; var section: String?; var rangeStart: Int; var rangeEnd: Int; var text: String; var textHash: String
    init(_ value: EvidenceChunk) { id = value.id; paperID = value.paperID; documentHash = value.documentHash; page = value.page; section = value.section; rangeStart = value.characterRangeStart; rangeEnd = value.characterRangeEnd; text = value.text; textHash = value.textHash }
    func decoded() -> EvidenceChunk { EvidenceChunk(id: id, paperID: paperID, documentHash: documentHash, page: page, section: section, characterRangeStart: rangeStart, characterRangeEnd: rangeEnd, text: text, textHash: textHash) }
}

@Model final class StoredV8EvidenceAnchor {
    @Attribute(.unique) var id: String; var paperID: Int; var sourceKind: String; var page: Int?; var section: String?; var quote: String; var quoteHash: String; var figureKey: String?
    init(_ value: EvidenceAnchor) { id = value.id; paperID = value.paperID; sourceKind = value.sourceKind.rawValue; page = value.page; section = value.section; quote = value.quote; quoteHash = value.quoteHash; figureKey = value.figureKey }
    func decoded() throws -> EvidenceAnchor { guard let kind = EvidenceSourceKind(rawValue: sourceKind) else { throw LatticeLensError.persistenceUnavailable("V8 evidence anchor 无法解码") }; return EvidenceAnchor(id: id, paperID: paperID, sourceKind: kind, page: page, section: section, quote: quote, quoteHash: quoteHash, figureKey: figureKey) }
}

@Model final class StoredV8UserAnnotation {
    @Attribute(.unique) var id: UUID; var paperID: Int; var documentHash: String?; var sourceKind: String; var page: Int?; var rangeStart: Int?; var rangeEnd: Int?; var quote: String; var quoteHash: String; var colorName: String; var label: String; var note: String; var status: String; var createdAt: Date; var updatedAt: Date
    init(_ value: UserEvidenceAnchor) { id = value.id; paperID = value.paperID; documentHash = value.documentHash; sourceKind = value.sourceKind.rawValue; page = value.page; rangeStart = value.characterRangeStart; rangeEnd = value.characterRangeEnd; quote = value.quote; quoteHash = value.quoteHash; colorName = value.colorName; label = value.label; note = value.note; status = value.status.rawValue; createdAt = value.createdAt; updatedAt = value.updatedAt }
    func decoded() throws -> UserEvidenceAnchor { guard let kind = EvidenceSourceKind(rawValue: sourceKind), let status = UserEvidenceAnchorStatus(rawValue: status) else { throw LatticeLensError.persistenceUnavailable("V8 annotation 无法解码") }; return UserEvidenceAnchor(id: id, paperID: paperID, documentHash: documentHash, sourceKind: kind, page: page, characterRangeStart: rangeStart, characterRangeEnd: rangeEnd, quote: quote, quoteHash: quoteHash, colorName: colorName, label: label, note: note, status: status, createdAt: createdAt, updatedAt: updatedAt) }
}

@Model final class StoredV8RevisionSnapshot { @Attribute(.unique) var id: String; var paperID: Int; var revisionData: Data; init(_ value: PaperRevisionSnapshot) throws { id = value.id; paperID = value.paperID; revisionData = try JSONEncoder.latticeLens.encode(value) } }
@Model final class StoredV8RadarEvent { @Attribute(.unique) var id: UUID; var paperID: Int; var eventKind: String; var acknowledged: Bool; var eventData: Data; init(_ value: RadarEvent) throws { id = value.id; paperID = value.paperID; eventKind = value.eventKind.rawValue; acknowledged = value.isAcknowledged; eventData = try JSONEncoder.latticeLens.encode(value) } }
@Model final class StoredV8AuthorIndexGeneration { @Attribute(.unique) var id: String; var state: String; var generationData: Data; init(_ value: AuthorIndexGeneration) throws { id = value.id; state = value.state.rawValue; generationData = try JSONEncoder.latticeLens.encode(value) } }
@Model final class StoredV8SavedQuery { @Attribute(.unique) var id: UUID; var name: String; var query: String; var paused: Bool; var queryData: Data; init(_ value: SavedInspireQuery) throws { id = value.id; name = value.name; query = value.query; paused = value.isPaused; queryData = try JSONEncoder.latticeLens.encode(value) } }
@Model final class StoredV8SyncBatchV3 { @Attribute(.unique) var id: UUID; var jobID: String; var generationID: String; var state: String; var batchData: Data; init(_ value: SyncBatchV3) throws { id = value.id; jobID = value.jobID; generationID = value.generationID; state = value.state.rawValue; batchData = try JSONEncoder.latticeLens.encode(value) } }
@Model final class StoredV8SyncJobEvent { @Attribute(.unique) var id: UUID; var jobID: String; var kind: String; var eventData: Data; init(_ value: SyncJobEvent) throws { id = value.id; jobID = value.jobID; kind = value.kind.rawValue; eventData = try JSONEncoder.latticeLens.encode(value) } }
@Model final class StoredV8SyncBatch { @Attribute(.unique) var id: UUID; var jobID: String; var state: String; var batchData: Data; init(_ value: SyncBatch) throws { id = value.id; jobID = value.jobID; state = value.state.rawValue; batchData = try JSONEncoder.latticeLens.encode(value) } }
@Model final class StoredV8Workspace { @Attribute(.unique) var id: UUID; var name: String; var note: String; var updatedAt: Date; var orderData: Data; var frozenExportHash: String?; init(_ value: PaperWorkspace) throws { id = value.id; name = value.name; note = value.note; updatedAt = value.updatedAt; orderData = try JSONEncoder.latticeLens.encode(value.sortOrder); frozenExportHash = value.frozenExportHash } }
@Model final class StoredV8WorkspacePaperLink { @Attribute(.unique) var key: String; var workspaceID: UUID; var paperID: Int; var addedAt: Date; var sortIndex: Int; init(_ value: WorkspacePaperLink) { key = "\(value.workspaceID.uuidString):\(value.paperID)"; workspaceID = value.workspaceID; paperID = value.paperID; addedAt = value.addedAt; sortIndex = value.sortIndex } }
@Model final class StoredV8PhysicsContract { @Attribute(.unique) var id: UUID; var workspaceID: UUID; var rowKeysData: Data; var createdAt: Date; var updatedAt: Date; init(_ value: PhysicsContract) throws { id = value.id; workspaceID = value.workspaceID; rowKeysData = try JSONEncoder.latticeLens.encode(value.rowKeys); createdAt = value.createdAt; updatedAt = value.updatedAt } }
@Model final class StoredV8PhysicsCell { @Attribute(.unique) var id: UUID; var workspaceID: UUID; var paperID: Int; var rowKey: String; var value: String?; var unit: String?; var status: String; var anchorIDsData: Data; var extractionVersion: String; var sourceDocumentHash: String?; var updatedAt: Date; init(_ value: PhysicsContractCell) throws { id = value.id; workspaceID = value.workspaceID; paperID = value.paperID; rowKey = value.rowKey; self.value = value.value; unit = value.unit; status = value.status.rawValue; anchorIDsData = try JSONEncoder.latticeLens.encode(value.evidenceAnchorIDs); extractionVersion = value.extractionVersion; sourceDocumentHash = value.sourceDocumentHash; updatedAt = value.updatedAt } }
@Model final class StoredV8NotebookEntry { @Attribute(.unique) var id: UUID; var paperID: Int; var title: String; var body: String; var createdAt: Date; var updatedAt: Date; init(id: UUID, paperID: Int, title: String, body: String, createdAt: Date, updatedAt: Date) { self.id = id; self.paperID = paperID; self.title = title; self.body = body; self.createdAt = createdAt; self.updatedAt = updatedAt } }
@Model final class StoredV8NotebookAnchorLink { @Attribute(.unique) var key: String; var entryID: UUID; var anchorID: String; var sortIndex: Int; init(entryID: UUID, anchorID: String, sortIndex: Int) { key = "\(entryID.uuidString):\(anchorID)"; self.entryID = entryID; self.anchorID = anchorID; self.sortIndex = sortIndex } }
@Model final class StoredV8ImportRecord { @Attribute(.unique) var id: UUID; var format: String; var paperID: Int?; var importData: Data; init(_ value: V3ImportedBibliography) throws { id = value.id; format = value.format.rawValue; paperID = value.matchedPaperID; importData = try JSONEncoder.latticeLens.encode(value) } }
@Model final class StoredV8ImportConflict {
    @Attribute(.unique) var key: String
    var importedID: UUID
    var paperID: Int
    var status: String
    var fieldsData: Data

    init(_ value: V3ImportConflict) throws {
        key = value.importedID.uuidString
        importedID = value.importedID
        paperID = value.paperID
        status = value.status.rawValue
        // Keep the scalar column name stable for existing V8 stores while
        // upgrading its Codable payload from a field list to the full audit
        // record (including explicitly accepted fields).
        fieldsData = try JSONEncoder.latticeLens.encode(value)
    }

    func decoded() throws -> V3ImportConflict {
        if let value = try? JSONDecoder.latticeLens.decode(V3ImportConflict.self, from: fieldsData) { return value }
        // V8 rows written before field-level consent stored only `[String]`.
        let fields = try JSONDecoder.latticeLens.decode([String].self, from: fieldsData)
        return V3ImportConflict(importedID: importedID, paperID: paperID, fields: fields,
                                status: V3ImportReviewStatus(rawValue: status) ?? .pending)
    }
}
@Model final class StoredV8ExportTransaction { @Attribute(.unique) var id: UUID; var format: String; var state: String; var createdAt: Date; var transactionData: Data; init(_ value: ExportRecord) throws { id = value.id; format = value.format.rawValue; state = value.succeeded ? "succeeded" : (value.errorCategory == nil ? "prepared" : "failed"); createdAt = value.createdAt; transactionData = try JSONEncoder.latticeLens.encode(value) } }
@Model final class StoredV8ProviderRunProvenance { @Attribute(.unique) var id: String; var paperID: Int; var workflowKind: String; var provenanceData: Data; init(id: String, paperID: Int, workflowKind: String, provenanceData: Data) { self.id = id; self.paperID = paperID; self.workflowKind = workflowKind; self.provenanceData = provenanceData } }
@Model final class StoredV8SearchIndexState { @Attribute(.unique) var key: String; var revision: Int; var rebuiltAt: Date; var indexHash: String; init(revision: Int, rebuiltAt: Date, indexHash: String) { key = "search-index"; self.revision = revision; self.rebuiltAt = rebuiltAt; self.indexHash = indexHash } }
@Model final class StoredV8BundleRecord { @Attribute(.unique) var id: UUID; var direction: String; var state: String; var manifestHash: String; var createdAt: Date; init(id: UUID, direction: String, state: String, manifestHash: String, createdAt: Date) { self.id = id; self.direction = direction; self.state = state; self.manifestHash = manifestHash; self.createdAt = createdAt } }
@Model final class StoredV8MigrationJournal { @Attribute(.unique) var id: UUID; var phase: String; var startedAt: Date; var completedAt: Date?; var journalData: Data; init(_ value: V3MigrationJournalEntry) throws { id = value.id; phase = value.phase; startedAt = value.startedAt; completedAt = value.completedAt; journalData = try JSONEncoder.latticeLens.encode(value) } }
@Model final class StoredV8StoreBackupManifest { @Attribute(.unique) var id: UUID; var schemaVersion: Int; var createdAt: Date; var manifestHash: String; var manifestData: Data; init(id: UUID, schemaVersion: Int, createdAt: Date, manifestHash: String, manifestData: Data) { self.id = id; self.schemaVersion = schemaVersion; self.createdAt = createdAt; self.manifestHash = manifestHash; self.manifestData = manifestData } }

/// Quarantine is active evidence state, not a flag reconstructed from an
/// export snapshot.  Keeping one stable row per anchor lets validator failures
/// survive relaunch without forcing a full-library rewrite.
@Model final class StoredV8QuarantinedEvidence {
    @Attribute(.unique) var evidenceID: String; var quarantinedAt: Date
    init(evidenceID: String, quarantinedAt: Date = Date()) { self.evidenceID = evidenceID; self.quarantinedAt = quarantinedAt }
}

/// This marker is the only V8 activation switch.  Its presence with
/// `schemaVersion == 80` means the V8 typed tables are the active truth; V7
/// records are never queried by the normal V8 repository path.
@Model final class StoredV8StoreMarker {
    @Attribute(.unique) var key: String; var schemaVersion: Int; var materializedAt: Date; var sourceSchemaVersion: Int; var semanticHash: String
    init(schemaVersion: Int = 80, materializedAt: Date = Date(), sourceSchemaVersion: Int = 7, semanticHash: String) { key = "v8-typed-active-store"; self.schemaVersion = schemaVersion; self.materializedAt = materializedAt; self.sourceSchemaVersion = sourceSchemaVersion; self.semanticHash = semanticHash }
}

/// V9 adds the final active-store local-search projection without weakening
/// the V8 typed rows.  `StoredV9PaperSearchTerm` is the reverse index needed
/// to update a single paper without scanning every token row; the posting row
/// then answers a query without materialising the complete library snapshot.
@Model final class StoredV9PaperSearchTerm {
    @Attribute(.unique) var key: String
    var paperID: Int
    var token: String

    init(paperID: Int, token: String) {
        key = "\(paperID)|\(token)"
        self.paperID = paperID
        self.token = token
    }
}

@Model final class StoredV9SearchToken {
    @Attribute(.unique) var token: String
    var paperIDsData: Data
    var updatedAt: Date

    init(token: String, paperIDs: Set<Int>, updatedAt: Date = Date()) {
        self.token = token
        self.paperIDsData = Self.encode(paperIDs)
        self.updatedAt = updatedAt
    }

    var paperIDs: Set<Int> { Self.decode(paperIDsData) }

    func replacePaperIDs(_ ids: Set<Int>, at date: Date = Date()) {
        paperIDsData = Self.encode(ids)
        updatedAt = date
    }

    private static func encode(_ values: Set<Int>) -> Data {
        var data = Data()
        data.reserveCapacity(values.count * 8)
        for value in values.sorted() {
            let word = UInt64(bitPattern: Int64(value))
            for shift in stride(from: 0, through: 56, by: 8) {
                data.append(UInt8((word >> UInt64(shift)) & 0xff))
            }
        }
        return data
    }

    private static func decode(_ data: Data) -> Set<Int> {
        let bytes = [UInt8](data)
        guard bytes.count.isMultiple(of: 8) else { return [] }
        return Set(stride(from: 0, to: bytes.count, by: 8).map { offset in
            var word: UInt64 = 0
            for index in 0..<8 { word |= UInt64(bytes[offset + index]) << UInt64(index * 8) }
            return Int(Int64(bitPattern: word))
        })
    }
}

enum LatticeLensSchemaV8: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(8, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [StoredV8Author.self, StoredV8Paper.self, StoredV8PaperAuthorLink.self, StoredV8HIndexSnapshot.self,
         StoredV8SyncCheckpoint.self, StoredV8ReadingWorkflowState.self, StoredV8Note.self, StoredV8Tag.self,
         StoredV8PaperTagLink.self, StoredV8Collection.self, StoredV8PaperCollectionLink.self, StoredV8AIArtifact.self,
         StoredV8CitationSnapshot.self, StoredV8BibTeXRecord.self, StoredV8FullTextDocument.self, StoredV8CitationEdge.self,
         StoredV8CoauthorEdge.self, StoredV8CloudRecordState.self, StoredV8ConflictCopy.self,
         StoredV8ContentBlob.self, StoredV8OrphanedBlobDeletion.self, StoredV8DocumentReference.self, StoredV8EvidenceChunk.self,
         StoredV8EvidenceAnchor.self, StoredV8UserAnnotation.self, StoredV8RevisionSnapshot.self, StoredV8RadarEvent.self,
         StoredV8AuthorIndexGeneration.self, StoredV8SavedQuery.self, StoredV8SyncBatchV3.self, StoredV8SyncJobEvent.self,
         StoredV8SyncBatch.self, StoredV8Workspace.self, StoredV8WorkspacePaperLink.self,
         StoredV8PhysicsContract.self, StoredV8PhysicsCell.self, StoredV8NotebookEntry.self, StoredV8NotebookAnchorLink.self,
         StoredV8ImportRecord.self, StoredV8ImportConflict.self, StoredV8ExportTransaction.self,
         StoredV8ProviderRunProvenance.self, StoredV8SearchIndexState.self, StoredV8BundleRecord.self,
         StoredV8MigrationJournal.self, StoredV8StoreBackupManifest.self, StoredV8QuarantinedEvidence.self,
         StoredV8StoreMarker.self]
    }
}

/// The final 1.0 active schema.  V8 remains the typed domain core; V9 adds
/// only a rebuildable, durable local token index.  A V8 store can therefore
/// migrate lightweightly, then build this projection without rewriting the
/// source domain rows.
enum LatticeLensSchemaV9: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(9, 0, 0) }
    static var models: [any PersistentModel.Type] {
        LatticeLensSchemaV8.models + [StoredV9PaperSearchTerm.self, StoredV9SearchToken.self]
    }
}

enum LatticeLensMigrationPlanV9: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LatticeLensSchemaV8.self, LatticeLensSchemaV9.self] }
    static var stages: [MigrationStage] { [.lightweight(fromVersion: LatticeLensSchemaV8.self, toVersion: LatticeLensSchemaV9.self)] }
}

/// Per-query measurements used only by the disk benchmark to identify which
/// bounded V9 search stage dominates a real SwiftData store.  The values
/// contain counts and elapsed time only: no query text, bibliographic text or
/// user-library path is persisted in benchmark evidence.
struct V9SearchPerformanceBreakdown: Equatable, Sendable {
    var queryTermCount = 0
    var postingRowCount = 0
    var postingCandidateCount = 0
    var candidatePaperRowCount = 0
    var decodedPaperCount = 0
    var postingLookupMilliseconds = 0
    var postingDecodeAndIntersectionMilliseconds = 0
    var candidatePaperFetchMilliseconds = 0
    var paperDecodeMilliseconds = 0
    var resultSortMilliseconds = 0
}

/// The repository-facing form of the same V9 search operation.  It exists so
/// the real-disk benchmark can measure the actor/context used by the product,
/// rather than accidentally timing only `ModelContainer.mainContext`.
struct V9MeasuredSearchResult: Sendable {
    let papers: [Paper]
    let usedV9Projection: Bool
    let breakdown: V9SearchPerformanceBreakdown
}

/// A rebuildable V9 projection over the final typed rows.  The only full
/// rebuild happens after the lightweight V8→V9 schema migration or an
/// explicit corruption repair.  Normal product mutations call `update` with
/// their changed stable paper IDs and touch only their old/new token rows.
enum V9TypedSearchIndex {
    // Bump the projection marker whenever its on-disk representation changes.
    // V9's token/reverse-token data is explicitly rebuildable, so an older
    // prefix-expanded projection must never be mistaken for this compact form.
    static let markerPrefix = "v9-token-index-v2:"

    static func rebuild(in context: ModelContext, at date: Date = Date()) throws {
        try context.delete(model: StoredV9PaperSearchTerm.self)
        try context.delete(model: StoredV9SearchToken.self)

        // A V8→V9 first-open rebuild may cover a large library.  Fetch the
        // supporting rows once and group them by stable ID; fetching notes,
        // links and tag/collection rows separately for every paper would turn
        // this one-off operation into an avoidable N×table scan.
        let notesByPaper = Dictionary(grouping: try context.fetch(FetchDescriptor<StoredV8Note>()), by: \.paperID)
            .mapValues { $0.map(\.body) }
        let tagNames = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<StoredV8Tag>()).map { ($0.id, $0.name) })
        let tagNamesByPaper = Dictionary(grouping: try context.fetch(FetchDescriptor<StoredV8PaperTagLink>()), by: \.paperID)
            .mapValues { $0.compactMap { tagNames[$0.tagID] } }
        let collectionNames = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<StoredV8Collection>()).map { ($0.id, $0.name) })
        let collectionNamesByPaper = Dictionary(grouping: try context.fetch(FetchDescriptor<StoredV8PaperCollectionLink>()), by: \.paperID)
            .mapValues { $0.compactMap { collectionNames[$0.collectionID] } }

        var postings = [String: Set<Int>]()
        for paper in try context.fetch(FetchDescriptor<StoredV8Paper>()) {
            let paperID = paper.literatureID
            let values = baseValues(for: paper) + (notesByPaper[paperID] ?? []) +
                (tagNamesByPaper[paperID] ?? []) + (collectionNamesByPaper[paperID] ?? [])
            let terms = indexTerms(for: values)
            for term in terms {
                context.insert(StoredV9PaperSearchTerm(paperID: paperID, token: term))
                postings[term, default: []].insert(paperID)
            }
        }
        for (token, paperIDs) in postings {
            context.insert(StoredV9SearchToken(token: token, paperIDs: paperIDs, updatedAt: date))
        }
        try markCurrent(in: context, at: date)
        try context.save()
    }

    static func update(paperIDs: Set<Int>, knownNewPaperIDs: Set<Int> = [],
                       in context: ModelContext, at date: Date = Date()) throws {
        guard !paperIDs.isEmpty else { return }
        for paperID in paperIDs {
            // A page of never-before-seen INSPIRE papers has no reverse rows
            // to retire.  Asking SwiftData for those rows by `paperID` can
            // otherwise fault its entire unindexed reverse-token table once
            // per paper, which made a first live sync monopolise the UI.
            if !knownNewPaperIDs.contains(paperID) {
                let previousDescriptor = FetchDescriptor<StoredV9PaperSearchTerm>(predicate: #Predicate { $0.paperID == paperID })
                let previous = try context.fetch(previousDescriptor)
                let oldTerms = Set(previous.map(\.token))
                for row in previous { context.delete(row) }
                for term in oldTerms { try remove(paperID: paperID, from: term, in: context, at: date) }
            }

            let paperDescriptor = FetchDescriptor<StoredV8Paper>(predicate: #Predicate { $0.literatureID == paperID })
            guard try context.fetch(paperDescriptor).first != nil else { continue }
            for term in try terms(for: paperID, in: context) {
                context.insert(StoredV9PaperSearchTerm(paperID: paperID, token: term))
                try insert(paperID: paperID, into: term, in: context, at: date)
            }
        }
        try markCurrent(in: context, at: date)
    }

    static func searchPapers(query: String, limit: Int, in context: ModelContext) throws -> [Paper] {
        var ignoredBreakdown = V9SearchPerformanceBreakdown()
        return try searchPapers(query: query, limit: limit, in: context, breakdown: &ignoredBreakdown)
    }

    /// The overload is intentionally internal to the persistence module.  It
    /// makes the production algorithm observable in the real disk benchmark
    /// without adding diagnostic state to the store or a second search path.
    static func searchPapers(query: String, limit: Int, in context: ModelContext,
                             breakdown: inout V9SearchPerformanceBreakdown) throws -> [Paper] {
        let maximum = max(1, limit)
        let queryTerms = queryTerms(for: query)
        breakdown = V9SearchPerformanceBreakdown(queryTermCount: queryTerms.count)
        if queryTerms.isEmpty {
            let fetchStart = ContinuousClock.Instant.now
            var descriptor = FetchDescriptor<StoredV8Paper>(sortBy: [SortDescriptor(\.title, order: .forward)])
            descriptor.fetchLimit = maximum
            let rows = try context.fetch(descriptor)
            breakdown.candidatePaperFetchMilliseconds += milliseconds(since: fetchStart)
            breakdown.candidatePaperRowCount += rows.count
            let decodeStart = ContinuousClock.Instant.now
            let papers = try rows.map { try $0.decoded() }
            breakdown.paperDecodeMilliseconds += milliseconds(since: decodeStart)
            breakdown.decodedPaperCount += papers.count
            return papers
        }

        var candidates: Set<Int>?
        for term in queryTerms.sorted() {
            // Complete token queries are the common warm path and must remain
            // an equality lookup on the unique token column. SwiftData may
            // otherwise evaluate a String prefix predicate outside SQLite and
            // fault the entire vocabulary into the context. Partial input
            // still has the prefix fallback, but it is never substituted for
            // this indexed exact lookup.
            let lookupStart = ContinuousClock.Instant.now
            let exactDescriptor = FetchDescriptor<StoredV9SearchToken>(predicate: #Predicate { $0.token == term })
            let exact = try context.fetch(exactDescriptor)
            let postings: [StoredV9SearchToken]
            if exact.isEmpty {
                let prefixDescriptor = FetchDescriptor<StoredV9SearchToken>(predicate: #Predicate { $0.token.starts(with: term) })
                postings = try context.fetch(prefixDescriptor)
            } else {
                postings = exact
            }
            breakdown.postingLookupMilliseconds += milliseconds(since: lookupStart)
            guard !postings.isEmpty else { return [] }
            breakdown.postingRowCount += postings.count
            let intersectionStart = ContinuousClock.Instant.now
            let ids = postings.reduce(into: Set<Int>()) { $0.formUnion($1.paperIDs) }
            breakdown.postingDecodeAndIntersectionMilliseconds += milliseconds(since: intersectionStart)
            breakdown.postingCandidateCount += ids.count
            candidates = candidates.map { $0.intersection(ids) } ?? ids
            if candidates?.isEmpty == true { return [] }
        }
        guard let candidateIDs = candidates else { return [] }
        // Query terms are matched against the compact, one-row-per-full-token
        // vocabulary. This preserves prefix-like input such as `gluo` while
        // avoiding a separate persistent row for every character prefix of
        // every paper token. Bound materialisation to the UI result budget
        // before decoding rich paper payload columns.
        let orderedCandidates = candidateIDs.sorted()
        var results = [Paper]()
        var candidateOffset = 0
        while results.count < maximum, candidateOffset < orderedCandidates.count {
            // SwiftData can evaluate `Set.contains` client-side for a dynamic
            // collection predicate, faulting the full paper table. Query an
            // indexed numeric range instead, then retain only candidate IDs.
            // For common postings such as `local`, this returns the bounded
            // result page in one SQLite fetch; sparse postings advance in
            // bounded candidate windows without materialising a snapshot.
            let windowEnd = min(orderedCandidates.count, candidateOffset + max(128, maximum * 4))
            let lowerBound = orderedCandidates[candidateOffset]
            let upperBound = orderedCandidates[windowEnd - 1]
            let allowed = Set(orderedCandidates[candidateOffset..<windowEnd])
            var descriptor = FetchDescriptor<StoredV8Paper>(predicate: #Predicate {
                $0.literatureID >= lowerBound && $0.literatureID <= upperBound
            })
            descriptor.fetchLimit = maximum - results.count
            let fetchStart = ContinuousClock.Instant.now
            let fetchedRows = try context.fetch(descriptor)
            breakdown.candidatePaperFetchMilliseconds += milliseconds(since: fetchStart)
            breakdown.candidatePaperRowCount += fetchedRows.count
            let decodeStart = ContinuousClock.Instant.now
            let decodedRows = try fetchedRows
                .filter { allowed.contains($0.literatureID) }
                .map { try $0.decoded() }
            breakdown.paperDecodeMilliseconds += milliseconds(since: decodeStart)
            breakdown.decodedPaperCount += decodedRows.count
            results += decodedRows
            candidateOffset = windowEnd
        }
        let sortStart = ContinuousClock.Instant.now
        let sortedResults = results.sorted { ($0.timelineDate ?? .distantPast) > ($1.timelineDate ?? .distantPast) }
        breakdown.resultSortMilliseconds += milliseconds(since: sortStart)
        return sortedResults
    }

    static func isCurrent(in context: ModelContext) throws -> Bool {
        guard let state = try context.fetch(FetchDescriptor<StoredV8SearchIndexState>()).first else { return false }
        return state.indexHash.hasPrefix(markerPrefix)
    }

    private static func insert(paperID: Int, into token: String, in context: ModelContext, at date: Date) throws {
        let descriptor = FetchDescriptor<StoredV9SearchToken>(predicate: #Predicate { $0.token == token })
        if let row = try context.fetch(descriptor).first {
            var ids = row.paperIDs
            ids.insert(paperID)
            row.replacePaperIDs(ids, at: date)
        } else {
            context.insert(StoredV9SearchToken(token: token, paperIDs: [paperID], updatedAt: date))
        }
    }

    private static func remove(paperID: Int, from token: String, in context: ModelContext, at date: Date) throws {
        let descriptor = FetchDescriptor<StoredV9SearchToken>(predicate: #Predicate { $0.token == token })
        guard let row = try context.fetch(descriptor).first else { return }
        var ids = row.paperIDs
        ids.remove(paperID)
        if ids.isEmpty { context.delete(row) }
        else { row.replacePaperIDs(ids, at: date) }
    }

    private static func markCurrent(in context: ModelContext, at date: Date) throws {
        let existing = try context.fetch(FetchDescriptor<StoredV8SearchIndexState>())
        let nextRevision = (existing.map(\.revision).max() ?? 0) + 1
        for row in existing { context.delete(row) }
        context.insert(StoredV8SearchIndexState(revision: nextRevision, rebuiltAt: date,
                                                 indexHash: markerPrefix + String(nextRevision)))
    }

    private static func terms(for paperID: Int, in context: ModelContext) throws -> Set<String> {
        let paperDescriptor = FetchDescriptor<StoredV8Paper>(predicate: #Predicate { $0.literatureID == paperID })
        guard let paper = try context.fetch(paperDescriptor).first else { return [] }
        var values = baseValues(for: paper)

        let notes = try context.fetch(FetchDescriptor<StoredV8Note>(predicate: #Predicate { $0.paperID == paperID }))
        values.append(contentsOf: notes.map(\.body))

        let tagLinks = try context.fetch(FetchDescriptor<StoredV8PaperTagLink>(predicate: #Predicate { $0.paperID == paperID }))
        for link in tagLinks {
            let tagID = link.tagID
            let tagDescriptor = FetchDescriptor<StoredV8Tag>(predicate: #Predicate { $0.id == tagID })
            if let tag = try context.fetch(tagDescriptor).first { values.append(tag.name) }
        }

        let collectionLinks = try context.fetch(FetchDescriptor<StoredV8PaperCollectionLink>(predicate: #Predicate { $0.paperID == paperID }))
        for link in collectionLinks {
            let collectionID = link.collectionID
            let collectionDescriptor = FetchDescriptor<StoredV8Collection>(predicate: #Predicate { $0.id == collectionID })
            if let collection = try context.fetch(collectionDescriptor).first { values.append(collection.name) }
        }
        return indexTerms(for: values)
    }

    private static func baseValues(for paper: StoredV8Paper) -> [String] {
        var values = [paper.title, paper.abstractText, paper.arxivID ?? "", paper.doi ?? ""]
        if let contributors = try? JSONDecoder.latticeLens.decode([PaperContributor].self, from: paper.contributorsData) {
            values.append(contentsOf: contributors.map(\.fullName))
        }
        return values
    }

    private static func indexTerms(for values: [String]) -> Set<String> {
        Set(values.flatMap(V4SearchTokenTerms.make))
    }

    private static func queryTerms(for query: String) -> Set<String> {
        Set(V4SearchTokenTerms.make(query))
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let components = start.duration(to: .now).components
        return max(0, Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000))
    }
}

/// Compact semantic evidence written both to the staging migration journal and
/// the V8 activation marker.  This intentionally verifies counts, stable IDs
/// and link identities rather than trusting that a container opened without
/// throwing.  It contains no library text or user paths.
struct V8StoreSemanticSummary: Codable, Equatable, Sendable {
    let counts: [String: Int]
    let stableIDHash: String

    static func make(_ snapshot: LibrarySnapshot) -> V8StoreSemanticSummary {
        var counts = [String: Int]()
        counts["authors"] = snapshot.authors.count; counts["papers"] = snapshot.papers.count
        counts["paperAuthorLinks"] = snapshot.paperAuthorLinks.count; counts["checkpoints"] = snapshot.checkpoints.count
        counts["notes"] = snapshot.notes.count; counts["tags"] = snapshot.tags.count; counts["paperTags"] = snapshot.paperTags.count
        counts["collections"] = snapshot.collections.count; counts["collectionLinks"] = snapshot.collectionPapers.count
        counts["fullTextDocuments"] = snapshot.fullTextDocuments.count
        counts["chunks"] = snapshot.evidenceChunks.count; counts["anchors"] = snapshot.evidenceAnchors.count
        counts["annotations"] = snapshot.userEvidenceAnchors.count; counts["workspaces"] = snapshot.workspaces.count
        counts["workspaceLinks"] = snapshot.workspacePaperLinks.count; counts["physicsCells"] = snapshot.physicsContractCells.count
        counts["radarEvents"] = snapshot.radarEvents.count; counts["documentReferences"] = snapshot.documentReferences.count
        counts["contentBlobs"] = snapshot.contentBlobs.count; counts["orphanedBlobDeletions"] = snapshot.orphanedBlobDeletions.count
        counts["quarantinedEvidence"] = snapshot.quarantinedEvidenceIDs.count
        var identityValues = [String]()
        identityValues += snapshot.authors.keys.map { "a:\($0)" }
        identityValues += snapshot.papers.keys.map { "p:\($0)" }
        identityValues += snapshot.paperAuthorLinks.map { "pa:\($0.paperID):\($0.authorRecid):\($0.position)" }
        identityValues += snapshot.notes.keys.map { "n:\($0.uuidString)" }
        identityValues += snapshot.tags.keys.map { "t:\($0.uuidString)" }
        identityValues += snapshot.paperTags.map { "pt:\($0.paperID):\($0.tagID.uuidString)" }
        identityValues += snapshot.collections.keys.map { "c:\($0.uuidString)" }
        identityValues += snapshot.collectionPapers.map { "cp:\($0.collectionID.uuidString):\($0.paperID)" }
        identityValues += snapshot.evidenceChunks.keys.map { "ch:\($0)" }
        identityValues += snapshot.evidenceAnchors.keys.map { "ea:\($0)" }
        identityValues += snapshot.userEvidenceAnchors.keys.map { "ua:\($0.uuidString)" }
        identityValues += snapshot.workspaces.keys.map { "w:\($0.uuidString)" }
        identityValues += snapshot.workspacePaperLinks.map { "wp:\($0.workspaceID.uuidString):\($0.paperID)" }
        identityValues += snapshot.physicsContractCells.keys.map { "pc:\($0.uuidString)" }
        identityValues += snapshot.radarEvents.keys.map { "r:\($0.uuidString)" }
        identityValues += snapshot.documentReferences.keys.map { "dr:\($0)" }
        identityValues += snapshot.contentBlobs.keys.map { "b:\($0)" }
        identityValues += snapshot.orphanedBlobDeletions.keys.map { "o:\($0)" }
        identityValues += snapshot.quarantinedEvidenceIDs.map { "q:\($0)" }
        let identities = identityValues.sorted().joined(separator: "|")
        return V8StoreSemanticSummary(counts: counts, stableIDHash: StableHash.sha256(identities))
    }
}

/// V8's compatibility bridge is deliberately one-way: it recreates an
/// immutable `LibrarySnapshot` for existing view models, but the persistent
/// truth stays in these typed tables.  V7 is never read from an active V8
/// container.
enum V8TypedStoreCodec {
    static func materialize(_ snapshot: LibrarySnapshot, in context: ModelContext, sourceSchemaVersion: Int = 7) throws {
        try removeAll(from: context)
        // This target is an inactive staging store.  Checkpointing large
        // inserts keeps SwiftData's pending-change set bounded during an
        // actual V7→final migration; publication still happens only after
        // the later full semantic verification and atomic activation.
        func checkpoint(_ count: Int) throws {
            if count > 0, count.isMultiple(of: 2_000) { try context.save() }
        }
        for (index, value) in snapshot.authors.values.enumerated() {
            context.insert(try StoredV8Author(value)); if let h = value.hIndex { context.insert(try StoredV8HIndexSnapshot(h)) }
            try checkpoint(index + 1)
        }
        for (index, value) in snapshot.papers.values.enumerated() {
            context.insert(try StoredV8Paper(value)); try checkpoint(index + 1)
        }
        for (index, value) in snapshot.paperAuthorLinks.enumerated() {
            context.insert(StoredV8PaperAuthorLink(value)); try checkpoint(index + 1)
        }
        for value in snapshot.checkpoints.values { context.insert(try StoredV8SyncCheckpoint(value)) }
        // Older V7 domain records can predate explicit reading-state rows.
        // A final typed library nevertheless has one durable workflow row per
        // paper, derived from the source paper's immutable reading fields.
        // This makes a first read mutation a scalar update, not a new-row
        // schema repair on the user-facing hot path.
        var readingStates = snapshot.readingStates
        for paper in snapshot.papers.values where readingStates[paper.literatureID] == nil {
            readingStates[paper.literatureID] = ReadingState(paperID: paper.literatureID, isRead: paper.isRead,
                                                              readAt: paper.readAt, isFavorite: paper.isFavorite,
                                                              updatedAt: paper.readAt ?? paper.firstSeenAt)
        }
        for (index, value) in readingStates.values.enumerated() {
            context.insert(StoredV8ReadingWorkflowState(value)); try checkpoint(index + 1)
        }
        for value in snapshot.notes.values { context.insert(StoredV8Note(value)) }
        for value in snapshot.tags.values { context.insert(StoredV8Tag(value)) }
        for value in snapshot.paperTags { context.insert(StoredV8PaperTagLink(value)) }
        for value in snapshot.collections.values { context.insert(StoredV8Collection(value)) }
        for value in snapshot.collectionPapers { context.insert(StoredV8PaperCollectionLink(value)) }
        for value in snapshot.insights.values { context.insert(StoredV8AIArtifact(cacheKey: value.cacheKey, paperID: value.paperID, workflowKind: "insight", createdAt: value.createdAt, artifactData: try JSONEncoder.latticeLens.encode(value))) }
        for value in snapshot.evidenceInsights.values { context.insert(StoredV8AIArtifact(cacheKey: value.cacheKey, paperID: value.paperID, workflowKind: "evidenceInsight", createdAt: value.createdAt, artifactData: try JSONEncoder.latticeLens.encode(value))) }
        for value in snapshot.visionArtifacts.values { context.insert(StoredV8AIArtifact(cacheKey: value.cacheKey, paperID: value.paperID, workflowKind: "vision", createdAt: value.createdAt, artifactData: try JSONEncoder.latticeLens.encode(value))) }
        for value in snapshot.citationSnapshots.values { context.insert(StoredV8CitationSnapshot(value)) }
        for value in snapshot.bibTeXRecords.values { context.insert(StoredV8BibTeXRecord(value)) }
        for value in snapshot.fullTextDocuments.values { context.insert(StoredV8FullTextDocument(value)) }
        for (index, value) in snapshot.evidenceChunks.values.enumerated() {
            context.insert(StoredV8EvidenceChunk(value)); try checkpoint(index + 1)
        }
        for value in snapshot.evidenceAnchors.values { context.insert(StoredV8EvidenceAnchor(value)) }
        for value in snapshot.syncBatches.values { context.insert(try StoredV8SyncBatch(value)) }
        for value in snapshot.authorIndexGenerations.values { context.insert(try StoredV8AuthorIndexGeneration(value)) }
        for value in snapshot.savedInspireQueries.values { context.insert(try StoredV8SavedQuery(value)) }
        for value in snapshot.syncBatchesV3.values { context.insert(try StoredV8SyncBatchV3(value)) }
        for value in snapshot.syncJobEvents.values { context.insert(try StoredV8SyncJobEvent(value)) }
        for value in snapshot.paperRevisionSnapshots.values { context.insert(try StoredV8RevisionSnapshot(value)) }
        for value in snapshot.radarEvents.values { context.insert(try StoredV8RadarEvent(value)) }
        for value in snapshot.contentBlobs.values { context.insert(StoredV8ContentBlob(value)) }
        for value in snapshot.orphanedBlobDeletions.values { context.insert(StoredV8OrphanedBlobDeletion(value)) }
        for value in snapshot.documentReferences.values { context.insert(StoredV8DocumentReference(value)) }
        for value in snapshot.userEvidenceAnchors.values { context.insert(StoredV8UserAnnotation(value)) }
        for value in snapshot.notebookEntries.values { context.insert(StoredV8NotebookEntry(id: value.id, paperID: value.paperID, title: value.title, body: value.body, createdAt: value.createdAt, updatedAt: value.updatedAt)) }
        for value in snapshot.notebookAnchorLinks { context.insert(StoredV8NotebookAnchorLink(entryID: value.entryID, anchorID: value.anchorID, sortIndex: value.sortIndex)) }
        for value in snapshot.workspaces.values { context.insert(try StoredV8Workspace(value)) }
        for value in snapshot.workspacePaperLinks { context.insert(StoredV8WorkspacePaperLink(value)) }
        for value in snapshot.physicsContracts.values { context.insert(try StoredV8PhysicsContract(value)) }
        for value in snapshot.physicsContractCells.values { context.insert(try StoredV8PhysicsCell(value)) }
        for value in snapshot.citationEdges.values { context.insert(StoredV8CitationEdge(value)) }
        for value in snapshot.coauthorEdges.values { context.insert(StoredV8CoauthorEdge(value)) }
        for value in snapshot.cloudSyncStates.values { context.insert(StoredV8CloudRecordState(value)) }
        for value in snapshot.conflictCopies.values { context.insert(StoredV8ConflictCopy(value)) }
        for value in snapshot.importedBibliographies.values { context.insert(try StoredV8ImportRecord(value)) }
        for value in snapshot.importConflicts.values { context.insert(try StoredV8ImportConflict(value)) }
        for value in snapshot.exportRecords.values { context.insert(try StoredV8ExportTransaction(value)) }
        for value in snapshot.migrationJournal.values { context.insert(try StoredV8MigrationJournal(value)) }
        for evidenceID in snapshot.quarantinedEvidenceIDs { context.insert(StoredV8QuarantinedEvidence(evidenceID: evidenceID)) }
        let summary = V8StoreSemanticSummary.make(snapshot)
        context.insert(StoredV8SearchIndexState(revision: 1, rebuiltAt: Date(), indexHash: summary.stableIDHash))
        context.insert(StoredV8StoreMarker(sourceSchemaVersion: sourceSchemaVersion, semanticHash: summary.stableIDHash))
        try context.save()
    }

    static func snapshot(from context: ModelContext) throws -> LibrarySnapshot {
        let marker = try context.fetch(FetchDescriptor<StoredV8StoreMarker>()).first
        guard let marker, marker.schemaVersion >= 80 else { throw LatticeLensError.persistenceUnavailable("V8 typed activation marker 缺失；资料库保持只读") }
        var result = LibrarySnapshot(schemaVersion: 8, v3SchemaVersion: 3)
        for row in try context.fetch(FetchDescriptor<StoredV8Author>()) { let value = try row.decoded(); result.authors[value.recid] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8Paper>()) { let value = try row.decoded(); result.papers[value.literatureID] = value }
        result.paperAuthorLinks = Set(try context.fetch(FetchDescriptor<StoredV8PaperAuthorLink>()).map { $0.decoded() })
        for row in try context.fetch(FetchDescriptor<StoredV8SyncCheckpoint>()) { let value = try row.decoded(); result.checkpoints[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8ReadingWorkflowState>()) { let value = row.decoded(); result.readingStates[value.paperID] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8Note>()) { let value = row.decoded(); result.notes[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8Tag>()) { let value = row.decoded(); result.tags[value.id] = value }
        result.paperTags = Set(try context.fetch(FetchDescriptor<StoredV8PaperTagLink>()).map { $0.decoded() })
        for row in try context.fetch(FetchDescriptor<StoredV8Collection>()) { let value = row.decoded(); result.collections[value.id] = value }
        result.collectionPapers = Set(try context.fetch(FetchDescriptor<StoredV8PaperCollectionLink>()).map { $0.decoded() })
        for row in try context.fetch(FetchDescriptor<StoredV8AIArtifact>()) {
            switch row.workflowKind {
            case "insight": let value = try JSONDecoder.latticeLens.decode(InsightArtifact.self, from: row.artifactData); result.insights[value.cacheKey] = value
            case "evidenceInsight": let value = try JSONDecoder.latticeLens.decode(EvidenceInsightArtifact.self, from: row.artifactData); result.evidenceInsights[value.cacheKey] = value
            case "vision": let value = try JSONDecoder.latticeLens.decode(VisionArtifact.self, from: row.artifactData); result.visionArtifacts[value.cacheKey] = value
            default: throw LatticeLensError.persistenceUnavailable("V8 AI artifact workflow 无法识别")
            }
        }
        for row in try context.fetch(FetchDescriptor<StoredV8CitationSnapshot>()) { let value = row.decoded(); result.citationSnapshots[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8BibTeXRecord>()) { let value = try row.decoded(); result.bibTeXRecords[value.paperID] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8FullTextDocument>()) { let value = try row.decoded(); result.fullTextDocuments[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8CitationEdge>()) { let value = try row.decoded(); result.citationEdges[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8CoauthorEdge>()) { let value = try row.decoded(); result.coauthorEdges[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8CloudRecordState>()) { let value = row.decoded(); result.cloudSyncStates[value.recordID] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8ConflictCopy>()) { let value = row.decoded(); result.conflictCopies[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8EvidenceChunk>()) { let value = row.decoded(); result.evidenceChunks[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8EvidenceAnchor>()) { let value = try row.decoded(); result.evidenceAnchors[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8SyncBatch>()) { let value = try JSONDecoder.latticeLens.decode(SyncBatch.self, from: row.batchData); result.syncBatches[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8AuthorIndexGeneration>()) { let value = try JSONDecoder.latticeLens.decode(AuthorIndexGeneration.self, from: row.generationData); result.authorIndexGenerations[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8SavedQuery>()) { let value = try JSONDecoder.latticeLens.decode(SavedInspireQuery.self, from: row.queryData); result.savedInspireQueries[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8SyncBatchV3>()) { let value = try JSONDecoder.latticeLens.decode(SyncBatchV3.self, from: row.batchData); result.syncBatchesV3[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8SyncJobEvent>()) { let value = try JSONDecoder.latticeLens.decode(SyncJobEvent.self, from: row.eventData); result.syncJobEvents[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8RevisionSnapshot>()) { let value = try JSONDecoder.latticeLens.decode(PaperRevisionSnapshot.self, from: row.revisionData); result.paperRevisionSnapshots[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8RadarEvent>()) { let value = try JSONDecoder.latticeLens.decode(RadarEvent.self, from: row.eventData); result.radarEvents[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8ContentBlob>()) { let value = row.decoded(); result.contentBlobs[value.hash] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8OrphanedBlobDeletion>()) { let value = row.decoded(); result.orphanedBlobDeletions[value.blobHash] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8DocumentReference>()) { let value = try row.decoded(); result.documentReferences[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8UserAnnotation>()) { let value = try row.decoded(); result.userEvidenceAnchors[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8NotebookEntry>()) { result.notebookEntries[row.id] = NotebookEntry(id: row.id, paperID: row.paperID, title: row.title, body: row.body, createdAt: row.createdAt, updatedAt: row.updatedAt) }
        result.notebookAnchorLinks = Set(try context.fetch(FetchDescriptor<StoredV8NotebookAnchorLink>()).map { NotebookAnchorLink(entryID: $0.entryID, anchorID: $0.anchorID, sortIndex: $0.sortIndex) })
        for row in try context.fetch(FetchDescriptor<StoredV8Workspace>()) { let order = try JSONDecoder.latticeLens.decode([Int].self, from: row.orderData); result.workspaces[row.id] = PaperWorkspace(id: row.id, name: row.name, createdAt: row.updatedAt, updatedAt: row.updatedAt, sortOrder: order, note: row.note, frozenExportHash: row.frozenExportHash) }
        result.workspacePaperLinks = Set(try context.fetch(FetchDescriptor<StoredV8WorkspacePaperLink>()).map { WorkspacePaperLink(workspaceID: $0.workspaceID, paperID: $0.paperID, addedAt: $0.addedAt, sortIndex: $0.sortIndex) })
        for row in try context.fetch(FetchDescriptor<StoredV8PhysicsContract>()) { result.physicsContracts[row.id] = PhysicsContract(id: row.id, workspaceID: row.workspaceID, rowKeys: try JSONDecoder.latticeLens.decode([String].self, from: row.rowKeysData), createdAt: row.createdAt, updatedAt: row.updatedAt) }
        for row in try context.fetch(FetchDescriptor<StoredV8PhysicsCell>()) { result.physicsContractCells[row.id] = PhysicsContractCell(id: row.id, workspaceID: row.workspaceID, rowKey: row.rowKey, paperID: row.paperID, value: row.value, unit: row.unit, status: PhysicsCellStatus(rawValue: row.status) ?? .missing, evidenceAnchorIDs: try JSONDecoder.latticeLens.decode([String].self, from: row.anchorIDsData), extractionVersion: row.extractionVersion, sourceDocumentHash: row.sourceDocumentHash, updatedAt: row.updatedAt) }
        for row in try context.fetch(FetchDescriptor<StoredV8ImportRecord>()) { let value = try JSONDecoder.latticeLens.decode(V3ImportedBibliography.self, from: row.importData); result.importedBibliographies[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8ImportConflict>()) { let value = try row.decoded(); result.importConflicts[value.importedID] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8ExportTransaction>()) { let value = try JSONDecoder.latticeLens.decode(ExportRecord.self, from: row.transactionData); result.exportRecords[value.id] = value }
        for row in try context.fetch(FetchDescriptor<StoredV8MigrationJournal>()) { let value = try JSONDecoder.latticeLens.decode(V3MigrationJournalEntry.self, from: row.journalData); result.migrationJournal[value.id] = value }
        result.quarantinedEvidenceIDs = Set(try context.fetch(FetchDescriptor<StoredV8QuarantinedEvidence>()).map(\.evidenceID))
        return result
    }

    /// Migration/recovery-only verification. Normal bounded row mutations do
    /// not materialize the entire library merely to recompute this baseline;
    /// their row-level transaction is verified by stable IDs and the next
    /// explicit migration/backup verification pass.
    static func verifyMigrationSemanticIntegrity(from context: ModelContext) throws -> V8StoreSemanticSummary {
        let marker = try context.fetch(FetchDescriptor<StoredV8StoreMarker>()).first
        guard let marker else { throw LatticeLensError.persistenceUnavailable("V8 typed activation marker 缺失；资料库保持只读") }
        let summary = V8StoreSemanticSummary.make(try snapshot(from: context))
        guard summary.stableIDHash == marker.semanticHash else { throw LatticeLensError.persistenceUnavailable("V8 typed store 语义哈希不匹配；资料库保持只读") }
        return summary
    }

    private static func removeAll(from context: ModelContext) throws {
        try context.delete(model: StoredV8Author.self); try context.delete(model: StoredV8Paper.self); try context.delete(model: StoredV8PaperAuthorLink.self)
        try context.delete(model: StoredV8HIndexSnapshot.self); try context.delete(model: StoredV8SyncCheckpoint.self); try context.delete(model: StoredV8ReadingWorkflowState.self)
        try context.delete(model: StoredV8Note.self); try context.delete(model: StoredV8Tag.self); try context.delete(model: StoredV8PaperTagLink.self); try context.delete(model: StoredV8Collection.self); try context.delete(model: StoredV8PaperCollectionLink.self)
        try context.delete(model: StoredV8AIArtifact.self); try context.delete(model: StoredV8CitationSnapshot.self); try context.delete(model: StoredV8BibTeXRecord.self); try context.delete(model: StoredV8FullTextDocument.self); try context.delete(model: StoredV8CitationEdge.self); try context.delete(model: StoredV8CoauthorEdge.self); try context.delete(model: StoredV8CloudRecordState.self); try context.delete(model: StoredV8ConflictCopy.self); try context.delete(model: StoredV8ContentBlob.self); try context.delete(model: StoredV8OrphanedBlobDeletion.self); try context.delete(model: StoredV8DocumentReference.self); try context.delete(model: StoredV8EvidenceChunk.self); try context.delete(model: StoredV8EvidenceAnchor.self); try context.delete(model: StoredV8UserAnnotation.self)
        try context.delete(model: StoredV8RevisionSnapshot.self); try context.delete(model: StoredV8RadarEvent.self); try context.delete(model: StoredV8AuthorIndexGeneration.self); try context.delete(model: StoredV8SavedQuery.self); try context.delete(model: StoredV8SyncBatchV3.self); try context.delete(model: StoredV8SyncJobEvent.self); try context.delete(model: StoredV8SyncBatch.self); try context.delete(model: StoredV8Workspace.self); try context.delete(model: StoredV8WorkspacePaperLink.self); try context.delete(model: StoredV8PhysicsContract.self); try context.delete(model: StoredV8PhysicsCell.self)
        try context.delete(model: StoredV8NotebookEntry.self); try context.delete(model: StoredV8NotebookAnchorLink.self); try context.delete(model: StoredV8ImportRecord.self); try context.delete(model: StoredV8ImportConflict.self); try context.delete(model: StoredV8ExportTransaction.self); try context.delete(model: StoredV8ProviderRunProvenance.self); try context.delete(model: StoredV8SearchIndexState.self); try context.delete(model: StoredV8BundleRecord.self); try context.delete(model: StoredV8MigrationJournal.self); try context.delete(model: StoredV8StoreBackupManifest.self); try context.delete(model: StoredV8QuarantinedEvidence.self); try context.delete(model: StoredV8StoreMarker.self)
    }
}

// MARK: - V7 to V8 staged migration

/// The external journal is intentionally independent of either SQLite family.
/// A failure while SwiftData is migrating cannot erase the only record needed
/// to make the old V7 library recoverable.  It records store *names* only;
/// user paths and library contents never leave the local store package.
struct V8MigrationJournal: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable, CaseIterable {
        case prepared, copied, migrated, semanticallyVerified, activated, failed, rolledBack
    }

    let id: UUID
    let sourceStoreName: String
    let activeStoreName: String
    let stagingStoreName: String
    let startedAt: Date
    var completedAt: Date?
    var phase: Phase
    let backupManifestID: UUID
    let backupManifestHash: String
    var preSummary: V8StoreSemanticSummary?
    var postSummary: V8StoreSemanticSummary?
    var errorCategory: String?
}

enum V8MigrationCrashPoint: Sendable, Equatable {
    case afterCopied, afterMigrated, beforeSemanticVerification, beforeActivation, afterActivation
}

enum V8MigrationCoordinatorError: Error, Equatable, Sendable {
    case injectedCrash(V8MigrationCrashPoint)
    case sourceMissing
    case activeTargetExists
    case semanticMismatch
    case invalidJournal
}

struct V8MigrationOutcome: Sendable, Equatable {
    let journalURL: URL
    let journal: V8MigrationJournal
}

enum V8MigrationCoordinator {
    /// Migrates only an explicit caller-owned V7 source into a distinct V8
    /// target.  This routine never opens V7 with the normal active-store
    /// writer, so a legacy V7 source is not materialized or rewritten in
    /// place just to produce the final schema.
    @MainActor
    static func migrateV7ToV8(sourceURL: URL, activeV8URL: URL, backupRoot: URL,
                              crashAt: V8MigrationCrashPoint? = nil,
                              fileManager: FileManager = .default) throws -> V8MigrationOutcome {
        guard fileManager.fileExists(atPath: sourceURL.path) else { throw V8MigrationCoordinatorError.sourceMissing }
        guard !fileManager.fileExists(atPath: activeV8URL.path) else { throw V8MigrationCoordinatorError.activeTargetExists }
        let parent = activeV8URL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let id = UUID()
        let stagingURL = parent.appendingPathComponent(".latticelens-v8-stage-\(id.uuidString).store")
        let journalURL = parent.appendingPathComponent(".latticelens-v8-migration-\(id.uuidString).json")
        let backup = try V4StoreBackupCoordinator.createBackup(source: sourceURL, destinationRoot: backupRoot, schemaVersion: 7, fileManager: fileManager)
        var journal = V8MigrationJournal(id: id, sourceStoreName: sourceURL.lastPathComponent, activeStoreName: activeV8URL.lastPathComponent,
                                         stagingStoreName: stagingURL.lastPathComponent, startedAt: Date(), completedAt: nil,
                                         phase: .prepared, backupManifestID: backup.id, backupManifestHash: backup.manifestHash,
                                         preSummary: nil, postSummary: nil, errorCategory: nil)
        try write(journal, to: journalURL)
        journal.phase = .copied
        try write(journal, to: journalURL)
        if crashAt == .afterCopied { throw V8MigrationCoordinatorError.injectedCrash(.afterCopied) }

        do {
            let source = try readV7CompatibilitySnapshot(at: sourceURL)
            journal.preSummary = V8StoreSemanticSummary.make(source)
            let manifestData = try JSONEncoder.latticeLens.encode(backup)
            do {
                let schema = Schema(versionedSchema: LatticeLensSchemaV8.self)
                let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: stagingURL))
                let context = container.mainContext
                try V8TypedStoreCodec.materialize(source, in: context, sourceSchemaVersion: 7)
                context.insert(StoredV8StoreBackupManifest(id: backup.id, schemaVersion: backup.schemaVersion, createdAt: backup.createdAt,
                                                            manifestHash: backup.manifestHash, manifestData: manifestData))
                try context.save()
                journal.postSummary = V8StoreSemanticSummary.make(try V8TypedStoreCodec.snapshot(from: context))
            }
            journal.phase = .migrated
            try write(journal, to: journalURL)
            if crashAt == .afterMigrated { throw V8MigrationCoordinatorError.injectedCrash(.afterMigrated) }
            if crashAt == .beforeSemanticVerification { throw V8MigrationCoordinatorError.injectedCrash(.beforeSemanticVerification) }
            guard journal.preSummary == journal.postSummary else { throw V8MigrationCoordinatorError.semanticMismatch }
            journal.phase = .semanticallyVerified
            try write(journal, to: journalURL)
            if crashAt == .beforeActivation { throw V8MigrationCoordinatorError.injectedCrash(.beforeActivation) }
            try activateStoreFamily(stagingURL: stagingURL, activeURL: activeV8URL, fileManager: fileManager)
            journal.phase = .activated
            journal.completedAt = Date()
            try write(journal, to: journalURL)
            if crashAt == .afterActivation { throw V8MigrationCoordinatorError.injectedCrash(.afterActivation) }
            return V8MigrationOutcome(journalURL: journalURL, journal: journal)
        } catch let error as V8MigrationCoordinatorError where {
            if case .injectedCrash = error { return true }
            return false
        }() {
            // A crash injection models process death: leave the independently
            // journaled phase and the V7 source untouched. `recover` is the
            // only code that may retire this coordinator-owned staging family.
            throw error
        } catch {
            journal.phase = .failed
            journal.errorCategory = String(describing: type(of: error))
            try? write(journal, to: journalURL)
            try? removeStoreFamily(at: stagingURL, parent: parent, fileManager: fileManager)
            journal.phase = .rolledBack
            journal.completedAt = Date()
            try? write(journal, to: journalURL)
            throw error
        }
    }

    /// Finishes only the safe recovery branch.  Any unactivated staging store
    /// is discarded, never promoted heuristically; the original V7 source and
    /// verified backup stay readable.  An activated V8 target is opened and
    /// semantically revalidated before it is reported as recovered.
    @MainActor
    static func recover(journalURL: URL, parent: URL, fileManager: FileManager = .default) throws -> V8MigrationJournal {
        var journal = try JSONDecoder.latticeLens.decode(V8MigrationJournal.self, from: Data(contentsOf: journalURL))
        guard journalURL.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL else { throw V8MigrationCoordinatorError.invalidJournal }
        let staging = parent.appendingPathComponent(journal.stagingStoreName)
        let active = parent.appendingPathComponent(journal.activeStoreName)
        switch journal.phase {
        case .activated:
            let schema = Schema(versionedSchema: LatticeLensSchemaV8.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: active))
            let summary = try V8TypedStoreCodec.verifyMigrationSemanticIntegrity(from: container.mainContext)
            guard summary == journal.postSummary else { throw V8MigrationCoordinatorError.semanticMismatch }
            return journal
        case .rolledBack:
            return journal
        case .prepared, .copied, .migrated, .semanticallyVerified, .failed:
            try removeStoreFamily(at: staging, parent: parent, fileManager: fileManager)
            journal.phase = .rolledBack
            journal.completedAt = Date()
            try write(journal, to: journalURL)
            return journal
        }
    }

    @MainActor
    private static func readV7CompatibilitySnapshot(at sourceURL: URL) throws -> LibrarySnapshot {
        let schema = Schema(versionedSchema: LatticeLensSchemaV7.self)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV7.self,
                                           configurations: ModelConfiguration(url: sourceURL))
        let context = container.mainContext
        if let marker = try context.fetch(FetchDescriptor<StoredV7StoreMarker>()).first, marker.schemaVersion >= 71 {
            return try V7DomainRecordCodec.decode(rows: context.fetch(FetchDescriptor<StoredV7DomainRecord>()))
        }
        guard let legacy = try context.fetch(FetchDescriptor<StoredLibraryDocument>()).first else { return LibrarySnapshot(schemaVersion: 7, v3SchemaVersion: 3) }
        return try JSONDecoder.latticeLens.decode(LibrarySnapshot.self, from: legacy.snapshotData)
    }

    private static func write(_ journal: V8MigrationJournal, to url: URL) throws {
        try JSONEncoder.latticeLens.encode(journal).write(to: url, options: .atomic)
    }

    private static func activateStoreFamily(stagingURL: URL, activeURL: URL, fileManager: FileManager) throws {
        guard !fileManager.fileExists(atPath: activeURL.path) else { throw V8MigrationCoordinatorError.activeTargetExists }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: stagingURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.moveItem(at: source, to: URL(fileURLWithPath: activeURL.path + suffix))
        }
    }

    private static func removeStoreFamily(at storeURL: URL, parent: URL, fileManager: FileManager) throws {
        guard storeURL.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL,
              storeURL.lastPathComponent.hasPrefix(".latticelens-v8-stage-") else { throw V8MigrationCoordinatorError.invalidJournal }
        for suffix in ["", "-wal", "-shm"] {
            let member = URL(fileURLWithPath: storeURL.path + suffix)
            if fileManager.fileExists(atPath: member.path) { try fileManager.removeItem(at: member) }
        }
    }
}

/// The V8 production repository keeps hot mutations bounded to the rows whose
/// stable IDs participate in the operation.  `snapshot()` is retained only as
/// a compatibility projection for the current SwiftUI/view-model boundary;
/// it is not read before note/read/tag/collection mutations.
@ModelActor
actor V8TypedLibraryStore: LibraryStoring {
    private var availabilityFailure: String?
    private var lastKnownGoodSnapshot: LibrarySnapshot?
    /// V8-only test/migration containers remain valid compatibility inputs.
    /// The normal application factory opens V9, where these entities exist.
    private var v9SearchIndexAvailability: Bool?

    func initializationState() -> LibraryInitializationState {
        do {
            // Startup must validate the activation boundary without decoding
            // the whole library.  The latter can include tens of thousands of
            // V9 token rows and large artifact payloads, none of which are a
            // prerequisite for first paint or for opening Settings.
            guard let marker = try modelContext.fetch(FetchDescriptor<StoredV8StoreMarker>()).first,
                  marker.schemaVersion >= 80 else {
                throw LatticeLensError.persistenceUnavailable("V8 typed activation marker 缺失")
            }
            return .ready
        } catch {
            let reason = "V8 typed store 读取失败；资料库保持只读，原 V7 source 未被覆盖"
            availabilityFailure = reason
            return .readOnlyFailure(reason)
        }
    }

    func snapshot() -> LibrarySnapshot {
        do {
            let value = try checkedSnapshot()
            lastKnownGoodSnapshot = value
            return value
        } catch {
            if let lastKnownGoodSnapshot { return lastKnownGoodSnapshot }
            var failure = LibrarySnapshot(); failure.readErrorMessage = "V8 typed store 读取失败；当前仅提供只读错误占位"
            return failure
        }
    }

    func snapshotResult() -> LibrarySnapshotReadResult {
        do {
            let value = try checkedSnapshot(); lastKnownGoodSnapshot = value
            return LibrarySnapshotReadResult(state: .ready, snapshot: value, message: nil)
        } catch {
            let reason = availabilityFailure ?? "V8 typed store 读取失败；保留最后一次有效资料库"
            if let lastKnownGoodSnapshot { return LibrarySnapshotReadResult(state: .readOnlyFailure, snapshot: lastKnownGoodSnapshot, message: reason) }
            var failure = LibrarySnapshot(); failure.readErrorMessage = reason
            return LibrarySnapshotReadResult(state: .readOnlyFailure, snapshot: failure, message: reason)
        }
    }

    /// These projections are deliberately typed-row queries rather than
    /// wrappers around `snapshot()`: startup and paper selection should not
    /// materialize unrelated papers, AI artifacts, or V9 search postings.
    func authorSidebarProjection() -> LibraryAuthorSidebarProjection {
        do {
            let authors = try modelContext.fetch(FetchDescriptor<StoredV8Author>()).map { try $0.decoded() }
            let generations = try modelContext.fetch(FetchDescriptor<StoredV8AuthorIndexGeneration>())
                .map { try JSONDecoder.latticeLens.decode(AuthorIndexGeneration.self, from: $0.generationData) }
            let activeMembership = generations
                .filter { $0.state == .completed }
                .max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }?
                .activeMembership
            return LibraryAuthorSidebarProjection(authors: authors, activeMembership: activeMembership)
        } catch {
            availabilityFailure = "V8 typed store 作者投影读取失败；资料库保持只读"
            return LibraryAuthorSidebarProjection(authors: [], activeMembership: nil)
        }
    }

    func author(recid: Int) -> Author? {
        do {
            let descriptor = FetchDescriptor<StoredV8Author>(predicate: #Predicate { $0.recid == recid })
            return try modelContext.fetch(descriptor).first.map { try $0.decoded() }
        } catch {
            availabilityFailure = "V8 typed store 作者行读取失败；资料库保持只读"
            return nil
        }
    }

    func papers(forAuthorRecid authorRecid: Int) -> [Paper] {
        do {
            let links = try modelContext.fetch(FetchDescriptor<StoredV8PaperAuthorLink>(predicate: #Predicate { $0.authorRecid == authorRecid }))
            var values: [Paper] = []
            for link in links {
                if let paper = try typedPaper(id: link.paperID) { values.append(paper) }
            }
            return values.sorted { lhs, rhs in
                if (lhs.timelineDate ?? .distantPast) != (rhs.timelineDate ?? .distantPast) {
                    return (lhs.timelineDate ?? .distantPast) > (rhs.timelineDate ?? .distantPast)
                }
                return lhs.literatureID < rhs.literatureID
            }
        } catch {
            availabilityFailure = "V8 typed store 作者论文投影读取失败；资料库保持只读"
            return []
        }
    }

    func papers(forIDs ids: [Int]) -> [Int: Paper] {
        do {
            var values: [Int: Paper] = [:]
            for id in Set(ids) {
                if let paper = try typedPaper(id: id) { values[id] = paper }
            }
            return values
        } catch {
            availabilityFailure = "V8 typed store 论文行读取失败；资料库保持只读"
            return [:]
        }
    }

    func trackedAuthorRecids() -> Set<Int> {
        do {
            let descriptor = FetchDescriptor<StoredV8Author>(predicate: #Predicate { $0.isTracked == true })
            return Set(try modelContext.fetch(descriptor).map(\.recid))
        } catch {
            availabilityFailure = "V8 typed store tracked 作者读取失败；资料库保持只读"
            return []
        }
    }

    func insight(cacheKey: String) -> InsightArtifact? {
        do {
            let descriptor = FetchDescriptor<StoredV8AIArtifact>(predicate: #Predicate { $0.cacheKey == cacheKey })
            guard let row = try modelContext.fetch(descriptor).first, row.workflowKind == "insight" else { return nil }
            return try JSONDecoder.latticeLens.decode(InsightArtifact.self, from: row.artifactData)
        } catch {
            availabilityFailure = "V8 typed store insight 缓存读取失败；资料库保持只读"
            return nil
        }
    }

    func paperContext(paperID: Int, insightCacheKey: String?) -> LibraryPaperContextProjection {
        do {
            let paper = try typedPaper(id: paperID)
            let documents = try modelContext.fetch(FetchDescriptor<StoredV8FullTextDocument>(predicate: #Predicate { $0.paperID == paperID }))
                .map { try $0.decoded() }
            let anchors = try modelContext.fetch(FetchDescriptor<StoredV8EvidenceAnchor>(predicate: #Predicate { $0.paperID == paperID }))
                .map { try $0.decoded() }
            let notes = try modelContext.fetch(FetchDescriptor<StoredV8Note>(predicate: #Predicate { $0.paperID == paperID }))
                .map { $0.decoded() }
            let bibDescriptor = FetchDescriptor<StoredV8BibTeXRecord>(predicate: #Predicate { $0.paperID == paperID })
            let bibTeX = try modelContext.fetch(bibDescriptor).first.map { try $0.decoded() }
            let linkedTagIDs = Set(try modelContext.fetch(FetchDescriptor<StoredV8PaperTagLink>(predicate: #Predicate { $0.paperID == paperID })).map(\.tagID))
            let allTags = try modelContext.fetch(FetchDescriptor<StoredV8Tag>()).map { $0.decoded() }
            let tagsByID = Dictionary(uniqueKeysWithValues: allTags.map { ($0.id, $0) })
            let allCollections = try modelContext.fetch(FetchDescriptor<StoredV8Collection>()).map { $0.decoded() }
            let selectedCollectionIDs = Set(try modelContext.fetch(FetchDescriptor<StoredV8PaperCollectionLink>(predicate: #Predicate { $0.paperID == paperID })).map(\.collectionID))
            let artifacts = try modelContext.fetch(FetchDescriptor<StoredV8AIArtifact>(predicate: #Predicate { $0.paperID == paperID }))
            var cachedInsight: InsightArtifact?
            var evidenceInsights: [EvidenceInsightArtifact] = []
            var visionArtifacts: [VisionArtifact] = []
            for artifact in artifacts {
                switch artifact.workflowKind {
                case "insight":
                    if artifact.cacheKey == insightCacheKey {
                        cachedInsight = try JSONDecoder.latticeLens.decode(InsightArtifact.self, from: artifact.artifactData)
                    }
                case "evidenceInsight":
                    evidenceInsights.append(try JSONDecoder.latticeLens.decode(EvidenceInsightArtifact.self, from: artifact.artifactData))
                case "vision":
                    visionArtifacts.append(try JSONDecoder.latticeLens.decode(VisionArtifact.self, from: artifact.artifactData))
                default:
                    throw LatticeLensError.persistenceUnavailable("V8 AI artifact workflow 无法识别")
                }
            }
            return LibraryPaperContextProjection(
                paper: paper,
                insight: cachedInsight,
                fullTextDocuments: documents,
                evidenceAnchors: anchors,
                evidenceInsights: evidenceInsights,
                visionArtifacts: visionArtifacts,
                notes: notes,
                bibTeXRecord: bibTeX,
                tags: linkedTagIDs.compactMap { tagsByID[$0] },
                availableTags: allTags,
                availableCollections: allCollections,
                selectedCollectionIDs: selectedCollectionIDs
            )
        } catch {
            availabilityFailure = "V8 typed store 单篇上下文读取失败；资料库保持只读"
            return LibraryPaperContextProjection(paper: nil, insight: nil, fullTextDocuments: [], evidenceAnchors: [],
                                                 evidenceInsights: [], visionArtifacts: [], notes: [], bibTeXRecord: nil,
                                                 tags: [], availableTags: [], availableCollections: [], selectedCollectionIDs: [])
        }
    }

    private func typedPaper(id: Int) throws -> Paper? {
        let descriptor = FetchDescriptor<StoredV8Paper>(predicate: #Predicate { $0.literatureID == id })
        return try modelContext.fetch(descriptor).first.map { try $0.decoded() }
    }

    func searchPapers(_ query: String, limit: Int) -> [Paper] {
        searchPapersWithMetrics(query, limit: limit).papers
    }

    /// Internal measurement support for the actual-disk benchmark.  It takes
    /// exactly the same V9 branch as `searchPapers(_:limit:)`; metrics are
    /// returned to the caller and are not written to the library store.
    func searchPapersWithMetrics(_ query: String, limit: Int) -> V9MeasuredSearchResult {
        do {
            if try hasV9SearchIndex() {
                var breakdown = V9SearchPerformanceBreakdown()
                let papers = try V9TypedSearchIndex.searchPapers(query: query, limit: limit,
                                                                  in: modelContext, breakdown: &breakdown)
                return V9MeasuredSearchResult(papers: papers, usedV9Projection: true, breakdown: breakdown)
            }
            return V9MeasuredSearchResult(papers: compatibilitySearch(query: query, limit: limit,
                                                                        snapshot: try checkedSnapshot()),
                                          usedV9Projection: false,
                                          breakdown: V9SearchPerformanceBreakdown())
        } catch {
            return V9MeasuredSearchResult(papers: [], usedV9Projection: false,
                                          breakdown: V9SearchPerformanceBreakdown())
        }
    }

    private func hasV9SearchIndex() throws -> Bool {
        if let v9SearchIndexAvailability { return v9SearchIndexAvailability }
        do {
            var descriptor = FetchDescriptor<StoredV9SearchToken>()
            descriptor.fetchLimit = 1
            _ = try modelContext.fetch(descriptor)
            v9SearchIndexAvailability = true
        } catch {
            // The V8 test containers deliberately do not include the V9
            // projection.  They retain the bounded compatibility behavior;
            // the product factory never uses that fallback after V9 opens.
            v9SearchIndexAvailability = false
        }
        return v9SearchIndexAvailability ?? false
    }

    private func refreshV9SearchIndex(_ paperIDs: Set<Int>, knownNewPaperIDs: Set<Int> = []) throws {
        guard try hasV9SearchIndex() else { return }
        try V9TypedSearchIndex.update(paperIDs: paperIDs, knownNewPaperIDs: knownNewPaperIDs, in: modelContext)
    }

    private func compatibilitySearch(query: String, limit: Int, snapshot: LibrarySnapshot) -> [Paper] {
        let needle = SearchNormalizer.normalize(query)
        let maximum = max(1, limit)
        guard !needle.isEmpty else {
            return Array(snapshot.papers.values.sorted { $0.displayTitle < $1.displayTitle }.prefix(maximum))
        }
        let taggedPaperIDs = Set(snapshot.paperTags.compactMap { link -> Int? in
            guard let tag = snapshot.tags[link.tagID], SearchNormalizer.normalize(tag.name).contains(needle) else { return nil }
            return link.paperID
        })
        let collectionPaperIDs = Set(snapshot.collectionPapers.compactMap { link -> Int? in
            guard let collection = snapshot.collections[link.collectionID], SearchNormalizer.normalize(collection.name).contains(needle) else { return nil }
            return link.paperID
        })
        let notedPaperIDs = Set(snapshot.notes.values.compactMap { note in
            SearchNormalizer.normalize(note.body).contains(needle) ? note.paperID : nil
        })
        return Array(snapshot.papers.values.filter { paper in
            taggedPaperIDs.contains(paper.literatureID) || collectionPaperIDs.contains(paper.literatureID) || notedPaperIDs.contains(paper.literatureID) ||
            SearchNormalizer.normalize(paper.displayTitle).contains(needle) ||
            paper.titles.contains { SearchNormalizer.normalize($0.value).contains(needle) } ||
            paper.contributors.contains { SearchNormalizer.normalize($0.fullName).contains(needle) } ||
            SearchNormalizer.normalize(paper.arxivID ?? "").contains(needle) ||
            SearchNormalizer.normalize(paper.doi ?? "").contains(needle)
        }
        .sorted { ($0.timelineDate ?? .distantPast) > ($1.timelineDate ?? .distantPast) }
        .prefix(maximum))
    }

    func upsert(authors: [Author]) throws {
        try requireWritable()
        try upsertAuthorRows(authors)
        try modelContext.save()
    }

    private func upsertAuthorRows(_ authors: [Author]) throws {
        for incoming in authors {
            let authorRecid = incoming.recid
            let descriptor = FetchDescriptor<StoredV8Author>(predicate: #Predicate { $0.recid == authorRecid })
            var merged = incoming
            if let existing = try modelContext.fetch(descriptor).first {
                let prior = try existing.decoded()
                merged.isTracked = prior.isTracked
                merged.lastSyncedAt = incoming.lastSyncedAt ?? prior.lastSyncedAt
                merged.lastCheckpointAt = incoming.lastCheckpointAt ?? prior.lastCheckpointAt
                merged.lastSuccessfulSyncAt = incoming.lastSuccessfulSyncAt ?? prior.lastSuccessfulSyncAt
                if merged.hIndex == nil, merged.hIndexState == .unknown { merged.hIndex = prior.hIndex; merged.hIndexState = prior.hIndexState }
                modelContext.delete(existing)
            }
            let hDescriptor = FetchDescriptor<StoredV8HIndexSnapshot>(predicate: #Predicate { $0.authorRecid == authorRecid })
            for row in try modelContext.fetch(hDescriptor) { modelContext.delete(row) }
            modelContext.insert(try StoredV8Author(merged))
            if let h = merged.hIndex { modelContext.insert(try StoredV8HIndexSnapshot(h)) }
        }
    }

    func upsert(papers: [Paper], for authorRecid: Int) throws -> PaperUpsertReport {
        try requireWritable()
        let report = try upsertPaperRows(papers, for: authorRecid)
        try modelContext.save()
        return report
    }

    /// Updates only the rows touched by a literature page.  The caller owns
    /// the save boundary so a page can be committed with its revision, Radar,
    /// and checkpoint rows in one SwiftData transaction.
    private func upsertPaperRows(_ papers: [Paper], for authorRecid: Int,
                                 updateSearchIndex: Bool = true) throws -> PaperUpsertReport {
        var report = PaperUpsertReport.empty
        var newlyInsertedPaperIDs = Set<Int>()
        var searchInvalidatedPaperIDs = Set<Int>()
        for (position, incoming) in papers.enumerated() {
            let paperID = incoming.literatureID
            let descriptor = FetchDescriptor<StoredV8Paper>(predicate: #Predicate { $0.literatureID == paperID })
            var merged = incoming
            if let existing = try modelContext.fetch(descriptor).first {
                let prior = try existing.decoded()
                merged.firstSeenAt = prior.firstSeenAt; merged.isRead = prior.isRead; merged.readAt = prior.readAt; merged.isFavorite = prior.isFavorite
                if V8TypedLibraryStore.paperMetadataChanged(from: prior, to: incoming) {
                    report.metadataUpdated += 1
                    // The V9 terms include title, abstract, contributor, DOI
                    // and arXiv metadata.  Rebuild only when that searchable
                    // content actually changed; a conditional GET/second
                    // launch must not re-index an unchanged live page.
                    searchInvalidatedPaperIDs.insert(paperID)
                } else {
                    report.unchanged += 1
                }
                if let oldCitation = prior.citationCount, let newCitation = incoming.citationCount, oldCitation != newCitation {
                    report.citationChanged += 1
                }
                modelContext.delete(existing)
            } else {
                report.inserted += 1
                newlyInsertedPaperIDs.insert(paperID)
                searchInvalidatedPaperIDs.insert(paperID)
            }
            modelContext.insert(try StoredV8Paper(merged))
            let key = "\(merged.literatureID):\(authorRecid)"
            let linkDescriptor = FetchDescriptor<StoredV8PaperAuthorLink>(predicate: #Predicate { $0.key == key })
            for row in try modelContext.fetch(linkDescriptor) { modelContext.delete(row) }
            modelContext.insert(StoredV8PaperAuthorLink(PaperAuthorLink(paperID: merged.literatureID, authorRecid: authorRecid, position: position)))
            if let citationCount = incoming.citationCount {
                let citationDescriptor = FetchDescriptor<StoredV8CitationSnapshot>(predicate: #Predicate { $0.paperID == paperID })
                let latest = try modelContext.fetch(citationDescriptor).max { $0.fetchedAt < $1.fetchedAt }
                if latest?.citationCount != citationCount {
                    modelContext.insert(StoredV8CitationSnapshot(CitationSnapshot(paperID: paperID, citationCount: citationCount, fetchedAt: Date())))
                }
            }
        }
        if updateSearchIndex {
            try refreshV9SearchIndex(searchInvalidatedPaperIDs, knownNewPaperIDs: newlyInsertedPaperIDs)
        }
        return report
    }

    func upsert(detail paper: Paper) throws {
        try requireWritable()
        let paperID = paper.literatureID
        let descriptor = FetchDescriptor<StoredV8Paper>(predicate: #Predicate { $0.literatureID == paperID })
        var merged = paper
        if let existing = try modelContext.fetch(descriptor).first {
            let prior = try existing.decoded(); merged.firstSeenAt = prior.firstSeenAt; merged.isRead = prior.isRead; merged.readAt = prior.readAt; merged.isFavorite = prior.isFavorite
            modelContext.delete(existing)
        }
        modelContext.insert(try StoredV8Paper(merged)); try refreshV9SearchIndex([paperID]); try modelContext.save()
    }

    func save(checkpoint: SyncCheckpoint?) throws {
        guard let checkpoint else { return }; try requireWritable()
        try replaceCheckpointRow(checkpoint)
        try modelContext.save()
    }

    func checkpoint(jobID: String) throws -> SyncCheckpoint? {
        let descriptor = FetchDescriptor<StoredV8SyncCheckpoint>(predicate: #Predicate { $0.jobID == jobID })
        return try modelContext.fetch(descriptor).first.map { try $0.decoded() }
    }

    func completeCheckpoint(jobID: String, at: Date) throws {
        guard var checkpoint = try checkpoint(jobID: jobID) else { return }
        checkpoint.nextURL = nil; checkpoint.state = .completed; checkpoint.updatedAt = at; checkpoint.completedAt = at; try save(checkpoint: checkpoint)
    }

    func deleteCheckpoint(jobID: String) throws {
        try requireWritable(); let descriptor = FetchDescriptor<StoredV8SyncCheckpoint>(predicate: #Predicate { $0.jobID == jobID })
        for row in try modelContext.fetch(descriptor) { modelContext.delete(row) }; try modelContext.save()
    }

    func commitAuthorIndexPage(authors: [Author], checkpoint: SyncCheckpoint,
                               generation: AuthorIndexGeneration) throws {
        try requireWritable()
        try upsertAuthorRows(authors)
        try replaceCheckpointRow(checkpoint)
        try replaceGenerationRow(generation)
        try modelContext.save()
    }

    func commitHIndexOutcome(author: Author, checkpoint: SyncCheckpoint,
                             generation: AuthorIndexGeneration) throws {
        try requireWritable()
        try upsertAuthorRows([author])
        try replaceCheckpointRow(checkpoint)
        try replaceGenerationRow(generation)
        try modelContext.save()
    }

    func commitAuthorIndexState(checkpoint: SyncCheckpoint,
                                generation: AuthorIndexGeneration) throws {
        try requireWritable()
        try replaceCheckpointRow(checkpoint)
        try replaceGenerationRow(generation)
        try modelContext.save()
    }

    func commitAuthorIndexCompletion(checkpoint: SyncCheckpoint,
                                     generation: AuthorIndexGeneration) throws {
        try requireWritable()
        try replaceCheckpointRow(checkpoint)
        try replaceGenerationRow(generation)
        try modelContext.save()
    }

    func commitPaperSyncPage(_ commit: PaperSyncPageCommit) throws -> PaperUpsertReport {
        try requireWritable()
        let report = try upsertPaperRows(commit.papers, for: commit.authorRecid,
                                         updateSearchIndex: commit.updateSearchIndex)
        for revision in commit.revisions {
            let revisionID = revision.id
            try replaceRow(try StoredV8RevisionSnapshot(revision), matching: FetchDescriptor<StoredV8RevisionSnapshot>(predicate: #Predicate { $0.id == revisionID }))
        }
        for event in commit.radarEvents {
            let eventID = event.id
            try replaceRow(try StoredV8RadarEvent(event), matching: FetchDescriptor<StoredV8RadarEvent>(predicate: #Predicate { $0.id == eventID }))
        }
        try replaceCheckpointRow(commit.checkpoint)
        let jobEventID = commit.jobEvent.id
        try replaceRow(try StoredV8SyncJobEvent(commit.jobEvent), matching: FetchDescriptor<StoredV8SyncJobEvent>(predicate: #Predicate { $0.id == jobEventID }))
        try modelContext.save()
        return report
    }

    func save(insight: InsightArtifact) throws {
        try requireWritable(); try replaceAIArtifact(cacheKey: insight.cacheKey, paperID: insight.paperID, kind: "insight", createdAt: insight.createdAt, value: insight)
    }

    func removeInsights() throws {
        try requireWritable(); let descriptor = FetchDescriptor<StoredV8AIArtifact>(predicate: #Predicate { $0.workflowKind == "insight" })
        for row in try modelContext.fetch(descriptor) { modelContext.delete(row) }; try modelContext.save()
    }

    func setTracked(_ tracked: Bool, authorRecid: Int) throws {
        try requireWritable(); let descriptor = FetchDescriptor<StoredV8Author>(predicate: #Predicate { $0.recid == authorRecid })
        guard let existing = try modelContext.fetch(descriptor).first else { return }; var value = try existing.decoded(); value.isTracked = tracked
        modelContext.delete(existing); modelContext.insert(try StoredV8Author(value)); try modelContext.save()
    }

    func markRead(_ read: Bool, paperID: Int, at: Date?) throws {
        try requireWritable(); let descriptor = FetchDescriptor<StoredV8Paper>(predicate: #Predicate { $0.literatureID == paperID })
        guard let existing = try modelContext.fetch(descriptor).first else { return }
        let updatedAt = at ?? Date()
        // Reading state is not search text.  Update its typed scalar columns
        // in place instead of decoding and replacing the rich paper payload;
        // this keeps a single read mutation independent of paper size and of
        // the 20k-row search projection.
        existing.isRead = read
        existing.readAt = read ? updatedAt : nil
        let stateDescriptor = FetchDescriptor<StoredV8ReadingWorkflowState>(predicate: #Predicate { $0.paperID == paperID })
        if let state = try modelContext.fetch(stateDescriptor).first {
            state.isRead = read
            state.readAt = existing.readAt
            state.updatedAt = updatedAt
        } else {
            modelContext.insert(StoredV8ReadingWorkflowState(ReadingState(paperID: paperID, isRead: read, readAt: existing.readAt,
                                                                            isFavorite: existing.isFavorite, updatedAt: updatedAt)))
        }
        try modelContext.save()
    }

    func applyReferenceMutation(_ mutation: ReferenceMutation) throws {
        try requireWritable()
        switch mutation {
        case .setFavorite(let paperID, let isFavorite, let at):
            try setFavorite(isFavorite, paperID: paperID, at: at)
        case .upsertNote(let note):
            let noteID = note.id
            let descriptor = FetchDescriptor<StoredV8Note>(predicate: #Predicate { $0.id == noteID })
            let existing = try modelContext.fetch(descriptor)
            let affected = Set(existing.map(\.paperID) + [note.paperID])
            for row in existing { modelContext.delete(row) }
            modelContext.insert(StoredV8Note(note)); try refreshV9SearchIndex(affected); try modelContext.save()
        case .deleteNote(let id):
            let descriptor = FetchDescriptor<StoredV8Note>(predicate: #Predicate { $0.id == id })
            let existing = try modelContext.fetch(descriptor)
            let affected = Set(existing.map(\.paperID))
            for row in existing { modelContext.delete(row) }; try refreshV9SearchIndex(affected); try modelContext.save()
        case .upsertTag(let tag):
            let tagID = tag.id
            let affected = try paperIDs(tagID: tagID)
            let descriptor = FetchDescriptor<StoredV8Tag>(predicate: #Predicate { $0.id == tagID })
            for row in try modelContext.fetch(descriptor) { modelContext.delete(row) }
            modelContext.insert(StoredV8Tag(tag)); try refreshV9SearchIndex(affected); try modelContext.save()
        case .deleteTag(let id):
            let affected = try paperIDs(tagID: id)
            let descriptor = FetchDescriptor<StoredV8Tag>(predicate: #Predicate { $0.id == id }); for row in try modelContext.fetch(descriptor) { modelContext.delete(row) }
            let links = FetchDescriptor<StoredV8PaperTagLink>(predicate: #Predicate { $0.tagID == id }); for row in try modelContext.fetch(links) { modelContext.delete(row) }; try refreshV9SearchIndex(affected); try modelContext.save()
        case .setTags(let paperID, let tagIDs):
            let descriptor = FetchDescriptor<StoredV8PaperTagLink>(predicate: #Predicate { $0.paperID == paperID }); for row in try modelContext.fetch(descriptor) { modelContext.delete(row) }
            for tagID in tagIDs { modelContext.insert(StoredV8PaperTagLink(PaperTagLink(paperID: paperID, tagID: tagID))) }; try refreshV9SearchIndex([paperID]); try modelContext.save()
        case .upsertCollection(let collection):
            let collectionID = collection.id
            let affected = try paperIDs(collectionID: collectionID)
            let descriptor = FetchDescriptor<StoredV8Collection>(predicate: #Predicate { $0.id == collectionID }); for row in try modelContext.fetch(descriptor) { modelContext.delete(row) }
            modelContext.insert(StoredV8Collection(collection)); try refreshV9SearchIndex(affected); try modelContext.save()
        case .deleteCollection(let id):
            let affected = try paperIDs(collectionID: id)
            let descriptor = FetchDescriptor<StoredV8Collection>(predicate: #Predicate { $0.id == id }); for row in try modelContext.fetch(descriptor) { modelContext.delete(row) }
            let links = FetchDescriptor<StoredV8PaperCollectionLink>(predicate: #Predicate { $0.collectionID == id }); for row in try modelContext.fetch(links) { modelContext.delete(row) }; try refreshV9SearchIndex(affected); try modelContext.save()
        case .setCollectionPapers(let collectionID, let newPaperIDs, let at):
            let previous = try paperIDs(collectionID: collectionID)
            let descriptor = FetchDescriptor<StoredV8PaperCollectionLink>(predicate: #Predicate { $0.collectionID == collectionID }); for row in try modelContext.fetch(descriptor) { modelContext.delete(row) }
            for paperID in newPaperIDs { modelContext.insert(StoredV8PaperCollectionLink(CollectionPaperLink(collectionID: collectionID, paperID: paperID, addedAt: at))) }
            try refreshV9SearchIndex(previous.union(newPaperIDs)); try modelContext.save()
        }
    }

    private func paperIDs(tagID: UUID) throws -> Set<Int> {
        let descriptor = FetchDescriptor<StoredV8PaperTagLink>(predicate: #Predicate { $0.tagID == tagID })
        return Set(try modelContext.fetch(descriptor).map(\.paperID))
    }

    private func paperIDs(collectionID: UUID) throws -> Set<Int> {
        let descriptor = FetchDescriptor<StoredV8PaperCollectionLink>(predicate: #Predicate { $0.collectionID == collectionID })
        return Set(try modelContext.fetch(descriptor).map(\.paperID))
    }

    func saveFullText(document: FullTextDocument, chunks: [EvidenceChunk], anchors: [EvidenceAnchor]) throws {
        _ = try saveFullTextTyped(document: document, chunks: chunks, anchors: anchors)
    }

    func saveFullTextAndPlan(document: FullTextDocument, chunks: [EvidenceChunk], anchors: [EvidenceAnchor]) throws -> BlobMutationPlan {
        try saveFullTextTyped(document: document, chunks: chunks, anchors: anchors)
    }

    func saveOrphanedBlobDeletion(_ record: OrphanedBlobDeletion) throws {
        try requireWritable()
        let blobHash = record.blobHash
        try replaceRow(StoredV8OrphanedBlobDeletion(record), matching: FetchDescriptor<StoredV8OrphanedBlobDeletion>(predicate: #Predicate { $0.blobHash == blobHash }))
        try modelContext.save()
    }

    func orphanedBlobDeletions() throws -> [OrphanedBlobDeletion] {
        try modelContext.fetch(FetchDescriptor<StoredV8OrphanedBlobDeletion>())
            .map { $0.decoded() }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func removeOrphanedBlobDeletion(blobHash: String) throws {
        try requireWritable()
        try deleteRows(FetchDescriptor<StoredV8OrphanedBlobDeletion>(predicate: #Predicate { $0.blobHash == blobHash }))
        try modelContext.save()
    }

    func saveEvidenceAnchors(_ anchors: [EvidenceAnchor]) throws {
        try requireWritable()
        for anchor in anchors {
            let anchorID = anchor.id
            try replaceRow(StoredV8EvidenceAnchor(anchor), matching: FetchDescriptor<StoredV8EvidenceAnchor>(predicate: #Predicate { $0.id == anchorID }))
        }
        try modelContext.save()
    }
    func deleteFullText(documentID: String) throws { _ = try deleteFullTextTyped(documentID: documentID) }

    func deleteFullTextAndPlan(documentID: String) throws -> FullTextDeletionPlan {
        try deleteFullTextTyped(documentID: documentID)
    }
    func saveEvidenceInsight(_ artifact: EvidenceInsightArtifact) throws { try requireWritable(); try replaceAIArtifact(cacheKey: artifact.cacheKey, paperID: artifact.paperID, kind: "evidenceInsight", createdAt: artifact.createdAt, value: artifact) }
    func saveVisionArtifact(_ artifact: VisionArtifact) throws { try requireWritable(); try replaceAIArtifact(cacheKey: artifact.cacheKey, paperID: artifact.paperID, kind: "vision", createdAt: artifact.createdAt, value: artifact) }
    func saveBibTeXRecord(_ record: BibTeXRecord) throws {
        try requireWritable()
        let paperID = record.paperID
        try replaceRow(StoredV8BibTeXRecord(record), matching: FetchDescriptor<StoredV8BibTeXRecord>(predicate: #Predicate { $0.paperID == paperID }))
        try modelContext.save()
    }

    func commitAcceptedImport(paper: Paper, conflict: V3ImportConflict) throws {
        try requireWritable()
        let paperID = paper.literatureID
        let paperDescriptor = FetchDescriptor<StoredV8Paper>(predicate: #Predicate { $0.literatureID == paperID })
        var merged = paper
        if let existing = try modelContext.fetch(paperDescriptor).first {
            let prior = try existing.decoded()
            merged.firstSeenAt = prior.firstSeenAt
            merged.isRead = prior.isRead
            merged.readAt = prior.readAt
            merged.isFavorite = prior.isFavorite
            modelContext.delete(existing)
        }
        modelContext.insert(try StoredV8Paper(merged))
        let importedID = conflict.importedID
        try replaceRow(try StoredV8ImportConflict(conflict), matching: FetchDescriptor<StoredV8ImportConflict>(predicate: #Predicate { $0.importedID == importedID }))
        try refreshV9SearchIndex([paperID])
        try modelContext.save()
    }

    func commitNotebookEntry(_ entry: NotebookEntry, links: [NotebookAnchorLink]) throws {
        try requireWritable()
        let entryID = entry.id
        try replaceRow(StoredV8NotebookEntry(id: entry.id, paperID: entry.paperID, title: entry.title, body: entry.body,
                                             createdAt: entry.createdAt, updatedAt: entry.updatedAt),
                       matching: FetchDescriptor<StoredV8NotebookEntry>(predicate: #Predicate { $0.id == entryID }))
        try deleteRows(FetchDescriptor<StoredV8NotebookAnchorLink>(predicate: #Predicate { $0.entryID == entryID }))
        for link in links.sorted(by: { $0.sortIndex < $1.sortIndex }) {
            modelContext.insert(StoredV8NotebookAnchorLink(entryID: link.entryID, anchorID: link.anchorID, sortIndex: link.sortIndex))
        }
        try modelContext.save()
    }

    func applyV3(_ mutation: V3Mutation) throws {
        try requireWritable()
        try applyV3Typed(mutation)
        try modelContext.save()
    }

    private func checkedSnapshot() throws -> LibrarySnapshot {
        if let availabilityFailure { throw LatticeLensError.persistenceUnavailable(availabilityFailure) }
        do { return try V8TypedStoreCodec.snapshot(from: modelContext) }
        catch { availabilityFailure = "V8 typed store 读取/解码失败；后续写入已停止"; throw LatticeLensError.persistenceUnavailable(availabilityFailure!) }
    }

    private func requireWritable() throws { if let availabilityFailure { throw LatticeLensError.persistenceUnavailable(availabilityFailure) } }

    private static func paperMetadataChanged(from old: Paper, to new: Paper) -> Bool {
        old.updated != new.updated || old.titles != new.titles || old.abstracts != new.abstracts ||
        old.citationCount != new.citationCount || old.figures != new.figures ||
        old.documents != new.documents || old.contributors != new.contributors ||
        old.publicationStatus != new.publicationStatus || old.publicationYear != new.publicationYear
    }

    private func replaceCheckpointRow(_ checkpoint: SyncCheckpoint) throws {
        let checkpointJobID = checkpoint.jobID
        let descriptor = FetchDescriptor<StoredV8SyncCheckpoint>(predicate: #Predicate { $0.jobID == checkpointJobID })
        for row in try modelContext.fetch(descriptor) { modelContext.delete(row) }
        modelContext.insert(try StoredV8SyncCheckpoint(checkpoint))
    }

    private func replaceGenerationRow(_ generation: AuthorIndexGeneration) throws {
        let generationID = generation.id
        let descriptor = FetchDescriptor<StoredV8AuthorIndexGeneration>(predicate: #Predicate { $0.id == generationID })
        for row in try modelContext.fetch(descriptor) { modelContext.delete(row) }
        modelContext.insert(try StoredV8AuthorIndexGeneration(generation))
    }

    private func replaceRow<Model: PersistentModel>(_ row: Model, matching descriptor: FetchDescriptor<Model>) throws {
        for existing in try modelContext.fetch(descriptor) { modelContext.delete(existing) }
        modelContext.insert(row)
    }

    private func deleteRows<Model: PersistentModel>(_ descriptor: FetchDescriptor<Model>) throws {
        for row in try modelContext.fetch(descriptor) { modelContext.delete(row) }
    }

    /// V8 must never decode and re-materialize the complete compatibility
    /// snapshot for a workbench action.  Every V3 mutation below is resolved
    /// by its stable typed identity and shares the caller's one save boundary.
    private func applyV3Typed(_ mutation: V3Mutation) throws {
        switch mutation {
        case .deleteInsight(let key), .deleteEvidenceInsight(let key), .deleteVisionArtifact(let key):
            try deleteRows(FetchDescriptor<StoredV8AIArtifact>(predicate: #Predicate { $0.cacheKey == key }))
        case .saveGeneration(let value):
            try replaceGenerationRow(value)
        case .saveRevision(let value):
            let id = value.id
            try replaceRow(try StoredV8RevisionSnapshot(value), matching: FetchDescriptor<StoredV8RevisionSnapshot>(predicate: #Predicate { $0.id == id }))
        case .saveRadarEvent(let value):
            let id = value.id
            try replaceRow(try StoredV8RadarEvent(value), matching: FetchDescriptor<StoredV8RadarEvent>(predicate: #Predicate { $0.id == id }))
        case .acknowledgeRadarEvent(let id):
            let descriptor = FetchDescriptor<StoredV8RadarEvent>(predicate: #Predicate { $0.id == id })
            guard let row = try modelContext.fetch(descriptor).first else { return }
            var value = try JSONDecoder.latticeLens.decode(RadarEvent.self, from: row.eventData)
            value.isAcknowledged = true
            try replaceRow(try StoredV8RadarEvent(value), matching: descriptor)
        case .saveQuery(let value):
            let id = value.id
            try replaceRow(try StoredV8SavedQuery(value), matching: FetchDescriptor<StoredV8SavedQuery>(predicate: #Predicate { $0.id == id }))
        case .deleteQuery(let id):
            try deleteRows(FetchDescriptor<StoredV8SavedQuery>(predicate: #Predicate { $0.id == id }))
        case .saveBatch(let value):
            let id = value.id
            try replaceRow(try StoredV8SyncBatchV3(value), matching: FetchDescriptor<StoredV8SyncBatchV3>(predicate: #Predicate { $0.id == id }))
        case .saveJobEvent(let value):
            let id = value.id
            try replaceRow(try StoredV8SyncJobEvent(value), matching: FetchDescriptor<StoredV8SyncJobEvent>(predicate: #Predicate { $0.id == id }))
        case .saveBlob(let value):
            let blobHash = value.hash
            try replaceRow(StoredV8ContentBlob(value), matching: FetchDescriptor<StoredV8ContentBlob>(predicate: #Predicate { $0.blobHash == blobHash }))
        case .saveOrphanedBlobDeletion(let value):
            let blobHash = value.blobHash
            try replaceRow(StoredV8OrphanedBlobDeletion(value), matching: FetchDescriptor<StoredV8OrphanedBlobDeletion>(predicate: #Predicate { $0.blobHash == blobHash }))
        case .deleteOrphanedBlobDeletion(let blobHash):
            try deleteRows(FetchDescriptor<StoredV8OrphanedBlobDeletion>(predicate: #Predicate { $0.blobHash == blobHash }))
        case .saveDocumentReference(let value):
            let id = value.id
            try replaceRow(StoredV8DocumentReference(value), matching: FetchDescriptor<StoredV8DocumentReference>(predicate: #Predicate { $0.id == id }))
        case .saveUserAnchor(let value):
            let id = value.id
            try replaceRow(StoredV8UserAnnotation(value), matching: FetchDescriptor<StoredV8UserAnnotation>(predicate: #Predicate { $0.id == id }))
        case .deleteUserAnchor(let id):
            try deleteRows(FetchDescriptor<StoredV8UserAnnotation>(predicate: #Predicate { $0.id == id }))
        case .saveNotebookEntry(let value):
            let id = value.id
            try replaceRow(StoredV8NotebookEntry(id: value.id, paperID: value.paperID, title: value.title, body: value.body,
                                                 createdAt: value.createdAt, updatedAt: value.updatedAt),
                           matching: FetchDescriptor<StoredV8NotebookEntry>(predicate: #Predicate { $0.id == id }))
        case .deleteNotebookEntry(let id):
            try deleteRows(FetchDescriptor<StoredV8NotebookEntry>(predicate: #Predicate { $0.id == id }))
            try deleteRows(FetchDescriptor<StoredV8NotebookAnchorLink>(predicate: #Predicate { $0.entryID == id }))
        case .replaceNotebookAnchorLinks(let entryID, let links):
            try deleteRows(FetchDescriptor<StoredV8NotebookAnchorLink>(predicate: #Predicate { $0.entryID == entryID }))
            for link in links.sorted(by: { $0.sortIndex < $1.sortIndex }) {
                modelContext.insert(StoredV8NotebookAnchorLink(entryID: link.entryID, anchorID: link.anchorID, sortIndex: link.sortIndex))
            }
        case .saveWorkspace(let value):
            let id = value.id
            try replaceRow(try StoredV8Workspace(value), matching: FetchDescriptor<StoredV8Workspace>(predicate: #Predicate { $0.id == id }))
        case .deleteWorkspace(let id):
            try deleteRows(FetchDescriptor<StoredV8Workspace>(predicate: #Predicate { $0.id == id }))
            try deleteRows(FetchDescriptor<StoredV8WorkspacePaperLink>(predicate: #Predicate { $0.workspaceID == id }))
            try deleteRows(FetchDescriptor<StoredV8PhysicsContract>(predicate: #Predicate { $0.workspaceID == id }))
            try deleteRows(FetchDescriptor<StoredV8PhysicsCell>(predicate: #Predicate { $0.workspaceID == id }))
        case .saveWorkspaceLink(let value):
            let key = "\(value.workspaceID.uuidString):\(value.paperID)"
            try replaceRow(StoredV8WorkspacePaperLink(value), matching: FetchDescriptor<StoredV8WorkspacePaperLink>(predicate: #Predicate { $0.key == key }))
        case .deleteWorkspaceLink(let workspaceID, let paperID):
            let key = "\(workspaceID.uuidString):\(paperID)"
            try deleteRows(FetchDescriptor<StoredV8WorkspacePaperLink>(predicate: #Predicate { $0.key == key }))
        case .savePhysicsContract(let value):
            let id = value.id
            try replaceRow(try StoredV8PhysicsContract(value), matching: FetchDescriptor<StoredV8PhysicsContract>(predicate: #Predicate { $0.id == id }))
        case .savePhysicsCell(let value):
            let id = value.id
            try replaceRow(try StoredV8PhysicsCell(value), matching: FetchDescriptor<StoredV8PhysicsCell>(predicate: #Predicate { $0.id == id }))
        case .replacePhysicsMatrix(let workspaceID, let cells):
            try deleteRows(FetchDescriptor<StoredV8PhysicsCell>(predicate: #Predicate { $0.workspaceID == workspaceID }))
            for value in cells { modelContext.insert(try StoredV8PhysicsCell(value)) }
        case .saveCitationEdge(let value):
            let id = value.id
            try replaceRow(StoredV8CitationEdge(value), matching: FetchDescriptor<StoredV8CitationEdge>(predicate: #Predicate { $0.id == id }))
        case .saveCoauthorEdge(let value):
            let id = value.id
            try replaceRow(StoredV8CoauthorEdge(value), matching: FetchDescriptor<StoredV8CoauthorEdge>(predicate: #Predicate { $0.id == id }))
        case .saveExport(let value):
            let id = value.id
            try replaceRow(try StoredV8ExportTransaction(value), matching: FetchDescriptor<StoredV8ExportTransaction>(predicate: #Predicate { $0.id == id }))
        case .saveCloudState(let value):
            let recordID = value.recordID
            try replaceRow(StoredV8CloudRecordState(value), matching: FetchDescriptor<StoredV8CloudRecordState>(predicate: #Predicate { $0.recordID == recordID }))
        case .saveConflict(let value):
            let id = value.id
            try replaceRow(StoredV8ConflictCopy(value), matching: FetchDescriptor<StoredV8ConflictCopy>(predicate: #Predicate { $0.id == id }))
        case .saveMigrationJournal(let value):
            let id = value.id
            try replaceRow(try StoredV8MigrationJournal(value), matching: FetchDescriptor<StoredV8MigrationJournal>(predicate: #Predicate { $0.id == id }))
        case .saveImportedBibliography(let value):
            let id = value.id
            try replaceRow(try StoredV8ImportRecord(value), matching: FetchDescriptor<StoredV8ImportRecord>(predicate: #Predicate { $0.id == id }))
        case .saveImportConflict(let value):
            let importedID = value.importedID
            try replaceRow(try StoredV8ImportConflict(value), matching: FetchDescriptor<StoredV8ImportConflict>(predicate: #Predicate { $0.importedID == importedID }))
        case .setImportConflictStatus(let importedID, let status):
            let descriptor = FetchDescriptor<StoredV8ImportConflict>(predicate: #Predicate { $0.importedID == importedID })
            guard let row = try modelContext.fetch(descriptor).first else { return }
            var value = try row.decoded()
            value.status = status
            if status != .accepted { value.acceptedFields = [] }
            try replaceRow(try StoredV8ImportConflict(value), matching: descriptor)
        case .quarantineEvidence(let id):
            let descriptor = FetchDescriptor<StoredV8QuarantinedEvidence>(predicate: #Predicate { $0.evidenceID == id })
            if try modelContext.fetch(descriptor).isEmpty { modelContext.insert(StoredV8QuarantinedEvidence(evidenceID: id)) }
        }
    }

    private func replaceAIArtifact<T: Encodable>(cacheKey: String, paperID: Int, kind: String, createdAt: Date, value: T) throws {
        let descriptor = FetchDescriptor<StoredV8AIArtifact>(predicate: #Predicate { $0.cacheKey == cacheKey })
        for row in try modelContext.fetch(descriptor) { modelContext.delete(row) }
        modelContext.insert(StoredV8AIArtifact(cacheKey: cacheKey, paperID: paperID, workflowKind: kind, createdAt: createdAt, artifactData: try JSONEncoder.latticeLens.encode(value)))
        try modelContext.save()
    }

    private func setFavorite(_ favorite: Bool, paperID: Int, at: Date) throws {
        let descriptor = FetchDescriptor<StoredV8Paper>(predicate: #Predicate { $0.literatureID == paperID })
        guard let existing = try modelContext.fetch(descriptor).first else { return }; var paper = try existing.decoded(); paper.isFavorite = favorite
        modelContext.delete(existing); modelContext.insert(try StoredV8Paper(paper))
        let stateDescriptor = FetchDescriptor<StoredV8ReadingWorkflowState>(predicate: #Predicate { $0.paperID == paperID })
        for row in try modelContext.fetch(stateDescriptor) { modelContext.delete(row) }
        modelContext.insert(StoredV8ReadingWorkflowState(ReadingState(paperID: paperID, isRead: paper.isRead, readAt: paper.readAt, isFavorite: favorite, updatedAt: at)))
        try modelContext.save()
    }

    /// Commit the document row, document reference, blob refcount, chunks and
    /// anchors together. The returned plan is intentionally computed only
    /// after that save boundary; callers may then delete an app-owned PDF.
    private func saveFullTextTyped(document: FullTextDocument, chunks: [EvidenceChunk], anchors: [EvidenceAnchor]) throws -> BlobMutationPlan {
        try requireWritable()
        // Capture only scalar values outside `#Predicate`.  Capturing a
        // property from a Codable value here makes the current SwiftData
        // runtime bridge an NSNumber-to-NSString cast at execution time.
        let documentPaperID = document.paperID
        let documentID = document.id
        let documentHash = document.sha256
        let existingDocuments = try modelContext.fetch(FetchDescriptor<StoredV8FullTextDocument>(predicate: #Predicate { $0.paperID == documentPaperID }))
        let superseded = try existingDocuments.map { try $0.decoded() }.filter {
            $0.id != document.id && $0.sourceKind == document.sourceKind && $0.sourceURL == document.sourceURL
        }
        var retired = [(hash: String, filename: String?)]()
        for old in superseded {
            retired.append(contentsOf: try retireDocumentReference(documentID: old.id))
            try deleteDocumentContent(paperID: old.paperID, documentHash: old.sha256)
            let oldDocumentID = old.id
            let descriptor = FetchDescriptor<StoredV8FullTextDocument>(predicate: #Predicate { $0.documentID == oldDocumentID })
            for row in try modelContext.fetch(descriptor) { modelContext.delete(row) }
        }

        // Re-extracting the same document replaces only that document's
        // chunks/anchors. Its active reference remains one contribution to the
        // content-addressed blob rather than being decremented and incremented.
        try deleteDocumentContent(paperID: documentPaperID, documentHash: documentHash)
        let documentDescriptor = FetchDescriptor<StoredV8FullTextDocument>(predicate: #Predicate { $0.documentID == documentID })
        for row in try modelContext.fetch(documentDescriptor) { modelContext.delete(row) }
        modelContext.insert(StoredV8FullTextDocument(document))
        try activateDocumentReference(document)
        for chunk in chunks { modelContext.insert(StoredV8EvidenceChunk(chunk)) }
        for anchor in anchors { modelContext.insert(StoredV8EvidenceAnchor(anchor)) }
        try modelContext.save()
        return try completedRetirementPlan(documentID: document.id, retired: retired)
    }

    private func deleteFullTextTyped(documentID: String) throws -> FullTextDeletionPlan {
        try requireWritable()
        let descriptor = FetchDescriptor<StoredV8FullTextDocument>(predicate: #Predicate { $0.documentID == documentID })
        guard let row = try modelContext.fetch(descriptor).first else {
            return FullTextDeletionPlan(documentID: documentID, blobHash: nil, localFilename: nil, remainingReferenceCount: 0, shouldDeleteFile: false)
        }
        let document = try row.decoded()
        let referenceDescriptor = FetchDescriptor<StoredV8DocumentReference>(predicate: #Predicate { $0.id == documentID })
        let reference = try modelContext.fetch(referenceDescriptor).first
        let blobHash = reference?.contentBlobHash ?? document.sha256
        let filename: String?
        if let reference {
            let referenceHash = reference.contentBlobHash
            let blobDescriptor = FetchDescriptor<StoredV8ContentBlob>(predicate: #Predicate { $0.blobHash == referenceHash })
            filename = try modelContext.fetch(blobDescriptor).first?.localFilename ?? document.localFilename
        } else {
            filename = document.localFilename
        }
        let retired = try retireDocumentReference(documentID: documentID)
        try deleteDocumentContent(paperID: document.paperID, documentHash: document.sha256)
        modelContext.delete(row)
        try modelContext.save()
        let remaining = try blobReferenceCount(blobHash)
        return FullTextDeletionPlan(documentID: documentID, blobHash: blobHash, localFilename: filename,
                                    remainingReferenceCount: remaining, shouldDeleteFile: retired.contains { $0.hash == blobHash } && remaining == 0)
    }

    private func activateDocumentReference(_ document: FullTextDocument) throws {
        let documentID = document.id
        let descriptor = FetchDescriptor<StoredV8DocumentReference>(predicate: #Predicate { $0.id == documentID })
        if let reference = try modelContext.fetch(descriptor).first {
            let wasActive = !reference.isDeleted
            let previousHash = reference.contentBlobHash
            if wasActive && previousHash != document.sha256 { _ = try decrementBlob(previousHash) }
            if !wasActive || previousHash != document.sha256 { try incrementBlob(hash: document.sha256, byteCount: document.byteCount, filename: document.localFilename) }
            reference.paperID = document.paperID; reference.documentHash = document.sha256; reference.sourceURL = document.sourceURL.absoluteString
            reference.sourceKind = document.sourceKind.rawValue; reference.contentBlobHash = document.sha256; reference.isDeleted = false
        } else {
            try incrementBlob(hash: document.sha256, byteCount: document.byteCount, filename: document.localFilename)
            modelContext.insert(StoredV8DocumentReference(DocumentReference(id: document.id, paperID: document.paperID, documentHash: document.sha256,
                                                                             sourceURL: document.sourceURL, sourceKind: document.sourceKind,
                                                                             contentBlobHash: document.sha256, isDeleted: false)))
        }
    }

    private func retireDocumentReference(documentID: String) throws -> [(hash: String, filename: String?)] {
        let descriptor = FetchDescriptor<StoredV8DocumentReference>(predicate: #Predicate { $0.id == documentID })
        guard let reference = try modelContext.fetch(descriptor).first, !reference.isDeleted else { return [] }
        reference.isDeleted = true
        return try decrementBlob(reference.contentBlobHash)
    }

    private func incrementBlob(hash: String, byteCount: Int, filename: String?) throws {
        let descriptor = FetchDescriptor<StoredV8ContentBlob>(predicate: #Predicate { $0.blobHash == hash })
        if let blob = try modelContext.fetch(descriptor).first {
            blob.referenceCount += 1
            if blob.localFilename == nil { blob.localFilename = filename }
        } else {
            modelContext.insert(StoredV8ContentBlob(ContentBlob(hash: hash, byteCount: byteCount, localFilename: filename, referenceCount: 1, createdAt: Date())))
        }
    }

    private func decrementBlob(_ hash: String) throws -> [(hash: String, filename: String?)] {
        let descriptor = FetchDescriptor<StoredV8ContentBlob>(predicate: #Predicate { $0.blobHash == hash })
        guard let blob = try modelContext.fetch(descriptor).first else { return [(hash, nil)] }
        blob.referenceCount = max(0, blob.referenceCount - 1)
        return [(hash, blob.localFilename)]
    }

    private func blobReferenceCount(_ hash: String) throws -> Int {
        let descriptor = FetchDescriptor<StoredV8ContentBlob>(predicate: #Predicate { $0.blobHash == hash })
        return try modelContext.fetch(descriptor).first?.referenceCount ?? 0
    }

    private func deleteDocumentContent(paperID: Int, documentHash: String) throws {
        let chunkDescriptor = FetchDescriptor<StoredV8EvidenceChunk>(predicate: #Predicate { $0.paperID == paperID && $0.documentHash == documentHash })
        let chunks = try modelContext.fetch(chunkDescriptor)
        let chunkIDs = Set(chunks.map(\.id))
        for row in chunks { modelContext.delete(row) }
        let prefix = "v3pdf:\(paperID):\(documentHash):"
        let anchorDescriptor = FetchDescriptor<StoredV8EvidenceAnchor>(predicate: #Predicate { $0.paperID == paperID && $0.sourceKind == "pdf" })
        for row in try modelContext.fetch(anchorDescriptor) where chunkIDs.contains(row.id) || row.id.hasPrefix(prefix) { modelContext.delete(row) }
    }

    private func completedRetirementPlan(documentID: String, retired: [(hash: String, filename: String?)]) throws -> BlobMutationPlan {
        var hashes = Set<String>(); var filenames = Set<String>()
        for item in retired where try blobReferenceCount(item.hash) == 0 {
            hashes.insert(item.hash); if let filename = item.filename { filenames.insert(filename) }
        }
        return BlobMutationPlan(documentID: documentID, retiredBlobHashes: hashes.sorted(), retiredLocalFilenames: filenames.sorted())
    }

}

/// A migration failure must never silently fall back to a new JSON library.
/// This fail-closed store lets the UI present recovery information while every
/// mutating operation remains unavailable until the user chooses a new,
/// explicit recovery target.
actor V8MigrationBlockedStore: LibraryStoring {
    private let reason: String
    init(reason: String) { self.reason = reason }
    func initializationState() -> LibraryInitializationState { .readOnlyFailure(reason) }
    func snapshot() -> LibrarySnapshot { var value = LibrarySnapshot(); value.readErrorMessage = reason; return value }
    func snapshotResult() -> LibrarySnapshotReadResult { LibrarySnapshotReadResult(state: .readOnlyFailure, snapshot: snapshot(), message: reason) }
    private func unavailable() -> Error { LatticeLensError.persistenceUnavailable(reason) }
    func upsert(authors: [Author]) throws { throw unavailable() }
    func upsert(papers: [Paper], for authorRecid: Int) throws -> PaperUpsertReport { throw unavailable() }
    func upsert(detail paper: Paper) throws { throw unavailable() }
    func save(checkpoint: SyncCheckpoint?) throws { throw unavailable() }
    func checkpoint(jobID: String) throws -> SyncCheckpoint? { throw unavailable() }
    func completeCheckpoint(jobID: String, at: Date) throws { throw unavailable() }
    func deleteCheckpoint(jobID: String) throws { throw unavailable() }
    func save(insight: InsightArtifact) throws { throw unavailable() }
    func removeInsights() throws { throw unavailable() }
    func setTracked(_ tracked: Bool, authorRecid: Int) throws { throw unavailable() }
    func markRead(_ read: Bool, paperID: Int, at: Date?) throws { throw unavailable() }
    func applyReferenceMutation(_ mutation: ReferenceMutation) throws { throw unavailable() }
    func saveFullText(document: FullTextDocument, chunks: [EvidenceChunk], anchors: [EvidenceAnchor]) throws { throw unavailable() }
    func saveEvidenceAnchors(_ anchors: [EvidenceAnchor]) throws { throw unavailable() }
    func deleteFullText(documentID: String) throws { throw unavailable() }
    func saveEvidenceInsight(_ artifact: EvidenceInsightArtifact) throws { throw unavailable() }
    func saveVisionArtifact(_ artifact: VisionArtifact) throws { throw unavailable() }
    func saveBibTeXRecord(_ record: BibTeXRecord) throws { throw unavailable() }
    func applyV3(_ mutation: V3Mutation) throws { throw unavailable() }
}

@ModelActor actor V4NormalizedLibraryStore {
    func paperCount() throws -> Int { try modelContext.fetchCount(FetchDescriptor<StoredV4Paper>()) }
    func authorCount() throws -> Int { try modelContext.fetchCount(FetchDescriptor<StoredV4Author>()) }
    func linkCount() throws -> Int { try modelContext.fetchCount(FetchDescriptor<StoredV4PaperAuthorLink>()) }
    func chunkCount() throws -> Int { try modelContext.fetchCount(FetchDescriptor<StoredV4Chunk>()) }

    func upsert(paper: StoredV4Paper) throws {
        let paperID = paper.literatureID
        let descriptor = FetchDescriptor<StoredV4Paper>(predicate: #Predicate<StoredV4Paper> { $0.literatureID == paperID })
        if let existing = try modelContext.fetch(descriptor).first {
            existing.title = paper.title; existing.abstractText = paper.abstractText; existing.doi = paper.doi; existing.arxivID = paper.arxivID; existing.updatedAt = paper.updatedAt
            existing.isRead = paper.isRead; existing.isFavorite = paper.isFavorite; existing.readingState = paper.readingState; existing.priority = paper.priority
        } else { modelContext.insert(paper) }
        try modelContext.save()
    }

    /// A bounded, single-transaction upsert used by production imports and
    /// the disk-backed performance harness.  It deliberately resolves each
    /// identity against the normalized rows and saves once, so callers do not
    /// accidentally turn a batch import into N snapshot rewrites or N commits.
    @discardableResult
    func upsertSyntheticBatch(startingAt firstPaperID: Int, count: Int) throws -> V4BatchUpsertOutcome {
        guard firstPaperID >= 0, count >= 0 else { throw V4LocalError.notFound }
        var inserted = 0
        var updated = 0
        for offset in 0..<count {
            let paperID = firstPaperID + offset
            let descriptor = FetchDescriptor<StoredV4Paper>(predicate: #Predicate<StoredV4Paper> { $0.literatureID == paperID })
            if let existing = try modelContext.fetch(descriptor).first {
                existing.title = "Synthetic batch update \(paperID)"
                existing.abstractText = "local benchmark batch upsert \(paperID)"
                existing.updatedAt = Date()
                updated += 1
            } else {
                modelContext.insert(StoredV4Paper(literatureID: paperID,
                                                   title: "Synthetic batch insert \(paperID)",
                                                   abstractText: "local benchmark batch upsert \(paperID)"))
                inserted += 1
            }
        }
        try modelContext.save()
        return V4BatchUpsertOutcome(inserted: inserted, updated: updated)
    }

    func markRead(paperID: Int, read: Bool) throws {
        let descriptor = FetchDescriptor<StoredV4Paper>(predicate: #Predicate<StoredV4Paper> { $0.literatureID == paperID })
        guard let paper = try modelContext.fetch(descriptor).first else { throw V4LocalError.notFound }
        paper.isRead = read; paper.readingState = read ? V4ReadingWorkflowState.reading.rawValue : V4ReadingWorkflowState.inbox.rawValue
        paper.updatedAt = Date(); try modelContext.save()
    }

    func search(_ normalizedQuery: String, limit: Int = 100) throws -> [StoredV4SearchIndexEntry] {
        // `normalizedText` is already folded by SearchNormalizer.  Using the
        // locale-aware comparator here forced a full Foundation collation of
        // every row; a plain normalized substring keeps the query in the
        // SwiftData store and preserves the same search semantics.
        // Do not add an unindexed global sort before the limit: SQLite would
        // materialize every matching row merely to return the first 100.
        // Product ranking is applied from the bounded candidate set.
        var descriptor = FetchDescriptor<StoredV4SearchIndexEntry>(predicate: #Predicate { $0.normalizedText.contains(normalizedQuery) })
        descriptor.fetchLimit = max(0, limit)
        return try modelContext.fetch(descriptor)
    }

    func searchCount(_ normalizedQuery: String, limit: Int = 100) throws -> Int {
        try searchPaperIDs(normalizedQuery, limit: limit).count
    }

    func searchPaperIDs(_ normalizedQuery: String, limit: Int = 100) throws -> [Int] {
        let tokens = V4SearchTokenTerms.make(normalizedQuery)
        guard !tokens.isEmpty, limit > 0 else { return [] }
        var candidates: Set<Int>?
        for token in tokens {
            let descriptor = FetchDescriptor<StoredV4SearchToken>(predicate: #Predicate { $0.token == token })
            guard let row = try modelContext.fetch(descriptor).first else { return [] }
            let values = Set(row.paperIDs)
            candidates = candidates.map { $0.intersection(values) } ?? values
            if candidates?.isEmpty == true { return [] }
        }
        return Array((candidates ?? []).sorted().prefix(limit))
    }

    func saveIndex(_ entries: [V4SearchIndexEntry]) throws {
        for value in try modelContext.fetch(FetchDescriptor<StoredV4SearchIndexEntry>()) { modelContext.delete(value) }
        for entry in entries { modelContext.insert(StoredV4SearchIndexEntry(entry)) }
        try rebuildTokenIndex(entries)
        try modelContext.save()
    }

    func insertSynthetic(authorCount: Int, paperCount: Int, linkCount: Int, chunkCount: Int) throws {
        for index in 0..<authorCount { modelContext.insert(StoredV4Author(recid: index)) }
        for index in 0..<paperCount { modelContext.insert(StoredV4Paper(literatureID: index, title: "Synthetic hep-lat \(index)", abstractText: "local benchmark")) }
        for index in 0..<linkCount {
            // Keep each synthetic relationship unique: 100k links over 20k
            // papers and 2k authors must not collapse to 20k rows through a
            // modulo pair that repeats after the least common multiple.
            let paperID = index % max(1, paperCount)
            let authorRecid = (index / max(1, paperCount)) % max(1, authorCount)
            modelContext.insert(StoredV4PaperAuthorLink(paperID: paperID, authorRecid: authorRecid, position: index % 12))
        }
        for index in 0..<chunkCount {
            let text = "chunk \(index) a=0.09 fm local benchmark"
            modelContext.insert(StoredV4Chunk(id: "chunk-\(index)", paperID: index % max(1, paperCount), documentHash: "hash-\(index % 100)", page: index % 10 + 1, text: text, textHash: StableHash.sha256(text)))
        }
        // The benchmark must exercise the actual local search index rather
        // than an empty projection or an in-memory Dictionary substitute.
        for index in 0..<paperCount {
            let title = "Synthetic hep-lat \(index)"
            let abstract = "local benchmark lattice QCD paper \(index)"
            modelContext.insert(StoredV4SearchIndexEntry(V4SearchIndexEntry(id: "paper-title-\(index)", paperID: index, field: "title", text: title, normalizedText: SearchNormalizer.normalize(title), page: nil, quote: nil, quoteHash: nil)))
            modelContext.insert(StoredV4SearchIndexEntry(V4SearchIndexEntry(id: "paper-abstract-\(index)", paperID: index, field: "abstract", text: abstract, normalizedText: SearchNormalizer.normalize(abstract), page: nil, quote: nil, quoteHash: nil)))
        }
        var tokens = [String: Set<Int>]()
        for index in 0..<paperCount {
            let text = "Synthetic hep-lat \(index) local benchmark lattice QCD paper \(index)"
            for token in Set(V4SearchTokenTerms.make(text)) {
                tokens[token, default: []].insert(index)
            }
        }
        for (token, paperIDs) in tokens { modelContext.insert(StoredV4SearchToken(token: token, paperIDs: Array(paperIDs))) }
        try modelContext.save()
    }

    private func rebuildTokenIndex(_ entries: [V4SearchIndexEntry]) throws {
        for value in try modelContext.fetch(FetchDescriptor<StoredV4SearchToken>()) { modelContext.delete(value) }
        var mapping = [String: Set<Int>]()
        for entry in entries {
            for token in Set(V4SearchTokenTerms.make(entry.text)) {
                mapping[token, default: []].insert(entry.paperID)
            }
        }
        for (token, paperIDs) in mapping { modelContext.insert(StoredV4SearchToken(token: token, paperIDs: Array(paperIDs))) }
    }
}

struct V4BatchUpsertOutcome: Equatable, Sendable {
    let inserted: Int
    let updated: Int
}

extension StoredV4Author {
    convenience init(recid: Int) {
        self.init(recid: recid, preferredName: "Synthetic Author \(recid)", hIndexAll: nil, hIndexState: "unknown", isSelf: false, updatedAt: Date())
    }
}

enum V4NormalizedStoreFactory {
    static func makeInMemory() throws -> V4NormalizedLibraryStore {
        let schema = Schema(versionedSchema: LatticeLensSchemaV6.self)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV6.self, configurations: configuration)
        return V4NormalizedLibraryStore(modelContainer: container)
    }

    /// Test/diagnostic-only factory for an explicit caller-owned store URL.
    /// It never selects the app's default library path, so migration drills
    /// cannot accidentally open or overwrite a user's active library.
    static func makeDiskBacked(at url: URL) throws -> V4NormalizedLibraryStore {
        let bootstrap = try V4StoreBootstrapCoordinator.prepare(storeURL: url, targetSchemaVersion: 6)
        let schema = Schema(versionedSchema: LatticeLensSchemaV6.self)
        let configuration = ModelConfiguration(url: url)
        do {
            // `prepare` has already copied the complete pre-open store family
            // (including SQLite WAL/SHM sidecars) and written a durable
            // journal.  Never open an existing store before that boundary.
            let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV6.self, configurations: configuration)
            let context = ModelContext(container)
            let count = (try? context.fetchCount(FetchDescriptor<StoredV4Paper>())) ?? 0
            try bootstrap.complete(postRowCount: count)
            return V4NormalizedLibraryStore(modelContainer: container)
        } catch {
            try? bootstrap.fail(error)
            throw error
        }
    }
}

struct V4StoreBackupFile: Codable, Hashable, Sendable {
    let relativePath: String
    let byteCount: Int
    let sha256: String
}

struct V4StoreBackupManifest: Codable, Hashable, Sendable {
    let id: UUID
    let schemaVersion: Int
    let createdAt: Date
    /// A stable, non-sensitive source description.  Backup manifests can be
    /// copied into a Research Bundle or an audit record, so they must never
    /// serialize a user's absolute library path.
    let sourcePathCategory: String
    let files: [V4StoreBackupFile]
    let manifestHash: String

    init(id: UUID, schemaVersion: Int, createdAt: Date, sourcePathCategory: String,
         files: [V4StoreBackupFile], manifestHash: String) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.sourcePathCategory = sourcePathCategory
        self.files = files
        self.manifestHash = manifestHash
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, createdAt, sourcePathCategory, sourcePath, files, manifestHash
    }

    /// Decode historical local manifests without retaining their path in a
    /// newly re-encoded artifact.  The legacy field is intentionally not
    /// exposed as a property and is never emitted by `encode(to:)`.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        sourcePathCategory = try values.decodeIfPresent(String.self, forKey: .sourcePathCategory) ?? "legacy_redacted_source"
        files = try values.decode([V4StoreBackupFile].self, forKey: .files)
        manifestHash = try values.decode(String.self, forKey: .manifestHash)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(sourcePathCategory, forKey: .sourcePathCategory)
        try values.encode(files, forKey: .files)
        try values.encode(manifestHash, forKey: .manifestHash)
    }
}

enum V4StoreBackupCoordinator {
    static func createBackup(source: URL, destinationRoot: URL, schemaVersion: Int = 5, fileManager: FileManager = .default) throws -> V4StoreBackupManifest {
        guard source.standardizedFileURL.path != destinationRoot.standardizedFileURL.path else { throw V4LocalError.pathEscape }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let backupID = UUID(); let destination = destinationRoot.appendingPathComponent(backupID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var files: [V4StoreBackupFile] = []
        let sourceIsDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if sourceIsDirectory {
            let enumerator = fileManager.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            while let url = enumerator?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let relative = url.path.replacingOccurrences(of: source.path + "/", with: "")
                let target = destination.appendingPathComponent(relative)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: url, to: target)
                let data = try Data(contentsOf: url)
                files.append(V4StoreBackupFile(relativePath: relative, byteCount: data.count, sha256: StableHash.sha256(data)))
            }
        } else {
            // SwiftData/Core Data SQLite stores are a family: a checkpointed
            // main file can still have live `-wal` and `-shm` sidecars.  A
            // backup that copies only the main file can restore a logically
            // older or corrupt database, so preserve every extant sibling as
            // one manifest-verified unit.
            let family = [source,
                          URL(fileURLWithPath: source.path + "-wal"),
                          URL(fileURLWithPath: source.path + "-shm")]
            for member in family where fileManager.fileExists(atPath: member.path) {
                let data = try Data(contentsOf: member)
                let relative = member.lastPathComponent
                let target = destination.appendingPathComponent(relative)
                try data.write(to: target, options: .atomic)
                files.append(V4StoreBackupFile(relativePath: relative, byteCount: data.count, sha256: StableHash.sha256(data)))
            }
            // A caller may not claim a backup of a nonexistent store.  Fresh
            // stores are deliberately handled by the bootstrap without any
            // backup/journal record.
            guard !files.isEmpty else { throw V4LocalError.notFound }
        }
        let encoded = try JSONEncoder.latticeLens.encode(files)
        let sourcePathCategory = sourceIsDirectory ? "store_package" : "sqlite_store_family"
        let manifest = V4StoreBackupManifest(id: backupID, schemaVersion: schemaVersion, createdAt: Date(), sourcePathCategory: sourcePathCategory, files: files,
                                             manifestHash: StableHash.sha256(encoded))
        try JSONEncoder.latticeLens.encode(manifest).write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
        return manifest
    }

    static func verify(_ manifest: V4StoreBackupManifest, in backupRoot: URL,
                       fileManager: FileManager = .default) throws -> Bool {
        let directory = backupRoot.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        for entry in manifest.files {
            let file = try V4OwnedPath.canonicalFile(named: entry.relativePath, root: directory, fileManager: fileManager)
            guard fileManager.fileExists(atPath: file.path) else { return false }
            let data = try Data(contentsOf: file)
            guard data.count == entry.byteCount, StableHash.sha256(data) == entry.sha256 else { return false }
        }
        return StableHash.sha256((try JSONEncoder.latticeLens.encode(manifest.files))) == manifest.manifestHash
    }

    /// Copies a verified backup into a fresh target.  Existing active store
    /// packages are never replaced in place.
    static func restore(_ manifest: V4StoreBackupManifest, from backupRoot: URL, to target: URL,
                        fileManager: FileManager = .default) throws {
        guard !fileManager.fileExists(atPath: target.path) else { throw V4LocalError.bundleConflict }
        guard try verify(manifest, in: backupRoot, fileManager: fileManager) else { throw V4LocalError.invalidBundle("backup hash mismatch") }
        let source = backupRoot.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        for entry in manifest.files {
            let sourceFile = try V4OwnedPath.canonicalFile(named: entry.relativePath, root: source, fileManager: fileManager)
            let targetFile = try V4OwnedPath.canonicalFile(named: entry.relativePath, root: target, fileManager: fileManager)
            try fileManager.createDirectory(at: targetFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceFile, to: targetFile)
        }
    }
}

/// Independent, pre-open migration record for a caller-owned SwiftData URL.
/// The journal is deliberately outside the SQLite store family, so a failed
/// model migration cannot erase the evidence required to resume or restore to
/// a new target.  It records hashes/counts, never library contents.
struct V4StoreMigrationJournal: Codable, Hashable, Sendable {
    enum Phase: String, Codable, Sendable { case backupComplete, opening, completed, failed }

    let id: UUID
    let storeName: String
    let targetSchemaVersion: Int
    let startedAt: Date
    var completedAt: Date?
    var phase: Phase
    let backupManifest: V4StoreBackupManifest
    let preRowCount: Int?
    var postRowCount: Int?
    var errorCategory: String?
}

/// A prepared migration can be completed or marked failed exactly once.  It
/// owns only the JSON journal beneath the explicit store parent; restoring is
/// always performed separately into a fresh user-selected target.
final class V4StoreBootstrapHandle: @unchecked Sendable {
    private let journalURL: URL
    private var journal: V4StoreMigrationJournal
    private let fileManager: FileManager
    private var terminal = false

    fileprivate init(journalURL: URL, journal: V4StoreMigrationJournal, fileManager: FileManager) {
        self.journalURL = journalURL; self.journal = journal; self.fileManager = fileManager
    }

    func complete(postRowCount: Int?) throws {
        guard !terminal else { throw V4LocalError.invalidTransition }
        terminal = true
        journal.phase = .completed; journal.completedAt = Date(); journal.postRowCount = postRowCount
        try write()
    }

    func fail(_ error: Error) throws {
        guard !terminal else { return }
        terminal = true
        journal.phase = .failed; journal.completedAt = Date(); journal.errorCategory = String(describing: type(of: error))
        try write()
    }

    private func write() throws {
        let data = try JSONEncoder.latticeLens.encode(journal)
        try data.write(to: journalURL, options: .atomic)
    }
}

enum V4StoreBootstrapCoordinator {
    /// Called before a ModelContainer opens an existing store.  New empty
    /// stores have no migration risk and therefore produce no spurious backup.
    static func prepare(storeURL: URL, targetSchemaVersion: Int, fileManager: FileManager = .default) throws -> V4StoreBootstrapHandle {
        let parent = storeURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: storeURL.path) else {
            let empty = V4StoreBackupManifest(id: UUID(), schemaVersion: targetSchemaVersion, createdAt: Date(), sourcePathCategory: "new_empty_store", files: [], manifestHash: StableHash.sha256(Data()))
            let journal = V4StoreMigrationJournal(id: UUID(), storeName: storeURL.lastPathComponent, targetSchemaVersion: targetSchemaVersion,
                                                   startedAt: Date(), completedAt: nil, phase: .opening, backupManifest: empty,
                                                   preRowCount: 0, postRowCount: nil, errorCategory: nil)
            let url = journalURL(for: storeURL, id: journal.id)
            try JSONEncoder.latticeLens.encode(journal).write(to: url, options: .atomic)
            return V4StoreBootstrapHandle(journalURL: url, journal: journal, fileManager: fileManager)
        }
        let backupRoot = parent.appendingPathComponent("LatticeLens-StoreBackups", isDirectory: true)
        let manifest = try V4StoreBackupCoordinator.createBackup(source: storeURL, destinationRoot: backupRoot,
                                                                   schemaVersion: targetSchemaVersion, fileManager: fileManager)
        let journal = V4StoreMigrationJournal(id: UUID(), storeName: storeURL.lastPathComponent, targetSchemaVersion: targetSchemaVersion,
                                               startedAt: Date(), completedAt: nil, phase: .backupComplete, backupManifest: manifest,
                                               preRowCount: nil, postRowCount: nil, errorCategory: nil)
        let url = journalURL(for: storeURL, id: journal.id)
        try JSONEncoder.latticeLens.encode(journal).write(to: url, options: .atomic)
        var opening = journal; opening.phase = .opening
        try JSONEncoder.latticeLens.encode(opening).write(to: url, options: .atomic)
        return V4StoreBootstrapHandle(journalURL: url, journal: opening, fileManager: fileManager)
    }

    static func journalURL(for storeURL: URL, id: UUID) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent(".latticelens-migration-\(storeURL.lastPathComponent)-\(id.uuidString).json")
    }
}
