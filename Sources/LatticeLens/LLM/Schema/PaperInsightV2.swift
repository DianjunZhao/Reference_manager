import Foundation

/// A structurally labelled display equation extracted from the current local
/// ar5iv HTML file.  It is intentionally separate from a prose retrieval
/// chunk: title relevance must never decide whether a numbered equation is
/// sent to the all-coverage formula contract.
struct NumberedEquationInput: Codable, Hashable, Sendable {
    let equationID: String
    let label: String
    let tex: String
    let evidenceID: String
    let section: String?

    enum CodingKeys: String, CodingKey {
        case equationID = "equation_id"
        case label
        case tex
        case evidenceID = "evidence_id"
        case section
    }
}

struct EvidenceInputPayload: Codable, Sendable {
    /// Ordinary prose context remains bounded. Numbered equations use their
    /// own inventory below and are never selected by this relevance limit.
    static let maximumChunks = 12
    static let maximumMetadataAnchors = 12
    static let maximumNumberedEquations = 256
    static let maximumPayloadBytes = 1_000_000
    static let maximumPayloadScalars = 480_000
    let paperID: Int
    let documentHash: String
    /// Coordinates carried by a full-text anchor depend on the document
    /// representation. PDF anchors are page-addressable, whereas ar5iv HTML
    /// anchors are bounded source excerpts without an invented PDF page.
    /// Keep the representation in the request so the validator can check the
    /// appropriate coordinate contract without weakening identity/hash checks.
    let documentSourceKind: FullTextSourceKind
    let title: String
    let abstract: String?
    let chunks: [EvidenceChunk]
    let anchors: [EvidenceAnchor]
    let numberedEquations: [NumberedEquationInput]
    /// `false` is fail-closed. It covers old HTML extractions, PDF fallback,
    /// malformed indexes and explicit local payload limits; no provider call
    /// is permitted in those cases.
    var numberedEquationCoverageComplete: Bool
    var numberedEquationCoverageFailure: String?
    let figureKeys: [String]
    let retrievalQuery: String
    let rankerVersion: String
    let payloadByteCount: Int
    let payloadScalarCount: Int
    let payloadTokenEstimate: Int
    /// Hash of the complete local numbered-equation inventory.  Older
    /// payloads may omit it; a new formula job will then derive a bounded
    /// payload identity from the validated equation projection.
    let inventoryHash: String?
    /// Present for a formula batch request.  A batch is validated against its
    /// own equation subset; the merged artifact is validated against the full
    /// inventory before persistence.
    let batchIndex: Int?
    let batchTotal: Int?

    enum CodingKeys: String, CodingKey {
        case paperID, documentHash, documentSourceKind, title, abstract, chunks, anchors
        case numberedEquations = "numbered_equations"
        case numberedEquationCoverageComplete = "numbered_equation_coverage_complete"
        case numberedEquationCoverageFailure = "numbered_equation_coverage_failure"
        case figureKeys, retrievalQuery, rankerVersion, payloadByteCount, payloadScalarCount, payloadTokenEstimate, inventoryHash, batchIndex, batchTotal
    }

    init(paper: Paper, document: FullTextDocument, chunks: [EvidenceChunk], anchors: [EvidenceAnchor]) {
        paperID = paper.literatureID
        documentHash = document.sha256
        documentSourceKind = document.sourceKind
        title = paper.displayTitle
        abstract = paper.preferredAbstract
        let eligibleChunks = chunks.filter { $0.paperID == paper.literatureID && $0.documentHash == document.sha256 }
        let formulaChunks = eligibleChunks.filter { $0.equationID != nil || $0.equationLabel != nil || $0.equationTeX != nil || $0.equationOrdinal != nil }
            .sorted { lhs, rhs in
                let left = lhs.equationOrdinal ?? .max
                let right = rhs.equationOrdinal ?? .max
                return left == right ? lhs.id < rhs.id : left < right
            }
        let ordinaryChunks = eligibleChunks.filter { $0.equationID == nil && $0.equationLabel == nil && $0.equationTeX == nil && $0.equationOrdinal == nil }
        let selectedOrdinaryChunks = Array(ordinaryChunks.prefix(Self.maximumChunks))
        let selectedChunks = selectedOrdinaryChunks + formulaChunks
        let selectedIDs = Set(selectedChunks.map(\.id))
        self.chunks = selectedChunks
        // Every selected formula chunk retains its own same-document anchor.
        // Metadata stays separately bounded; formula anchors never consume the
        // metadata allowance or get silently removed by a generic prefix.
        let fullTextAnchors = anchors.filter { selectedIDs.contains($0.id) }.sorted { $0.id < $1.id }
        let metadataAnchors = Array(anchors.filter { $0.sourceKind != .pdf }.sorted { $0.id < $1.id }.prefix(Self.maximumMetadataAnchors))
        self.anchors = fullTextAnchors + metadataAnchors

        let anchorsByID = Dictionary(uniqueKeysWithValues: fullTextAnchors.map { ($0.id, $0) })
        var coverageFailure: String?
        if document.sourceKind != .arxivHTML {
            coverageFailure = "PDF 文本回退不具备结构化编号公式全覆盖保证；请读取 ar5iv HTML 后再生成。"
        } else if document.numberedEquationIndexVersion != FullTextService.numberedEquationIndexVersion {
            coverageFailure = "本地 ar5iv HTML 尚未建立当前编号公式索引；请先在本机重建索引。"
        } else if document.numberedEquationIndexComplete != true {
            coverageFailure = document.numberedEquationIndexFailure ?? "本地 ar5iv HTML 的编号公式索引不完整；不会生成部分覆盖结果。"
        } else if formulaChunks.count > Self.maximumNumberedEquations {
            coverageFailure = "编号公式索引超过本地全覆盖上限（\(formulaChunks.count)/\(Self.maximumNumberedEquations)）；不会生成部分覆盖结果。"
        }

        var equations = [NumberedEquationInput]()
        var seenEquationIDs = Set<String>()
        for chunk in formulaChunks {
            guard let equationID = chunk.equationID,
                  let label = chunk.equationLabel,
                  let tex = chunk.equationTeX,
                  !equationID.isEmpty, !label.isEmpty, !tex.isEmpty,
                  seenEquationIDs.insert(equationID).inserted,
                  let anchor = anchorsByID[chunk.id], anchor.quoteHash == chunk.textHash,
                  anchor.quote == chunk.text else {
                coverageFailure = "本地 ar5iv 编号公式索引损坏或缺少同一 document 的 evidence anchor；不会生成部分覆盖结果。"
                break
            }
            equations.append(NumberedEquationInput(equationID: equationID, label: label, tex: tex,
                                                   evidenceID: anchor.id, section: chunk.section))
        }
        self.numberedEquations = equations
        self.numberedEquationCoverageComplete = coverageFailure == nil
        self.numberedEquationCoverageFailure = coverageFailure
        figureKeys = Array(paper.figures.prefix(12).map(\.key))
        retrievalQuery = SearchNormalizer.normalize(paper.displayTitle)
        rankerVersion = "local-title-token-v2-plus-numbered-equations"
        let numberedBytes = equations.reduce(0) { $0 + $1.equationID.utf8.count + $1.label.utf8.count + $1.tex.utf8.count + $1.evidenceID.utf8.count + ($1.section?.utf8.count ?? 0) }
        let numberedScalars = equations.reduce(0) { $0 + $1.equationID.unicodeScalars.count + $1.label.unicodeScalars.count + $1.tex.unicodeScalars.count + $1.evidenceID.unicodeScalars.count + ($1.section?.unicodeScalars.count ?? 0) }
        payloadByteCount = self.chunks.reduce(0) { $0 + $1.byteCount } + self.anchors.reduce(0) { $0 + $1.quote.utf8.count } + numberedBytes
        payloadScalarCount = self.chunks.reduce(0) { $0 + $1.scalarCount } + self.anchors.reduce(0) { $0 + $1.quote.unicodeScalars.count } + numberedScalars
        payloadTokenEstimate = self.chunks.reduce(0) { $0 + $1.tokenEstimate } + self.anchors.reduce(0) { $0 + max(1, $1.quote.split { $0.isWhitespace || $0.isPunctuation }.count) } + equations.reduce(0) { $0 + max(1, $1.tex.split { $0.isWhitespace || $0.isPunctuation }.count) }
        if self.numberedEquationCoverageComplete,
           (payloadByteCount > Self.maximumPayloadBytes || payloadScalarCount > Self.maximumPayloadScalars) {
            self.numberedEquationCoverageComplete = false
            self.numberedEquationCoverageFailure = "编号公式与受限 evidence payload 超过本地全覆盖上限（\(payloadByteCount) bytes，\(payloadScalarCount) scalars）；不会生成部分覆盖结果。"
        }
        inventoryHash = document.numberedEquationInventoryHash
            ?? FormulaInventory.payloadHash(documentHash: document.sha256, equations: equations)
        self.batchIndex = nil
        self.batchTotal = nil
    }

    /// Builds a bounded payload carrying only the requested numbered equation
    /// IDs.  Ordinary prose is sent in the first batch; later batches contain
    /// only their formula chunks plus bounded metadata anchors.  The source
    /// inventory remains represented by `numberedEquations`, while the final
    /// workflow performs a second full-source bijection check.
    func batch(for equationIDs: [String], index: Int, total: Int) throws -> EvidenceInputPayload {
        guard total > 0, index >= 0, index < total else { throw LatticeLensError.schemaViolation("formula batch index 无效") }
        let requested = equationIDs
        guard !requested.isEmpty || numberedEquations.isEmpty,
              Set(requested).count == requested.count,
              Set(requested).isSubset(of: Set(numberedEquations.map(\.equationID)) ) else {
            throw LatticeLensError.schemaViolation("formula batch equation_id 不属于本次 inventory")
        }
        let selectedEquations = requested.compactMap { id in numberedEquations.first { $0.equationID == id } }
        guard selectedEquations.count == requested.count else { throw LatticeLensError.schemaViolation("formula batch 缺少 inventory equation") }
        let selectedChunks = chunks.filter { chunk in
            guard let id = chunk.equationID else { return index == 0 }
            return requested.contains(id)
        }
        let selectedIDs = Set(selectedChunks.map(\.id))
        let selectedAnchors = anchors.filter { anchor in
            selectedIDs.contains(anchor.id) || (anchor.sourceKind != .pdf && index == 0)
        }
        var copy = EvidenceInputPayload(
            paperID: paperID, documentHash: documentHash, documentSourceKind: documentSourceKind,
            title: title, abstract: abstract, chunks: selectedChunks, anchors: selectedAnchors,
            numberedEquations: selectedEquations, numberedEquationCoverageComplete: numberedEquationCoverageComplete,
            numberedEquationCoverageFailure: numberedEquationCoverageFailure, figureKeys: figureKeys,
            retrievalQuery: retrievalQuery, rankerVersion: rankerVersion,
            payloadByteCount: selectedChunks.reduce(0) { $0 + $1.byteCount }
                + selectedAnchors.reduce(0) { $0 + $1.quote.utf8.count }
                + selectedEquations.reduce(0) { $0 + $1.equationID.utf8.count + $1.label.utf8.count + $1.tex.utf8.count + $1.evidenceID.utf8.count + ($1.section?.utf8.count ?? 0) },
            payloadScalarCount: selectedChunks.reduce(0) { $0 + $1.scalarCount }
                + selectedAnchors.reduce(0) { $0 + $1.quote.unicodeScalars.count }
                + selectedEquations.reduce(0) { $0 + $1.equationID.unicodeScalars.count + $1.label.unicodeScalars.count + $1.tex.unicodeScalars.count + $1.evidenceID.unicodeScalars.count + ($1.section?.unicodeScalars.count ?? 0) },
            payloadTokenEstimate: selectedChunks.reduce(0) { $0 + $1.tokenEstimate }
                + selectedEquations.reduce(0) { $0 + max(1, $1.tex.split { $0.isWhitespace || $0.isPunctuation }.count) },
            inventoryHash: inventoryHash,
            batchIndex: index, batchTotal: total
        )
        // A caller can still inspect this subset as a bounded source.  It is
        // the merged full-source validation, not this flag, that authorizes a
        // complete artifact.
        copy.numberedEquationCoverageComplete = numberedEquationCoverageComplete
        return copy
    }

    /// The prose insight pass must not ask a provider to derive the complete
    /// equation set in one request. Formula claims are filled only by the
    /// separately checkpointed batch workflow.
    func proseOnly() -> EvidenceInputPayload {
        let proseChunks = chunks.filter { $0.equationID == nil && $0.equationLabel == nil && $0.equationTeX == nil && $0.equationOrdinal == nil }
        let proseIDs = Set(proseChunks.map(\.id))
        let proseAnchors = anchors.filter { $0.sourceKind != .pdf || proseIDs.contains($0.id) }
        return EvidenceInputPayload(
            paperID: paperID, documentHash: documentHash, documentSourceKind: documentSourceKind,
            title: title, abstract: abstract, chunks: proseChunks, anchors: proseAnchors,
            numberedEquations: [], numberedEquationCoverageComplete: numberedEquationCoverageComplete,
            numberedEquationCoverageFailure: numberedEquationCoverageFailure, figureKeys: figureKeys,
            retrievalQuery: retrievalQuery, rankerVersion: rankerVersion,
            payloadByteCount: proseChunks.reduce(0) { $0 + $1.byteCount } + proseAnchors.reduce(0) { $0 + $1.quote.utf8.count },
            payloadScalarCount: proseChunks.reduce(0) { $0 + $1.scalarCount } + proseAnchors.reduce(0) { $0 + $1.quote.unicodeScalars.count },
            payloadTokenEstimate: proseChunks.reduce(0) { $0 + $1.tokenEstimate },
            inventoryHash: inventoryHash, batchIndex: nil, batchTotal: nil
        )
    }

    private init(paperID: Int, documentHash: String, documentSourceKind: FullTextSourceKind,
                 title: String, abstract: String?, chunks: [EvidenceChunk], anchors: [EvidenceAnchor],
                 numberedEquations: [NumberedEquationInput], numberedEquationCoverageComplete: Bool,
                 numberedEquationCoverageFailure: String?, figureKeys: [String], retrievalQuery: String,
                 rankerVersion: String, payloadByteCount: Int, payloadScalarCount: Int,
                 payloadTokenEstimate: Int, inventoryHash: String?, batchIndex: Int?, batchTotal: Int?) {
        self.paperID = paperID; self.documentHash = documentHash; self.documentSourceKind = documentSourceKind
        self.title = title; self.abstract = abstract; self.chunks = chunks; self.anchors = anchors
        self.numberedEquations = numberedEquations; self.numberedEquationCoverageComplete = numberedEquationCoverageComplete
        self.numberedEquationCoverageFailure = numberedEquationCoverageFailure; self.figureKeys = figureKeys
        self.retrievalQuery = retrievalQuery; self.rankerVersion = rankerVersion
        self.payloadByteCount = payloadByteCount; self.payloadScalarCount = payloadScalarCount
        self.payloadTokenEstimate = payloadTokenEstimate; self.inventoryHash = inventoryHash
        self.batchIndex = batchIndex; self.batchTotal = batchTotal
    }

    var anchorAllowlist: Set<String> { Set(anchors.map(\.id)) }
    var sourceByAnchor: [String: String] { Dictionary(uniqueKeysWithValues: anchors.map { ($0.id, $0.quote) }) }
}

struct LocalEvidenceRetriever: Sendable {
    let maximumChunks: Int

    init(maximumChunks: Int = 12) { self.maximumChunks = max(1, maximumChunks) }

    func retrieve(paper: Paper, snapshot: LibrarySnapshot) -> (document: FullTextDocument, chunks: [EvidenceChunk], anchors: [EvidenceAnchor])? {
        return retrieve(
            paper: paper,
            documents: Array(snapshot.fullTextDocuments.values),
            chunks: Array(snapshot.evidenceChunks.values),
            anchors: Array(snapshot.evidenceAnchors.values)
        )
    }

    /// Bounded single-paper path used by the interactive Evidence tab.  The
    /// older snapshot overload remains for compatibility tests and exports,
    /// but production generation must not decode unrelated authors, papers,
    /// or V9 search postings merely to find twelve local chunks.
    func retrieve(paper: Paper, context: LibraryPaperContextProjection) -> (document: FullTextDocument, chunks: [EvidenceChunk], anchors: [EvidenceAnchor])? {
        retrieve(paper: paper, documents: context.fullTextDocuments,
                 chunks: context.evidenceChunks, anchors: context.evidenceAnchors)
    }

    private func retrieve(paper: Paper, documents: [FullTextDocument], chunks allChunks: [EvidenceChunk], anchors allAnchors: [EvidenceAnchor]) -> (document: FullTextDocument, chunks: [EvidenceChunk], anchors: [EvidenceAnchor])? {
        guard let document = documents
            .filter({ $0.paperID == paper.literatureID && $0.extractionState == .extracted })
            .sorted(by: { ($0.downloadedAt ?? .distantPast) > ($1.downloadedAt ?? .distantPast) }).first else { return nil }
        let allChunks = allChunks.filter { $0.paperID == paper.literatureID && $0.documentHash == document.sha256 }
        let terms = Set(SearchNormalizer.normalize(paper.displayTitle).split(whereSeparator: { $0 == " " }).map(String.init).filter { $0.count >= 3 })
        let ranked = allChunks.filter { $0.equationID == nil && $0.equationLabel == nil && $0.equationTeX == nil && $0.equationOrdinal == nil }.sorted { lhs, rhs in
            let lhsScore = terms.reduce(0) { $0 + (SearchNormalizer.normalize(lhs.text).contains($1) ? 1 : 0) }
            let rhsScore = terms.reduce(0) { $0 + (SearchNormalizer.normalize(rhs.text).contains($1) ? 1 : 0) }
            return lhsScore == rhsScore ? lhs.id < rhs.id : lhsScore > rhsScore
        }
        let formulaChunks = allChunks.filter { $0.equationID != nil || $0.equationLabel != nil || $0.equationTeX != nil || $0.equationOrdinal != nil }
            .sorted { lhs, rhs in
                let left = lhs.equationOrdinal ?? .max
                let right = rhs.equationOrdinal ?? .max
                return left == right ? lhs.id < rhs.id : left < right
            }
        let chunks = Array(ranked.prefix(maximumChunks)) + formulaChunks
        let ids = Set(chunks.map(\.id))
        let fullTextAnchors = allAnchors.filter { ids.contains($0.id) }
        // Abstract/caption anchors are persisted independently of a full text and
        // are intentionally retained when a full-text document is deleted.
        let metadataAnchors = allAnchors.filter {
            $0.paperID == paper.literatureID && $0.sourceKind != .pdf
        }
        let anchors = (fullTextAnchors + metadataAnchors).sorted { $0.id < $1.id }
        guard !chunks.isEmpty, !fullTextAnchors.isEmpty else { return nil }
        return (document, chunks, anchors)
    }
}

enum PaperInsightV2Validator {
    static let schemaVersion = "paper-insight-v2"
    static let sourceScope = "fulltext_with_anchors"

    static func decode(_ data: Data, source: EvidenceInputPayload, maximumFigures: Int,
                       expectedFormulaSegments: [String: FormulaDerivationSegmentExpectation] = [:]) throws -> PaperInsightV2 {
        guard !data.isEmpty, data.count <= PaperInsightValidator.maximumResponseBytes else { throw LatticeLensError.schemaViolation("v2 insight 响应超限") }
        // LLMs sometimes put a TeX command such as `\\alpha` directly inside a
        // JSON string, rather than serialising the command marker as a JSON
        // backslash escape.  Repair only that wire-format defect before the
        // duplicate-key grammar walk; the repair never changes a valid JSON
        // escape, never repairs malformed `\\u` escapes, and all semantic,
        // provenance, anchor, numeric and size checks still follow below.
        let normalizedData = BareTeXJSONEscapeNormalizer.normalize(data)
        // A second, deliberately narrower syntax repair handles the common
        // model omission `[{...}{...}]` or `["step one" "step two"]`.
        // It inserts a comma only between two fully parsed, unambiguous JSON
        // array elements. Object punctuation, numbers, escapes, incomplete
        // strings and every schema/provenance field remain untouched. If the
        // whole response is not otherwise strict JSON, this returns the bytes
        // unchanged and the fail-closed grammar walk below reports the error.
        let commaNormalizedData = MissingArrayCommaJSONNormalizer.normalize(normalizedData)
        guard commaNormalizedData.count <= PaperInsightValidator.maximumResponseBytes else {
            throw LatticeLensError.schemaViolation("v2 insight 响应超限")
        }
        try JSONDuplicateKeyDetector.validate(commaNormalizedData)
        guard let raw = try? JSONDecoder().decode(JSONValue.self, from: commaNormalizedData) else { throw LatticeLensError.schemaViolation("v2 insight JSON 无法解码") }
        // A number of OpenAI-compatible gateways add harmless transport
        // metadata, or place the model's JSON object under `data`/`result`.
        // That metadata is not evidence and must never be saved.  Recover one
        // unambiguous contract object, then validate only the fields the app
        // actually persists. Missing required fields, duplicate keys, bad
        // types, malformed evidence IDs, and unanchored numeric claims remain
        // hard failures below; only a structurally valid but unprovable
        // direct/inference item is discarded before persistence.
        let contractRoot = try extractContractRoot(from: raw)
        try validateEvidenceInput(source)
        // A model sometimes returns an otherwise well-formed direct or
        // inference item with no current anchor (or with an ID outside this
        // one bounded payload).  Never attach an arbitrary quote to rescue
        // it: the normalizer discards only that unprovable item and records a
        // generic missing-data sentinel.  Every claim that survives still
        // goes through the strict shape, anchor, and numeric-provenance checks
        // below. Malformed item shapes are deliberately not repaired.
        let normalizedContractRoot = UnanchoredEvidenceClaimNormalizer.normalize(
            contractRoot,
            anchorAllowlist: source.anchorAllowlist
        )
        try validateShape(normalizedContractRoot, source: source)
        guard let canonicalData = try? JSONEncoder.latticeLens.encode(normalizedContractRoot),
              let insight = try? JSONDecoder.latticeLens.decode(PaperInsightV2.self, from: canonicalData),
              insight.schemaVersion == schemaVersion, insight.sourceScope == sourceScope else {
            throw LatticeLensError.schemaViolation("v2 schema 或 source scope 不匹配")
        }
        guard insight.importantFigures.count <= maximumFigures,
              (maximumFigures > 0 || insight.importantFigures.isEmpty),
              insight.importantFigures.allSatisfy({ source.figureKeys.contains($0.figureKey) && $0.evidenceMode == .captionOnly }) else {
            throw LatticeLensError.schemaViolation("v2 图像选择越出本地 allowlist")
        }
        let claims = [insight.physics.researchQuestion] + insight.physics.methodAndDataFlow + insight.physics.mainResults +
            insight.physics.reasonableInferences + insight.physics.missingInformation + insight.physics.caveats +
            insight.physics.importantFormulaDerivations
        for claim in claims {
            switch claim.epistemicStatus {
            case .direct, .inference:
                guard !claim.evidenceIDs.isEmpty, Set(claim.evidenceIDs).isSubset(of: source.anchorAllowlist) else {
                    throw LatticeLensError.schemaViolation("direct/inference claim 缺少本次有效 evidence anchor")
                }
                // A value and its unit must be recoverable from one original
                // anchor, never by concatenating two unrelated snippets.
                let quotes = claim.evidenceIDs.compactMap { source.sourceByAnchor[$0] }
                guard NumericClaimEvidence.isAnchored(claim.textZH, quotes: quotes) else {
                    throw LatticeLensError.schemaViolation("v2 精确数值或单位无法回查 evidence")
                }
            case .missing:
                guard claim.evidenceIDs.isEmpty else { throw LatticeLensError.schemaViolation("missing claim 不得伪造 anchor") }
            }
        }
        try validateNumberedEquationCoverage(insight, source: source,
                                             expectedFormulaSegments: expectedFormulaSegments)
        return canonicalFormulaOrder(insight, source: source)
    }

    private static func validateShape(_ raw: JSONValue, source: EvidenceInputPayload) throws {
        let root = try object(raw, keys: ["schema_version", "source_scope", "title_zh", "abstract_zh", "physics", "important_figures", "terminology"], path: "root")
        for key in ["schema_version", "source_scope", "title_zh"] {
            try nonempty(try value(root, key, "root"), path: key)
        }
        // The original INSPIRE/arXiv metadata occasionally has no abstract.
        // Keep the key and its String type mandatory, but reserve exactly
        // `""` as the explicit, non-invented "source abstract unavailable"
        // sentinel.  Whitespace is still not a valid abstract and every
        // provenance-bearing field below remains fail-closed.
        try abstractText(try value(root, "abstract_zh", "root"), path: "abstract_zh")
        let physics = try objectAllowingOptional(
            try value(root, "physics", "root"),
            requiredKeys: ["research_question", "method_and_data_flow", "main_results", "reasonable_inferences", "missing_information", "caveats"],
            optionalKeys: ["important_formula_derivations"],
            path: "physics")
        try researchQuestionClaim(try value(physics, "research_question", "physics"))
        for key in ["method_and_data_flow", "main_results", "reasonable_inferences", "missing_information", "caveats"] {
            let items = try array(try value(physics, key, "physics"), maximum: 32, path: "physics.\(key)")
            let required: EpistemicStatus? = switch key {
            case "method_and_data_flow", "main_results": .direct
            case "reasonable_inferences": .inference
            case "missing_information": .missing
            default: nil // caveats may be direct, inference, or missing
            }
            for (index, item) in items.enumerated() { try claim(item, path: "physics.\(key)[\(index)]", requiredStatus: required) }
        }
        if let formulas = physics["important_formula_derivations"] {
            let items = try array(formulas, maximum: EvidenceInputPayload.maximumNumberedEquations, path: "physics.important_formula_derivations")
            for (index, item) in items.enumerated() {
                try claim(item, path: "physics.important_formula_derivations[\(index)]", requiredStatus: .direct,
                          requireFormulaStructure: true,
                          requireEquationID: source.documentSourceKind == .arxivHTML && !source.numberedEquations.isEmpty,
                          requireTypedStepContract: source.documentSourceKind == .arxivHTML && !source.numberedEquations.isEmpty)
            }
        }
        let figures = try array(try value(root, "important_figures", "root"), maximum: 5, path: "important_figures")
        for (index, figure) in figures.enumerated() {
            let object = try object(figure, keys: ["figure_key", "caption_zh", "why_important", "evidence_mode"], path: "important_figures[\(index)]")
            for key in object.keys { try nonempty(try value(object, key, "important_figures"), path: "important_figures.\(key)") }
        }
        let terms = try array(try value(root, "terminology", "root"), maximum: TerminologyEntry.maximumItems, path: "terminology")
        for (index, term) in terms.enumerated() {
            let object = try object(term, keys: ["source", "zh", "note"], path: "terminology[\(index)]")
            try nonempty(try value(object, "source", "terminology"), path: "terminology.source")
            try nonempty(try value(object, "zh", "terminology"), path: "terminology.zh")
            guard let note = object["note"]?.stringValue, note.unicodeScalars.count <= 16_000 else { throw LatticeLensError.schemaViolation("terminology note 超限") }
        }
    }

    /// Returns exactly the paper-insight object that is allowed to cross the
    /// model boundary.  Root-level diagnostic fields are deliberately dropped
    /// rather than made part of a durable research claim.  A gateway wrapper
    /// is accepted only when it contains one, and only one, complete schema
    /// candidate; this avoids guessing which of several model outputs to use.
    private static func extractContractRoot(from raw: JSONValue) throws -> JSONValue {
        let requiredKeys: Set<String> = [
            "schema_version", "source_scope", "title_zh", "abstract_zh",
            "physics", "important_figures", "terminology"
        ]
        guard let outer = raw.objectValue else {
            throw LatticeLensError.schemaViolation("root 不是 JSON 对象")
        }

        func projectedContract(_ object: [String: JSONValue]) -> JSONValue? {
            guard requiredKeys.isSubset(of: Set(object.keys)) else { return nil }
            return .object(Dictionary(uniqueKeysWithValues: requiredKeys.compactMap { key in
                object[key].map { (key, $0) }
            }))
        }

        if let direct = projectedContract(outer) {
            return direct
        }

        // These are conventional OpenAI-compatible envelope names, not a
        // general recursive JSON search.  The latter could accidentally turn
        // an unrelated quoted object into a successful research artifact.
        let envelopeKeys = ["data", "result", "output", "paper_insight", "paper_insight_v2"]
        let candidates = envelopeKeys.compactMap { key -> JSONValue? in
            guard let nested = outer[key]?.objectValue else { return nil }
            return projectedContract(nested)
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            let missing = requiredKeys.subtracting(Set(outer.keys)).sorted().joined(separator: ", ")
            throw LatticeLensError.schemaViolation(
                "root 缺少必需 key（\(missing)）；也未找到唯一的 data/result/output schema 对象"
            )
        }
        return candidate
    }

    private static func validateEvidenceInput(_ source: EvidenceInputPayload) throws {
        let anchors = source.anchors
        guard Set(anchors.map(\.id)).count == anchors.count else {
            throw LatticeLensError.schemaViolation("v2 evidence input 包含重复 anchor ID")
        }
        guard source.chunks.allSatisfy({ $0.paperID == source.paperID && $0.documentHash == source.documentHash &&
            $0.textHash == StableHash.sha256($0.text) }) else {
            throw LatticeLensError.schemaViolation("v2 evidence chunk 不属于当前 paper/document，或 text hash 不匹配")
        }
        let chunksByID = Dictionary(uniqueKeysWithValues: source.chunks.map { ($0.id, $0) })
        for anchor in anchors {
            guard anchor.paperID == source.paperID, StableHash.sha256(anchor.quote) == anchor.quoteHash else {
                throw LatticeLensError.schemaViolation("v2 evidence anchor 不属于当前 paper，或 quote hash 不匹配")
            }
            if anchor.sourceKind == .pdf {
                guard let chunk = chunksByID[anchor.id],
                      chunk.textHash == anchor.quoteHash, chunk.text == anchor.quote else {
                    throw LatticeLensError.schemaViolation("v2 全文 anchor 不属于本次受限 document payload")
                }
                switch source.documentSourceKind {
                case .arxivHTML:
                    // ar5iv is HTML, not a PDF. Its extractor deliberately
                    // records no fabricated page number; section/chunk/hash
                    // identity remains fully bound to this exact payload.
                    guard anchor.page == nil, anchor.section == chunk.section else {
                        throw LatticeLensError.schemaViolation("v2 ar5iv HTML anchor 坐标不属于本次受限 document payload")
                    }
                case .inspireDocument, .arxivPDF:
                    guard chunk.page == anchor.page else {
                        throw LatticeLensError.schemaViolation("v2 全文 anchor 不属于本次受限 document payload")
                    }
                }
            }
        }
        let equationsAreStructurallyBound = source.numberedEquations.allSatisfy { equation in
            guard let chunk = chunksByID[equation.evidenceID],
                  chunk.equationID == equation.equationID,
                  chunk.equationLabel == equation.label,
                  chunk.equationTeX == equation.tex,
                  let anchor = anchors.first(where: { $0.id == equation.evidenceID }) else { return false }
            return anchor.quote == chunk.text && anchor.quoteHash == chunk.textHash
        }
        guard equationsAreStructurallyBound,
              Set(source.numberedEquations.map(\.equationID)).count == source.numberedEquations.count else {
            throw LatticeLensError.schemaViolation("v2 编号公式索引不属于本次受限 document payload")
        }
    }

    private static func claim(_ raw: JSONValue, path: String, requiredStatus: EpistemicStatus? = nil,
                              requireFormulaStructure: Bool = false,
                              requireEquationID: Bool = false,
                              requireTypedStepContract: Bool = false) throws {
        let object = try objectAllowingOptional(raw,
                                                requiredKeys: ["text_zh", "epistemic_status", "evidence_ids"],
                                                optionalKeys: ["formula_tex", "equation_id", "derivation_steps", "derivation_step_contract", "conclusion_zh", "derivation_segment"],
                                                path: path)
        try nonempty(try value(object, "text_zh", path), path: "\(path).text_zh")
        guard let status = object["epistemic_status"]?.stringValue, EpistemicStatus(rawValue: status) != nil else {
            throw LatticeLensError.schemaViolation("\(path).epistemic_status 无效")
        }
        if let requiredStatus, status != requiredStatus.rawValue {
            throw LatticeLensError.schemaViolation("\(path).epistemic_status 与 section 语义不匹配")
        }
        let evidenceValues = try array(try value(object, "evidence_ids", path), maximum: 16, path: "\(path).evidence_ids")
        let evidenceStrings = evidenceValues.compactMap { $0.stringValue }
        guard evidenceStrings.count == evidenceValues.count, Set(evidenceStrings).count == evidenceStrings.count else {
            throw LatticeLensError.schemaViolation("\(path).evidence_ids 不得重复或包含非字符串")
        }
        for (index, anchor) in evidenceValues.enumerated() {
            try nonempty(anchor, path: "\(path).evidence_ids[\(index)]")
        }
        if let formula = object["formula_tex"] {
            try nonempty(formula, path: "\(path).formula_tex")
        }
        if let steps = object["derivation_steps"] {
            let values = try array(steps, maximum: FormulaDerivationStep.maximumStepsPerSegment, path: "\(path).derivation_steps")
            for (index, step) in values.enumerated() {
                try nonempty(step, path: "\(path).derivation_steps[\(index)]")
            }
            if requireFormulaStructure {
                guard !values.isEmpty else { throw LatticeLensError.schemaViolation("\(path).derivation_steps 不能为空") }
            }
        } else if requireFormulaStructure {
            throw LatticeLensError.schemaViolation("\(path) 缺少 derivation_steps")
        }
        if let rawContract = object["derivation_step_contract"] {
            let steps = try array(rawContract, maximum: FormulaDerivationStep.maximumStepsPerSegment,
                                  path: "\(path).derivation_step_contract")
            for (index, step) in steps.enumerated() {
                try formulaStep(step, path: "\(path).derivation_step_contract[\(index)]")
            }
            if requireTypedStepContract, steps.isEmpty {
                throw LatticeLensError.schemaViolation("\(path).derivation_step_contract 不能为空")
            }
        } else if requireTypedStepContract {
            throw LatticeLensError.schemaViolation("\(path) 缺少 derivation_step_contract")
        }
        if let conclusion = object["conclusion_zh"] {
            try nonempty(conclusion, path: "\(path).conclusion_zh")
        }
        if let rawSegment = object["derivation_segment"] {
            let segment = try objectAllowingOptional(rawSegment,
                requiredKeys: ["index", "is_final"], optionalKeys: ["continuation_summary"],
                path: "\(path).derivation_segment")
            guard let index = segment["index"]?.integerValue,
                  (0..<FormulaDerivationSegmentCheckpoint.maximumSegmentsPerEquation).contains(index),
                  case .bool? = segment["is_final"] else {
                throw LatticeLensError.schemaViolation("\(path).derivation_segment index/is_final 无效")
            }
            if let summary = segment["continuation_summary"] {
                try nonempty(summary, path: "\(path).derivation_segment.continuation_summary")
            }
        }
        if requireFormulaStructure, object["formula_tex"] == nil {
            throw LatticeLensError.schemaViolation("\(path) 缺少 formula_tex")
        }
        if requireEquationID {
            guard let equationID = object["equation_id"] else {
                throw LatticeLensError.schemaViolation("\(path) 缺少 equation_id")
            }
            try nonempty(equationID, path: "\(path).equation_id")
        } else if let equationID = object["equation_id"] {
            try nonempty(equationID, path: "\(path).equation_id")
        }
    }

    private static func formulaStep(_ raw: JSONValue, path: String) throws {
        let object = try objectAllowingOptional(
            raw,
            requiredKeys: ["step_id", "ordinal", "text_zh", "rule_or_assumption", "referenced_equation_ids", "evidence_anchor_ids", "source_document_hashes", "epistemic_status"],
            optionalKeys: ["before_tex", "after_tex"],
            path: path
        )
        try nonempty(try value(object, "step_id", path), path: "\(path).step_id")
        guard let ordinal = object["ordinal"]?.integerValue, (1...FormulaDerivationStep.maximumSteps).contains(ordinal) else {
            throw LatticeLensError.schemaViolation("\(path).ordinal 无效")
        }
        try nonempty(try value(object, "text_zh", path), path: "\(path).text_zh")
        try nonempty(try value(object, "rule_or_assumption", path), path: "\(path).rule_or_assumption")
        guard let status = object["epistemic_status"]?.stringValue, EpistemicStatus(rawValue: status) != nil else {
            throw LatticeLensError.schemaViolation("\(path).epistemic_status 无效")
        }
        for key in ["referenced_equation_ids", "evidence_anchor_ids", "source_document_hashes"] {
            let values = try array(try value(object, key, path), maximum: 32, path: "\(path).\(key)")
            let strings = values.compactMap(\.stringValue)
            guard strings.count == values.count, Set(strings).count == strings.count else {
                throw LatticeLensError.schemaViolation("\(path).\(key) 不得包含重复或非字符串值")
            }
            for (index, item) in values.enumerated() {
                try nonempty(item, path: "\(path).\(key)[\(index)]")
            }
        }
        for key in ["before_tex", "after_tex"] {
            if let tex = object[key] { try nonempty(tex, path: "\(path).\(key)") }
        }
    }

    /// A successful ar5iv all-coverage artifact has a bijection between the
    /// local structural inventory and returned formula claims. This executes
    /// after ordinary shape/anchor validation so a rejection never turns a
    /// malformed provider response into an apparently valid partial result.
    private static func validateNumberedEquationCoverage(
        _ insight: PaperInsightV2,
        source: EvidenceInputPayload,
        expectedFormulaSegments: [String: FormulaDerivationSegmentExpectation]
    ) throws {
        guard source.documentSourceKind == .arxivHTML else { return }
        guard source.numberedEquationCoverageComplete else {
            throw LatticeLensError.schemaViolation(source.numberedEquationCoverageFailure ?? "编号公式索引不完整；不会生成部分覆盖结果。")
        }
        let expected = Dictionary(uniqueKeysWithValues: source.numberedEquations.map { ($0.equationID, $0) })
        let claims = insight.physics.importantFormulaDerivations
        let isBatchPayload = source.batchIndex != nil || (source.batchTotal ?? 1) > 1
        if !expectedFormulaSegments.isEmpty,
           Set(expectedFormulaSegments.keys) != Set(expected.keys) {
            throw LatticeLensError.schemaViolation("公式 segment 校验清单与本次 source equation 集合不一致")
        }
        guard claims.count == expected.count else {
            throw LatticeLensError.schemaViolation("编号公式覆盖不完整：已返回 \(claims.count)/\(expected.count) 条；不会保存部分公式推导。")
        }
        var seen = Set<String>()
        var dependencies = [String: Set<String>]()
        for claim in claims {
            guard claim.epistemicStatus == .direct,
                  let equationID = claim.equationID,
                  seen.insert(equationID).inserted,
                  let equation = expected[equationID] else {
                throw LatticeLensError.schemaViolation("编号公式覆盖无效：返回了重复或不属于本次清单的 equation_id；不会保存结果。")
            }
            guard claim.evidenceIDs == [equation.evidenceID] else {
                throw LatticeLensError.schemaViolation("编号公式覆盖无效：\(equation.label) 必须且只能使用它自己的 evidence anchor；不会保存结果。")
            }
            guard let formulaTeX = claim.formulaTeX,
                  equivalentFormulaTeX(formulaTeX, equation.tex) else {
                throw LatticeLensError.schemaViolation("编号公式覆盖无效：\(equation.label) 的 formula_tex 未逐字保留本地 ar5iv TeX；不会保存结果。")
            }
            let steps = claim.formulaDerivationSteps
            guard !steps.isEmpty, claim.derivationSteps == steps.map(\.textZH) else {
                throw LatticeLensError.schemaViolation("编号公式覆盖无效：\(equation.label) 缺少新版本 typed derivation step contract；不会保存结果。")
            }
            let segmentExpectation = expectedFormulaSegments[equationID]
            if let segmentExpectation {
                guard let metadata = claim.derivationSegment,
                      metadata.index == segmentExpectation.index,
                      metadata.isFinal ? (metadata.continuationSummary == nil && claim.conclusionZH != nil) :
                        (metadata.continuationSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && claim.conclusionZH == nil),
                      steps.count <= FormulaDerivationStep.maximumStepsPerSegment,
                      steps.first?.beforeTeX?.trimmingCharacters(in: .whitespacesAndNewlines) ==
                        segmentExpectation.precedingTeX.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    throw LatticeLensError.schemaViolation("编号公式 segment metadata、续写边界或 final/conclusion 状态不一致。")
                }
            } else {
                if let metadata = claim.derivationSegment,
                   metadata.index != 0 || !metadata.isFinal || metadata.continuationSummary != nil {
                    throw LatticeLensError.schemaViolation("未启用 segment 续写时只接受 index=0 的完整公式推导。")
                }
                if let failure = FormulaDerivationChainValidator.failure(for: claim, sourceTeX: equation.tex) {
                    throw LatticeLensError.schemaViolation(
                        "编号公式覆盖无效：\(equation.label) 的推导链不完整（\(failure.displayNameZH)）；不会保存结果。"
                    )
                }
            }
            var derivationAnchorIDs = Set(claim.evidenceIDs)
            var priorAfterTeX: String?
            for (offset, step) in steps.enumerated() {
                let expectedOrdinal = (segmentExpectation?.startingOrdinal ?? 1) + offset
                guard step.stepID == "\(equationID):step:\(expectedOrdinal)", step.ordinal == expectedOrdinal else {
                    throw LatticeLensError.schemaViolation("编号公式覆盖无效：\(equation.label) 的 step ID 或 ordinal 不连续。")
                }
                if let segmentExpectation {
                    guard let before = step.beforeTeX?.trimmingCharacters(in: .whitespacesAndNewlines),
                          let after = step.afterTeX?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !after.isEmpty,
                          before == (priorAfterTeX ?? segmentExpectation.precedingTeX.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        throw LatticeLensError.schemaViolation("编号公式 segment 内部 TeX 边界不连续。")
                    }
                    priorAfterTeX = after
                }
                guard step.epistemicStatus == .inference,
                      step.sourceDocumentHashes == [source.documentHash] else {
                    throw LatticeLensError.schemaViolation("编号公式覆盖无效：\(equation.label) 的模型步骤必须标为 inference 并绑定当前 document hash。")
                }
                guard Set(step.evidenceAnchorIDs).isSubset(of: source.anchorAllowlist),
                      !step.evidenceAnchorIDs.isEmpty || !step.referencedEquationIDs.isEmpty else {
                    throw LatticeLensError.schemaViolation("编号公式覆盖无效：\(equation.label) 的步骤缺少当前来源 anchor 或公式依赖。")
                }
                guard !step.referencedEquationIDs.contains(equationID) else {
                    throw LatticeLensError.schemaViolation("编号公式覆盖无效：\(equation.label) 的步骤含自身依赖。")
                }
                if step.structuralStatus == .rejected {
                    throw LatticeLensError.schemaViolation("编号公式覆盖无效：\(equation.label) 的 TeX 结构检查拒绝该步骤。")
                }
                let dependencyAnchorIDs = step.referencedEquationIDs.compactMap { expected[$0]?.evidenceID }
                let supportingAnchorIDs = Set(step.evidenceAnchorIDs).union(dependencyAnchorIDs)
                derivationAnchorIDs.formUnion(supportingAnchorIDs)
                let quotes = supportingAnchorIDs.compactMap { source.sourceByAnchor[$0] }
                let numericContent = [step.textZH, step.ruleOrAssumption,
                                      step.beforeTeX ?? "", step.afterTeX ?? ""].joined(separator: " ")
                guard NumericClaimEvidence.isAnchored(numericContent, quotes: quotes) else {
                    throw LatticeLensError.schemaViolation("编号公式覆盖无效：\(equation.label) 的步骤数值无法回查同一来源 anchor。")
                }
                dependencies[equationID, default: []].formUnion(step.referencedEquationIDs)
            }
            let conclusionQuotes = derivationAnchorIDs.compactMap { source.sourceByAnchor[$0] }
            if let conclusion = claim.conclusionZH,
               !NumericClaimEvidence.isAnchored(conclusion, quotes: conclusionQuotes) {
                throw LatticeLensError.schemaViolation("编号公式覆盖无效：\(equation.label) 的结论数值无法回查来源 anchor。")
            }
            if !isBatchPayload {
                guard steps.allSatisfy({ Set($0.referencedEquationIDs).isSubset(of: Set(expected.keys)) }) else {
                    throw LatticeLensError.schemaViolation("编号公式 coverage 引用了当前 inventory 之外的 equation ID。")
                }
            }
        }
        guard seen == Set(expected.keys) else {
            throw LatticeLensError.schemaViolation("编号公式覆盖不完整：已返回 \(seen.count)/\(expected.count) 条；不会保存部分公式推导。")
        }
        if !isBatchPayload, containsDependencyCycle(dependencies) {
            throw LatticeLensError.schemaViolation("编号公式 derivation dependency graph 存在有向环。")
        }
        // For a batch request the equality above is intentionally scoped to
        // that batch.  The caller must run this validator again with the
        // unbatched source before writing a complete artifact.  Keeping this
        // branch explicit documents the boundary and prevents a future
        // change from treating a partial batch as full coverage.
        _ = isBatchPayload
    }

    private static func containsDependencyCycle(_ dependencies: [String: Set<String>]) -> Bool {
        var visiting = Set<String>()
        var visited = Set<String>()
        func visit(_ node: String) -> Bool {
            if visiting.contains(node) { return true }
            if visited.contains(node) { return false }
            visiting.insert(node)
            for dependency in dependencies[node, default: []] where visit(dependency) { return true }
            visiting.remove(node)
            visited.insert(node)
            return false
        }
        return dependencies.keys.contains(where: visit)
    }

    /// The local extractor stores bare annotation TeX. A provider may retain
    /// only an outer display delimiter; accept that harmless presentation
    /// wrapper but reject all expression edits, whitespace rewrites included.
    private static func equivalentFormulaTeX(_ candidate: String, _ source: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare: String
        if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count >= 4 {
            bare = String(trimmed.dropFirst(2).dropLast(2))
        } else if trimmed.hasPrefix("$"), trimmed.hasSuffix("$"), trimmed.count >= 2 {
            bare = String(trimmed.dropFirst().dropLast())
        } else {
            bare = trimmed
        }
        return bare == source
    }

    /// Providers may serialize valid array elements in a different order. The
    /// persisted reader must nevertheless follow the original paper order,
    /// which is the deterministic ordinal order of the local inventory.
    private static func canonicalFormulaOrder(_ insight: PaperInsightV2, source: EvidenceInputPayload) -> PaperInsightV2 {
        guard source.documentSourceKind == .arxivHTML, !source.numberedEquations.isEmpty else { return insight }
        let claimsByID = Dictionary(uniqueKeysWithValues: insight.physics.importantFormulaDerivations.compactMap { claim in
            claim.equationID.map { ($0, claim) }
        })
        let orderedClaims = source.numberedEquations.compactMap { claimsByID[$0.equationID] }
        let physics = InsightPhysicsV2(
            researchQuestion: insight.physics.researchQuestion,
            methodAndDataFlow: insight.physics.methodAndDataFlow,
            mainResults: insight.physics.mainResults,
            reasonableInferences: insight.physics.reasonableInferences,
            missingInformation: insight.physics.missingInformation,
            caveats: insight.physics.caveats,
            importantFormulaDerivations: orderedClaims
        )
        return PaperInsightV2(
            schemaVersion: insight.schemaVersion,
            sourceScope: insight.sourceScope,
            titleZH: insight.titleZH,
            abstractZH: insight.abstractZH,
            physics: physics,
            importantFigures: insight.importantFigures,
            terminology: insight.terminology
        )
    }

    /// A research question is normally a direct, anchored claim.  `missing`
    /// is also accepted for the explicit non-claim sentinel emitted by
    /// `UnanchoredEvidenceClaimNormalizer` (or when the supplied source
    /// genuinely does not state a research question).  Inference remains
    /// forbidden here: it would turn the paper's stated question into a
    /// model-authored interpretation.
    private static func researchQuestionClaim(_ raw: JSONValue) throws {
        try claim(raw, path: "physics.research_question")
        guard let status = raw.objectValue?["epistemic_status"]?.stringValue,
              status == EpistemicStatus.direct.rawValue || status == EpistemicStatus.missing.rawValue else {
            throw LatticeLensError.schemaViolation("physics.research_question 必须是 direct 或 missing")
        }
    }

    private static func object(_ raw: JSONValue, keys: Set<String>, path: String) throws -> [String: JSONValue] {
        guard let object = raw.objectValue, Set(object.keys) == keys else { throw LatticeLensError.schemaViolation("\(path) 包含未知或缺失 key") }
        return object
    }

    private static func objectAllowingOptional(_ raw: JSONValue, requiredKeys: Set<String>, optionalKeys: Set<String>, path: String) throws -> [String: JSONValue] {
        guard let object = raw.objectValue else { throw LatticeLensError.schemaViolation("\(path) 不是对象") }
        let keys = Set(object.keys)
        guard requiredKeys.isSubset(of: keys), keys.subtracting(requiredKeys).isSubset(of: optionalKeys) else {
            throw LatticeLensError.schemaViolation("\(path) 包含未知或缺失 key")
        }
        return object
    }

    private static func value(_ object: [String: JSONValue], _ key: String, _ path: String) throws -> JSONValue {
        guard let value = object[key] else { throw LatticeLensError.schemaViolation("\(path) 缺少 \(key)") }
        return value
    }

    private static func array(_ raw: JSONValue, maximum: Int, path: String) throws -> [JSONValue] {
        guard let array = raw.arrayValue, array.count <= maximum else { throw LatticeLensError.schemaViolation("\(path) 不是受限数组") }
        return array
    }

    private static func nonempty(_ raw: JSONValue, path: String) throws {
        guard let string = raw.stringValue, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, string.unicodeScalars.count <= 16_000 else {
            throw LatticeLensError.schemaViolation("\(path) 不是受限非空字符串")
        }
    }

    private static func abstractText(_ raw: JSONValue, path: String) throws {
        guard let string = raw.stringValue,
              string.unicodeScalars.count <= 16_000,
              (string.isEmpty || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
            throw LatticeLensError.schemaViolation("\(path) 不是受限字符串；仅可用空字符串表示来源未提供摘要")
        }
    }
}

/// Repairs the single invalid JSON pattern emitted by some LLMs for TeX:
/// a literal U+005C command marker inside a quoted JSON string (for example,
/// `\\alpha`) instead of the JSON encoding that represents that marker.  It is
/// deliberately a byte-level, syntax-preserving normalizer rather than a
/// permissive JSON parser: valid escapes stay byte-identical, a malformed
/// unicode escape stays malformed, and the strict duplicate-key parser still
/// rejects every other invalid JSON construct.
private enum BareTeXJSONEscapeNormalizer {
    private static let backslash: UInt8 = 0x5C
    private static let quote: UInt8 = 0x22
    private static let unicodeEscape: UInt8 = 0x75

    static func normalize(_ data: Data) -> Data {
        let input = Array(data)
        var output = [UInt8]()
        output.reserveCapacity(input.count)
        var index = 0
        var insideString = false

        while index < input.count {
            let byte = input[index]
            if !insideString {
                output.append(byte)
                if byte == quote { insideString = true }
                index += 1
                continue
            }

            if byte == quote {
                output.append(byte)
                insideString = false
                index += 1
                continue
            }

            guard byte == backslash else {
                output.append(byte)
                index += 1
                continue
            }

            guard index + 1 < input.count else {
                output.append(byte)
                index += 1
                continue
            }

            let following = input[index + 1]
            if isStandardSimpleEscape(following) {
                output.append(byte)
                output.append(following)
                index += 2
                continue
            }
            if following == unicodeEscape {
                // Keep both valid and malformed unicode escapes unchanged so
                // the strict JSON grammar reports malformed sequences instead
                // of treating them as TeX.
                output.append(byte)
                output.append(following)
                index += 2
                continue
            }

            // A non-JSON escape in a model-written reader-facing string is
            // treated as a literal TeX-style command marker.  Doubling it
            // makes the surrounding JSON valid while preserving the exact
            // character the reader should see after decoding.
            output.append(backslash)
            output.append(backslash)
            index += 1
        }
        return Data(output)
    }

    private static func isStandardSimpleEscape(_ byte: UInt8) -> Bool {
        [quote, backslash, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(byte)
    }
}

/// Repairs one unambiguous model formatting error: a comma omitted *between*
/// two already-complete JSON values in an array. This is intentionally not a
/// general JSON repairer. Only `"string" "string"` and `{...}{...}` can cross
/// this boundary, because those are the two repeated item shapes permitted by
/// the Evidence schema. Object members, numbers, literals, malformed escapes,
/// control characters, truncated values and all other malformed constructs are
/// rejected by returning the original bytes to the strict parser.
private enum MissingArrayCommaJSONNormalizer {
    static func normalize(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        var parser = Parser(bytes: Array(data))
        guard (try? parser.parseDocument()) != nil, parser.didRepair else { return data }
        return Data(parser.output)
    }

    private enum ValueKind: Equatable {
        case object
        case array
        case string
        case primitive
    }

    private enum ParseFailure: Error {
        case invalid
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var output = [UInt8]()
        var didRepair = false

        init(bytes: [UInt8]) {
            self.bytes = bytes
            output.reserveCapacity(bytes.count)
        }

        mutating func parseDocument() throws {
            _ = try parseValue()
            copyWhitespace()
            guard index == bytes.count else { throw ParseFailure.invalid }
        }

        mutating func parseValue() throws -> ValueKind {
            copyWhitespace()
            guard index < bytes.count else { throw ParseFailure.invalid }
            switch bytes[index] {
            case 0x7B:
                try parseObject()
                return .object
            case 0x5B:
                try parseArray()
                return .array
            case 0x22:
                try parseString()
                return .string
            case 0x74:
                try parseLiteral("true")
                return .primitive
            case 0x66:
                try parseLiteral("false")
                return .primitive
            case 0x6E:
                try parseLiteral("null")
                return .primitive
            case 0x2D, 0x30...0x39:
                try parseNumber()
                return .primitive
            default:
                throw ParseFailure.invalid
            }
        }

        mutating func parseObject() throws {
            try expectAndCopy(0x7B)
            copyWhitespace()
            if consumeAndCopy(0x7D) { return }
            while true {
                copyWhitespace()
                try parseString()
                copyWhitespace()
                try expectAndCopy(0x3A)
                _ = try parseValue()
                copyWhitespace()
                if consumeAndCopy(0x7D) { return }
                try expectAndCopy(0x2C)
            }
        }

        mutating func parseArray() throws {
            try expectAndCopy(0x5B)
            copyWhitespace()
            if consumeAndCopy(0x5D) { return }
            while true {
                let previous = try parseValue()
                copyWhitespace()
                if consumeAndCopy(0x5D) { return }
                if consumeAndCopy(0x2C) { continue }
                guard index < bytes.count,
                      isUnambiguousArrayBoundary(after: previous, before: bytes[index]) else {
                    throw ParseFailure.invalid
                }
                // Whitespace preceding this insertion has already been copied;
                // JSON permits the comma after that whitespace and it leaves
                // the values themselves byte-identical.
                output.append(0x2C)
                didRepair = true
            }
        }

        mutating func parseString() throws {
            try expectAndCopy(0x22)
            while index < bytes.count {
                let byte = takeAndCopy()
                if byte == 0x22 { return }
                guard byte >= 0x20 else { throw ParseFailure.invalid }
                guard byte == 0x5C else { continue }
                guard index < bytes.count else { throw ParseFailure.invalid }
                let escaped = takeAndCopy()
                if escaped == 0x75 {
                    for _ in 0..<4 {
                        guard index < bytes.count, isHex(bytes[index]) else { throw ParseFailure.invalid }
                        _ = takeAndCopy()
                    }
                } else if !isSimpleEscape(escaped) {
                    throw ParseFailure.invalid
                }
            }
            throw ParseFailure.invalid
        }

        mutating func parseLiteral(_ literal: String) throws {
            for expected in literal.utf8 {
                guard index < bytes.count, bytes[index] == expected else { throw ParseFailure.invalid }
                _ = takeAndCopy()
            }
        }

        mutating func parseNumber() throws {
            if index < bytes.count, bytes[index] == 0x2D { _ = takeAndCopy() }
            guard index < bytes.count else { throw ParseFailure.invalid }
            if bytes[index] == 0x30 {
                _ = takeAndCopy()
            } else {
                try consumeDigits()
            }
            if index < bytes.count, bytes[index] == 0x2E {
                _ = takeAndCopy()
                try consumeDigits()
            }
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                _ = takeAndCopy()
                if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { _ = takeAndCopy() }
                try consumeDigits()
            }
        }

        mutating func consumeDigits() throws {
            let start = index
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { _ = takeAndCopy() }
            guard index > start else { throw ParseFailure.invalid }
        }

        mutating func copyWhitespace() {
            while index < bytes.count, isWhitespace(bytes[index]) { _ = takeAndCopy() }
        }

        mutating func expectAndCopy(_ expected: UInt8) throws {
            guard consumeAndCopy(expected) else { throw ParseFailure.invalid }
        }

        mutating func consumeAndCopy(_ expected: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == expected else { return false }
            _ = takeAndCopy()
            return true
        }

        mutating func takeAndCopy() -> UInt8 {
            let byte = bytes[index]
            output.append(byte)
            index += 1
            return byte
        }

        private func isUnambiguousArrayBoundary(after previous: ValueKind, before next: UInt8) -> Bool {
            (previous == .string && next == 0x22) || (previous == .object && next == 0x7B)
        }

        private func isWhitespace(_ byte: UInt8) -> Bool {
            [0x20, 0x0A, 0x0D, 0x09].contains(byte)
        }

        private func isSimpleEscape(_ byte: UInt8) -> Bool {
            [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(byte)
        }

        private func isHex(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
        }
    }
}

/// Prevents unprovable provider prose from crossing the Evidence boundary
/// without inventing a source relationship. A well-shaped `direct` or
/// `inference` item is eligible for removal only when its IDs are empty or
/// outside the current payload allowlist. Its text is never persisted.  Bad
/// JSON types, duplicate IDs, unknown keys, wrong section statuses, invalid
/// formula structure, `missing` claims with IDs, and numeric claims whose
/// *valid* anchors do not contain the value remain hard validation failures.
private enum UnanchoredEvidenceClaimNormalizer {
    private static let discardedClaimNotice =
        "模型返回的部分 direct/inference 内容缺少本次有效 evidence anchor，已丢弃且未作为论文结论保存。"
    private static let unavailableResearchQuestion =
        "模型未将研究问题返回为可回查的当前证据；未采纳未锚定的原始文本。"

    static func normalize(_ raw: JSONValue, anchorAllowlist: Set<String>) -> JSONValue {
        guard case .object(var root) = raw,
              case .object(var physics)? = root["physics"] else {
            return raw
        }

        var discarded = false
        if let question = physics["research_question"] {
            if isLegacyScalarResearchQuestion(question) ||
                isDiscardableUnanchoredClaim(question, anchorAllowlist: anchorAllowlist, requiredStatus: .direct,
                                             requiresFormulaStructure: false, requiresEquationID: false) {
                physics["research_question"] = missingClaim(unavailableResearchQuestion)
                discarded = true
            }
        }

        for key in ["method_and_data_flow", "main_results"] {
            if let filtered = filteringDiscardableClaims(
                physics[key], anchorAllowlist: anchorAllowlist, allowedStatuses: [.direct], requiresFormulaStructure: false
            ) {
                physics[key] = filtered.value
                discarded = discarded || filtered.didDiscard
            }
        }
        if let filtered = filteringDiscardableClaims(
            physics["reasonable_inferences"], anchorAllowlist: anchorAllowlist, allowedStatuses: [.inference], requiresFormulaStructure: false
        ) {
            physics["reasonable_inferences"] = filtered.value
            discarded = discarded || filtered.didDiscard
        }
        if let filtered = filteringDiscardableClaims(
            physics["caveats"], anchorAllowlist: anchorAllowlist, allowedStatuses: [.direct, .inference], requiresFormulaStructure: false
        ) {
            physics["caveats"] = filtered.value
            discarded = discarded || filtered.didDiscard
        }
        if let filtered = filteringDiscardableClaims(
            physics["important_formula_derivations"], anchorAllowlist: anchorAllowlist, allowedStatuses: [.direct], requiresFormulaStructure: true
        ) {
            physics["important_formula_derivations"] = filtered.value
            discarded = discarded || filtered.didDiscard
        }

        if discarded, case .array(var missing)? = physics["missing_information"],
           missing.count < 32,
           !missing.contains(where: { $0.objectValue?["text_zh"]?.stringValue == discardedClaimNotice }) {
            missing.append(missingClaim(discardedClaimNotice))
            physics["missing_information"] = .array(missing)
        }
        root["physics"] = .object(physics)
        return .object(root)
    }

    private static func isLegacyScalarResearchQuestion(_ raw: JSONValue) -> Bool {
        guard let question = raw.stringValue else { return false }
        return isBoundedNonempty(question)
    }

    private static func filteringDiscardableClaims(
        _ raw: JSONValue?,
        anchorAllowlist: Set<String>,
        allowedStatuses: Set<EpistemicStatus>,
        requiresFormulaStructure: Bool
    ) -> (value: JSONValue, didDiscard: Bool)? {
        guard case .array(let items)? = raw else { return nil }
        var didDiscard = false
        let retained = items.filter { item in
            guard let itemStatus = status(of: item), allowedStatuses.contains(itemStatus) else {
                return true
            }
            let shouldDiscard = isDiscardableUnanchoredClaim(
                item,
                anchorAllowlist: anchorAllowlist,
                requiredStatus: itemStatus,
                requiresFormulaStructure: requiresFormulaStructure,
                requiresEquationID: requiresFormulaStructure
            )
            didDiscard = didDiscard || shouldDiscard
            return !shouldDiscard
        }
        return (.array(retained), didDiscard)
    }

    private static func status(of raw: JSONValue) -> EpistemicStatus? {
        guard let value = raw.objectValue?["epistemic_status"]?.stringValue else { return nil }
        return EpistemicStatus(rawValue: value)
    }

    /// This intentionally repeats the bounded item-shape checks used by the
    /// strict validator. If any shape condition is absent, the item is left
    /// untouched so `validateShape` can reject it rather than hiding a parser
    /// or schema failure behind the compatibility path.
    private static func isDiscardableUnanchoredClaim(
        _ raw: JSONValue,
        anchorAllowlist: Set<String>,
        requiredStatus: EpistemicStatus?,
        requiresFormulaStructure: Bool,
        requiresEquationID: Bool
    ) -> Bool {
        let requiredKeys: Set<String> = ["text_zh", "epistemic_status", "evidence_ids"]
        let optionalKeys: Set<String> = ["formula_tex", "equation_id", "derivation_steps", "derivation_step_contract", "conclusion_zh", "derivation_segment"]
        guard let object = raw.objectValue,
              requiredKeys.isSubset(of: Set(object.keys)),
              Set(object.keys).subtracting(requiredKeys).isSubset(of: optionalKeys),
              let status = status(of: raw), let requiredStatus, status == requiredStatus,
              status == .direct || status == .inference,
              let text = object["text_zh"]?.stringValue, isBoundedNonempty(text),
              let evidenceValues = object["evidence_ids"]?.arrayValue,
              evidenceValues.count <= 16 else {
            return false
        }
        let evidenceIDs = evidenceValues.compactMap(\.stringValue)
        guard evidenceIDs.count == evidenceValues.count,
              Set(evidenceIDs).count == evidenceIDs.count,
              evidenceIDs.allSatisfy(isBoundedNonempty),
              validOptionalFormulaFields(object, requiresFormulaStructure: requiresFormulaStructure,
                                         requiresEquationID: requiresEquationID) else {
            return false
        }
        return evidenceIDs.isEmpty || !Set(evidenceIDs).isSubset(of: anchorAllowlist)
    }

    private static func validOptionalFormulaFields(
        _ object: [String: JSONValue],
        requiresFormulaStructure: Bool,
        requiresEquationID: Bool
    ) -> Bool {
        if let formula = object["formula_tex"],
           !(formula.stringValue.map(isBoundedNonempty) ?? false) {
            return false
        }
        if let steps = object["derivation_steps"] {
            guard let values = steps.arrayValue, values.count <= FormulaDerivationStep.maximumStepsPerSegment,
                  values.allSatisfy({ $0.stringValue.map(isBoundedNonempty) ?? false }),
                  !requiresFormulaStructure || !values.isEmpty else {
                return false
            }
        } else if requiresFormulaStructure {
            return false
        }
        if let conclusion = object["conclusion_zh"],
           !(conclusion.stringValue.map(isBoundedNonempty) ?? false) {
            return false
        }
        if let equationID = object["equation_id"],
           !(equationID.stringValue.map(isBoundedNonempty) ?? false) {
            return false
        }
        if let rawSegment = object["derivation_segment"] {
            guard let segment = rawSegment.objectValue,
                  Set(segment.keys).isSubset(of: ["index", "is_final", "continuation_summary"]),
                  let index = segment["index"]?.integerValue,
                  (0..<FormulaDerivationSegmentCheckpoint.maximumSegmentsPerEquation).contains(index),
                  case .bool? = segment["is_final"] else {
                return false
            }
            if let summary = segment["continuation_summary"],
               !(summary.stringValue.map(isBoundedNonempty) ?? false) {
                return false
            }
        }
        return (!requiresFormulaStructure || object["formula_tex"] != nil) &&
            (!requiresEquationID || object["equation_id"] != nil)
    }

    private static func missingClaim(_ text: String) -> JSONValue {
        .object([
            "text_zh": .string(text),
            "epistemic_status": .string(EpistemicStatus.missing.rawValue),
            "evidence_ids": .array([])
        ])
    }

    private static func isBoundedNonempty(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.unicodeScalars.count <= 16_000
    }
}
