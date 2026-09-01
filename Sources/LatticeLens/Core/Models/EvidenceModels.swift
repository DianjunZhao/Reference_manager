import Foundation

struct ReadingState: Codable, Hashable, Sendable {
    let paperID: Int
    var isRead: Bool
    var readAt: Date?
    var isFavorite: Bool
    var updatedAt: Date
}

struct UserNote: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let paperID: Int
    var body: String
    var createdAt: Date
    var updatedAt: Date
}

struct LibraryTag: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var colorName: String?
    var createdAt: Date
}

struct PaperTagLink: Codable, Hashable, Sendable {
    let paperID: Int
    let tagID: UUID
}

struct PaperCollection: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var createdAt: Date
}

struct CollectionPaperLink: Codable, Hashable, Sendable {
    let collectionID: UUID
    let paperID: Int
    let addedAt: Date
}

struct CitationSnapshot: Codable, Hashable, Identifiable, Sendable {
    let paperID: Int
    let citationCount: Int
    let fetchedAt: Date
    var id: String { "\(paperID):\(fetchedAt.ISO8601Format())" }
}

/// The citation text is owned by INSPIRE.  This record is created only after a
/// syntactically valid endpoint response; it never represents app-generated
/// BibTeX with guessed fields.
struct BibTeXRecord: Codable, Hashable, Identifiable, Sendable {
    let paperID: Int
    let sourceURL: URL
    let sourceFetchedAt: Date
    let contents: String
    var id: Int { paperID }
}

enum FullTextSourceKind: String, Codable, CaseIterable, Sendable {
    case inspireDocument
    case arxivPDF
    /// ar5iv renders the arXiv source as HTML.  It is kept separate from the
    /// PDF source so provenance is visible in the paper context and exports.
    case arxivHTML

    var displayNameZH: String {
        switch self {
        case .inspireDocument: "INSPIRE 文档"
        case .arxivPDF: "arXiv PDF"
        case .arxivHTML: "ar5iv HTML"
        }
    }
}

enum FullTextExtractionState: String, Codable, Sendable {
    case notDownloaded
    case downloading
    case downloaded
    case extracting
    case extracted
    case textExtractionUnavailable
    case failed
    case deleted

    var displayNameZH: String {
        switch self {
        case .notDownloaded: "未下载"
        case .downloading: "下载中"
        case .downloaded: "已下载"
        case .extracting: "提取中"
        case .extracted: "已提取"
        case .textExtractionUnavailable: "无法提取文本"
        case .failed: "失败"
        case .deleted: "已删除"
        }
    }
}

struct FullTextDocument: Codable, Hashable, Identifiable, Sendable {
    let paperID: Int
    let sourceURL: URL
    let sourceKind: FullTextSourceKind
    let sha256: String
    let byteCount: Int
    var localFilename: String?
    var pageCount: Int?
    var extractionState: FullTextExtractionState
    var downloadedAt: Date?
    var lastErrorCategory: String?
    var id: String { "\(paperID):\(sha256)" }
}

struct EvidenceChunk: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let paperID: Int
    let documentHash: String
    let page: Int
    let section: String?
    let characterRangeStart: Int
    let characterRangeEnd: Int
    let text: String
    let textHash: String
    /// Bounded local accounting used by the evidence payload contract.  These
    /// values are derived before a request is built and never contain source
    /// text themselves.
    let byteCount: Int
    let scalarCount: Int
    let tokenEstimate: Int

    init(id: String, paperID: Int, documentHash: String, page: Int, section: String?,
         characterRangeStart: Int, characterRangeEnd: Int, text: String, textHash: String,
         byteCount: Int? = nil, scalarCount: Int? = nil, tokenEstimate: Int? = nil) {
        self.id = id
        self.paperID = paperID
        self.documentHash = documentHash
        self.page = page
        self.section = section
        self.characterRangeStart = characterRangeStart
        self.characterRangeEnd = characterRangeEnd
        self.text = text
        self.textHash = textHash
        self.byteCount = byteCount ?? text.utf8.count
        self.scalarCount = scalarCount ?? text.unicodeScalars.count
        self.tokenEstimate = tokenEstimate ?? max(1, text.split { $0.isWhitespace || $0.isPunctuation }.count)
    }

    private enum CodingKeys: String, CodingKey {
        case id, paperID, documentHash, page, section, characterRangeStart, characterRangeEnd, text, textHash
        case byteCount, scalarCount, tokenEstimate
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  paperID: try values.decode(Int.self, forKey: .paperID),
                  documentHash: try values.decode(String.self, forKey: .documentHash),
                  page: try values.decode(Int.self, forKey: .page),
                  section: try values.decodeIfPresent(String.self, forKey: .section),
                  characterRangeStart: try values.decode(Int.self, forKey: .characterRangeStart),
                  characterRangeEnd: try values.decode(Int.self, forKey: .characterRangeEnd),
                  text: try values.decode(String.self, forKey: .text),
                  textHash: try values.decode(String.self, forKey: .textHash),
                  byteCount: try values.decodeIfPresent(Int.self, forKey: .byteCount),
                  scalarCount: try values.decodeIfPresent(Int.self, forKey: .scalarCount),
                  tokenEstimate: try values.decodeIfPresent(Int.self, forKey: .tokenEstimate))
    }
}

enum EvidenceSourceKind: String, Codable, CaseIterable, Sendable {
    case abstract
    case caption
    case pdf

    var displayNameZH: String {
        switch self { case .abstract: "摘要"; case .caption: "图注"; case .pdf: "全文" }
    }
}

struct EvidenceAnchor: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let paperID: Int
    let sourceKind: EvidenceSourceKind
    let page: Int?
    let section: String?
    let quote: String
    let quoteHash: String
    let figureKey: String?
}

enum EpistemicStatus: String, Codable, CaseIterable, Sendable {
    case direct
    case inference
    case missing

    var displayNameZH: String {
        switch self {
        case .direct: "原文直接支持"
        case .inference: "基于原文的推断"
        case .missing: "原文未提供"
        }
    }
}

struct EvidenceClaim: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let textZH: String
    let epistemicStatus: EpistemicStatus
    let evidenceIDs: [String]
    /// Optional structured fields used by formula-focused v2 evidence. They
    /// remain optional so previously cached claim artifacts decode unchanged.
    let formulaTeX: String?
    let derivationSteps: [String]
    let conclusionZH: String?

    enum CodingKeys: String, CodingKey {
        case textZH = "text_zh"
        case epistemicStatus = "epistemic_status"
        case evidenceIDs = "evidence_ids"
        case formulaTeX = "formula_tex"
        case derivationSteps = "derivation_steps"
        case conclusionZH = "conclusion_zh"
    }

    init(id: UUID = UUID(), textZH: String, epistemicStatus: EpistemicStatus, evidenceIDs: [String],
         formulaTeX: String? = nil, derivationSteps: [String] = [], conclusionZH: String? = nil) {
        self.id = id
        self.textZH = textZH
        self.epistemicStatus = epistemicStatus
        self.evidenceIDs = evidenceIDs
        self.formulaTeX = formulaTeX
        self.derivationSteps = derivationSteps
        self.conclusionZH = conclusionZH
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(textZH: try values.decode(String.self, forKey: .textZH),
                  epistemicStatus: try values.decode(EpistemicStatus.self, forKey: .epistemicStatus),
                  evidenceIDs: try values.decode([String].self, forKey: .evidenceIDs),
                  formulaTeX: try values.decodeIfPresent(String.self, forKey: .formulaTeX),
                  derivationSteps: try values.decodeIfPresent([String].self, forKey: .derivationSteps) ?? [],
                  conclusionZH: try values.decodeIfPresent(String.self, forKey: .conclusionZH))
    }
}

struct InsightPhysicsV2: Codable, Hashable, Sendable {
    let researchQuestion: EvidenceClaim
    let methodAndDataFlow: [EvidenceClaim]
    let mainResults: [EvidenceClaim]
    let reasonableInferences: [EvidenceClaim]
    let missingInformation: [EvidenceClaim]
    let caveats: [EvidenceClaim]
    /// Formula-focused derivations generated only from the retrieved PDF
    /// anchors.  Older cached v2 artifacts may omit this field; decoding then
    /// yields an empty list and remains backward compatible.
    let importantFormulaDerivations: [EvidenceClaim]

    enum CodingKeys: String, CodingKey {
        case researchQuestion = "research_question"
        case methodAndDataFlow = "method_and_data_flow"
        case mainResults = "main_results"
        case reasonableInferences = "reasonable_inferences"
        case missingInformation = "missing_information"
        case caveats
        case importantFormulaDerivations = "important_formula_derivations"
    }

    init(researchQuestion: EvidenceClaim, methodAndDataFlow: [EvidenceClaim], mainResults: [EvidenceClaim],
         reasonableInferences: [EvidenceClaim], missingInformation: [EvidenceClaim], caveats: [EvidenceClaim],
         importantFormulaDerivations: [EvidenceClaim] = []) {
        self.researchQuestion = researchQuestion
        self.methodAndDataFlow = methodAndDataFlow
        self.mainResults = mainResults
        self.reasonableInferences = reasonableInferences
        self.missingInformation = missingInformation
        self.caveats = caveats
        self.importantFormulaDerivations = importantFormulaDerivations
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            researchQuestion: try values.decode(EvidenceClaim.self, forKey: .researchQuestion),
            methodAndDataFlow: try values.decode([EvidenceClaim].self, forKey: .methodAndDataFlow),
            mainResults: try values.decode([EvidenceClaim].self, forKey: .mainResults),
            reasonableInferences: try values.decode([EvidenceClaim].self, forKey: .reasonableInferences),
            missingInformation: try values.decode([EvidenceClaim].self, forKey: .missingInformation),
            caveats: try values.decode([EvidenceClaim].self, forKey: .caveats),
            importantFormulaDerivations: try values.decodeIfPresent([EvidenceClaim].self, forKey: .importantFormulaDerivations) ?? [])
    }
}

struct PaperInsightV2: Codable, Hashable, Sendable {
    let schemaVersion: String
    let sourceScope: String
    let titleZH: String
    let abstractZH: String
    let physics: InsightPhysicsV2
    let importantFigures: [ImportantFigureInsight]
    let terminology: [InsightTerminology]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sourceScope = "source_scope"
        case titleZH = "title_zh"
        case abstractZH = "abstract_zh"
        case physics
        case importantFigures = "important_figures"
        case terminology
    }
}

struct EvidenceInsightArtifact: Codable, Hashable, Identifiable, Sendable {
    let cacheKey: String
    let paperID: Int
    let documentHash: String
    let chunkIDs: [String]
    let insight: PaperInsightV2
    let createdAt: Date
    let retrievalQuery: String
    let rankerVersion: String
    let selectedChunkIDs: [String]
    let promptVersion: String
    let schemaVersion: String
    let payloadHash: String
    let payloadByteCount: Int
    let payloadScalarCount: Int
    var isStale: Bool
    var id: String { cacheKey }

    init(cacheKey: String, paperID: Int, documentHash: String, chunkIDs: [String], insight: PaperInsightV2,
         createdAt: Date, retrievalQuery: String = "paper title terms", rankerVersion: String = "local-title-token-v1",
         selectedChunkIDs: [String]? = nil, promptVersion: String = EvidenceInsightPrompt.version,
         schemaVersion: String = PaperInsightV2Validator.schemaVersion, payloadHash: String = "",
         payloadByteCount: Int = 0, payloadScalarCount: Int = 0, isStale: Bool = false) {
        self.cacheKey = cacheKey
        self.paperID = paperID
        self.documentHash = documentHash
        self.chunkIDs = chunkIDs
        self.insight = insight
        self.createdAt = createdAt
        self.retrievalQuery = retrievalQuery
        self.rankerVersion = rankerVersion
        self.selectedChunkIDs = selectedChunkIDs ?? chunkIDs
        self.promptVersion = promptVersion
        self.schemaVersion = schemaVersion
        self.payloadHash = payloadHash
        self.payloadByteCount = payloadByteCount
        self.payloadScalarCount = payloadScalarCount
        self.isStale = isStale
    }

    private enum CodingKeys: String, CodingKey {
        case cacheKey, paperID, documentHash, chunkIDs, insight, createdAt, retrievalQuery, rankerVersion
        case selectedChunkIDs, promptVersion, schemaVersion, payloadHash, payloadByteCount, payloadScalarCount, isStale
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(cacheKey: try values.decode(String.self, forKey: .cacheKey),
                  paperID: try values.decode(Int.self, forKey: .paperID),
                  documentHash: try values.decode(String.self, forKey: .documentHash),
                  chunkIDs: try values.decode([String].self, forKey: .chunkIDs),
                  insight: try values.decode(PaperInsightV2.self, forKey: .insight),
                  createdAt: try values.decode(Date.self, forKey: .createdAt),
                  retrievalQuery: try values.decodeIfPresent(String.self, forKey: .retrievalQuery) ?? "legacy",
                  rankerVersion: try values.decodeIfPresent(String.self, forKey: .rankerVersion) ?? "legacy",
                  selectedChunkIDs: try values.decodeIfPresent([String].self, forKey: .selectedChunkIDs),
                  promptVersion: try values.decodeIfPresent(String.self, forKey: .promptVersion) ?? "legacy",
                  schemaVersion: try values.decodeIfPresent(String.self, forKey: .schemaVersion) ?? PaperInsightV2Validator.schemaVersion,
                  payloadHash: try values.decodeIfPresent(String.self, forKey: .payloadHash) ?? "",
                  payloadByteCount: try values.decodeIfPresent(Int.self, forKey: .payloadByteCount) ?? 0,
                  payloadScalarCount: try values.decodeIfPresent(Int.self, forKey: .payloadScalarCount) ?? 0,
                  isStale: try values.decodeIfPresent(Bool.self, forKey: .isStale) ?? false)
    }
}

/// Cache identity for a full-text evidence analysis.  It intentionally differs
/// from the v1 abstract/caption cache: changing either the PDF bytes, retrieved
/// anchors, source scope, provider capability or terminology creates a new
/// artifact instead of silently reusing an explanation with weaker provenance.
struct EvidenceInsightCacheKey: Hashable, Sendable {
    let paperID: Int
    let paperUpdated: Date?
    let documentHash: String
    let chunkIDs: [String]
    let promptVersion: String
    let schemaVersion: String
    let sourceScope: String
    let provider: String
    let normalizedBaseURL: String
    let model: String
    let credentialRevision: Int
    let mode: InsightMode
    let detailLevel: InsightDetailLevel
    let maximumFigures: Int
    let terminologyHash: String
    let providerCapabilityHash: String

    var value: String {
        let fields = [
            String(paperID), paperUpdated?.ISO8601Format() ?? "", documentHash,
            chunkIDs.sorted().joined(separator: "|"), promptVersion, schemaVersion,
            sourceScope, provider, normalizedBaseURL, model, String(credentialRevision),
            mode.rawValue, detailLevel.rawValue, String(maximumFigures), terminologyHash,
            providerCapabilityHash
        ]
        return StableHash.sha256(fields.joined(separator: "|"))
    }
}

enum EvidenceAnchorFactory {
    static let maximumMetadataQuoteScalars = 12_000

    /// Abstract/caption anchors are generated locally from the preserved
    /// INSPIRE metadata.  They make the Evidence Lens useful before a PDF is
    /// explicitly downloaded, while never promoting the scope to full text.
    static func metadataAnchors(for paper: Paper) -> [EvidenceAnchor] {
        var anchors: [EvidenceAnchor] = []
        for (index, abstract) in paper.abstracts.enumerated() {
            let quote = bounded(abstract.value)
            guard !quote.isEmpty else { continue }
            let hash = StableHash.sha256(quote)
            anchors.append(EvidenceAnchor(
                id: "abstract:\(paper.literatureID):\(index + 1):\(hash.prefix(12))",
                paperID: paper.literatureID,
                sourceKind: .abstract,
                page: nil,
                section: abstract.source,
                quote: quote,
                quoteHash: hash,
                figureKey: nil
            ))
        }
        for figure in paper.figures {
            guard let caption = figure.caption else { continue }
            let quote = bounded(caption)
            guard !quote.isEmpty else { continue }
            let hash = StableHash.sha256(quote)
            anchors.append(EvidenceAnchor(
                id: "caption:\(paper.literatureID):\(figure.key):\(hash.prefix(12))",
                paperID: paper.literatureID,
                sourceKind: .caption,
                page: nil,
                section: figure.label ?? figure.source,
                quote: quote,
                quoteHash: hash,
                figureKey: figure.key
            ))
        }
        return anchors.sorted { $0.id < $1.id }
    }

    private static func bounded(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.prefix(maximumMetadataQuoteScalars)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct VisionFigureInsight: Codable, Hashable, Identifiable, Sendable {
    let figureKey: String
    let textZH: String
    let evidenceMode: String

    var id: String { figureKey }

    enum CodingKeys: String, CodingKey {
        case figureKey = "figure_key"
        case textZH = "text_zh"
        case evidenceMode = "evidence_mode"
    }
}

struct VisionArtifact: Codable, Hashable, Identifiable, Sendable {
    let cacheKey: String
    let paperID: Int
    let figureKeys: [String]
    let imageHashes: [String]
    let provider: String
    let model: String
    let createdAt: Date
    let text: String
    let insights: [VisionFigureInsight]
    let imageByteCounts: [Int]
    let preflightHash: String?
    let endpoint: String?
    let originalDimensions: [[Int]]
    let resizedDimensions: [[Int]]
    let totalBytes: Int
    let requestCount: Int
    var id: String { cacheKey }

    init(cacheKey: String, paperID: Int, figureKeys: [String], imageHashes: [String], provider: String, model: String,
         createdAt: Date, text: String, insights: [VisionFigureInsight], imageByteCounts: [Int] = [],
         preflightHash: String? = nil, endpoint: String? = nil, originalDimensions: [[Int]] = [],
         resizedDimensions: [[Int]] = [], totalBytes: Int = 0, requestCount: Int = 1) {
        self.cacheKey = cacheKey
        self.paperID = paperID
        self.figureKeys = figureKeys
        self.imageHashes = imageHashes
        self.provider = provider
        self.model = model
        self.createdAt = createdAt
        self.text = text
        self.insights = insights
        self.imageByteCounts = imageByteCounts
        self.preflightHash = preflightHash
        self.endpoint = endpoint
        self.originalDimensions = originalDimensions
        self.resizedDimensions = resizedDimensions
        self.totalBytes = totalBytes
        self.requestCount = requestCount
    }

    private enum CodingKeys: String, CodingKey {
        case cacheKey, paperID, figureKeys, imageHashes, provider, model, createdAt, text, insights, imageByteCounts, preflightHash, endpoint
        case originalDimensions, resizedDimensions, totalBytes, requestCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(cacheKey: try values.decode(String.self, forKey: .cacheKey),
                  paperID: try values.decode(Int.self, forKey: .paperID),
                  figureKeys: try values.decodeIfPresent([String].self, forKey: .figureKeys) ?? [],
                  imageHashes: try values.decodeIfPresent([String].self, forKey: .imageHashes) ?? [],
                  provider: try values.decode(String.self, forKey: .provider),
                  model: try values.decode(String.self, forKey: .model),
                  createdAt: try values.decode(Date.self, forKey: .createdAt),
                  text: try values.decodeIfPresent(String.self, forKey: .text) ?? "",
                  insights: try values.decodeIfPresent([VisionFigureInsight].self, forKey: .insights) ?? [],
                  imageByteCounts: try values.decodeIfPresent([Int].self, forKey: .imageByteCounts) ?? [],
                  preflightHash: try values.decodeIfPresent(String.self, forKey: .preflightHash),
                  endpoint: try values.decodeIfPresent(String.self, forKey: .endpoint),
                  originalDimensions: try values.decodeIfPresent([[Int]].self, forKey: .originalDimensions) ?? [],
                  resizedDimensions: try values.decodeIfPresent([[Int]].self, forKey: .resizedDimensions) ?? [],
                  totalBytes: try values.decodeIfPresent(Int.self, forKey: .totalBytes) ?? 0,
                  requestCount: try values.decodeIfPresent(Int.self, forKey: .requestCount) ?? 1)
    }
}

struct SyncBatch: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let jobID: String
    let startedAt: Date
    var completedAt: Date?
    var state: SyncCheckpointState
    var newRecords: Int
    var metadataUpdatedRecords: Int
    var citationChangedRecords: Int
    var failureCount: Int
}
