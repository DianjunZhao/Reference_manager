import SwiftUI

/// A process-local renderer for untrusted Markdown and TeX fragments.  It
/// never instantiates a web view, loads a script, or interprets HTML.  The
/// native TeX preview deliberately supports a bounded readable subset and
/// leaves unsupported commands visible; the exact raw source is always
/// selectable through a local disclosure control.
enum LocalMarkdownTeX {
    enum Segment: Equatable {
        case markdown(String)
        case inlineTeX(String)
        case displayTeX(String)
    }

    static func segments(in source: String) -> [Segment] {
        let source = normalizedMathMarkup(source)
        guard !source.isEmpty else { return [.markdown("")] }
        var output: [Segment] = []
        var markdownStart = source.startIndex
        var cursor = source.startIndex

        func appendMarkdown(until end: String.Index) {
            guard markdownStart < end else { return }
            output.append(.markdown(String(source[markdownStart..<end])))
        }

        while cursor < source.endIndex {
            guard source[cursor] == "$", !isEscaped(source, at: cursor) else {
                cursor = source.index(after: cursor)
                continue
            }
            let afterFirstDollar = source.index(after: cursor)
            let display = afterFirstDollar < source.endIndex && source[afterFirstDollar] == "$"
            let contentStart = display ? source.index(after: afterFirstDollar) : afterFirstDollar
            guard let closing = closingDollar(in: source, from: contentStart, display: display) else {
                cursor = afterFirstDollar
                continue
            }
            let raw = String(source[contentStart..<closing])
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                cursor = source.index(after: closing)
                continue
            }
            appendMarkdown(until: cursor)
            output.append(display ? .displayTeX(raw) : .inlineTeX(raw))
            cursor = display ? source.index(after: source.index(after: closing)) : source.index(after: closing)
            markdownStart = cursor
        }
        appendMarkdown(until: source.endIndex)
        return output.isEmpty ? [.markdown(source)] : output
    }

    /// LLM providers and imported metadata occasionally serialize TeX as an
    /// XML-like marker (`<math display="inline">…</math>`).  That marker is
    /// transport syntax, not reader-facing content; normalize it before the
    /// native renderer sees the string.  We also accept standard TeX
    /// delimiters so formulas in titles, captions, evidence and notes share
    /// one rendering path.
    private static func normalizedMathMarkup(_ source: String) -> String {
        var value = source
        let patterns: [(String, Bool)] = [
            (#"(?is)<math\s+display\s*=\s*['\"]inline['\"]\s*>(.*?)</math>"#, false),
            (#"(?is)<math\s+display\s*=\s*['\"]block['\"]\s*>(.*?)</math>"#, true),
            (#"(?is)<math\s*>(.*?)</math>"#, false),
            (#"(?is)<tex\s*>(.*?)</tex>"#, false)
        ]
        for (pattern, display) in patterns {
            value = replaceMathTags(in: value, pattern: pattern, display: display)
        }
        value = replaceMathTags(in: value, pattern: #"(?s)\\\((.*?)\\\)"#, display: false)
        value = replaceMathTags(in: value, pattern: #"(?s)\\\[(.*?)\\\]"#, display: true)
        return value
    }

    /// `String.replacingOccurrences` treats every `$` in a regex replacement
    /// as a capture reference. Build the replacement from match ranges so the
    /// literal TeX delimiters remain exactly one/two dollar signs.
    private static func replaceMathTags(in source: String, pattern: String, display: Bool) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let fullRange = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, range: fullRange)
        guard !matches.isEmpty else { return source }
        var output = ""
        var cursor = source.startIndex
        for match in matches {
            guard let whole = Range(match.range, in: source),
                  let capture = Range(match.range(at: 1), in: source) else { continue }
            output += source[cursor..<whole.lowerBound]
            let body = normalizedMathBody(String(source[capture]))
            output += display ? "$$\(body)$$" : "$\(body)$"
            cursor = whole.upperBound
        }
        output += source[cursor..<source.endIndex]
        return output
    }

    /// INSPIRE sometimes embeds MathML elements inside its `<math>` wrapper
    /// (`<mi>`, `<mrow>`, `<mn>`, ...).  Those XML tags are transport
    /// structure, not reader-facing text.  Strip only the bounded MathML
    /// element names here while preserving the mathematical characters and
    /// entities, so a title never renders the literal `<mi>…</mi>` markup.
    private static func normalizedMathBody(_ body: String) -> String {
        var value = body.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&nbsp;", " "), ("&#x2212;", "−"), ("&#x03B1;", "α"),
            ("&#x03B2;", "β"), ("&#x03B3;", "γ"), ("&#x03B4;", "δ")
        ]
        for (entity, replacement) in entities { value = value.replacingOccurrences(of: entity, with: replacement) }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func nativeTeXPreview(_ raw: String) -> String {
        var value = normalizedMathBody(raw)
        let replacements = [
            "\\alpha": "α", "\\beta": "β", "\\gamma": "γ", "\\delta": "δ",
            "\\epsilon": "ε", "\\kappa": "κ", "\\lambda": "λ", "\\mu": "μ",
            "\\nu": "ν", "\\pi": "π", "\\rho": "ρ", "\\sigma": "σ",
            "\\tau": "τ", "\\phi": "φ", "\\chi": "χ", "\\omega": "ω",
            "\\Gamma": "Γ", "\\Delta": "Δ", "\\Lambda": "Λ", "\\Pi": "Π",
            "\\Sigma": "Σ", "\\Phi": "Φ", "\\Omega": "Ω", "\\times": "×",
            "\\cdot": "·", "\\pm": "±", "\\leq": "≤", "\\geq": "≥",
            "\\rightarrow": "→", "\\leftarrow": "←", "\\infty": "∞", "\\partial": "∂",
            "\\sum": "∑", "\\prod": "∏", "\\int": "∫", "\\nabla": "∇"
        ]
        for (source, replacement) in replacements { value = value.replacingOccurrences(of: source, with: replacement) }
        value = value.replacingOccurrences(of: "\\left", with: "")
        value = value.replacingOccurrences(of: "\\right", with: "")
        value = value.replacingOccurrences(of: "\\,", with: " ")
        value = value.replacingOccurrences(of: "\\!", with: "")
        value = value.replacingOccurrences(of: "\\quad", with: "  ")
        value = replaceBracedCommand(in: value, command: "frac") { arguments in
            guard arguments.count == 2 else { return arguments.joined() }
            let numerator = arguments[0], denominator = arguments[1]
            let n = nativeTeXPreview(numerator)
            let d = nativeTeXPreview(denominator)
            // Unicode fraction slash is rendered by the system math-capable
            // font and remains selectable/searchable; unlike the old
            // `(a)/(b)` fallback it conveys a genuine numerator/denominator.
            let left = n.count == 1 ? n : "⟮\(n)⟯"
            let right = d.count == 1 ? d : "⟮\(d)⟯"
            return "\(left)⁄\(right)"
        }
        value = replaceBracedCommand(in: value, command: "sqrt") { arguments in
            guard let radicand = arguments.first else { return "√" }
            return "√\(radicand.count == 1 ? radicand : "(\(radicand))")"
        }
        for command in ["mathrm", "text", "operatorname", "mathbf", "mathit"] {
            value = replaceBracedCommand(in: value, command: command) { $0.first ?? "" }
        }
        value = replaceScripts(in: value)
        value = value.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return value
    }

    /// Replace a TeX command whose arguments are brace-delimited.  A small
    /// scanner is used instead of a regular expression so nested fractions and
    /// radicals are handled deterministically without a web/math engine.
    private static func replaceBracedCommand(in source: String, command: String,
                                             transform: ([String]) -> String) -> String {
        let needle = "\\\(command)"
        var result = "", cursor = source.startIndex
        while let range = source.range(of: needle, range: cursor..<source.endIndex) {
            result += source[cursor..<range.lowerBound]
            var scan = range.upperBound
            var arguments: [String] = []
            while arguments.count < (command == "frac" ? 2 : 1) {
                while scan < source.endIndex, source[scan].isWhitespace { scan = source.index(after: scan) }
                guard scan < source.endIndex, source[scan] == "{",
                      let parsed = balancedGroup(in: source, opening: scan) else {
                    arguments.removeAll(); break
                }
                arguments.append(parsed.body)
                scan = parsed.end
            }
            guard !arguments.isEmpty else {
                result += source[range.lowerBound..<range.upperBound]
                cursor = range.upperBound
                continue
            }
            result += transform(arguments)
            cursor = scan
        }
        result += source[cursor..<source.endIndex]
        return result
    }

    private static func balancedGroup(in source: String, opening: String.Index) -> (body: String, end: String.Index)? {
        guard source[opening] == "{" else { return nil }
        var depth = 0, cursor = opening
        while cursor < source.endIndex {
            if source[cursor] == "{" { depth += 1 }
            if source[cursor] == "}" {
                depth -= 1
                if depth == 0 {
                    let bodyStart = source.index(after: opening)
                    return (String(source[bodyStart..<cursor]), source.index(after: cursor))
                }
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func replaceScripts(in source: String) -> String {
        var output = "", cursor = source.startIndex
        while cursor < source.endIndex {
            guard source[cursor] == "^" || source[cursor] == "_" else {
                output.append(source[cursor]); cursor = source.index(after: cursor); continue
            }
            let marker = source[cursor]
            var scan = source.index(after: cursor)
            let script: String
            if scan < source.endIndex, source[scan] == "{", let group = balancedGroup(in: source, opening: scan) {
                script = group.body; scan = group.end
            } else if scan < source.endIndex {
                script = String(source[scan]); scan = source.index(after: scan)
            } else { output.append(marker); break }
            let mapped = script.map { marker == "^" ? superscript[$0] ?? $0 : subscriptMap[$0] ?? $0 }
            output += String(mapped)
            cursor = scan
        }
        return output
    }

    private static let superscript: [Character: Character] = ["0":"⁰", "1":"¹", "2":"²", "3":"³", "4":"⁴", "5":"⁵", "6":"⁶", "7":"⁷", "8":"⁸", "9":"⁹", "+":"⁺", "-":"⁻", "=":"⁼", "(":"⁽", ")":"⁾", "n":"ⁿ", "i":"ⁱ"]
    private static let subscriptMap: [Character: Character] = ["0":"₀", "1":"₁", "2":"₂", "3":"₃", "4":"₄", "5":"₅", "6":"₆", "7":"₇", "8":"₈", "9":"₉", "+":"₊", "-":"₋", "=":"₌", "(":"₍", ")":"₎", "a":"ₐ", "e":"ₑ", "h":"ₕ", "i":"ᵢ", "j":"ⱼ", "k":"ₖ", "l":"ₗ", "m":"ₘ", "n":"ₙ", "o":"ₒ", "p":"ₚ", "r":"ᵣ", "s":"ₛ", "t":"ₜ", "u":"ᵤ", "v":"ᵥ", "x":"ₓ"]

    private static func closingDollar(in source: String, from start: String.Index, display: Bool) -> String.Index? {
        var cursor = start
        while cursor < source.endIndex {
            if source[cursor] == "$", !isEscaped(source, at: cursor) {
                let after = source.index(after: cursor)
                if display {
                    if after < source.endIndex, source[after] == "$" { return cursor }
                } else {
                    return cursor
                }
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func isEscaped(_ source: String, at index: String.Index) -> Bool {
        var cursor = index
        var count = 0
        while cursor > source.startIndex {
            let before = source.index(before: cursor)
            guard source[before] == "\\" else { break }
            count += 1
            cursor = before
        }
        return count.isMultiple(of: 2) == false
    }
}

/// Compact inline variant used by list rows and headers.  It shares the same
/// normalization as the full reader but composes into one wrapping `Text`, so
/// a long INSPIRE title remains a normal two-line row instead of a vertical
/// stack of formula disclosures.
struct LocalMarkdownTeXInlineText: View {
    let source: String

    private var composed: Text {
        LocalMarkdownTeX.segments(in: source).reduce(Text("")) { partial, segment in
            switch segment {
            case .markdown(let value):
                return partial + Text(value)
            case .inlineTeX(let raw), .displayTeX(let raw):
                return partial + Text(LocalMarkdownTeX.nativeTeXPreview(raw)).font(.body)
            }
        }
    }

    var body: some View { composed.textSelection(.enabled) }
}

struct LocalMarkdownTeXText: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(LocalMarkdownTeX.segments(in: source).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .markdown(let markdown):
                    if let parsed = try? AttributedString(markdown: markdown) {
                        Text(parsed).textSelection(.enabled)
                    } else {
                        Text(markdown).textSelection(.enabled)
                    }
                case .inlineTeX(let raw):
                    TeXPreview(raw: raw, display: false)
                case .displayTeX(let raw):
                    TeXPreview(raw: raw, display: true)
                }
            }
        }
        .accessibilityIdentifier("localMarkdownTeXRenderer")
    }
}

private struct TeXPreview: View {
    let raw: String
    let display: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(LocalMarkdownTeX.nativeTeXPreview(raw))
                .font(display ? .title3 : .body)
                .fontDesign(.serif)
                .textSelection(.enabled)
        }
        .padding(display ? 10 : 0)
        .background(display ? Color.secondary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        DisclosureGroup("原始 LaTeX（可选择并复制）") {
            Text(raw).font(.caption.monospaced()).textSelection(.enabled)
        }
        .accessibilityIdentifier("rawLaTeX")
    }
}
