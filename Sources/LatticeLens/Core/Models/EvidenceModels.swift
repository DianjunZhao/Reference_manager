import Foundation

/// Builds the deterministic ar5iv HTML URL used by the Evidence reader.
/// INSPIRE has historically emitted an arXiv eprint as a bare identifier,
/// `arXiv:<id>`, or an abs/pdf URL.  Normalize those equivalent forms before
/// interpolating the identifier into the allow-listed HTTPS path.  This helper
/// never performs network I/O and returns nil for malformed/untrusted input.
enum ArxivHTMLLink {
    static let host = "ar5iv.labs.arxiv.org"

    static func normalizedIdentifier(from raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 256 else { return nil }

        if let url = URL(string: value), let urlHost = url.host?.lowercased() {
            if ["arxiv.org", "export.arxiv.org", host].contains(urlHost) {
                guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
                let path = url.path
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if let marker = ["abs/", "pdf/", "html/"].first(where: { path.lowercased().hasPrefix($0) }) {
                    value = String(path.dropFirst(marker.count))
                }
            }
        }

        if let colon = value.firstIndex(of: ":"), value[..<colon].lowercased() == "arxiv" {
            value = String(value[value.index(after: colon)...])
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if value.lowercased().hasSuffix(".pdf") { value.removeLast(4) }
        guard !value.isEmpty, value.count <= 128,
              !value.contains(".."), !value.contains("\\"),
              !value.contains("//"),
              value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/-]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    static func url(for raw: String) -> URL? {
        guard let identifier = normalizedIdentifier(from: raw) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/html/\(identifier)"
        guard let url = components.url,
              url.scheme == "https", url.host == host,
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }
}

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
    /// ar5iv HTML can be re-read locally into a deterministic inventory of
    /// labelled display equations.  `nil` means this document predates that
    /// extraction pass, so it must never be presented as all-equations
    /// coverage.  These optional fields deliberately keep older persisted
    /// stores decodable.
    var numberedEquationIndexVersion: Int? = nil
    var numberedEquationCount: Int? = nil
    /// A current version marker alone is insufficient: every visible ar5iv
    /// equation label must also have produced exactly one TeX-backed record.
    /// `nil` preserves compatibility with documents extracted before this
    /// explicit completeness receipt existed.
    var numberedEquationIndexComplete: Bool? = nil
    var numberedEquationIndexFailure: String? = nil
    /// Stable identity of the complete local formula inventory.  This is
    /// separate from the document hash: a parser-version or structural
    /// extraction change must invalidate formula jobs even when the source
    /// bytes are unchanged.
    var numberedEquationInventoryHash: String? = nil
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
    /// Present only for a display equation that ar5iv itself labelled, for
    /// example `(2.3)` or `(A.1)`.  Regular retrieval chunks remain exactly
    /// compatible with the pre-indexed representation.
    let equationID: String?
    let equationLabel: String?
    let equationTeX: String?
    let equationOrdinal: Int?

    init(id: String, paperID: Int, documentHash: String, page: Int, section: String?,
         characterRangeStart: Int, characterRangeEnd: Int, text: String, textHash: String,
         byteCount: Int? = nil, scalarCount: Int? = nil, tokenEstimate: Int? = nil,
         equationID: String? = nil, equationLabel: String? = nil,
         equationTeX: String? = nil, equationOrdinal: Int? = nil) {
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
        self.equationID = equationID
        self.equationLabel = equationLabel
        self.equationTeX = equationTeX
        self.equationOrdinal = equationOrdinal
    }

    private enum CodingKeys: String, CodingKey {
        case id, paperID, documentHash, page, section, characterRangeStart, characterRangeEnd, text, textHash
        case byteCount, scalarCount, tokenEstimate
        case equationID, equationLabel, equationTeX, equationOrdinal
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
                  tokenEstimate: try values.decodeIfPresent(Int.self, forKey: .tokenEstimate),
                  equationID: try values.decodeIfPresent(String.self, forKey: .equationID),
                  equationLabel: try values.decodeIfPresent(String.self, forKey: .equationLabel),
                  equationTeX: try values.decodeIfPresent(String.self, forKey: .equationTeX),
                  equationOrdinal: try values.decodeIfPresent(Int.self, forKey: .equationOrdinal))
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

enum FormulaStructuralStatus: String, Codable, CaseIterable, Sendable {
    case verifiedStructural = "verified_structural"
    case needsManual = "needs_manual"
    case rejected
}

enum FormulaPhysicsReviewStatus: String, Codable, CaseIterable, Sendable {
    case needsManualPhysics = "needs_manual_physics"
    case reviewedWithReceipt = "reviewed_with_receipt"
}

/// One provenance-bound step in a numbered-equation derivation. The two
/// status dimensions are computed locally: provider JSON cannot claim a
/// structural pass or a human physics review.
struct FormulaDerivationStep: Codable, Hashable, Sendable, Identifiable {
    /// One provider response is deliberately small; a complete derivation is
    /// assembled from at most eight independently checkpointed segments.
    static let maximumStepsPerSegment = 32
    static let maximumSteps = 256

    let stepID: String
    let ordinal: Int
    let textZH: String
    let beforeTeX: String?
    let afterTeX: String?
    let ruleOrAssumption: String
    let referencedEquationIDs: [String]
    let evidenceAnchorIDs: [String]
    let sourceDocumentHashes: [String]
    let epistemicStatus: EpistemicStatus

    var id: String { stepID }
    var structuralStatus: FormulaStructuralStatus {
        FormulaStepTeXStructure.status(before: beforeTeX, after: afterTeX)
    }
    var physicsReview: FormulaPhysicsReviewStatus { .needsManualPhysics }

    enum CodingKeys: String, CodingKey {
        case stepID = "step_id"
        case ordinal
        case textZH = "text_zh"
        case beforeTeX = "before_tex"
        case afterTeX = "after_tex"
        case ruleOrAssumption = "rule_or_assumption"
        case referencedEquationIDs = "referenced_equation_ids"
        case evidenceAnchorIDs = "evidence_anchor_ids"
        case sourceDocumentHashes = "source_document_hashes"
        case epistemicStatus = "epistemic_status"
    }

    init(stepID: String, ordinal: Int, textZH: String, beforeTeX: String? = nil,
         afterTeX: String? = nil, ruleOrAssumption: String,
         referencedEquationIDs: [String] = [], evidenceAnchorIDs: [String] = [],
         sourceDocumentHashes: [String], epistemicStatus: EpistemicStatus) {
        self.stepID = stepID
        self.ordinal = ordinal
        self.textZH = textZH
        self.beforeTeX = beforeTeX
        self.afterTeX = afterTeX
        self.ruleOrAssumption = ruleOrAssumption
        self.referencedEquationIDs = referencedEquationIDs
        self.evidenceAnchorIDs = evidenceAnchorIDs
        self.sourceDocumentHashes = sourceDocumentHashes
        self.epistemicStatus = epistemicStatus
    }
}

struct FormulaDerivationSegmentMetadata: Codable, Hashable, Sendable {
    let index: Int
    let isFinal: Bool
    let continuationSummary: String?

    enum CodingKeys: String, CodingKey {
        case index
        case isFinal = "is_final"
        case continuationSummary = "continuation_summary"
    }
}

private struct LegacyEvidenceClaimIdentity: Encodable {
    let identityVersion: Int
    let codingPath: [String]
    let textZH: String
    let epistemicStatus: EpistemicStatus
    let evidenceIDs: [String]
    let formulaTeX: String?
    let equationID: String?
    let derivationSteps: [String]
    let formulaDerivationSteps: [FormulaDerivationStep]
    let conclusionZH: String?
    let derivationSegment: FormulaDerivationSegmentMetadata?
    let derivationSegmentProvenanceHash: String?

    func stableUUID() throws -> UUID {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = StableHash.sha256(try encoder.encode(self))
        let value = "\(digest.prefix(8))-\(digest.dropFirst(8).prefix(4))-\(digest.dropFirst(12).prefix(4))-\(digest.dropFirst(16).prefix(4))-\(digest.dropFirst(20).prefix(12))"
        guard let uuid = UUID(uuidString: value) else {
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Could not form a stable legacy EvidenceClaim UUID."))
        }
        return uuid
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
    /// The immutable ID of an ar5iv-labelled equation.  It is populated only
    /// by the all-numbered-equations contract; legacy formula artifacts keep
    /// this optional field absent and are visibly marked as non-comprehensive.
    let equationID: String?
    let derivationSteps: [String]
    let formulaDerivationSteps: [FormulaDerivationStep]
    let conclusionZH: String?
    let derivationSegment: FormulaDerivationSegmentMetadata?
    /// Hash of the ordered, validated segment receipts that produced this
    /// complete claim. It binds the final proof to request/response hashes.
    let derivationSegmentProvenanceHash: String?

    enum CodingKeys: String, CodingKey {
        case id
        case textZH = "text_zh"
        case epistemicStatus = "epistemic_status"
        case evidenceIDs = "evidence_ids"
        case formulaTeX = "formula_tex"
        case equationID = "equation_id"
        case derivationSteps = "derivation_steps"
        case formulaDerivationSteps = "derivation_step_contract"
        case conclusionZH = "conclusion_zh"
        case derivationSegment = "derivation_segment"
        case derivationSegmentProvenanceHash = "derivation_segment_provenance_hash"
    }

    init(id: UUID = UUID(), textZH: String, epistemicStatus: EpistemicStatus, evidenceIDs: [String],
         formulaTeX: String? = nil, equationID: String? = nil,
         derivationSteps: [String] = [], formulaDerivationSteps: [FormulaDerivationStep] = [],
         conclusionZH: String? = nil, derivationSegment: FormulaDerivationSegmentMetadata? = nil,
         derivationSegmentProvenanceHash: String? = nil) {
        self.id = id
        self.textZH = textZH
        self.epistemicStatus = epistemicStatus
        self.evidenceIDs = evidenceIDs
        self.formulaTeX = formulaTeX
        self.equationID = equationID
        self.formulaDerivationSteps = formulaDerivationSteps
        self.derivationSteps = derivationSteps.isEmpty ? formulaDerivationSteps.map(\.textZH) : derivationSteps
        self.conclusionZH = conclusionZH
        self.derivationSegment = derivationSegment
        self.derivationSegmentProvenanceHash = derivationSegmentProvenanceHash
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let textZH = try values.decode(String.self, forKey: .textZH)
        let epistemicStatus = try values.decode(EpistemicStatus.self, forKey: .epistemicStatus)
        let evidenceIDs = try values.decode([String].self, forKey: .evidenceIDs)
        let formulaTeX = try values.decodeIfPresent(String.self, forKey: .formulaTeX)
        let equationID = try values.decodeIfPresent(String.self, forKey: .equationID)
        let derivationSteps = try values.decodeIfPresent([String].self, forKey: .derivationSteps) ?? []
        let formulaDerivationSteps = try values.decodeIfPresent([FormulaDerivationStep].self, forKey: .formulaDerivationSteps) ?? []
        let conclusionZH = try values.decodeIfPresent(String.self, forKey: .conclusionZH)
        let derivationSegment = try values.decodeIfPresent(FormulaDerivationSegmentMetadata.self, forKey: .derivationSegment)
        let derivationSegmentProvenanceHash = try values.decodeIfPresent(String.self, forKey: .derivationSegmentProvenanceHash)
        let id: UUID
        if let explicitID = try values.decodeIfPresent(UUID.self, forKey: .id) {
            id = explicitID
        } else {
            let identity = LegacyEvidenceClaimIdentity(
                identityVersion: 1,
                codingPath: decoder.codingPath.map { key in
                    key.intValue.map { "\(key.stringValue)#\($0)" } ?? key.stringValue
                },
                textZH: textZH,
                epistemicStatus: epistemicStatus,
                evidenceIDs: evidenceIDs,
                formulaTeX: formulaTeX,
                equationID: equationID,
                derivationSteps: derivationSteps,
                formulaDerivationSteps: formulaDerivationSteps,
                conclusionZH: conclusionZH,
                derivationSegment: derivationSegment,
                derivationSegmentProvenanceHash: derivationSegmentProvenanceHash
            )
            id = try identity.stableUUID()
        }
        self.init(id: id, textZH: textZH, epistemicStatus: epistemicStatus, evidenceIDs: evidenceIDs,
                  formulaTeX: formulaTeX, equationID: equationID, derivationSteps: derivationSteps,
                  formulaDerivationSteps: formulaDerivationSteps, conclusionZH: conclusionZH,
                  derivationSegment: derivationSegment,
                  derivationSegmentProvenanceHash: derivationSegmentProvenanceHash)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(textZH, forKey: .textZH)
        try values.encode(epistemicStatus, forKey: .epistemicStatus)
        try values.encode(evidenceIDs, forKey: .evidenceIDs)
        try values.encodeIfPresent(formulaTeX, forKey: .formulaTeX)
        try values.encodeIfPresent(equationID, forKey: .equationID)
        try values.encode(derivationSteps, forKey: .derivationSteps)
        if !formulaDerivationSteps.isEmpty {
            try values.encode(formulaDerivationSteps, forKey: .formulaDerivationSteps)
        }
        try values.encodeIfPresent(conclusionZH, forKey: .conclusionZH)
        try values.encodeIfPresent(derivationSegment, forKey: .derivationSegment)
        try values.encodeIfPresent(derivationSegmentProvenanceHash, forKey: .derivationSegmentProvenanceHash)
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
    /// The exact local ar5iv equation inventory bound to this artifact.  Both
    /// fields default on decode so old cached "important formula" artifacts
    /// remain readable but cannot impersonate a verified complete result.
    let numberedEquationIDs: [String]
    let numberedEquationCoverageComplete: Bool
    var isStale: Bool
    var id: String { cacheKey }

    init(cacheKey: String, paperID: Int, documentHash: String, chunkIDs: [String], insight: PaperInsightV2,
         createdAt: Date, retrievalQuery: String = "paper title terms", rankerVersion: String = "local-title-token-v1",
         selectedChunkIDs: [String]? = nil, promptVersion: String = EvidenceInsightPrompt.version,
         schemaVersion: String = PaperInsightV2Validator.schemaVersion, payloadHash: String = "",
         payloadByteCount: Int = 0, payloadScalarCount: Int = 0,
         numberedEquationIDs: [String] = [], numberedEquationCoverageComplete: Bool = false,
         isStale: Bool = false) {
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
        self.numberedEquationIDs = numberedEquationIDs
        self.numberedEquationCoverageComplete = numberedEquationCoverageComplete
        self.isStale = isStale
    }

    private enum CodingKeys: String, CodingKey {
        case cacheKey, paperID, documentHash, chunkIDs, insight, createdAt, retrievalQuery, rankerVersion
        case selectedChunkIDs, promptVersion, schemaVersion, payloadHash, payloadByteCount, payloadScalarCount
        case numberedEquationIDs, numberedEquationCoverageComplete, isStale
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
                  numberedEquationIDs: try values.decodeIfPresent([String].self, forKey: .numberedEquationIDs) ?? [],
                  numberedEquationCoverageComplete: try values.decodeIfPresent(Bool.self, forKey: .numberedEquationCoverageComplete) ?? false,
                  isStale: try values.decodeIfPresent(Bool.self, forKey: .isStale) ?? false)
    }
}

/// Non-secret identity captured with a completed evidence artifact before its
/// final library write. Provider credentials and raw endpoint URLs are never
/// persisted here; the profile and settings are represented by a stable hash.
struct EvidenceInsightPublicationContext: Codable, Hashable, Sendable {
    let cacheKey: String
    let paperID: Int
    let documentHash: String
    let inventoryHash: String
    let sourcePayloadHash: String
    let provider: String
    let providerProfileFingerprint: String
    let modelID: String
    let promptVersion: String
    let schemaVersion: String
    let sourceScope: String

    var analysisRunID: String { Self.analysisRunID(cacheKey: cacheKey) }
    static func analysisRunID(cacheKey: String) -> String {
        "evidence-insight-publication:\(StableHash.sha256(cacheKey))"
    }
}

/// A fully validated artifact that is durable but not yet visible in the
/// library's normal evidence-artifact collection.
struct ReadyEvidenceInsightPublication: Codable, Hashable, Sendable {
    let context: EvidenceInsightPublicationContext
    let artifact: EvidenceInsightArtifact

    var hasConsistentIdentity: Bool {
        let equationIDs = artifact.insight.physics.importantFormulaDerivations.compactMap(\.equationID)
        return !context.cacheKey.isEmpty && context.paperID == artifact.paperID &&
            context.cacheKey == artifact.cacheKey && context.documentHash == artifact.documentHash &&
            context.sourcePayloadHash == artifact.payloadHash &&
            context.promptVersion == artifact.promptVersion && context.schemaVersion == artifact.schemaVersion &&
            context.sourceScope == artifact.insight.sourceScope && artifact.insight.schemaVersion == context.schemaVersion &&
            artifact.numberedEquationCoverageComplete && !artifact.isStale &&
            artifact.chunkIDs == artifact.selectedChunkIDs &&
            Set(artifact.numberedEquationIDs).count == artifact.numberedEquationIDs.count &&
            equationIDs == artifact.numberedEquationIDs
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
