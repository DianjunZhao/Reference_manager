import Foundation
import SwiftData
import Darwin
import SQLite3

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
    // 1.0.11's V9 store already persists these four summary columns. Keep their
    // exact legacy shape; only the later-added inventory hash must stay out of
    // the V9 entity. The full source-bound inventory is canonical in V10 rows.
    var numberedEquationIndexVersion: Int?
    var numberedEquationCount: Int?
    var numberedEquationIndexComplete: Bool?
    var numberedEquationIndexFailure: String?
    @Transient var numberedEquationInventoryHash: String? = nil
    init(_ value: FullTextDocument) { documentID = value.id; paperID = value.paperID; sourceURL = value.sourceURL.absoluteString; sourceKind = value.sourceKind.rawValue; sha256 = value.sha256; byteCount = value.byteCount; localFilename = value.localFilename; pageCount = value.pageCount; extractionState = value.extractionState.rawValue; downloadedAt = value.downloadedAt; lastErrorCategory = value.lastErrorCategory; numberedEquationIndexVersion = value.numberedEquationIndexVersion; numberedEquationCount = value.numberedEquationCount; numberedEquationIndexComplete = value.numberedEquationIndexComplete; numberedEquationIndexFailure = value.numberedEquationIndexFailure; numberedEquationInventoryHash = value.numberedEquationInventoryHash }
    func decoded() throws -> FullTextDocument { guard let url = URL(string: sourceURL), let kind = FullTextSourceKind(rawValue: sourceKind), let state = FullTextExtractionState(rawValue: extractionState) else { throw LatticeLensError.persistenceUnavailable("V8 full-text document 无法解码") }; return FullTextDocument(paperID: paperID, sourceURL: url, sourceKind: kind, sha256: sha256, byteCount: byteCount, localFilename: localFilename, pageCount: pageCount, extractionState: state, downloadedAt: downloadedAt, lastErrorCategory: lastErrorCategory, numberedEquationIndexVersion: numberedEquationIndexVersion, numberedEquationCount: numberedEquationCount, numberedEquationIndexComplete: numberedEquationIndexComplete, numberedEquationIndexFailure: numberedEquationIndexFailure, numberedEquationInventoryHash: numberedEquationInventoryHash) }
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
    var equationID: String?; var equationLabel: String?; var equationTeX: String?; var equationOrdinal: Int?
    init(_ value: EvidenceChunk) { id = value.id; paperID = value.paperID; documentHash = value.documentHash; page = value.page; section = value.section; rangeStart = value.characterRangeStart; rangeEnd = value.characterRangeEnd; text = value.text; textHash = value.textHash; equationID = value.equationID; equationLabel = value.equationLabel; equationTeX = value.equationTeX; equationOrdinal = value.equationOrdinal }
    func decoded() -> EvidenceChunk { EvidenceChunk(id: id, paperID: paperID, documentHash: documentHash, page: page, section: section, characterRangeStart: rangeStart, characterRangeEnd: rangeEnd, text: text, textHash: textHash, equationID: equationID, equationLabel: equationLabel, equationTeX: equationTeX, equationOrdinal: equationOrdinal) }
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

// V10 keeps the V8 domain rows and V9 rebuildable search index intact, while
// adding separately queryable rows for category profiles, formula provenance,
// analysis attempts and durable reading/index state. Payload columns preserve
// the complete Codable contract; identity and lifecycle columns remain typed
// for bounded queries and crash recovery.
@Model final class StoredV10AuthorCategoryMembership {
    @Attribute(.unique) var id: String
    var authorID: Int
    var category: String
    var generationID: String
    var isCurrent: Bool
    var updatedAt: Date
    init(id: String, authorID: Int, category: String, generationID: String, isCurrent: Bool, updatedAt: Date = Date()) {
        self.id = id; self.authorID = authorID; self.category = category; self.generationID = generationID; self.isCurrent = isCurrent; self.updatedAt = updatedAt
    }
}

@Model final class StoredV10CategoryProfile {
    @Attribute(.unique) var id: String
    var revision: Int
    var categoriesData: Data
    var updatedAt: Date
    init(id: String = "active", revision: Int, categoriesData: Data, updatedAt: Date = Date()) {
        self.id = id; self.revision = revision; self.categoriesData = categoriesData; self.updatedAt = updatedAt
    }
}

@Model final class StoredV10FormulaInventory {
    @Attribute(.unique) var id: String
    var paperID: Int
    var documentID: String
    var documentHash: String
    var inventoryHash: String
    var parserVersion: Int
    var status: String
    var payload: Data
    var updatedAt: Date
    init(id: String, paperID: Int, documentID: String, documentHash: String, inventoryHash: String, parserVersion: Int, status: String, payload: Data, updatedAt: Date = Date()) {
        self.id = id; self.paperID = paperID; self.documentID = documentID; self.documentHash = documentHash; self.inventoryHash = inventoryHash; self.parserVersion = parserVersion; self.status = status; self.payload = payload; self.updatedAt = updatedAt
    }
}

@Model final class StoredV10FormulaInventoryItem {
    @Attribute(.unique) var id: String
    var paperID: Int
    var documentID: String
    var documentHash: String
    var inventoryHash: String
    var equationID: String
    var label: String
    var ordinal: Int
    var sourceByteStart: Int
    var sourceByteEnd: Int
    var sourceTeXHash: String
    var anchorID: String?
    var status: String
    var payload: Data
    init(id: String, paperID: Int, documentID: String, documentHash: String, inventoryHash: String, equationID: String, label: String, ordinal: Int, sourceByteStart: Int, sourceByteEnd: Int, sourceTeXHash: String, anchorID: String?, status: String, payload: Data) {
        self.id = id; self.paperID = paperID; self.documentID = documentID; self.documentHash = documentHash; self.inventoryHash = inventoryHash; self.equationID = equationID; self.label = label; self.ordinal = ordinal; self.sourceByteStart = sourceByteStart; self.sourceByteEnd = sourceByteEnd; self.sourceTeXHash = sourceTeXHash; self.anchorID = anchorID; self.status = status; self.payload = payload
    }
}

@Model final class StoredV10FormulaDerivationJob {
    @Attribute(.unique) var id: String
    var paperID: Int
    var documentID: String
    var documentHash: String
    var inventoryHash: String
    var state: String
    var promptVersion: String
    var schemaVersion: String
    var createdAt: Date
    var updatedAt: Date
    var payload: Data
    init(id: String, paperID: Int, documentID: String, documentHash: String, inventoryHash: String, state: String, promptVersion: String, schemaVersion: String, createdAt: Date, updatedAt: Date, payload: Data) {
        self.id = id; self.paperID = paperID; self.documentID = documentID; self.documentHash = documentHash; self.inventoryHash = inventoryHash; self.state = state; self.promptVersion = promptVersion; self.schemaVersion = schemaVersion; self.createdAt = createdAt; self.updatedAt = updatedAt; self.payload = payload
    }
}

@Model final class StoredV10FormulaBatch {
    @Attribute(.unique) var id: String
    var jobID: String
    var ordinal: Int
    var equationIDsData: Data
    var payloadHash: String
    var status: String
    var updatedAt: Date
    init(id: String, jobID: String, ordinal: Int, equationIDsData: Data, payloadHash: String, status: String, updatedAt: Date = Date()) {
        self.id = id; self.jobID = jobID; self.ordinal = ordinal; self.equationIDsData = equationIDsData; self.payloadHash = payloadHash; self.status = status; self.updatedAt = updatedAt
    }
}

@Model final class StoredV10FormulaBatchCheckpoint {
    @Attribute(.unique) var id: String
    var jobID: String
    var inventoryHash: String
    var batchIndex: Int
    var batchTotal: Int
    var equationIDsData: Data
    var requestID: String?
    var attemptCount: Int
    var payloadHash: String
    var receivedBytes: Int
    var receivedCharacters: Int
    var firstContentAt: Date?
    var lastContentAt: Date?
    var status: String
    var errorCategory: String?
    var updatedAt: Date
    init(id: String, jobID: String, inventoryHash: String, batchIndex: Int, batchTotal: Int, equationIDsData: Data, requestID: String?, attemptCount: Int, payloadHash: String, receivedBytes: Int, receivedCharacters: Int, firstContentAt: Date?, lastContentAt: Date?, status: String, errorCategory: String?, updatedAt: Date) {
        self.id = id; self.jobID = jobID; self.inventoryHash = inventoryHash; self.batchIndex = batchIndex; self.batchTotal = batchTotal; self.equationIDsData = equationIDsData; self.requestID = requestID; self.attemptCount = attemptCount; self.payloadHash = payloadHash; self.receivedBytes = receivedBytes; self.receivedCharacters = receivedCharacters; self.firstContentAt = firstContentAt; self.lastContentAt = lastContentAt; self.status = status; self.errorCategory = errorCategory; self.updatedAt = updatedAt
    }
}

@Model final class StoredV10FormulaDerivationStep {
    @Attribute(.unique) var id: String
    var jobID: String
    var equationID: String
    var ordinal: Int
    var text: String
    var anchorID: String?
    var status: String
    init(id: String, jobID: String, equationID: String, ordinal: Int, text: String, anchorID: String?, status: String) {
        self.id = id; self.jobID = jobID; self.equationID = equationID; self.ordinal = ordinal; self.text = text; self.anchorID = anchorID; self.status = status
    }
}

@Model final class StoredV10EquationDependency {
    @Attribute(.unique) var id: String
    var jobID: String
    var equationID: String
    var dependsOnEquationID: String
    var status: String
    init(id: String, jobID: String, equationID: String, dependsOnEquationID: String, status: String) {
        self.id = id; self.jobID = jobID; self.equationID = equationID; self.dependsOnEquationID = dependsOnEquationID; self.status = status
    }
}

@Model final class StoredV10FormulaValidationReport {
    @Attribute(.unique) var id: String
    var jobID: String
    var inventoryHash: String
    var claimHash: String
    var validatorVersion: String
    var status: String
    var payload: Data
    var createdAt: Date
    init(id: String, jobID: String, inventoryHash: String, claimHash: String, validatorVersion: String, status: String, payload: Data, createdAt: Date = Date()) {
        self.id = id; self.jobID = jobID; self.inventoryHash = inventoryHash; self.claimHash = claimHash; self.validatorVersion = validatorVersion; self.status = status; self.payload = payload; self.createdAt = createdAt
    }
}

@Model final class StoredV10AnalysisRun {
    @Attribute(.unique) var id: String
    var workflowKind: String
    var phase: String
    var providerRevision: String
    var modelID: String
    var promptVersion: String
    var schemaVersion: String
    var payloadHash: String
    var sourceDocumentHashesData: Data
    var inventoryHash: String?
    var updatedAt: Date
    var payload: Data
    init(id: String, workflowKind: String, phase: String, providerRevision: String, modelID: String, promptVersion: String, schemaVersion: String, payloadHash: String, sourceDocumentHashesData: Data, inventoryHash: String?, updatedAt: Date = Date(), payload: Data) {
        self.id = id; self.workflowKind = workflowKind; self.phase = phase; self.providerRevision = providerRevision; self.modelID = modelID; self.promptVersion = promptVersion; self.schemaVersion = schemaVersion; self.payloadHash = payloadHash; self.sourceDocumentHashesData = sourceDocumentHashesData; self.inventoryHash = inventoryHash; self.updatedAt = updatedAt; self.payload = payload
    }
}

@Model final class StoredV10AnalysisAttempt {
    @Attribute(.unique) var id: String
    var runID: String
    var requestIndex: Int
    var batchIndex: Int?
    var requestID: String
    var attempt: Int
    var status: String
    var receivedBytes: Int
    var receivedCharacters: Int
    var errorCategory: String?
    var updatedAt: Date
    init(id: String, runID: String, requestIndex: Int, batchIndex: Int?, requestID: String, attempt: Int, status: String, receivedBytes: Int, receivedCharacters: Int, errorCategory: String?, updatedAt: Date = Date()) {
        self.id = id; self.runID = runID; self.requestIndex = requestIndex; self.batchIndex = batchIndex; self.requestID = requestID; self.attempt = attempt; self.status = status; self.receivedBytes = receivedBytes; self.receivedCharacters = receivedCharacters; self.errorCategory = errorCategory; self.updatedAt = updatedAt
    }
}

@Model final class StoredV10ReadingWorkflowState {
    @Attribute(.unique) var paperID: Int
    var state: String
    var selectedAnchorID: String?
    var updatedAt: Date
    init(paperID: Int, state: String, selectedAnchorID: String?, updatedAt: Date = Date()) { self.paperID = paperID; self.state = state; self.selectedAnchorID = selectedAnchorID; self.updatedAt = updatedAt }
}

@Model final class StoredV10SearchIndexState {
    @Attribute(.unique) var indexName: String
    var version: Int
    var state: String
    var indexedRecordCount: Int
    var updatedAt: Date
    init(indexName: String, version: Int, state: String, indexedRecordCount: Int, updatedAt: Date = Date()) {
        self.indexName = indexName; self.version = version; self.state = state; self.indexedRecordCount = indexedRecordCount; self.updatedAt = updatedAt
    }
}

// V11 keeps V10 immutable and moves formula-job reads/writes onto normalized
// rows. The V10 checkpoint blob remains only as a migration/Bundle projection.
@Model final class StoredV11FormulaDerivationJob {
    @Attribute(.unique) var id: String
    var paperID: Int
    var documentHash: String
    var inventoryHash: String
    var equationIDsData: Data
    var batchSize: Int
    var state: String
    var promptVersion: String
    var schemaVersion: String
    var contextFingerprint: String?
    var startedAt: Date
    var updatedAt: Date
    init(id: String, paperID: Int, documentHash: String, inventoryHash: String,
         equationIDsData: Data, batchSize: Int, state: String, promptVersion: String,
         schemaVersion: String, contextFingerprint: String?, startedAt: Date, updatedAt: Date) {
        self.id = id; self.paperID = paperID; self.documentHash = documentHash
        self.inventoryHash = inventoryHash; self.equationIDsData = equationIDsData
        self.batchSize = batchSize; self.state = state; self.promptVersion = promptVersion
        self.schemaVersion = schemaVersion; self.contextFingerprint = contextFingerprint
        self.startedAt = startedAt; self.updatedAt = updatedAt
    }
}

@Model final class StoredV11FormulaClaim {
    @Attribute(.unique) var id: String
    var jobID: String
    var batchIndex: Int
    var equationID: String
    var claimUUID: String
    var textZH: String
    var epistemicStatus: String
    var evidenceIDsData: Data
    var formulaTeX: String?
    var derivationStepsData: Data
    var conclusionZH: String?
    var claimHash: String
    init(id: String, jobID: String, batchIndex: Int, equationID: String, claimUUID: String,
         textZH: String, epistemicStatus: String, evidenceIDsData: Data, formulaTeX: String?,
         derivationStepsData: Data, conclusionZH: String?, claimHash: String) {
        self.id = id; self.jobID = jobID; self.batchIndex = batchIndex; self.equationID = equationID
        self.claimUUID = claimUUID; self.textZH = textZH; self.epistemicStatus = epistemicStatus
        self.evidenceIDsData = evidenceIDsData; self.formulaTeX = formulaTeX
        self.derivationStepsData = derivationStepsData; self.conclusionZH = conclusionZH
        self.claimHash = claimHash
    }
}

@Model final class StoredV11FormulaDerivationStep {
    @Attribute(.unique) var id: String
    var jobID: String
    var batchIndex: Int
    var equationID: String
    var stepID: String
    var ordinal: Int
    var textZH: String
    var beforeTeX: String?
    var afterTeX: String?
    var ruleOrAssumption: String
    var referencedEquationIDsData: Data
    var evidenceAnchorIDsData: Data
    var sourceDocumentHashesData: Data
    var epistemicStatus: String
    init(id: String, jobID: String, batchIndex: Int, equationID: String, stepID: String,
         ordinal: Int, textZH: String, beforeTeX: String?, afterTeX: String?,
         ruleOrAssumption: String, referencedEquationIDsData: Data, evidenceAnchorIDsData: Data,
         sourceDocumentHashesData: Data, epistemicStatus: String) {
        self.id = id; self.jobID = jobID; self.batchIndex = batchIndex; self.equationID = equationID
        self.stepID = stepID; self.ordinal = ordinal; self.textZH = textZH
        self.beforeTeX = beforeTeX; self.afterTeX = afterTeX; self.ruleOrAssumption = ruleOrAssumption
        self.referencedEquationIDsData = referencedEquationIDsData
        self.evidenceAnchorIDsData = evidenceAnchorIDsData
        self.sourceDocumentHashesData = sourceDocumentHashesData
        self.epistemicStatus = epistemicStatus
    }
}

enum LatticeLensSchemaV11: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(11, 0, 0) }
    static var models: [any PersistentModel.Type] {
        LatticeLensSchemaV10.models + [StoredV11FormulaDerivationJob.self,
            StoredV11FormulaClaim.self, StoredV11FormulaDerivationStep.self]
    }
}

/// V12 makes each validated long-derivation segment independently durable.
/// V11's completed-claim rows remain as the compatibility projection; these
/// rows are the canonical source for segment resume and provenance.
@Model final class StoredV12FormulaDerivationSegment {
    @Attribute(.unique) var id: String
    var jobID: String
    var paperID: Int
    var documentHash: String
    var inventoryHash: String
    var equationID: String
    var sourceTeX: String
    var sourceTeXHash: String
    var segmentIndex: Int
    var firstOrdinal: Int
    var stepCount: Int
    var isFinal: Bool
    var continuationSummary: String?
    var conclusionZH: String?
    var requestID: String
    var requestPayloadHash: String
    var responseHash: String
    var receivedBytes: Int
    var receivedCharacters: Int
    var firstContentAt: Date?
    var lastContentAt: Date?
    var stepsHash: String
    var receiptHash: String
    var chainHash: String

    init(id: String, jobID: String, paperID: Int, documentHash: String, inventoryHash: String,
         equationID: String, sourceTeX: String, sourceTeXHash: String, segmentIndex: Int,
         firstOrdinal: Int, stepCount: Int, isFinal: Bool, continuationSummary: String?,
         conclusionZH: String?, requestID: String, requestPayloadHash: String, responseHash: String,
         receivedBytes: Int, receivedCharacters: Int, firstContentAt: Date?, lastContentAt: Date?,
         stepsHash: String, receiptHash: String, chainHash: String) {
        self.id = id; self.jobID = jobID; self.paperID = paperID
        self.documentHash = documentHash; self.inventoryHash = inventoryHash
        self.equationID = equationID; self.sourceTeX = sourceTeX; self.sourceTeXHash = sourceTeXHash
        self.segmentIndex = segmentIndex; self.firstOrdinal = firstOrdinal; self.stepCount = stepCount
        self.isFinal = isFinal; self.continuationSummary = continuationSummary
        self.conclusionZH = conclusionZH; self.requestID = requestID
        self.requestPayloadHash = requestPayloadHash; self.responseHash = responseHash
        self.receivedBytes = receivedBytes; self.receivedCharacters = receivedCharacters
        self.firstContentAt = firstContentAt; self.lastContentAt = lastContentAt
        self.stepsHash = stepsHash; self.receiptHash = receiptHash; self.chainHash = chainHash
    }
}

@Model final class StoredV12FormulaDerivationSegmentStep {
    @Attribute(.unique) var id: String
    var jobID: String
    var equationID: String
    var segmentIndex: Int
    var stepID: String
    var ordinal: Int
    var textZH: String
    var beforeTeX: String?
    var afterTeX: String?
    var ruleOrAssumption: String
    var referencedEquationIDsData: Data
    var evidenceAnchorIDsData: Data
    var sourceDocumentHashesData: Data
    var epistemicStatus: String

    init(id: String, jobID: String, equationID: String, segmentIndex: Int, stepID: String,
         ordinal: Int, textZH: String, beforeTeX: String?, afterTeX: String?,
         ruleOrAssumption: String, referencedEquationIDsData: Data,
         evidenceAnchorIDsData: Data, sourceDocumentHashesData: Data, epistemicStatus: String) {
        self.id = id; self.jobID = jobID; self.equationID = equationID
        self.segmentIndex = segmentIndex; self.stepID = stepID; self.ordinal = ordinal
        self.textZH = textZH; self.beforeTeX = beforeTeX; self.afterTeX = afterTeX
        self.ruleOrAssumption = ruleOrAssumption
        self.referencedEquationIDsData = referencedEquationIDsData
        self.evidenceAnchorIDsData = evidenceAnchorIDsData
        self.sourceDocumentHashesData = sourceDocumentHashesData
        self.epistemicStatus = epistemicStatus
    }
}

enum LatticeLensSchemaV12: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(12, 0, 0) }
    static var models: [any PersistentModel.Type] {
        LatticeLensSchemaV11.models + [StoredV12FormulaDerivationSegment.self,
            StoredV12FormulaDerivationSegmentStep.self]
    }
}

enum LatticeLensSchemaV10: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(10, 0, 0) }
    static var models: [any PersistentModel.Type] {
        LatticeLensSchemaV9.models + [StoredV10AuthorCategoryMembership.self, StoredV10CategoryProfile.self,
            StoredV10FormulaInventory.self, StoredV10FormulaInventoryItem.self, StoredV10FormulaDerivationJob.self,
            StoredV10FormulaBatch.self, StoredV10FormulaBatchCheckpoint.self, StoredV10FormulaDerivationStep.self,
            StoredV10EquationDependency.self, StoredV10FormulaValidationReport.self, StoredV10AnalysisRun.self,
            StoredV10AnalysisAttempt.self, StoredV10ReadingWorkflowState.self, StoredV10SearchIndexState.self]
    }
}

enum V10CategoryProfileBootstrap {
    static func migrateOrCreate(in context: ModelContext) throws {
        let profiles = try context.fetch(FetchDescriptor<StoredV10CategoryProfile>())
        guard profiles.count <= 1 else { throw V10StoreMigrationError.semanticMismatch }
        let checkpoints = try context.fetch(FetchDescriptor<StoredV8SyncCheckpoint>())
        let legacyCheckpoints = checkpoints.filter { row in
            guard let checkpoint = try? row.decoded() else { return false }
            return checkpoint.jobKind == "author-candidates" && ArxivCategoryQueryBuilder.isLegacyQuery(checkpoint.query)
        }
        var changed = false
        if profiles.isEmpty {
            let profile = legacyCheckpoints.isEmpty
                ? CategoryProfile()
                : CategoryProfile.migratingLegacy(categories: Set(SupportedArxivCategory.legacyV1.map(\.rawValue)))
            context.insert(StoredV10CategoryProfile(revision: profile.revision,
                                                    categoriesData: try JSONEncoder.latticeLens.encode(profile.rawValues)))
            changed = true
        }
        if !legacyCheckpoints.isEmpty {
            let stateID = "legacy-author-category-checkpoints"
            let descriptor = FetchDescriptor<StoredV10SearchIndexState>(predicate: #Predicate { $0.indexName == stateID })
            if try context.fetch(descriptor).isEmpty {
                context.insert(StoredV10SearchIndexState(indexName: stateID, version: ArxivCategoryQueryBuilder.revision,
                    state: "invalidated_by_query_revision", indexedRecordCount: legacyCheckpoints.count))
                changed = true
            }
        }
        if changed { try context.save() }
    }
}

@ModelActor
actor V10CategoryProfileStore: CategoryProfileStoring {
    func loadCategoryProfile() throws -> CategoryProfile? {
        let descriptor = FetchDescriptor<StoredV10CategoryProfile>(predicate: #Predicate { $0.id == "active" })
        guard let row = try modelContext.fetch(descriptor).first else { return nil }
        let values = try JSONDecoder.latticeLens.decode([String].self, from: row.categoriesData)
        let categories = Set(values.compactMap(SupportedArxivCategory.init(rawValue:)))
        guard categories.count == Set(values).count else {
            throw LatticeLensError.persistenceUnavailable("V10 分类 profile 含未支持分类；保留现有选择，未自动创建默认 profile")
        }
        return CategoryProfile(categories: categories, revision: row.revision)
    }

    func saveCategoryProfile(_ profile: CategoryProfile) throws {
        do {
            let data = try JSONEncoder.latticeLens.encode(profile.rawValues)
            let descriptor = FetchDescriptor<StoredV10CategoryProfile>(predicate: #Predicate { $0.id == "active" })
            if let row = try modelContext.fetch(descriptor).first {
                row.revision = profile.revision; row.categoriesData = data; row.updatedAt = Date()
            } else {
                modelContext.insert(StoredV10CategoryProfile(revision: profile.revision, categoriesData: data))
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}

enum LatticeLensMigrationPlanV10: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LatticeLensSchemaV8.self, LatticeLensSchemaV9.self, LatticeLensSchemaV10.self] }
    static var stages: [MigrationStage] {
        LatticeLensMigrationPlanV9.stages + [.lightweight(fromVersion: LatticeLensSchemaV9.self, toVersion: LatticeLensSchemaV10.self)]
    }
}

enum LatticeLensMigrationPlanV11: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        LatticeLensMigrationPlanV10.schemas + [LatticeLensSchemaV11.self]
    }
    static var stages: [MigrationStage] {
        LatticeLensMigrationPlanV10.stages + [
            .lightweight(fromVersion: LatticeLensSchemaV10.self, toVersion: LatticeLensSchemaV11.self)
        ]
    }
}

enum LatticeLensMigrationPlanV12: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        LatticeLensMigrationPlanV11.schemas + [LatticeLensSchemaV12.self]
    }
    static var stages: [MigrationStage] {
        LatticeLensMigrationPlanV11.stages + [
            .lightweight(fromVersion: LatticeLensSchemaV11.self, toVersion: LatticeLensSchemaV12.self)
        ]
    }
}

enum V10FormulaJobStoreError: Error, LocalizedError, Equatable {
    case inconsistent(String)

    var errorDescription: String? {
        switch self {
        case .inconsistent(let reason): "公式作業 typed store 無法安全讀寫：\(reason)"
        }
    }
}

@ModelActor
actor V10FormulaJobStore: EvidenceInsightPublicationStoring {
    nonisolated private static func claimRowID(jobID: String, batchIndex: Int, equationID: String) -> String {
        "\(jobID):claim:\(batchIndex):\(StableHash.sha256(equationID))"
    }

    nonisolated private static func segmentRowID(jobID: String, equationID: String, segmentIndex: Int) -> String {
        "\(jobID):segment:\(StableHash.sha256(equationID)):\(segmentIndex)"
    }

    nonisolated private static func segmentStepRowID(jobID: String, equationID: String,
                                                      segmentIndex: Int, stepID: String) -> String {
        "\(jobID):segment-step:\(StableHash.sha256(equationID)):\(segmentIndex):\(StableHash.sha256(stepID))"
    }

    nonisolated private static func structuredStepRowID(jobID: String, stepID: String) -> String {
        "\(jobID):structured-step:\(StableHash.sha256(stepID))"
    }

    nonisolated private static func restoreSegmentStates(
        jobID: String,
        paperID: Int,
        documentHash: String,
        inventoryHash: String,
        equationIDs: [String],
        segmentRows: [StoredV12FormulaDerivationSegment],
        stepRows: [StoredV12FormulaDerivationSegmentStep]
    ) throws -> [String: FormulaDerivationSegmentCheckpoint] {
        guard segmentRows.allSatisfy({ $0.jobID == jobID }),
              stepRows.allSatisfy({ $0.jobID == jobID }) else {
            throw V10FormulaJobStoreError.inconsistent("V12 formula segment rows reference another job")
        }
        _ = try Self.uniqueRows(segmentRows, family: "V12 formula segment") { $0.id }
        let stepsByID = try Self.uniqueRows(stepRows, family: "V12 formula segment step") { $0.id }
        guard Set(stepRows.map { "\($0.equationID)|\($0.segmentIndex)|\($0.stepID)" }).count == stepRows.count else {
            throw V10FormulaJobStoreError.inconsistent("V12 formula segment step logical identity 重複")
        }
        if segmentRows.isEmpty {
            guard stepRows.isEmpty else {
                throw V10FormulaJobStoreError.inconsistent("V12 formula segment step has no segment parent")
            }
            return [:]
        }

        var checkpoints = [String: FormulaDerivationSegmentCheckpoint]()
        var expectedStepIDs = Set<String>()
        let orderedSegments = segmentRows.sorted {
            $0.equationID == $1.equationID
                ? $0.segmentIndex < $1.segmentIndex
                : $0.equationID < $1.equationID
        }
        for row in orderedSegments {
            guard equationIDs.contains(row.equationID), row.paperID == paperID,
                  row.documentHash == documentHash, row.inventoryHash == inventoryHash,
                  row.id == Self.segmentRowID(jobID: jobID, equationID: row.equationID,
                                              segmentIndex: row.segmentIndex),
                  row.sourceTeXHash == StableHash.sha256(row.sourceTeX),
                  row.firstOrdinal > 0,
                  (1...FormulaDerivationStep.maximumStepsPerSegment).contains(row.stepCount),
                  row.requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw V10FormulaJobStoreError.inconsistent("V12 formula segment identity/scope/source metadata mismatch")
            }
            let steps = stepRows.filter {
                $0.equationID == row.equationID && $0.segmentIndex == row.segmentIndex
            }.sorted { $0.ordinal < $1.ordinal }
            guard steps.count == row.stepCount,
                  steps.map(\.ordinal) == Array(row.firstOrdinal..<(row.firstOrdinal + row.stepCount)) else {
                throw V10FormulaJobStoreError.inconsistent("V12 formula segment typed steps are missing or non-contiguous")
            }
            var typedSteps = [FormulaDerivationStep]()
            for stored in steps {
                let expectedID = Self.segmentStepRowID(jobID: jobID, equationID: row.equationID,
                    segmentIndex: row.segmentIndex, stepID: stored.stepID)
                guard stored.id == expectedID, stored.jobID == jobID,
                      stored.segmentIndex == row.segmentIndex,
                      stored.stepID == "\(row.equationID):step:\(stored.ordinal)",
                      let status = EpistemicStatus(rawValue: stored.epistemicStatus) else {
                    throw V10FormulaJobStoreError.inconsistent("V12 formula segment step identity/status mismatch")
                }
                expectedStepIDs.insert(stored.id)
                typedSteps.append(FormulaDerivationStep(stepID: stored.stepID, ordinal: stored.ordinal,
                    textZH: stored.textZH, beforeTeX: stored.beforeTeX, afterTeX: stored.afterTeX,
                    ruleOrAssumption: stored.ruleOrAssumption,
                    referencedEquationIDs: try JSONDecoder.latticeLens.decode([String].self, from: stored.referencedEquationIDsData),
                    evidenceAnchorIDs: try JSONDecoder.latticeLens.decode([String].self, from: stored.evidenceAnchorIDsData),
                    sourceDocumentHashes: try JSONDecoder.latticeLens.decode([String].self, from: stored.sourceDocumentHashesData),
                    epistemicStatus: status))
            }
            let stepEncoder = JSONEncoder.latticeLens
            stepEncoder.outputFormatting.insert(.sortedKeys)
            guard row.stepsHash == StableHash.sha256(try stepEncoder.encode(typedSteps)) else {
                throw V10FormulaJobStoreError.inconsistent("V12 formula segment step payload hash mismatch")
            }
            let receipt = FormulaDerivationSegmentReceipt(index: row.segmentIndex, steps: typedSteps,
                isFinal: row.isFinal, continuationSummary: row.continuationSummary,
                conclusionZH: row.conclusionZH, requestID: row.requestID,
                requestPayloadHash: row.requestPayloadHash, responseHash: row.responseHash,
                receivedBytes: row.receivedBytes, receivedCharacters: row.receivedCharacters,
                firstContentAt: row.firstContentAt, lastContentAt: row.lastContentAt)
            guard row.receiptHash == (try FormulaDerivationSegmentCheckpoint.provenanceHash(for: receipt)) else {
                throw V10FormulaJobStoreError.inconsistent("V12 formula segment receipt hash mismatch")
            }
            var checkpoint = checkpoints[row.equationID]
                ?? FormulaDerivationSegmentCheckpoint(equationID: row.equationID, sourceTeX: row.sourceTeX)
            guard checkpoint.sourceTeX == row.sourceTeX,
                  checkpoint.completedSteps.count + 1 == row.firstOrdinal else {
                throw V10FormulaJobStoreError.inconsistent("V12 formula segment TeX/ordinal chain mismatch")
            }
            try checkpoint.appendSegment(index: row.segmentIndex, steps: typedSteps,
                isFinal: row.isFinal, continuationSummary: row.continuationSummary,
                conclusionZH: row.conclusionZH, requestID: row.requestID,
                requestPayloadHash: row.requestPayloadHash, responseHash: row.responseHash,
                receivedBytes: row.receivedBytes, receivedCharacters: row.receivedCharacters,
                firstContentAt: row.firstContentAt, lastContentAt: row.lastContentAt)
            guard row.chainHash == (try checkpoint.provenanceHash()) else {
                throw V10FormulaJobStoreError.inconsistent("V12 formula segment chain hash mismatch")
            }
            checkpoints[row.equationID] = checkpoint
        }
        guard Set(stepsByID.keys) == expectedStepIDs,
              checkpoints.values.allSatisfy({ (try? $0.validatedCopy()) == $0 }) else {
            throw V10FormulaJobStoreError.inconsistent("V12 formula segment rows contain orphan steps or invalid checkpoints")
        }
        return checkpoints
    }

    nonisolated static func canonicalCheckpoint(row: StoredV10FormulaDerivationJob,
                                                context: StoredV11FormulaDerivationJob,
                                                segmentRows: [StoredV12FormulaDerivationSegment] = [],
                                                segmentStepRows: [StoredV12FormulaDerivationSegmentStep] = [],
                                                modelContext: ModelContext) throws -> FormulaDerivationCheckpoint {
        let jobID = row.id
        guard context.id == row.id, context.paperID == row.paperID,
              context.documentHash == row.documentHash, context.inventoryHash == row.inventoryHash,
              context.state == row.state, context.promptVersion == row.promptVersion,
              context.schemaVersion == row.schemaVersion, context.startedAt == row.createdAt,
              context.updatedAt == row.updatedAt, context.batchSize > 0,
              let state = FormulaJobState(rawValue: context.state) else {
            throw V10FormulaJobStoreError.inconsistent("V11 formula job typed metadata 與 V10 compatibility row 不一致")
        }
        let equationIDs = try JSONDecoder.latticeLens.decode([String].self, from: context.equationIDsData)
        guard !equationIDs.isEmpty, Set(equationIDs).count == equationIDs.count else {
            throw V10FormulaJobStoreError.inconsistent("V11 formula job equation identity 無效或重複")
        }
        let segmentStates = try Self.restoreSegmentStates(jobID: jobID, paperID: context.paperID,
            documentHash: context.documentHash, inventoryHash: context.inventoryHash,
            equationIDs: equationIDs, segmentRows: segmentRows, stepRows: segmentStepRows)

        let batchRows = try modelContext.fetch(FetchDescriptor<StoredV10FormulaBatchCheckpoint>(predicate: #Predicate { $0.jobID == jobID }))
        let definitionRows = try modelContext.fetch(FetchDescriptor<StoredV10FormulaBatch>(predicate: #Predicate { $0.jobID == jobID }))
        guard batchRows.count == definitionRows.count, !batchRows.isEmpty else {
            throw V10FormulaJobStoreError.inconsistent("V11 formula job batch row family 缺失或不完整")
        }
        let orderedRows = batchRows.sorted { $0.batchIndex < $1.batchIndex }
        guard orderedRows.map(\.batchIndex) == Array(0..<orderedRows.count),
              Set(definitionRows.map(\.id)).count == definitionRows.count else {
            throw V10FormulaJobStoreError.inconsistent("V11 formula job batch indices are not contiguous and unique")
        }
        let definitions = try Self.uniqueRows(definitionRows, family: "formula batch") { $0.id }
        var batches = [FormulaBatchCheckpoint]()
        for batch in orderedRows {
            let expectedID = "\(row.id):batch:\(batch.batchIndex)"
            guard batch.id == expectedID, batch.inventoryHash == row.inventoryHash,
                  batch.batchTotal == orderedRows.count,
                  let definition = definitions[expectedID], definition.jobID == row.id,
                  definition.ordinal == batch.batchIndex, definition.payloadHash == batch.payloadHash,
                  definition.status == batch.status,
                  let status = FormulaBatchStatus(rawValue: batch.status) else {
                throw V10FormulaJobStoreError.inconsistent("V11 formula job batch row identity/status mismatch")
            }
            let batchEquationIDs = try JSONDecoder.latticeLens.decode([String].self, from: batch.equationIDsData)
            let definitionEquationIDs = try JSONDecoder.latticeLens.decode([String].self, from: definition.equationIDsData)
            guard !batchEquationIDs.isEmpty, Set(batchEquationIDs).count == batchEquationIDs.count,
                  batchEquationIDs == definitionEquationIDs else {
                throw V10FormulaJobStoreError.inconsistent("V11 formula job batch equation rows mismatch")
            }
            batches.append(FormulaBatchCheckpoint(jobID: row.id, batchIndex: batch.batchIndex,
                batchTotal: batch.batchTotal, equationIDs: batchEquationIDs, payloadHash: batch.payloadHash,
                requestID: batch.requestID, attemptCount: batch.attemptCount,
                receivedBytes: batch.receivedBytes, receivedCharacters: batch.receivedCharacters,
                firstContentAt: batch.firstContentAt, lastContentAt: batch.lastContentAt,
                status: status, errorCategory: batch.errorCategory, updatedAt: batch.updatedAt))
        }
        guard batches.flatMap(\.equationIDs) == equationIDs else {
            throw V10FormulaJobStoreError.inconsistent("V11 formula job batch partition differs from typed equation order")
        }

        let claimRows = try modelContext.fetch(FetchDescriptor<StoredV11FormulaClaim>(predicate: #Predicate { $0.jobID == jobID }))
        let stepRows = try modelContext.fetch(FetchDescriptor<StoredV11FormulaDerivationStep>(predicate: #Predicate { $0.jobID == jobID }))
        let claimsByID = try Self.uniqueRows(claimRows, family: "V11 formula claim") { $0.id }
        let stepsByID = try Self.uniqueRows(stepRows, family: "V11 structured formula step") { $0.id }
        guard Set(claimRows.map { "\($0.batchIndex)|\($0.equationID)" }).count == claimRows.count,
              Set(stepRows.map(\.stepID)).count == stepRows.count else {
            throw V10FormulaJobStoreError.inconsistent("V11 formula claim/step logical identity 重複")
        }

        var claimsByBatch = [Int: [EvidenceClaim]]()
        var expectedClaimIDs = Set<String>()
        var expectedStepIDs = Set<String>()
        for batch in batches where batch.status == .completed {
            for equationID in batch.equationIDs {
                let claimID = Self.claimRowID(jobID: row.id, batchIndex: batch.batchIndex, equationID: equationID)
                expectedClaimIDs.insert(claimID)
                guard let claimRow = claimsByID[claimID], claimRow.batchIndex == batch.batchIndex,
                      claimRow.equationID == equationID, claimRow.jobID == row.id,
                      let claimUUID = UUID(uuidString: claimRow.claimUUID),
                      let epistemicStatus = EpistemicStatus(rawValue: claimRow.epistemicStatus) else {
                    throw V10FormulaJobStoreError.inconsistent("V11 completed formula claim row missing/invalid")
                }
                let structuredRows = stepRows.filter {
                    $0.batchIndex == batch.batchIndex && $0.equationID == equationID
                }.sorted { $0.ordinal < $1.ordinal }
                guard structuredRows.enumerated().allSatisfy({ $0.element.ordinal == $0.offset + 1 }) else {
                    throw V10FormulaJobStoreError.inconsistent("V11 structured formula step ordinals are not contiguous")
                }
                var structuredSteps = [FormulaDerivationStep]()
                for stored in structuredRows {
                    let expectedStepID = Self.structuredStepRowID(jobID: row.id, stepID: stored.stepID)
                    guard stored.id == expectedStepID, stored.jobID == row.id,
                          stored.stepID == "\(equationID):step:\(stored.ordinal)",
                          let stepStatus = EpistemicStatus(rawValue: stored.epistemicStatus) else {
                        throw V10FormulaJobStoreError.inconsistent("V11 structured formula step identity/status mismatch")
                    }
                    expectedStepIDs.insert(stored.id)
                    structuredSteps.append(FormulaDerivationStep(stepID: stored.stepID, ordinal: stored.ordinal,
                        textZH: stored.textZH, beforeTeX: stored.beforeTeX, afterTeX: stored.afterTeX,
                        ruleOrAssumption: stored.ruleOrAssumption,
                        referencedEquationIDs: try JSONDecoder.latticeLens.decode([String].self, from: stored.referencedEquationIDsData),
                        evidenceAnchorIDs: try JSONDecoder.latticeLens.decode([String].self, from: stored.evidenceAnchorIDsData),
                        sourceDocumentHashes: try JSONDecoder.latticeLens.decode([String].self, from: stored.sourceDocumentHashesData),
                        epistemicStatus: stepStatus))
                }
                let segmentState = segmentStates[equationID]
                let segmentProvenanceHash = try segmentState?.provenanceHash()
                if let segmentState {
                    guard segmentState.isComplete,
                          segmentState.completedSteps == structuredSteps,
                          segmentState.conclusionZH == claimRow.conclusionZH else {
                        throw V10FormulaJobStoreError.inconsistent("V12 completed formula claim differs from its segment chain")
                    }
                }
                let claim = EvidenceClaim(id: claimUUID, textZH: claimRow.textZH,
                    epistemicStatus: epistemicStatus,
                    evidenceIDs: try JSONDecoder.latticeLens.decode([String].self, from: claimRow.evidenceIDsData),
                    formulaTeX: claimRow.formulaTeX, equationID: equationID,
                    derivationSteps: try JSONDecoder.latticeLens.decode([String].self, from: claimRow.derivationStepsData),
                    formulaDerivationSteps: structuredSteps, conclusionZH: claimRow.conclusionZH,
                    derivationSegmentProvenanceHash: segmentProvenanceHash)
                guard try Self.claimHash(claim) == claimRow.claimHash else {
                    throw V10FormulaJobStoreError.inconsistent("V11 formula claim hash mismatch")
                }
                claimsByBatch[batch.batchIndex, default: []].append(claim)
            }
        }
        guard Set(claimsByID.keys) == expectedClaimIDs,
              Set(stepsByID.keys) == expectedStepIDs else {
            throw V10FormulaJobStoreError.inconsistent("V11 formula claim or structured-step rows contain missing/extra data")
        }
        for batch in batches where batch.status == .completed {
            let order = Dictionary(uniqueKeysWithValues: batch.equationIDs.enumerated().map { ($0.element, $0.offset) })
            claimsByBatch[batch.batchIndex] = claimsByBatch[batch.batchIndex]?.sorted {
                order[$0.equationID ?? "", default: Int.max] < order[$1.equationID ?? "", default: Int.max]
            }
        }

        let job = FormulaDerivationJob(jobID: row.id, paperID: context.paperID,
            documentHash: context.documentHash, inventoryHash: context.inventoryHash,
            equationIDs: equationIDs, batchSize: context.batchSize, state: state, batches: batches,
            startedAt: context.startedAt, updatedAt: context.updatedAt)
        return FormulaDerivationCheckpoint(job: job, completedClaimsByBatch: claimsByBatch,
            derivationSegmentsByEquation: segmentStates.isEmpty ? nil : segmentStates,
            promptVersion: context.promptVersion, schemaVersion: context.schemaVersion,
            contextFingerprint: context.contextFingerprint, updatedAt: context.updatedAt)
    }

    private static func claimHash(_ claim: EvidenceClaim) throws -> String {
        let encoder = JSONEncoder.latticeLens
        encoder.outputFormatting.insert(.sortedKeys)
        return StableHash.sha256(try encoder.encode(claim))
    }

    func formulaJob(id: String) throws -> FormulaDerivationCheckpoint? {
        let descriptor = FetchDescriptor<StoredV10FormulaDerivationJob>(predicate: #Predicate { $0.id == id })
        guard let row = try modelContext.fetch(descriptor).first else { return nil }
        let canonicalRows = try modelContext.fetch(FetchDescriptor<StoredV11FormulaDerivationJob>(predicate: #Predicate { $0.id == id }))
        let segmentRows = try modelContext.fetch(FetchDescriptor<StoredV12FormulaDerivationSegment>(predicate: #Predicate { $0.jobID == id }))
        let segmentStepRows = try modelContext.fetch(FetchDescriptor<StoredV12FormulaDerivationSegmentStep>(predicate: #Predicate { $0.jobID == id }))
        guard canonicalRows.count <= 1 else {
            throw V10FormulaJobStoreError.inconsistent("V11 formula job identity 重複")
        }
        let projection: FormulaDerivationCheckpoint
        if let canonical = canonicalRows.first {
            projection = try Self.canonicalCheckpoint(row: row, context: canonical,
                segmentRows: segmentRows, segmentStepRows: segmentStepRows, modelContext: modelContext)
        } else {
            // V10 JSON is consulted only to seed normalized rows for a job
            // written before V11/V12 canonical tables were introduced.
            projection = try JSONDecoder.latticeLens.decode(FormulaDerivationCheckpoint.self, from: row.payload)
        }
        guard projection.job.jobID == row.id,
              projection.job.paperID == row.paperID,
              projection.job.documentHash == row.documentHash,
              projection.job.inventoryHash == row.inventoryHash,
              projection.promptVersion == row.promptVersion,
              projection.schemaVersion == row.schemaVersion,
              // The shared ISO-8601 JSON codec stores whole seconds, whereas
              // SwiftData keeps subsecond precision.
              abs(projection.job.startedAt.timeIntervalSince(row.createdAt)) < 1 else {
            throw V10FormulaJobStoreError.inconsistent("formula job metadata 與相容投影不一致")
        }
        if projection.promptVersion == FormulaDerivationPrompt.version {
            // V12 segment rows are the canonical source. A malformed legacy
            // projection must not make a fully validated typed job unreadable;
            // when the projection remains decodable, still reject any conflict.
            if let compatibility = try? JSONDecoder.latticeLens.decode(FormulaDerivationCheckpoint.self,
                                                                        from: row.payload),
               !Self.sameSegmentProvenance(projection.derivationSegmentsByEquation,
                                           compatibility.derivationSegmentsByEquation) {
                throw V10FormulaJobStoreError.inconsistent("V12 canonical segment rows differ from the compatibility projection")
            }
        }

        var definitions = try modelContext.fetch(FetchDescriptor<StoredV10FormulaBatch>(predicate: #Predicate { $0.jobID == id }))
        let typedCheckpoints = try modelContext.fetch(FetchDescriptor<StoredV10FormulaBatchCheckpoint>(predicate: #Predicate { $0.jobID == id }))
        if definitions.isEmpty, !typedCheckpoints.isEmpty,
           typedCheckpoints.count == projection.job.batches.count {
            // V10 checkpoints written before typed batch-definition rows existed
            // are upgraded once from their validated checkpoint rows. This is a
            // narrow compatibility migration; partial/corrupt row families fail
            // closed below and are never silently reconstructed from JSON alone.
            for typed in typedCheckpoints {
                let batchID = "\(id):batch:\(typed.batchIndex)"
                let equationIDs = try JSONDecoder.latticeLens.decode([String].self, from: typed.equationIDsData)
                guard typed.id == batchID, typed.jobID == id,
                      typed.inventoryHash == row.inventoryHash,
                      let projected = projection.job.batches.first(where: { $0.batchIndex == typed.batchIndex }),
                      projected.id == batchID, projected.equationIDs == equationIDs,
                      projected.payloadHash == typed.payloadHash else {
                    throw V10FormulaJobStoreError.inconsistent("legacy formula batch checkpoint cannot be migrated")
                }
                modelContext.insert(StoredV10FormulaBatch(id: batchID, jobID: id, ordinal: typed.batchIndex,
                    equationIDsData: typed.equationIDsData, payloadHash: typed.payloadHash,
                    status: typed.status, updatedAt: typed.updatedAt))
            }
            do { try modelContext.save() }
            catch { modelContext.rollback(); throw error }
            definitions = try modelContext.fetch(FetchDescriptor<StoredV10FormulaBatch>(predicate: #Predicate { $0.jobID == id }))
        }
        guard definitions.count == projection.job.batches.count,
              typedCheckpoints.count == projection.job.batches.count else {
            throw V10FormulaJobStoreError.inconsistent("formula batch typed rows 缺失或數量不符")
        }
        let definitionRows = try Self.uniqueRows(definitions, family: "formula batch") { $0.id }
        let checkpointRows = try Self.uniqueRows(typedCheckpoints, family: "formula batch checkpoint") { $0.id }
        let orderedCheckpoints = typedCheckpoints.sorted { $0.batchIndex < $1.batchIndex }
        guard orderedCheckpoints.map(\.batchIndex) == Array(0..<orderedCheckpoints.count),
              Set(orderedCheckpoints.map(\.batchIndex)).count == orderedCheckpoints.count,
              Set(projection.job.equationIDs).count == projection.job.equationIDs.count else {
            throw V10FormulaJobStoreError.inconsistent("formula batch index 或 equation identity 重複")
        }

        var reconstructedBatches = [FormulaBatchCheckpoint]()
        reconstructedBatches.reserveCapacity(orderedCheckpoints.count)
        for typed in orderedCheckpoints {
            let batchID = "\(id):batch:\(typed.batchIndex)"
            guard typed.id == batchID,
                  typed.inventoryHash == row.inventoryHash,
                  typed.batchTotal == orderedCheckpoints.count,
                  let definition = definitionRows[batchID],
                  let status = FormulaBatchStatus(rawValue: typed.status),
                  definition.ordinal == typed.batchIndex,
                  definition.id == batchID,
                  definition.jobID == id,
                  definition.status == typed.status,
                  definition.payloadHash == typed.payloadHash else {
                throw V10FormulaJobStoreError.inconsistent("formula batch typed row metadata 不一致")
            }
            let equationIDs = try JSONDecoder.latticeLens.decode([String].self, from: typed.equationIDsData)
            let definitionEquationIDs = try JSONDecoder.latticeLens.decode([String].self, from: definition.equationIDsData)
            guard !equationIDs.isEmpty,
                  Set(equationIDs).count == equationIDs.count,
                  equationIDs == definitionEquationIDs,
                  let projected = projection.job.batches.first(where: { $0.batchIndex == typed.batchIndex }),
                  projected.id == batchID,
                  projected.equationIDs == equationIDs,
                  projected.payloadHash == typed.payloadHash else {
                throw V10FormulaJobStoreError.inconsistent("formula batch equation list 與投影不一致")
            }
            reconstructedBatches.append(FormulaBatchCheckpoint(jobID: id,
                batchIndex: typed.batchIndex, batchTotal: typed.batchTotal, equationIDs: equationIDs,
                payloadHash: typed.payloadHash, requestID: typed.requestID, attemptCount: typed.attemptCount,
                receivedBytes: typed.receivedBytes, receivedCharacters: typed.receivedCharacters,
                firstContentAt: typed.firstContentAt, lastContentAt: typed.lastContentAt,
                status: status, errorCategory: typed.errorCategory, updatedAt: typed.updatedAt))
        }
        guard reconstructedBatches.flatMap(\.equationIDs) == projection.job.equationIDs,
              Set(definitionRows.keys) == Set(checkpointRows.keys),
              definitions.allSatisfy({ definition in
                  guard let typed = checkpointRows[definition.id] else { return false }
                  return definition.updatedAt == typed.updatedAt
              }),
              let state = FormulaJobState(rawValue: row.state) else {
            throw V10FormulaJobStoreError.inconsistent("formula job typed rows 無法組成連續 checkpoint")
        }

        let completedBatchIndices = Set(reconstructedBatches.filter { $0.status == .completed }.map(\.batchIndex))
        guard Set(projection.completedClaimsByBatch.keys) == completedBatchIndices else {
            throw V10FormulaJobStoreError.inconsistent("completed batches 與 claims 投影不一致")
        }
        let storedSteps = try modelContext.fetch(FetchDescriptor<StoredV10FormulaDerivationStep>(predicate: #Predicate { $0.jobID == id }))
        let stepRows = try Self.uniqueRows(storedSteps, family: "formula derivation step") { $0.id }
        var expectedSteps = [String: (equationID: String, ordinal: Int, text: String, anchorID: String?, status: String)]()
        for batch in reconstructedBatches where batch.status == .completed {
            let claims = projection.completedClaimsByBatch[batch.batchIndex] ?? []
            let claimEquationIDs = claims.compactMap(\.equationID)
            guard claimEquationIDs.count == claims.count,
                  claimEquationIDs.count == batch.equationIDs.count,
                  Set(claimEquationIDs) == Set(batch.equationIDs) else {
                throw V10FormulaJobStoreError.inconsistent("completed formula batch claims coverage 不完整")
            }
            for claim in claims {
                guard let equationID = claim.equationID else {
                    throw V10FormulaJobStoreError.inconsistent("completed formula claim 缺少 equation ID")
                }
                for (ordinal, text) in claim.derivationSteps.enumerated() {
                    let stepID = "\(id):\(equationID):\(ordinal)"
                    expectedSteps[stepID] = (equationID, ordinal, text, claim.evidenceIDs.first,
                                             "validated_batch_\(batch.batchIndex)")
                }
            }
        }
        guard Set(stepRows.keys) == Set(expectedSteps.keys),
              expectedSteps.allSatisfy({ stepID, step in
                  guard let stored = stepRows[stepID] else { return false }
                  return stored.equationID == step.equationID && stored.ordinal == step.ordinal &&
                      stored.text == step.text && stored.anchorID == step.anchorID && stored.status == step.status
        }) else {
            throw V10FormulaJobStoreError.inconsistent("formula derivation steps 與已完成 claims 不一致")
        }

        let expectedDependencies = try Self.expectedDependencies(
            job: projection.job, claimsByBatch: projection.completedClaimsByBatch)
        var typedDependencies = try modelContext.fetch(FetchDescriptor<StoredV10EquationDependency>(predicate: #Predicate { $0.jobID == id }))
        if typedDependencies.isEmpty, !expectedDependencies.isEmpty {
            // Earlier V10 writers did not materialize dependency edges. Backfill
            // only the wholly absent family; a partial family is treated as
            // possible tampering and is rejected below.
            for (dependencyID, dependency) in expectedDependencies {
                modelContext.insert(StoredV10EquationDependency(id: dependencyID, jobID: id,
                    equationID: dependency.equationID,
                    dependsOnEquationID: dependency.dependsOnEquationID, status: dependency.status))
            }
            try modelContext.save()
            typedDependencies = try modelContext.fetch(FetchDescriptor<StoredV10EquationDependency>(predicate: #Predicate { $0.jobID == id }))
        }
        let dependencyRows = try Self.uniqueRows(typedDependencies, family: "equation dependency") { $0.id }
        guard Set(typedDependencies.map { "\($0.equationID)|\($0.dependsOnEquationID)" }).count == typedDependencies.count,
              Set(dependencyRows.keys) == Set(expectedDependencies.keys),
              expectedDependencies.allSatisfy({ dependencyID, dependency in
                  guard let stored = dependencyRows[dependencyID] else { return false }
                  return stored.jobID == id && stored.equationID == dependency.equationID &&
                      stored.dependsOnEquationID == dependency.dependsOnEquationID && stored.status == dependency.status
              }) else {
            throw V10FormulaJobStoreError.inconsistent("equation dependency rows 與已完成 claims 不一致")
        }

        let runID = "formula:\(id)"
        let runRows = try modelContext.fetch(FetchDescriptor<StoredV10AnalysisRun>(predicate: #Predicate { $0.id == runID }))
        let expectedSourceHashes = try JSONEncoder.latticeLens.encode([row.documentHash])
        let expectedRunPayloadHash = StableHash.sha256([id, row.documentHash, row.inventoryHash].joined(separator: "|"))
        var needsTypedAuditBackfill = false
        guard runRows.count <= 1 else {
            throw V10FormulaJobStoreError.inconsistent("formula AnalysisRun identity 重複")
        }
        if let run = runRows.first {
            let storedSourceHashes = try JSONDecoder.latticeLens.decode([String].self, from: run.sourceDocumentHashesData)
            guard runRows.count == 1, run.workflowKind == "formula_derivation",
                  run.phase == state.rawValue, run.promptVersion == row.promptVersion,
                  run.schemaVersion == row.schemaVersion, run.inventoryHash == row.inventoryHash,
                  run.payloadHash == expectedRunPayloadHash,
                  storedSourceHashes == [row.documentHash], run.updatedAt == row.updatedAt else {
                throw V10FormulaJobStoreError.inconsistent("formula AnalysisRun 與 job checkpoint 不一致")
            }
        } else {
            // Older V10 writers could persist a job without its audit-run row.
            // Rebuild this metadata only after the batch/step/dependency rows
            // above have been checked against the checkpoint projection.
            modelContext.insert(StoredV10AnalysisRun(id: runID, workflowKind: "formula_derivation",
                phase: state.rawValue, providerRevision: "not-recorded", modelID: "not-recorded",
                promptVersion: row.promptVersion, schemaVersion: row.schemaVersion,
                payloadHash: expectedRunPayloadHash, sourceDocumentHashesData: expectedSourceHashes,
                inventoryHash: row.inventoryHash, updatedAt: row.updatedAt, payload: Data()))
            needsTypedAuditBackfill = true
        }

        let attempts = try modelContext.fetch(FetchDescriptor<StoredV10AnalysisAttempt>(predicate: #Predicate { $0.runID == runID }))
        let attemptsByID = try Self.uniqueRows(attempts, family: "analysis attempt") { $0.id }
        guard Set(attempts.map { "\($0.batchIndex ?? -1)|\($0.attempt)" }).count == attempts.count,
              attempts.allSatisfy({ attempt in
                  guard let batchIndex = attempt.batchIndex,
                        let batch = reconstructedBatches.first(where: { $0.batchIndex == batchIndex }) else { return false }
                  return attempt.requestIndex == batchIndex && attempt.attempt > 0 &&
                      attempt.attempt <= batch.attemptCount && attempt.id == Self.attemptID(
                          runID: runID, batchIndex: batchIndex, attempt: attempt.attempt) &&
                      !attempt.requestID.isEmpty && attempt.receivedBytes >= 0 &&
                      attempt.receivedCharacters >= 0 && FormulaBatchStatus(rawValue: attempt.status) != nil
              }) else {
            throw V10FormulaJobStoreError.inconsistent("typed analysis attempts 含未知或重複的 batch/attempt identity")
        }
        for batch in reconstructedBatches where batch.attemptCount > 0 {
            guard let requestID = batch.requestID, !requestID.isEmpty else { continue }
            let attemptID = Self.attemptID(runID: runID, batchIndex: batch.batchIndex, attempt: batch.attemptCount)
            if let attempt = attemptsByID[attemptID] {
                guard attempt.batchIndex == batch.batchIndex, attempt.attempt == batch.attemptCount,
                      attempt.requestIndex == batch.batchIndex, attempt.requestID == requestID,
                      attempt.status == batch.status.rawValue,
                      attempt.receivedBytes == batch.receivedBytes,
                      attempt.receivedCharacters == batch.receivedCharacters,
                      attempt.errorCategory == batch.errorCategory,
                      attempt.updatedAt == batch.updatedAt else {
                    throw V10FormulaJobStoreError.inconsistent("latest typed analysis attempt 與 batch checkpoint 不一致")
                }
            } else {
                modelContext.insert(StoredV10AnalysisAttempt(id: attemptID, runID: runID,
                    requestIndex: batch.batchIndex, batchIndex: batch.batchIndex, requestID: requestID,
                    attempt: batch.attemptCount, status: batch.status.rawValue,
                    receivedBytes: batch.receivedBytes, receivedCharacters: batch.receivedCharacters,
                    errorCategory: batch.errorCategory, updatedAt: batch.updatedAt))
                needsTypedAuditBackfill = true
            }
        }
        if needsTypedAuditBackfill {
            do { try modelContext.save() }
            catch { modelContext.rollback(); throw error }
        }

        if canonicalRows.isEmpty {
            do {
                try persistCanonicalRows(projection)
                try persistSegmentRows(projection)
                row.payload = try JSONEncoder.latticeLens.encode(projection)
                try modelContext.save()
            } catch {
                modelContext.rollback()
                throw error
            }
        }

        var job = projection.job
        job.state = state
        job.batches = reconstructedBatches
        job.startedAt = row.createdAt
        job.updatedAt = row.updatedAt
        return FormulaDerivationCheckpoint(job: job,
            completedClaimsByBatch: projection.completedClaimsByBatch,
            derivationSegmentsByEquation: projection.derivationSegmentsByEquation,
            promptVersion: projection.promptVersion, schemaVersion: projection.schemaVersion,
            contextFingerprint: projection.contextFingerprint, updatedAt: row.updatedAt)
    }

    private static func sameSegmentProvenance(
        _ lhs: [String: FormulaDerivationSegmentCheckpoint]?,
        _ rhs: [String: FormulaDerivationSegmentCheckpoint]?
    ) -> Bool {
        let left = lhs ?? [:]
        let right = rhs ?? [:]
        guard Set(left.keys) == Set(right.keys) else { return false }
        return left.allSatisfy { equationID, value in
            guard let other = right[equationID],
                  let leftHash = try? value.provenanceHash(),
                  let rightHash = try? other.provenanceHash() else { return false }
            return leftHash == rightHash
        }
    }

    func saveFormulaJob(_ checkpoint: FormulaDerivationCheckpoint) throws {
        do {
            try persistFormulaJob(checkpoint, validationReport: nil)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func readyEvidenceInsightPublication(cacheKey: String) throws -> ReadyEvidenceInsightPublication? {
        let runID = EvidenceInsightPublicationContext.analysisRunID(cacheKey: cacheKey)
        let rows = try modelContext.fetch(FetchDescriptor<StoredV10AnalysisRun>(predicate: #Predicate { $0.id == runID }))
        guard rows.count <= 1 else {
            throw V10FormulaJobStoreError.inconsistent("ready evidence publication AnalysisRun identity 重複")
        }
        guard let row = rows.first else { return nil }
        return try decodeReadyEvidencePublication(row, requestedCacheKey: cacheKey)
    }

    func saveReadyEvidenceInsightPublication(_ publication: ReadyEvidenceInsightPublication) throws {
        guard publication.hasConsistentIdentity else {
            throw V10FormulaJobStoreError.inconsistent("ready evidence publication identity/hash mismatch")
        }
        do {
            let context = publication.context
            let runID = context.analysisRunID
            let rows = try modelContext.fetch(FetchDescriptor<StoredV10AnalysisRun>(predicate: #Predicate { $0.id == runID }))
            guard rows.count <= 1 else {
                throw V10FormulaJobStoreError.inconsistent("ready evidence publication AnalysisRun identity 重複")
            }
            let payload = try JSONEncoder.latticeLens.encode(publication)
            let payloadHash = StableHash.sha256(payload)
            let sourceHashes = try JSONEncoder.latticeLens.encode([context.documentHash])
            if let row = rows.first {
                let prior = try decodeReadyEvidencePublication(row, requestedCacheKey: context.cacheKey)
                guard prior.context == context else {
                    throw V10FormulaJobStoreError.inconsistent("ready evidence publication frozen context cannot be rewritten")
                }
                row.phase = "ready_to_publish"
                row.providerRevision = context.providerProfileFingerprint
                row.modelID = context.modelID
                row.promptVersion = context.promptVersion
                row.schemaVersion = context.schemaVersion
                row.payloadHash = payloadHash
                row.sourceDocumentHashesData = sourceHashes
                row.inventoryHash = context.inventoryHash
                row.updatedAt = publication.artifact.createdAt
                row.payload = payload
            } else {
                modelContext.insert(StoredV10AnalysisRun(
                    id: runID, workflowKind: "evidence_insight", phase: "ready_to_publish",
                    providerRevision: context.providerProfileFingerprint, modelID: context.modelID,
                    promptVersion: context.promptVersion, schemaVersion: context.schemaVersion,
                    payloadHash: payloadHash, sourceDocumentHashesData: sourceHashes,
                    inventoryHash: context.inventoryHash, updatedAt: publication.artifact.createdAt,
                    payload: payload
                ))
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func removeReadyEvidenceInsightPublication(cacheKey: String) throws {
        do {
            let runID = EvidenceInsightPublicationContext.analysisRunID(cacheKey: cacheKey)
            let rows = try modelContext.fetch(FetchDescriptor<StoredV10AnalysisRun>(predicate: #Predicate { $0.id == runID }))
            guard rows.count <= 1 else {
                throw V10FormulaJobStoreError.inconsistent("ready evidence publication AnalysisRun identity 重複")
            }
            guard let row = rows.first else { return }
            _ = try decodeReadyEvidencePublication(row, requestedCacheKey: cacheKey)
            modelContext.delete(row)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func decodeReadyEvidencePublication(
        _ row: StoredV10AnalysisRun,
        requestedCacheKey: String
    ) throws -> ReadyEvidenceInsightPublication {
        guard row.workflowKind == "evidence_insight", row.phase == "ready_to_publish",
              row.id == EvidenceInsightPublicationContext.analysisRunID(cacheKey: requestedCacheKey),
              row.payloadHash == StableHash.sha256(row.payload),
              let sourceHashes = try? JSONDecoder.latticeLens.decode([String].self, from: row.sourceDocumentHashesData),
              sourceHashes.count == 1 else {
            throw V10FormulaJobStoreError.inconsistent("ready evidence publication row metadata/hash invalid")
        }
        let publication = try JSONDecoder.latticeLens.decode(ReadyEvidenceInsightPublication.self, from: row.payload)
        let context = publication.context
        guard publication.hasConsistentIdentity, context.cacheKey == requestedCacheKey,
              context.analysisRunID == row.id, sourceHashes == [context.documentHash],
              row.providerRevision == context.providerProfileFingerprint,
              row.modelID == context.modelID, row.promptVersion == context.promptVersion,
              row.schemaVersion == context.schemaVersion, row.inventoryHash == context.inventoryHash else {
            throw V10FormulaJobStoreError.inconsistent("ready evidence publication payload/AnalysisRun metadata mismatch")
        }
        return publication
    }

    func saveFormulaJobWithValidation(_ checkpoint: FormulaDerivationCheckpoint,
                                     report: FormulaCoverageReport) throws {
        do {
            try persistFormulaJob(checkpoint, validationReport: report)
            guard try formulaValidationReport(jobID: checkpoint.job.jobID) == report else {
                throw V10FormulaJobStoreError.inconsistent("committed formula validation report could not be read back")
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func formulaValidationReport(jobID: String) throws -> FormulaCoverageReport? {
        let reportID = "\(jobID):\(FormulaCoverageValidator.version)"
        let reportRows = try modelContext.fetch(FetchDescriptor<StoredV10FormulaValidationReport>())
        guard let row = reportRows.first(where: { $0.id == reportID }) else { return nil }
        guard row.status != "stale" else { return nil }
        let report = try JSONDecoder.latticeLens.decode(FormulaCoverageReport.self, from: row.payload)
        guard row.jobID == jobID, row.validatorVersion == FormulaCoverageValidator.version,
              report.inventoryHash == row.inventoryHash, report.claimHash == row.claimHash,
              (row.status == "complete") == report.isComplete else {
            throw V10FormulaJobStoreError.inconsistent("formula validation report metadata 與內容不一致")
        }
        return report
    }

    private func persistSegmentRows(_ checkpoint: FormulaDerivationCheckpoint) throws {
        let job = checkpoint.job
        let segmentStates = checkpoint.derivationSegmentsByEquation ?? [:]
        guard Set(segmentStates.keys).isSubset(of: Set(job.equationIDs)) else {
            throw V10FormulaJobStoreError.inconsistent("V12 segment checkpoint contains an unknown equation ID")
        }

        var desiredSegments = [String: StoredV12FormulaDerivationSegment]()
        var desiredSteps = [String: StoredV12FormulaDerivationSegmentStep]()
        let encoder = JSONEncoder.latticeLens
        encoder.outputFormatting.insert(.sortedKeys)
        for equationID in job.equationIDs {
            guard let storedState = segmentStates[equationID] else { continue }
            let state = try storedState.validatedCopy()
            guard state.equationID == equationID, !state.segments.isEmpty else {
                throw V10FormulaJobStoreError.inconsistent("V12 segment checkpoint has an empty or mismatched equation state")
            }
            var prefix = FormulaDerivationSegmentCheckpoint(equationID: equationID, sourceTeX: state.sourceTeX)
            for receipt in state.segments {
                let stepsHash = StableHash.sha256(try encoder.encode(receipt.steps))
                let receiptHash = try FormulaDerivationSegmentCheckpoint.provenanceHash(for: receipt)
                try prefix.appendSegment(index: receipt.index, steps: receipt.steps, isFinal: receipt.isFinal,
                    continuationSummary: receipt.continuationSummary, conclusionZH: receipt.conclusionZH,
                    requestID: receipt.requestID, requestPayloadHash: receipt.requestPayloadHash,
                    responseHash: receipt.responseHash, receivedBytes: receipt.receivedBytes,
                    receivedCharacters: receipt.receivedCharacters, firstContentAt: receipt.firstContentAt,
                    lastContentAt: receipt.lastContentAt)
                let chainHash = try prefix.provenanceHash()
                let id = Self.segmentRowID(jobID: job.jobID, equationID: equationID,
                                           segmentIndex: receipt.index)
                let row = StoredV12FormulaDerivationSegment(id: id, jobID: job.jobID,
                    paperID: job.paperID, documentHash: job.documentHash, inventoryHash: job.inventoryHash,
                    equationID: equationID, sourceTeX: state.sourceTeX,
                    sourceTeXHash: StableHash.sha256(state.sourceTeX), segmentIndex: receipt.index,
                    firstOrdinal: receipt.steps[0].ordinal, stepCount: receipt.steps.count,
                    isFinal: receipt.isFinal, continuationSummary: receipt.continuationSummary,
                    conclusionZH: receipt.conclusionZH, requestID: receipt.requestID,
                    requestPayloadHash: receipt.requestPayloadHash, responseHash: receipt.responseHash,
                    receivedBytes: receipt.receivedBytes, receivedCharacters: receipt.receivedCharacters,
                    firstContentAt: receipt.firstContentAt, lastContentAt: receipt.lastContentAt,
                    stepsHash: stepsHash, receiptHash: receiptHash, chainHash: chainHash)
                guard desiredSegments.updateValue(row, forKey: id) == nil else {
                    throw V10FormulaJobStoreError.inconsistent("duplicate V12 formula segment identity")
                }

                for step in receipt.steps {
                    let stepRowID = Self.segmentStepRowID(jobID: job.jobID, equationID: equationID,
                        segmentIndex: receipt.index, stepID: step.stepID)
                    let stepRow = StoredV12FormulaDerivationSegmentStep(id: stepRowID,
                        jobID: job.jobID, equationID: equationID, segmentIndex: receipt.index,
                        stepID: step.stepID, ordinal: step.ordinal, textZH: step.textZH,
                        beforeTeX: step.beforeTeX, afterTeX: step.afterTeX,
                        ruleOrAssumption: step.ruleOrAssumption,
                        referencedEquationIDsData: try encoder.encode(step.referencedEquationIDs),
                        evidenceAnchorIDsData: try encoder.encode(step.evidenceAnchorIDs),
                        sourceDocumentHashesData: try encoder.encode(step.sourceDocumentHashes),
                        epistemicStatus: step.epistemicStatus.rawValue)
                    guard desiredSteps.updateValue(stepRow, forKey: stepRowID) == nil else {
                        throw V10FormulaJobStoreError.inconsistent("duplicate V12 formula segment step identity")
                    }
                }
            }
            guard prefix == state else {
                throw V10FormulaJobStoreError.inconsistent("V12 formula segment checkpoint failed canonical revalidation")
            }
        }

        let existingSegments = try modelContext.fetch(FetchDescriptor<StoredV12FormulaDerivationSegment>(
            predicate: #Predicate { $0.jobID == job.jobID }))
        let existingSteps = try modelContext.fetch(FetchDescriptor<StoredV12FormulaDerivationSegmentStep>(
            predicate: #Predicate { $0.jobID == job.jobID }))
        var priorSegments = try Self.uniqueRows(existingSegments, family: "V12 formula segment") { $0.id }
        var priorSteps = try Self.uniqueRows(existingSteps, family: "V12 formula segment step") { $0.id }
        guard Set(existingSegments.map { "\($0.equationID)|\($0.segmentIndex)" }).count == existingSegments.count,
              Set(existingSteps.map { "\($0.equationID)|\($0.segmentIndex)|\($0.stepID)" }).count == existingSteps.count,
              Set(priorSegments.keys).isSubset(of: Set(desiredSegments.keys)),
              Set(priorSteps.keys).isSubset(of: Set(desiredSteps.keys)) else {
            throw V10FormulaJobStoreError.inconsistent("V12 segment rows are duplicated or a previously validated segment disappeared")
        }
        for (id, expected) in desiredSegments {
            guard let prior = priorSegments.removeValue(forKey: id) else {
                modelContext.insert(expected)
                continue
            }
            guard prior.jobID == expected.jobID, prior.paperID == expected.paperID,
                  prior.documentHash == expected.documentHash, prior.inventoryHash == expected.inventoryHash,
                  prior.equationID == expected.equationID, prior.sourceTeX == expected.sourceTeX,
                  prior.sourceTeXHash == expected.sourceTeXHash, prior.segmentIndex == expected.segmentIndex,
                  prior.firstOrdinal == expected.firstOrdinal, prior.stepCount == expected.stepCount,
                  prior.isFinal == expected.isFinal, prior.continuationSummary == expected.continuationSummary,
                  prior.conclusionZH == expected.conclusionZH, prior.requestID == expected.requestID,
                  prior.requestPayloadHash == expected.requestPayloadHash, prior.responseHash == expected.responseHash,
                  prior.receivedBytes == expected.receivedBytes,
                  prior.receivedCharacters == expected.receivedCharacters,
                  prior.firstContentAt == expected.firstContentAt, prior.lastContentAt == expected.lastContentAt,
                  prior.stepsHash == expected.stepsHash, prior.receiptHash == expected.receiptHash,
                  prior.chainHash == expected.chainHash else {
                throw V10FormulaJobStoreError.inconsistent("V12 formula segment is append-only and its stable row changed")
            }
        }
        for (id, expected) in desiredSteps {
            guard let prior = priorSteps.removeValue(forKey: id) else {
                modelContext.insert(expected)
                continue
            }
            guard prior.jobID == expected.jobID, prior.equationID == expected.equationID,
                  prior.segmentIndex == expected.segmentIndex, prior.stepID == expected.stepID,
                  prior.ordinal == expected.ordinal, prior.textZH == expected.textZH,
                  prior.beforeTeX == expected.beforeTeX, prior.afterTeX == expected.afterTeX,
                  prior.ruleOrAssumption == expected.ruleOrAssumption,
                  prior.referencedEquationIDsData == expected.referencedEquationIDsData,
                  prior.evidenceAnchorIDsData == expected.evidenceAnchorIDsData,
                  prior.sourceDocumentHashesData == expected.sourceDocumentHashesData,
                  prior.epistemicStatus == expected.epistemicStatus else {
                throw V10FormulaJobStoreError.inconsistent("V12 formula segment step is append-only and its stable row changed")
            }
        }
    }

    private func persistCanonicalRows(_ checkpoint: FormulaDerivationCheckpoint) throws {
        let job = checkpoint.job
        let jobID = job.jobID
        let jobRows = try modelContext.fetch(FetchDescriptor<StoredV11FormulaDerivationJob>(predicate: #Predicate { $0.id == jobID }))
        guard jobRows.count <= 1 else {
            throw V10FormulaJobStoreError.inconsistent("V11 formula job identity 重複寫入")
        }
        let equationIDsData = try JSONEncoder.latticeLens.encode(job.equationIDs)
        if let typedJob = jobRows.first {
            guard typedJob.paperID == job.paperID, typedJob.documentHash == job.documentHash,
                  typedJob.inventoryHash == job.inventoryHash, typedJob.equationIDsData == equationIDsData,
                  typedJob.batchSize == job.batchSize, typedJob.promptVersion == checkpoint.promptVersion,
                  typedJob.schemaVersion == checkpoint.schemaVersion,
                  typedJob.contextFingerprint == checkpoint.contextFingerprint,
                  typedJob.startedAt == job.startedAt else {
                throw V10FormulaJobStoreError.inconsistent("V11 formula job frozen identity cannot be rewritten")
            }
            typedJob.state = job.state.rawValue
            typedJob.updatedAt = checkpoint.updatedAt
        } else {
            modelContext.insert(StoredV11FormulaDerivationJob(id: jobID, paperID: job.paperID,
                documentHash: job.documentHash, inventoryHash: job.inventoryHash,
                equationIDsData: equationIDsData, batchSize: job.batchSize,
                state: job.state.rawValue, promptVersion: checkpoint.promptVersion,
                schemaVersion: checkpoint.schemaVersion, contextFingerprint: checkpoint.contextFingerprint,
                startedAt: job.startedAt, updatedAt: checkpoint.updatedAt))
        }

        let oldClaims = try modelContext.fetch(FetchDescriptor<StoredV11FormulaClaim>(predicate: #Predicate { $0.jobID == jobID }))
        let oldSteps = try modelContext.fetch(FetchDescriptor<StoredV11FormulaDerivationStep>(predicate: #Predicate { $0.jobID == jobID }))
        var claimsByID = try Self.uniqueRows(oldClaims, family: "V11 formula claim") { $0.id }
        var stepsByID = try Self.uniqueRows(oldSteps, family: "V11 structured formula step") { $0.id }
        guard Set(oldClaims.map { "\($0.batchIndex)|\($0.equationID)" }).count == oldClaims.count,
              Set(oldSteps.map(\.stepID)).count == oldSteps.count else {
            throw V10FormulaJobStoreError.inconsistent("V11 formula rows contain duplicate logical identities")
        }

        var desiredClaimIDs = Set<String>()
        var desiredStepIDs = Set<String>()
        var allStepIDs = Set<String>()
        for (batchIndex, claims) in checkpoint.completedClaimsByBatch {
            for claim in claims {
                guard let equationID = claim.equationID else {
                    throw V10FormulaJobStoreError.inconsistent("V11 formula claim 缺少 equation ID")
                }
                let claimID = Self.claimRowID(jobID: jobID, batchIndex: batchIndex, equationID: equationID)
                guard desiredClaimIDs.insert(claimID).inserted else {
                    throw V10FormulaJobStoreError.inconsistent("duplicate V11 formula claim identity")
                }
                let claimHash = try Self.claimHash(claim)
                let evidenceIDsData = try JSONEncoder.latticeLens.encode(claim.evidenceIDs)
                let derivationStepsData = try JSONEncoder.latticeLens.encode(claim.derivationSteps)
                if let stored = claimsByID.removeValue(forKey: claimID) {
                    guard stored.jobID == jobID, stored.batchIndex == batchIndex,
                          stored.equationID == equationID else {
                        throw V10FormulaJobStoreError.inconsistent("V11 formula claim stable identity collision")
                    }
                    let claimUUID = claim.id.uuidString
                    if stored.claimUUID != claimUUID { stored.claimUUID = claimUUID }
                    if stored.textZH != claim.textZH { stored.textZH = claim.textZH }
                    if stored.epistemicStatus != claim.epistemicStatus.rawValue {
                        stored.epistemicStatus = claim.epistemicStatus.rawValue
                    }
                    if stored.evidenceIDsData != evidenceIDsData { stored.evidenceIDsData = evidenceIDsData }
                    if stored.formulaTeX != claim.formulaTeX { stored.formulaTeX = claim.formulaTeX }
                    if stored.derivationStepsData != derivationStepsData {
                        stored.derivationStepsData = derivationStepsData
                    }
                    if stored.conclusionZH != claim.conclusionZH { stored.conclusionZH = claim.conclusionZH }
                    if stored.claimHash != claimHash { stored.claimHash = claimHash }
                } else {
                    modelContext.insert(StoredV11FormulaClaim(id: claimID, jobID: jobID,
                        batchIndex: batchIndex, equationID: equationID, claimUUID: claim.id.uuidString,
                        textZH: claim.textZH, epistemicStatus: claim.epistemicStatus.rawValue,
                        evidenceIDsData: evidenceIDsData, formulaTeX: claim.formulaTeX,
                        derivationStepsData: derivationStepsData, conclusionZH: claim.conclusionZH,
                        claimHash: claimHash))
                }

                for step in claim.formulaDerivationSteps {
                    guard allStepIDs.insert(step.stepID).inserted else {
                        throw V10FormulaJobStoreError.inconsistent("duplicate V11 structured formula step ID")
                    }
                    let stepID = Self.structuredStepRowID(jobID: jobID, stepID: step.stepID)
                    guard desiredStepIDs.insert(stepID).inserted else {
                        throw V10FormulaJobStoreError.inconsistent("duplicate V11 structured formula step row")
                    }
                    let referencedEquationIDsData = try JSONEncoder.latticeLens.encode(step.referencedEquationIDs)
                    let evidenceAnchorIDsData = try JSONEncoder.latticeLens.encode(step.evidenceAnchorIDs)
                    let sourceDocumentHashesData = try JSONEncoder.latticeLens.encode(step.sourceDocumentHashes)
                    if let stored = stepsByID.removeValue(forKey: stepID) {
                        guard stored.jobID == jobID, stored.stepID == step.stepID else {
                        throw V10FormulaJobStoreError.inconsistent("V11 structured formula step stable identity collision")
                    }
                    if stored.batchIndex != batchIndex { stored.batchIndex = batchIndex }
                    if stored.equationID != equationID { stored.equationID = equationID }
                    if stored.ordinal != step.ordinal { stored.ordinal = step.ordinal }
                    if stored.textZH != step.textZH { stored.textZH = step.textZH }
                    if stored.beforeTeX != step.beforeTeX { stored.beforeTeX = step.beforeTeX }
                    if stored.afterTeX != step.afterTeX { stored.afterTeX = step.afterTeX }
                    if stored.ruleOrAssumption != step.ruleOrAssumption {
                        stored.ruleOrAssumption = step.ruleOrAssumption
                    }
                    if stored.referencedEquationIDsData != referencedEquationIDsData {
                        stored.referencedEquationIDsData = referencedEquationIDsData
                    }
                    if stored.evidenceAnchorIDsData != evidenceAnchorIDsData {
                        stored.evidenceAnchorIDsData = evidenceAnchorIDsData
                    }
                    if stored.sourceDocumentHashesData != sourceDocumentHashesData {
                        stored.sourceDocumentHashesData = sourceDocumentHashesData
                    }
                    if stored.epistemicStatus != step.epistemicStatus.rawValue {
                        stored.epistemicStatus = step.epistemicStatus.rawValue
                    }
                    } else {
                        modelContext.insert(StoredV11FormulaDerivationStep(id: stepID, jobID: jobID,
                            batchIndex: batchIndex, equationID: equationID, stepID: step.stepID,
                            ordinal: step.ordinal, textZH: step.textZH, beforeTeX: step.beforeTeX,
                            afterTeX: step.afterTeX, ruleOrAssumption: step.ruleOrAssumption,
                            referencedEquationIDsData: referencedEquationIDsData,
                            evidenceAnchorIDsData: evidenceAnchorIDsData,
                            sourceDocumentHashesData: sourceDocumentHashesData,
                            epistemicStatus: step.epistemicStatus.rawValue))
                    }
                }
            }
        }
        for stale in claimsByID.values { modelContext.delete(stale) }
        for stale in stepsByID.values { modelContext.delete(stale) }
    }

    private func persistFormulaJob(_ checkpoint: FormulaDerivationCheckpoint,
                                   validationReport: FormulaCoverageReport?) throws {
        try Self.validate(checkpoint)
        let id = checkpoint.job.jobID
        let descriptor = FetchDescriptor<StoredV10FormulaDerivationJob>(predicate: #Predicate { $0.id == id })
        let storedDefinitionRows = try modelContext.fetch(FetchDescriptor<StoredV10FormulaBatch>(predicate: #Predicate { $0.jobID == id }))
        let storedCheckpointRows = try modelContext.fetch(FetchDescriptor<StoredV10FormulaBatchCheckpoint>(predicate: #Predicate { $0.jobID == id }))
        let storedStepRows = try modelContext.fetch(FetchDescriptor<StoredV10FormulaDerivationStep>(predicate: #Predicate { $0.jobID == id }))
        var priorDefinitions = try Self.uniqueRows(storedDefinitionRows, family: "formula batch") { $0.id }
        var priorCheckpoints = try Self.uniqueRows(storedCheckpointRows, family: "formula batch checkpoint") { $0.id }
        var priorSteps = try Self.uniqueRows(storedStepRows, family: "formula derivation step") { $0.id }
        guard Set(storedDefinitionRows.map(\.ordinal)).count == storedDefinitionRows.count,
              Set(storedCheckpointRows.map(\.batchIndex)).count == storedCheckpointRows.count,
              Set(storedStepRows.map { "\($0.equationID)|\($0.ordinal)" }).count == storedStepRows.count else {
            throw V10FormulaJobStoreError.inconsistent("formula typed rows 含重複 logical identity")
        }
        if !storedDefinitionRows.isEmpty || !storedCheckpointRows.isEmpty {
            let expectedIDs = Set(checkpoint.job.batches.map(\.id))
            guard Set(priorDefinitions.keys) == expectedIDs,
                  Set(priorCheckpoints.keys) == expectedIDs else {
                throw V10FormulaJobStoreError.inconsistent("formula batch plan 改變或既有 typed checkpoint 不完整")
            }
        }

        let row: StoredV10FormulaDerivationJob
        if let existing = try modelContext.fetch(descriptor).first {
            guard existing.paperID == checkpoint.job.paperID,
                  existing.documentHash == checkpoint.job.documentHash,
                  existing.inventoryHash == checkpoint.job.inventoryHash,
                  existing.promptVersion == checkpoint.promptVersion,
                  existing.schemaVersion == checkpoint.schemaVersion,
                  existing.createdAt == checkpoint.job.startedAt else {
                throw V10FormulaJobStoreError.inconsistent("formula job identity cannot be rewritten")
            }
            existing.state = checkpoint.job.state.rawValue
            existing.updatedAt = checkpoint.updatedAt
            existing.promptVersion = checkpoint.promptVersion
            existing.schemaVersion = checkpoint.schemaVersion
            row = existing
        } else {
            let created = StoredV10FormulaDerivationJob(id: id, paperID: checkpoint.job.paperID,
                documentID: "\(checkpoint.job.paperID):\(checkpoint.job.documentHash)",
                documentHash: checkpoint.job.documentHash, inventoryHash: checkpoint.job.inventoryHash,
                state: checkpoint.job.state.rawValue, promptVersion: checkpoint.promptVersion,
                schemaVersion: checkpoint.schemaVersion, createdAt: checkpoint.job.startedAt,
                updatedAt: checkpoint.updatedAt, payload: Data())
            modelContext.insert(created); row = created
        }
        _ = row

        for batch in checkpoint.job.batches {
            let equationIDs = try JSONEncoder.latticeLens.encode(batch.equationIDs)
            if let definition = priorDefinitions.removeValue(forKey: batch.id) {
                if definition.equationIDsData != equationIDs { definition.equationIDsData = equationIDs }
                if definition.payloadHash != batch.payloadHash { definition.payloadHash = batch.payloadHash }
                if definition.status != batch.status.rawValue { definition.status = batch.status.rawValue }
                if definition.updatedAt != batch.updatedAt { definition.updatedAt = batch.updatedAt }
            } else {
                modelContext.insert(StoredV10FormulaBatch(id: batch.id, jobID: id, ordinal: batch.batchIndex,
                    equationIDsData: equationIDs, payloadHash: batch.payloadHash,
                    status: batch.status.rawValue, updatedAt: batch.updatedAt))
            }
            if let row = priorCheckpoints.removeValue(forKey: batch.id) {
                if row.inventoryHash != checkpoint.job.inventoryHash {
                    row.inventoryHash = checkpoint.job.inventoryHash
                }
                if row.batchIndex != batch.batchIndex { row.batchIndex = batch.batchIndex }
                if row.batchTotal != batch.batchTotal { row.batchTotal = batch.batchTotal }
                if row.equationIDsData != equationIDs { row.equationIDsData = equationIDs }
                if row.requestID != batch.requestID { row.requestID = batch.requestID }
                if row.attemptCount != batch.attemptCount { row.attemptCount = batch.attemptCount }
                if row.payloadHash != batch.payloadHash { row.payloadHash = batch.payloadHash }
                if row.receivedBytes != batch.receivedBytes { row.receivedBytes = batch.receivedBytes }
                if row.receivedCharacters != batch.receivedCharacters {
                    row.receivedCharacters = batch.receivedCharacters
                }
                if row.firstContentAt != batch.firstContentAt { row.firstContentAt = batch.firstContentAt }
                if row.lastContentAt != batch.lastContentAt { row.lastContentAt = batch.lastContentAt }
                if row.status != batch.status.rawValue { row.status = batch.status.rawValue }
                if row.errorCategory != batch.errorCategory { row.errorCategory = batch.errorCategory }
                if row.updatedAt != batch.updatedAt { row.updatedAt = batch.updatedAt }
            } else {
                modelContext.insert(StoredV10FormulaBatchCheckpoint(id: batch.id, jobID: id,
                    inventoryHash: checkpoint.job.inventoryHash, batchIndex: batch.batchIndex,
                    batchTotal: batch.batchTotal, equationIDsData: equationIDs, requestID: batch.requestID,
                    attemptCount: batch.attemptCount, payloadHash: batch.payloadHash,
                    receivedBytes: batch.receivedBytes, receivedCharacters: batch.receivedCharacters,
                    firstContentAt: batch.firstContentAt, lastContentAt: batch.lastContentAt,
                    status: batch.status.rawValue, errorCategory: batch.errorCategory, updatedAt: batch.updatedAt))
            }
        }
        guard priorDefinitions.isEmpty, priorCheckpoints.isEmpty else {
            throw V10FormulaJobStoreError.inconsistent("formula batch upsert left unexpected rows")
        }

        var desiredSteps = [String: (equationID: String, ordinal: Int, text: String, anchorID: String?, status: String)]()
        for (batchIndex, claims) in checkpoint.completedClaimsByBatch {
            for claim in claims {
                guard let equationID = claim.equationID else { continue }
                for (ordinal, text) in claim.derivationSteps.enumerated() {
                    let stepID = "\(id):\(equationID):\(ordinal)"
                    let step = (equationID: equationID, ordinal: ordinal, text: text,
                                anchorID: claim.evidenceIDs.first, status: "validated_batch_\(batchIndex)")
                    guard desiredSteps.updateValue(step, forKey: stepID) == nil else {
                        throw V10FormulaJobStoreError.inconsistent("duplicate formula step identity")
                    }
                }
            }
        }
        for (stepID, step) in desiredSteps {
            if let row = priorSteps.removeValue(forKey: stepID) {
                if row.equationID != step.equationID { row.equationID = step.equationID }
                if row.ordinal != step.ordinal { row.ordinal = step.ordinal }
                if row.text != step.text { row.text = step.text }
                if row.anchorID != step.anchorID { row.anchorID = step.anchorID }
                if row.status != step.status { row.status = step.status }
            } else {
                modelContext.insert(StoredV10FormulaDerivationStep(id: stepID, jobID: id,
                    equationID: step.equationID, ordinal: step.ordinal, text: step.text,
                    anchorID: step.anchorID, status: step.status))
            }
        }
        for stale in priorSteps.values { modelContext.delete(stale) }

        let desiredDependencies = try Self.expectedDependencies(job: checkpoint.job,
            claimsByBatch: checkpoint.completedClaimsByBatch)
        let storedDependencyRows = try modelContext.fetch(FetchDescriptor<StoredV10EquationDependency>(predicate: #Predicate { $0.jobID == id }))
        var priorDependencies = try Self.uniqueRows(storedDependencyRows, family: "equation dependency") { $0.id }
        guard Set(storedDependencyRows.map { "\($0.equationID)|\($0.dependsOnEquationID)" }).count == storedDependencyRows.count else {
            throw V10FormulaJobStoreError.inconsistent("equation dependency rows 含重複 logical edge")
        }
        for (dependencyID, dependency) in desiredDependencies {
            if let row = priorDependencies.removeValue(forKey: dependencyID) {
                if row.equationID != dependency.equationID { row.equationID = dependency.equationID }
                if row.dependsOnEquationID != dependency.dependsOnEquationID {
                    row.dependsOnEquationID = dependency.dependsOnEquationID
                }
                if row.status != dependency.status { row.status = dependency.status }
            } else {
                modelContext.insert(StoredV10EquationDependency(id: dependencyID, jobID: id,
                    equationID: dependency.equationID,
                    dependsOnEquationID: dependency.dependsOnEquationID, status: dependency.status))
            }
        }
        for stale in priorDependencies.values { modelContext.delete(stale) }

        try persistSegmentRows(checkpoint)
        try persistCanonicalRows(checkpoint)
        try persistAnalysisRunAndAttempts(checkpoint)
        try persistValidationReport(validationReport, checkpoint: checkpoint)
        // Keep the V10 column as a portable migration/Bundle projection only;
        // all resume reads after V11 continue to verify typed canonical rows.
        row.payload = try JSONEncoder.latticeLens.encode(checkpoint)
        try modelContext.save()
    }

    private func persistAnalysisRunAndAttempts(_ checkpoint: FormulaDerivationCheckpoint) throws {
        let job = checkpoint.job
        let runID = "formula:\(job.jobID)"
        let runDescriptor = FetchDescriptor<StoredV10AnalysisRun>(predicate: #Predicate { $0.id == runID })
        let expectedSourceHashes = try JSONEncoder.latticeLens.encode([job.documentHash])
        let payloadHash = StableHash.sha256([job.jobID, job.documentHash, job.inventoryHash].joined(separator: "|"))
        let existingRuns = try modelContext.fetch(runDescriptor)
        guard existingRuns.count <= 1 else {
            throw V10FormulaJobStoreError.inconsistent("formula AnalysisRun identity 重複")
        }
        if let run = existingRuns.first {
            guard run.workflowKind == "formula_derivation" else {
                throw V10FormulaJobStoreError.inconsistent("AnalysisRun ID 已屬於其他 workflow")
            }
            if run.phase != job.state.rawValue { run.phase = job.state.rawValue }
            if run.promptVersion != checkpoint.promptVersion { run.promptVersion = checkpoint.promptVersion }
            if run.schemaVersion != checkpoint.schemaVersion { run.schemaVersion = checkpoint.schemaVersion }
            if run.payloadHash != payloadHash { run.payloadHash = payloadHash }
            if run.sourceDocumentHashesData != expectedSourceHashes { run.sourceDocumentHashesData = expectedSourceHashes }
            if run.inventoryHash != job.inventoryHash { run.inventoryHash = job.inventoryHash }
            if run.updatedAt != checkpoint.updatedAt { run.updatedAt = checkpoint.updatedAt }
        } else {
            modelContext.insert(StoredV10AnalysisRun(id: runID, workflowKind: "formula_derivation",
                phase: job.state.rawValue, providerRevision: "not-recorded", modelID: "not-recorded",
                promptVersion: checkpoint.promptVersion, schemaVersion: checkpoint.schemaVersion,
                payloadHash: payloadHash, sourceDocumentHashesData: expectedSourceHashes,
                inventoryHash: job.inventoryHash, updatedAt: checkpoint.updatedAt, payload: Data()))
        }

        let storedAttempts = try modelContext.fetch(FetchDescriptor<StoredV10AnalysisAttempt>(predicate: #Predicate { $0.runID == runID }))
        var attemptsByID = try Self.uniqueRows(storedAttempts, family: "analysis attempt") { $0.id }
        for batch in job.batches where batch.attemptCount > 0 {
            guard let requestID = batch.requestID, !requestID.isEmpty else { continue }
            let attemptID = Self.attemptID(runID: runID, batchIndex: batch.batchIndex, attempt: batch.attemptCount)
            if let attempt = attemptsByID.removeValue(forKey: attemptID) {
                if attempt.requestIndex != batch.batchIndex { attempt.requestIndex = batch.batchIndex }
                if attempt.batchIndex != batch.batchIndex { attempt.batchIndex = batch.batchIndex }
                if attempt.requestID != requestID { attempt.requestID = requestID }
                if attempt.status != batch.status.rawValue { attempt.status = batch.status.rawValue }
                if attempt.receivedBytes != batch.receivedBytes { attempt.receivedBytes = batch.receivedBytes }
                if attempt.receivedCharacters != batch.receivedCharacters { attempt.receivedCharacters = batch.receivedCharacters }
                if attempt.errorCategory != batch.errorCategory { attempt.errorCategory = batch.errorCategory }
                if attempt.updatedAt != batch.updatedAt { attempt.updatedAt = batch.updatedAt }
            } else {
                modelContext.insert(StoredV10AnalysisAttempt(id: attemptID, runID: runID,
                    requestIndex: batch.batchIndex, batchIndex: batch.batchIndex, requestID: requestID,
                    attempt: batch.attemptCount, status: batch.status.rawValue,
                    receivedBytes: batch.receivedBytes, receivedCharacters: batch.receivedCharacters,
                    errorCategory: batch.errorCategory, updatedAt: batch.updatedAt))
            }
        }
    }

    private func persistValidationReport(_ report: FormulaCoverageReport?,
                                         checkpoint: FormulaDerivationCheckpoint) throws {
        let validatorVersion = FormulaCoverageValidator.version
        let reportID = "\(checkpoint.job.jobID):\(validatorVersion)"
        let rows = try modelContext.fetch(FetchDescriptor<StoredV10FormulaValidationReport>())
            .filter { $0.id == reportID }
        guard rows.count <= 1 else {
            throw V10FormulaJobStoreError.inconsistent("formula validation report identity 重複")
        }
        if let report {
            let claims = checkpoint.job.batches.sorted { $0.batchIndex < $1.batchIndex }
                .flatMap { checkpoint.completedClaimsByBatch[$0.batchIndex] ?? [] }
            let inventoryRows = try modelContext.fetch(FetchDescriptor<StoredV10FormulaInventory>(predicate: #Predicate {
                $0.paperID == checkpoint.job.paperID && $0.inventoryHash == checkpoint.job.inventoryHash
            }))
            guard inventoryRows.count == 1,
                  let inventoryRow = inventoryRows.first,
                  let inventory = try? JSONDecoder.latticeLens.decode(FormulaInventory.self, from: inventoryRow.payload) else {
                throw V10FormulaJobStoreError.inconsistent("formula validation report 缺少唯一來源 inventory")
            }
            let anchorRows = try modelContext.fetch(FetchDescriptor<StoredV8EvidenceAnchor>(predicate: #Predicate {
                $0.paperID == checkpoint.job.paperID
            }))
            let decodedAnchors = try anchorRows.map { try $0.decoded() }
            guard Set(decodedAnchors.map(\.id)).count == decodedAnchors.count else {
                throw V10FormulaJobStoreError.inconsistent("formula validation report source anchors 含重複 identity")
            }
            let anchors = Dictionary(uniqueKeysWithValues: decodedAnchors.map { ($0.id, $0) })
            let expected = FormulaCoverageValidator.report(inventory: inventory, claims: claims, anchors: anchors)
            let expectedStatus = checkpoint.job.state == .complete
            guard report.inventoryHash == checkpoint.job.inventoryHash,
                  report.inventoryHash == expected.inventoryHash,
                  report.claimHash == expected.claimHash,
                  report.inventoryIDs == expected.inventoryIDs,
                  report.claimIDs == expected.claimIDs,
                  report.missingEquationIDs == expected.missingEquationIDs,
                  report.extraEquationIDs == expected.extraEquationIDs,
                  report.duplicateEquationIDs == expected.duplicateEquationIDs,
                  report.invalidEquationIDs == expected.invalidEquationIDs,
                  report.derivationIncompleteEquationIDs == expected.derivationIncompleteEquationIDs,
                  report.structuralNeedsManualEquationIDs == expected.structuralNeedsManualEquationIDs,
                  report.structuralRejectedEquationIDs == expected.structuralRejectedEquationIDs,
                  report.physicsNeedsManualEquationIDs == expected.physicsNeedsManualEquationIDs,
                  (report.isComplete == expectedStatus) else {
                throw V10FormulaJobStoreError.inconsistent("formula validation report 與 checkpoint claims 不符")
            }
            let encoded = try JSONEncoder.latticeLens.encode(report)
            if let row = rows.first {
                row.inventoryHash = report.inventoryHash
                row.claimHash = report.claimHash
                row.validatorVersion = validatorVersion
                row.status = report.isComplete ? "complete" : "incomplete"
                row.payload = encoded
            } else {
                modelContext.insert(StoredV10FormulaValidationReport(id: reportID,
                    jobID: checkpoint.job.jobID, inventoryHash: report.inventoryHash,
                    claimHash: report.claimHash, validatorVersion: validatorVersion,
                    status: report.isComplete ? "complete" : "incomplete", payload: encoded,
                    createdAt: checkpoint.updatedAt))
            }
        } else if let prior = rows.first {
            // Retain the old receipt for audit, but make it impossible to read
            // as the current validation after a job has resumed or changed.
            prior.status = "stale"
        }
    }

    private static func attemptID(runID: String, batchIndex: Int, attempt: Int) -> String {
        "\(runID):batch:\(batchIndex):attempt:\(attempt)"
    }

    private struct DependencyProjection {
        let equationID: String
        let dependsOnEquationID: String
        let status: String
    }

    private static func expectedDependencies(job: FormulaDerivationJob,
                                             claimsByBatch: [Int: [EvidenceClaim]]) throws -> [String: DependencyProjection] {
        let equationIDs = Set(job.equationIDs)
        var result = [String: DependencyProjection]()
        for claim in claimsByBatch.values.flatMap({ $0 }) {
            guard let equationID = claim.equationID else {
                throw V10FormulaJobStoreError.inconsistent("formula claim 缺少 equation ID")
            }
            for step in claim.formulaDerivationSteps {
                guard step.referencedEquationIDs.count == Set(step.referencedEquationIDs).count,
                      step.referencedEquationIDs.allSatisfy({ equationIDs.contains($0) && $0 != equationID }) else {
                    throw V10FormulaJobStoreError.inconsistent("formula step dependency 指向未知或自身 equation")
                }
                for targetID in step.referencedEquationIDs {
                    let dependencyID = Self.dependencyID(jobID: job.jobID,
                        equationID: equationID, dependsOnEquationID: targetID)
                    let dependency = DependencyProjection(equationID: equationID,
                        dependsOnEquationID: targetID, status: step.epistemicStatus.rawValue)
                    if let prior = result[dependencyID],
                       prior.equationID != dependency.equationID ||
                       prior.dependsOnEquationID != dependency.dependsOnEquationID ||
                       prior.status != dependency.status {
                        throw V10FormulaJobStoreError.inconsistent("formula dependency edge 重複且狀態衝突")
                    }
                    result[dependencyID] = dependency
                }
            }
        }
        return result
    }

    nonisolated static func dependencyID(jobID: String, equationID: String, dependsOnEquationID: String) -> String {
        "\(jobID):dependency:\(StableHash.sha256("\(equationID)|\(dependsOnEquationID)"))"
    }

    private static func uniqueRows<Row>(_ rows: [Row], family: String,
                                        identity: (Row) -> String) throws -> [String: Row] {
        var result = [String: Row]()
        for row in rows {
            guard result.updateValue(row, forKey: identity(row)) == nil else {
                throw V10FormulaJobStoreError.inconsistent("\(family) rows 含重複 ID")
            }
        }
        return result
    }

    private static func validate(_ checkpoint: FormulaDerivationCheckpoint) throws {
        let job = checkpoint.job
        let segments = checkpoint.derivationSegmentsByEquation ?? [:]
        let orderedBatches = job.batches.sorted { $0.batchIndex < $1.batchIndex }
        guard Set(job.equationIDs).count == job.equationIDs.count,
              Set(segments.keys).isSubset(of: Set(job.equationIDs)),
              orderedBatches.map(\.batchIndex) == Array(0..<orderedBatches.count),
              Set(orderedBatches.map(\.id)).count == orderedBatches.count,
              orderedBatches.allSatisfy({ batch in
                  batch.jobID == job.jobID && batch.batchTotal == orderedBatches.count &&
                  batch.equationIDs.count == Set(batch.equationIDs).count && !batch.equationIDs.isEmpty
              }),
              orderedBatches.flatMap(\.equationIDs) == job.equationIDs else {
            throw V10FormulaJobStoreError.inconsistent("formula checkpoint batch partition 不完整")
        }
        let completedIndices = Set(orderedBatches.filter { $0.status == .completed }.map(\.batchIndex))
        guard Set(checkpoint.completedClaimsByBatch.keys) == completedIndices else {
            throw V10FormulaJobStoreError.inconsistent("completed batches 與 claims 數量不一致")
        }
        for batch in orderedBatches where batch.status == .completed {
            let claims = checkpoint.completedClaimsByBatch[batch.batchIndex] ?? []
            let equationIDs = claims.compactMap(\.equationID)
            guard equationIDs.count == claims.count,
                  equationIDs.count == batch.equationIDs.count,
                  Set(equationIDs).count == equationIDs.count,
                  Set(equationIDs) == Set(batch.equationIDs) else {
                throw V10FormulaJobStoreError.inconsistent("completed formula batch claims coverage 不完整")
            }
        }
        for (equationID, segment) in segments {
            guard segment.equationID == equationID, !segment.segments.isEmpty,
                  try segment.validatedCopy() == segment else {
                throw V10FormulaJobStoreError.inconsistent("formula segment checkpoint is invalid or not append-only")
            }
            if let claim = checkpoint.completedClaimsByBatch.values.flatMap({ $0 })
                .first(where: { $0.equationID == equationID }) {
                guard segment.isComplete, segment.completedSteps == claim.formulaDerivationSteps,
                      segment.conclusionZH == claim.conclusionZH,
                      claim.derivationSegmentProvenanceHash == (try segment.provenanceHash()) else {
                    throw V10FormulaJobStoreError.inconsistent("completed formula claim/proof differs from its segment chain")
                }
            }
        }
        if checkpoint.promptVersion == FormulaDerivationPrompt.version {
            for batch in orderedBatches where batch.status == .completed {
                guard batch.equationIDs.allSatisfy({ equationID in
                    segments[equationID]?.isComplete == true &&
                    checkpoint.completedClaimsByBatch[batch.batchIndex]?.contains(where: { $0.equationID == equationID }) == true
                }) else {
                    throw V10FormulaJobStoreError.inconsistent("V12 completed batch is missing a complete segment proof")
                }
            }
        }
    }
}

/// V10's formula inventory has one immutable source-bound header and one
/// independently queryable row per visible equation. A single context save
/// publishes the header and all changed item rows together.
@ModelActor
actor V10FormulaInventoryStore: FormulaInventoryStoring {
    func saveFormulaInventory(_ inventory: FormulaInventory, paperID: Int) async throws {
        do {
            try persist(inventory, paperID: paperID)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func formulaInventory(paperID: Int, documentHash: String) async throws -> FormulaInventory? {
        let documentID = "\(paperID):\(documentHash)"
        let descriptor = FetchDescriptor<StoredV10FormulaInventory>(predicate: #Predicate { $0.id == documentID })
        guard let header = try modelContext.fetch(descriptor).first else { return nil }
        let inventory = try JSONDecoder.latticeLens.decode(FormulaInventory.self, from: header.payload)
        let expectedStatus = inventory.isComplete ? "complete" : "incomplete"
        guard header.paperID == paperID, header.documentID == documentID,
              header.documentHash == documentHash, header.inventoryHash == inventory.inventoryHash,
              header.parserVersion == inventory.parserVersion,
              inventory.parserVersion == FormulaInventoryParser.parserVersion,
              header.status == expectedStatus else {
            throw LatticeLensError.persistenceUnavailable("V10 formula inventory header 不一致")
        }

        let itemDescriptor = FetchDescriptor<StoredV10FormulaInventoryItem>(predicate: #Predicate { $0.documentID == documentID })
        let rows = try modelContext.fetch(itemDescriptor)
        guard rows.count == inventory.items.count else {
            throw LatticeLensError.persistenceUnavailable("V10 formula inventory item row 數量不一致")
        }
        var rowsByID: [String: StoredV10FormulaInventoryItem] = [:]
        for row in rows {
            guard rowsByID.updateValue(row, forKey: row.equationID) == nil else {
                throw LatticeLensError.persistenceUnavailable("V10 formula inventory equation ID 重複")
            }
        }
        let expectedItemStatus = inventory.isComplete ? "indexed" : "inventory_incomplete"
        for item in inventory.items {
            guard let row = rowsByID[item.equationID],
                  row.paperID == paperID, row.documentID == documentID,
                  row.documentHash == documentHash, row.inventoryHash == inventory.inventoryHash,
                  row.equationID == item.equationID, row.label == item.label,
                  row.ordinal == item.ordinal, row.sourceByteStart == item.sourceByteStart,
                  row.sourceByteEnd == item.sourceByteEnd, row.sourceTeXHash == item.normalizedTeXHash,
                  row.anchorID == item.evidenceID, row.status == expectedItemStatus,
                  try JSONDecoder.latticeLens.decode(FormulaInventoryItem.self, from: row.payload) == item else {
                throw LatticeLensError.persistenceUnavailable("V10 formula inventory item \(item.equationID) 與 immutable payload 不一致")
            }
        }
        return inventory
    }

    private func persist(_ inventory: FormulaInventory, paperID: Int) throws {
        guard !inventory.documentHash.isEmpty,
              inventory.labelledEquationCount >= inventory.items.count,
              inventory.labelledEquationCount <= FormulaInventory.maximumItems,
              Set(inventory.items.map(\.equationID)).count == inventory.items.count,
              Set(inventory.items.map(\.label)).count == inventory.items.count,
              inventory.items.allSatisfy({
                  $0.documentHash == inventory.documentHash && $0.ordinal > 0 &&
                  $0.sourceByteStart >= 0 && $0.sourceByteEnd >= $0.sourceByteStart
              }) else {
            throw LatticeLensError.persistenceUnavailable("V10 formula inventory violates its source/identity contract")
        }

        let documentID = "\(paperID):\(inventory.documentHash)"
        let inventoryID = documentID
        let encodedInventory = try JSONEncoder.latticeLens.encode(inventory)
        let status = inventory.isComplete ? "complete" : "incomplete"
        let headerDescriptor = FetchDescriptor<StoredV10FormulaInventory>(predicate: #Predicate { $0.id == inventoryID })
        if let header = try modelContext.fetch(headerDescriptor).first {
            if header.paperID != paperID { throw LatticeLensError.persistenceUnavailable("V10 formula inventory ID collision") }
            let changed = header.documentID != documentID || header.documentHash != inventory.documentHash ||
                header.inventoryHash != inventory.inventoryHash || header.parserVersion != inventory.parserVersion ||
                header.status != status || header.payload != encodedInventory
            if changed {
                header.documentID = documentID
                header.documentHash = inventory.documentHash
                header.inventoryHash = inventory.inventoryHash
                header.parserVersion = inventory.parserVersion
                header.status = status
                header.payload = encodedInventory
                header.updatedAt = Date()
            }
        } else {
            modelContext.insert(StoredV10FormulaInventory(id: inventoryID, paperID: paperID,
                documentID: documentID, documentHash: inventory.documentHash,
                inventoryHash: inventory.inventoryHash, parserVersion: inventory.parserVersion,
                status: status, payload: encodedInventory))
        }

        let storedRows = try modelContext.fetch(FetchDescriptor<StoredV10FormulaInventoryItem>(
            predicate: #Predicate { $0.documentID == documentID }))
        var priorRows: [String: StoredV10FormulaInventoryItem] = [:]
        for row in storedRows {
            guard priorRows.updateValue(row, forKey: row.equationID) == nil else {
                throw LatticeLensError.persistenceUnavailable("V10 formula inventory equation ID 重複")
            }
        }
        let itemStatus = inventory.isComplete ? "indexed" : "inventory_incomplete"
        for item in inventory.items {
            let itemID = "\(documentID):\(item.equationID)"
            let itemPayload = try JSONEncoder.latticeLens.encode(item)
            if let row = priorRows.removeValue(forKey: item.equationID) {
                guard row.id == itemID else { throw LatticeLensError.persistenceUnavailable("V10 formula item stable ID collision") }
                if row.paperID != paperID { row.paperID = paperID }
                if row.documentID != documentID { row.documentID = documentID }
                if row.documentHash != inventory.documentHash { row.documentHash = inventory.documentHash }
                if row.inventoryHash != inventory.inventoryHash { row.inventoryHash = inventory.inventoryHash }
                if row.label != item.label { row.label = item.label }
                if row.ordinal != item.ordinal { row.ordinal = item.ordinal }
                if row.sourceByteStart != item.sourceByteStart { row.sourceByteStart = item.sourceByteStart }
                if row.sourceByteEnd != item.sourceByteEnd { row.sourceByteEnd = item.sourceByteEnd }
                if row.sourceTeXHash != item.normalizedTeXHash { row.sourceTeXHash = item.normalizedTeXHash }
                if row.anchorID != item.evidenceID { row.anchorID = item.evidenceID }
                if row.status != itemStatus { row.status = itemStatus }
                if row.payload != itemPayload { row.payload = itemPayload }
            } else {
                modelContext.insert(StoredV10FormulaInventoryItem(id: itemID, paperID: paperID,
                    documentID: documentID, documentHash: inventory.documentHash,
                    inventoryHash: inventory.inventoryHash, equationID: item.equationID,
                    label: item.label, ordinal: item.ordinal, sourceByteStart: item.sourceByteStart,
                    sourceByteEnd: item.sourceByteEnd, sourceTeXHash: item.normalizedTeXHash,
                    anchorID: item.evidenceID, status: itemStatus, payload: itemPayload))
            }
        }
        for stale in priorRows.values { modelContext.delete(stale) }
        try modelContext.save()
    }
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
            // Keep unchanged postings in place. A common token may be present
            // in most of a large library; removing and reinserting every token
            // for a one-note edit would decode and rewrite that whole posting
            // set even when only one note-specific token changed.
            let previousRows: [StoredV9PaperSearchTerm]
            if knownNewPaperIDs.contains(paperID) {
                previousRows = []
            } else {
                let previousDescriptor = FetchDescriptor<StoredV9PaperSearchTerm>(predicate: #Predicate { $0.paperID == paperID })
                previousRows = try context.fetch(previousDescriptor)
            }
            let oldTerms = Set(previousRows.map(\.token))

            let paperDescriptor = FetchDescriptor<StoredV8Paper>(predicate: #Predicate { $0.literatureID == paperID })
            guard let paper = try context.fetch(paperDescriptor).first else {
                for row in previousRows { context.delete(row) }
                for term in oldTerms { try remove(paperID: paperID, from: term, in: context, at: date) }
                continue
            }
            let newTerms = try terms(for: paper, in: context)
            let removedTerms = oldTerms.subtracting(newTerms)
            let addedTerms = newTerms.subtracting(oldTerms)
            for row in previousRows where removedTerms.contains(row.token) {
                context.delete(row)
            }
            for term in removedTerms {
                try remove(paperID: paperID, from: term, in: context, at: date)
            }
            for term in addedTerms {
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

    private static func terms(for paper: StoredV8Paper, in context: ModelContext) throws -> Set<String> {
        let paperID = paper.literatureID
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
actor V8TypedLibraryStore: LibraryStoring, EvidenceInsightPublicationStoring, CategoryProfileStoring, FormulaInventoryStoring, FormulaJobStoring, AppFixtureLargeSeedCommitting {
    private var availabilityFailure: String?
    /// Row-level decode problems are recoverable: the readable rows remain
    /// visible and the next explicit sync must be allowed to repair them.
    /// Keep this separate from `availabilityFailure`, which is reserved for
    /// structural store failures that genuinely require read-only mode.
    private var availabilityWarning: String?
    private var lastKnownGoodSnapshot: LibrarySnapshot?
    /// V8-only test/migration containers remain valid compatibility inputs.
    /// The normal application factory opens V9, where these entities exist.
    private var v9SearchIndexAvailability: Bool?

    func formulaJob(id: String) async throws -> FormulaDerivationCheckpoint? {
        let jobs = V10FormulaJobStore(modelContainer: modelContainer)
        return try await jobs.formulaJob(id: id)
    }

    func saveFormulaJob(_ checkpoint: FormulaDerivationCheckpoint) async throws {
        let jobs = V10FormulaJobStore(modelContainer: modelContainer)
        try await jobs.saveFormulaJob(checkpoint)
    }

    func saveFormulaJobWithValidation(_ checkpoint: FormulaDerivationCheckpoint,
                                     report: FormulaCoverageReport) async throws {
        let jobs = V10FormulaJobStore(modelContainer: modelContainer)
        try await jobs.saveFormulaJobWithValidation(checkpoint, report: report)
    }

    func formulaValidationReport(jobID: String) async throws -> FormulaCoverageReport? {
        let jobs = V10FormulaJobStore(modelContainer: modelContainer)
        return try await jobs.formulaValidationReport(jobID: jobID)
    }

    func readyEvidenceInsightPublication(cacheKey: String) async throws -> ReadyEvidenceInsightPublication? {
        let jobs = V10FormulaJobStore(modelContainer: modelContainer)
        return try await jobs.readyEvidenceInsightPublication(cacheKey: cacheKey)
    }

    func saveReadyEvidenceInsightPublication(_ publication: ReadyEvidenceInsightPublication) async throws {
        let jobs = V10FormulaJobStore(modelContainer: modelContainer)
        try await jobs.saveReadyEvidenceInsightPublication(publication)
    }

    func removeReadyEvidenceInsightPublication(cacheKey: String) async throws {
        let jobs = V10FormulaJobStore(modelContainer: modelContainer)
        try await jobs.removeReadyEvidenceInsightPublication(cacheKey: cacheKey)
    }

    func loadCategoryProfile() async throws -> CategoryProfile? {
        let profiles = V10CategoryProfileStore(modelContainer: modelContainer)
        return try await profiles.loadCategoryProfile()
    }

    func saveCategoryProfile(_ profile: CategoryProfile) async throws {
        let profiles = V10CategoryProfileStore(modelContainer: modelContainer)
        try await profiles.saveCategoryProfile(profile)
    }

    func saveFormulaInventory(_ inventory: FormulaInventory, paperID: Int) async throws {
        let inventories = V10FormulaInventoryStore(modelContainer: modelContainer)
        try await inventories.saveFormulaInventory(inventory, paperID: paperID)
    }

    func formulaInventory(paperID: Int, documentHash: String) async throws -> FormulaInventory? {
        let inventories = V10FormulaInventoryStore(modelContainer: modelContainer)
        return try await inventories.formulaInventory(paperID: paperID, documentHash: documentHash)
    }

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

    func exportResearchBundle(to destination: URL, includePDFBytes: Bool,
                              pdfRoot: URL?) throws -> V4BundleManifest {
        let value = try checkedSnapshot()
        return try V4ResearchBundle.exportV2(snapshot: value, typedContext: modelContext,
                                             to: destination, includePDFBytes: includePDFBytes,
                                             pdfRoot: pdfRoot, appVersion: "LatticeLens-2.0.0")
    }

    func snapshotResult() -> LibrarySnapshotReadResult {
        do {
            let value = try checkedSnapshot(); lastKnownGoodSnapshot = value
            return LibrarySnapshotReadResult(state: .ready, snapshot: value, message: nil)
        } catch {
            let reason = availabilityFailure ?? availabilityWarning ?? "V8 typed store 读取失败；保留最后一次有效资料库"
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
            // Decode author rows independently.  A single malformed legacy
            // row must not turn the whole sidebar into an empty projection;
            // the self-author row and every other readable row remain useful
            // for browsing and for an explicit retry.
            let rows = try modelContext.fetch(FetchDescriptor<StoredV8Author>())
            let authors = rows.compactMap { row -> Author? in
                do { return try row.decoded() }
                catch {
                    availabilityWarning = "V8 typed store 存在无法解码的作者行；已跳过该行"
                    return nil
                }
            }

            // Generation payloads are audit/checkpoint metadata, not a
            // prerequisite for painting author rows.  Decode them one by one
            // and retain the most recent valid completed membership.  This is
            // especially important after an interrupted upgrade where an old
            // generation may contain fields unknown to the current decoder.
            let generationRows = try modelContext.fetch(FetchDescriptor<StoredV8AuthorIndexGeneration>())
            var completed: [AuthorIndexGeneration] = []
            for row in generationRows {
                do {
                    let generation = try JSONDecoder.latticeLens.decode(AuthorIndexGeneration.self, from: row.generationData)
                    if generation.state == .completed { completed.append(generation) }
                } catch {
                    availabilityWarning = "V8 typed store 存在无法解码的作者索引 checkpoint；已保留可读作者行"
                }
            }
            let activeMembership = completed.max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }?.activeMembership
            return LibraryAuthorSidebarProjection(authors: authors, activeMembership: activeMembership)
        } catch {
            availabilityFailure = "V8 typed store 作者投影读取失败；资料库保持只读"
            return LibraryAuthorSidebarProjection(authors: [], activeMembership: nil)
        }
    }

    /// Read only the compact generation rows for the progress capsule.  Do
    /// not materialize the complete compatibility snapshot on every sidebar
    /// refresh (the author index can deliver thousands of queue outcomes).
    func authorIndexProgressState() -> SyncCheckpointState? {
        do {
            let rows = try modelContext.fetch(FetchDescriptor<StoredV8AuthorIndexGeneration>())
            return rows.compactMap { row -> AuthorIndexGeneration? in
                try? JSONDecoder.latticeLens.decode(AuthorIndexGeneration.self, from: row.generationData)
            }
            .max { $0.startedAt < $1.startedAt }?.state
        } catch {
            availabilityWarning = "V8 typed store 作者索引状态读取失败；继续显示可读作者行"
            return nil
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
                do {
                    if let paper = try typedPaper(id: link.paperID) { values.append(paper) }
                } catch {
                    // One corrupt/legacy paper payload should not hide every
                    // other paper for this author.  Keep the readable rows
                    // visible and let the next explicit sync repair the bad
                    // record instead of presenting a blank timeline.
                    availabilityWarning = "V8 typed store 存在无法解码的论文行；已跳过该行"
                }
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

    func visionArtifact(cacheKey: String) -> VisionArtifact? {
        do {
            let descriptor = FetchDescriptor<StoredV8AIArtifact>(predicate: #Predicate { $0.cacheKey == cacheKey })
            guard let row = try modelContext.fetch(descriptor).first, row.workflowKind == "vision" else { return nil }
            return try JSONDecoder.latticeLens.decode(VisionArtifact.self, from: row.artifactData)
        } catch {
            availabilityFailure = "V8 typed store vision 缓存读取失败；资料库保持只读"
            return nil
        }
    }

    func paperContext(paperID: Int, insightCacheKey: String?) async -> LibraryPaperContextProjection {
        do {
            let paper = try typedPaper(id: paperID)
            var documents = try modelContext.fetch(FetchDescriptor<StoredV8FullTextDocument>(predicate: #Predicate { $0.paperID == paperID }))
                .map { try $0.decoded() }
            // The inventory hash is intentionally transient on the V9-compatible
            // document entity. Rehydrate it from the canonical V10 inventory for
            // complete HTML indexes before analysis payloads are constructed.
            for index in documents.indices {
                var document = documents[index]
                guard document.sourceKind == .arxivHTML,
                      document.numberedEquationIndexComplete == true else { continue }
                do {
                    guard let inventory = try await formulaInventory(paperID: document.paperID,
                                                                      documentHash: document.sha256),
                          inventory.isComplete,
                          inventory.documentHash == document.sha256,
                          inventory.parserVersion == document.numberedEquationIndexVersion else {
                        document.numberedEquationIndexComplete = false
                        document.numberedEquationInventoryHash = nil
                        document.numberedEquationIndexFailure = "重開後缺少完整且匹配的 V10 source inventory；已按不完整處理。"
                        documents[index] = document
                        continue
                    }
                    document.numberedEquationInventoryHash = inventory.inventoryHash
                } catch {
                    document.numberedEquationIndexComplete = false
                    document.numberedEquationInventoryHash = nil
                    document.numberedEquationIndexFailure = "重開後無法驗證 V10 source inventory；已按不完整處理。"
                }
                documents[index] = document
            }
            let chunks = try modelContext.fetch(FetchDescriptor<StoredV8EvidenceChunk>(predicate: #Predicate { $0.paperID == paperID }))
                .map { $0.decoded() }
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
                evidenceChunks: chunks,
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
            return LibraryPaperContextProjection(paper: nil, insight: nil, fullTextDocuments: [], evidenceChunks: [], evidenceAnchors: [],
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

    /// Publishes only a pristine, isolated UI-fixture corpus. Existing library
    /// data is never merged or cleared here; the caller's full snapshot check
    /// is repeated inside the repository actor before any rows are inserted.
    func commitLargeFixtureSeed(_ seed: AppFixtureLargeSeed) throws {
        try requireWritable()
        guard AppFixtureLargeData.isPristineStore(try checkedSnapshot()) else {
            throw LatticeLensError.persistenceUnavailable("large UI fixture 只能写入空的隔离 store；现有资料已保留")
        }
        guard Set(seed.authors.map(\.recid)).count == seed.authors.count,
              Set(seed.papers.map(\.literatureID)).count == seed.papers.count,
              Set(seed.tags.map(\.id)).count == seed.tags.count,
              Set(seed.collections.map(\.id)).count == seed.collections.count else {
            throw LatticeLensError.schemaViolation("large UI fixture 包含重复的稳定 ID")
        }

        do {
            for author in seed.authors {
                modelContext.insert(try StoredV8Author(author))
                if let hIndex = author.hIndex {
                    modelContext.insert(try StoredV8HIndexSnapshot(hIndex))
                }
            }
            for (position, paper) in seed.papers.enumerated() {
                modelContext.insert(try StoredV8Paper(paper))
                modelContext.insert(StoredV8PaperAuthorLink(PaperAuthorLink(
                    paperID: paper.literatureID, authorRecid: seed.authorRecid, position: position)))
                if let citationCount = paper.citationCount {
                    modelContext.insert(StoredV8CitationSnapshot(CitationSnapshot(
                        paperID: paper.literatureID, citationCount: citationCount, fetchedAt: Date())))
                }
            }
            for tag in seed.tags { modelContext.insert(StoredV8Tag(tag)) }
            for link in seed.tagLinks { modelContext.insert(StoredV8PaperTagLink(link)) }
            for collection in seed.collections { modelContext.insert(StoredV8Collection(collection)) }
            for link in seed.collectionLinks { modelContext.insert(StoredV8PaperCollectionLink(link)) }
            for checkpoint in seed.checkpoints { modelContext.insert(try StoredV8SyncCheckpoint(checkpoint)) }
            for query in seed.savedQueries { modelContext.insert(try StoredV8SavedQuery(query)) }
            for event in seed.radarEvents { modelContext.insert(try StoredV8RadarEvent(event)) }
            for workspace in seed.workspaces { modelContext.insert(try StoredV8Workspace(workspace)) }
            for anchor in seed.evidenceAnchors { modelContext.insert(StoredV8EvidenceAnchor(anchor)) }

            // This rebuild fetches the supporting rows once and commits the
            // fixture plus its derived V9 projection with one SQLite save.
            try V9TypedSearchIndex.rebuild(in: modelContext)
        } catch {
            modelContext.rollback()
            throw error
        }
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
            if let row = existing.first {
                row.paperID = note.paperID
                row.body = note.body
                row.createdAt = note.createdAt
                row.updatedAt = note.updatedAt
                for duplicate in existing.dropFirst() { modelContext.delete(duplicate) }
            } else {
                modelContext.insert(StoredV8Note(note))
            }
            try refreshV9SearchIndex(affected); try modelContext.save()
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
    func saveEvidenceInsight(_ artifact: EvidenceInsightArtifact) throws {
        try requireWritable()
        do {
            try replaceAIArtifact(cacheKey: artifact.cacheKey, paperID: artifact.paperID,
                                  kind: "evidenceInsight", createdAt: artifact.createdAt, value: artifact)
        } catch {
            modelContext.rollback()
            throw error
        }
    }
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
        catch {
            // Compatibility snapshots decode many independent legacy payloads
            // at once.  A malformed optional row can make that projection
            // unavailable, but it must not poison the typed store: bounded
            // row reads still work and an explicit refresh must be able to
            // replace the bad record.  Structural failures are still surfaced
            // to the caller through the read-only snapshot result.
            availabilityWarning = "V8 typed store 存在无法解码的兼容行；已保留可读投影，刷新可继续修复"
            throw LatticeLensError.persistenceUnavailable(availabilityWarning!)
        }
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
        let sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard sourceValues.isSymbolicLink != true else { throw V4LocalError.pathEscape }
        if fileManager.fileExists(atPath: destinationRoot.path) {
            let destinationValues = try destinationRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard destinationValues.isSymbolicLink != true, destinationValues.isDirectory == true else {
                throw V4LocalError.pathEscape
            }
        }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let backupID = UUID(); let destination = destinationRoot.appendingPathComponent(backupID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var files: [V4StoreBackupFile] = []
        let sourceIsDirectory = sourceValues.isDirectory == true
        if sourceIsDirectory {
            let enumerator = fileManager.enumerator(at: source,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            while let url = enumerator?.nextObject() as? URL {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw V4LocalError.pathEscape }
                guard values.isRegularFile == true else { continue }
                let relative = url.path.replacingOccurrences(of: source.path + "/", with: "")
                let ownedSource = try V4OwnedPath.canonicalFile(named: relative, root: source, fileManager: fileManager)
                guard ownedSource.resolvingSymlinksInPath().standardizedFileURL
                        == url.resolvingSymlinksInPath().standardizedFileURL else { throw V4LocalError.pathEscape }
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
                let values = try member.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true else { throw V4LocalError.pathEscape }
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

// MARK: - V9/V10 to 2.0 staged activation

/// The only path that may publish a 2.0 store. The existing store is first
/// copied as a complete SQLite family (or package) into a verified backup;
/// schema migration runs only against a second, disposable staging copy.
enum V10StoreMigrationPhase: String, Codable, Sendable, CaseIterable {
    case prepared, backedUp, staged, categoryMigrated, searchIndexReady
    case migrated, verified, activated, failed, rolledBack
    case legacyFormulaIndexBuilt = "formulaIndexBuilt"
}

enum V10StoreMigrationCrashPoint: Sendable, Equatable {
    case afterBackup, duringCopy, categoryMigration, searchIndexReady
    case afterSemanticVerification, beforeActivation, afterActivation
}

enum V10StoreMigrationError: Error, Equatable, Sendable {
    case injectedCrash(V10StoreMigrationCrashPoint)
    case sourceMissing, invalidSource, activeDescriptorExists, storeOwnerBusy
    case invalidJournal, invalidDescriptor, backupMismatch, semanticMismatch
}

/// Store-family hashes and source-semantic counts, without source paths or
/// library text. `manifestHash` covers all fields except itself.
struct V10MigrationBackupManifest: Codable, Sendable {
    let id: UUID
    let sourceSchemaVersion: Int
    let targetSchemaVersion: Int
    let createdAt: Date
    let recordCounts: [String: Int]
    let stableIDHash: String
    let semanticSummary: V10StoreSemanticSummary?
    let storeFamilyManifest: V4StoreBackupManifest
    let manifestHash: String

    private struct HashPayload: Encodable {
        let id: UUID
        let sourceSchemaVersion: Int
        let targetSchemaVersion: Int
        let createdAt: Date
        let recordCounts: [String: Int]
        let stableIDHash: String
        let semanticSummary: V10StoreSemanticSummary?
        let storeFamilyManifest: V4StoreBackupManifest
    }

    init(id: UUID, sourceSchemaVersion: Int, targetSchemaVersion: Int, createdAt: Date,
         summary: V10StoreSemanticSummary, storeFamilyManifest: V4StoreBackupManifest) throws {
        self.id = id
        self.sourceSchemaVersion = sourceSchemaVersion
        self.targetSchemaVersion = targetSchemaVersion
        self.createdAt = createdAt
        recordCounts = summary.recordCounts
        stableIDHash = summary.stableIDHash
        semanticSummary = summary
        self.storeFamilyManifest = storeFamilyManifest
        manifestHash = StableHash.sha256(try JSONEncoder.latticeLens.encode(HashPayload(
            id: id, sourceSchemaVersion: sourceSchemaVersion, targetSchemaVersion: targetSchemaVersion,
            createdAt: createdAt, recordCounts: summary.recordCounts, stableIDHash: summary.stableIDHash,
            semanticSummary: summary,
            storeFamilyManifest: storeFamilyManifest)))
    }

    func verifiesHash() throws -> Bool {
        let payload = HashPayload(id: id, sourceSchemaVersion: sourceSchemaVersion,
            targetSchemaVersion: targetSchemaVersion, createdAt: createdAt, recordCounts: recordCounts,
            stableIDHash: stableIDHash, semanticSummary: semanticSummary,
            storeFamilyManifest: storeFamilyManifest)
        return StableHash.sha256(try JSONEncoder.latticeLens.encode(payload)) == manifestHash
    }
}

struct V10StoreMigrationJournal: Codable, Sendable {
    let id: UUID
    let sourceStoreName: String
    let stagingStoreName: String
    let descriptorName: String
    let sourceSchemaVersion: Int
    let targetSchemaVersion: Int
    let backupManifestID: UUID
    let backupManifestHash: String
    let sourceSummary: V10StoreSemanticSummary
    let startedAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var phase: V10StoreMigrationPhase
    var targetSummary: V10StoreSemanticSummary?
    var errorCategory: String?
    let semanticFormatVersion: Int
    let legacySourceSummary: V8StoreSemanticSummary?
    let legacyTargetSummary: V8StoreSemanticSummary?

    private enum CodingKeys: String, CodingKey {
        case id, sourceStoreName, stagingStoreName, descriptorName, sourceSchemaVersion, targetSchemaVersion
        case backupManifestID, backupManifestHash, sourceSummary, startedAt, updatedAt, completedAt, phase
        case targetSummary, errorCategory, semanticFormatVersion, legacySourceSummary, legacyTargetSummary
    }

    init(id: UUID, sourceStoreName: String, stagingStoreName: String, descriptorName: String,
         sourceSchemaVersion: Int, targetSchemaVersion: Int, backupManifestID: UUID,
         backupManifestHash: String, sourceSummary: V10StoreSemanticSummary, startedAt: Date,
         updatedAt: Date, completedAt: Date?, phase: V10StoreMigrationPhase,
         targetSummary: V10StoreSemanticSummary?, errorCategory: String?) {
        self.id = id
        self.sourceStoreName = sourceStoreName
        self.stagingStoreName = stagingStoreName
        self.descriptorName = descriptorName
        self.sourceSchemaVersion = sourceSchemaVersion
        self.targetSchemaVersion = targetSchemaVersion
        self.backupManifestID = backupManifestID
        self.backupManifestHash = backupManifestHash
        self.sourceSummary = sourceSummary
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.phase = phase
        self.targetSummary = targetSummary
        self.errorCategory = errorCategory
        semanticFormatVersion = 2
        legacySourceSummary = nil
        legacyTargetSummary = nil
    }

    private static func bridgeLegacy(_ summary: V8StoreSemanticSummary) -> V10StoreSemanticSummary {
        V10StoreSemanticSummary(domainSummary: summary,
            serializedLibraryHash: "legacy-v8-summary:\(summary.stableIDHash)",
            typedRowCounts: [:], typedIdentityHash: StableHash.sha256(""),
            typedContentHash: StableHash.sha256(""))
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        sourceStoreName = try values.decode(String.self, forKey: .sourceStoreName)
        stagingStoreName = try values.decode(String.self, forKey: .stagingStoreName)
        descriptorName = try values.decode(String.self, forKey: .descriptorName)
        sourceSchemaVersion = try values.decode(Int.self, forKey: .sourceSchemaVersion)
        targetSchemaVersion = try values.decode(Int.self, forKey: .targetSchemaVersion)
        backupManifestID = try values.decode(UUID.self, forKey: .backupManifestID)
        backupManifestHash = try values.decode(String.self, forKey: .backupManifestHash)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        completedAt = try values.decodeIfPresent(Date.self, forKey: .completedAt)
        phase = try values.decode(V10StoreMigrationPhase.self, forKey: .phase)
        errorCategory = try values.decodeIfPresent(String.self, forKey: .errorCategory)

        if let current = try? values.decode(V10StoreSemanticSummary.self, forKey: .sourceSummary) {
            sourceSummary = current
            legacySourceSummary = try values.decodeIfPresent(V8StoreSemanticSummary.self, forKey: .legacySourceSummary)
            semanticFormatVersion = try values.decodeIfPresent(Int.self, forKey: .semanticFormatVersion) ?? 2
        } else {
            let legacy = try values.decode(V8StoreSemanticSummary.self, forKey: .sourceSummary)
            sourceSummary = Self.bridgeLegacy(legacy)
            legacySourceSummary = legacy
            semanticFormatVersion = 1
        }

        if let current = try? values.decode(V10StoreSemanticSummary.self, forKey: .targetSummary) {
            targetSummary = current
            legacyTargetSummary = try values.decodeIfPresent(V8StoreSemanticSummary.self, forKey: .legacyTargetSummary)
        } else if let legacy = try? values.decode(V8StoreSemanticSummary.self, forKey: .targetSummary) {
            targetSummary = Self.bridgeLegacy(legacy)
            legacyTargetSummary = legacy
        } else {
            targetSummary = nil
            legacyTargetSummary = try values.decodeIfPresent(V8StoreSemanticSummary.self, forKey: .legacyTargetSummary)
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(sourceStoreName, forKey: .sourceStoreName)
        try values.encode(stagingStoreName, forKey: .stagingStoreName)
        try values.encode(descriptorName, forKey: .descriptorName)
        try values.encode(sourceSchemaVersion, forKey: .sourceSchemaVersion)
        try values.encode(targetSchemaVersion, forKey: .targetSchemaVersion)
        try values.encode(backupManifestID, forKey: .backupManifestID)
        try values.encode(backupManifestHash, forKey: .backupManifestHash)
        try values.encode(sourceSummary, forKey: .sourceSummary)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encodeIfPresent(completedAt, forKey: .completedAt)
        try values.encode(phase, forKey: .phase)
        try values.encodeIfPresent(targetSummary, forKey: .targetSummary)
        try values.encodeIfPresent(errorCategory, forKey: .errorCategory)
        try values.encode(semanticFormatVersion, forKey: .semanticFormatVersion)
        try values.encodeIfPresent(legacySourceSummary, forKey: .legacySourceSummary)
        try values.encodeIfPresent(legacyTargetSummary, forKey: .legacyTargetSummary)
    }
}

struct V10ActiveStoreDescriptor: Codable, Sendable {
    let runID: UUID
    let storeName: String
    let schemaVersion: Int
    let backupManifestID: UUID
    let backupManifestHash: String
    let semanticHash: String
    let activatedAt: Date
}

struct V10StoreMigrationOutcome: Sendable {
    let journalURL: URL
    let journal: V10StoreMigrationJournal
    let backupManifest: V10MigrationBackupManifest
    let activeStoreURL: URL
}

/// Semantic receipt spanning the normalized V8 domain projection and all
/// V10 typed rows. The library snapshot hash checks row contents and links;
/// the typed fingerprints cover formula/category/job state that is not part
/// of that compatibility projection.
private enum V10CanonicalLibraryFingerprint {
    private static let dictionaryFields: Set<String> = [
        "authors", "papers", "insights", "evidenceInsights", "checkpoints", "readingStates",
        "notes", "tags", "collections", "citationSnapshots", "bibTeXRecords", "fullTextDocuments",
        "evidenceChunks", "evidenceAnchors", "visionArtifacts", "syncBatches", "authorIndexGenerations",
        "paperRevisionSnapshots", "radarEvents", "savedInspireQueries", "syncBatchesV3", "syncJobEvents",
        "contentBlobs", "orphanedBlobDeletions", "documentReferences", "userEvidenceAnchors",
        "notebookEntries", "workspaces", "physicsContracts", "physicsContractCells", "citationEdges",
        "coauthorEdges", "exportRecords", "cloudSyncStates", "conflictCopies", "importedBibliographies",
        "importConflicts", "migrationJournal",
    ]

    private static let setFields: Set<String> = [
        "paperAuthorLinks", "paperTags", "collectionPapers", "notebookAnchorLinks",
        "workspacePaperLinks", "quarantinedEvidenceIDs",
    ]

    static let formatVersion = 3

    static func hash(snapshot: LibrarySnapshot, encoder: JSONEncoder) throws -> String {
        let encodedSnapshot = try encoder.encode(snapshot)
        let json = try JSONSerialization.jsonObject(with: encodedSnapshot)
        let canonicalObject = try normalize(json, path: [])
        let canonicalJSON = try JSONSerialization.data(withJSONObject: canonicalObject,
            options: [.sortedKeys, .withoutEscapingSlashes])
        var versionedBytes = Data("latticelens-library-snapshot-v3\n".utf8)
        versionedBytes.append(canonicalJSON)
        return StableHash.sha256(versionedBytes)
    }

    private static func normalize(_ value: Any, path: [String]) throws -> Any {
        if path.count == 1, dictionaryFields.contains(path[0]) {
            let rawEntries: [(key: Any, value: Any)]
            if let object = value as? [String: Any] {
                rawEntries = object.map { (key: $0.key, value: $0.value) }
            } else if let pairs = value as? [Any], pairs.count.isMultiple(of: 2) {
                rawEntries = stride(from: 0, to: pairs.count, by: 2).map {
                    (key: pairs[$0], value: pairs[$0 + 1])
                }
            } else {
                throw V10StoreMigrationError.semanticMismatch
            }

            let entries = try rawEntries.map { entry in
                (key: try normalize(entry.key, path: path + ["$mapKey"]),
                 keyBytes: try canonicalJSON(for: entry.key),
                 value: try normalize(entry.value, path: path + ["$mapValue"]))
            }.sorted { $0.keyBytes.lexicographicallyPrecedes($1.keyBytes) }
            return entries.map { ["key": $0.key, "value": $0.value] }
        }

        if isSet(path), let values = value as? [Any] {
            let entries = try values.map { item in
                let normalized = try normalize(item, path: path + ["$setValue"])
                return (value: normalized, bytes: try canonicalJSON(for: normalized))
            }.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
            return entries.map(\.value)
        }

        if let object = value as? [String: Any] {
            var normalized = [String: Any](minimumCapacity: object.count)
            for key in object.keys.sorted() {
                guard let member = object[key] else { continue }
                normalized[key] = try normalize(member, path: path + [key])
            }
            return normalized
        }

        if let values = value as? [Any] {
            return try values.map { try normalize($0, path: path + ["$arrayValue"]) }
        }
        return value
    }

    private static func isSet(_ path: [String]) -> Bool {
        if path.count == 1, setFields.contains(path[0]) { return true }
        return path == ["authors", "$mapValue", "arxivCategories"] ||
            path == ["checkpoints", "$mapValue", "activeMembership"] ||
            path == ["checkpoints", "$mapValue", "stagingMembership"] ||
            path == ["authorIndexGenerations", "$mapValue", "activeMembership"] ||
            path == ["authorIndexGenerations", "$mapValue", "stagingMembership"]
    }

    private static func canonicalJSON(for value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value,
            options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }
}

struct V10StoreSemanticSummary: Codable, Equatable, Sendable {
    let domainSummary: V8StoreSemanticSummary
    let serializedLibraryHash: String
    let serializedLibraryHashFormatVersion: Int
    let typedRowCounts: [String: Int]
    let typedIdentityHash: String
    let typedContentHash: String
    let typedFamilyIdentityHashes: [String: String]
    let typedFamilyContentHashes: [String: String]
    let searchIndexStateRowHashes: [String: String]
    let categoryProfileCategories: [String]?
    let hasLegacyCategoryCheckpoint: Bool
    let legacyCategoryCheckpointCount: Int
    let legacyCheckpointInvalidationCount: Int?

    private enum CodingKeys: String, CodingKey {
        case domainSummary, serializedLibraryHash, serializedLibraryHashFormatVersion
        case typedRowCounts, typedIdentityHash, typedContentHash
        case typedFamilyIdentityHashes, typedFamilyContentHashes
        case searchIndexStateRowHashes
        case categoryProfileCategories, hasLegacyCategoryCheckpoint, legacyCategoryCheckpointCount
        case legacyCheckpointInvalidationCount
    }

    init(domainSummary: V8StoreSemanticSummary, serializedLibraryHash: String,
         serializedLibraryHashFormatVersion: Int = 1,
         typedRowCounts: [String: Int], typedIdentityHash: String, typedContentHash: String,
         typedFamilyIdentityHashes: [String: String] = [:], typedFamilyContentHashes: [String: String] = [:],
         searchIndexStateRowHashes: [String: String] = [:],
         categoryProfileCategories: [String]? = nil, hasLegacyCategoryCheckpoint: Bool = false,
         legacyCategoryCheckpointCount: Int = 0,
         legacyCheckpointInvalidationCount: Int? = nil) {
        self.domainSummary = domainSummary
        self.serializedLibraryHash = serializedLibraryHash
        self.serializedLibraryHashFormatVersion = serializedLibraryHashFormatVersion
        self.typedRowCounts = typedRowCounts
        self.typedIdentityHash = typedIdentityHash
        self.typedContentHash = typedContentHash
        self.typedFamilyIdentityHashes = typedFamilyIdentityHashes
        self.typedFamilyContentHashes = typedFamilyContentHashes
        self.searchIndexStateRowHashes = searchIndexStateRowHashes
        self.categoryProfileCategories = categoryProfileCategories
        self.hasLegacyCategoryCheckpoint = hasLegacyCategoryCheckpoint
        self.legacyCategoryCheckpointCount = legacyCategoryCheckpointCount
        self.legacyCheckpointInvalidationCount = legacyCheckpointInvalidationCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(domainSummary: try values.decode(V8StoreSemanticSummary.self, forKey: .domainSummary),
            serializedLibraryHash: try values.decode(String.self, forKey: .serializedLibraryHash),
            serializedLibraryHashFormatVersion: try values.decodeIfPresent(Int.self,
                forKey: .serializedLibraryHashFormatVersion) ?? 1,
            typedRowCounts: try values.decode([String: Int].self, forKey: .typedRowCounts),
            typedIdentityHash: try values.decode(String.self, forKey: .typedIdentityHash),
            typedContentHash: try values.decode(String.self, forKey: .typedContentHash),
            typedFamilyIdentityHashes: try values.decodeIfPresent([String: String].self, forKey: .typedFamilyIdentityHashes) ?? [:],
            typedFamilyContentHashes: try values.decodeIfPresent([String: String].self, forKey: .typedFamilyContentHashes) ?? [:],
            searchIndexStateRowHashes: try values.decodeIfPresent([String: String].self,
                forKey: .searchIndexStateRowHashes) ?? [:],
            categoryProfileCategories: try values.decodeIfPresent([String].self, forKey: .categoryProfileCategories),
            hasLegacyCategoryCheckpoint: try values.decodeIfPresent(Bool.self, forKey: .hasLegacyCategoryCheckpoint) ?? false,
            legacyCategoryCheckpointCount: try values.decodeIfPresent(Int.self, forKey: .legacyCategoryCheckpointCount) ?? 0,
            legacyCheckpointInvalidationCount: try values.decodeIfPresent(Int.self, forKey: .legacyCheckpointInvalidationCount))
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(domainSummary, forKey: .domainSummary)
        try values.encode(serializedLibraryHash, forKey: .serializedLibraryHash)
        if serializedLibraryHashFormatVersion > 1 {
            try values.encode(serializedLibraryHashFormatVersion, forKey: .serializedLibraryHashFormatVersion)
        }
        try values.encode(typedRowCounts, forKey: .typedRowCounts)
        try values.encode(typedIdentityHash, forKey: .typedIdentityHash)
        try values.encode(typedContentHash, forKey: .typedContentHash)
        try values.encode(typedFamilyIdentityHashes, forKey: .typedFamilyIdentityHashes)
        try values.encode(typedFamilyContentHashes, forKey: .typedFamilyContentHashes)
        if !searchIndexStateRowHashes.isEmpty {
            try values.encode(searchIndexStateRowHashes, forKey: .searchIndexStateRowHashes)
        }
        try values.encodeIfPresent(categoryProfileCategories, forKey: .categoryProfileCategories)
        try values.encode(hasLegacyCategoryCheckpoint, forKey: .hasLegacyCategoryCheckpoint)
        try values.encode(legacyCategoryCheckpointCount, forKey: .legacyCategoryCheckpointCount)
        try values.encodeIfPresent(legacyCheckpointInvalidationCount, forKey: .legacyCheckpointInvalidationCount)
    }

    var recordCounts: [String: Int] {
        var result = domainSummary.counts
        for (name, count) in typedRowCounts { result["typed.\(name)"] = count }
        return result
    }

    var stableIDHash: String {
        var components = [domainSummary.stableIDHash, serializedLibraryHash,
                          typedIdentityHash, typedContentHash,
                          StableHash.sha256(typedFamilyIdentityHashes.sorted { $0.key < $1.key }
                            .map { "\($0.key):\($0.value)" }.joined(separator: "|")),
                          StableHash.sha256(typedFamilyContentHashes.sorted { $0.key < $1.key }
                            .map { "\($0.key):\($0.value)" }.joined(separator: "|")),
                          categoryProfileCategories?.joined(separator: ",") ?? "no-category-profile",
                          String(hasLegacyCategoryCheckpoint), String(legacyCategoryCheckpointCount),
                          legacyCheckpointInvalidationCount.map(String.init) ?? "no-invalidation-count"]
        if serializedLibraryHashFormatVersion > 1 {
            components.insert("semantic-summary-v\(serializedLibraryHashFormatVersion)", at: 0)
        }
        return StableHash.sha256(components.joined(separator: "|"))
    }

    func preservesDomainAndTypedRows(in target: V10StoreSemanticSummary, sourceSchemaVersion: Int) -> Bool {
        guard serializedLibraryHashFormatVersion == target.serializedLibraryHashFormatVersion,
              domainSummary == target.domainSummary,
              serializedLibraryHash == target.serializedLibraryHash else { return false }
        if sourceSchemaVersion < 10 {
            // A V8/V9 import may add a category profile and, only when an old
            // hep-lat/hep-th checkpoint exists, its explicit invalidation
            // marker. Formula/analysis rows are user work and must not be
            // fabricated by migration.
            var expectedRows = ["categoryProfiles": 1]
            if hasLegacyCategoryCheckpoint { expectedRows["searchIndexStates"] = 1 }
            let expectedProfile = hasLegacyCategoryCheckpoint
                ? CategoryProfile.migratingLegacy(categories: Set(SupportedArxivCategory.legacyV1.map(\.rawValue))).rawValues
                : CategoryProfile().rawValues
            let expectedInvalidationCount = hasLegacyCategoryCheckpoint ? legacyCategoryCheckpointCount : nil
            return target.typedRowCounts == expectedRows
                && categoryProfileCategories == expectedProfile
                && target.categoryProfileCategories == expectedProfile
                && target.hasLegacyCategoryCheckpoint == hasLegacyCategoryCheckpoint
                && target.legacyCategoryCheckpointCount == legacyCategoryCheckpointCount
                && target.legacyCheckpointInvalidationCount == expectedInvalidationCount
        }
        guard hasLegacyCategoryCheckpoint == target.hasLegacyCategoryCheckpoint,
              legacyCategoryCheckpointCount == target.legacyCategoryCheckpointCount else { return false }
        let families = Set(typedRowCounts.keys).union(target.typedRowCounts.keys)
        for family in families {
            let sourceCount = typedRowCounts[family, default: 0]
            let targetCount = target.typedRowCounts[family, default: 0]
            let sourceIDs = typedFamilyIdentityHashes[family]
            let targetIDs = target.typedFamilyIdentityHashes[family]
            let sourceContent = typedFamilyContentHashes[family]
            let targetContent = target.typedFamilyContentHashes[family]
            if sourceCount == targetCount, sourceIDs == targetIDs, sourceContent == targetContent { continue }
            if family == "categoryProfiles", sourceCount == 0, targetCount == 1,
               categoryProfileCategories == target.categoryProfileCategories { continue }
            if family == "searchIndexStates", sourceCount == 0, targetCount == 1,
               hasLegacyCategoryCheckpoint,
               target.legacyCheckpointInvalidationCount == legacyCategoryCheckpointCount { continue }
            if family == "searchIndexStates", hasLegacyCategoryCheckpoint,
               target.legacyCheckpointInvalidationCount == legacyCategoryCheckpointCount,
               searchIndexStateRowHashes["legacy-author-category-checkpoints"] == nil,
               let markerHash = target.searchIndexStateRowHashes["legacy-author-category-checkpoints"],
               targetCount == sourceCount + 1 {
                var preservedRows = searchIndexStateRowHashes
                preservedRows["legacy-author-category-checkpoints"] = markerHash
                if preservedRows == target.searchIndexStateRowHashes,
                   searchIndexStateRowHashes.count == sourceCount,
                   target.searchIndexStateRowHashes.count == targetCount {
                    continue
                }
            }
            return false
        }
        let expectedProfile = categoryProfileCategories ?? (hasLegacyCategoryCheckpoint
            ? CategoryProfile.migratingLegacy(categories: Set(SupportedArxivCategory.legacyV1.map(\.rawValue))).rawValues
            : CategoryProfile().rawValues)
        guard expectedProfile == target.categoryProfileCategories else { return false }
        if legacyCheckpointInvalidationCount != nil {
            return legacyCheckpointInvalidationCount == target.legacyCheckpointInvalidationCount
        }
        return hasLegacyCategoryCheckpoint
            ? target.legacyCheckpointInvalidationCount == legacyCategoryCheckpointCount
            : target.legacyCheckpointInvalidationCount == nil
    }

    func hasSameDomainAndTypedRows(as other: V10StoreSemanticSummary) -> Bool {
        domainSummary == other.domainSummary &&
            typedRowCounts == other.typedRowCounts &&
            typedIdentityHash == other.typedIdentityHash &&
            typedContentHash == other.typedContentHash &&
            typedFamilyIdentityHashes == other.typedFamilyIdentityHashes &&
            typedFamilyContentHashes == other.typedFamilyContentHashes &&
            categoryProfileCategories == other.categoryProfileCategories &&
            hasLegacyCategoryCheckpoint == other.hasLegacyCategoryCheckpoint &&
            legacyCategoryCheckpointCount == other.legacyCategoryCheckpointCount &&
            legacyCheckpointInvalidationCount == other.legacyCheckpointInvalidationCount
    }

    @MainActor
    static func make(from context: ModelContext, schemaVersion: Int) throws -> V10StoreSemanticSummary {
        let snapshot = try V8TypedStoreCodec.snapshot(from: context)
        let encoder = JSONEncoder.latticeLens
        encoder.outputFormatting.insert(.sortedKeys)
        let libraryHash = try V10CanonicalLibraryFingerprint.hash(snapshot: snapshot, encoder: encoder)
        let legacyCheckpointCount = snapshot.checkpoints.values.filter { checkpoint in
            checkpoint.jobKind == "author-candidates" && ArxivCategoryQueryBuilder.isLegacyQuery(checkpoint.query)
        }.count
        let hasLegacyCheckpoint = legacyCheckpointCount > 0
        guard schemaVersion >= 10 else {
            let expectedProfile = hasLegacyCheckpoint
                ? CategoryProfile.migratingLegacy(categories: Set(SupportedArxivCategory.legacyV1.map(\.rawValue))).rawValues
                : CategoryProfile().rawValues
            return V10StoreSemanticSummary(domainSummary: V8StoreSemanticSummary.make(snapshot),
                serializedLibraryHash: libraryHash,
                serializedLibraryHashFormatVersion: V10CanonicalLibraryFingerprint.formatVersion,
                typedRowCounts: [:],
                typedIdentityHash: StableHash.sha256(""), typedContentHash: StableHash.sha256(""),
                categoryProfileCategories: expectedProfile, hasLegacyCategoryCheckpoint: hasLegacyCheckpoint,
                legacyCategoryCheckpointCount: legacyCheckpointCount)
        }

        var counts = [String: Int]()
        var identities = [String]()
        var content = [String]()
        var identitiesByFamily = [String: [String]]()
        var contentByFamily = [String: [String]]()
        var seenIDsByFamily = [String: Set<String>]()
        func add(_ family: String, _ id: String, _ fields: [String]) throws {
            guard seenIDsByFamily[family, default: []].insert(id).inserted else {
                throw V10StoreMigrationError.semanticMismatch
            }
            counts[family, default: 0] += 1
            identities.append("\(family):\(id)")
            let identity = "\(family):\(id)"
            let rowContent = "\(identity):\(StableHash.sha256(try encoder.encode(fields)))"
            content.append(rowContent)
            identitiesByFamily[family, default: []].append(identity)
            contentByFamily[family, default: []].append(rowContent)
        }
        func date(_ value: Date?) -> String { value.map { String($0.timeIntervalSince1970.bitPattern) } ?? "nil" }
        func optional(_ value: String?) -> String { value ?? "nil" }
        func hash(_ value: Data) -> String { StableHash.sha256(value) }

        for row in try context.fetch(FetchDescriptor<StoredV10AuthorCategoryMembership>()) {
            try add("categoryMemberships", row.id, [String(row.authorID), row.category, row.generationID,
                String(row.isCurrent), date(row.updatedAt)])
        }
        let categoryProfiles = try context.fetch(FetchDescriptor<StoredV10CategoryProfile>())
        guard categoryProfiles.count <= 1 else { throw V10StoreMigrationError.semanticMismatch }
        var categoryProfileCategories: [String]?
        if categoryProfiles.count == 1, let profile = categoryProfiles.first {
            let rawValues = try JSONDecoder.latticeLens.decode([String].self, from: profile.categoriesData)
            let categories = Set(rawValues.compactMap(SupportedArxivCategory.init(rawValue:)))
            guard categories.count == Set(rawValues).count else { throw V10StoreMigrationError.semanticMismatch }
            categoryProfileCategories = SupportedArxivCategory.canonical(categories).map(\.rawValue)
        } else {
            categoryProfileCategories = hasLegacyCheckpoint
                ? CategoryProfile.migratingLegacy(categories: Set(SupportedArxivCategory.legacyV1.map(\.rawValue))).rawValues
                : CategoryProfile().rawValues
        }
        for row in categoryProfiles {
            try add("categoryProfiles", row.id, [String(row.revision), hash(row.categoriesData), date(row.updatedAt)])
        }
        for row in try context.fetch(FetchDescriptor<StoredV10FormulaInventory>()) {
            try add("formulaInventories", row.id, [String(row.paperID), row.documentID, row.documentHash,
                row.inventoryHash, String(row.parserVersion), row.status, hash(row.payload), date(row.updatedAt)])
        }
        var logicalFormulaItems = Set<Data>()
        for row in try context.fetch(FetchDescriptor<StoredV10FormulaInventoryItem>()) {
            let logicalIdentity = try encoder.encode([
                String(row.paperID), row.documentID, row.documentHash, row.inventoryHash, row.equationID
            ])
            guard logicalFormulaItems.insert(logicalIdentity).inserted else {
                throw V10StoreMigrationError.semanticMismatch
            }
            try add("formulaItems", row.id, [String(row.paperID), row.documentID, row.documentHash,
                row.inventoryHash, row.equationID, row.label, String(row.ordinal), String(row.sourceByteStart),
                String(row.sourceByteEnd), row.sourceTeXHash, optional(row.anchorID), row.status, hash(row.payload)])
        }
        for row in try context.fetch(FetchDescriptor<StoredV10FormulaDerivationJob>()) {
            try add("formulaJobs", row.id, [String(row.paperID), row.documentID, row.documentHash,
                row.inventoryHash, row.state, row.promptVersion, row.schemaVersion, date(row.createdAt),
                date(row.updatedAt), hash(row.payload)])
        }
        for row in try context.fetch(FetchDescriptor<StoredV10FormulaBatch>()) {
            try add("formulaBatches", row.id, [row.jobID, String(row.ordinal), hash(row.equationIDsData),
                row.payloadHash, row.status, date(row.updatedAt)])
        }
        for row in try context.fetch(FetchDescriptor<StoredV10FormulaBatchCheckpoint>()) {
            try add("formulaBatchCheckpoints", row.id, [row.jobID, row.inventoryHash, String(row.batchIndex),
                String(row.batchTotal), hash(row.equationIDsData), optional(row.requestID), String(row.attemptCount),
                row.payloadHash, String(row.receivedBytes), String(row.receivedCharacters), date(row.firstContentAt),
                date(row.lastContentAt), row.status, optional(row.errorCategory), date(row.updatedAt)])
        }
        for row in try context.fetch(FetchDescriptor<StoredV10FormulaDerivationStep>()) {
            try add("formulaSteps", row.id, [row.jobID, row.equationID, String(row.ordinal), row.text,
                optional(row.anchorID), row.status])
        }
        for row in try context.fetch(FetchDescriptor<StoredV10EquationDependency>()) {
            try add("equationDependencies", row.id, [row.jobID, row.equationID, row.dependsOnEquationID, row.status])
        }
        for row in try context.fetch(FetchDescriptor<StoredV10FormulaValidationReport>()) {
            try add("formulaValidationReports", row.id, [row.jobID, row.inventoryHash, row.claimHash,
                row.validatorVersion, row.status, hash(row.payload), date(row.createdAt)])
        }
        for row in try context.fetch(FetchDescriptor<StoredV10AnalysisRun>()) {
            try add("analysisRuns", row.id, [row.workflowKind, row.phase, row.providerRevision, row.modelID,
                row.promptVersion, row.schemaVersion, row.payloadHash, hash(row.sourceDocumentHashesData),
                optional(row.inventoryHash), date(row.updatedAt), hash(row.payload)])
        }
        for row in try context.fetch(FetchDescriptor<StoredV10AnalysisAttempt>()) {
            try add("analysisAttempts", row.id, [row.runID, String(row.requestIndex),
                row.batchIndex.map(String.init) ?? "nil", row.requestID, String(row.attempt), row.status,
                String(row.receivedBytes), String(row.receivedCharacters), optional(row.errorCategory), date(row.updatedAt)])
        }
        for row in try context.fetch(FetchDescriptor<StoredV10ReadingWorkflowState>()) {
            try add("readingWorkflowStates", String(row.paperID), [row.state, optional(row.selectedAnchorID), date(row.updatedAt)])
        }
        let searchStates = try context.fetch(FetchDescriptor<StoredV10SearchIndexState>())
        let legacyInvalidation = searchStates.first { $0.indexName == "legacy-author-category-checkpoints" }
        var searchIndexStateRowHashes = [String: String]()
        for row in searchStates {
            let fields = [String(row.version), row.state, String(row.indexedRecordCount), date(row.updatedAt)]
            try add("searchIndexStates", row.indexName, fields)
            searchIndexStateRowHashes[row.indexName] = StableHash.sha256(try encoder.encode(fields))
        }
        if schemaVersion >= 12 {
            for row in try context.fetch(FetchDescriptor<StoredV12FormulaDerivationSegment>()) {
                try add("formulaDerivationSegmentsV12", row.id, [row.jobID, String(row.paperID),
                    row.documentHash, row.inventoryHash, row.equationID, row.sourceTeX,
                    row.sourceTeXHash, String(row.segmentIndex), String(row.firstOrdinal),
                    String(row.stepCount), String(row.isFinal), optional(row.continuationSummary),
                    optional(row.conclusionZH), row.requestID, row.requestPayloadHash, row.responseHash,
                    String(row.receivedBytes), String(row.receivedCharacters), date(row.firstContentAt),
                    date(row.lastContentAt), row.stepsHash, row.receiptHash, row.chainHash])
            }
            for row in try context.fetch(FetchDescriptor<StoredV12FormulaDerivationSegmentStep>()) {
                try add("formulaDerivationSegmentStepsV12", row.id, [row.jobID, row.equationID,
                    String(row.segmentIndex), row.stepID, String(row.ordinal), row.textZH,
                    optional(row.beforeTeX), optional(row.afterTeX), row.ruleOrAssumption,
                    hash(row.referencedEquationIDsData), hash(row.evidenceAnchorIDsData),
                    hash(row.sourceDocumentHashesData), row.epistemicStatus])
            }
        }
        return V10StoreSemanticSummary(domainSummary: V8StoreSemanticSummary.make(snapshot),
            serializedLibraryHash: libraryHash,
            serializedLibraryHashFormatVersion: V10CanonicalLibraryFingerprint.formatVersion,
            typedRowCounts: counts,
            typedIdentityHash: StableHash.sha256(identities.sorted().joined(separator: "\n")),
            typedContentHash: StableHash.sha256(content.sorted().joined(separator: "\n")),
            typedFamilyIdentityHashes: identitiesByFamily.mapValues { StableHash.sha256($0.sorted().joined(separator: "\n")) },
            typedFamilyContentHashes: contentByFamily.mapValues { StableHash.sha256($0.sorted().joined(separator: "\n")) },
            searchIndexStateRowHashes: searchIndexStateRowHashes,
            categoryProfileCategories: categoryProfileCategories,
            hasLegacyCategoryCheckpoint: hasLegacyCheckpoint,
            legacyCategoryCheckpointCount: legacyCheckpointCount,
            legacyCheckpointInvalidationCount: legacyInvalidation?.state == "invalidated_by_query_revision" &&
                legacyInvalidation?.version == ArxivCategoryQueryBuilder.revision
                ? legacyInvalidation?.indexedRecordCount : nil)
    }
}

enum V10StoreSQLiteSchemaProbe {
    /// Reads Core Data's persisted version identifiers through a SQLite
    /// read-only connection. It deliberately avoids ModelContainer, whose
    /// migration manager may try to reconcile a mismatched schema on open.
    static func schemaVersion(at storeURL: URL, fileManager: FileManager = .default) throws -> Int {
        let values = try storeURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw V10StoreMigrationError.invalidSource }
        let databaseURL: URL
        if values.isDirectory == true {
            let enumerator = fileManager.enumerator(at: storeURL, includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [.skipsHiddenFiles])
            let candidates = (enumerator?.allObjects as? [URL] ?? []).filter { url in
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
                guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
                defer { try? handle.close() }
                guard let header = try? handle.read(upToCount: 16) else { return false }
                return header == Data("SQLite format 3\0".utf8)
            }
            guard candidates.count == 1, let candidate = candidates.first else {
                throw V10StoreMigrationError.invalidSource
            }
            databaseURL = candidate
        } else {
            databaseURL = storeURL
        }

        // SQLite readers may update the WAL shared-memory lock page even with
        // SQLITE_OPEN_READONLY.  The source store must remain byte-stable
        // while we decide which staged migration to run, so inspect it via an
        // immutable URI: this connection takes no locks and cannot create or
        // rewrite the source -shm file.  The coordinator later verifies a
        // copied SQLite family before opening any migration schema.
        var components = URLComponents()
        components.scheme = "file"
        components.path = databaseURL.path
        components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        guard let databaseURI = components.string else { throw V10StoreMigrationError.invalidSource }
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(databaseURI, &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nil)
        guard openStatus == SQLITE_OK, let database else {
            if let database { _ = sqlite3_close(database) }
            throw V10StoreMigrationError.invalidSource
        }
        defer { _ = sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT Z_PLIST FROM Z_METADATA LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw V10StoreMigrationError.invalidSource }
        defer { _ = sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { throw V10StoreMigrationError.invalidSource }
        let length = Int(sqlite3_column_bytes(statement, 0))
        guard length > 0 else { throw V10StoreMigrationError.invalidSource }
        let metadataData = Data(bytes: bytes, count: length)
        guard let metadata = try PropertyListSerialization.propertyList(from: metadataData, options: [], format: nil) as? [String: Any],
              let identifiers = metadata["NSStoreModelVersionIdentifiers"] as? [String],
              let identifier = identifiers.first,
              let major = Int(identifier.split(separator: ".").first ?? "") else {
            throw V10StoreMigrationError.invalidSource
        }
        return major
    }
}

/// Cross-process owner lease for a library directory. The lock file is
/// intentionally retained: unlinking a lock file while another process has
/// it open could permit two processes to lock different inodes.
final class V10StoreOwnerLease: @unchecked Sendable {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) { self.fileDescriptor = fileDescriptor }

    static func acquire(for storeURL: URL, fileManager: FileManager = .default) throws -> V10StoreOwnerLease {
        let parent = storeURL.deletingLastPathComponent().standardizedFileURL
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let lockURL = parent.appendingPathComponent(".latticelens-store-owner.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw V10StoreMigrationError.storeOwnerBusy }
        var fileLock = Darwin.flock()
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        fileLock.l_start = 0
        fileLock.l_len = 0
        guard Darwin.fcntl(descriptor, F_SETLK, &fileLock) == 0 else {
            _ = Darwin.close(descriptor)
            throw V10StoreMigrationError.storeOwnerBusy
        }
        return V10StoreOwnerLease(fileDescriptor: descriptor)
    }

    deinit {
        var fileLock = Darwin.flock()
        fileLock.l_type = Int16(F_UNLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        fileLock.l_start = 0
        fileLock.l_len = 0
        _ = Darwin.fcntl(fileDescriptor, F_SETLK, &fileLock)
        _ = Darwin.close(fileDescriptor)
    }
}

enum V10StoreMigrationCoordinator {
    private static func supportsTarget(_ version: Int) -> Bool { version == 11 || version == 12 }
    private static func stagingPrefix(for version: Int) -> String { ".latticelens-v\(version)-stage-" }
    private static func migrationPrefix(for version: Int) -> String { ".latticelens-v\(version)-migration-" }
    private static func probePrefix(for version: Int) -> String { ".latticelens-v\(version)-probe-" }

    static func descriptorURL(for baseStoreURL: URL, targetSchemaVersion: Int = 11) -> URL {
        let suffix = targetSchemaVersion == 11 ? ".active.json" : ".active-v\(targetSchemaVersion).json"
        return baseStoreURL.deletingLastPathComponent()
            .appendingPathComponent(".\(baseStoreURL.lastPathComponent)\(suffix)")
    }

    static func resolveActiveStoreURL(for baseStoreURL: URL, targetSchemaVersion: Int = 11,
                                      fileManager: FileManager = .default) throws -> URL? {
        guard supportsTarget(targetSchemaVersion) else { throw V10StoreMigrationError.invalidDescriptor }
        let descriptorURL = descriptorURL(for: baseStoreURL, targetSchemaVersion: targetSchemaVersion)
        guard fileManager.fileExists(atPath: descriptorURL.path) else { return nil }
        let descriptor = try JSONDecoder.latticeLens.decode(V10ActiveStoreDescriptor.self, from: Data(contentsOf: descriptorURL))
        guard descriptor.schemaVersion == targetSchemaVersion,
              descriptor.storeName.hasPrefix(stagingPrefix(for: targetSchemaVersion)),
              descriptor.storeName.hasSuffix(".store"),
              !descriptor.storeName.contains("/"), !descriptor.storeName.contains("\\"),
              descriptor.storeName != ".", descriptor.storeName != ".." else {
            throw V10StoreMigrationError.invalidDescriptor
        }
        let activeURL = baseStoreURL.deletingLastPathComponent().appendingPathComponent(descriptor.storeName)
        guard fileManager.fileExists(atPath: activeURL.path) else { throw V10StoreMigrationError.invalidDescriptor }
        return activeURL
    }

    static func validateActiveDescriptorEvidence(
        descriptorURL: URL,
        backupRoot: URL,
        fileManager: FileManager = .default,
        targetSchemaVersion: Int = 11
    ) throws -> V10StoreMigrationJournal {
        guard supportsTarget(targetSchemaVersion) else { throw V10StoreMigrationError.invalidDescriptor }
        let parent = descriptorURL.deletingLastPathComponent().standardizedFileURL
        guard backupRoot.deletingLastPathComponent().standardizedFileURL == parent else {
            throw V10StoreMigrationError.invalidDescriptor
        }
        let descriptor = try JSONDecoder.latticeLens.decode(
            V10ActiveStoreDescriptor.self, from: Data(contentsOf: descriptorURL))
        let activeURL = parent.appendingPathComponent(descriptor.storeName)
        let activeValues = try activeURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard descriptor.schemaVersion == targetSchemaVersion,
              descriptor.storeName.hasPrefix(stagingPrefix(for: targetSchemaVersion)), descriptor.storeName.hasSuffix(".store"),
              !descriptor.storeName.contains("/"), !descriptor.storeName.contains("\\"),
              descriptor.storeName != ".", descriptor.storeName != "..",
              activeValues.isSymbolicLink != true,
              activeValues.isRegularFile == true || activeValues.isDirectory == true,
              fileManager.fileExists(atPath: activeURL.path) else {
            throw V10StoreMigrationError.invalidDescriptor
        }

        let journalURL = parent.appendingPathComponent(
            "\(migrationPrefix(for: targetSchemaVersion))\(descriptor.runID.uuidString).json")
        let journal = try JSONDecoder.latticeLens.decode(
            V10StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
        guard journal.id == descriptor.runID, journal.phase == .activated,
              journal.stagingStoreName == descriptor.storeName,
              journal.descriptorName == descriptorURL.lastPathComponent,
              journal.sourceSchemaVersion >= 8, journal.targetSchemaVersion == targetSchemaVersion,
              journal.backupManifestID == descriptor.backupManifestID,
              journal.backupManifestHash == descriptor.backupManifestHash else {
            throw V10StoreMigrationError.invalidDescriptor
        }

        let migrationManifestURL = backupRoot
            .appendingPathComponent(journal.backupManifestID.uuidString, isDirectory: true)
            .appendingPathComponent("migration-manifest.json")
        let manifest = try JSONDecoder.latticeLens.decode(
            V10MigrationBackupManifest.self, from: Data(contentsOf: migrationManifestURL))
        guard manifest.id == journal.backupManifestID,
              manifest.sourceSchemaVersion == journal.sourceSchemaVersion,
              manifest.targetSchemaVersion == journal.targetSchemaVersion,
              manifest.manifestHash == journal.backupManifestHash,
              try manifest.verifiesHash() else {
            throw V10StoreMigrationError.invalidDescriptor
        }

        if journal.semanticFormatVersion >= 2 {
            guard let targetSummary = journal.targetSummary,
                  manifest.semanticSummary == journal.sourceSummary,
                  manifest.recordCounts == journal.sourceSummary.recordCounts,
                  manifest.stableIDHash == journal.sourceSummary.stableIDHash,
                  descriptor.semanticHash == targetSummary.stableIDHash else {
                throw V10StoreMigrationError.invalidDescriptor
            }
        } else {
            guard let legacySource = journal.legacySourceSummary,
                  let legacyTarget = journal.legacyTargetSummary,
                  manifest.semanticSummary == nil,
                  manifest.recordCounts == legacySource.counts,
                  manifest.stableIDHash == legacySource.stableIDHash,
                  descriptor.semanticHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  journal.targetSummary?.domainSummary == legacyTarget else {
                throw V10StoreMigrationError.invalidDescriptor
            }
        }
        return journal
    }

    /// `sourceSchemaVersion` comes from the SQLite read-only metadata probe.
    /// `inspectBackupCopy` opens only a throwaway copy of the verified backup;
    /// it must never open the active source URL. `migrateAndVerify` receives
    /// only the final staging URL.
    @MainActor
    static func migrate(
        sourceURL: URL,
        descriptorURL: URL,
        backupRoot: URL,
        crashAt: V10StoreMigrationCrashPoint? = nil,
        ownerLease: V10StoreOwnerLease? = nil,
        fileManager: FileManager = .default,
        targetSchemaVersion: Int = 11,
        readBackupSchemaVersion: (URL) throws -> Int = { try V10StoreSQLiteSchemaProbe.schemaVersion(at: $0) },
        inspectBackupCopy: (URL, Int) throws -> V10StoreSemanticSummary,
        migrateAndVerify: (URL, (V10StoreMigrationPhase) throws -> Void) throws -> V10StoreSemanticSummary
    ) throws -> V10StoreMigrationOutcome {
        guard supportsTarget(targetSchemaVersion) else { throw V10StoreMigrationError.invalidSource }
        let stagePrefix = stagingPrefix(for: targetSchemaVersion)
        let journalPrefix = migrationPrefix(for: targetSchemaVersion)
        let probeFilePrefix = probePrefix(for: targetSchemaVersion)
        let source = sourceURL.standardizedFileURL
        let parent = source.deletingLastPathComponent()
        guard sourceURL.deletingLastPathComponent().standardizedFileURL == parent,
              descriptorURL.deletingLastPathComponent().standardizedFileURL == parent,
              backupRoot.deletingLastPathComponent().standardizedFileURL == parent else {
            throw V10StoreMigrationError.invalidSource
        }
        guard fileManager.fileExists(atPath: source.path) else { throw V10StoreMigrationError.sourceMissing }
        guard !fileManager.fileExists(atPath: descriptorURL.path) else { throw V10StoreMigrationError.activeDescriptorExists }
        let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard sourceValues.isSymbolicLink != true,
              sourceValues.isRegularFile == true || sourceValues.isDirectory == true else {
            throw V10StoreMigrationError.invalidSource
        }

        let lease = try ownerLease ?? V10StoreOwnerLease.acquire(for: source, fileManager: fileManager)
        defer { withExtendedLifetime(lease) {} }

        let runID = UUID()
        let stagingName = "\(stagePrefix)\(runID.uuidString).store"
        let stagingURL = parent.appendingPathComponent(stagingName)
        let journalURL = parent.appendingPathComponent("\(journalPrefix)\(runID.uuidString).json")
        guard !fileManager.fileExists(atPath: stagingURL.path), !fileManager.fileExists(atPath: journalURL.path) else {
            throw V10StoreMigrationError.invalidSource
        }

        let rawStoreManifest = try V4StoreBackupCoordinator.createBackup(
            source: source, destinationRoot: backupRoot, schemaVersion: 0,
            fileManager: fileManager)
        guard try V4StoreBackupCoordinator.verify(rawStoreManifest, in: backupRoot, fileManager: fileManager) else {
            throw V10StoreMigrationError.backupMismatch
        }

        let probeURL = parent.appendingPathComponent("\(probeFilePrefix)\(runID.uuidString).store")
        defer { try? removeStagingStore(at: probeURL, parent: parent, fileManager: fileManager) }
        try copyVerifiedBackup(rawStoreManifest, backupRoot: backupRoot, sourceURL: source,
                               stagingURL: probeURL, sourceIsDirectory: sourceValues.isDirectory == true,
                               crashAt: nil, fileManager: fileManager)
        let sourceSchemaVersion = try readBackupSchemaVersion(probeURL)
        guard (8...targetSchemaVersion).contains(sourceSchemaVersion) else {
            throw V10StoreMigrationError.invalidSource
        }
        let sourceSummary = try inspectBackupCopy(probeURL, sourceSchemaVersion)
        let encodedFiles = try JSONEncoder.latticeLens.encode(rawStoreManifest.files)
        let storeManifest = V4StoreBackupManifest(
            id: rawStoreManifest.id, schemaVersion: sourceSchemaVersion, createdAt: rawStoreManifest.createdAt,
            sourcePathCategory: rawStoreManifest.sourcePathCategory, files: rawStoreManifest.files,
            manifestHash: StableHash.sha256(encodedFiles))
        let backupDirectory = backupRoot.appendingPathComponent(storeManifest.id.uuidString, isDirectory: true)
        try JSONEncoder.latticeLens.encode(storeManifest)
            .write(to: backupDirectory.appendingPathComponent("manifest.json"), options: .atomic)

        let backupManifest = try V10MigrationBackupManifest(
            id: storeManifest.id, sourceSchemaVersion: sourceSchemaVersion, targetSchemaVersion: targetSchemaVersion,
            createdAt: Date(), summary: sourceSummary, storeFamilyManifest: storeManifest)
        let migrationManifestURL = backupDirectory.appendingPathComponent("migration-manifest.json")
        try JSONEncoder.latticeLens.encode(backupManifest).write(to: migrationManifestURL, options: .atomic)

        var journal = V10StoreMigrationJournal(
            id: runID, sourceStoreName: source.lastPathComponent, stagingStoreName: stagingName,
            descriptorName: descriptorURL.lastPathComponent, sourceSchemaVersion: sourceSchemaVersion,
            targetSchemaVersion: targetSchemaVersion, backupManifestID: storeManifest.id,
            backupManifestHash: backupManifest.manifestHash, sourceSummary: sourceSummary,
            startedAt: Date(), updatedAt: Date(), completedAt: nil, phase: .prepared,
            targetSummary: nil, errorCategory: nil)
        try write(journal, to: journalURL)

        func advance(_ phase: V10StoreMigrationPhase) throws {
            journal.phase = phase; journal.updatedAt = Date()
            try write(journal, to: journalURL)
            switch (crashAt, phase) {
            case (.afterBackup, .backedUp),
                 (.categoryMigration, .categoryMigrated), (.searchIndexReady, .searchIndexReady),
                 (.afterSemanticVerification, .verified), (.beforeActivation, .verified):
                if let crashAt { throw V10StoreMigrationError.injectedCrash(crashAt) }
            default: break
            }
        }

        do {
            try advance(.backedUp)
            try copyVerifiedBackup(storeManifest, backupRoot: backupRoot, sourceURL: source,
                                   stagingURL: stagingURL, sourceIsDirectory: sourceValues.isDirectory == true,
                                   crashAt: crashAt, fileManager: fileManager)
            try advance(.staged)
            let targetSummary = try migrateAndVerify(stagingURL, advance)
            journal.targetSummary = targetSummary
            journal.phase = .migrated; journal.updatedAt = Date()
            try write(journal, to: journalURL)
            guard sourceSummary.preservesDomainAndTypedRows(in: targetSummary,
                                                            sourceSchemaVersion: sourceSchemaVersion) else {
                throw V10StoreMigrationError.semanticMismatch
            }
            try advance(.verified)
            let descriptor = V10ActiveStoreDescriptor(runID: runID, storeName: stagingName,
                schemaVersion: targetSchemaVersion, backupManifestID: storeManifest.id,
                backupManifestHash: backupManifest.manifestHash, semanticHash: targetSummary.stableIDHash,
                activatedAt: Date())
            try writeDescriptor(descriptor, to: descriptorURL)
            if crashAt == .afterActivation { throw V10StoreMigrationError.injectedCrash(.afterActivation) }
            journal.phase = .activated; journal.updatedAt = Date(); journal.completedAt = Date()
            try write(journal, to: journalURL)
            return V10StoreMigrationOutcome(journalURL: journalURL, journal: journal,
                                             backupManifest: backupManifest, activeStoreURL: stagingURL)
        } catch let error as V10StoreMigrationError {
            if case .injectedCrash = error { throw error }
            journal.phase = .failed; journal.updatedAt = Date()
            journal.errorCategory = String(describing: error)
            try? write(journal, to: journalURL)
            throw error
        } catch {
            journal.phase = .failed; journal.updatedAt = Date()
            journal.errorCategory = String(describing: type(of: error))
            try? write(journal, to: journalURL)
            throw error
        }
    }

    @MainActor
    static func recover(
        journalURL: URL,
        parent: URL,
        descriptorURL: URL,
        backupRoot: URL,
        fileManager: FileManager = .default,
        verifyActive: (URL) throws -> V10StoreSemanticSummary
    ) throws -> V10StoreMigrationJournal {
        let root = parent.standardizedFileURL
        guard journalURL.deletingLastPathComponent().standardizedFileURL == root,
              descriptorURL.deletingLastPathComponent().standardizedFileURL == root,
              backupRoot.deletingLastPathComponent().standardizedFileURL == root else {
            throw V10StoreMigrationError.invalidJournal
        }
        var journal = try JSONDecoder.latticeLens.decode(V10StoreMigrationJournal.self, from: Data(contentsOf: journalURL))
        guard supportsTarget(journal.targetSchemaVersion),
              journal.stagingStoreName.hasPrefix(stagingPrefix(for: journal.targetSchemaVersion)),
              journal.stagingStoreName.hasSuffix(".store"),
              !journal.stagingStoreName.contains("/"), !journal.stagingStoreName.contains("\\"),
              journal.descriptorName == descriptorURL.lastPathComponent else {
            throw V10StoreMigrationError.invalidJournal
        }
        let backupDirectory = backupRoot.appendingPathComponent(journal.backupManifestID.uuidString, isDirectory: true)
        let manifestURL = backupDirectory.appendingPathComponent("migration-manifest.json")
        let manifest = try JSONDecoder.latticeLens.decode(V10MigrationBackupManifest.self, from: Data(contentsOf: manifestURL))
        let semanticManifestMatches: Bool
        if journal.semanticFormatVersion >= 2 {
            semanticManifestMatches = manifest.semanticSummary == journal.sourceSummary
                && manifest.recordCounts == journal.sourceSummary.recordCounts
                && manifest.stableIDHash == journal.sourceSummary.stableIDHash
        } else if let legacy = journal.legacySourceSummary {
            semanticManifestMatches = manifest.semanticSummary == nil
                && manifest.recordCounts == legacy.counts
                && manifest.stableIDHash == legacy.stableIDHash
        } else {
            semanticManifestMatches = false
        }
        guard manifest.id == journal.backupManifestID,
              manifest.manifestHash == journal.backupManifestHash,
              try manifest.verifiesHash(), semanticManifestMatches,
              try V4StoreBackupCoordinator.verify(manifest.storeFamilyManifest, in: backupRoot, fileManager: fileManager) else {
            throw V10StoreMigrationError.backupMismatch
        }

        let stagingURL = root.appendingPathComponent(journal.stagingStoreName)
        if fileManager.fileExists(atPath: descriptorURL.path) {
            let descriptor = try JSONDecoder.latticeLens.decode(V10ActiveStoreDescriptor.self, from: Data(contentsOf: descriptorURL))
            if descriptor.runID == journal.id {
                guard descriptor.storeName == journal.stagingStoreName,
                      descriptor.schemaVersion == journal.targetSchemaVersion,
                      descriptor.backupManifestHash == journal.backupManifestHash,
                      let targetSummary = journal.targetSummary else {
                    throw V10StoreMigrationError.semanticMismatch
                }
                let activeSummary = try verifyActive(stagingURL)
                if journal.semanticFormatVersion >= 2 {
                    guard journal.sourceSummary.preservesDomainAndTypedRows(
                            in: targetSummary, sourceSchemaVersion: journal.sourceSchemaVersion) else {
                        throw V10StoreMigrationError.semanticMismatch
                    }
                    if activeSummary == targetSummary,
                       descriptor.semanticHash == targetSummary.stableIDHash {
                        // The active target still matches the exact receipt written before activation.
                    } else if targetSummary.searchIndexStateRowHashes.isEmpty,
                              !activeSummary.searchIndexStateRowHashes.isEmpty,
                              targetSummary.serializedLibraryHashFormatVersion ==
                                activeSummary.serializedLibraryHashFormatVersion,
                              activeSummary.searchIndexStateRowHashes.count ==
                                activeSummary.typedRowCounts["searchIndexStates", default: 0],
                              activeSummary.hasSameDomainAndTypedRows(as: targetSummary),
                              descriptor.semanticHash == targetSummary.stableIDHash {
                        // Older v2 journals stored aggregate search-state hashes but not the
                        // per-row decomposition needed to prove an additive migration marker.
                        // All persisted aggregate hashes and the descriptor still match, so
                        // enrich the journal from the verified active store without changing it.
                        journal.targetSummary = activeSummary
                    } else if targetSummary.serializedLibraryHashFormatVersion <
                                activeSummary.serializedLibraryHashFormatVersion,
                              activeSummary.hasSameDomainAndTypedRows(as: targetSummary),
                              descriptor.semanticHash == targetSummary.stableIDHash ||
                                descriptor.semanticHash == activeSummary.stableIDHash {
                        // A pre-canonicalization v2 journal recorded a JSONEncoder hash whose Set order
                        // could vary between processes. The old source/target equality was checked
                        // before its descriptor was written; on crash recovery, retain that receipt,
                        // verify all stable domain/typed-row projections, then upgrade the target hash.
                        if descriptor.semanticHash != activeSummary.stableIDHash {
                            let upgradedDescriptor = V10ActiveStoreDescriptor(
                                runID: descriptor.runID, storeName: descriptor.storeName,
                                schemaVersion: descriptor.schemaVersion, backupManifestID: descriptor.backupManifestID,
                                backupManifestHash: descriptor.backupManifestHash,
                                semanticHash: activeSummary.stableIDHash, activatedAt: descriptor.activatedAt)
                            try writeDescriptor(upgradedDescriptor, to: descriptorURL)
                        }
                        journal.targetSummary = activeSummary
                    } else {
                        throw V10StoreMigrationError.semanticMismatch
                    }
                } else {
                    guard let legacyTarget = journal.legacyTargetSummary,
                          activeSummary.domainSummary == legacyTarget,
                          descriptor.semanticHash == legacyTarget.stableIDHash else {
                        throw V10StoreMigrationError.semanticMismatch
                    }
                    let upgradedDescriptor = V10ActiveStoreDescriptor(
                        runID: descriptor.runID, storeName: descriptor.storeName,
                        schemaVersion: descriptor.schemaVersion, backupManifestID: descriptor.backupManifestID,
                        backupManifestHash: descriptor.backupManifestHash,
                        semanticHash: activeSummary.stableIDHash, activatedAt: descriptor.activatedAt)
                    try writeDescriptor(upgradedDescriptor, to: descriptorURL)
                }
                journal.phase = .activated; journal.updatedAt = Date(); journal.completedAt = Date()
                journal.errorCategory = nil
                try write(journal, to: journalURL)
                return journal
            }
        }

        try removeStagingStore(at: stagingURL, parent: root, fileManager: fileManager)
        journal.phase = .rolledBack; journal.updatedAt = Date(); journal.completedAt = Date()
        try write(journal, to: journalURL)
        return journal
    }

    private static func copyVerifiedBackup(_ manifest: V4StoreBackupManifest, backupRoot: URL,
                                           sourceURL: URL, stagingURL: URL, sourceIsDirectory: Bool,
                                           crashAt: V10StoreMigrationCrashPoint?,
                                           fileManager: FileManager) throws {
        guard try V4StoreBackupCoordinator.verify(manifest, in: backupRoot, fileManager: fileManager) else {
            throw V10StoreMigrationError.backupMismatch
        }
        let backupDirectory = backupRoot.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        var copiedCount = 0
        if sourceIsDirectory {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            for entry in manifest.files {
                let backupFile = try V4OwnedPath.canonicalFile(named: entry.relativePath, root: backupDirectory, fileManager: fileManager)
                let stagingFile = try V4OwnedPath.canonicalFile(named: entry.relativePath, root: stagingURL, fileManager: fileManager)
                try fileManager.createDirectory(at: stagingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: backupFile, to: stagingFile)
                copiedCount += 1
                if crashAt == .duringCopy, copiedCount == 1 {
                    throw V10StoreMigrationError.injectedCrash(.duringCopy)
                }
            }
        } else {
            try fileManager.createDirectory(at: stagingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            for entry in manifest.files {
                let baseName = sourceURL.lastPathComponent
                guard entry.relativePath == baseName || entry.relativePath.hasPrefix(baseName + "-") else {
                    throw V10StoreMigrationError.backupMismatch
                }
                let suffix = String(entry.relativePath.dropFirst(baseName.count))
                guard ["", "-wal", "-shm"].contains(suffix) else { throw V10StoreMigrationError.backupMismatch }
                let backupFile = try V4OwnedPath.canonicalFile(named: entry.relativePath, root: backupDirectory, fileManager: fileManager)
                try fileManager.copyItem(at: backupFile, to: URL(fileURLWithPath: stagingURL.path + suffix))
                copiedCount += 1
                if crashAt == .duringCopy, copiedCount == 1 {
                    throw V10StoreMigrationError.injectedCrash(.duringCopy)
                }
            }
        }
        for entry in manifest.files {
            let stagedFile: URL
            if sourceIsDirectory {
                stagedFile = try V4OwnedPath.canonicalFile(named: entry.relativePath, root: stagingURL, fileManager: fileManager)
            } else {
                let suffix = String(entry.relativePath.dropFirst(sourceURL.lastPathComponent.count))
                stagedFile = URL(fileURLWithPath: stagingURL.path + suffix)
            }
            let data = try Data(contentsOf: stagedFile)
            guard data.count == entry.byteCount, StableHash.sha256(data) == entry.sha256 else {
                throw V10StoreMigrationError.backupMismatch
            }
        }
    }

    private static func removeStagingStore(at stagingURL: URL, parent: URL, fileManager: FileManager) throws {
        let ownedPrefix = [stagingPrefix(for: 11), stagingPrefix(for: 12),
                           probePrefix(for: 11), probePrefix(for: 12)].contains {
            stagingURL.lastPathComponent.hasPrefix($0)
        }
        guard stagingURL.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL,
              ownedPrefix, stagingURL.pathExtension == "store" else {
            throw V10StoreMigrationError.invalidJournal
        }
        let values = try? stagingURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { throw V10StoreMigrationError.invalidJournal }
        if values?.isDirectory == true {
            try fileManager.removeItem(at: stagingURL)
        } else {
            for suffix in ["", "-wal", "-shm"] {
                let member = URL(fileURLWithPath: stagingURL.path + suffix)
                if fileManager.fileExists(atPath: member.path) { try fileManager.removeItem(at: member) }
            }
        }
    }

    private static func write(_ journal: V10StoreMigrationJournal, to url: URL) throws {
        try JSONEncoder.latticeLens.encode(journal).write(to: url, options: .atomic)
    }

    private static func writeDescriptor(_ descriptor: V10ActiveStoreDescriptor, to url: URL) throws {
        let data = try JSONEncoder.latticeLens.encode(descriptor)
        try data.write(to: url, options: .atomic)
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
