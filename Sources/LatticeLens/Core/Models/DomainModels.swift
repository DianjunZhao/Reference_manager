import Foundation

/// Fixed product contract. This is a record identifier, never a name match.
enum ProductContract {
    static let selfAuthorRecid = 2_010_363
    static let hIndexThreshold = 20
    static let sourceScope = "title_abstract_figure_captions"
    static let insightSchemaVersion = "paper-insight-v1"
}

enum HIndexState: String, Codable, Sendable, CaseIterable {
    case unknown
    case qualified
    case rejected
    case stale
    case failed
}

struct HIndexSnapshot: Codable, Hashable, Sendable {
    let authorRecid: Int
    let all: Int
    let published: Int?
    let excludesSelfCitations: Bool
    let source: String
    let query: String
    let fetchedAt: Date
    let rawSchemaHash: String
    var inputPaperCount: Int? = nil
    var missingCitationCount: Int? = nil
    var pageCount: Int? = nil
    var computationFormulaVersion: String? = nil

    var isQualified: Bool {
        !excludesSelfCitations && all > ProductContract.hIndexThreshold
    }
}

struct Author: Codable, Hashable, Identifiable, Sendable {
    let recid: Int
    var preferredName: String
    var nativeNames: [String]
    var bai: String?
    var arxivCategories: Set<String>
    var hIndex: HIndexSnapshot?
    var hIndexState: HIndexState
    var isTracked: Bool
    var lastSyncedAt: Date?
    /// v3 separates durable page progress from a completed generation's
    /// freshness. `lastSyncedAt` remains as the v2 compatibility projection.
    var lastCheckpointAt: Date? = nil
    var lastSuccessfulSyncAt: Date? = nil

    var id: Int { recid }
    var isSelf: Bool { recid == ProductContract.selfAuthorRecid }
    var isHepLatCandidate: Bool { arxivCategories.contains("hep-lat") }
    var isVisibleInQualifiedList: Bool { isSelf || hIndexState == .qualified }

    var sectionKey: String {
        let family = preferredName.split(separator: ",", maxSplits: 1).first.map(String.init) ?? preferredName
        guard let scalar = family.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .uppercased().unicodeScalars.first,
            CharacterSet.letters.contains(scalar) else { return "#" }
        return String(Character(scalar))
    }

    /// Stable, locale-independent grouping/sort material. Display ordering may
    /// still use localized comparison as a final tie-breaker.
    var stableSortKey: String {
        let family = preferredName.split(separator: ",", maxSplits: 1).first.map(String.init) ?? preferredName
        return SearchNormalizer.normalize(family)
    }

    func matches(search query: String) -> Bool {
        let needle = SearchNormalizer.normalize(query)
        guard !needle.isEmpty else { return true }
        return ([preferredName, bai ?? ""] + nativeNames)
            .map(SearchNormalizer.normalize)
            .contains { $0.contains(needle) }
    }
}

struct PaperTitle: Codable, Hashable, Sendable, Identifiable {
    let value: String
    let source: String?
    var id: String { "\(source ?? "unknown"):\(value)" }
}

struct PaperAbstract: Codable, Hashable, Sendable, Identifiable {
    let value: String
    let source: String?
    var id: String { "\(source ?? "unknown"):\(value)" }
}

struct PaperFigure: Codable, Hashable, Sendable, Identifiable {
    let key: String
    let url: URL?
    let label: String?
    let caption: String?
    let source: String?
    let filename: String?
    var id: String { key }
}

struct PaperContributor: Codable, Hashable, Sendable, Identifiable {
    let recid: Int?
    let fullName: String
    let position: Int

    var id: String { "\(recid.map(String.init) ?? fullName):\(position)" }
}

struct PaperDocument: Codable, Hashable, Sendable, Identifiable {
    let key: String
    let url: URL?
    let source: String?
    let filename: String?
    let isFullText: Bool

    var id: String { key }
}

struct Paper: Codable, Hashable, Identifiable, Sendable {
    let literatureID: Int
    var titles: [PaperTitle]
    var abstracts: [PaperAbstract]
    var preprintDate: Date?
    var earliestDate: Date?
    var arxivID: String?
    var arxivCategories: [String]
    var doi: String?
    var citationCount: Int?
    var publicationStatus: String?
    var updated: Date?
    var figures: [PaperFigure]
    var contributors: [PaperContributor] = []
    var documents: [PaperDocument] = []
    var firstSeenAt: Date
    var isRead: Bool
    var readAt: Date? = nil
    var isFavorite: Bool = false

    var id: Int { literatureID }
    var displayTitle: String { titles.first?.value ?? "Untitled record \(literatureID)" }
    var preferredAbstract: String? { abstracts.first?.value }
    var timelineDate: Date? { preprintDate ?? earliestDate }
    var timelineYear: Int { Calendar.current.component(.year, from: timelineDate ?? firstSeenAt) }

    init(literatureID: Int, titles: [PaperTitle], abstracts: [PaperAbstract], preprintDate: Date?, earliestDate: Date?,
         arxivID: String?, arxivCategories: [String], doi: String?, citationCount: Int?, publicationStatus: String?,
         updated: Date?, figures: [PaperFigure], contributors: [PaperContributor] = [], documents: [PaperDocument] = [],
         firstSeenAt: Date, isRead: Bool, readAt: Date? = nil, isFavorite: Bool = false) {
        self.literatureID = literatureID
        self.titles = titles
        self.abstracts = abstracts
        self.preprintDate = preprintDate
        self.earliestDate = earliestDate
        self.arxivID = arxivID
        self.arxivCategories = arxivCategories
        self.doi = doi
        self.citationCount = citationCount
        self.publicationStatus = publicationStatus
        self.updated = updated
        self.figures = figures
        self.contributors = contributors
        self.documents = documents
        self.firstSeenAt = firstSeenAt
        self.isRead = isRead
        self.readAt = readAt
        self.isFavorite = isFavorite
    }

    private enum CodingKeys: String, CodingKey {
        case literatureID, titles, abstracts, preprintDate, earliestDate, arxivID, arxivCategories, doi, citationCount
        case publicationStatus, updated, figures, contributors, documents, firstSeenAt, isRead, readAt, isFavorite
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            literatureID: try values.decode(Int.self, forKey: .literatureID),
            titles: try values.decodeIfPresent([PaperTitle].self, forKey: .titles) ?? [],
            abstracts: try values.decodeIfPresent([PaperAbstract].self, forKey: .abstracts) ?? [],
            preprintDate: try values.decodeIfPresent(Date.self, forKey: .preprintDate),
            earliestDate: try values.decodeIfPresent(Date.self, forKey: .earliestDate),
            arxivID: try values.decodeIfPresent(String.self, forKey: .arxivID),
            arxivCategories: try values.decodeIfPresent([String].self, forKey: .arxivCategories) ?? [],
            doi: try values.decodeIfPresent(String.self, forKey: .doi),
            citationCount: try values.decodeIfPresent(Int.self, forKey: .citationCount),
            publicationStatus: try values.decodeIfPresent(String.self, forKey: .publicationStatus),
            updated: try values.decodeIfPresent(Date.self, forKey: .updated),
            figures: try values.decodeIfPresent([PaperFigure].self, forKey: .figures) ?? [],
            contributors: try values.decodeIfPresent([PaperContributor].self, forKey: .contributors) ?? [],
            documents: try values.decodeIfPresent([PaperDocument].self, forKey: .documents) ?? [],
            firstSeenAt: try values.decodeIfPresent(Date.self, forKey: .firstSeenAt) ?? Date(),
            isRead: try values.decodeIfPresent(Bool.self, forKey: .isRead) ?? false,
            readAt: try values.decodeIfPresent(Date.self, forKey: .readAt),
            isFavorite: try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        )
    }
}

struct PaperAuthorLink: Codable, Hashable, Sendable {
    let paperID: Int
    let authorRecid: Int
    let position: Int
}

enum SyncPhase: String, Codable, Sendable {
    case idle
    case loadingLocal
    case syncingMetadata
    case ready
    case stale
    case partial
    case cancelled
    case failed
}

enum SyncCheckpointState: String, Codable, Sendable {
    case active
    case paused
    case cancelled
    case failed
    case completed

    var isTerminal: Bool { self == .cancelled || self == .failed || self == .completed }
}

struct SyncStatus: Codable, Hashable, Sendable {
    var phase: SyncPhase
    var message: String
    var completedPages: Int
    var successfulRecords: Int
    var failedRecords: Int
    var lastUpdatedAt: Date?
    var newRecords: Int = 0
    var metadataUpdatedRecords: Int = 0
    var unchangedRecords: Int = 0
    var remainingRecords: Int? = nil

    static let idle = SyncStatus(phase: .idle, message: "未同步", completedPages: 0, successfulRecords: 0, failedRecords: 0, lastUpdatedAt: nil)
}

struct SyncCheckpoint: Codable, Hashable, Sendable, Identifiable {
    let jobID: String
    let jobKind: String
    let query: String
    let generationID: String
    var nextURL: URL?
    var completedPages: Int
    var successfulRecords: Int
    var failedRecords: Int
    var failedIDs: [Int]
    var pendingIDs: [Int]
    var cancelledIDs: [Int]
    var retryableIDs: [Int]
    var startedAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var lastCheckpointAt: Date?
    var lastSuccessfulSyncAt: Date?
    var activeMembership: Set<Int>
    var stagingMembership: Set<Int>
    var state: SyncCheckpointState

    var id: String { jobID }

    /// A completed generation is a publication boundary.  In particular, a
    /// failed h-index lookup remains retryable evidence, not a terminal zero;
    /// promoting staging membership while it exists would make an incomplete
    /// author set look final after relaunch.
    var isCompletionEligible: Bool {
        nextURL == nil && pendingIDs.isEmpty && retryableIDs.isEmpty
    }

    /// Stable queue identity used on relaunch.  Never rebuild this from a
    /// fresh author query: doing so can accidentally retry completed IDs or
    /// drop a previously persisted retryable ID.
    var resumableIDs: [Int] {
        Array(Set(pendingIDs + retryableIDs)).sorted()
    }

    init(
        jobID: String,
        jobKind: String,
        query: String,
        generationID: String = UUID().uuidString,
        nextURL: URL? = nil,
        completedPages: Int = 0,
        successfulRecords: Int = 0,
        failedRecords: Int = 0,
        failedIDs: [Int] = [],
        pendingIDs: [Int] = [],
        cancelledIDs: [Int] = [],
        retryableIDs: [Int] = [],
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        lastCheckpointAt: Date? = nil,
        lastSuccessfulSyncAt: Date? = nil,
        activeMembership: Set<Int> = [],
        stagingMembership: Set<Int> = [],
        state: SyncCheckpointState = .active
    ) {
        self.jobID = jobID
        self.jobKind = jobKind
        self.query = query
        self.generationID = generationID
        self.nextURL = nextURL
        self.completedPages = completedPages
        self.successfulRecords = successfulRecords
        self.failedRecords = failedRecords
        self.failedIDs = failedIDs
        self.pendingIDs = pendingIDs
        self.cancelledIDs = cancelledIDs
        self.retryableIDs = retryableIDs
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.lastCheckpointAt = lastCheckpointAt
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.activeMembership = activeMembership
        self.stagingMembership = stagingMembership
        self.state = state
    }

    /// Compatibility bridge for a v1 encoded checkpoint; new code must use the
    /// typed job id/state initializer above.
    init(jobKind: String, query: String, nextURL: URL?, completedPages: Int, successfulRecords: Int, failedRecords: Int, lastCompletedAt: Date?) {
        self.init(jobID: "\(jobKind):\(query)", jobKind: jobKind, query: query, nextURL: nextURL,
                  completedPages: completedPages, successfulRecords: successfulRecords, failedRecords: failedRecords,
                  startedAt: lastCompletedAt ?? Date(), updatedAt: lastCompletedAt ?? Date(),
                  completedAt: nextURL == nil ? lastCompletedAt : nil,
                  state: nextURL == nil ? .completed : .active)
    }

    private enum CodingKeys: String, CodingKey {
        case jobID, jobKind, query, generationID, nextURL, completedPages, successfulRecords, failedRecords
        case failedIDs, pendingIDs, cancelledIDs, retryableIDs, startedAt, updatedAt, completedAt, lastCheckpointAt, lastSuccessfulSyncAt
        case activeMembership, stagingMembership, state, lastCompletedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacyDate = try values.decodeIfPresent(Date.self, forKey: .lastCompletedAt)
        let kind = try values.decode(String.self, forKey: .jobKind)
        let query = try values.decode(String.self, forKey: .query)
        let nextURL = try values.decodeIfPresent(URL.self, forKey: .nextURL)
        self.init(
            jobID: try values.decodeIfPresent(String.self, forKey: .jobID) ?? "\(kind):\(query)",
            jobKind: kind,
            query: query,
            generationID: try values.decodeIfPresent(String.self, forKey: .generationID) ?? "v1-import",
            nextURL: nextURL,
            completedPages: try values.decodeIfPresent(Int.self, forKey: .completedPages) ?? 0,
            successfulRecords: try values.decodeIfPresent(Int.self, forKey: .successfulRecords) ?? 0,
            failedRecords: try values.decodeIfPresent(Int.self, forKey: .failedRecords) ?? 0,
            failedIDs: try values.decodeIfPresent([Int].self, forKey: .failedIDs) ?? [],
            pendingIDs: try values.decodeIfPresent([Int].self, forKey: .pendingIDs) ?? [],
            cancelledIDs: try values.decodeIfPresent([Int].self, forKey: .cancelledIDs) ?? [],
            retryableIDs: try values.decodeIfPresent([Int].self, forKey: .retryableIDs) ?? [],
            startedAt: try values.decodeIfPresent(Date.self, forKey: .startedAt) ?? legacyDate ?? Date(),
            updatedAt: try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? legacyDate ?? Date(),
            completedAt: try values.decodeIfPresent(Date.self, forKey: .completedAt) ?? (nextURL == nil ? legacyDate : nil),
            lastCheckpointAt: try values.decodeIfPresent(Date.self, forKey: .lastCheckpointAt),
            lastSuccessfulSyncAt: try values.decodeIfPresent(Date.self, forKey: .lastSuccessfulSyncAt),
            activeMembership: try values.decodeIfPresent(Set<Int>.self, forKey: .activeMembership) ?? [],
            stagingMembership: try values.decodeIfPresent(Set<Int>.self, forKey: .stagingMembership) ?? [],
            state: try values.decodeIfPresent(SyncCheckpointState.self, forKey: .state) ?? (nextURL == nil ? .completed : .active)
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(jobID, forKey: .jobID)
        try values.encode(jobKind, forKey: .jobKind)
        try values.encode(query, forKey: .query)
        try values.encode(generationID, forKey: .generationID)
        try values.encodeIfPresent(nextURL, forKey: .nextURL)
        try values.encode(completedPages, forKey: .completedPages)
        try values.encode(successfulRecords, forKey: .successfulRecords)
        try values.encode(failedRecords, forKey: .failedRecords)
        try values.encode(failedIDs, forKey: .failedIDs)
        try values.encode(pendingIDs, forKey: .pendingIDs)
        try values.encode(cancelledIDs, forKey: .cancelledIDs)
        try values.encode(retryableIDs, forKey: .retryableIDs)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encodeIfPresent(completedAt, forKey: .completedAt)
        try values.encodeIfPresent(lastCheckpointAt, forKey: .lastCheckpointAt)
        try values.encodeIfPresent(lastSuccessfulSyncAt, forKey: .lastSuccessfulSyncAt)
        try values.encode(activeMembership, forKey: .activeMembership)
        try values.encode(stagingMembership, forKey: .stagingMembership)
        try values.encode(state, forKey: .state)
    }
}

struct PaperUpsertReport: Codable, Hashable, Sendable {
    var inserted = 0
    var metadataUpdated = 0
    var citationChanged = 0
    var unchanged = 0

    static let empty = PaperUpsertReport()

    static func + (lhs: PaperUpsertReport, rhs: PaperUpsertReport) -> PaperUpsertReport {
        PaperUpsertReport(inserted: lhs.inserted + rhs.inserted,
                          metadataUpdated: lhs.metadataUpdated + rhs.metadataUpdated,
                          citationChanged: lhs.citationChanged + rhs.citationChanged,
                          unchanged: lhs.unchanged + rhs.unchanged)
    }
}

struct InsightCacheKey: Codable, Hashable, Sendable {
    let paperID: Int
    let paperUpdated: Date?
    let promptVersion: String
    let insightSchemaVersion: String
    let sourceScope: String
    let provider: String
    let normalizedBaseURL: String
    let model: String
    let credentialRevision: Int
    let mode: InsightMode
    let detailLevel: InsightDetailLevel
    let figureSetHash: String
    let maximumFigures: Int
    let terminologyHash: String
    let providerCapabilityHash: String

    var value: String {
        let fields = [String(paperID), paperUpdated?.ISO8601Format() ?? "", promptVersion, insightSchemaVersion, sourceScope,
                      provider, normalizedBaseURL, model, String(credentialRevision), mode.rawValue, detailLevel.rawValue,
                      figureSetHash, String(maximumFigures), terminologyHash, providerCapabilityHash]
        return StableHash.sha256(fields.joined(separator: "|"))
    }
}

struct InsightArtifact: Codable, Hashable, Sendable, Identifiable {
    let cacheKey: String
    let paperID: Int
    let insight: PaperInsightV1
    let createdAt: Date
    var id: String { cacheKey }
}

struct LibrarySnapshot: Codable, Sendable {
    var authors: [Int: Author] = [:]
    var papers: [Int: Paper] = [:]
    var paperAuthorLinks: Set<PaperAuthorLink> = []
    var insights: [String: InsightArtifact] = [:]
    var evidenceInsights: [String: EvidenceInsightArtifact] = [:]
    var checkpoints: [String: SyncCheckpoint] = [:]
    var readingStates: [Int: ReadingState] = [:]
    var notes: [UUID: UserNote] = [:]
    var tags: [UUID: LibraryTag] = [:]
    var paperTags: Set<PaperTagLink> = []
    var collections: [UUID: PaperCollection] = [:]
    var collectionPapers: Set<CollectionPaperLink> = []
    var citationSnapshots: [String: CitationSnapshot] = [:]
    var bibTeXRecords: [Int: BibTeXRecord] = [:]
    var fullTextDocuments: [String: FullTextDocument] = [:]
    var evidenceChunks: [String: EvidenceChunk] = [:]
    var evidenceAnchors: [String: EvidenceAnchor] = [:]
    var visionArtifacts: [String: VisionArtifact] = [:]
    var syncBatches: [UUID: SyncBatch] = [:]
    // v3 normalized/workbench records. These fields are additive so v1/v2
    // snapshots remain decodable and rollback-compatible.
    var authorIndexGenerations: [String: AuthorIndexGeneration] = [:]
    var paperRevisionSnapshots: [String: PaperRevisionSnapshot] = [:]
    var radarEvents: [UUID: RadarEvent] = [:]
    var savedInspireQueries: [UUID: SavedInspireQuery] = [:]
    var syncBatchesV3: [UUID: SyncBatchV3] = [:]
    var syncJobEvents: [UUID: SyncJobEvent] = [:]
    var contentBlobs: [String: ContentBlob] = [:]
    var orphanedBlobDeletions: [String: OrphanedBlobDeletion] = [:]
    var documentReferences: [String: DocumentReference] = [:]
    var userEvidenceAnchors: [UUID: UserEvidenceAnchor] = [:]
    var notebookEntries: [UUID: NotebookEntry] = [:]
    var notebookAnchorLinks: Set<NotebookAnchorLink> = []
    var workspaces: [UUID: PaperWorkspace] = [:]
    var workspacePaperLinks: Set<WorkspacePaperLink> = []
    var physicsContracts: [UUID: PhysicsContract] = [:]
    var physicsContractCells: [UUID: PhysicsContractCell] = [:]
    var citationEdges: [String: CitationEdge] = [:]
    var coauthorEdges: [String: CoauthorEdge] = [:]
    var exportRecords: [UUID: ExportRecord] = [:]
    var cloudSyncStates: [String: CloudSyncRecordState] = [:]
    var conflictCopies: [UUID: ConflictCopy] = [:]
    var importedBibliographies: [UUID: V3ImportedBibliography] = [:]
    var importConflicts: [UUID: V3ImportConflict] = [:]
    var migrationJournal: [UUID: V3MigrationJournalEntry] = [:]
    var quarantinedEvidenceIDs: Set<String> = []
    var schemaVersion: Int = 2
    var v3SchemaVersion: Int = 3
    /// Non-nil only for a fail-visible read result when no last-known-good
    /// snapshot exists. It prevents a decode failure from masquerading as an
    /// empty, writable library.
    var readErrorMessage: String? = nil

    private enum CodingKeys: String, CodingKey {
        case authors, papers, paperAuthorLinks, insights, evidenceInsights, checkpoints, readingStates, notes, tags, paperTags
        case collections, collectionPapers, citationSnapshots, bibTeXRecords, fullTextDocuments, evidenceChunks, evidenceAnchors, visionArtifacts, syncBatches, schemaVersion
        case authorIndexGenerations, paperRevisionSnapshots, radarEvents, savedInspireQueries, syncBatchesV3, syncJobEvents
        case contentBlobs, orphanedBlobDeletions, documentReferences, userEvidenceAnchors, notebookEntries, notebookAnchorLinks, workspaces, workspacePaperLinks, physicsContracts, physicsContractCells
        case citationEdges, coauthorEdges, exportRecords, cloudSyncStates, conflictCopies, importedBibliographies, importConflicts, migrationJournal, quarantinedEvidenceIDs, v3SchemaVersion, readErrorMessage
    }

    init(authors: [Int: Author] = [:], papers: [Int: Paper] = [:], paperAuthorLinks: Set<PaperAuthorLink> = [],
         insights: [String: InsightArtifact] = [:], evidenceInsights: [String: EvidenceInsightArtifact] = [:], checkpoints: [String: SyncCheckpoint] = [:],
         readingStates: [Int: ReadingState] = [:], notes: [UUID: UserNote] = [:], tags: [UUID: LibraryTag] = [:], paperTags: Set<PaperTagLink> = [],
         collections: [UUID: PaperCollection] = [:], collectionPapers: Set<CollectionPaperLink> = [], citationSnapshots: [String: CitationSnapshot] = [:], bibTeXRecords: [Int: BibTeXRecord] = [:],
         fullTextDocuments: [String: FullTextDocument] = [:], evidenceChunks: [String: EvidenceChunk] = [:], evidenceAnchors: [String: EvidenceAnchor] = [:],
         visionArtifacts: [String: VisionArtifact] = [:], syncBatches: [UUID: SyncBatch] = [:],
         authorIndexGenerations: [String: AuthorIndexGeneration] = [:], paperRevisionSnapshots: [String: PaperRevisionSnapshot] = [:],
         radarEvents: [UUID: RadarEvent] = [:], savedInspireQueries: [UUID: SavedInspireQuery] = [:], syncBatchesV3: [UUID: SyncBatchV3] = [:],
         syncJobEvents: [UUID: SyncJobEvent] = [:], contentBlobs: [String: ContentBlob] = [:], orphanedBlobDeletions: [String: OrphanedBlobDeletion] = [:], documentReferences: [String: DocumentReference] = [:],
         userEvidenceAnchors: [UUID: UserEvidenceAnchor] = [:], notebookEntries: [UUID: NotebookEntry] = [:], notebookAnchorLinks: Set<NotebookAnchorLink> = [],
         workspaces: [UUID: PaperWorkspace] = [:], workspacePaperLinks: Set<WorkspacePaperLink> = [],
         physicsContracts: [UUID: PhysicsContract] = [:], physicsContractCells: [UUID: PhysicsContractCell] = [:], citationEdges: [String: CitationEdge] = [:],
         coauthorEdges: [String: CoauthorEdge] = [:], exportRecords: [UUID: ExportRecord] = [:], cloudSyncStates: [String: CloudSyncRecordState] = [:],
         conflictCopies: [UUID: ConflictCopy] = [:], importedBibliographies: [UUID: V3ImportedBibliography] = [:], importConflicts: [UUID: V3ImportConflict] = [:], migrationJournal: [UUID: V3MigrationJournalEntry] = [:], quarantinedEvidenceIDs: Set<String> = [],
         schemaVersion: Int = 2, v3SchemaVersion: Int = 3, readErrorMessage: String? = nil) {
        self.authors = authors
        self.papers = papers
        self.paperAuthorLinks = paperAuthorLinks
        self.insights = insights
        self.evidenceInsights = evidenceInsights
        self.checkpoints = checkpoints
        var normalizedReadingStates = readingStates
        for paper in papers.values where normalizedReadingStates[paper.literatureID] == nil {
            normalizedReadingStates[paper.literatureID] = ReadingState(paperID: paper.literatureID, isRead: paper.isRead,
                                                                       readAt: paper.readAt, isFavorite: paper.isFavorite,
                                                                       updatedAt: paper.readAt ?? paper.firstSeenAt)
        }
        self.readingStates = normalizedReadingStates
        self.notes = notes
        self.tags = tags
        self.paperTags = paperTags
        self.collections = collections
        self.collectionPapers = collectionPapers
        self.citationSnapshots = citationSnapshots
        self.bibTeXRecords = bibTeXRecords
        self.fullTextDocuments = fullTextDocuments
        self.evidenceChunks = evidenceChunks
        self.evidenceAnchors = evidenceAnchors
        self.visionArtifacts = visionArtifacts
        self.syncBatches = syncBatches
        self.authorIndexGenerations = authorIndexGenerations
        self.paperRevisionSnapshots = paperRevisionSnapshots
        self.radarEvents = radarEvents
        self.savedInspireQueries = savedInspireQueries
        self.syncBatchesV3 = syncBatchesV3
        self.syncJobEvents = syncJobEvents
        self.contentBlobs = contentBlobs
        self.orphanedBlobDeletions = orphanedBlobDeletions
        self.documentReferences = documentReferences
        self.userEvidenceAnchors = userEvidenceAnchors
        self.notebookEntries = notebookEntries
        self.notebookAnchorLinks = notebookAnchorLinks
        self.workspaces = workspaces
        self.workspacePaperLinks = workspacePaperLinks
        self.physicsContracts = physicsContracts
        self.physicsContractCells = physicsContractCells
        self.citationEdges = citationEdges
        self.coauthorEdges = coauthorEdges
        self.exportRecords = exportRecords
        self.cloudSyncStates = cloudSyncStates
        self.conflictCopies = conflictCopies
        self.importedBibliographies = importedBibliographies
        self.importConflicts = importConflicts
        self.migrationJournal = migrationJournal
        self.quarantinedEvidenceIDs = quarantinedEvidenceIDs
        self.schemaVersion = max(2, schemaVersion)
        self.v3SchemaVersion = max(3, v3SchemaVersion)
        self.readErrorMessage = readErrorMessage
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(authors: try values.decodeIfPresent([Int: Author].self, forKey: .authors) ?? [:],
                  papers: try values.decodeIfPresent([Int: Paper].self, forKey: .papers) ?? [:],
                  paperAuthorLinks: try values.decodeIfPresent(Set<PaperAuthorLink>.self, forKey: .paperAuthorLinks) ?? [],
                  insights: try values.decodeIfPresent([String: InsightArtifact].self, forKey: .insights) ?? [:],
                  evidenceInsights: try values.decodeIfPresent([String: EvidenceInsightArtifact].self, forKey: .evidenceInsights) ?? [:],
                  checkpoints: try values.decodeIfPresent([String: SyncCheckpoint].self, forKey: .checkpoints) ?? [:],
                  readingStates: try values.decodeIfPresent([Int: ReadingState].self, forKey: .readingStates) ?? [:],
                  notes: try values.decodeIfPresent([UUID: UserNote].self, forKey: .notes) ?? [:],
                  tags: try values.decodeIfPresent([UUID: LibraryTag].self, forKey: .tags) ?? [:],
                  paperTags: try values.decodeIfPresent(Set<PaperTagLink>.self, forKey: .paperTags) ?? [],
                  collections: try values.decodeIfPresent([UUID: PaperCollection].self, forKey: .collections) ?? [:],
                  collectionPapers: try values.decodeIfPresent(Set<CollectionPaperLink>.self, forKey: .collectionPapers) ?? [],
                  citationSnapshots: try values.decodeIfPresent([String: CitationSnapshot].self, forKey: .citationSnapshots) ?? [:],
                  bibTeXRecords: try values.decodeIfPresent([Int: BibTeXRecord].self, forKey: .bibTeXRecords) ?? [:],
                  fullTextDocuments: try values.decodeIfPresent([String: FullTextDocument].self, forKey: .fullTextDocuments) ?? [:],
                  evidenceChunks: try values.decodeIfPresent([String: EvidenceChunk].self, forKey: .evidenceChunks) ?? [:],
                  evidenceAnchors: try values.decodeIfPresent([String: EvidenceAnchor].self, forKey: .evidenceAnchors) ?? [:],
                  visionArtifacts: try values.decodeIfPresent([String: VisionArtifact].self, forKey: .visionArtifacts) ?? [:],
                  syncBatches: try values.decodeIfPresent([UUID: SyncBatch].self, forKey: .syncBatches) ?? [:],
                  authorIndexGenerations: try values.decodeIfPresent([String: AuthorIndexGeneration].self, forKey: .authorIndexGenerations) ?? [:],
                  paperRevisionSnapshots: try values.decodeIfPresent([String: PaperRevisionSnapshot].self, forKey: .paperRevisionSnapshots) ?? [:],
                  radarEvents: try values.decodeIfPresent([UUID: RadarEvent].self, forKey: .radarEvents) ?? [:],
                  savedInspireQueries: try values.decodeIfPresent([UUID: SavedInspireQuery].self, forKey: .savedInspireQueries) ?? [:],
                  syncBatchesV3: try values.decodeIfPresent([UUID: SyncBatchV3].self, forKey: .syncBatchesV3) ?? [:],
                  syncJobEvents: try values.decodeIfPresent([UUID: SyncJobEvent].self, forKey: .syncJobEvents) ?? [:],
                  contentBlobs: try values.decodeIfPresent([String: ContentBlob].self, forKey: .contentBlobs) ?? [:],
                  orphanedBlobDeletions: try values.decodeIfPresent([String: OrphanedBlobDeletion].self, forKey: .orphanedBlobDeletions) ?? [:],
                  documentReferences: try values.decodeIfPresent([String: DocumentReference].self, forKey: .documentReferences) ?? [:],
                  userEvidenceAnchors: try values.decodeIfPresent([UUID: UserEvidenceAnchor].self, forKey: .userEvidenceAnchors) ?? [:],
                  notebookEntries: try values.decodeIfPresent([UUID: NotebookEntry].self, forKey: .notebookEntries) ?? [:],
                  notebookAnchorLinks: try values.decodeIfPresent(Set<NotebookAnchorLink>.self, forKey: .notebookAnchorLinks) ?? [],
                  workspaces: try values.decodeIfPresent([UUID: PaperWorkspace].self, forKey: .workspaces) ?? [:],
                  workspacePaperLinks: try values.decodeIfPresent(Set<WorkspacePaperLink>.self, forKey: .workspacePaperLinks) ?? [],
                  physicsContracts: try values.decodeIfPresent([UUID: PhysicsContract].self, forKey: .physicsContracts) ?? [:],
                  physicsContractCells: try values.decodeIfPresent([UUID: PhysicsContractCell].self, forKey: .physicsContractCells) ?? [:],
                  citationEdges: try values.decodeIfPresent([String: CitationEdge].self, forKey: .citationEdges) ?? [:],
                  coauthorEdges: try values.decodeIfPresent([String: CoauthorEdge].self, forKey: .coauthorEdges) ?? [:],
                  exportRecords: try values.decodeIfPresent([UUID: ExportRecord].self, forKey: .exportRecords) ?? [:],
                  cloudSyncStates: try values.decodeIfPresent([String: CloudSyncRecordState].self, forKey: .cloudSyncStates) ?? [:],
                  conflictCopies: try values.decodeIfPresent([UUID: ConflictCopy].self, forKey: .conflictCopies) ?? [:],
                  importedBibliographies: try values.decodeIfPresent([UUID: V3ImportedBibliography].self, forKey: .importedBibliographies) ?? [:],
                  importConflicts: try values.decodeIfPresent([UUID: V3ImportConflict].self, forKey: .importConflicts) ?? [:],
                  migrationJournal: try values.decodeIfPresent([UUID: V3MigrationJournalEntry].self, forKey: .migrationJournal) ?? [:],
                  quarantinedEvidenceIDs: try values.decodeIfPresent(Set<String>.self, forKey: .quarantinedEvidenceIDs) ?? [],
                  schemaVersion: try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
                  v3SchemaVersion: try values.decodeIfPresent(Int.self, forKey: .v3SchemaVersion) ?? 3,
                  readErrorMessage: try values.decodeIfPresent(String.self, forKey: .readErrorMessage))
    }
}

enum SearchNormalizer {
    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
            .lowercased()
    }
}
