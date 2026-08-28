import Foundation

struct EvidenceInputPayload: Codable, Sendable {
    static let maximumChunks = 12
    static let maximumAnchors = 32
    static let maximumPayloadBytes = 256 * 1024
    static let maximumPayloadScalars = 120_000
    let paperID: Int
    let documentHash: String
    let title: String
    let abstract: String?
    let chunks: [EvidenceChunk]
    let anchors: [EvidenceAnchor]
    let figureKeys: [String]
    let retrievalQuery: String
    let rankerVersion: String
    let payloadByteCount: Int
    let payloadScalarCount: Int
    let payloadTokenEstimate: Int

    init(paper: Paper, document: FullTextDocument, chunks: [EvidenceChunk], anchors: [EvidenceAnchor]) {
        paperID = paper.literatureID
        documentHash = document.sha256
        title = paper.displayTitle
        abstract = paper.preferredAbstract
        var selectedChunks = [EvidenceChunk]()
        var runningBytes = 0
        var runningScalars = 0
        for chunk in chunks.filter({ $0.paperID == paper.literatureID && $0.documentHash == document.sha256 }).prefix(Self.maximumChunks) {
            let chunkBytes = chunk.byteCount
            let chunkScalars = chunk.scalarCount
            guard runningBytes + chunkBytes <= Self.maximumPayloadBytes,
                  runningScalars + chunkScalars <= Self.maximumPayloadScalars else { break }
            selectedChunks.append(chunk)
            runningBytes += chunkBytes
            runningScalars += chunkScalars
        }
        let selectedIDs = Set(selectedChunks.map(\.id))
        self.chunks = selectedChunks
        // A v2 request contains only retrieved PDF anchors plus a small,
        // deterministic metadata allowance.  Metadata provenance remains
        // useful before/alongside full text, but it must not turn an unbounded
        // collection of captions into an implicit whole-library prompt.
        let pdfAnchors = anchors.filter { selectedIDs.contains($0.id) }.sorted { $0.id < $1.id }
        let metadataAnchors = anchors.filter { $0.sourceKind != .pdf }.sorted { $0.id < $1.id }
        self.anchors = Array((pdfAnchors + metadataAnchors).prefix(Self.maximumAnchors))
        figureKeys = Array(paper.figures.prefix(12).map(\.key))
        retrievalQuery = SearchNormalizer.normalize(paper.displayTitle)
        rankerVersion = "local-title-token-v1"
        payloadByteCount = self.chunks.reduce(0) { $0 + $1.byteCount } + self.anchors.reduce(0) { $0 + $1.quote.utf8.count }
        payloadScalarCount = self.chunks.reduce(0) { $0 + $1.scalarCount } + self.anchors.reduce(0) { $0 + $1.quote.unicodeScalars.count }
        payloadTokenEstimate = self.chunks.reduce(0) { $0 + $1.tokenEstimate } + self.anchors.reduce(0) { $0 + max(1, $1.quote.split { $0.isWhitespace || $0.isPunctuation }.count) }
    }

    var anchorAllowlist: Set<String> { Set(anchors.map(\.id)) }
    var sourceByAnchor: [String: String] { Dictionary(uniqueKeysWithValues: anchors.map { ($0.id, $0.quote) }) }
}

struct LocalEvidenceRetriever: Sendable {
    let maximumChunks: Int

    init(maximumChunks: Int = 12) { self.maximumChunks = max(1, maximumChunks) }

    func retrieve(paper: Paper, snapshot: LibrarySnapshot) -> (document: FullTextDocument, chunks: [EvidenceChunk], anchors: [EvidenceAnchor])? {
        guard let document = snapshot.fullTextDocuments.values
            .filter({ $0.paperID == paper.literatureID && $0.extractionState == .extracted })
            .sorted(by: { ($0.downloadedAt ?? .distantPast) > ($1.downloadedAt ?? .distantPast) }).first else { return nil }
        let allChunks = snapshot.evidenceChunks.values.filter { $0.paperID == paper.literatureID && $0.documentHash == document.sha256 }
        let terms = Set(SearchNormalizer.normalize(paper.displayTitle).split(whereSeparator: { $0 == " " }).map(String.init).filter { $0.count >= 3 })
        let ranked = allChunks.sorted { lhs, rhs in
            let lhsScore = terms.reduce(0) { $0 + (SearchNormalizer.normalize(lhs.text).contains($1) ? 1 : 0) }
            let rhsScore = terms.reduce(0) { $0 + (SearchNormalizer.normalize(rhs.text).contains($1) ? 1 : 0) }
            return lhsScore == rhsScore ? lhs.id < rhs.id : lhsScore > rhsScore
        }
        let chunks = Array(ranked.prefix(maximumChunks))
        let ids = Set(chunks.map(\.id))
        let pdfAnchors = snapshot.evidenceAnchors.values.filter { ids.contains($0.id) }
        // Abstract/caption anchors are persisted independently of a PDF and
        // are intentionally retained when a full-text document is deleted.
        let metadataAnchors = snapshot.evidenceAnchors.values.filter {
            $0.paperID == paper.literatureID && $0.sourceKind != .pdf
        }
        let anchors = (pdfAnchors + metadataAnchors).sorted { $0.id < $1.id }
        guard !chunks.isEmpty, !pdfAnchors.isEmpty else { return nil }
        return (document, chunks, anchors)
    }
}

enum PaperInsightV2Validator {
    static let schemaVersion = "paper-insight-v2"
    static let sourceScope = "fulltext_with_anchors"

    static func decode(_ data: Data, source: EvidenceInputPayload, maximumFigures: Int) throws -> PaperInsightV2 {
        guard !data.isEmpty, data.count <= PaperInsightValidator.maximumResponseBytes else { throw LatticeLensError.schemaViolation("v2 insight 响应超限") }
        try JSONDuplicateKeyDetector.validate(data)
        guard let raw = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw LatticeLensError.schemaViolation("v2 insight JSON 无法解码") }
        try validateShape(raw)
        try validateEvidenceInput(source)
        guard let insight = try? JSONDecoder.latticeLens.decode(PaperInsightV2.self, from: data),
              insight.schemaVersion == schemaVersion, insight.sourceScope == sourceScope else {
            throw LatticeLensError.schemaViolation("v2 schema 或 source scope 不匹配")
        }
        guard insight.importantFigures.count <= maximumFigures,
              (maximumFigures > 0 || insight.importantFigures.isEmpty),
              insight.importantFigures.allSatisfy({ source.figureKeys.contains($0.figureKey) && $0.evidenceMode == .captionOnly }) else {
            throw LatticeLensError.schemaViolation("v2 图像选择越出本地 allowlist")
        }
        let claims = [insight.physics.researchQuestion] + insight.physics.methodAndDataFlow + insight.physics.mainResults +
            insight.physics.reasonableInferences + insight.physics.missingInformation + insight.physics.caveats
        for claim in claims {
            switch claim.epistemicStatus {
            case .direct, .inference:
                guard !claim.evidenceIDs.isEmpty, Set(claim.evidenceIDs).isSubset(of: source.anchorAllowlist) else {
                    throw LatticeLensError.schemaViolation("direct/inference claim 缺少本次有效 evidence anchor")
                }
                // A value and its unit must be recoverable from one original
                // anchor, never by concatenating two unrelated snippets.
                let quotes = claim.evidenceIDs.compactMap { source.sourceByAnchor[$0] }
                guard numericTokensAreAnchored(claim.textZH, quotes: quotes) else {
                    throw LatticeLensError.schemaViolation("v2 精确数值或单位无法回查 evidence")
                }
            case .missing:
                guard claim.evidenceIDs.isEmpty else { throw LatticeLensError.schemaViolation("missing claim 不得伪造 anchor") }
            }
        }
        return insight
    }

    private static func validateShape(_ raw: JSONValue) throws {
        let root = try object(raw, keys: ["schema_version", "source_scope", "title_zh", "abstract_zh", "physics", "important_figures", "terminology"], path: "root")
        for key in ["schema_version", "source_scope", "title_zh", "abstract_zh"] { try nonempty(try value(root, key, "root"), path: key) }
        let physics = try object(try value(root, "physics", "root"), keys: ["research_question", "method_and_data_flow", "main_results", "reasonable_inferences", "missing_information", "caveats"], path: "physics")
        try claim(try value(physics, "research_question", "physics"), path: "physics.research_question", requiredStatus: .direct)
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
                guard let chunk = chunksByID[anchor.id], chunk.page == anchor.page,
                      chunk.textHash == anchor.quoteHash, chunk.text == anchor.quote else {
                    throw LatticeLensError.schemaViolation("v2 PDF anchor 不属于本次受限 document payload")
                }
            }
        }
    }

    private static func claim(_ raw: JSONValue, path: String, requiredStatus: EpistemicStatus? = nil) throws {
        let object = try object(raw, keys: ["text_zh", "epistemic_status", "evidence_ids"], path: path)
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
    }

    private static func numericTokensAreAnchored(_ text: String, quotes: [String]) -> Bool {
        // Only numbers carrying a physical unit/uncertainty, or an explicit
        // ensemble/count context, are treated as physics tokens.  Years,
        // equation labels, reference numbers and page numbers therefore do
        // not force a claim to cite an unrelated anchor.
        let pattern = #"(?<![0-9A-Za-z])[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?(?:\s*(?:±|\+/-)\s*[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)?(?:\s*(?:GeV|MeV|keV|TeV|fm(?:\^-?\d+)?|GeV\^\d+|%|a(?:\^-?\d+)?|L\^3[×x*]T|L|T|cfg(?:s)?|ensembles?))?(?![0-9A-Za-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        let values = regex.matches(in: text, range: range).compactMap { match -> String? in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            let token = String(text[swiftRange])
            let hasUnit = token.range(of: #"(?:GeV|MeV|keV|TeV|fm|%|\ba\b|\bL\b|\bT\b|cfg|ensemble)"#, options: [.regularExpression, .caseInsensitive]) != nil
            let hasUncertainty = token.contains("±") || token.contains("+/-") || token.contains("(")
            if hasUnit || hasUncertainty { return token }
            let contextStart = text.index(swiftRange.lowerBound, offsetBy: -32, limitedBy: text.startIndex) ?? text.startIndex
            let contextEnd = text.index(swiftRange.upperBound, offsetBy: 32, limitedBy: text.endIndex) ?? text.endIndex
            let context = text[contextStart..<contextEnd]
            return context.range(of: #"ensemble|configuration|config|sample|trajectory|t[_ -]?sep|source[ -]?sink|momentum"#, options: [.regularExpression, .caseInsensitive]) != nil ? token : nil
        }
        return values.allSatisfy { token in
            let pattern = "(?<![0-9A-Za-z])\(NSRegularExpression.escapedPattern(for: token))(?![0-9A-Za-z])"
            return quotes.contains { quote in
                (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: quote, range: NSRange(quote.startIndex..., in: quote)) != nil
            }
        }
    }

    private static func object(_ raw: JSONValue, keys: Set<String>, path: String) throws -> [String: JSONValue] {
        guard let object = raw.objectValue, Set(object.keys) == keys else { throw LatticeLensError.schemaViolation("\(path) 包含未知或缺失 key") }
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
}
