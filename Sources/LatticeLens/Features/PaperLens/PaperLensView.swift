import SwiftUI
import PDFKit
import UniformTypeIdentifiers

private struct MarkdownNoteDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private enum PaperLensTab: String, CaseIterable, Identifiable {
    case overview, physics, figures, evidence, source
    var id: String { rawValue }
    var title: String {
        switch self { case .overview: "概览"; case .physics: "物理解释"; case .figures: "重要图像"; case .evidence: "证据"; case .source: "原始资料" }
    }
}

/// Exact local PDFKit selection used for a user-created annotation.  The
/// locator only emits it when the selected quote occurs exactly once on one
/// page, so a later document update has a stable, auditable relocation key.
struct PDFTextSelectionAnchor: Equatable, Sendable {
    let page: Int
    let characterRangeStart: Int
    let characterRangeEnd: Int
    let quote: String
    let quoteHash: String
}

enum PDFTextSelectionLocator {
    static let maximumScalars = 20_000

    static func locate(pageText: String, quote: String, page: Int) -> PDFTextSelectionAnchor? {
        let selected = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard page > 0, !selected.isEmpty, selected.unicodeScalars.count <= maximumScalars else { return nil }
        let text = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: selected, range: searchStart..<text.endIndex) {
            ranges.append(range)
            guard ranges.count == 1 else { return nil }
            searchStart = range.upperBound
        }
        guard let range = ranges.only else { return nil }
        return PDFTextSelectionAnchor(page: page,
                                      characterRangeStart: text.distance(from: text.startIndex, to: range.lowerBound),
                                      characterRangeEnd: text.distance(from: text.startIndex, to: range.upperBound),
                                      quote: selected, quoteHash: StableHash.sha256(selected))
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

struct PaperLensView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var tab: PaperLensTab = AppLaunchConfiguration.fixtureInitialPaperLensTab
        .flatMap(PaperLensTab.init(rawValue:)) ?? .overview

    var body: some View {
        Group {
            if let paper = viewModel.selectedPaper {
                VStack(alignment: .leading, spacing: 0) {
                    PaperHeader(paper: paper, viewModel: viewModel)
                    Divider()
                    Picker("Paper Lens 标签", selection: $tab) {
                        ForEach(PaperLensTab.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("paperLensTabs")
                    .padding()
                    Divider()
                    Group {
                        switch tab {
                        case .overview: OverviewTab(paper: paper, artifact: viewModel.insightArtifact)
                        case .physics: PhysicsTab(paper: paper, viewModel: viewModel, artifact: viewModel.insightArtifact, evidenceArtifact: viewModel.evidenceInsightArtifact)
                        case .figures: FiguresTab(paper: paper, artifact: viewModel.insightArtifact, viewModel: viewModel)
                        case .evidence: EvidenceTab(paper: paper, viewModel: viewModel)
                        case .source: SourceTab(paper: paper, viewModel: viewModel)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    InsightStatusBar(viewModel: viewModel)
                }
            } else {
                ContentUnavailableView("选择一篇论文", systemImage: "doc.text.magnifyingglass", description: Text("原始 metadata 会先从本地渲染；LLM 分析是独立的后续状态。"))
            }
        }
        .navigationTitle("AI 论文镜头")
        .onChange(of: viewModel.evidenceJumpAnchor?.id) { _, anchorID in
            // Cross-surface evidence navigation is an instruction to enter
            // the Evidence tab; otherwise a correctly queued anchor could
            // remain behind the reader's previously selected tab.
            if anchorID != nil { tab = .evidence }
        }
    }
}

private struct PaperHeader: View {
    let paper: Paper
    @ObservedObject var viewModel: AppViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            LocalMarkdownTeXInlineText(source: paper.displayTitle).font(.title3)
            if let arxiv = paper.arxivID { Text("arXiv:\(arxiv)") }
            HStack(spacing: 8) {
                if let category = paper.arxivCategories.first { Text(category) }
                if let publicationYear = paper.publicationYear { Text("发表 \(publicationYear)") }
                if let citations = paper.citationCount { Text("引用 \(citations)") }
                if let updated = paper.updated { Text("更新 \(updated.formatted(date: .abbreviated, time: .shortened))") }
            }
            .font(.caption).foregroundStyle(.secondary)
            Button { viewModel.toggleReadSelectedPaper() } label: {
                Label(paper.isRead ? "标为未读" : "标为已读", systemImage: paper.isRead ? "envelope.badge" : "checkmark.circle")
            }
            .accessibilityIdentifier("toggleRead")
            .accessibilityValue(paper.isRead ? "read" : "unread")
        }
        .padding()
    }
}

private struct OverviewTab: View {
    let paper: Paper
    let artifact: InsightArtifact?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                EvidenceBadge()
                if let artifact {
                    GroupBox("中文标题") { LocalMarkdownTeXText(source: artifact.insight.titleZH).frame(maxWidth: .infinity, alignment: .leading) }
                    GroupBox("中文摘要") { LocalMarkdownTeXText(source: artifact.insight.abstractZH).frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    ContentUnavailableView("尚未生成分析", systemImage: "sparkles", description: Text("原始资料仍可在“原始资料”标签浏览。"))
                }
                if let abstract = paper.preferredAbstract {
                    DisclosureGroup("原始摘要") { LocalMarkdownTeXText(source: abstract).padding(.top, 4) }
                } else {
                    Label("无摘要，无法生成可靠物理解释。", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .padding()
        }
    }
}

private struct PhysicsTab: View {
    let paper: Paper
    @ObservedObject var viewModel: AppViewModel
    let artifact: InsightArtifact?
    let evidenceArtifact: EvidenceInsightArtifact?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let insight = evidenceArtifact?.insight {
                    EvidenceScopeBadge(fullText: true)
                    GroupBox("重要公式推导（LLM）") {
                        FormulaDerivationSection(
                            claims: insight.physics.importantFormulaDerivations,
                            anchors: Dictionary(uniqueKeysWithValues: viewModel.selectedEvidenceAnchors.map { ($0.id, $0) })
                        )
                    }
                    EvidenceClaimSection(title: "研究问题", claims: [insight.physics.researchQuestion])
                    EvidenceClaimSection(title: "方法与数据流", claims: insight.physics.methodAndDataFlow)
                    EvidenceClaimSection(title: "主要结果", claims: insight.physics.mainResults)
                    EvidenceClaimSection(title: "合理推断", claims: insight.physics.reasonableInferences)
                    EvidenceClaimSection(title: "原始资料未提供", claims: insight.physics.missingInformation)
                    EvidenceClaimSection(title: "解释限制", claims: insight.physics.caveats)
                } else if let insight = artifact?.insight {
                    EvidenceScopeBadge(fullText: false)
                    TextSection(title: "研究问题", text: insight.physics.researchQuestion)
                    TextSection(title: "物理背景", text: insight.physics.background)
                    ListSection(title: "方法与数据流", values: insight.physics.methodAndDataFlow)
                    ListSection(title: "主要结果", values: insight.physics.mainResults)
                    ListSection(title: "原始资料报告的格点约定", values: insight.physics.latticeConventionsReported)
                    ListSection(title: "原始摘要未提供", values: insight.physics.missingInformation)
                    ListSection(title: "解释限制", values: insight.physics.caveats)
                } else {
                    ContentUnavailableView("等待可验证的分析结果", systemImage: "checkmark.shield", description: Text("不会从标题扩写为论文结论。"))
                }
            }
            .padding()
        }
    }
}

private struct FiguresTab: View {
    let paper: Paper
    let artifact: InsightArtifact?
    @ObservedObject var viewModel: AppViewModel
    @State private var selectedFigureKey: String?
    @State private var previewFigure: PaperFigure?

    private var displayFigures: [PaperFigure] {
        let selected = Set(artifact?.insight.importantFigures.map(\.figureKey) ?? [])
        return selected.isEmpty ? paper.figures : paper.figures.filter { selected.contains($0.key) }
    }

    var body: some View {
        if displayFigures.isEmpty {
            ContentUnavailableView("没有可展示的 INSPIRE 图像", systemImage: "photo", description: Text("v1 不生成或伪造原图；仅使用 record 中的 figures。"))
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("默认仅使用 caption；Vision 会发送当前选定的缩放图像像素。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("分析 figure 像素") { viewModel.generateSelectedVisionInsight() }
                        .disabled(viewModel.settings.maximumFigures == 0)
                        .accessibilityIdentifier("generateVisionInsight")
                    if viewModel.settings.maximumFigures == 0 {
                        Text("maximumFigures=0 · 不发送图像").font(.caption2).foregroundStyle(.secondary)
                    }
                    if case .connecting = viewModel.visionState { Button("取消") { viewModel.cancelVision() } }
                    if case .receiving = viewModel.visionState { Button("取消") { viewModel.cancelVision() } }
                }
                .padding(10).background(.bar)
                HStack(spacing: 0) {
                List {
                    ForEach(displayFigures) { figure in
                        Button {
                            selectedFigureKey = figure.key
                        } label: {
                            VStack(alignment: .leading) {
                                Text(figure.label ?? figure.key).lineLimit(2)
                                Text(viewModel.visionArtifact?.insights.contains(where: { $0.figureKey == figure.key }) == true ? "vision: resized pixels sent" : "caption-only")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("figureRow-\(figure.key)")
                        .accessibilityLabel(figure.label ?? figure.key)
                        .accessibilityValue(viewModel.visionArtifact?.insights.contains(where: { $0.figureKey == figure.key }) == true ? "vision: resized pixels sent" : "caption-only")
                    }
                }
                .frame(minWidth: 160, maxWidth: 220)
                Divider()
                if let figure = selectedFigure ?? displayFigures.first {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let url = figure.url, url.scheme?.lowercased() == "https" {
                                Button { previewFigure = figure } label: {
                                    FigureImageView(figure: figure, purpose: "正在按需加载 INSPIRE 图像")
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("previewFigure-\(figure.key)")
                                .accessibilityLabel("打开 INSPIRE 原图预览")
                            } else { ContentUnavailableView("记录没有可用图像 URL", systemImage: "photo.badge.exclamationmark") }
                            GroupBox("原始 caption") {
                                LocalMarkdownTeXText(source: figure.caption ?? "INSPIRE record 未提供 caption。")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            GroupBox("图像 provenance") {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("来源：\(figure.source ?? "未知")")
                                    Text("文件名：\(figure.filename ?? "未知")")
                                    Text(artifact?.insight.importantFigures.contains(where: { $0.figureKey == figure.key }) == true ? "caption-only：模型只读取 caption，未查看图像像素。" : "未进入模型选择；显示 INSPIRE metadata。")
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            if let chosen = artifact?.insight.importantFigures.first(where: { $0.figureKey == figure.key }) {
                                GroupBox("中文图注") { LocalMarkdownTeXText(source: chosen.captionZH).frame(maxWidth: .infinity, alignment: .leading) }
                                GroupBox("选择理由") { Text(chosen.whyImportant).frame(maxWidth: .infinity, alignment: .leading) }
                            }
                            if let vision = viewModel.visionArtifact?.insights.first(where: { $0.figureKey == figure.key }) {
                                GroupBox("图像解读") {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Label("模型查看了缩放图像像素", systemImage: "eye").font(.caption)
                                        LocalMarkdownTeXText(source: vision.textZH)
                                    }
                                }
                            }
                            EvidenceBadge()
                        }
                        .padding()
                    }
                }
            }
            }
            .task(id: displayFigures.map(\.key)) {
                let availableKeys = Set(displayFigures.map(\.key))
                if selectedFigureKey == nil || !availableKeys.contains(selectedFigureKey ?? "") {
                    selectedFigureKey = displayFigures.first?.key
                }
            }
            .sheet(item: $previewFigure) { figure in FigurePreview(figure: figure) }
        }
    }

    private var selectedFigure: PaperFigure? { displayFigures.first { $0.key == selectedFigureKey } }
}

private struct FigurePreview: View {
    let figure: PaperFigure
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(figure.label ?? figure.key).font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
            }
            if let url = figure.url, url.scheme?.lowercased() == "https" {
                FigureImageView(figure: figure, purpose: "正在加载 INSPIRE 原图")
            } else {
                ContentUnavailableView("原图 URL 不满足 HTTPS 安全策略", systemImage: "lock.trianglebadge.exclamationmark")
            }
            LocalMarkdownTeXText(source: figure.caption ?? "INSPIRE record 未提供 caption.")
                .font(.caption)
        }
        .padding().frame(minWidth: 700, minHeight: 600)
    }
}

/// Fixture URLs are identifiers for process-local image bytes, never network
/// destinations.  Production URLs continue through `AsyncImage` only after
/// the INSPIRE mapper has accepted an HTTPS record URL.
private struct FigureImageView: View {
    let figure: PaperFigure
    let purpose: String

    private var isFixture: Bool { figure.url?.host == "fixture.invalid" }

    var body: some View {
        if isFixture {
            VStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line")
                    .resizable().scaledToFit().frame(width: 260, height: 180)
                    .foregroundStyle(.blue, .secondary)
                Text("测试缩略图 · 图像字节仅保留在进程内")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        } else {
            AsyncImage(url: figure.url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                case .failure: ContentUnavailableView("图像加载失败", systemImage: "exclamationmark.triangle")
                default: ProgressView(purpose)
                }
            }
        }
    }
}

private struct SourceTab: View {
    let paper: Paper
    @ObservedObject var viewModel: AppViewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let status = viewModel.paperDetailStatusMessage {
                    Label(status, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("paperDetailStatus")
                }
                // Keep user-owned reference actions at the start of the
                // Source tab.  Bibliographic fields can be long, but a local
                // read/favorite/note/tag/collection action should not require
                // scrolling past remote record metadata first.
                ReferenceControls(viewModel: viewModel)
                GroupBox("文献标题") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(paper.titles) { title in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("[\(title.source ?? "unknown")]").font(.caption).foregroundStyle(.secondary)
                                LocalMarkdownTeXText(source: title.value)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("摘要") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(paper.abstracts) { abstract in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("[\(abstract.source ?? "unknown")]").font(.caption).foregroundStyle(.secondary)
                                LocalMarkdownTeXText(source: abstract.value)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("书目元数据") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        SourceRow(name: "INSPIRE 记录 ID", value: String(paper.literatureID))
                        SourceRow(name: "arXiv", value: paper.arxivID ?? "未提供")
                        SourceRow(name: "DOI", value: paper.doi ?? "未提供")
                        SourceRow(name: "分类", value: paper.arxivCategories.joined(separator: ", "))
                        SourceRow(name: "发表状态", value: paper.publicationStatus ?? "未提供")
                        SourceRow(name: "发表年份（INSPIRE）", value: paper.publicationYear.map(String.init) ?? "未提供")
                        SourceRow(name: "记录更新时间", value: paper.updated?.formatted(date: .abbreviated, time: .shortened) ?? "未提供")
                        SourceRow(name: "图像数", value: String(paper.figures.count))
                    }
                }
                GroupBox("作者（INSPIRE 顺序）") {
                    VStack(alignment: .leading, spacing: 4) {
                        if paper.contributors.isEmpty {
                            Text("INSPIRE 搜索记录未提供作者顺序。").foregroundStyle(.secondary)
                        } else {
                            ForEach(paper.contributors.sorted { $0.position < $1.position }) { contributor in
                                HStack(alignment: .firstTextBaseline, spacing: 0) {
                                    Text("\(contributor.position + 1). \(contributor.fullName)\(contributor.recid.map { " · recid \($0)" } ?? "")")
                                        .multilineTextAlignment(.leading)
                                        .textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("文档与全文") {
                    if paper.documents.isEmpty {
                        Text("INSPIRE 记录未提供文档元数据。").foregroundStyle(.secondary)
                    } else {
                        ForEach(paper.documents) { document in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(document.filename ?? document.key).textSelection(.enabled)
                                Text("来源：\(document.source ?? "未知") · 全文：\(document.isFullText ? "是" : "否")")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let url = document.url { Text(url.absoluteString).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                if let url = URL(string: "https://inspirehep.net/literature/\(paper.literatureID)") {
                    Link(destination: url) { Label("在 INSPIRE 打开", systemImage: "safari") }
                        .accessibilityIdentifier("openInspireWeb")
                }
                if let apiURL = URL(string: "https://inspirehep.net/api/literature/\(paper.literatureID)") {
                    Link(destination: apiURL) { Label("打开 INSPIRE JSON", systemImage: "curlybraces") }
                        .accessibilityIdentifier("openInspireJSON")
                }
                BibTeXSourceControls(viewModel: viewModel)
            }
            .padding()
        }
        .accessibilityIdentifier("paperSourceScroll")
    }
}

private struct BibTeXSourceControls: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var document: MarkdownNoteDocument?
    @State private var exporting = false

    var body: some View {
        GroupBox("INSPIRE BibTeX") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("获取 / 刷新") { viewModel.fetchBibTeXForSelectedPaper() }
                        .accessibilityIdentifier("fetchBibTeX")
                    Button("导出…") { prepareExport() }
                        .disabled(viewModel.selectedBibTeXRecord == nil)
                        .accessibilityIdentifier("exportBibTeX")
                    Spacer()
                    if let record = viewModel.selectedBibTeXRecord {
                        Text("已验证 · \(record.sourceFetchedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("未缓存；不会生成替代条目").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let record = viewModel.selectedBibTeXRecord {
                    Text(record.sourceURL.absoluteString).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(record.contents).font(.system(.caption, design: .monospaced)).lineLimit(8).textSelection(.enabled)
                }
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .plainText,
                      defaultFilename: "LatticeLens-\(viewModel.selectedPaper?.literatureID ?? 0).bib") { result in
            viewModel.finishSelectedBibTeXExport(result)
        }
    }

    private func prepareExport() {
        Task {
            guard let text = await viewModel.prepareSelectedBibTeXExport() else { return }
            document = MarkdownNoteDocument(text: text)
            exporting = true
        }
    }
}

private struct SourceRow: View {
    let name: String
    let value: String
    var body: some View { GridRow { Text(name).foregroundStyle(.secondary); Text(value).textSelection(.enabled) } }
}

private struct TextSection: View {
    let title: String
    let text: String
    var body: some View { GroupBox(title) { LocalMarkdownTeXText(source: text).frame(maxWidth: .infinity, alignment: .leading) } }
}

private struct ListSection: View {
    let title: String
    let values: [String]
    var body: some View {
        GroupBox(title) {
            if values.isEmpty { Text("原始资料未提供。").foregroundStyle(.secondary) }
            else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "circle.fill").font(.caption)
                            LocalMarkdownTeXText(source: value)
                        }
                    }
                }
            }
        }
    }
}

private struct EvidenceBadge: View {
    var body: some View {
        EvidenceScopeBadge(fullText: false)
    }
}

private struct EvidenceScopeBadge: View {
    let fullText: Bool
    var body: some View {
        Label(fullText ? "证据范围：本地提取的全文 anchor + metadata" : "证据范围：标题 + 摘要 + figure captions", systemImage: "checkmark.shield")
            .font(.caption).padding(.horizontal, 8).padding(.vertical, 5).background(.blue.opacity(0.12), in: Capsule())
            .accessibilityLabel(fullText ? "证据范围：本地提取的全文锚点与 metadata；不含图像像素" : "证据范围：标题、摘要和图像 caption；不含全文或图像像素")
    }
}

private struct EvidenceTab: View {
    let paper: Paper
    @ObservedObject var viewModel: AppViewModel
    @State private var filter: EvidenceSourceKind?
    @State private var previewAnchor: EvidenceAnchor?

    private var anchors: [EvidenceAnchor] {
        viewModel.selectedEvidenceAnchors.filter { filter == nil || $0.sourceKind == filter }
    }

    private var firstAvailablePDFAnchor: EvidenceAnchor? {
        anchors.first { $0.sourceKind == .pdf }
    }

    @MainActor
    private func presentEvidenceJumpIfAvailable() {
        guard let anchor = viewModel.evidenceJumpAnchor, anchor.paperID == paper.literatureID else { return }
        filter = anchor.sourceKind
        if anchor.sourceKind == .pdf, viewModel.selectedFullTextDocument?.sourceKind != .arxivHTML { previewAnchor = anchor }
        viewModel.consumeEvidenceJump(anchor.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                EvidenceScopeBadge(fullText: viewModel.selectedFullTextDocument?.extractionState == .extracted)
                Spacer()
                if let document = viewModel.selectedFullTextDocument, document.extractionState == .extracted {
                    Button("生成重要公式推导") { viewModel.generateSelectedEvidenceInsight() }
                        .accessibilityIdentifier("generateEvidenceInsight")
                    Button("删除本地全文", role: .destructive) { viewModel.deleteSelectedFullText() }
                        .accessibilityIdentifier("deleteSelectedFullText")
                    if let anchor = firstAvailablePDFAnchor, viewModel.selectedFullTextDocument?.sourceKind != .arxivHTML {
                        Button("打开当前 PDF anchor") { previewAnchor = anchor }
                            .accessibilityIdentifier("openFirstPDFEvidenceAnchor")
                            .keyboardShortcut("o", modifiers: [.command, .shift])
                    }
                }
            }
            .padding(.horizontal).padding(.top)
            if let message = viewModel.fullTextStatusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    .accessibilityIdentifier("fullTextStatus")
            }
            GroupBox("重要公式推导（LLM）") {
                if let artifact = viewModel.evidenceInsightArtifact {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("以下推导仅来自已提取的全文 chunks，并逐条绑定可回查的 anchor；不会把摘要级猜测当作公式。")
                            .font(.caption).foregroundStyle(.secondary)
                        FormulaDerivationSection(
                            claims: artifact.insight.physics.importantFormulaDerivations,
                            anchors: Dictionary(uniqueKeysWithValues: viewModel.selectedEvidenceAnchors.map { ($0.id, $0) })
                        )
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("本标签专门展示论文重要公式及其逐步推导。请先下载并提取全文，再点击“生成重要公式推导”；LLM 会把原文公式与自己的推导明确区分，并保留来源 anchor。")
                            .font(.caption).foregroundStyle(.secondary)
                        if viewModel.selectedFullTextDocument?.extractionState == .extracted {
                            Text("全文已就绪，点击上方按钮生成公式推导。")
                                .font(.caption)
                        }
                    }
                }
            }
            .padding(.horizontal)
            if viewModel.selectedFullTextDocument == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("尚未下载全文：当前只可浏览 abstract/caption anchors。")
                    ForEach(paper.documents.filter { $0.isFullText && $0.url != nil }) { document in
                        Button {
                            viewModel.requestFullTextPreflight(document)
                        } label: {
                            Label("预检并下载 \(document.source ?? "INSPIRE") PDF", systemImage: "arrow.down.doc")
                        }
                            .accessibilityIdentifier("downloadFullText-\(document.key)")
                    }
                    if let arxivID = paper.arxivID, !arxivID.isEmpty {
                        Button {
                            viewModel.requestArxivHTMLPreflight()
                        } label: {
                            Label("从 ar5iv 获取 HTML 全文（arXiv:\(arxivID)）", systemImage: "globe")
                        }
                        .accessibilityIdentifier("downloadArxivHTML-\(paper.literatureID)")
                    }
                    if paper.documents.filter({ $0.isFullText && $0.url != nil }).isEmpty {
                        Text(paper.arxivID == nil ? "INSPIRE record 未提供受信任的 public fulltext URL。" : "无 INSPIRE 全文时，可使用上方 ar5iv HTML 来源。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
            } else if let document = viewModel.selectedFullTextDocument {
                GroupBox("本地全文") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        SourceRow(name: "来源", value: document.sourceKind.displayNameZH)
                        SourceRow(name: "bytes", value: String(document.byteCount))
                        SourceRow(name: "SHA-256", value: document.sha256)
                        SourceRow(name: "pages", value: document.pageCount.map(String.init) ?? "未提取")
                        SourceRow(name: "状态", value: document.extractionState.displayNameZH)
                    }
                }
                .padding(.horizontal)
            }
            Picker("anchor 类型", selection: $filter) {
                Text("全部").tag(EvidenceSourceKind?.none)
                ForEach(EvidenceSourceKind.allCases, id: \.self) { type in Text(type.displayNameZH).tag(EvidenceSourceKind?.some(type)) }
            }
            .pickerStyle(.segmented).padding(.horizontal)
            if let artifact = viewModel.evidenceInsightArtifact {
                EvidenceArtifactSummary(artifact: artifact)
                    .padding(.horizontal)
            }
            if let annotationStatus = viewModel.annotationStatusMessage {
                Text(annotationStatus)
                    .font(.caption)
                    .foregroundStyle(annotationStatus.contains("失败") ? .red : .secondary)
                    .padding(.horizontal)
                    .accessibilityIdentifier("annotationSaveStatus")
                    .accessibilityLabel("Local annotation save status")
                    .accessibilityValue(annotationStatus)
            }
            List(anchors) { anchor in
                // Keep the anchor preview and its mutation action in separate
                // vertical regions.  The preview label can legitimately span
                // the whole detail column; placing a link beside it lets its
                // unbounded quote content lay the action outside the column
                // on a narrow window, where it is no longer clickable.
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        if anchor.sourceKind == .pdf, viewModel.selectedFullTextDocument?.sourceKind != .arxivHTML { previewAnchor = anchor }
                    } label: { EvidenceAnchorRow(anchor: anchor) }
                    .buttonStyle(.plain)
                    .disabled(anchor.sourceKind != .pdf || viewModel.selectedFullTextDocument?.sourceKind == .arxivHTML)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Keep the source kind at the stable prefix boundary so
                    // UI automation can select PDF anchors without coupling
                    // to the v3 document/hash-derived identifier payload.
                    .accessibilityIdentifier("evidenceAnchor-\(anchor.sourceKind.rawValue):\(anchor.id)")
                    HStack {
                        Button("加 annotation") { viewModel.createUserAnnotation(from: anchor) }
                            .buttonStyle(.link)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityIdentifier("annotateEvidence-\(anchor.id)")
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(item: $previewAnchor) { anchor in
            PDFAnchorPreview(document: viewModel.selectedFullTextDocument, anchor: anchor) { selection in
                viewModel.createUserAnnotation(fromPDFSelection: selection, document: viewModel.selectedFullTextDocument)
            }
        }
        .task(id: "\(paper.literatureID):\(viewModel.evidenceJumpAnchor?.id ?? "")") {
            // Give the selected-paper snapshot one turn to reload its local
            // document reference before opening a PDF page.  No network work
            // is performed by this navigation path.
            await Task.yield()
            presentEvidenceJumpIfAvailable()
        }
        .onChange(of: viewModel.evidenceJumpAnchor?.id) { _, anchorID in
            guard anchorID != nil else { return }
            Task { @MainActor in
                // Let the Workbench onDismiss transaction settle before this
                // Evidence-owned PDF sheet is requested.
                await Task.yield()
                presentEvidenceJumpIfAvailable()
            }
        }
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                presentEvidenceJumpIfAvailable()
            }
        }
    }
}

private struct EvidenceAnchorRow: View {
    let anchor: EvidenceAnchor
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(anchor.sourceKind.displayNameZH).font(.caption).foregroundStyle(.secondary)
                if let page = anchor.page { Text("PDF p.\(page)").font(.caption).foregroundStyle(.secondary) }
                if let section = anchor.section { Text(section).font(.caption).lineLimit(1).foregroundStyle(.secondary) }
            }
            LocalMarkdownTeXText(source: anchor.quote)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EvidenceArtifactSummary: View {
    let artifact: EvidenceInsightArtifact
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("已验证 paper-insight-v2").font(.headline)
            Text("检索 chunk：\(artifact.chunkIDs.count) · 生成于 \(artifact.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                StatusCount(label: "direct", claims: [artifact.insight.physics.researchQuestion] + artifact.insight.physics.methodAndDataFlow + artifact.insight.physics.mainResults)
                StatusCount(label: "inference", claims: artifact.insight.physics.reasonableInferences)
                StatusCount(label: "missing", claims: artifact.insight.physics.missingInformation)
            }
        }
    }
}

private struct StatusCount: View {
    let label: String
    let claims: [EvidenceClaim]
    var body: some View { Text("\(label) \(claims.count)").font(.caption).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule()) }
}

private struct EvidenceClaimSection: View {
    let title: String
    let claims: [EvidenceClaim]
    var body: some View {
        GroupBox(title) {
            if claims.isEmpty { Text("原始资料未提供。").foregroundStyle(.secondary) }
            else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(claims) { claim in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .top) {
                                Text(claim.epistemicStatus.displayNameZH)
                                    .font(.caption)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                                LocalMarkdownTeXText(source: claim.textZH)
                            }
                            if !claim.evidenceIDs.isEmpty {
                                Text("回查锚点：" + claim.evidenceIDs.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            } else if claim.epistemicStatus == .missing {
                                Text("无回查锚点：原文未提供此信息")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Formula claims deserve a more explicit presentation than ordinary prose:
/// the epistemic label, native local math rendering, and every full-text anchor
/// are kept in one bounded card so a reader can verify the derivation without
/// parsing raw `<math>` markup or opaque UUIDs.
private struct FormulaDerivationSection: View {
    let claims: [EvidenceClaim]
    let anchors: [String: EvidenceAnchor]

    var body: some View {
        if claims.isEmpty {
            Text("未找到可回查的论文重要公式；当前全文 chunks 没有足够的公式文本。")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(claims.enumerated()), id: \.element.id) { index, claim in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("公式 " + String(index + 1)).font(.subheadline.weight(.semibold))
                            Text(claim.epistemicStatus.displayNameZH)
                                .font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(claim.epistemicStatus == .direct ? .green.opacity(0.15) : .orange.opacity(0.15), in: Capsule())
                        }
                        LocalMarkdownTeXText(source: claim.textZH)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        if let formula = claim.formulaTeX {
                            GroupBox("原文公式（direct）") {
                                LocalTeXFormulaText(source: formula)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if !claim.derivationSteps.isEmpty {
                            GroupBox("LLM 推导（基于原文公式）") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(claim.derivationSteps.enumerated()), id: \.offset) { stepIndex, step in
                                        HStack(alignment: .top, spacing: 8) {
                                            Text("\(stepIndex + 1).")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            LocalMarkdownTeXText(source: step)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                            }
                        }
                        if let conclusion = claim.conclusionZH {
                            GroupBox("结论") {
                                LocalMarkdownTeXText(source: conclusion)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if claim.evidenceIDs.isEmpty {
                            Text("无 PDF 锚点；此项不能作为 direct 公式结论。")
                                .font(.caption2).foregroundStyle(.orange)
                        } else {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(claim.evidenceIDs, id: \.self) { evidenceID in
                                    if let anchor = anchors[evidenceID] {
                                        let location = anchor.page.map { "第 " + String($0) + " 页" } ?? "元数据"
                                        let section = anchor.section.map { " · " + $0 } ?? ""
                                        Text("回查：" + anchor.sourceKind.displayNameZH + " " + location + section)
                                            .font(.caption2).foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    } else {
                                        Text("回查锚点缺失：" + evidenceID)
                                            .font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}

struct PDFAnchorPreview: View {
    let document: FullTextDocument?
    let anchor: EvidenceAnchor
    var createAnnotation: ((PDFTextSelectionAnchor) -> Void)? = nil
    var compact = false
    @State private var selection: PDFTextSelectionAnchor?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PDF p.\(anchor.page ?? 0)")
                .font(.headline)
                // As with the nested Compare inspector, identify a concrete
                // visible child instead of relying solely on a sheet root.
                .accessibilityIdentifier("pdfAnchorPreviewPageTitle-\(anchor.page ?? 0)")
            LocalMarkdownTeXText(source: anchor.quote).font(.caption).lineLimit(4)
            if let document, let filename = document.localFilename {
                PDFPageView(url: FullTextService.defaultCacheDirectory.appendingPathComponent(filename), page: anchor.page ?? 1,
                            textSelection: $selection)
                    .accessibilityIdentifier("pdfKitReader")
                if let selection, let createAnnotation {
                    HStack {
                        Text("已选 p.\(selection.page) · range \(selection.characterRangeStart)–\(selection.characterRangeEnd)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("将选中文本加 annotation") { createAnnotation(selection) }
                            .accessibilityIdentifier("annotatePDFSelection")
                    }
                } else if createAnnotation != nil {
                    Text("选择同一 PDF 页中唯一出现的文本后可创建 annotation；跨页或重复文本不会做模糊定位。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("本地 PDF 已删除", systemImage: "doc.badge.minus")
            }
        }
        // Do not identify this container: on macOS SwiftUI an outer identifier
        // can be inherited by its visible descendants and hide the stable page
        // title from XCUIApplication/assistive technology.
        .padding().frame(minWidth: compact ? nil : 700, minHeight: compact ? 220 : 600)
    }
}

private struct PDFPageView: NSViewRepresentable {
    let url: URL
    let page: Int
    @Binding var textSelection: PDFTextSelectionAnchor?

    func makeCoordinator() -> Coordinator { Coordinator(selection: $textSelection) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        if let target = view.document?.page(at: max(0, page - 1)) { view.go(to: target) }
        context.coordinator.observe(view)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if let target = view.document?.page(at: max(0, page - 1)), view.currentPage !== target { view.go(to: target) }
    }

    @MainActor
    final class Coordinator: NSObject {
        private var selection: Binding<PDFTextSelectionAnchor?>
        private weak var pdfView: PDFView?

        init(selection: Binding<PDFTextSelectionAnchor?>) { self.selection = selection }

        deinit { NotificationCenter.default.removeObserver(self) }

        func observe(_ view: PDFView) {
            pdfView = view
            NotificationCenter.default.addObserver(self, selector: #selector(selectionDidChange(_:)),
                                                   name: Notification.Name.PDFViewSelectionChanged, object: view)
        }

        @objc private func selectionDidChange(_ notification: Notification) {
            guard let view = pdfView, let selected = view.currentSelection,
                  let page = selected.pages.first, selected.pages.count == 1,
                  let pageIndex = view.document?.index(for: page),
                  let pageText = page.string, let quote = selected.string else {
                selection.wrappedValue = nil
                return
            }
            selection.wrappedValue = PDFTextSelectionLocator.locate(pageText: pageText, quote: quote, page: pageIndex + 1)
        }
    }
}

private struct ReferenceControls: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var note = ""
    @State private var tagName = ""
    @State private var collectionName = ""
    @State private var markdownDocument: MarkdownNoteDocument?
    @State private var isExportingMarkdown = false
    @State private var presentTagManager = false
    @State private var presentCollectionManager = false
    @State private var favoritePresentationOverride: Bool?

    private var selectedPaperIsFavorite: Bool {
        if let favoritePresentationOverride { return favoritePresentationOverride }
        guard let paper = viewModel.selectedPaper else { return false }
        return viewModel.isFavorite(paper)
    }

    var body: some View {
        GroupBox("文献管理") {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    favoritePresentationOverride = !selectedPaperIsFavorite
                    viewModel.toggleFavoriteSelectedPaper()
                } label: {
                    Label(selectedPaperIsFavorite ? "取消收藏" : "收藏", systemImage: selectedPaperIsFavorite ? "star.fill" : "star")
                }
                .accessibilityIdentifier("toggleFavorite")
                .accessibilityValue(selectedPaperIsFavorite ? "favorite" : "not_favorite")
                if let paperID = viewModel.selectedPaper?.literatureID {
                    Text(selectedPaperIsFavorite ? "已收藏" : "未收藏")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        // State is part of this testing-only semantic identity
                        // so an accessibility client gets a new query target
                        // after a local mutation instead of a cached value.
                        .accessibilityIdentifier("favoriteState-\(paperID)-\(selectedPaperIsFavorite ? "favorite" : "not_favorite")")
                        .accessibilityValue(selectedPaperIsFavorite ? "favorite" : "not_favorite")
                        // macOS accessibility can retain a cached StaticText
                        // node when only its value changes.  Its semantic
                        // identifier remains stable for assistive tools and
                        // UI tests, while this rendering identity makes the
                        // local state transition observable immediately.
                        .id("favorite-state-\(paperID)-\(selectedPaperIsFavorite ? "favorite" : "not_favorite")")
                }
                HStack {
                    TextField("新建 tag", text: $tagName)
                        .accessibilityIdentifier("newTagName")
                    Button("添加") { viewModel.createTag(named: tagName); tagName = "" }
                        .disabled(tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("addTag")
                }
                if !viewModel.availableTags.isEmpty {
                    Button("管理 tags…") { presentTagManager = true }
                        .accessibilityIdentifier("manageTags")
                    Text(viewModel.selectedTags.map(\.name).joined(separator: ", ").isEmpty ? "未设置 tag" : "tags：\(viewModel.selectedTags.map(\.name).joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let paperID = viewModel.selectedPaper?.literatureID {
                    let availableTagNames = viewModel.availableTags.map(\.name).sorted().joined(separator: ", ")
                    Text(availableTagNames.isEmpty ? "尚无可用 tag" : "可用 tags：\(availableTagNames)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("availableTagsState-\(paperID)-\(viewModel.availableTags.count)")
                        .accessibilityValue(availableTagNames)
                        // AppKit can preserve a stale accessibility value on
                        // a reused Text node even after its identifier/count
                        // changes.  The tag names are the semantic value read
                        // by VoiceOver and the fixture UI contract, so make
                        // the rendering identity track that full projection.
                        .id("available-tags-state-\(paperID)-\(availableTagNames)")
                }
                HStack {
                    TextField("新建 collection", text: $collectionName)
                        .accessibilityIdentifier("newCollectionName")
                    Button("添加") { viewModel.createCollection(named: collectionName); collectionName = "" }
                        .disabled(collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("addCollection")
                }
                if !viewModel.availableCollections.isEmpty {
                    Button("管理 collections…") { presentCollectionManager = true }
                        .accessibilityIdentifier("manageCollections")
                    Text(selectedCollectionNames.isEmpty ? "未加入 collection" : "collections：\(selectedCollectionNames.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if viewModel.isUsingFixtureDependencies {
                    // The macOS accessibility bridge maps a vertical TextField
                    // to an NSTextView whose typed value is not observable by
                    // XCUIApplication.  Keep fixture I/O process-local and use
                    // the single-line native control solely for the automated
                    // durable-save path; production retains its multiline
                    // editor below.
                    TextField("本地阅读 note（fixture，不发送至 provider）", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("readingNote")
                } else {
                    TextEditor(text: $note)
                        .frame(minHeight: 90)
                        .overlay(alignment: .topLeading) {
                            if note.isEmpty {
                                Text("本地阅读 note（不发送至 provider）")
                                    .foregroundStyle(.secondary)
                                    .padding(8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityIdentifier("readingNote")
                }
                HStack {
                    Button("保存 note") { viewModel.saveSelectedPaperNote(note, existing: viewModel.selectedNotes.first) }
                        .accessibilityIdentifier("saveReadingNote")
                    if let noteItem = viewModel.selectedNotes.first { Button("删除 note", role: .destructive) { viewModel.deleteNote(noteItem); note = "" } }
                }
                if let paperID = viewModel.selectedPaper?.literatureID {
                    let noteBodies = viewModel.selectedNotes.map(\.body).sorted().joined(separator: "\n")
                    Text(viewModel.selectedNotes.isEmpty ? "尚无已保存 note" : "已保存 \(viewModel.selectedNotes.count) 条本地 note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !viewModel.selectedNotes.isEmpty {
                        // Keep the durable projection as actual rendered text.  On
                        // macOS the accessibility bridge may retain a Text view’s
                        // visual value instead of a separately supplied
                        // accessibilityValue; rendering the saved body here lets
                        // assistive clients and fixture UI tests read the same
                        // persisted state a user sees.
                        Text(noteBodies)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("noteState-\(paperID)-\(viewModel.selectedNotes.count)")
                            .accessibilityLabel(noteBodies)
                    }
                }
                HStack {
                    Button("复制 validated Markdown note") { viewModel.copySelectedPaperMarkdownNote() }
                        .accessibilityIdentifier("copyMarkdownNote")
                    Button("导出 Markdown…") { prepareMarkdownExport() }
                        .accessibilityIdentifier("exportMarkdownNote")
                }
            }
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            // The ViewModel reloads authoritative storage on a failed write;
            // discard only this temporary presentation projection when it
            // reports that failure.
            if message == "无法更新收藏状态。" { favoritePresentationOverride = nil }
        }
        // A paper switch must reset the editor identity before a stale note can
        // be saved into the newly selected paper.
        .id("reference-controls-\(viewModel.selectedPaperID ?? 0)")
        .onAppear { note = viewModel.selectedNotes.first?.body ?? "" }
        .sheet(isPresented: $presentTagManager) {
            ReferenceSelectionManager(viewModel: viewModel, kind: .tag,
                                      isPresented: $presentTagManager)
        }
        .sheet(isPresented: $presentCollectionManager) {
            ReferenceSelectionManager(viewModel: viewModel, kind: .collection,
                                      isPresented: $presentCollectionManager)
        }
        .fileExporter(isPresented: $isExportingMarkdown,
                      document: markdownDocument,
                      contentType: .plainText,
                      defaultFilename: "LatticeLens-reading-note-\(viewModel.selectedPaper?.literatureID ?? 0)") { result in
            viewModel.finishSelectedMarkdownExport(result)
        }
    }

    private var selectedTagIDs: Set<UUID> { Set(viewModel.selectedTags.map(\.id)) }
    private var selectedCollectionIDs: Set<UUID> {
        viewModel.selectedCollectionIDs
    }
    private var selectedCollectionNames: [String] {
        viewModel.availableCollections.filter { selectedCollectionIDs.contains($0.id) }.map(\.name).sorted()
    }
    private func prepareMarkdownExport() {
        Task {
            do {
                let text = try await viewModel.prepareSelectedMarkdownExport()
                markdownDocument = MarkdownNoteDocument(text: text)
                isExportingMarkdown = true
            } catch {
                viewModel.reportUserError("无法准备 Markdown 导出：\(error.localizedDescription)")
            }
        }
    }
}

private enum ReferenceManagerKind {
    case tag
    case collection

    var title: String { self == .tag ? "管理 tags" : "管理 collections" }
    var searchPrompt: String { self == .tag ? "搜索 tags" : "搜索 collections" }
    var listIdentifier: String { self == .tag ? "tagManagerScrollableList" : "collectionManagerScrollableList" }
}

private struct ReferenceSelectionItem: Identifiable, Equatable {
    let id: UUID
    let name: String
}

/// A searchable native management surface for large tag/collection sets.
/// Checkboxes edit a process-local draft.  The persistent mutation is deferred
/// to Apply, so cancelling a 100-item selection pass is zero-write.
private struct ReferenceSelectionManager: View {
    @ObservedObject var viewModel: AppViewModel
    let kind: ReferenceManagerKind
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var draftSelection: Set<UUID>
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var pendingDelete: ReferenceSelectionItem?

    init(viewModel: AppViewModel, kind: ReferenceManagerKind, isPresented: Binding<Bool>) {
        self.viewModel = viewModel
        self.kind = kind
        _isPresented = isPresented
        switch kind {
        case .tag: _query = State(initialValue: AppLaunchConfiguration.fixtureInitialTagManagerSearch ?? "")
        case .collection: _query = State(initialValue: AppLaunchConfiguration.fixtureInitialCollectionManagerSearch ?? "")
        }
        switch kind {
        case .tag: _draftSelection = State(initialValue: Set(viewModel.selectedTags.map(\.id)))
        case .collection: _draftSelection = State(initialValue: viewModel.selectedCollectionIDs)
        }
    }

    private var items: [ReferenceSelectionItem] {
        let values: [ReferenceSelectionItem]
        switch kind {
        case .tag: values = viewModel.availableTags.map { ReferenceSelectionItem(id: $0.id, name: $0.name) }
        case .collection: values = viewModel.availableCollections.map { ReferenceSelectionItem(id: $0.id, name: $0.name) }
        }
        let needle = SearchNormalizer.normalize(query)
        return values
            .filter { needle.isEmpty || SearchNormalizer.normalize($0.name).contains(needle) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(kind.title).font(.title3)
                Spacer()
                Text("已选择 \(draftSelection.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            TextField(kind.searchPrompt, text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .accessibilityIdentifier(kind == .tag ? "tagManagerSearch" : "collectionManagerSearch")
            List {
                if items.isEmpty {
                    Text("没有匹配项").foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Button {
                            if draftSelection.contains(item.id) { draftSelection.remove(item.id) }
                            else { draftSelection.insert(item.id) }
                        } label: {
                            Image(systemName: draftSelection.contains(item.id) ? "checkmark.square.fill" : "square")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.name)
                        .accessibilityValue(draftSelection.contains(item.id) ? "selected" : "unselected")
                        Text(item.name).lineLimit(1)
                        Spacer(minLength: 8)
                        if renamingID == item.id {
                            TextField("新名称", text: $renameText)
                                .frame(width: 150)
                                .accessibilityIdentifier("renameReferenceItem")
                            Button("保存") { saveRename(item) }
                            Button("取消") { renamingID = nil; renameText = "" }
                        } else {
                            Button("重命名") { renamingID = item.id; renameText = item.name }
                            Button("删除", role: .destructive) { pendingDelete = item }
                        }
                    }
                    .accessibilityIdentifier("\(kind == .tag ? "tag" : "collection")-manager-row-\(item.id.uuidString)")
                }
            }
            .scrollIndicators(.visible)
            .accessibilityIdentifier(kind.listIdentifier)
            .accessibilityLabel(kind == .tag ? "Tags scrollable list" : "Collections scrollable list")
            Divider()
            HStack {
                // This manager is itself presented from a long-lived Paper
                // Lens hierarchy.  Drive its owning binding directly: an
                // ambient `dismiss()` can retire the responder but leave a
                // modal accessibility layer behind on macOS.
                Button("取消", role: .cancel) { isPresented = false }
                    .accessibilityIdentifier("cancelReferenceSelection")
                Spacer()
                Button("应用") { applyDraft(); isPresented = false }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("applyReferenceSelection")
            }
            .padding()
        }
        .frame(minWidth: 600, minHeight: 560)
        .confirmationDialog("删除 \(kind == .tag ? "tag" : "collection")？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            if let pendingDelete {
                Button("删除", role: .destructive) { delete(pendingDelete); self.pendingDelete = nil }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将解除 \(linkCount(for: pendingDelete?.id)) 条论文关联；不会删除论文或 PDF。")
        }
    }

    private func applyDraft() {
        switch kind {
        case .tag: viewModel.setSelectedPaperTags(draftSelection)
        case .collection: viewModel.setSelectedPaperCollections(draftSelection)
        }
    }

    private func saveRename(_ item: ReferenceSelectionItem) {
        switch kind {
        case .tag:
            if let tag = viewModel.availableTags.first(where: { $0.id == item.id }) { viewModel.renameTag(tag, to: renameText) }
        case .collection:
            if let collection = viewModel.availableCollections.first(where: { $0.id == item.id }) { viewModel.renameCollection(collection, to: renameText) }
        }
        renamingID = nil
        renameText = ""
    }

    private func delete(_ item: ReferenceSelectionItem) {
        draftSelection.remove(item.id)
        switch kind {
        case .tag:
            if let tag = viewModel.availableTags.first(where: { $0.id == item.id }) { viewModel.deleteTag(tag) }
        case .collection:
            if let collection = viewModel.availableCollections.first(where: { $0.id == item.id }) { viewModel.deleteCollection(collection) }
        }
    }

    private func linkCount(for id: UUID?) -> Int {
        guard let id else { return 0 }
        switch kind {
        case .tag: return viewModel.workbenchSnapshot.paperTags.filter { $0.tagID == id }.count
        case .collection: return viewModel.workbenchSnapshot.collectionPapers.filter { $0.collectionID == id }.count
        }
    }
}

private struct InsightStatusBar: View {
    @ObservedObject var viewModel: AppViewModel
    private var text: String {
        switch viewModel.insightState {
        case .idle: "尚未调用 LLM"
        case .connecting: "正在连接 · 本次将发送 \(viewModel.settings.mode == .fast ? 1 : 2) 次请求"
        case .waitingFirstContent: "已连接 · 正在等待首段内容"
        case .receiving(let characters, let bytes): "正在接收 · \(characters) 字符 / \(bytes) bytes"
        case .validating: "正在验证结构化资料边界"
        case .completed(let cacheHit, let requestCount): cacheHit ? "已从本地缓存显示 · 0 次请求" : "已完成 · \(requestCount) 次请求"
        case .cancelled: viewModel.insightArtifact == nil ? "已取消；本次没有保存结果" : "已取消；已保留先前成功结果"
        case .failed(let message): "失败：\(message)"
        }
    }
    var body: some View {
        HStack {
            // Keep the semantic status outside TimelineView.  On macOS the
            // latter may keep an old closure snapshot in the accessibility
            // tree until its next periodic tick, which made cancel/completion
            // announcements stale even though AppViewModel had changed state.
            // Elapsed time remains independently refreshable and decorative.
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("insightStatus")
                .accessibilityLabel("分析状态")
                .accessibilityValue(text)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(elapsedSuffix(at: context.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Spacer()
            if case .connecting = viewModel.insightState {
                Button("取消") { viewModel.cancelInsight() }
                    .accessibilityIdentifier("cancelInsight")
                    .keyboardShortcut(.cancelAction)
            }
            if case .waitingFirstContent = viewModel.insightState {
                Button("取消") { viewModel.cancelInsight() }
                    .accessibilityIdentifier("cancelInsight")
                    .keyboardShortcut(.cancelAction)
            }
            if case .receiving = viewModel.insightState {
                Button("取消") { viewModel.cancelInsight() }
                    .accessibilityIdentifier("cancelInsight")
                    .keyboardShortcut(.cancelAction)
            }
            Button("重新生成") { viewModel.generateSelectedInsight() }
                .disabled(viewModel.selectedPaper == nil)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .frame(minWidth: 88)
                .accessibilityIdentifier("regenerateInsight")
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        // Keep the action band inside the detail column's safe area even when
        // the host window is at the compact 820×640 floor.  A fixed minimum
        // height and bottom inset prevent the primary action from being
        // visually clipped against the screen edge (which also makes pointer
        // activation unreliable on a scaled display).
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .center)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .padding(.bottom, 4)
        .background(.bar)
    }

    private func elapsedSuffix(at date: Date) -> String {
        guard viewModel.isInsightRunning else { return "" }
        guard let started = viewModel.insightStartedAt else { return "" }
        return " · \(max(0, Int(date.timeIntervalSince(started)))) s"
    }
}
