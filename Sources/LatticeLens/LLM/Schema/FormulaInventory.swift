import Foundation

/// Bounded TeX structure checks used for step status only. A pass establishes
/// balanced delimiters/environments and required arguments for the small
/// supported command subset; it never establishes algebraic or physical
/// equivalence. Unknown macros stay readable and are marked for manual review.
enum FormulaStepTeXStructure {
    private enum ParseResult { case supported, unsupported, malformed }

    static func status(before: String?, after: String?) -> FormulaStructuralStatus {
        guard let before, let after,
              !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .needsManual
        }
        let results = [before, after].map(parse)
        if results.contains(where: { if case .malformed = $0 { true } else { false } }) { return .rejected }
        if results.contains(where: { if case .unsupported = $0 { true } else { false } }) { return .needsManual }
        return .verifiedStructural
    }

    private static func parse(_ source: String) -> ParseResult {
        var unsupported = false
        var delimiters = [Character]()
        var slashRun = 0
        for character in source {
            let escaped = slashRun.isMultiple(of: 2) == false
            if !escaped {
                switch character {
                case "{", "(", "[": delimiters.append(character)
                case "}", ")", "]":
                    let expected: Character = character == "}" ? "{" : (character == ")" ? "(" : "[")
                    guard delimiters.popLast() == expected else { return .malformed }
                default: break
                }
            }
            slashRun = character == "\\" ? slashRun + 1 : 0
        }
        guard delimiters.isEmpty else { return .malformed }

        var cursor = source.startIndex
        slashRun = 0
        while cursor < source.endIndex {
            let character = source[cursor]
            let escaped = slashRun.isMultiple(of: 2) == false
            if !escaped && (character == "_" || character == "^") {
                let next = source.index(after: cursor)
                guard scriptArgumentEnd(in: source, after: next) != nil else { return .malformed }
            }
            slashRun = character == "\\" ? slashRun + 1 : 0
            cursor = source.index(after: cursor)
        }

        let ns = source as NSString
        let environmentRegex = try! NSRegularExpression(pattern: #"\\(begin|end)\s*\{([A-Za-z0-9*]+)\}"#)
        var environments = [String]()
        let environmentMatches = environmentRegex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        for match in environmentMatches {
            guard let actionRange = Range(match.range(at: 1), in: source),
                  let nameRange = Range(match.range(at: 2), in: source) else { return .malformed }
            let action = String(source[actionRange])
            let name = String(source[nameRange])
            if action == "begin" { environments.append(name) }
            else if environments.popLast() != name { return .malformed }
        }
        guard environments.isEmpty else { return .malformed }

        let commandRegex = try! NSRegularExpression(pattern: #"\\([A-Za-z]+)"#)
        let commandMatches = commandRegex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        let requiredSingleGroup: Set<String> = ["mathrm", "mathit", "mathbf", "mathcal", "mathbb", "mathsf", "mathtt", "operatorname", "text", "overline", "underline", "bar", "hat", "tilde", "vec", "dot", "ddot", "widehat", "widetilde"]
        let known: Set<String> = [
            "alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta", "theta", "vartheta", "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "varpi", "rho", "varrho", "sigma", "tau", "upsilon", "phi", "varphi", "chi", "psi", "omega",
            "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Upsilon", "Phi", "Psi", "Omega",
            "frac", "sqrt", "mathrm", "mathit", "mathbf", "mathcal", "mathbb", "mathsf", "mathtt", "operatorname", "text", "overline", "underline", "bar", "hat", "tilde", "vec", "dot", "ddot", "widehat", "widetilde",
            "sum", "prod", "int", "oint", "lim", "exp", "log", "ln", "sin", "cos", "tan", "max", "min", "sup", "inf", "det", "tr", "Re", "Im",
            "partial", "nabla", "cdot", "times", "pm", "mp", "le", "leq", "ge", "geq", "neq", "approx", "sim", "simeq", "equiv", "propto", "infty", "to", "rightarrow", "leftarrow", "Rightarrow", "Leftarrow", "leftrightarrow", "mapsto", "in", "notin", "subset", "subseteq", "cup", "cap", "forall", "exists", "mathbbm", "displaystyle", "textstyle", "quad", "qquad", ",", ";", ":", "!", "left", "right", "big", "Big", "bigg", "Bigg", "begin", "end"
        ]
        for match in commandMatches {
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let wholeRange = Range(match.range(at: 0), in: source) else { return .malformed }
            let name = String(source[nameRange])
            if !known.contains(name) { unsupported = true; continue }
            var cursor = wholeRange.upperBound
            if name == "frac" {
                guard let first = groupEnd(in: source, after: cursor, opener: "{", closer: "}"),
                      groupEnd(in: source, after: first, opener: "{", closer: "}") != nil else { return .malformed }
            } else if name == "sqrt" {
                cursor = skippingWhitespace(in: source, from: cursor)
                if cursor < source.endIndex, source[cursor] == "[" {
                    guard let optionalEnd = groupEnd(in: source, after: cursor, opener: "[", closer: "]") else { return .malformed }
                    cursor = optionalEnd
                }
                guard groupEnd(in: source, after: cursor, opener: "{", closer: "}") != nil else { return .malformed }
            } else if requiredSingleGroup.contains(name),
                      groupEnd(in: source, after: cursor, opener: "{", closer: "}") == nil {
                return .malformed
            }
        }
        return unsupported ? .unsupported : .supported
    }

    private static func groupEnd(in source: String, after index: String.Index,
                                 opener: Character, closer: Character) -> String.Index? {
        var cursor = skippingWhitespace(in: source, from: index)
        guard cursor < source.endIndex, source[cursor] == opener else { return nil }
        var depth = 0
        var slashRun = 0
        while cursor < source.endIndex {
            let character = source[cursor]
            let escaped = slashRun.isMultiple(of: 2) == false
            if !escaped {
                if character == opener { depth += 1 }
                if character == closer {
                    depth -= 1
                    if depth == 0 { return source.index(after: cursor) }
                }
            }
            slashRun = character == "\\" ? slashRun + 1 : 0
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func skippingWhitespace(in source: String, from index: String.Index) -> String.Index {
        var cursor = index
        while cursor < source.endIndex, source[cursor].isWhitespace { cursor = source.index(after: cursor) }
        return cursor
    }

    private static func scriptArgumentEnd(in source: String, after index: String.Index) -> String.Index? {
        let start = skippingWhitespace(in: source, from: index)
        guard start < source.endIndex else { return nil }
        if source[start] == "{" { return groupEnd(in: source, after: start, opener: "{", closer: "}") }
        if source[start] == "\\" {
            var end = source.index(after: start)
            while end < source.endIndex, source[end].isLetter { end = source.index(after: end) }
            return end == source.index(after: start) && end < source.endIndex ? source.index(after: end) : end
        }
        return source.index(after: start)
    }
}

/// One numbered display equation discovered in the local ar5iv document.
/// `sourceTeX` is immutable provenance: model output is never allowed to
/// rewrite it.  The byte range and DOM path are diagnostic coordinates only;
/// the document hash remains the identity boundary.
struct FormulaInventoryItem: Codable, Hashable, Sendable, Identifiable {
    let equationID: String
    let label: String
    let sourceTeX: String
    let normalizedTeXHash: String
    let ordinal: Int
    let domPath: String
    let sourceByteStart: Int
    let sourceByteEnd: Int
    let documentHash: String
    let evidenceID: String?

    init(equationID: String, label: String, sourceTeX: String,
         ordinal: Int, domPath: String = "", sourceByteStart: Int = 0,
         sourceByteEnd: Int = 0, documentHash: String, evidenceID: String? = nil,
         normalizedTeXHash: String? = nil) {
        self.equationID = equationID
        self.label = label
        self.sourceTeX = sourceTeX
        self.normalizedTeXHash = normalizedTeXHash ?? StableHash.sha256(sourceTeX)
        self.ordinal = ordinal
        self.domPath = domPath
        self.sourceByteStart = max(0, sourceByteStart)
        self.sourceByteEnd = max(self.sourceByteStart, sourceByteEnd)
        self.documentHash = documentHash
        self.evidenceID = evidenceID
    }

    var id: String { equationID }
    /// Short aliases make the value convenient for prompt/test fixtures while
    /// keeping `sourceTeX` as the canonical persisted field.
    var tex: String { sourceTeX }
    var sourceTex: String { sourceTeX }
}

struct FormulaInventory: Codable, Hashable, Sendable, Identifiable {
    /// Bump this whenever DOM recovery semantics change. Persisted indexes
    /// carrying an older parser version must be rebuilt before a provider job
    /// can be considered complete.
    static let currentParserVersion = 3
    static let maximumItems = 256

    let documentHash: String
    let parserVersion: Int
    let items: [FormulaInventoryItem]
    let labelledEquationCount: Int
    let failureReason: String?
    /// When an inventory is reconstructed from a persisted, already verified
    /// payload, retain the parser's original hash even though DOM coordinates
    /// are no longer available in the compact evidence projection.
    let declaredInventoryHash: String?

    init(documentHash: String, items: [FormulaInventoryItem],
         labelledEquationCount: Int? = nil, parserVersion: Int = currentParserVersion,
         failureReason: String? = nil, declaredInventoryHash: String? = nil) {
        self.documentHash = documentHash
        self.parserVersion = parserVersion
        self.items = items.sorted { $0.ordinal == $1.ordinal ? $0.equationID < $1.equationID : $0.ordinal < $1.ordinal }
        self.labelledEquationCount = labelledEquationCount ?? items.count
        self.failureReason = failureReason
        self.declaredInventoryHash = declaredInventoryHash
    }

    var id: String { inventoryHash }
    var equationIDs: [String] { items.map(\.equationID) }
    var labels: [String] { items.map(\.label) }
    var isComplete: Bool {
        failureReason == nil && labelledEquationCount == items.count &&
            Set(equationIDs).count == equationIDs.count && items.allSatisfy { $0.documentHash == documentHash }
    }
    var inventoryHash: String {
        if let declaredInventoryHash { return declaredInventoryHash }
        let basis = items.map {
            "\($0.equationID)|\($0.label)|\($0.normalizedTeXHash)|\($0.ordinal)|\($0.domPath)|\($0.sourceByteStart)-\($0.sourceByteEnd)|\($0.documentHash)"
        }.joined(separator: "\n")
        return StableHash.sha256("formula-inventory-v\(parserVersion)|\(documentHash)|\(labelledEquationCount)|\(basis)|failure:\(failureReason ?? "")")
    }

    /// A payload-only identity is useful when a caller has the validated
    /// `NumberedEquationInput` projection but not the full DOM coordinates.
    /// It intentionally uses the same document/parser boundary as the full
    /// inventory and never treats model-generated formula text as a source.
    static func payloadHash(documentHash: String, equations: [NumberedEquationInput],
                            parserVersion: Int = currentParserVersion) -> String {
        let basis = equations.enumerated().map { index, equation in
            "\(index + 1)|\(equation.equationID)|\(equation.label)|\(StableHash.sha256(equation.tex))|\(equation.evidenceID)"
        }.joined(separator: "\n")
        return StableHash.sha256("formula-payload-v\(parserVersion)|\(documentHash)|\(basis)")
    }
}

/// A small, dependency-free tolerant HTML tree used only for ar5iv's
/// semantic equation markup.  It deliberately does not execute scripts or
/// fetch any remote resources.  Unlike a regex over complete containers, it
/// handles nested tags, align rows and annotations split across text nodes.
enum FormulaInventoryParser {
    static let parserVersion = FormulaInventory.currentParserVersion

    static func parse(html: String, documentHash: String,
                      maximumItems: Int = FormulaInventory.maximumItems) -> FormulaInventory {
        let limit = max(1, maximumItems)
        let tree = HTMLTreeParser(html: html).parse()
        var labels = tree.nodes.filter { $0.hasClass("ltx_tag_equation") }
            .map { (node: $0, label: htmlText($0.textContent)) }
        labels.sort { $0.node.start < $1.node.start }
        guard labels.count <= limit else {
            return FormulaInventory(documentHash: documentHash, items: [], labelledEquationCount: labels.count,
                                     parserVersion: parserVersion,
                                     failureReason: "ar5iv HTML 中检测到 \(labels.count) 条带编号公式，超过本地上限 \(limit)。")
        }

        var items = [FormulaInventoryItem]()
        var seenLabels = Set<String>()
        var failures = [String]()
        for (labelNode, rawLabel) in labels {
            let label = normalizeLabel(rawLabel)
            if !seenLabels.insert(label).inserted {
                failures.append("检测到重复的可见公式编号 \(label)。")
                continue
            }
            guard label.range(of: #"\d"#, options: .regularExpression) != nil else {
                failures.append("检测到不支持的可见公式编号 \(label.isEmpty ? "(空)" : label)。")
                continue
            }
            guard let container = labelNode.nearestAncestor(where: {
                $0.hasClass("ltx_equation") || $0.hasClass("ltx_eqn_row") || $0.tag == "tr" ||
                $0.hasClass("ltx_eqn_table") || $0.hasClass("ltx_align") || $0.hasClass("ltx_multline")
            }) else {
                failures.append("编号公式 \(label) 缺少 ltx_equation 容器。")
                continue
            }
            let labelsInContainer = container.descendantsAndSelf()
                .filter { $0.hasClass("ltx_tag_equation") }
                .sorted { $0.start < $1.start }
            let mathNodes = container.descendantsAndSelf().filter { $0.tag == "math" }.sorted { $0.start < $1.start }
            guard !mathNodes.isEmpty else {
                failures.append("编号公式 \(label) 缺少 MathML/TeX annotation。")
                continue
            }
            guard labelsInContainer.count == 1, mathNodes.count == 1,
                  labelsInContainer.first === labelNode else {
                failures.append("公式容器中的可见编号与 MathML 数量不一致；编号公式 \(label) 无法唯一配对。")
                continue
            }
            let math = mathNodes[0]
            guard let tex = tex(from: math), !tex.isEmpty else {
                failures.append("编号公式 \(label) 缺少可恢复的 source TeX。")
                continue
            }
            let ordinal = items.count + 1
            let equationID = "ar5iv:\(documentHash):\(ordinal)"
            items.append(FormulaInventoryItem(
                equationID: equationID, label: label, sourceTeX: tex,
                ordinal: ordinal, domPath: math.domPath,
                sourceByteStart: container.start, sourceByteEnd: container.end,
                documentHash: documentHash
            ))
        }
        if tree.unclosedTagCount > 0 { failures.append("ar5iv HTML 包含未闭合的结构标签，无法证明公式边界。") }
        let failure = failures.isEmpty && items.count == labels.count ? nil :
            (failures + (items.count == labels.count ? [] : ["ar5iv HTML 中检测到 \(labels.count) 条带编号公式，但仅能为 \(items.count) 条建立 TeX/evidence 记录；不会生成部分覆盖结果。"]))
                .joined(separator: " ")
        var finalItems = items
        // Evidence IDs are derived from the final ordinal and hash in the
        // existing store contract.  Keep inventory standalone but provide the
        // same deterministic value for callers that build anchors from it.
        finalItems = finalItems.map { item in
            let quote = "编号公式 \(item.label)\n$$\(item.sourceTeX)$$"
            let qHash = StableHash.sha256(quote)
            return FormulaInventoryItem(equationID: item.equationID, label: item.label, sourceTeX: item.sourceTeX,
                                        ordinal: item.ordinal, domPath: item.domPath,
                                        sourceByteStart: item.sourceByteStart, sourceByteEnd: item.sourceByteEnd,
                                        documentHash: item.documentHash,
                                        evidenceID: "ar5iv-equation:inventory:\(item.ordinal):\(qHash)",
                                        normalizedTeXHash: item.normalizedTeXHash)
        }
        return FormulaInventory(documentHash: documentHash, items: finalItems,
                                 labelledEquationCount: labels.count, parserVersion: parserVersion,
                                 failureReason: failure)
    }

    private static func tex(from math: HTMLNode) -> String? {
        if let annotation = math.descendantsAndSelf().first(where: {
            $0.tag == "annotation" && ($0.attributes["encoding"]?.lowercased() == "application/x-tex" ||
                $0.attributes["encoding"]?.lowercased() == "text/x-tex")
        }) {
            return htmlText(annotation.textContent)
        }
        if let alt = math.attributes.first(where: { $0.key.lowercased() == "alttext" })?.value {
            return htmlText(alt)
        }
        return nil
    }

    private static func normalizeLabel(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func htmlText(_ value: String) -> String {
        var output = value
        let named: [(String, String)] = [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")]
        for (from, to) in named { output = output.replacingOccurrences(of: from, with: to) }
        if let regex = try? NSRegularExpression(pattern: #"&#x([0-9A-Fa-f]+);|&#([0-9]+);"#) {
            let range = NSRange(output.startIndex..., in: output)
            for match in regex.matches(in: output, range: range).reversed() {
                guard let whole = Range(match.range, in: output) else { continue }
                let hex = match.range(at: 1).location != NSNotFound ? String(output[Range(match.range(at: 1), in: output)!]) : nil
                let decimal = match.range(at: 2).location != NSNotFound ? String(output[Range(match.range(at: 2), in: output)!]) : nil
                if let scalar = UInt32(hex ?? decimal ?? "", radix: hex == nil ? 10 : 16).flatMap(UnicodeScalar.init) {
                    output.replaceSubrange(whole, with: String(scalar))
                }
            }
        }
        return output.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class HTMLNode {
    let tag: String
    let attributes: [String: String]
    let start: Int
    var end: Int
    weak var parent: HTMLNode?
    var children: [HTMLNode] = []
    private var orderedContent: [HTMLContent] = []

    init(tag: String, attributes: [String: String], start: Int, end: Int, parent: HTMLNode? = nil) {
        self.tag = tag; self.attributes = attributes; self.start = start; self.end = end; self.parent = parent
    }

    func hasClass(_ value: String) -> Bool {
        let classes = (attributes["class"] ?? "").split(whereSeparator: { character in
            character == " " || character == "\n" || character == "\t"
        })
        return classes.contains { $0 == Substring(value) }
    }

    func descendantsAndSelf() -> [HTMLNode] { [self] + children.flatMap { $0.descendantsAndSelf() } }

    func append(child: HTMLNode) {
        children.append(child)
        orderedContent.append(.element(child))
    }

    func append(text: String) {
        guard !text.isEmpty else { return }
        orderedContent.append(.text(text))
    }

    func nearestAncestor(where predicate: (HTMLNode) -> Bool) -> HTMLNode? {
        var current: HTMLNode? = self
        while let node = current { if predicate(node) { return node }; current = node.parent }
        return nil
    }
    var textContent: String {
        orderedContent.map { item in
            switch item {
            case .text(let value): value
            case .element(let child): child.textContent
            }
        }.joined()
    }
    var domPath: String {
        var parts = [String](); var current: HTMLNode? = self
        while let node = current {
            let siblings = node.parent?.children.filter { $0.tag == node.tag } ?? [node]
            let index = (siblings.firstIndex { $0 === node } ?? 0) + 1
            parts.append("\(node.tag)[\(index)]"); current = node.parent
        }
        return parts.reversed().joined(separator: "/")
    }
}

private enum HTMLContent {
    case text(String)
    case element(HTMLNode)
}

private struct HTMLTree {
    let root: HTMLNode
    let nodes: [HTMLNode]
    let unclosedTagCount: Int
}

private struct HTMLTreeParser {
    let html: String

    func parse() -> HTMLTree {
        let root = HTMLNode(tag: "#document", attributes: [:], start: 0, end: html.utf8.count)
        var stack = [root]
        var nodes = [HTMLNode]()
        var unclosed = 0
        var cursor = html.startIndex
        var cursorByteOffset = 0
        let voidTags: Set<String> = ["meta", "link", "img", "br", "hr", "input", "source", "area", "base", "col", "embed", "param", "track", "wbr"]
        let rawTextTags: Set<String> = ["script", "style", "textarea", "title"]

        while cursor < html.endIndex {
            guard html[cursor] == "<" else {
                let textEnd = html[cursor...].firstIndex(of: "<") ?? html.endIndex
                let text = String(html[cursor..<textEnd])
                stack.last?.append(text: text)
                cursorByteOffset += text.utf8.count
                cursor = textEnd
                continue
            }

            if html[cursor...].hasPrefix("<!--") {
                guard let commentEnd = html.range(of: "-->", range: html.index(cursor, offsetBy: 4)..<html.endIndex)?.upperBound else {
                    unclosed += 1
                    break
                }
                cursorByteOffset += html[cursor..<commentEnd].utf8.count
                cursor = commentEnd
                continue
            }

            let afterOpen = html.index(after: cursor)
            guard afterOpen < html.endIndex else {
                stack.last?.append(text: "<")
                break
            }
            let first = html[afterOpen]
            let isDeclaration = first == "!" || first == "?"
            let isEndTag = first == "/"
            let nameStart = isEndTag ? html.index(after: afterOpen) : afterOpen
            guard isDeclaration || (nameStart < html.endIndex && isASCIIAlpha(html[nameStart])) else {
                stack.last?.append(text: "<")
                cursorByteOffset += 1
                cursor = afterOpen
                continue
            }
            guard let tokenEnd = tagTokenEnd(startingAt: cursor) else {
                stack.last?.append(text: String(html[cursor...]))
                unclosed += 1
                break
            }
            let tokenStart = html.index(after: cursor)
            let tokenBodyEnd = html.index(before: tokenEnd)
            let tokenBody = String(html[tokenStart..<tokenBodyEnd])
            let startByte = cursorByteOffset
            let endByte = startByte + html[cursor..<tokenEnd].utf8.count
            cursorByteOffset = endByte
            cursor = tokenEnd

            if isDeclaration { continue }
            if isEndTag {
                let closingName = tokenBody.dropFirst().drop { $0.isWhitespace || $0 == "/" }
                    .prefix { !$0.isWhitespace && $0 != "/" }
                    .lowercased()
                if let index = stack.lastIndex(where: { $0.tag == closingName }) {
                    // Do not silently repair a closing ancestor across open
                    // descendants: equation containment would be ambiguous.
                    if index < stack.count - 1 { unclosed += stack.count - 1 - index }
                    stack[index].end = endByte
                    stack.removeSubrange(index...)
                } else {
                    unclosed += 1
                }
                continue
            }

            let trimmedBody = tokenBody.trimmingCharacters(in: .whitespacesAndNewlines)
            let isSelfClosing = trimmedBody.hasSuffix("/")
            let content = isSelfClosing
                ? String(trimmedBody.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                : trimmedBody
            let name = content.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
            guard !name.isEmpty else {
                unclosed += 1
                continue
            }
            let attributeText = String(content.dropFirst(name.count))
            let node = HTMLNode(tag: name, attributes: parseAttributes(attributeText),
                                start: startByte, end: endByte, parent: stack.last)
            stack.last?.append(child: node)
            nodes.append(node)
            if isSelfClosing || voidTags.contains(name) { continue }
            stack.append(node)

            if rawTextTags.contains(name) {
                let closePrefix = "</\(name)"
                guard let rawEnd = html.range(of: closePrefix, options: [.caseInsensitive], range: cursor..<html.endIndex)?.lowerBound else {
                    stack.last?.append(text: String(html[cursor...]))
                    stack.last?.end = html.utf8.count
                    unclosed += stack.count - 1
                    stack.removeSubrange(1...)
                    break
                }
                let rawText = String(html[cursor..<rawEnd])
                stack.last?.append(text: rawText)
                cursorByteOffset += rawText.utf8.count
                cursor = rawEnd
            }
        }
        if stack.count > 1 { unclosed += stack.count - 1; for node in stack.dropFirst() { node.end = html.utf8.count } }
        return HTMLTree(root: root, nodes: nodes, unclosedTagCount: unclosed)
    }

    private func isASCIIAlpha(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let value = character.unicodeScalars.first?.value else { return false }
        return (65...90).contains(value) || (97...122).contains(value)
    }

    /// Finds the end of a tag without treating `>` inside quoted attribute
    /// values as the tag delimiter.
    private func tagTokenEnd(startingAt start: String.Index) -> String.Index? {
        var index = html.index(after: start)
        var quote: Character?
        while index < html.endIndex {
            let character = html[index]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return html.index(after: index)
            }
            index = html.index(after: index)
        }
        return nil
    }

    private func parseAttributes(_ source: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([A-Za-z_:][A-Za-z0-9:_.-]*)(?:\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+)))?"#) else { return [:] }
        var output = [String: String]()
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
            let key = String(source[keyRange]).lowercased()
            let valueRange = [2, 3, 4].compactMap { index -> Range<String.Index>? in
                guard match.range(at: index).location != NSNotFound else { return nil }
                return Range(match.range(at: index), in: source)
            }.first
            output[key] = valueRange.map { String(source[$0]) } ?? ""
        }
        return output
    }
}

enum FormulaBatchStatus: String, Codable, CaseIterable, Sendable {
    case prepared, running, completed, retryable, paused, cancelled, failed
}

struct NumberedEquationBatch: Codable, Hashable, Sendable, Identifiable {
    let jobID: String
    let index: Int
    let total: Int
    let equationIDs: [String]
    let payloadHash: String
    let estimatedBytes: Int
    let estimatedScalars: Int
    let estimatedTokens: Int
    var id: String { "\(jobID):batch:\(index)" }
}

struct FormulaBatchCheckpoint: Codable, Hashable, Sendable, Identifiable {
    let jobID: String
    let batchIndex: Int
    let batchTotal: Int
    let equationIDs: [String]
    let payloadHash: String
    var requestID: String?
    var attemptCount: Int
    var receivedBytes: Int
    var receivedCharacters: Int
    var firstContentAt: Date?
    var lastContentAt: Date?
    var status: FormulaBatchStatus
    var errorCategory: String?
    var updatedAt: Date
    var id: String { "\(jobID):batch:\(batchIndex)" }

    init(jobID: String, batchIndex: Int, batchTotal: Int, equationIDs: [String], payloadHash: String,
         requestID: String? = nil, attemptCount: Int = 0, receivedBytes: Int = 0,
         receivedCharacters: Int = 0, firstContentAt: Date? = nil, lastContentAt: Date? = nil,
         status: FormulaBatchStatus = .prepared, errorCategory: String? = nil, updatedAt: Date = Date()) {
        self.jobID = jobID; self.batchIndex = batchIndex; self.batchTotal = batchTotal
        self.equationIDs = equationIDs; self.payloadHash = payloadHash; self.requestID = requestID
        self.attemptCount = attemptCount; self.receivedBytes = receivedBytes; self.receivedCharacters = receivedCharacters
        self.firstContentAt = firstContentAt; self.lastContentAt = lastContentAt; self.status = status
        self.errorCategory = errorCategory; self.updatedAt = updatedAt
    }
}

struct FormulaDerivationSegmentExpectation: Hashable, Sendable {
    let index: Int
    let startingOrdinal: Int
    let precedingTeX: String
}

enum FormulaDerivationSegmentCheckpointError: LocalizedError, Equatable, Sendable {
    case invalidIdentity
    case invalidSegmentOrder
    case invalidStepSequence
    case invalidContinuationState
    case resourceLimit
    case invalidDigest
    case invalidTelemetry

    var errorDescription: String? {
        switch self {
        case .invalidIdentity: "公式續寫 checkpoint 缺少 equation ID 或原文 TeX。"
        case .invalidSegmentOrder: "公式續寫 segment 順序重複、跳號或已完成後仍有新段。"
        case .invalidStepSequence: "公式續寫步驟的 ordinal、ID 或 TeX 邊界不連續。"
        case .invalidContinuationState: "非終段必須保留續寫摘要；終段必須提供結論。"
        case .resourceLimit: "公式推導超過每段 32 步、每式 8 段或總計 256 步的資源上限。"
        case .invalidDigest: "公式續寫 segment 缺少有效的 request/response SHA-256。"
        case .invalidTelemetry: "公式續寫 segment 的 request ID 或接收遙測資料無效。"
        }
    }
}

struct FormulaDerivationSegmentReceipt: Codable, Hashable, Sendable, Identifiable {
    let index: Int
    let steps: [FormulaDerivationStep]
    let isFinal: Bool
    let continuationSummary: String?
    let conclusionZH: String?
    let requestID: String
    let requestPayloadHash: String
    let responseHash: String
    let receivedBytes: Int
    let receivedCharacters: Int
    let firstContentAt: Date?
    let lastContentAt: Date?

    var id: Int { index }

    private enum CodingKeys: String, CodingKey {
        case index, steps, isFinal, continuationSummary, conclusionZH, requestID
        case requestPayloadHash, responseHash, receivedBytes, receivedCharacters
        case firstContentAt, lastContentAt
    }

    init(index: Int, steps: [FormulaDerivationStep], isFinal: Bool,
         continuationSummary: String?, conclusionZH: String?, requestID: String,
         requestPayloadHash: String, responseHash: String, receivedBytes: Int,
         receivedCharacters: Int, firstContentAt: Date?, lastContentAt: Date?) {
        self.index = index
        self.steps = steps
        self.isFinal = isFinal
        self.continuationSummary = continuationSummary
        self.conclusionZH = conclusionZH
        self.requestID = requestID
        self.requestPayloadHash = requestPayloadHash
        self.responseHash = responseHash
        self.receivedBytes = receivedBytes
        self.receivedCharacters = receivedCharacters
        self.firstContentAt = firstContentAt
        self.lastContentAt = lastContentAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        index = try values.decode(Int.self, forKey: .index)
        steps = try values.decode([FormulaDerivationStep].self, forKey: .steps)
        isFinal = try values.decode(Bool.self, forKey: .isFinal)
        continuationSummary = try values.decodeIfPresent(String.self, forKey: .continuationSummary)
        conclusionZH = try values.decodeIfPresent(String.self, forKey: .conclusionZH)
        // Pre-V12 checkpoints did not retain per-segment request identity or
        // receive telemetry. Preserve them for display/migration diagnosis,
        // but validatedCopy() rejects these rows for automatic resumption.
        requestID = try values.decodeIfPresent(String.self, forKey: .requestID) ?? ""
        requestPayloadHash = try values.decode(String.self, forKey: .requestPayloadHash)
        responseHash = try values.decode(String.self, forKey: .responseHash)
        receivedBytes = try values.decodeIfPresent(Int.self, forKey: .receivedBytes) ?? 0
        receivedCharacters = try values.decodeIfPresent(Int.self, forKey: .receivedCharacters) ?? 0
        firstContentAt = try values.decodeIfPresent(Date.self, forKey: .firstContentAt)
        lastContentAt = try values.decodeIfPresent(Date.self, forKey: .lastContentAt)
    }
}

/// Durable, append-only state for one equation's bounded derivation segments.
/// The full chain remains inference and is never a claim of physics validation.
struct FormulaDerivationSegmentCheckpoint: Codable, Hashable, Sendable, Identifiable {
    static let maximumSegmentsPerEquation = 8

    let equationID: String
    let sourceTeX: String
    private(set) var segments: [FormulaDerivationSegmentReceipt]

    var id: String { equationID }
    var isComplete: Bool { segments.last?.isFinal == true }
    var completedSteps: [FormulaDerivationStep] { segments.flatMap(\.steps) }
    var continuationSummary: String? { segments.last?.continuationSummary }
    var conclusionZH: String? { segments.last?.conclusionZH }

    static func provenanceHash(for receipt: FormulaDerivationSegmentReceipt) throws -> String {
        let encoder = JSONEncoder.latticeLens
        encoder.outputFormatting.insert(.sortedKeys)
        return StableHash.sha256(try encoder.encode(receipt))
    }

    func provenanceHash() throws -> String {
        struct Payload: Encodable {
            let equationID: String
            let sourceTeX: String
            let segments: [FormulaDerivationSegmentReceipt]
        }
        let encoder = JSONEncoder.latticeLens
        encoder.outputFormatting.insert(.sortedKeys)
        return StableHash.sha256(try encoder.encode(Payload(
            equationID: equationID, sourceTeX: sourceTeX, segments: segments)))
    }

    init(equationID: String, sourceTeX: String) {
        self.equationID = equationID
        self.sourceTeX = sourceTeX
        self.segments = []
    }

    mutating func appendSegment(index: Int, steps: [FormulaDerivationStep], isFinal: Bool,
                                continuationSummary: String?, conclusionZH: String?,
                                requestID: String, requestPayloadHash: String, responseHash: String,
                                receivedBytes: Int, receivedCharacters: Int,
                                firstContentAt: Date?, lastContentAt: Date?) throws {
        guard !equationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceTeX.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FormulaDerivationSegmentCheckpointError.invalidIdentity
        }
        guard !isComplete, index == segments.count else {
            throw FormulaDerivationSegmentCheckpointError.invalidSegmentOrder
        }
        guard !steps.isEmpty, steps.count <= FormulaDerivationStep.maximumStepsPerSegment,
              segments.count < Self.maximumSegmentsPerEquation,
              completedSteps.count + steps.count <= FormulaDerivationStep.maximumSteps else {
            throw FormulaDerivationSegmentCheckpointError.resourceLimit
        }
        guard Self.isSHA256(requestPayloadHash), Self.isSHA256(responseHash) else {
            throw FormulaDerivationSegmentCheckpointError.invalidDigest
        }
        guard !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              receivedBytes >= 0, receivedCharacters >= 0, receivedCharacters <= receivedBytes,
              (receivedBytes == 0) == (firstContentAt == nil && lastContentAt == nil),
              (firstContentAt == nil) == (lastContentAt == nil),
              firstContentAt.map({ first in lastContentAt.map { first <= $0 } ?? false }) ?? true else {
            throw FormulaDerivationSegmentCheckpointError.invalidTelemetry
        }
        let normalizedSummary = continuationSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConclusion = conclusionZH?.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            guard normalizedConclusion?.isEmpty == false, normalizedSummary?.isEmpty != false else {
                throw FormulaDerivationSegmentCheckpointError.invalidContinuationState
            }
        } else {
            guard normalizedSummary?.isEmpty == false, normalizedConclusion?.isEmpty != false,
                  segments.count + 1 < Self.maximumSegmentsPerEquation,
                  completedSteps.count + steps.count < FormulaDerivationStep.maximumSteps else {
                throw FormulaDerivationSegmentCheckpointError.resourceLimit
            }
        }

        var previousTeX = completedSteps.last?.afterTeX ?? sourceTeX
        let firstOrdinal = completedSteps.count + 1
        for (offset, step) in steps.enumerated() {
            let ordinal = firstOrdinal + offset
            guard step.stepID == "\(equationID):step:\(ordinal)", step.ordinal == ordinal,
                  !step.textZH.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !step.ruleOrAssumption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  step.epistemicStatus == .inference,
                  let before = step.beforeTeX?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let after = step.afterTeX?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !after.isEmpty, before == previousTeX,
                  step.structuralStatus != .rejected else {
                throw FormulaDerivationSegmentCheckpointError.invalidStepSequence
            }
            previousTeX = after
        }

        segments.append(FormulaDerivationSegmentReceipt(index: index, steps: steps, isFinal: isFinal,
            continuationSummary: isFinal ? nil : normalizedSummary,
            conclusionZH: isFinal ? normalizedConclusion : nil, requestID: requestID,
            requestPayloadHash: requestPayloadHash.lowercased(), responseHash: responseHash.lowercased(),
            receivedBytes: receivedBytes, receivedCharacters: receivedCharacters,
            firstContentAt: firstContentAt, lastContentAt: lastContentAt))
    }

    func validatedCopy() throws -> FormulaDerivationSegmentCheckpoint {
        var validated = FormulaDerivationSegmentCheckpoint(equationID: equationID, sourceTeX: sourceTeX)
        for segment in segments {
            try validated.appendSegment(index: segment.index, steps: segment.steps, isFinal: segment.isFinal,
                continuationSummary: segment.continuationSummary, conclusionZH: segment.conclusionZH,
                requestID: segment.requestID, requestPayloadHash: segment.requestPayloadHash,
                responseHash: segment.responseHash, receivedBytes: segment.receivedBytes,
                receivedCharacters: segment.receivedCharacters, firstContentAt: segment.firstContentAt,
                lastContentAt: segment.lastContentAt)
        }
        guard validated == self else { throw FormulaDerivationSegmentCheckpointError.invalidStepSequence }
        return validated
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value) || (65...70).contains($0.value)
        }
    }
}

struct FormulaDerivationJob: Codable, Hashable, Sendable, Identifiable {
    let jobID: String
    let paperID: Int
    let documentHash: String
    let inventoryHash: String
    let equationIDs: [String]
    let batchSize: Int
    var state: FormulaJobState
    var batches: [FormulaBatchCheckpoint]
    var startedAt: Date
    var updatedAt: Date
    var id: String { jobID }

    init(jobID: String = UUID().uuidString, paperID: Int, documentHash: String, inventoryHash: String,
         equationIDs: [String], batchSize: Int = 8, state: FormulaJobState = .prepared,
         batches: [FormulaBatchCheckpoint] = [], startedAt: Date = Date(), updatedAt: Date = Date()) {
        self.jobID = jobID; self.paperID = paperID; self.documentHash = documentHash; self.inventoryHash = inventoryHash
        self.equationIDs = equationIDs; self.batchSize = max(1, batchSize); self.state = state; self.batches = batches
        self.startedAt = startedAt; self.updatedAt = updatedAt
    }

    var completedEquationIDs: Set<String> {
        Set(batches.filter { $0.status == .completed }.flatMap(\.equationIDs))
    }
    var pendingEquationIDs: [String] { equationIDs.filter { !completedEquationIDs.contains($0) } }
    var isComplete: Bool { state == .complete && Set(equationIDs) == completedEquationIDs }
}

enum FormulaJobState: String, Codable, CaseIterable, Sendable {
    case prepared, inventorying, queued, running, retryable, paused, cancelled, validating, merging, complete, incomplete, failed
}

struct FormulaCoverageReport: Codable, Hashable, Sendable {
    let inventoryIDs: [String]
    let claimIDs: [String]
    let missingEquationIDs: [String]
    let extraEquationIDs: [String]
    let duplicateEquationIDs: [String]
    let invalidEquationIDs: [String]
    let derivationIncompleteEquationIDs: [String]
    let structuralNeedsManualEquationIDs: [String]
    let structuralRejectedEquationIDs: [String]
    let physicsNeedsManualEquationIDs: [String]
    let inventoryHash: String
    let claimHash: String

    var sourceCoverageComplete: Bool {
        missingEquationIDs.isEmpty && extraEquationIDs.isEmpty && duplicateEquationIDs.isEmpty &&
            invalidEquationIDs.isEmpty && inventoryIDs.count == claimIDs.count
    }
    var derivationCoverageComplete: Bool { derivationIncompleteEquationIDs.isEmpty }
    var structuralValidationPassed: Bool { structuralRejectedEquationIDs.isEmpty }
    var physicsReviewComplete: Bool { physicsNeedsManualEquationIDs.isEmpty }
    var isComplete: Bool { sourceCoverageComplete && derivationCoverageComplete && structuralValidationPassed }

    private enum CodingKeys: String, CodingKey {
        case inventoryIDs, claimIDs, missingEquationIDs, extraEquationIDs, duplicateEquationIDs
        case invalidEquationIDs, derivationIncompleteEquationIDs, structuralNeedsManualEquationIDs
        case structuralRejectedEquationIDs, physicsNeedsManualEquationIDs, inventoryHash, claimHash
    }

    init(inventoryIDs: [String], claimIDs: [String], missingEquationIDs: [String],
         extraEquationIDs: [String], duplicateEquationIDs: [String], invalidEquationIDs: [String],
         derivationIncompleteEquationIDs: [String] = [], structuralNeedsManualEquationIDs: [String] = [],
         structuralRejectedEquationIDs: [String] = [], physicsNeedsManualEquationIDs: [String] = [],
         inventoryHash: String, claimHash: String) {
        self.inventoryIDs = inventoryIDs
        self.claimIDs = claimIDs
        self.missingEquationIDs = missingEquationIDs
        self.extraEquationIDs = extraEquationIDs
        self.duplicateEquationIDs = duplicateEquationIDs
        self.invalidEquationIDs = invalidEquationIDs
        self.derivationIncompleteEquationIDs = derivationIncompleteEquationIDs
        self.structuralNeedsManualEquationIDs = structuralNeedsManualEquationIDs
        self.structuralRejectedEquationIDs = structuralRejectedEquationIDs
        self.physicsNeedsManualEquationIDs = physicsNeedsManualEquationIDs
        self.inventoryHash = inventoryHash
        self.claimHash = claimHash
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(inventoryIDs: try values.decode([String].self, forKey: .inventoryIDs),
                  claimIDs: try values.decode([String].self, forKey: .claimIDs),
                  missingEquationIDs: try values.decode([String].self, forKey: .missingEquationIDs),
                  extraEquationIDs: try values.decode([String].self, forKey: .extraEquationIDs),
                  duplicateEquationIDs: try values.decode([String].self, forKey: .duplicateEquationIDs),
                  invalidEquationIDs: try values.decode([String].self, forKey: .invalidEquationIDs),
                  derivationIncompleteEquationIDs: try values.decodeIfPresent([String].self, forKey: .derivationIncompleteEquationIDs) ?? [],
                  structuralNeedsManualEquationIDs: try values.decodeIfPresent([String].self, forKey: .structuralNeedsManualEquationIDs) ?? [],
                  structuralRejectedEquationIDs: try values.decodeIfPresent([String].self, forKey: .structuralRejectedEquationIDs) ?? [],
                  physicsNeedsManualEquationIDs: try values.decodeIfPresent([String].self, forKey: .physicsNeedsManualEquationIDs) ?? [],
                  inventoryHash: try values.decode(String.self, forKey: .inventoryHash),
                  claimHash: try values.decode(String.self, forKey: .claimHash))
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(inventoryIDs, forKey: .inventoryIDs)
        try values.encode(claimIDs, forKey: .claimIDs)
        try values.encode(missingEquationIDs, forKey: .missingEquationIDs)
        try values.encode(extraEquationIDs, forKey: .extraEquationIDs)
        try values.encode(duplicateEquationIDs, forKey: .duplicateEquationIDs)
        try values.encode(invalidEquationIDs, forKey: .invalidEquationIDs)
        // Omit additive empty fields so superseded v2 report payloads can be
        // decoded and re-encoded without changing their legacy payload hash.
        if !derivationIncompleteEquationIDs.isEmpty {
            try values.encode(derivationIncompleteEquationIDs, forKey: .derivationIncompleteEquationIDs)
        }
        if !structuralNeedsManualEquationIDs.isEmpty {
            try values.encode(structuralNeedsManualEquationIDs, forKey: .structuralNeedsManualEquationIDs)
        }
        if !structuralRejectedEquationIDs.isEmpty {
            try values.encode(structuralRejectedEquationIDs, forKey: .structuralRejectedEquationIDs)
        }
        if !physicsNeedsManualEquationIDs.isEmpty {
            try values.encode(physicsNeedsManualEquationIDs, forKey: .physicsNeedsManualEquationIDs)
        }
        try values.encode(inventoryHash, forKey: .inventoryHash)
        try values.encode(claimHash, forKey: .claimHash)
    }
}

enum FormulaDerivationChainFailure: String, Sendable {
    case missingSteps
    case missingConclusion
    case missingTransition
    case sourceMismatch
    case discontinuousTransition
    case rejectedTeXStructure
    case invalidStepText

    var displayNameZH: String {
        switch self {
        case .missingSteps: "推导步骤缺失"
        case .missingConclusion: "推导结论缺失"
        case .missingTransition: "步骤缺少起始式或结果式"
        case .sourceMismatch: "推导起始式与原文编号公式不一致"
        case .discontinuousTransition: "相邻推导步骤的中间公式不连续"
        case .rejectedTeXStructure: "推导步骤的 TeX 结构无效"
        case .invalidStepText: "推导步骤文字或规则/假设缺失"
        }
    }
}

/// Verifies only that a typed derivation is a complete, source-bound sequence.
/// It does not establish algebraic equivalence or physical correctness.
enum FormulaDerivationChainValidator {
    static func failure(for claim: EvidenceClaim, sourceTeX: String) -> FormulaDerivationChainFailure? {
        guard let conclusion = claim.conclusionZH,
              !conclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .missingConclusion
        }
        let steps = claim.formulaDerivationSteps
        guard !steps.isEmpty, steps.count <= FormulaDerivationStep.maximumSteps,
              claim.derivationSteps == steps.map(\.textZH) else {
            return .missingSteps
        }
        guard steps.allSatisfy({
            !$0.textZH.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.ruleOrAssumption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return .invalidStepText
        }
        guard let firstBefore = normalized(steps.first?.beforeTeX),
              normalized(sourceTeX) != nil,
              let finalAfter = normalized(steps.last?.afterTeX),
              !finalAfter.isEmpty,
              steps.allSatisfy({ normalized($0.beforeTeX) != nil && normalized($0.afterTeX) != nil }) else {
            return .missingTransition
        }
        guard firstBefore == normalized(sourceTeX) else { return .sourceMismatch }
        var previousAfter: String?
        for step in steps {
            guard let before = normalized(step.beforeTeX), let after = normalized(step.afterTeX) else {
                return .missingTransition
            }
            if let previousAfter, before != previousAfter { return .discontinuousTransition }
            if step.structuralStatus == .rejected { return .rejectedTeXStructure }
            previousAfter = after
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum FormulaCoverageValidationError: LocalizedError, Equatable, Sendable {
    case incomplete(FormulaCoverageReport)
    var errorDescription: String? {
        switch self {
        case .incomplete(let report):
            "编号公式验收不完整（原文缺 \(report.missingEquationIDs.count)、多 \(report.extraEquationIDs.count)、重复 \(report.duplicateEquationIDs.count)、来源无效 \(report.invalidEquationIDs.count)、推导链不完整 \(report.derivationIncompleteEquationIDs.count)、结构拒绝 \(report.structuralRejectedEquationIDs.count)）。"
        }
    }
}

enum FormulaCoverageValidator {
    static let version = "formula-coverage-v4-segment-provenance"
    static let legacyVersion = "formula-coverage-v3-derivation-chain"

    private struct ReferencedAnchor: Encodable {
        let requestedID: String
        let value: EvidenceAnchor?
    }

    private struct ClaimProofPayload: Encodable {
        let claim: EvidenceClaim
        let stepStructuralStatuses: [String]
        let stepPhysicsReviewStatuses: [String]
        let referencedAnchors: [ReferencedAnchor]
    }

    private static func proofHash(claims: [EvidenceClaim], anchors: [String: EvidenceAnchor]) -> (value: String, encoded: Bool) {
        let payloads = claims.map { claim in
            let referencedAnchorIDs = Set(
                claim.evidenceIDs + claim.formulaDerivationSteps.flatMap(\.evidenceAnchorIDs)
            ).sorted()
            return ClaimProofPayload(
                claim: claim,
                stepStructuralStatuses: claim.formulaDerivationSteps.map { $0.structuralStatus.rawValue },
                stepPhysicsReviewStatuses: claim.formulaDerivationSteps.map { $0.physicsReview.rawValue },
                referencedAnchors: referencedAnchorIDs.map { id in
                    ReferencedAnchor(requestedID: id, value: anchors[id])
                }
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            var bytes = Data("formula-claim-proof-v4|\(version)|".utf8)
            bytes.append(try encoder.encode(payloads))
            return (StableHash.sha256(bytes), true)
        } catch {
            // Encoding failure must never make a validation report look complete.
            return (StableHash.sha256("formula-claim-proof-v4|\(version)|encoding-failed"), false)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value) || (65...70).contains($0.value)
        }
    }

    static func report(inventory: FormulaInventory, claims: [EvidenceClaim], anchors: [String: EvidenceAnchor] = [:]) -> FormulaCoverageReport {
        let inventoryIDs = inventory.items.map(\.equationID)
        let claimIDs = claims.compactMap(\.equationID)
        var seen = Set<String>(); var duplicates = [String](); var invalid = [String]()
        var derivationIncomplete = Set<String>()
        var structuralNeedsManual = Set<String>()
        var structuralRejected = Set<String>()
        var physicsNeedsManual = Set<String>()
        var expected = [String: FormulaInventoryItem]()
        for item in inventory.items {
            if expected.updateValue(item, forKey: item.equationID) != nil { invalid.append(item.equationID) }
        }
        var previousOrdinal = 0
        var dependencies = [String: Set<String>]()
        for claim in claims {
            guard let id = claim.equationID, let item = expected[id] else { if let id = claim.equationID { invalid.append(id) }; continue }
            if !seen.insert(id).inserted { duplicates.append(id) }
            if item.ordinal < previousOrdinal { invalid.append(id) }
            previousOrdinal = max(previousOrdinal, item.ordinal)
            let candidate = claim.formulaTeX.map { stripDelimiters($0) }
            guard candidate == item.sourceTeX, claim.epistemicStatus == .direct else {
                invalid.append(id)
                continue
            }
            if let segmentHash = claim.derivationSegmentProvenanceHash, !isSHA256(segmentHash) {
                invalid.append(id)
                continue
            }
            for step in claim.formulaDerivationSteps {
                if step.structuralStatus == .needsManual { structuralNeedsManual.insert(id) }
                if step.structuralStatus == .rejected { structuralRejected.insert(id) }
                if step.physicsReview == .needsManualPhysics { physicsNeedsManual.insert(id) }
            }
            guard FormulaDerivationChainValidator.failure(for: claim, sourceTeX: item.sourceTeX) == nil else {
                derivationIncomplete.insert(id)
                continue
            }
            // A formula claim owns exactly one source anchor.  A missing
            // anchor is an invalid proof obligation, not an ignorable
            // optional field: silently continuing here used to make a report
            // look complete even though the TeX could not be traced back to
            // the current document.
            guard let evidenceID = item.evidenceID,
                  claim.evidenceIDs.count == 1,
                  claim.evidenceIDs.first == evidenceID,
                  let anchor = anchors[evidenceID],
                  anchor.paperID > 0,
                  anchor.quoteHash == StableHash.sha256(anchor.quote) else {
                invalid.append(id)
                continue
            }
            let expectedQuote = "编号公式 \(item.label)\n$$\(item.sourceTeX)$$"
            guard anchor.quote == expectedQuote else { invalid.append(id); continue }
            var claimDependencies = Set<String>()
            var stepsValid = true
            for (offset, step) in claim.formulaDerivationSteps.enumerated() {
                let ordinal = offset + 1
                guard step.stepID == "\(id):step:\(ordinal)", step.ordinal == ordinal,
                      step.epistemicStatus == .inference,
                      step.sourceDocumentHashes == [item.documentHash],
                      !step.evidenceAnchorIDs.isEmpty || !step.referencedEquationIDs.isEmpty,
                      Set(step.referencedEquationIDs).isSubset(of: Set(expected.keys)),
                      !step.referencedEquationIDs.contains(id),
                      (anchors.isEmpty || Set(step.evidenceAnchorIDs).isSubset(of: Set(anchors.keys))),
                      step.structuralStatus != .rejected,
                      step.physicsReview == .needsManualPhysics else {
                    stepsValid = false
                    break
                }
                claimDependencies.formUnion(step.referencedEquationIDs)
            }
            guard stepsValid else { derivationIncomplete.insert(id); continue }
            dependencies[id] = claimDependencies
        }
        if containsDependencyCycle(dependencies) { derivationIncomplete.formUnion(dependencies.keys) }
        let proof = proofHash(claims: claims, anchors: anchors)
        if !proof.encoded { invalid.append(contentsOf: claimIDs) }
        let inventorySet = Set(inventoryIDs); let claimSet = Set(claimIDs)
        return FormulaCoverageReport(inventoryIDs: inventoryIDs, claimIDs: claimIDs,
                                     missingEquationIDs: inventorySet.subtracting(claimSet).sorted(),
                                     extraEquationIDs: claimSet.subtracting(inventorySet).sorted(),
                                     duplicateEquationIDs: Array(Set(duplicates)).sorted(),
                                     invalidEquationIDs: Array(Set(invalid)).sorted(),
                                     derivationIncompleteEquationIDs: derivationIncomplete.sorted(),
                                     structuralNeedsManualEquationIDs: structuralNeedsManual.sorted(),
                                     structuralRejectedEquationIDs: structuralRejected.sorted(),
                                     physicsNeedsManualEquationIDs: physicsNeedsManual.sorted(),
                                     inventoryHash: inventory.inventoryHash,
                                     claimHash: proof.value)
    }

    static func validate(inventory: FormulaInventory, claims: [EvidenceClaim], anchors: [String: EvidenceAnchor] = [:]) throws -> FormulaCoverageReport {
        let result = report(inventory: inventory, claims: claims, anchors: anchors)
        guard inventory.isComplete, result.isComplete else { throw FormulaCoverageValidationError.incomplete(result) }
        return result
    }

    private static func stripDelimiters(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$") { return String(trimmed.dropFirst(2).dropLast(2)) }
        if trimmed.hasPrefix("$"), trimmed.hasSuffix("$") { return String(trimmed.dropFirst().dropLast()) }
        return trimmed
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
}

enum FormulaBatchPlanner {
    static let defaultBatchSize = 8
    static let defaultMaximumBatchTokens = 64_000

    static func plan(source: EvidenceInputPayload, jobID: String = UUID().uuidString,
                     batchSize: Int = defaultBatchSize, profile: ProviderProfile,
                     systemInstruction: String = FormulaDerivationPrompt.systemInstruction,
                     maximumPayloadBytes: Int = EvidenceInputPayload.maximumPayloadBytes,
                     maximumPayloadScalars: Int = EvidenceInputPayload.maximumPayloadScalars,
                     maximumPayloadTokens: Int = defaultMaximumBatchTokens) throws -> [NumberedEquationBatch] {
        guard source.numberedEquationCoverageComplete else { throw LatticeLensError.schemaViolation(source.numberedEquationCoverageFailure ?? "编号公式 inventory 不完整") }
        let size = max(1, batchSize)
        let byteLimit = max(1, maximumPayloadBytes)
        let scalarLimit = max(1, maximumPayloadScalars)
        let tokenLimit = max(1, maximumPayloadTokens)
        let equations = source.numberedEquations
        guard !equations.isEmpty else { return [] }

        // Use the actual provider JSON body for byte/scalar measurements and
        // its SHA-256. UTF-8 bytes are a conservative token upper bound for
        // the configured request budget; no model-specific tokenizer is
        // assumed. The equation count is an upper bound for batchTotal while
        // packing, so the final exact body can only be the same size or
        // smaller when the true batch count is known.
        var groups = [[NumberedEquationInput]]()
        var current = [NumberedEquationInput]()
        for equation in equations {
            if current.count >= size {
                groups.append(current)
                current = []
            }

            let candidate = current + [equation]
            if let metrics = try requestMetrics(source: source, equations: candidate,
                                                index: groups.count, total: equations.count,
                                                profile: profile, systemInstruction: systemInstruction),
               fits(metrics, byteLimit: byteLimit, scalarLimit: scalarLimit, tokenLimit: tokenLimit) {
                current = candidate
                continue
            }

            guard !current.isEmpty else {
                throw LatticeLensError.schemaViolation("单条编号公式的实际序列化请求超过本地 byte/scalar/token 上限；不会发送未界定的请求。")
            }
            groups.append(current)
            current = []
            guard let singleMetrics = try requestMetrics(source: source, equations: [equation],
                                                          index: groups.count, total: equations.count,
                                                          profile: profile, systemInstruction: systemInstruction),
                  fits(singleMetrics, byteLimit: byteLimit, scalarLimit: scalarLimit, tokenLimit: tokenLimit) else {
                throw LatticeLensError.schemaViolation("单条编号公式的实际序列化请求超过本地 byte/scalar/token 上限；不会发送未界定的请求。")
            }
            current = [equation]
        }
        if !current.isEmpty { groups.append(current) }

        return try groups.enumerated().map { index, group in
            guard let metrics = try requestMetrics(source: source, equations: group,
                                                   index: index, total: groups.count,
                                                   profile: profile, systemInstruction: systemInstruction),
                  fits(metrics, byteLimit: byteLimit, scalarLimit: scalarLimit, tokenLimit: tokenLimit) else {
                throw LatticeLensError.schemaViolation("最終 batchTotal 下的实际序列化公式请求超过本地上限。")
            }
            return NumberedEquationBatch(jobID: jobID, index: index, total: groups.count,
                                         equationIDs: group.map(\.equationID), payloadHash: metrics.sha256,
                                         estimatedBytes: metrics.bytes, estimatedScalars: metrics.scalars,
                                         estimatedTokens: metrics.tokenEstimate)
        }
    }

    static func batches(for equations: [NumberedEquationInput], batchSize: Int = defaultBatchSize, jobID: String = UUID().uuidString) -> [NumberedEquationBatch] {
        let groups = stride(from: 0, to: equations.count, by: max(1, batchSize)).map { Array(equations[$0..<min(equations.count, $0 + max(1, batchSize))]) }
        return groups.enumerated().map { index, group in
            let sourceProjection = group.map { "\($0.equationID)|\($0.tex)" }.joined(separator: "\n")
            return NumberedEquationBatch(jobID: jobID, index: index, total: groups.count,
                                         equationIDs: group.map(\.equationID),
                                         payloadHash: StableHash.sha256(sourceProjection),
                                         estimatedBytes: sourceProjection.utf8.count,
                                         estimatedScalars: sourceProjection.unicodeScalars.count,
                                         estimatedTokens: sourceProjection.utf8.count)
        }
    }

    private struct RequestMetrics {
        let sha256: String
        let bytes: Int
        let scalars: Int
        let tokenEstimate: Int
    }

    private static func requestMetrics(source: EvidenceInputPayload, equations: [NumberedEquationInput],
                                       index: Int, total: Int, profile: ProviderProfile,
                                       systemInstruction: String) throws -> RequestMetrics? {
        let batchSource = try source.batch(for: equations.map(\.equationID), index: index, total: total)
        let userPayload: String
        do {
            userPayload = try FormulaDerivationPrompt.userPayload(source: batchSource)
        } catch let LatticeLensError.schemaViolation(message) where message.contains("payload 上限") {
            return nil
        }
        let body = try OpenAICompatibleCompletionRequestBody(
            system: systemInstruction, userPayload: userPayload, profile: profile
        ).encoded()
        guard let serialized = String(data: body, encoding: .utf8) else {
            throw LatticeLensError.malformedPayload
        }
        return RequestMetrics(sha256: StableHash.sha256(body), bytes: body.count,
                              scalars: serialized.unicodeScalars.count,
                              tokenEstimate: body.count)
    }

    private static func fits(_ metrics: RequestMetrics, byteLimit: Int,
                             scalarLimit: Int, tokenLimit: Int) -> Bool {
        metrics.bytes <= byteLimit && metrics.scalars <= scalarLimit && metrics.tokenEstimate <= tokenLimit
    }
}
