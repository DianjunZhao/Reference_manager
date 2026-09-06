import AppKit
import SwiftUI
import WebKit

/// Presentation only: cached evidence, original TeX and epistemic status are
/// never rewritten. All model text is escaped; only bundled scripts execute.
enum FormulaReaderDocument {
    static let origin = "latticelens-math://bundle"

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func math(_ tex: String, display: Bool) -> String {
        let tag = display ? "div" : "span"
        return "<\(tag) class=\"math-\(display ? "display" : "inline")\" data-tex=\"\(escape(tex))\" data-display=\"\(display)\">\(escape(tex))</\(tag)>"
    }

    static func prose(_ text: String) -> String {
        LocalMarkdownTeX.segments(in: text).map { segment in
            switch segment {
            case .inlineTeX(let tex): return math(tex, display: false)
            case .displayTeX(let tex): return math(tex, display: true)
            case .markdown(let value): return styledText(value)
            }
        }.joined()
    }

    private static func styledText(_ text: String) -> String {
        // Parse emphasis before splitting bare TeX runs: splitting at Chinese
        // characters first would strand the two halves of **中文强调**.
        guard let regex = try? NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*|`([^`\n]+)`"#) else {
            return bareMathAndText(text)
        }
        var result = "", cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += bareMathAndText(String(text[cursor..<range.lowerBound]))
            if let bold = Range(match.range(at: 1), in: text) {
                result += "<strong>" + bareMathAndText(String(text[bold])) + "</strong>"
            } else if let code = Range(match.range(at: 2), in: text) {
                result += "<code>" + escape(String(text[code])) + "</code>"
            }
            cursor = range.upperBound
        }
        return result + bareMathAndText(String(text[cursor...]))
    }

    /// Conservative delimiter recovery for plain TeX runs in Chinese prose.
    /// Require a TeX command, a sub/superscript, or a single-symbol equation;
    /// never turn ordinary English, URLs, HTML, or currency into mathematics.
    /// Ambiguous runs remain readable text, not a guessed physics expression.
    private static func bareMathAndText(_ text: String) -> String {
        let pattern = #"[A-Za-z0-9\\{}\[\]()_^=+*/|&.,' :;!\-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return escape(text) }
        var result = "", cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += plainText(String(text[cursor..<range.lowerBound]))
            let original = String(text[range])
            let trimmed = original.trimmingCharacters(in: .whitespaces)
            // Mask command names/text arguments before detecting prose words.
            let noCommands = trimmed
                .replacingOccurrences(of: #"\\(?:text|mathrm|operatorname)\{[^{}]*\}"#, with: "x", options: .regularExpression)
                .replacingOccurrences(of: #"\\[A-Za-z]+"#, with: "x", options: .regularExpression)
            let hasWords = noCommands.range(of: #"[A-Za-z]{3,}"#, options: .regularExpression) != nil
            let isMath = trimmed.range(of: #"\\[A-Za-z]+|[_^]\{?[^ ]|^[A-Za-z](?:\([^)]*\))?\s*="#, options: .regularExpression) != nil
            if isMath && !hasWords && !trimmed.contains("://") && !trimmed.contains(";") {
                let leading = String(original.prefix(while: { $0.isWhitespace }))
                let trailing = String(original.reversed().prefix(while: { $0.isWhitespace }).reversed())
                result += escape(leading) + math(trimmed, display: false) + escape(trailing)
            } else {
                result += plainText(original)
            }
            cursor = range.upperBound
        }
        result += plainText(String(text[cursor...]))
        return result
    }

    private static func plainText(_ text: String) -> String {
        // Never interpret imported HTML or remote Markdown images.
        escape(text)
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    static func html(claims: [EvidenceClaim], anchors: [String: EvidenceAnchor]) -> String {
        let cards = claims.enumerated().map { index, claim in
            let formula = claim.formulaTeX.map {
                "<section><h3>公式 · \(escape(claim.epistemicStatus.displayNameZH))</h3>" +
                math(LocalMarkdownTeX.formulaRawSource($0), display: true) + "</section>"
            } ?? ""
            let steps = claim.derivationSteps.isEmpty ? "" :
                "<section><h3>逐步推导 <small>LLM 推断，需独立核对</small></h3><ol>" +
                claim.derivationSteps.map { "<li><div>\(prose($0))</div></li>" }.joined() + "</ol></section>"
            let conclusion = claim.conclusionZH.map { "<section class=\"conclusion\"><h3>结论</h3>\(prose($0))</section>" } ?? ""
            let sources = claim.evidenceIDs.map { id in
                guard let anchor = anchors[id] else { return "<li>回查锚点缺失：\(escape(id))</li>" }
                let location = anchor.page.map { "第 \($0) 页" } ?? (anchor.sourceKind == .pdf ? "HTML 全文片段" : "元数据")
                let section = anchor.section.map { " · " + $0 } ?? ""
                return "<li>\(escape(location + section)) <code>\(escape(id))</code></li>"
            }.joined()
            let raw = ([claim.textZH] + [claim.formulaTeX].compactMap { $0 } + claim.derivationSteps + [claim.conclusionZH].compactMap { $0 }).joined(separator: "\n\n")
            return """
            <article aria-label="公式 \(index + 1)">
            <header><h2>公式 \(index + 1)</h2><span class="status">\(escape(claim.epistemicStatus.displayNameZH))</span></header>
            <div class="description">\(prose(claim.textZH))</div>
            \(formula)\(steps)\(conclusion)
            <footer><h3>来源回查</h3>\(sources.isEmpty ? "无全文锚点；不能作为原文直接支持的公式结论。" : "<ul>\(sources)</ul>")</footer>
            <details><summary>原始文本与 LaTeX（可选择复制）</summary><pre>\(escape(raw))</pre></details>
            </article>
            """
        }.joined()
        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src \(origin); style-src \(origin) 'unsafe-inline'; font-src \(origin); connect-src 'none'; img-src 'none'; base-uri 'none'; form-action 'none'">
        <link rel="stylesheet" href="\(origin)/katex.min.css"><link rel="stylesheet" href="\(origin)/reader.css">
        <script defer src="\(origin)/katex.min.js"></script><script defer src="\(origin)/reader.js"></script>
        <title>重要公式推导</title></head><body tabindex="0"><main>
        \(cards.isEmpty ? "<p>未找到可回查的论文重要公式。</p>" : cards)
        <p class="end-marker">— 推导结束 —</p></main></body></html>
        """
    }
}

@MainActor
final class FormulaReaderAssets: NSObject, WKURLSchemeHandler {
    var document = ""

    static var root: URL? {
        #if SWIFT_PACKAGE
        Bundle.module.url(forResource: "FormulaReader", withExtension: nil)
        #else
        Bundle.main.url(forResource: "FormulaReader", withExtension: nil)
        #endif
    }

    static func assetURL(for url: URL) -> URL? {
        guard url.scheme == "latticelens-math", url.host == "bundle", url.query == nil,
              url.fragment == nil, url.user == nil, url.password == nil, url.port == nil else { return nil }
        let path = url.path
        let known = ["/katex.min.js", "/reader.js", "/katex.min.css", "/reader.css"]
        let isFont = path.range(of: #"^/fonts/KaTeX_[A-Za-z0-9_-]+\.woff2$"#, options: .regularExpression) != nil
        guard known.contains(path) || isFont else { return nil }
        return root?.appendingPathComponent(String(path.dropFirst()))
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let data: Data
        let mime: String
        if url.absoluteString == FormulaReaderDocument.origin + "/document" {
            data = Data(document.utf8); mime = "text/html"
        } else if let file = Self.assetURL(for: url), let bytes = try? Data(contentsOf: file) {
            data = bytes
            mime = switch file.pathExtension { case "js": "text/javascript"; case "css": "text/css"; default: "font/woff2" }
        } else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable)); return
        }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

/// One WebKit document per derivation collection, with a permanent AppKit
/// scrollbar independent of the user's auto-hiding system preference.
@MainActor
final class FormulaReaderHost: NSView, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    let scroller = NSScroller()
    private let assets = FormulaReaderAssets()
    private var currentHTML = ""
    private var maximum = 0.0
    private var viewport = 1.0

    override init(frame: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(assets, forURLScheme: "latticelens-math")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        configuration.userContentController.add(self, name: "readerScroll")
        webView.navigationDelegate = self
        scroller.scrollerStyle = .legacy
        scroller.target = self
        scroller.action = #selector(scrollChanged(_:))
        scroller.setAccessibilityLabel("公式推导垂直滚动条")
        scroller.setAccessibilityIdentifier("formulaDerivationScroller")
        addSubview(webView); addSubview(scroller)
        webView.translatesAutoresizingMaskIntoConstraints = false
        scroller.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor), webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor), webView.trailingAnchor.constraint(equalTo: scroller.leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: trailingAnchor), scroller.topAnchor.constraint(equalTo: topAnchor),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroller.widthAnchor.constraint(equalToConstant: NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
        ])
    }

    required init?(coder: NSCoder) { nil }

    func load(_ html: String) {
        guard currentHTML != html else { return } // Progress ticks do not reset reading position.
        currentHTML = html
        assets.document = html
        webView.load(URLRequest(url: URL(string: FormulaReaderDocument.origin + "/document")!))
    }

    func tearDown() {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "readerScroll")
        webView.navigationDelegate = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? [String: Double],
              let total = value["total"], let height = value["height"], let top = value["top"],
              total.isFinite, height.isFinite, top.isFinite, height > 0, total >= height else { return }
        maximum = max(0, total - height); viewport = height
        scroller.knobProportion = min(1, height / total)
        scroller.doubleValue = maximum > 0 ? min(1, max(0, top / maximum)) : 0
        scroller.isEnabled = maximum > 0
    }

    @objc private func scrollChanged(_ sender: NSScroller) {
        var top = sender.doubleValue * maximum
        switch sender.hitPart {
        case .decrementLine: top -= 40
        case .incrementLine: top += 40
        case .decrementPage: top -= viewport * 0.9
        case .incrementPage: top += viewport * 0.9
        default: break
        }
        webView.evaluateJavaScript("window.scrollTo(0, \(min(maximum, max(0, top))))", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.absoluteString == FormulaReaderDocument.origin + "/document" ? .allow : .cancel)
    }
}

struct FormulaReader: NSViewRepresentable {
    let claims: [EvidenceClaim]
    let anchors: [String: EvidenceAnchor]
    func makeNSView(context: Context) -> FormulaReaderHost { FormulaReaderHost(frame: .zero) }
    func updateNSView(_ nsView: FormulaReaderHost, context: Context) {
        nsView.load(FormulaReaderDocument.html(claims: claims, anchors: anchors))
    }
    static func dismantleNSView(_ nsView: FormulaReaderHost, coordinator: ()) { nsView.tearDown() }
}
