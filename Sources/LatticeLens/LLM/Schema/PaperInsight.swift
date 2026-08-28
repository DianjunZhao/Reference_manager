import Foundation

enum InsightMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fast
    case deep
    var id: String { rawValue }
    var displayName: String { self == .fast ? "Fast（1 次请求）" : "Deep（2 次请求）" }
}

enum InsightDetailLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case concise
    case standard
    case detailed
    var id: String { rawValue }
    var displayName: String {
        switch self { case .concise: "简洁"; case .standard: "标准"; case .detailed: "详细" }
    }
}

enum EvidenceMode: String, Codable, Sendable {
    case captionOnly = "caption_only"
}

struct InsightPhysics: Codable, Hashable, Sendable {
    let researchQuestion: String
    let background: String
    let methodAndDataFlow: [String]
    let mainResults: [String]
    let latticeConventionsReported: [String]
    let missingInformation: [String]
    let caveats: [String]

    enum CodingKeys: String, CodingKey {
        case researchQuestion = "research_question"
        case background
        case methodAndDataFlow = "method_and_data_flow"
        case mainResults = "main_results"
        case latticeConventionsReported = "lattice_conventions_reported"
        case missingInformation = "missing_information"
        case caveats
    }
}

struct ImportantFigureInsight: Codable, Hashable, Sendable, Identifiable {
    let figureKey: String
    let captionZH: String
    let whyImportant: String
    let evidenceMode: EvidenceMode
    var id: String { figureKey }

    enum CodingKeys: String, CodingKey {
        case figureKey = "figure_key"
        case captionZH = "caption_zh"
        case whyImportant = "why_important"
        case evidenceMode = "evidence_mode"
    }
}

struct InsightTerminology: Codable, Hashable, Sendable, Identifiable {
    let source: String
    let zh: String
    let note: String
    var id: String { source }
}

struct PaperInsightV1: Codable, Hashable, Sendable {
    let schemaVersion: String
    let sourceScope: String
    let titleZH: String
    let abstractZH: String
    let physics: InsightPhysics
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

struct InsightSourcePayload: Codable, Sendable {
    let paperID: Int
    let updated: Date?
    let titles: [PaperTitle]
    let abstracts: [PaperAbstract]
    let arxivID: String?
    let arxivCategories: [String]
    let doi: String?
    let figures: [SourceFigure]
    /// Audit-only field: records local truncation categories, never the removed
    /// text. It lets the UI disclose bounded prompt input without leaking it.
    let truncatedFields: [String]

    static let maximumTitles = 8
    static let maximumAbstracts = 4
    static let maximumFigures = 12
    static let maximumTextScalars = 12_000

    struct SourceFigure: Codable, Sendable {
        let key: String
        let label: String?
        let caption: String?
    }

    init(paper: Paper) {
        paperID = paper.literatureID
        updated = paper.updated
        var truncations: [String] = []
        let sourceTitles = Array(paper.titles.prefix(Self.maximumTitles))
        if paper.titles.count > sourceTitles.count { truncations.append("titles.count") }
        titles = sourceTitles.map { item in
            let value = Self.truncate(item.value, field: "title", truncations: &truncations)
            return PaperTitle(value: value, source: item.source)
        }
        let sourceAbstracts = Array(paper.abstracts.prefix(Self.maximumAbstracts))
        if paper.abstracts.count > sourceAbstracts.count { truncations.append("abstracts.count") }
        abstracts = sourceAbstracts.map { item in
            let value = Self.truncate(item.value, field: "abstract", truncations: &truncations)
            return PaperAbstract(value: value, source: item.source)
        }
        arxivID = paper.arxivID
        arxivCategories = paper.arxivCategories
        doi = paper.doi
        let sourceFigures = Array(paper.figures.prefix(Self.maximumFigures))
        if paper.figures.count > sourceFigures.count { truncations.append("figures.count") }
        figures = sourceFigures.map {
            SourceFigure(key: $0.key,
                         label: $0.label.map { Self.truncate($0, field: "figure.label", truncations: &truncations) },
                         caption: $0.caption.map { Self.truncate($0, field: "figure.caption", truncations: &truncations) })
        }
        truncatedFields = truncations.sorted()
    }

    var figureKeyAllowlist: Set<String> { Set(figures.map(\.key)) }
    var sourceText: String {
        (titles.map(\.value) + abstracts.map(\.value) + figures.compactMap(\.caption) + figures.compactMap(\.label)).joined(separator: "\n")
    }

    private static func truncate(_ value: String, field: String, truncations: inout [String]) -> String {
        guard value.unicodeScalars.count > maximumTextScalars else { return value }
        truncations.append(field)
        let scalars = value.unicodeScalars.prefix(maximumTextScalars)
        return String(String.UnicodeScalarView(scalars))
    }
}

enum PaperInsightValidator {
    static let maximumResponseBytes = 1_000_000

    static func decode(
        _ data: Data,
        source: InsightSourcePayload,
        maximumFigures: Int
    ) throws -> PaperInsightV1 {
        guard !data.isEmpty, data.count <= maximumResponseBytes else {
            throw LatticeLensError.schemaViolation("响应为空或超过本地大小上限")
        }
        try JSONDuplicateKeyDetector.validate(data)
        let raw: JSONValue
        do { raw = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw LatticeLensError.schemaViolation("JSON 无法解码") }
        try validateShape(raw)
        let insight: PaperInsightV1
        do {
            insight = try JSONDecoder.latticeLens.decode(PaperInsightV1.self, from: data)
        } catch {
            throw LatticeLensError.schemaViolation("不是 paper-insight-v1 JSON")
        }
        guard insight.schemaVersion == ProductContract.insightSchemaVersion else {
            throw LatticeLensError.schemaViolation("schema_version 不匹配")
        }
        guard insight.sourceScope == ProductContract.sourceScope else {
            throw LatticeLensError.schemaViolation("source_scope 越过标题、摘要与 captions 边界")
        }
        guard insight.importantFigures.count <= max(0, maximumFigures) else {
            throw LatticeLensError.schemaViolation("重要图像数量超过本地设置")
        }
        guard (maximumFigures != 0 || insight.importantFigures.isEmpty) else {
            throw LatticeLensError.schemaViolation("maximum figures 为 0 时必须返回空图像数组")
        }
        guard insight.importantFigures.allSatisfy({
            source.figureKeyAllowlist.contains($0.figureKey) && $0.evidenceMode == .captionOnly
        }) else {
            throw LatticeLensError.schemaViolation("模型返回了不在本次资料中的图像 key")
        }
        let claims = [insight.physics.researchQuestion, insight.physics.background] + insight.physics.methodAndDataFlow +
            insight.physics.mainResults + insight.physics.latticeConventionsReported + insight.physics.missingInformation + insight.physics.caveats
        guard claims.allSatisfy({ isNumericallySupported($0, by: source.sourceText) }) else {
            throw LatticeLensError.schemaViolation("带精确数值的物理陈述缺少摘要或 caption 锚点")
        }
        return insight
    }

    private static func isNumericallySupported(_ claim: String, by source: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: "(?<![0-9A-Za-z])[0-9]+(?:[.][0-9]+)?(?:\\s*(?:GeV|MeV|fm|%|a|L|T))?(?![0-9A-Za-z])", options: []) else { return false }
        let range = NSRange(claim.startIndex..., in: claim)
        let numericTokens = expression.matches(in: claim, range: range).compactMap { match -> String? in
            guard let swiftRange = Range(match.range, in: claim) else { return nil }
            return String(claim[swiftRange])
        }
        return numericTokens.allSatisfy { token in
            let escaped = NSRegularExpression.escapedPattern(for: token)
            let boundary = "(?<![0-9A-Za-z])\(escaped)(?![0-9A-Za-z])"
            guard let tokenExpression = try? NSRegularExpression(pattern: boundary) else { return false }
            return tokenExpression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil
        }
    }

    private static func validateShape(_ raw: JSONValue) throws {
        let root = try requireObject(raw, path: "root", exact: ["schema_version", "source_scope", "title_zh", "abstract_zh", "physics", "important_figures", "terminology"])
        let physics = try requireObject(try require(root, "physics", path: "root"), path: "physics",
                                        exact: ["research_question", "background", "method_and_data_flow", "main_results", "lattice_conventions_reported", "missing_information", "caveats"])
        let scalarKeys = ["research_question", "background"]
        for key in scalarKeys { try requireBoundedString(try require(physics, key, path: "physics"), path: "physics.\(key)") }
        for key in ["method_and_data_flow", "main_results", "lattice_conventions_reported", "missing_information", "caveats"] {
            try requireStringArray(try require(physics, key, path: "physics"), path: "physics.\(key)", maximum: 32)
        }
        try requireBoundedString(try require(root, "title_zh", path: "root"), path: "title_zh")
        try requireBoundedString(try require(root, "abstract_zh", path: "root"), path: "abstract_zh")
        let figures = try requireArray(try require(root, "important_figures", path: "root"), path: "important_figures", maximum: 5)
        for (index, value) in figures.enumerated() {
            let figure = try requireObject(value, path: "important_figures[\(index)]", exact: ["figure_key", "caption_zh", "why_important", "evidence_mode"])
            for key in ["figure_key", "caption_zh", "why_important", "evidence_mode"] {
                try requireBoundedString(try require(figure, key, path: "important_figures[\(index)]"), path: "important_figures[\(index)].\(key)")
            }
        }
        let terms = try requireArray(try require(root, "terminology", path: "root"), path: "terminology", maximum: TerminologyEntry.maximumItems)
        for (index, value) in terms.enumerated() {
            let term = try requireObject(value, path: "terminology[\(index)]", exact: ["source", "zh", "note"])
            for key in ["source", "zh", "note"] { try requireBoundedString(try require(term, key, path: "terminology[\(index)]"), path: "terminology[\(index)].\(key)") }
        }
    }

    private static func requireObject(_ value: JSONValue, path: String, exact keys: Set<String>) throws -> [String: JSONValue] {
        guard let object = value.objectValue, Set(object.keys) == keys else { throw LatticeLensError.schemaViolation("\(path) 的 key 集合不符合 schema") }
        return object
    }

    private static func require(_ object: [String: JSONValue], _ key: String, path: String) throws -> JSONValue {
        guard let value = object[key] else { throw LatticeLensError.schemaViolation("\(path) 缺少 \(key)") }
        return value
    }

    private static func requireArray(_ value: JSONValue, path: String, maximum: Int) throws -> [JSONValue] {
        guard let array = value.arrayValue, array.count <= maximum else { throw LatticeLensError.schemaViolation("\(path) 不是受限数组") }
        return array
    }

    private static func requireStringArray(_ value: JSONValue, path: String, maximum: Int) throws {
        for (index, item) in try requireArray(value, path: path, maximum: maximum).enumerated() {
            try requireBoundedString(item, path: "\(path)[\(index)]")
        }
    }

    private static func requireBoundedString(_ value: JSONValue, path: String) throws {
        guard let string = value.stringValue,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              string.unicodeScalars.count <= 16_000 else { throw LatticeLensError.schemaViolation("\(path) 不是受限非空字符串") }
    }
}

/// Before JSONDecoder collapses duplicate keys, make the JSON grammar walk and
/// reject ambiguous objects.  This intentionally accepts only standard JSON.
enum JSONDuplicateKeyDetector {
    static func validate(_ data: Data) throws {
        var parser = Parser(bytes: Array(data), index: 0)
        try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw LatticeLensError.schemaViolation("JSON 尾部含有额外内容") }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index: Int

        mutating func parseValue() throws {
            skipWhitespace()
            guard index < bytes.count else { throw LatticeLensError.schemaViolation("JSON 意外结束") }
            switch bytes[index] {
            case 0x7B: try parseObject()
            case 0x5B: try parseArray()
            case 0x22: _ = try parseString()
            case 0x74: try parseLiteral("true")
            case 0x66: try parseLiteral("false")
            case 0x6E: try parseLiteral("null")
            case 0x2D, 0x30...0x39: try parseNumber()
            default: throw LatticeLensError.schemaViolation("JSON token 无效")
            }
        }

        mutating func parseObject() throws {
            index += 1
            skipWhitespace()
            var keys = Set<String>()
            if consume(0x7D) { return }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 0x22 else { throw LatticeLensError.schemaViolation("object key 无效") }
                let key = try parseString()
                guard keys.insert(key).inserted else { throw LatticeLensError.schemaViolation("JSON object 有重复 key：\(key)") }
                skipWhitespace()
                guard consume(0x3A) else { throw LatticeLensError.schemaViolation("JSON object 缺少冒号") }
                try parseValue()
                skipWhitespace()
                if consume(0x7D) { return }
                guard consume(0x2C) else { throw LatticeLensError.schemaViolation("JSON object 缺少逗号") }
            }
        }

        mutating func parseArray() throws {
            index += 1
            skipWhitespace()
            if consume(0x5D) { return }
            while true {
                try parseValue()
                skipWhitespace()
                if consume(0x5D) { return }
                guard consume(0x2C) else { throw LatticeLensError.schemaViolation("JSON array 缺少逗号") }
            }
        }

        mutating func parseString() throws -> String {
            guard consume(0x22) else { throw LatticeLensError.schemaViolation("string 无效") }
            var output = [UInt8]()
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 0x22 {
                    var encoded = Data([0x22])
                    encoded.append(contentsOf: output)
                    encoded.append(0x22)
                    guard let string = try? JSONDecoder().decode(String.self, from: encoded) else {
                        throw LatticeLensError.schemaViolation("UTF-8 string 无效")
                    }
                    return string
                }
                guard byte >= 0x20 else { throw LatticeLensError.schemaViolation("string 含控制字符") }
                if byte == 0x5C {
                    guard index < bytes.count else { throw LatticeLensError.schemaViolation("string escape 无效") }
                    let escaped = bytes[index]
                    index += 1
                    if escaped == 0x75 {
                        guard index + 4 <= bytes.count else { throw LatticeLensError.schemaViolation("unicode escape 无效") }
                        let hex = Array(bytes[index..<(index + 4)])
                        guard hex.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }) else {
                            throw LatticeLensError.schemaViolation("unicode escape 无效")
                        }
                        output.append(contentsOf: "\\u".utf8)
                        output.append(contentsOf: hex)
                        index += 4
                    } else {
                        guard [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escaped) else {
                            throw LatticeLensError.schemaViolation("string escape 无效")
                        }
                        output.append(0x5C)
                        output.append(escaped)
                    }
                } else { output.append(byte) }
            }
            throw LatticeLensError.schemaViolation("string 未结束")
        }

        mutating func parseLiteral(_ literal: String) throws {
            let expected = Array(literal.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<(index + expected.count)]) == expected else {
                throw LatticeLensError.schemaViolation("JSON literal 无效")
            }
            index += expected.count
        }

        mutating func parseNumber() throws {
            let start = index
            if consume(0x2D) {}
            guard index < bytes.count else { throw LatticeLensError.schemaViolation("JSON number 无效") }
            if consume(0x30) {
                // Leading zero is complete before a possible fractional part.
            } else {
                try consumeDigits()
            }
            if consume(0x2E) { try consumeDigits() }
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                index += 1
                if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
                try consumeDigits()
            }
            guard index > start else { throw LatticeLensError.schemaViolation("JSON number 无效") }
        }

        mutating func consumeDigits() throws {
            let start = index
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
            guard index > start else { throw LatticeLensError.schemaViolation("JSON number 无效") }
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
    }
}
