import Foundation
import SwiftUI
import UniformTypeIdentifiers

private struct WorkbenchTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .json] }
    let text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// The v3 local entry point.  It intentionally reads the durable snapshot
/// through AppViewModel and never fabricates Radar/physics values in SwiftUI.
struct V3WorkbenchView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Int

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        let requestedTab = AppLaunchConfiguration.fixtureInitialWorkbenchTab
        let initialTab: Int
        switch requestedTab {
        case "compare": initialTab = 1
        case "notebook": initialTab = 2
        case "graph": initialTab = 3
        default: initialTab = 0
        }
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("证据工作台", systemImage: "rectangle.3.group")
                    .font(.title3)
                    // Keep the Workbench's stable region identifier on the
                    // title itself.  On current macOS, assigning it to the
                    // root VStack causes the accessibility bridge to replace
                    // descendant identifiers (for example
                    // `createNotebookEntry`) with `v3Workbench`.
                    .accessibilityIdentifier("v3Workbench")
                Spacer()
                Text("本地快照 · \(viewModel.workbenchSnapshot.v3SchemaVersion)")
                    .font(.caption).foregroundStyle(.secondary)
                Button("刷新") { Task { await viewModel.refreshWorkbench() } }
                    .accessibilityIdentifier("workbenchRefresh")
                Button("完成") { dismiss() }
            }
            .padding()
            Picker("工作台", selection: $tab) {
                Text("研究雷达").tag(0)
                Text("对照").tag(1)
                Text("笔记本与导出").tag(2)
                Text("关系图").tag(3)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("workbenchTabPicker")
            .padding(.horizontal)
            Divider()
            Group {
                switch tab {
                case 0: RadarWorkbenchTab(viewModel: viewModel)
                case 1: CompareWorkbenchTab(viewModel: viewModel, dismissWorkbench: { dismiss() })
                case 2: NotebookWorkbenchTab(viewModel: viewModel)
                default: GraphWorkbenchTab(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The v4 cockpit's contractual minimum is 1120 pt. At this width a
        // two-paper matrix and its evidence inspector can coexist; smaller
        // widths would otherwise hide the actionable inspector column.
        .frame(minWidth: 820, minHeight: 640)
        .task {
            await viewModel.refreshWorkbench()
            viewModel.runDueRadarQueries()
        }
    }
}

private struct RadarWorkbenchTab: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var queryName = "hep-lat"
    @State private var queryText = "arxiv_categories:hep-lat"
    @State private var policy: SavedQueryRefreshPolicy = .manual
    @State private var queryInteractionRevision = 0

    private var events: [RadarEvent] {
        viewModel.workbenchSnapshot.radarEvents.values.sorted { $0.observedAt > $1.observedAt }
    }

    private var savedQueries: [SavedInspireQuery] {
        viewModel.workbenchSnapshot.savedInspireQueries.values.sorted { $0.name < $1.name }
    }

    private var savedQueryPresentationID: String {
        savedQueries.map { "\($0.id.uuidString):\($0.isPaused)" }.joined(separator: "|")
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                Text("已保存的 INSPIRE 查询").font(.headline)
                TextField("名称", text: $queryName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("radarQueryName")
                TextField("INSPIRE 查询语句", text: $queryText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("radarQueryText")
                Picker("刷新策略", selection: $policy) {
                    ForEach(SavedQueryRefreshPolicy.allCases, id: \.self) { Text($0.displayNameZH).tag($0) }
                }
                .accessibilityIdentifier("radarRefreshPolicy")
                Button("保存查询") { viewModel.saveRadarQuery(name: queryName, query: queryText, policy: policy) }
                    .accessibilityIdentifier("saveRadarQuery")
                Divider()
                List(savedQueries) { query in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(query.name)
                            Text(query.query).font(.caption2).foregroundStyle(.secondary)
                            Text(query.isPaused ? "已暂停" : "运行中")
                                .font(.caption2)
                                .foregroundStyle(query.isPaused ? Color.orange : Color.secondary)
                                .accessibilityIdentifier("radarQueryState-\(query.id.uuidString)")
                                .accessibilityValue(query.isPaused ? "已暂停" : "运行中")
                        }
                        Spacer()
                        Button("刷新") { viewModel.refreshRadarQuery(query) }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("refreshRadarQuery-\(query.id.uuidString)")
                        if query.isPaused {
                            Button("继续") {
                                viewModel.setRadarQueryPaused(query, paused: false)
                                queryInteractionRevision &+= 1
                            }
                                .buttonStyle(.link)
                                .accessibilityIdentifier("resumeRadarQuery-\(query.id.uuidString)")
                        } else {
                            Button("暂停") {
                                viewModel.setRadarQueryPaused(query, paused: true)
                                queryInteractionRevision &+= 1
                            }
                                .buttonStyle(.link)
                                .accessibilityIdentifier("pauseRadarQuery-\(query.id.uuidString)")
                        }
                        Button("删除", role: .destructive) { viewModel.deleteRadarQuery(query.id) }
                            .buttonStyle(.link)
                    }
                    // A query keeps its durable UUID across a pause/resume,
                    // but the action surface must still be reconstructed so
                    // macOS accessibility publishes the new control label.
                    .id("\(query.id.uuidString):\(query.isPaused)")
                }
                // List row identity is intentionally broader than the durable
                // UUID: an unchanged query ID with a changed pause state must
                // rebuild its accessibility action on macOS.
                .id("\(savedQueryPresentationID):\(queryInteractionRevision)")
            }
            .padding()
            .frame(minWidth: 280, maxWidth: 340)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("研究雷达事件").font(.headline)
                    Spacer()
                    Text("仅来自两次带时间戳的 INSPIRE 快照差异")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if events.isEmpty {
                    ContentUnavailableView("暂无变化", systemImage: "dot.radiowaves.left.and.right", description: Text("完成一次本地/INSPIRE 同步后，记录差异会出现在这里。"))
                } else {
                    List(events) { event in
                        RadarEventRow(event: event, paper: viewModel.workbenchSnapshot.papers[event.paperID]) {
                            viewModel.acknowledgeRadarEvent(event.id)
                        }
                    }
                }
            }
            .padding()
        }
    }
}

private struct RadarEventRow: View {
    let event: RadarEvent
    let paper: Paper?
    let acknowledge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(event.eventKind.displayNameZH, systemImage: event.isAcknowledged ? "checkmark.circle" : "bell.badge")
                Text("论文 \(event.paperID)").font(.caption).foregroundStyle(.secondary)
                Text(event.isAcknowledged ? "已确认" : "待确认")
                    .font(.caption2)
                    .accessibilityIdentifier("radarEventAcknowledgement-\(event.id.uuidString)")
                    .accessibilityValue(event.isAcknowledged ? "acknowledged" : "unacknowledged")
                    .id("radar-acknowledgement-\(event.id.uuidString)-\(event.isAcknowledged)")
                Spacer()
                if !event.isAcknowledged {
                    Button("确认") { acknowledge() }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("acknowledgeRadarEvent-\(event.id.uuidString)")
                }
            }
            ForEach(event.changedFields.compactMap(V4RadarFieldChange.decodeStorageMarker), id: \.semanticKey) { change in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(change.field) · \(change.kind.displayNameZH)").font(.caption).bold()
                    LocalMarkdownTeXInlineText(source: "之前：\(change.beforeDisplay ?? "∅")")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    LocalMarkdownTeXInlineText(source: "之后：\(change.afterDisplay ?? "∅")")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    Text("批次 \(change.batchID.uuidString.prefix(8)) · \(change.sourceURL.absoluteString)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                .accessibilityIdentifier("radarFieldDiff-\(change.paperID)-\(change.field)")
            }
            if let paper {
                LocalMarkdownTeXInlineText(source: paper.displayTitle).lineLimit(2)
            } else {
                Text("本地未找到论文元数据").lineLimit(2)
            }
            Text("变化：\(event.changedFields.filter { V4RadarFieldChange.decodeStorageMarker($0) == nil }.joined(separator: ", ")) · 观察时间 \(event.observedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("之前 \(event.beforeHash?.prefix(12) ?? "无")")
                Text("之后 \(event.afterHash.prefix(12))")
                if event.changedFields.compactMap(V4RadarFieldChange.decodeStorageMarker).contains(where: { $0.field == "citationCount" }) {
                    Text("引用 \(event.beforeCitationCount.map(String.init) ?? "无") → \(event.afterCitationCount.map(String.init) ?? "无")")
                }
                Link("来源", destination: event.sourceURL)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("radarEvent-\(event.id.uuidString)")
    }
}

private struct CompareWorkbenchTab: View {
    @ObservedObject var viewModel: AppViewModel
    let dismissWorkbench: () -> Void
    @State private var selectedPaperIDs: Set<Int> = []
    @State private var workspaceName = "新建对照工作区"
    @State private var selectedWorkspaceID: UUID?
    @State private var inspectorCell: PhysicsContractCell?
    @State private var previewAnchor: EvidenceAnchor?

    private var papers: [Paper] { viewModel.workbenchSnapshot.papers.values.sorted { $0.displayTitle < $1.displayTitle } }
    private var workspaces: [PaperWorkspace] { viewModel.workbenchSnapshot.workspaces.values.sorted { $0.updatedAt > $1.updatedAt } }
    private var selectedWorkspace: PaperWorkspace? { workspaces.first { $0.id == selectedWorkspaceID } ?? workspaces.first }
    private var cells: [PhysicsContractCell] {
        guard let workspace = selectedWorkspace else { return [] }
        return viewModel.workbenchSnapshot.physicsContractCells.values.filter { $0.workspaceID == workspace.id }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("选择 2–6 篇论文")
                    .font(.headline)
                    .accessibilityIdentifier("comparePaperSetRequirement")
                List(papers) { paper in
                    HStack(alignment: .top, spacing: 8) {
                        Button(selectedPaperIDs.contains(paper.literatureID) ? "移出" : "加入") {
                            if selectedPaperIDs.contains(paper.literatureID) {
                                selectedPaperIDs.remove(paper.literatureID)
                            } else {
                                selectedPaperIDs.insert(paper.literatureID)
                            }
                        }
                        .accessibilityIdentifier("toggleComparePaper-\(paper.literatureID)")
                        .accessibilityValue(selectedPaperIDs.contains(paper.literatureID) ? "已选择" : "未选择")
                        LocalMarkdownTeXInlineText(source: paper.displayTitle).lineLimit(2)
                    }
                }
                TextField("对照工作区名称", text: $workspaceName).textFieldStyle(.roundedBorder)
                Button("创建对照工作区") {
                    viewModel.createCompareWorkspace(name: workspaceName, paperIDs: Array(selectedPaperIDs).sorted())
                    selectedPaperIDs.removeAll()
                }
                .disabled(!(2...6).contains(selectedPaperIDs.count))
                .accessibilityIdentifier("createCompareWorkspace")
                Text("当前选择：\(selectedPaperIDs.count) · 原文直接支持的单元必须带同一论文锚点；缺失保持未知")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .frame(minWidth: 300, maxWidth: 360)
            VStack(alignment: .leading, spacing: 8) {
                if workspaces.isEmpty {
                    ContentUnavailableView("尚无工作区", systemImage: "square.split.2x1", description: Text("从左侧选择论文创建可回查的物理契约。"))
                } else {
                    Picker("工作区", selection: Binding(get: { selectedWorkspace?.id }, set: { selectedWorkspaceID = $0 })) {
                        ForEach(workspaces) { workspace in Text(workspace.name).tag(Optional(workspace.id)) }
                    }
                    .accessibilityIdentifier("compareWorkspacePicker")
                    if let workspace = selectedWorkspace {
                        Text("确定性规则只接受当前论文的明确格式；无法确认的作用量、ensemble、傅里叶约定或重整化信息保持缺失。")
                            .font(.caption).foregroundStyle(.secondary)
                        if let inspectorCell {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("检查器已选中：\(PhysicsContract.displayNameZH(for: inspectorCell.rowKey)) · 论文 \(inspectorCell.paperID)")
                                    .font(.caption)
                                    .accessibilityIdentifier("physicsCellInspectorSelection")
                                ForEach(inspectorCell.evidenceAnchorIDs, id: \.self) { anchorID in
                                    if let anchor = viewModel.workbenchSnapshot.evidenceAnchors[anchorID] {
                                        let anchorLocation = anchor.page.map { "第 " + String($0) + " 页" } ?? "元数据"
                                        Button("打开 \(anchor.sourceKind.displayNameZH) \(anchorLocation)") {
                                            // This compact inspector strip stays
                                            // visible above the scrollable
                                            // matrix. It exposes exactly the
                                            // Keep the PDF preview inside this
                                            // evidence inspector. Presenting a
                                            // second sheet while the Workbench
                                            // is dismissing is unreliable on
                                            // macOS and can consume the exact
                                            // anchor without rendering it.
                                            previewAnchor = anchor
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityIdentifier("physicsCellAnchor-\(inspectorCell.paperID)-\(inspectorCell.rowKey)-\(anchor.id)")
                                    }
                                }
                            }
                            .padding(6)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                        }
                        HStack(spacing: 12) {
                            PhysicsMatrix(workspace: selectedWorkspace, cells: cells) { cell in
                                inspectorCell = cell
                                previewAnchor = nil
                            }
                                // The matrix remains scrollable while the
                                // inspector is open. Giving it a bounded
                                // viewport reserves an actual visible column
                                // for the selected evidence instead of laying
                                // that column out beyond the sheet edge.
                                .frame(width: inspectorCell == nil ? nil : 260)
                                .frame(maxHeight: .infinity)
                            if let previewAnchor {
                                Divider()
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("全文第 \(previewAnchor.page ?? 0) 页")
                                            .font(.headline)
                                            .accessibilityIdentifier("pdfAnchorPreviewPageTitle-\(previewAnchor.page ?? 0)")
                                        Spacer()
                                        Button("返回单元检查器") { self.previewAnchor = nil }
                                            .accessibilityIdentifier("closeComparePDFAnchorPreview")
                                    }
                                    PDFAnchorPreview(
                                        document: viewModel.workbenchSnapshot.fullTextDocuments.values
                                            .filter { $0.paperID == previewAnchor.paperID }
                                            .sorted { ($0.downloadedAt ?? .distantPast) > ($1.downloadedAt ?? .distantPast) }
                                            .first,
                                        anchor: previewAnchor,
                                        compact: true
                                    )
                                }
                                .frame(minWidth: 300, maxWidth: 460, maxHeight: .infinity)
                            } else if let inspectorCell {
                                Divider()
                                PhysicsCellInspector(
                                    cell: inspectorCell,
                                    snapshot: viewModel.workbenchSnapshot,
                                    updateCell: { viewModel.updatePhysicsCell($0) },
                                    close: { self.inspectorCell = nil },
                                    openPaper: {
                                        viewModel.selectPaper(inspectorCell.paperID)
                                        dismissWorkbench()
                                    },
                                    openAnchor: { anchor in
                                        previewAnchor = anchor
                                    }
                                )
                                .frame(minWidth: 300, maxWidth: 360, maxHeight: .infinity)
                            }
                        }
                        HStack {
                            Button("仅用本地锚点提取") { viewModel.extractLocalCompareWorkspace(workspace.id) }
                                .accessibilityIdentifier("extractLocalCompare")
                            Spacer()
                            Text("仅更新已通过同一论文锚点验证的完整矩阵。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let status = viewModel.compareExtractionStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(status.hasPrefix("已") ? Color.secondary : Color.orange)
                                .accessibilityIdentifier("compareExtractionStatus")
                        }
                    }
                }
            }
            .padding()
        }
    }
}

private struct PhysicsMatrix: View {
    let workspace: PaperWorkspace?
    let cells: [PhysicsContractCell]
    let inspect: (PhysicsContractCell) -> Void

    private var rowKeys: [String] { PhysicsContract.defaultRows }
    private var paperIDs: [Int] { workspace?.sortOrder ?? [] }
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("物理约束矩阵").bold().frame(width: 140, alignment: .leading)
                    ForEach(paperIDs, id: \.self) { Text("论文 \($0)").bold().frame(width: 120, alignment: .leading) }
                }
                ForEach(rowKeys, id: \.self) { rowKey in
                    GridRow {
                        Text(PhysicsContract.displayNameZH(for: rowKey)).font(.caption).frame(width: 140, alignment: .leading)
                        ForEach(paperIDs, id: \.self) { paperID in
                            let cell = cells.first { $0.rowKey == rowKey && $0.paperID == paperID }
                            let displayValue = [cell?.value, cell?.unit].compactMap { $0 }.joined(separator: " ")
                            let state = cell?.status.displayNameZH ?? "缺失"
                            Button {
                                if let cell { inspect(cell) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    LocalMarkdownTeXInlineText(source: displayValue.isEmpty ? "未知" : displayValue)
                                        .accessibilityIdentifier("physicsCellValue-\(rowKey)-\(paperID)")
                                    Text(state).font(.caption2)
                                        .accessibilityIdentifier("physicsCellState-\(rowKey)-\(paperID)")
                                    if !(cell?.evidenceAnchorIDs.isEmpty ?? true) { Label("证据锚点", systemImage: "link") }
                                }
                                // Keep a two-paper Compare matrix legible in
                                // the 1120 pt minimum-width workbench. Larger
                                // paper sets retain horizontal scrolling,
                                // rather than pushing every evidence action
                                // into the rightmost edge of the sheet.
                                .frame(width: 120, alignment: .leading)
                                .padding(6)
                                .background((cell?.status == .missing ? Color.gray.opacity(0.1) : Color.blue.opacity(0.1)), in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("physicsCell-\(rowKey)-\(paperID)")
                            .accessibilityLabel("\(PhysicsContract.displayNameZH(for: rowKey)) 论文 \(paperID) \(displayValue.isEmpty ? "未知" : displayValue) \(state)")
                            .accessibilityValue("\(state)：\(displayValue.isEmpty ? "未知" : displayValue)")
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.visible)
        .accessibilityLabel("论文物理约束对照矩阵")
    }
}

private struct PhysicsCellInspector: View {
    let cell: PhysicsContractCell
    let snapshot: LibrarySnapshot
    let updateCell: (PhysicsContractCell) -> Void
    let close: () -> Void
    let openPaper: () -> Void
    let openAnchor: (EvidenceAnchor) -> Void
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("物理单元")
                    .font(.title3)
                    // A VStack used as the root of a nested SwiftUI sheet is
                    // not consistently surfaced as an AX element on macOS.
                    // Keep the inspector's semantic identity on its visible
                    // title so both assistive technology and XCUIApplication
                    // can establish that the evidence inspector—not merely a
                    // generic sheet—was opened.
                    .accessibilityIdentifier("physicsCellInspectorTitle")
                Spacer()
                Button("关闭") { close() }
            }
            Text(PhysicsContract.displayNameZH(for: cell.rowKey)).font(.headline)
            LocalMarkdownTeXInlineText(source: "论文 \(cell.paperID) · \(cell.status.displayNameZH) · \(cell.value ?? "未知") \(cell.unit ?? "")")
            Text("提取版本：\(cell.extractionVersion)").font(.caption).foregroundStyle(.secondary)
            if cell.evidenceAnchorIDs.isEmpty {
                Label("无锚点：该值保持缺失/未知，不能回查。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                ForEach(cell.evidenceAnchorIDs, id: \.self) { id in
                    if let anchor = snapshot.evidenceAnchors[id] {
                        VStack(alignment: .leading) {
                            Button("\(anchor.sourceKind.displayNameZH) \(anchor.page.map { "第 \($0) 页" } ?? "元数据")") {
                                openAnchor(anchor)
                            }
                            .buttonStyle(.link)
                            // The row and paper make this automation-facing
                            // identity stable across an atomic matrix refresh;
                            // the concrete evidence ID remains suffixed so a
                            // multi-anchor cell cannot collapse distinct links.
                            .accessibilityIdentifier("physicsCellAnchor-\(cell.paperID)-\(cell.rowKey)-\(anchor.id)")
                        LocalMarkdownTeXText(source: anchor.quote).lineLimit(4)
                        }
                    } else {
                        Text("失效锚点 \(id)").foregroundStyle(.orange)
                    }
                }
            }
            HStack {
                Button("编辑物理单元") { editing = true }
                Button("跳到原文 / 论文") { openPaper(); close() }
            }
                .accessibilityIdentifier("physicsCellOpenSource")
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("physicsCellInspector")
        .sheet(isPresented: $editing) {
            PhysicsCellEditor(cell: cell, anchors: snapshot.evidenceAnchors.values.filter { $0.paperID == cell.paperID }.sorted { $0.id < $1.id }) { edited in
                updateCell(edited); editing = false
            }
        }
    }
}

private struct PhysicsCellEditor: View {
    let cell: PhysicsContractCell
    let anchors: [EvidenceAnchor]
    let save: (PhysicsContractCell) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value: String
    @State private var unit: String
    @State private var status: PhysicsCellStatus
    @State private var anchorIDs: String

    init(cell: PhysicsContractCell, anchors: [EvidenceAnchor], save: @escaping (PhysicsContractCell) -> Void) {
        self.cell = cell; self.anchors = anchors; self.save = save
        _value = State(initialValue: cell.value ?? "")
        _unit = State(initialValue: cell.unit ?? "")
        _status = State(initialValue: cell.status)
        _anchorIDs = State(initialValue: cell.evidenceAnchorIDs.joined(separator: ","))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("编辑 \(PhysicsContract.displayNameZH(for: cell.rowKey))").font(.title3)
            Picker("状态", selection: $status) { ForEach(PhysicsCellStatus.allCases, id: \.self) { Text($0.displayNameZH).tag($0) } }
            TextField("数值（缺失时留空）", text: $value).textFieldStyle(.roundedBorder)
            TextField("单位", text: $unit).textFieldStyle(.roundedBorder)
            TextField("锚点 ID（逗号分隔）", text: $anchorIDs).textFieldStyle(.roundedBorder)
            Text("可用锚点：\(anchors.count)；原文直接支持／基于原文的推断必须选择同一论文锚点；无数值的限制说明可不带锚点，有数值时同样必须可回查。")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("验证并保存") {
                let ids = anchorIDs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                var edited = cell; edited.value = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
                edited.unit = unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : unit
                edited.status = status; edited.evidenceAnchorIDs = ids; edited.updatedAt = Date()
                save(edited); dismiss()
            }.keyboardShortcut(.defaultAction) }
        }.padding().frame(width: 560, height: 300)
    }
}

private struct NotebookWorkbenchTab: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var selectedPaperIDs: Set<Int> = []
    @State private var format: V3ExportFormat = .markdownNotebook
    @State private var document: WorkbenchTextDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var importDryRun: V3ImportResult?
    @State private var editingAnnotation: UserEvidenceAnchor?
    @State private var reviewingImportConflict: V3ImportConflict?
    // Present Notebook editing inside the already-presented Workbench sheet.
    // A second SwiftUI `.sheet` from this tab reliably broke the macOS AX
    // connection on the current SDK (the AUT stayed alive, but VoiceOver and
    // XCUITest lost the application after tapping "新建 notebook entry…").
    // Keeping this explicit local presentation state preserves the draft-only
    // transaction while avoiding a nested modal accessibility tree.
    @State private var presentingNotebookEditor = false
    @State private var editingNotebookEntry: NotebookEntry?

    private var papers: [Paper] { viewModel.workbenchSnapshot.papers.values.sorted { $0.displayTitle < $1.displayTitle } }
    var body: some View {
        if presentingNotebookEditor {
            NotebookEntryEditor(entry: editingNotebookEntry, snapshot: viewModel.workbenchSnapshot,
                                cancel: closeNotebookEditor) { id, paperID, title, body, anchorIDs in
                viewModel.saveNotebookEntry(id: id, paperID: paperID, title: title, body: body, anchorIDs: anchorIDs)
                closeNotebookEditor()
            }
        } else {
            notebookIndex
        }
    }

    private var notebookIndex: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("证据笔记本 / 可移植导出").font(.headline)
            Text("仅导出用户选择的本地记录；默认不写入本机 PDF 绝对路径。RIS/CSL 缺失字段保持缺失。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("格式", selection: $format) { ForEach(V3ExportFormat.allCases, id: \.self) { Text($0.displayNameZH).tag($0) } }
                Button("导出…") { prepareExport() }
                    .disabled(selectedPaperIDs.isEmpty)
                    .accessibilityIdentifier("workbenchExport")
                Button("导入 BibTeX / RIS / CSL…") { importing = true }
                    .accessibilityIdentifier("workbenchImport")
                Button("新建笔记本条目…") {
                    editingNotebookEntry = nil
                    presentingNotebookEditor = true
                }
                    .disabled(papers.isEmpty)
                    .accessibilityIdentifier("createNotebookEntry")
            }
            // Keep the most recent annotation's real edit/delete actions in
            // the primary viewport.  The full annotation List below remains
            // the complete notebook, but a long paper selection list must not
            // push every mutation behind an inaccessible scroll boundary.
            if let mostRecentAnnotation = viewModel.workbenchSnapshot.userEvidenceAnchors.values.max(by: { $0.updatedAt < $1.updatedAt }) {
            GroupBox("最近标注") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            LocalMarkdownTeXInlineText(source: mostRecentAnnotation.label)
                                // The primary viewport is the actionable
                                // Notebook summary. Keep its label readable
                                // to assistive clients after an in-place edit
                                // instead of making them traverse the long
                                // annotation List below.
                                .accessibilityIdentifier("annotationPrimaryLabel-\(mostRecentAnnotation.id.uuidString)")
                                .accessibilityValue(mostRecentAnnotation.label)
                            Text("\(mostRecentAnnotation.status.displayNameZH) · 论文 \(mostRecentAnnotation.paperID)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("编辑") { editingAnnotation = mostRecentAnnotation }
                            .accessibilityIdentifier("editAnnotation-\(mostRecentAnnotation.id.uuidString)")
                        Button("删除", role: .destructive) { viewModel.deleteUserAnnotation(mostRecentAnnotation.id) }
                            .accessibilityIdentifier("deleteAnnotation-\(mostRecentAnnotation.id.uuidString)")
                    }
                }
            }
            let entries = viewModel.workbenchSnapshot.notebookEntries.values.sorted { lhs, rhs in
                lhs.updatedAt == rhs.updatedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.updatedAt > rhs.updatedAt
            }
            GroupBox("笔记本条目 · 多锚点") {
                if entries.isEmpty {
                    Text("尚无笔记本条目。新建后可为同一篇论文选择多个标注/证据锚点，并以用户选择的顺序保存。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    List(entries) { entry in
                        let linkCount = viewModel.workbenchSnapshot.notebookAnchorLinks.filter { $0.entryID == entry.id }.count
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                LocalMarkdownTeXInlineText(source: entry.title)
                                Text("论文 \(entry.paperID) · \(linkCount) 个锚点 · \(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if !entry.body.isEmpty { LocalMarkdownTeXInlineText(source: entry.body).lineLimit(1).font(.caption) }
                            }
                            Spacer()
                            Button("编辑") {
                                editingNotebookEntry = entry
                                presentingNotebookEditor = true
                            }
                                .buttonStyle(.link)
                                .accessibilityIdentifier("editNotebookEntry-\(entry.id.uuidString)")
                            Button("删除", role: .destructive) { viewModel.deleteNotebookEntry(entry.id) }
                                .buttonStyle(.link)
                                .accessibilityIdentifier("deleteNotebookEntry-\(entry.id.uuidString)")
                        }
                        .accessibilityIdentifier("notebookEntryRow-\(entry.id.uuidString)")
                        // The title pins this row's semantic identity while
                        // the value communicates its separately durable link
                        // count.  This prevents a pre-existing fixture entry
                        // from satisfying a newly saved-entry assertion.
                        .accessibilityLabel(entry.title)
                        .accessibilityValue("\(linkCount) 个锚点")
                    }
                    .frame(minHeight: 96, maxHeight: 180)
                }
            }
            List(papers, selection: $selectedPaperIDs) { paper in
                LocalMarkdownTeXInlineText(source: paper.displayTitle).lineLimit(2).tag(paper.literatureID)
            }
            if !viewModel.workbenchSnapshot.exportRecords.isEmpty {
            GroupBox("导出来源记录") {
                    ForEach(viewModel.workbenchSnapshot.exportRecords.values.sorted { $0.createdAt > $1.createdAt }) { record in
                        HStack {
                            Text(record.format.displayNameZH)
                            Text(record.payloadHash.prefix(12)).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2)
                        }
                    }
                }
            }
            if !viewModel.workbenchSnapshot.importConflicts.isEmpty {
                GroupBox("导入冲突 · 需要审阅") {
                    ForEach(viewModel.workbenchSnapshot.importConflicts.values.sorted { $0.paperID < $1.paperID }, id: \.importedID) { conflict in
                        HStack {
                            Text("论文 \(conflict.paperID)：\(conflict.fields.joined(separator: ", "))")
                            Spacer(); Text(conflict.status.displayNameZH).font(.caption)
                            if conflict.status == .pending {
                                Button("审阅字段…") { reviewingImportConflict = conflict }
                                    .accessibilityIdentifier("reviewImportConflict-\(conflict.importedID.uuidString)")
                                Button("拒绝") { viewModel.setImportConflictStatus(conflict, status: .rejected) }
                            } else if conflict.status == .accepted {
                                Text("已合并：\(conflict.acceptedFields.joined(separator: ", "))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let dryRun = importDryRun {
                GroupBox("导入预演 · 尚未写入资料库") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("记录 \(dryRun.records.count) · 冲突 \(dryRun.conflicts.count)")
                        if dryRun.conflicts.isEmpty {
                            Text("没有字段冲突；仍需确认后才写入来源记录。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(dryRun.conflicts, id: \.importedID) { conflict in
                                    Text("论文 \(conflict.paperID)：\(conflict.fields.joined(separator: ", ")) · 待审阅")
                                    .font(.caption)
                            }
                        }
                        HStack {
                            Button("取消预演") { importDryRun = nil }
                            Button("确认写入导入记录") {
                                viewModel.commitNotebookImport(dryRun)
                                importDryRun = nil
                            }
                            .accessibilityIdentifier("commitNotebookImport")
                        }
                    }
                }
            }
            let annotations = viewModel.workbenchSnapshot.userEvidenceAnchors.values.sorted { $0.updatedAt > $1.updatedAt }
            if !annotations.isEmpty {
                GroupBox("本地标注") {
                    List(annotations) { annotation in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                        LocalMarkdownTeXInlineText(source: annotation.label)
                                Text(annotation.status.displayNameZH).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("编辑") { editingAnnotation = annotation }
                                    .buttonStyle(.link)
                                    .accessibilityIdentifier("editAnnotation-\(annotation.id.uuidString)")
                                Button("删除", role: .destructive) { viewModel.deleteUserAnnotation(annotation.id) }
                                    .buttonStyle(.link)
                                    .accessibilityIdentifier("deleteAnnotation-\(annotation.id.uuidString)")
                            }
                        Text("论文 \(annotation.paperID) · \(annotation.sourceKind.displayNameZH) \(annotation.page.map { "p\($0)" } ?? "元数据") · 范围 \(annotation.characterRangeStart.map(String.init) ?? "—")–\(annotation.characterRangeEnd.map(String.init) ?? "—")")
                                .font(.caption2).foregroundStyle(.secondary)
                            LocalMarkdownTeXInlineText(source: annotation.quote).lineLimit(2)
                        }
                        .accessibilityIdentifier("annotationRow-\(annotation.id.uuidString)")
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                }
            }
        }
        .padding()
        .fileExporter(isPresented: $exporting, document: document, contentType: format == .cslJSON || format == .provenanceJSON ? .json : .plainText,
                      defaultFilename: "LatticeLens-notebook") { result in
            viewModel.finishWorkbenchExport(result)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .json], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let ext = url.pathExtension.lowercased()
            let importFormat: V3ExportFormat = ext == "ris" ? .ris : (ext == "json" || ext == "csl" ? .cslJSON : .bibtex)
            Task {
                do { importDryRun = try await viewModel.dryRunNotebookImport(url: url, format: importFormat) }
                catch { viewModel.reportUserError("Bibliography 导入预检失败：\(error.localizedDescription)") }
            }
        }
        .sheet(item: $editingAnnotation) { annotation in
            AnnotationEditor(annotation: annotation, save: viewModel.updateUserAnnotation)
        }
        .sheet(item: $reviewingImportConflict) { conflict in
            ImportConflictReviewSheet(conflict: conflict) { acceptedFields in
                viewModel.acceptImportConflict(conflict, acceptedFields: acceptedFields)
            }
        }
    }

    private func closeNotebookEditor() {
        presentingNotebookEditor = false
        editingNotebookEntry = nil
    }

    private func prepareExport() {
        Task {
            guard let text = await viewModel.prepareWorkbenchExport(paperIDs: Array(selectedPaperIDs).sorted(), format: format) else { return }
            document = WorkbenchTextDocument(text: text)
            exporting = true
        }
    }
}

private struct NotebookAnchorChoice: Identifiable, Hashable {
    let id: String
    let label: String
    let detail: String
}

/// A draft-only editor: changing fields, paper, selected anchors, or their
/// order is entirely local until the explicit Save action.  This matters for
/// a notebook because otherwise a Cancel could quietly rewrite provenance.
private struct NotebookEntryEditor: View {
    let entry: NotebookEntry?
    let snapshot: LibrarySnapshot
    let cancel: () -> Void
    let save: (UUID?, Int, String, String, [String]) -> Void
    @State private var title: String
    @State private var bodyText: String
    @State private var paperFilter = ""
    @State private var selectedPaperID: Int?
    @State private var selectedAnchorIDs: [String]

    init(entry: NotebookEntry?, snapshot: LibrarySnapshot,
         cancel: @escaping () -> Void,
         save: @escaping (UUID?, Int, String, String, [String]) -> Void) {
        self.entry = entry
        self.snapshot = snapshot
        self.cancel = cancel
        self.save = save
        _title = State(initialValue: entry?.title ?? AppLaunchConfiguration.fixtureInitialNotebookEntryTitle ?? "")
        _bodyText = State(initialValue: entry?.body ?? "")
        _selectedPaperID = State(initialValue: entry?.paperID)
        _selectedAnchorIDs = State(initialValue: snapshot.notebookAnchorLinks
            .filter { $0.entryID == entry?.id }
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(\.anchorID))
    }

    private var papers: [Paper] {
        snapshot.papers.values.sorted { lhs, rhs in
            lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }
    }

    private var filteredPapers: [Paper] {
        let query = SearchNormalizer.normalize(paperFilter)
        guard !query.isEmpty else { return papers }
        return papers.filter { paper in
            SearchNormalizer.normalize(paper.displayTitle).contains(query) || String(paper.literatureID).contains(query)
        }
    }

    private var selectedPaper: Paper? {
        selectedPaperID.flatMap { snapshot.papers[$0] }
    }

    private var availableAnchors: [NotebookAnchorChoice] {
        guard let paperID = selectedPaperID else { return [] }
        let evidence = snapshot.evidenceAnchors.values.compactMap { anchor -> NotebookAnchorChoice? in
            guard anchor.paperID == paperID, !snapshot.quarantinedEvidenceIDs.contains(anchor.id),
                  StableHash.sha256(anchor.quote) == anchor.quoteHash else { return nil }
            let location = anchor.page.map { "第 \($0) 页" } ?? anchor.sourceKind.displayNameZH
            return NotebookAnchorChoice(id: anchor.id, label: "证据 · \(location)", detail: anchor.quote)
        }
        let annotations = snapshot.userEvidenceAnchors.values.compactMap { annotation -> NotebookAnchorChoice? in
            guard annotation.paperID == paperID, annotation.status == .valid,
                  StableHash.sha256(annotation.quote) == annotation.quoteHash else { return nil }
            let location = annotation.page.map { "第 \($0) 页" } ?? annotation.sourceKind.displayNameZH
            return NotebookAnchorChoice(id: annotation.id.uuidString, label: "标注 · \(annotation.label) · \(location)", detail: annotation.quote)
        }
        return (evidence + annotations).sorted { lhs, rhs in
            lhs.label == rhs.label ? lhs.id < rhs.id : lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    private var selectedAnchorsAreValid: Bool {
        let availableIDs = Set(availableAnchors.map(\.id))
        return selectedAnchorIDs.allSatisfy(availableIDs.contains)
    }

    private func displayName(for anchorID: String) -> String {
        availableAnchors.first { $0.id == anchorID }?.label ?? "锚点不可用或已过期 · \(anchorID.prefix(12))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry == nil ? "新建笔记本条目" : "编辑笔记本条目").font(.title3)
            Text("条目只能连接同一篇论文的有效证据/标注；顺序是可审计的持久化字段。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("标题", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("notebookEntryTitle")
                    GroupBox("论文") {
                        VStack(alignment: .leading, spacing: 6) {
                            if let selectedPaper {
                                HStack(spacing: 4) {
                                    Text("当前：")
                                    LocalMarkdownTeXInlineText(source: selectedPaper.displayTitle)
                                    Text("[\(selectedPaper.literatureID)]")
                                }
                                    .font(.caption)
                                    // Publish a stable state announcement so
                                    // assistive clients can verify that the
                                    // native picker action changed this draft
                                    // before its anchor choices are exposed.
                                    .accessibilityIdentifier("notebookSelectedPaper")
                                    .accessibilityLabel("笔记本当前论文")
                                    // The record ID remains in the visible selected-paper
                                    // text. Do not publish it as a bare accessibility value:
                                    // AppKit localizes digit sequences (for example,
                                    // `1234567` to `1,234,567`), which makes selection
                                    // announcements locale-dependent. Each paper row below
                                    // exposes its stable selected/not-selected state beside
                                    // its own visible INSPIRE record ID.
                                    .accessibilityValue("selected")
                            } else {
                                Text("必须选择一篇论文。更改论文会清空未保存的锚点草稿。")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("notebookSelectedPaper")
                                    .accessibilityLabel("笔记本当前论文")
                                    .accessibilityValue("none")
                            }
                            TextField("筛选标题或 INSPIRE 记录 ID", text: $paperFilter)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("notebookPaperFilter")
                            // A notebook may span the whole local library.
                            // Keep paper selection in its own bounded native
                            // scrolling region; an unbounded LazyVStack in
                            // the editor's outer ScrollView can move every
                            // paper button (and the following anchors) below
                            // the sheet fold on a real macOS window.
                            ScrollView(.vertical, showsIndicators: true) {
                                LazyVStack(alignment: .leading, spacing: 3) {
                                    ForEach(filteredPapers, id: \.literatureID) { paper in
                                        Button { selectPaper(paper) } label: {
                                            HStack {
                                                Image(systemName: selectedPaperID == paper.literatureID ? "checkmark.circle.fill" : "circle")
                                                Text("[\(paper.literatureID)]")
                                                LocalMarkdownTeXInlineText(source: paper.displayTitle).lineLimit(1)
                                                Spacer()
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .contentShape(Rectangle())
                                        .accessibilityIdentifier("notebookPaper-\(paper.literatureID)")
                                        .accessibilityValue(selectedPaperID == paper.literatureID ? "selected" : "not selected")
                                        // `ButtonStyle.plain` inside two
                                        // scroll regions can otherwise lose
                                        // an accessibility press on current
                                        // macOS. Route pointer and AX presses
                                        // through the same idempotent action.
                                        .simultaneousGesture(TapGesture().onEnded { selectPaper(paper) })
                                        .accessibilityAction(.default) { selectPaper(paper) }
                                    }
                                }
                            }
                            .frame(minHeight: 92, maxHeight: 150)
                            .scrollIndicators(.visible)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("notebookPapersScrollableList")
                            .accessibilityLabel("笔记本论文选择列表")
                        }
                    }
                    GroupBox("已选锚点 · 稳定顺序") {
                        if selectedAnchorIDs.isEmpty {
                            Text("可留空；选择后可用上下按钮确定进入笔记本的稳定顺序。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(selectedAnchorIDs.enumerated()), id: \.element) { pair in
                                    HStack {
                                        Text("\(pair.offset + 1). \(displayName(for: pair.element))").lineLimit(1)
                                        Spacer()
                                        Button("↑") { moveAnchor(at: pair.offset, by: -1) }.disabled(pair.offset == 0)
                                        Button("↓") { moveAnchor(at: pair.offset, by: 1) }.disabled(pair.offset + 1 == selectedAnchorIDs.count)
                                        Button("移除", role: .destructive) { selectedAnchorIDs.removeAll { $0 == pair.element } }
                                    }
                                }
                            }
                        }
                        if !selectedAnchorsAreValid {
                            Text("有选中的锚点已失效、隔离或不属于当前论文。移除它后才能保存；不会进行模糊重定位。")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                    if selectedPaperID != nil {
                        GroupBox("可用的有效锚点") {
                            if availableAnchors.isEmpty {
                            Text("该论文暂无可用锚点。可先在全文或证据页面创建。")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("已选择 \(selectedAnchorIDs.count) 个锚点")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier("notebookSelectedAnchorCount")
                                        .accessibilityLabel("笔记本草稿锚点数量")
                                        .accessibilityValue("\(selectedAnchorIDs.count)")
                                    ScrollView(.vertical, showsIndicators: true) {
                                        LazyVStack(alignment: .leading, spacing: 7) {
                                            ForEach(availableAnchors) { anchor in
                                                // Capture the rendered state once. Both the native button and
                                                // the supplemental tap gesture below can then request the same
                                                // idempotent transition, rather than racing two `toggle` calls
                                                // back to the original state in nested macOS scroll views.
                                                let isSelected = selectedAnchorIDs.contains(anchor.id)
                                                Button { setAnchorSelection(anchor.id, selected: !isSelected) } label: {
                                                    HStack(alignment: .top, spacing: 8) {
                                                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                                        VStack(alignment: .leading, spacing: 2) {
                                    LocalMarkdownTeXInlineText(source: anchor.label).font(.caption)
                                    LocalMarkdownTeXInlineText(source: anchor.detail).lineLimit(2).font(.caption2).foregroundStyle(.secondary)
                                                        }
                                                        Spacer()
                                                    }
                                                }
                                                .buttonStyle(.plain)
                                                .contentShape(Rectangle())
                                                .accessibilityIdentifier("notebookAnchor-\(anchor.id)")
                                                // A plain SwiftUI button otherwise exposes only its label to
                                                // VoiceOver.  Make the draft selection explicit so keyboard and
                                                // UI-test clients can distinguish a completed anchor selection
                                                // from a merely reachable row before the transaction is saved.
                                                .accessibilityValue(isSelected ? "selected" : "unselected")
                                                // On the current macOS accessibility bridge a plain Button inside
                                                // two ScrollViews can synthesize a pointer event without invoking
                                                // its action. Route that event through the identical idempotent
                                                // transition used by pointer and keyboard activation.
                                                .simultaneousGesture(TapGesture().onEnded {
                                                    setAnchorSelection(anchor.id, selected: !isSelected)
                                                })
                                            }
                                        }
                                    }
                                    .frame(minHeight: 92, maxHeight: 170)
                                    // This is deliberately an independently navigable region,
                                    // not merely a visual stack inside the editor's outer
                                    // ScrollView.  In particular, retain the native scrolling
                                    // element in the macOS accessibility hierarchy so VoiceOver
                                    // and XCUIApplication can reach the same multi-anchor
                                    // choices without relying on the outer sheet's offset.
                                    .scrollIndicators(.visible)
                                    .accessibilityElement(children: .contain)
                                    .accessibilityIdentifier("notebookAnchorsScrollableList")
                                        .accessibilityLabel("可用的有效笔记本锚点")
                                }
                            }
                        }
                    }
                    GroupBox("条目正文") {
                        TextEditor(text: $bodyText)
                            .frame(minHeight: 150)
                            .border(.quaternary)
                            .accessibilityIdentifier("notebookEntryBody")
                    }
                }
                .padding(.vertical, 2)
            }
            HStack {
                Spacer()
                Button("取消") { cancel() }
                    .accessibilityIdentifier("cancelNotebookEntry")
                Button("保存") {
                    guard let paperID = selectedPaperID else { return }
                    save(entry?.id, paperID, title, bodyText, selectedAnchorIDs)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedPaperID == nil || !selectedAnchorsAreValid)
                .accessibilityIdentifier("saveNotebookEntry")
            }
        }
        .padding()
        // The editor lives within V3WorkbenchView's 820×640 minimum sheet.
        // Its middle content remains independently scrollable while the
        // Cancel/Save actions stay pinned, including at the narrow v5 gate.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func setAnchorSelection(_ anchorID: String, selected: Bool) {
        if selected {
            if !selectedAnchorIDs.contains(anchorID) {
                selectedAnchorIDs.append(anchorID)
            }
        } else {
            selectedAnchorIDs.removeAll { $0 == anchorID }
        }
    }

    private func selectPaper(_ paper: Paper) {
        if selectedPaperID != paper.literatureID { selectedAnchorIDs.removeAll() }
        selectedPaperID = paper.literatureID
    }

    private func moveAnchor(at index: Int, by offset: Int) {
        let destination = index + offset
        guard selectedAnchorIDs.indices.contains(index), selectedAnchorIDs.indices.contains(destination) else { return }
        selectedAnchorIDs.swapAt(index, destination)
    }
}

private struct AnnotationEditor: View {
    let annotation: UserEvidenceAnchor
    let save: (UserEvidenceAnchor) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var note: String
    @State private var color: String

    init(annotation: UserEvidenceAnchor, save: @escaping (UserEvidenceAnchor) -> Void) {
        self.annotation = annotation; self.save = save
        _label = State(initialValue: annotation.label); _note = State(initialValue: annotation.note); _color = State(initialValue: annotation.colorName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑标注").font(.title3)
            Text("论文 \(annotation.paperID) · 引文哈希 \(annotation.quoteHash.prefix(12))").font(.caption).foregroundStyle(.secondary)
            LocalMarkdownTeXText(source: annotation.quote).lineLimit(4)
            TextField("标签", text: $label)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("annotationEditorLabel")
            TextField("颜色", text: $color)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("annotationEditorColor")
            TextEditor(text: $note)
                .frame(minHeight: 100).border(.quaternary)
                .accessibilityIdentifier("annotationEditorNote")
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存") {
                var updated = annotation
                updated.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.colorName = color.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.note = note
                updated.updatedAt = Date()
                save(updated); dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("saveAnnotation") }
        }
        .padding().frame(width: 560, height: 360)
    }
}

private struct ImportConflictReviewSheet: View {
    let conflict: V3ImportConflict
    let merge: (Set<String>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var acceptedFields: Set<String>

    init(conflict: V3ImportConflict, merge: @escaping (Set<String>) -> Void) {
        self.conflict = conflict
        self.merge = merge
        _acceptedFields = State(initialValue: Set(conflict.fields))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("审阅书目冲突").font(.title3)
            Text("论文 \(conflict.paperID) · 仅合并并记录明确勾选的字段。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(conflict.fields, id: \.self) { field in
                        Toggle(field, isOn: Binding(
                            get: { acceptedFields.contains(field) },
                            set: { selected in
                                if selected { acceptedFields.insert(field) }
                                else { acceptedFields.remove(field) }
                            }
                        ))
                        .accessibilityIdentifier("acceptImportField-\(conflict.importedID.uuidString)-\(field)")
                    }
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("合并已选字段") {
                    merge(acceptedFields)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(acceptedFields.isEmpty)
                .accessibilityIdentifier("commitAcceptedImport-\(conflict.importedID.uuidString)")
            }
        }
        .padding()
        .frame(width: 520, height: 300)
    }
}

private struct GraphWorkbenchTab: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var rootPaperID: Int?
    @State private var rootAuthorID: Int?
    @State private var graph: V3GraphSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("有界引用 / 合作者关系图").font(.headline)
            Text("预览：尚未摄取新的边 · 仅显示当前本地快照中已有来源支持的关系；不会伪造缺失关系。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("论文", selection: $rootPaperID) {
                    Text("不选").tag(Optional<Int>.none)
                    ForEach(viewModel.workbenchSnapshot.papers.values.sorted { $0.literatureID < $1.literatureID }) { paper in
                        HStack(spacing: 4) {
                            Text("\(paper.literatureID) ·")
                            LocalMarkdownTeXInlineText(source: paper.displayTitle)
                        }.tag(Optional(paper.literatureID))
                    }
                }
                Picker("作者记录 ID", selection: $rootAuthorID) {
                    Text("不选").tag(Optional<Int>.none)
                    ForEach(viewModel.workbenchSnapshot.authors.values.sorted { $0.recid < $1.recid }) { author in
                        Text("\(author.recid) · \(author.preferredName)").tag(Optional(author.recid))
                    }
                }
                Button("扩展一跳") { graph = V3GraphBuilder.build(snapshot: viewModel.workbenchSnapshot, rootPaperID: rootPaperID, rootAuthorRecid: rootAuthorID) }
            }
            if let graph {
                HStack {
                    Text("论文：\(graph.paperIDs.count) · 作者：\(graph.authorRecids.count)")
                    Text("引用边：\(graph.citationEdges.count) · 合作者边：\(graph.coauthorEdges.count)")
                    if graph.truncated { Label("已限制范围 / 已截断", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }.font(.caption)
                List {
                    ForEach(graph.citationEdges) { edge in
                        VStack(alignment: .leading) {
                            Text("引用 \(edge.fromPaperID) → \(edge.toPaperID)")
                            HStack { Link(edge.sourceURL.absoluteString, destination: edge.sourceURL); Text(edge.fetchedAt.formatted(date: .abbreviated, time: .shortened)); Text(edge.batchID.uuidString.prefix(8)) }
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(graph.coauthorEdges) { edge in
                        VStack(alignment: .leading) {
                            Text("合作者 \(edge.authorRecid) — \(edge.coauthorRecid)（论文 \(edge.sourcePaperID)）")
                            HStack { Link(edge.sourceURL.absoluteString, destination: edge.sourceURL); Text(edge.fetchedAt.formatted(date: .abbreviated, time: .shortened)); Text(edge.batchID.uuidString.prefix(8)) }
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ContentUnavailableView("选择 root 后扩展", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }.padding()
    }
}
