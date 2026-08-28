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

    static func nativeTeXPreview(_ raw: String) -> String {
        var value = raw
        let replacements = [
            "\\alpha": "α", "\\beta": "β", "\\gamma": "γ", "\\delta": "δ",
            "\\epsilon": "ε", "\\kappa": "κ", "\\lambda": "λ", "\\mu": "μ",
            "\\nu": "ν", "\\pi": "π", "\\rho": "ρ", "\\sigma": "σ",
            "\\tau": "τ", "\\phi": "φ", "\\chi": "χ", "\\omega": "ω",
            "\\Gamma": "Γ", "\\Delta": "Δ", "\\Lambda": "Λ", "\\Pi": "Π",
            "\\Sigma": "Σ", "\\Phi": "Φ", "\\Omega": "Ω", "\\times": "×",
            "\\cdot": "·", "\\pm": "±", "\\leq": "≤", "\\geq": "≥",
            "\\rightarrow": "→", "\\leftarrow": "←", "\\infty": "∞", "\\partial": "∂"
        ]
        for (source, replacement) in replacements { value = value.replacingOccurrences(of: source, with: replacement) }
        value = value.replacingOccurrences(of: "\\left", with: "")
        value = value.replacingOccurrences(of: "\\right", with: "")
        value = value.replacingOccurrences(of: "\\,", with: " ")
        value = value.replacingOccurrences(of: "\\!", with: "")
        value = value.replacingOccurrences(of: "\\quad", with: "  ")
        value = value.replacingOccurrences(of: #"\\(?:mathrm|text|operatorname)\{([^{}]*)\}"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\\frac\{([^{}]*)\}\{([^{}]*)\}"#, with: "($1)/($2)", options: .regularExpression)
        return value
    }

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
                .font(display ? .title3.monospaced() : .body.monospaced())
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
