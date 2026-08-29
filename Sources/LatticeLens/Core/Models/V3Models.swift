import Foundation

// MARK: - v3 Evidence Workbench records

enum RadarEventKind: String, Codable, CaseIterable, Sendable {
    case newPaper
    case recordRevised
    case citationChanged
    case newDocument
    case newFigure
    case publicationChanged
    // v4 semantic field events.  They are intentionally distinct from the
    // legacy `newDocument`/`newFigure` kinds so a removal can never be shown
    // as a new record.
    case fieldAdded
    case fieldRemoved
    case fieldModified

    var displayNameZH: String {
        switch self {
        case .newPaper: "新论文"
        case .recordRevised: "记录修订"
        case .citationChanged: "引用变化"
        case .newDocument: "新增全文"
        case .newFigure: "新增图像"
        case .publicationChanged: "发表状态变化"
        case .fieldAdded: "字段新增"
        case .fieldRemoved: "字段移除"
        case .fieldModified: "字段修改"
        }
    }
}

struct AuthorIndexGeneration: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let query: String
    let startedAt: Date
    var completedAt: Date?
    var state: SyncCheckpointState
    var activeMembership: Set<Int>
    var stagingMembership: Set<Int>
    var pageCount: Int
    var hQueueCompleted: Int
    var hQueuePending: Int
    var hQueueFailed: Int
    var hQueueCancelled: Int
    var lastCheckpointAt: Date?
}

struct PaperRevisionSnapshot: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let paperID: Int
    let recordHash: String
    let titleHash: String
    let abstractHash: String
    let citationCount: Int?
    let documentsHash: String
    let figuresHash: String
    let publicationHash: String
    let observedAt: Date
    let sourceURL: URL
    let syncBatchID: UUID
}

struct RadarEvent: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let paperID: Int
    let authorRecids: [Int]
    let eventKind: RadarEventKind
    let beforeHash: String?
    let afterHash: String
    let changedFields: [String]
    let syncBatchID: UUID
    let observedAt: Date
    let sourceURL: URL
    var isAcknowledged: Bool
    /// Explicit transitions preserve unknown citation counts; nil is never
    /// silently normalized to zero. Optional defaults keep v2 JSON decodable.
    var beforeCitationCount: Int? = nil
    var afterCitationCount: Int? = nil
}

enum SavedQueryRefreshPolicy: String, Codable, CaseIterable, Sendable {
    case manual
    case onLaunch
    case daily
    case weekly

    var displayNameZH: String {
        switch self { case .manual: "手动"; case .onLaunch: "启动时"; case .daily: "每天"; case .weekly: "每周" }
    }
}

struct SavedInspireQuery: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var query: String
    var refreshPolicy: SavedQueryRefreshPolicy
    var isPaused: Bool
    var lastRunAt: Date?
    var nextRunAt: Date?
    var createdAt: Date
}

struct SyncBatchV3: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let jobID: String
    let generationID: String
    let startedAt: Date
    var completedAt: Date?
    var state: SyncCheckpointState
    var newRecords: Int
    var metadataUpdated: Int
    var citationChanged: Int
    var unchanged: Int
    var failed: Int
    var durationMilliseconds: Int?
}

enum SyncJobEventKind: String, Codable, CaseIterable, Sendable {
    case pageStarted
    case pageCompleted
    case hIndexCompleted
    case recordFailed
    case cancelled
    case completed
}

struct SyncJobEvent: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let batchID: UUID
    let jobID: String
    let kind: SyncJobEventKind
    let page: Int?
    let completed: Int
    let qualified: Int
    let rejected: Int
    let failed: Int
    let remaining: Int?
    let observedAt: Date
    let message: String?
}

struct ContentBlob: Codable, Hashable, Identifiable, Sendable {
    let hash: String
    let byteCount: Int
    var localFilename: String?
    var referenceCount: Int
    var createdAt: Date
    var id: String { hash }
}

/// Durable post-commit cleanup obligation for an app-owned content-addressed
/// file.  The document/reference mutation has already committed; a retry may
/// delete the file only after rechecking this exact hash and byte count.
struct OrphanedBlobDeletion: Codable, Hashable, Identifiable, Sendable {
    let blobHash: String
    let filename: String
    let byteCount: Int
    var retryCount: Int
    var lastErrorCategory: String
    let createdAt: Date
    var updatedAt: Date
    var id: String { blobHash }
}

struct VisionPreflight: Codable, Hashable, Sendable {
    let paperID: Int
    let figureKeys: [String]
    let originalDimensions: [String: [Int]]
    let resizedDimensions: [String: [Int]]
    let imageBytes: [String: Int]
    let totalBytes: Int
    let endpoint: String
    let requestCount: Int
    let frozenHash: String
}

struct DocumentReference: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let paperID: Int
    let documentHash: String
    let sourceURL: URL
    let sourceKind: FullTextSourceKind
    let contentBlobHash: String
    var isDeleted: Bool
}

enum UserEvidenceAnchorStatus: String, Codable, CaseIterable, Sendable {
    case valid
    case stale
    case quarantined
}

struct UserEvidenceAnchor: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let paperID: Int
    let documentHash: String?
    let sourceKind: EvidenceSourceKind
    let page: Int?
    let characterRangeStart: Int?
    let characterRangeEnd: Int?
    let quote: String
    let quoteHash: String
    var colorName: String
    var label: String
    var note: String
    var status: UserEvidenceAnchorStatus
    let createdAt: Date
    var updatedAt: Date
}

/// A user-authored notebook record may reference several independently
/// auditable annotation/evidence anchors.  It is deliberately paper-scoped:
/// cross-paper comparison belongs in a Compare workspace, not in a notebook
/// entry that could otherwise make foreign evidence look local.
struct NotebookEntry: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let paperID: Int
    var title: String
    var body: String
    let createdAt: Date
    var updatedAt: Date
}

struct NotebookAnchorLink: Codable, Hashable, Sendable {
    let entryID: UUID
    let anchorID: String
    var sortIndex: Int
}

struct PaperWorkspace: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var sortOrder: [Int]
    var note: String
    var frozenExportHash: String?
}

struct WorkspacePaperLink: Codable, Hashable, Sendable {
    let workspaceID: UUID
    let paperID: Int
    let addedAt: Date
    var sortIndex: Int
}

enum PhysicsCellStatus: String, Codable, CaseIterable, Sendable {
    case direct
    case inference
    case crossPaperInference = "cross_paper_inference"
    case missing
    /// A limitation or qualification.  It may be anchor-free only when it
    /// carries no factual value; see `V4PhysicsValidator` for the enforced
    /// truth-table boundary.
    case caveat
    case stale

    var displayNameZH: String {
        switch self {
        case .direct: "直接证据"
        case .inference: "合理推断"
        case .crossPaperInference: "跨论文推断"
        case .missing: "缺失"
        case .caveat: "限制"
        case .stale: "已过期"
        }
    }
}

struct PhysicsContractCell: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let workspaceID: UUID
    let rowKey: String
    let paperID: Int
    var value: String?
    var unit: String?
    var status: PhysicsCellStatus
    var evidenceAnchorIDs: [String]
    var extractionVersion: String
    var sourceDocumentHash: String?
    var updatedAt: Date
}

struct PhysicsContract: Codable, Hashable, Identifiable, Sendable {
    static let defaultRows = [
        "observable_research_question", "action_ensemble", "lattice_geometry", "lattice_spacing",
        "pion_hadron_mass", "momentum_boost_smearing", "source_sink_tsep_operator",
        "correlator_ratio_fit", "renormalization", "fourier_convention", "matching",
        "continuum_chiral_volume_extrapolation", "statistics_systematics"
    ]

    let id: UUID
    let workspaceID: UUID
    let rowKeys: [String]
    let createdAt: Date
    var updatedAt: Date
}

enum GraphEdgeKind: String, Codable, CaseIterable, Sendable {
    case citation
    case coauthor
}

struct CitationEdge: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let fromPaperID: Int
    let toPaperID: Int
    let sourceURL: URL
    let fetchedAt: Date
    let query: String
    let batchID: UUID
    var idValue: String { id }
}

struct CoauthorEdge: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let authorRecid: Int
    let coauthorRecid: Int
    let sourcePaperID: Int
    let sourceURL: URL
    let fetchedAt: Date
    let query: String
    let batchID: UUID
    var idValue: String { id }
}

enum V3ExportFormat: String, Codable, CaseIterable, Sendable {
    case bibtex
    case markdownNotebook
    case ris
    case cslJSON
    case provenanceJSON

    var displayNameZH: String {
        switch self {
        case .bibtex: "BibTeX"
        case .markdownNotebook: "Markdown 笔记本"
        case .ris: "RIS"
        case .cslJSON: "CSL-JSON"
        case .provenanceJSON: "来源 JSON"
        }
    }
}

enum AIArtifactClearScope: String, CaseIterable, Hashable, Sendable {
    case insight
    case evidenceInsight
    case vision
    case all
}

struct ExportRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let format: V3ExportFormat
    let paperIDs: [Int]
    let destinationCategory: String
    let sourceHashes: [String]
    let createdAt: Date
    let payloadHash: String
    var succeeded: Bool
    var errorCategory: String?
}

struct CloudSyncRecordState: Codable, Hashable, Identifiable, Sendable {
    let recordID: String
    let recordType: String
    let fieldHash: String
    let pushedAt: Date?
    let pulledAt: Date?
    var id: String { recordID }
}

struct ConflictCopy: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let recordID: String
    let originalFieldHash: String
    let conflictingFieldHash: String
    let payload: String
    let createdAt: Date
}

struct V3MigrationJournalEntry: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let sourceSchema: Int
    let targetSchema: Int
    let startedAt: Date
    var completedAt: Date?
    var phase: String
    var preCount: Int
    var postCount: Int?
    var preHash: String
    var postHash: String?
    var quarantinedCount: Int
    var errorCategory: String?
}

enum LibrarySnapshotReadState: Codable, Equatable, Sendable {
    case ready
    case recovered
    case readOnlyFailure
}

struct LibrarySnapshotReadResult: Sendable {
    let state: LibrarySnapshotReadState
    let snapshot: LibrarySnapshot
    let message: String?
}

enum V3Mutation: Sendable {
    case deleteInsight(String)
    case deleteEvidenceInsight(String)
    case deleteVisionArtifact(String)
    case saveGeneration(AuthorIndexGeneration)
    case saveRevision(PaperRevisionSnapshot)
    case saveRadarEvent(RadarEvent)
    case acknowledgeRadarEvent(UUID)
    case saveQuery(SavedInspireQuery)
    case deleteQuery(UUID)
    case saveBatch(SyncBatchV3)
    case saveJobEvent(SyncJobEvent)
    case saveBlob(ContentBlob)
    case saveOrphanedBlobDeletion(OrphanedBlobDeletion)
    case deleteOrphanedBlobDeletion(blobHash: String)
    case saveDocumentReference(DocumentReference)
    case saveUserAnchor(UserEvidenceAnchor)
    case deleteUserAnchor(UUID)
    case saveNotebookEntry(NotebookEntry)
    case deleteNotebookEntry(UUID)
    case replaceNotebookAnchorLinks(entryID: UUID, links: [NotebookAnchorLink])
    case saveWorkspace(PaperWorkspace)
    case deleteWorkspace(UUID)
    case saveWorkspaceLink(WorkspacePaperLink)
    case deleteWorkspaceLink(workspaceID: UUID, paperID: Int)
    case savePhysicsContract(PhysicsContract)
    case savePhysicsCell(PhysicsContractCell)
    /// Validated as a complete matrix by the workbench service and then
    /// committed in one durable store mutation.  This avoids a half-replaced
    /// Compare table when any proposed cell fails evidence validation.
    case replacePhysicsMatrix(workspaceID: UUID, cells: [PhysicsContractCell])
    case saveCitationEdge(CitationEdge)
    case saveCoauthorEdge(CoauthorEdge)
    case saveExport(ExportRecord)
    case saveCloudState(CloudSyncRecordState)
    case saveConflict(ConflictCopy)
    case saveMigrationJournal(V3MigrationJournalEntry)
    case saveImportedBibliography(V3ImportedBibliography)
    case saveImportConflict(V3ImportConflict)
    case setImportConflictStatus(importedID: UUID, status: V3ImportReviewStatus)
    case quarantineEvidence(id: String)
}
