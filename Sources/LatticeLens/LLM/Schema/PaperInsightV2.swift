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
        // A v2 request contains only retrieved full-text anchors plus a small,
        // deterministic metadata allowance.  Metadata provenance remains
        // useful before/alongside full text, but it must not turn an unbounded
        // collection of captions into an implicit whole-library prompt.
        let fullTextAnchors = anchors.filter { selectedIDs.contains($0.id) }.sorted { $0.id < $1.id }
        let metadataAnchors = anchors.filter { $0.sourceKind != .pdf }.sorted { $0.id < $1.id }
        self.anchors = Array((fullTextAnchors + metadataAnchors).prefix(Self.maximumAnchors))
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
        let ranked = allChunks.sorted { lhs, rhs in
            let lhsScore = terms.reduce(0) { $0 + (SearchNormalizer.normalize(lhs.text).contains($1) ? 1 : 0) }
            let rhsScore = terms.reduce(0) { $0 + (SearchNormalizer.normalize(rhs.text).contains($1) ? 1 : 0) }
            return lhsScore == rhsScore ? lhs.id < rhs.id : lhsScore > rhsScore
        }
        let chunks = Array(ranked.prefix(maximumChunks))
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

    static func decode(_ data: Data, source: EvidenceInputPayload, maximumFigures: Int) throws -> PaperInsightV2 {
        guard !data.isEmpty, data.count <= PaperInsightValidator.maximumResponseBytes else { throw LatticeLensError.schemaViolation("v2 insight 响应超限") }
        // LLMs sometimes put a TeX command such as `\\alpha` directly inside a
        // JSON string, rather than serialising the command marker as a JSON
        // backslash escape.  Repair only that wire-format defect before the
        // duplicate-key grammar walk; the repair never changes a valid JSON
        // escape, never repairs malformed `\\u` escapes, and all semantic,
        // provenance, anchor, numeric and size checks still follow below.
        let normalizedData = BareTeXJSONEscapeNormalizer.normalize(data)
        guard normalizedData.count <= PaperInsightValidator.maximumResponseBytes else {
            throw LatticeLensError.schemaViolation("v2 insight 响应超限")
        }
        try JSONDuplicateKeyDetector.validate(normalizedData)
        guard let raw = try? JSONDecoder().decode(JSONValue.self, from: normalizedData) else { throw LatticeLensError.schemaViolation("v2 insight JSON 无法解码") }
        // A number of OpenAI-compatible gateways add harmless transport
        // metadata, or place the model's JSON object under `data`/`result`.
        // That metadata is not evidence and must never be saved.  Recover one
        // unambiguous contract object, then validate only the fields the app
        // actually persists.  Missing required fields, duplicate keys, bad
        // types, non-allowlisted anchors and unanchored numeric claims remain
        // hard failures below.
        let contractRoot = try extractContractRoot(from: raw)
        // Some otherwise complete OpenAI-compatible replies regress only this
        // field to a bare string.  Never reinterpret that string as a direct
        // research claim: the normalizer replaces it with a visible `missing`
        // sentinel, so formula claims still face the normal anchor/provenance
        // checks below while an unrelated schema typo does not discard them.
        let normalizedContractRoot = UnanchoredResearchQuestionNormalizer.normalize(contractRoot)
        try validateShape(normalizedContractRoot)
        try validateEvidenceInput(source)
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
            let items = try array(formulas, maximum: 8, path: "physics.important_formula_derivations")
            for (index, item) in items.enumerated() {
                try claim(item, path: "physics.important_formula_derivations[\(index)]", requiredStatus: .direct,
                          requireFormulaStructure: true)
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
                guard let chunk = chunksByID[anchor.id], chunk.page == anchor.page,
                      chunk.textHash == anchor.quoteHash, chunk.text == anchor.quote else {
                    throw LatticeLensError.schemaViolation("v2 全文 anchor 不属于本次受限 document payload")
                }
            }
        }
    }

    private static func claim(_ raw: JSONValue, path: String, requiredStatus: EpistemicStatus? = nil,
                              requireFormulaStructure: Bool = false) throws {
        let object = try objectAllowingOptional(raw,
                                                requiredKeys: ["text_zh", "epistemic_status", "evidence_ids"],
                                                optionalKeys: ["formula_tex", "derivation_steps", "conclusion_zh"],
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
            let values = try array(steps, maximum: 8, path: "\(path).derivation_steps")
            for (index, step) in values.enumerated() {
                try nonempty(step, path: "\(path).derivation_steps[\(index)]")
            }
            if requireFormulaStructure {
                guard !values.isEmpty else { throw LatticeLensError.schemaViolation("\(path).derivation_steps 不能为空") }
            }
        } else if requireFormulaStructure {
            throw LatticeLensError.schemaViolation("\(path) 缺少 derivation_steps")
        }
        if let conclusion = object["conclusion_zh"] {
            try nonempty(conclusion, path: "\(path).conclusion_zh")
        }
        if requireFormulaStructure, object["formula_tex"] == nil {
            throw LatticeLensError.schemaViolation("\(path) 缺少 formula_tex")
        }
    }

    /// A research question is normally a direct, anchored claim.  `missing`
    /// is also accepted for the explicit non-claim sentinel emitted by
    /// `UnanchoredResearchQuestionNormalizer` (or when the supplied source
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

/// Preserves the evidence boundary when a provider returns the one observed
/// legacy shape `physics.research_question: "..."`.  A scalar has neither an
/// epistemic label nor an anchor, so accepting its wording as a direct claim
/// would fabricate provenance.  Instead, replace only that exact scalar with
/// an explicit `missing` claim and deliberately drop the unanchored text.  No
/// arrays, objects, other fields, anchors, numerical claims, or unknown types
/// are repaired by this compatibility path.
private enum UnanchoredResearchQuestionNormalizer {
    static func normalize(_ raw: JSONValue) -> JSONValue {
        guard case .object(var root) = raw,
              case .object(var physics)? = root["physics"],
              let question = physics["research_question"]?.stringValue,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.unicodeScalars.count <= 16_000 else {
            return raw
        }

        physics["research_question"] = .object([
            "text_zh": .string("模型未将研究问题返回为可回查对象；未采纳未锚定的原始文本。"),
            "epistemic_status": .string(EpistemicStatus.missing.rawValue),
            "evidence_ids": .array([])
        ])
        root["physics"] = .object(physics)
        return .object(root)
    }
}
