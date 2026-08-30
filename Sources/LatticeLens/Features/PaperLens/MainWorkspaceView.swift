import SwiftUI

struct MainWorkspaceView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationSplitView {
            AuthorSidebar(viewModel: viewModel)
        } content: {
            PaperTimeline(viewModel: viewModel)
        } detail: {
            PaperLensView(viewModel: viewModel)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Label("LatticeLens", systemImage: "circle.grid.cross")
                    Divider().frame(height: 18)
                    if viewModel.isUsingFixtureDependencies {
                        Text("Fixture mode")
                            .foregroundStyle(.orange)
                            // Toolbar `Text` siblings otherwise coalesce
                            // into one AppKit accessibility node.  Fixture
                            // mode is a safety boundary for every UI test,
                            // so it must remain independently queryable.
                            .accessibilityElement(children: .ignore)
                            .accessibilityIdentifier("fixtureModeIndicator")
                            .accessibilityLabel("Fixture mode")
                            .accessibilityValue("enabled")
                        if viewModel.isLargeFixtureReady {
                            Text("Large fixture ready")
                                .foregroundStyle(.orange)
                                .accessibilityElement(children: .ignore)
                                .accessibilityIdentifier("largeFixtureModeIndicator")
                                .accessibilityLabel("Large fixture ready")
                                .accessibilityValue("ready")
                        }
                    }
                    Button {
                        viewModel.presentSyncCenter = true
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: viewModel.syncStatusSymbol)
                                .accessibilityHidden(true)
                                .imageScale(.small)
                                .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[VerticalAlignment.center] }
                            Text("INSPIRE")
                            Text(viewModel.syncToolbarStatus)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        // The principal toolbar item can shrink when all four
                        // trailing actions are visible.  Keep its rendered
                        // status intentionally short rather than forcing a
                        // multi-line text node out of the toolbar bounds.
                        .frame(minWidth: 170, idealWidth: 250, maxWidth: 330, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(viewModel.syncStatus.phase == .failed ? .red : .secondary)
                    .help(viewModel.connectivityDescription)
                    .accessibilityIdentifier("inspireConnectivity")
                    .accessibilityLabel("最近 INSPIRE 同步")
                    .accessibilityValue(viewModel.connectivityDescription)
                }
            }
            ToolbarItem(placement: .automatic) {
                Button { viewModel.presentResearchHome = true } label: { Label("研究首页", systemImage: "house") }
                    .accessibilityIdentifier("researchHomeButton")
            }
            ToolbarItem(placement: .automatic) {
                Button { viewModel.presentSyncCenter = true } label: { Label("同步中心", systemImage: "arrow.triangle.2.circlepath") }
                    .accessibilityIdentifier("syncCenterButton")
            }
            ToolbarItem(placement: .automatic) {
                Button { viewModel.openWorkbench() } label: { Label("Evidence Workbench", systemImage: "rectangle.3.group") }
                    .accessibilityIdentifier("workbenchButton")
            }
            ToolbarItem(placement: .automatic) {
                Button { viewModel.openSettings() } label: { Label("设置", systemImage: "gearshape") }
                    .accessibilityIdentifier("settingsButton")
            }
        }
        // Keep the fixture's historical sheet contract for XCTest (its
        // assertions intentionally scope controls through `app.sheets`).
        // Production uses an in-window modal instead: on this macOS release
        // a native sheet can leave the accessibility pipe closed, making the
        // visible Menu/SecureField controls impossible to inspect or activate.
        // The production overlay keeps one stable hierarchy and still blocks
        // the workspace behind it.
        .modifier(SettingsPresentationModifier(viewModel: viewModel))
        .sheet(isPresented: $viewModel.presentResearchHome) { V4ResearchHomeView(viewModel: viewModel) }
        .sheet(isPresented: $viewModel.presentSyncCenter) { SyncCenterView(viewModel: viewModel) }
        .sheet(isPresented: $viewModel.presentWorkbench) { V3WorkbenchView(viewModel: viewModel) }
        .alert("首次使用 AI 论文镜头", isPresented: $viewModel.presentPrivacyDisclosure) {
            Button("暂不发送", role: .cancel) { viewModel.declinePrivacyDisclosure() }
                .accessibilityIdentifier("declineInsightDisclosure")
            Button("了解并继续") { viewModel.acceptPrivacyDisclosure() }
                .accessibilityIdentifier("acceptInsightDisclosure")
        } message: {
            Text("将向当前配置的 LLM endpoint 发送论文标题、摘要、bibliographic metadata 和 figure captions。v1 不发送图像像素、作者邮箱或职位资料；分析只基于这些资料，不能替代全文审读。")
        }
        .alert("发送全文证据片段", isPresented: $viewModel.presentEvidencePrivacyDisclosure) {
            Button("暂不发送", role: .cancel) { viewModel.declineEvidencePrivacyDisclosure() }
                .accessibilityIdentifier("declineEvidenceDisclosure")
            Button("了解并继续") { viewModel.acceptEvidencePrivacyDisclosure() }
                .accessibilityIdentifier("acceptEvidenceDisclosure")
        } message: {
            Text("将向当前 provider endpoint 发送本次本地检索出的 PDF page chunks、对应 quote anchors，以及标题/摘要/captions。不会发送图像像素或整份 PDF；只有 validator 通过且所有 direct/inference claim 可回查时才保存结果。")
        }
        .alert("发送缩放后的 figure 图像像素", isPresented: $viewModel.presentVisionPrivacyDisclosure) {
            Button("暂不发送", role: .cancel) { viewModel.declineVisionPrivacyDisclosure() }
                .accessibilityIdentifier("declineVisionDisclosure")
            Button("了解并继续") { viewModel.acceptVisionPrivacyDisclosure() }
                .accessibilityIdentifier("acceptVisionDisclosure")
        } message: {
            if let preflight = viewModel.visionPreflight {
                let figures = preflight.figureKeys.joined(separator: ", ")
                let bytes = ByteCountFormatter.string(fromByteCount: Int64(preflight.totalBytes), countStyle: .file)
                let sizes = preflight.figureKeys.map { key in
                    let original = preflight.originalDimensions[key].map { "\($0.first ?? 0)×\($0.dropFirst().first ?? 0)" } ?? "unknown"
                    let resized = preflight.resizedDimensions[key].map { "\($0.first ?? 0)×\($0.dropFirst().first ?? 0)" } ?? "unknown"
                    return "\(key): \(original) → \(resized), \(preflight.imageBytes[key] ?? 0) B"
                }.joined(separator: "；")
                Text("本地已冻结 payload hash：\(preflight.frozenHash)。figure：\(figures)。原始/发送尺寸：\(sizes)。总发送 bytes：\(bytes)；endpoint：\(preflight.endpoint)；provider request：\(preflight.requestCount)。确认仅对该 hash 有效；不会发送 PDF 页面或其它图像。")
            } else {
                Text("没有冻结的 Vision preflight；不会发送像素。")
            }
        }
        .alert("下载本地全文 PDF？", isPresented: $viewModel.presentFullTextPreflight) {
            Button("取消", role: .cancel) { viewModel.cancelFullTextPreflight() }
                .accessibilityIdentifier("cancelFullTextPreflight")
            Button("下载并提取") { viewModel.confirmFullTextDownload() }
                .accessibilityIdentifier("confirmFullTextDownload")
        } message: {
            if let preflight = viewModel.fullTextPreflight {
                let estimate = preflight.advertisedByteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "服务器未提供"
                let limit = ByteCountFormatter.string(fromByteCount: Int64(preflight.hardByteLimit), countStyle: .file)
                Text("来源：\(preflight.finalURL.absoluteString)\nContent-Length：\(estimate)\n硬上限：\(limit)\n存储：\(preflight.cacheCategory)。确认后才会发送一次受限 GET；完成后会显示实际 bytes、SHA-256 和页数。")
            } else {
                Text("尚无有效 PDF 下载预检；不会发送 GET。")
            }
        }
        .alert("LatticeLens", isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.dismissError() } })) {
            Button("好", role: .cancel) { viewModel.dismissError() }
        } message: { Text(viewModel.errorMessage ?? "") }
    }
}

private struct SettingsPresentationModifier: ViewModifier {
    @ObservedObject var viewModel: AppViewModel

    @ViewBuilder
    func body(content: Content) -> some View {
        if viewModel.isUsingFixtureDependencies {
            content.sheet(isPresented: $viewModel.presentSettings) {
                SettingsView(viewModel: viewModel)
                    .id(viewModel.settingsPresentationID)
            }
        } else {
            content.overlay {
                if viewModel.presentSettings {
                    SettingsOverlay(viewModel: viewModel)
                        .id(viewModel.settingsPresentationID)
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
        }
    }
}

private struct SettingsOverlay: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ZStack {
            // This layer captures pointer events so the workspace cannot be
            // edited while Settings is open.  It is intentionally hidden
            // from assistive technology; the Settings hierarchy below is the
            // only modal surface that should be announced.
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            ProductionSettingsView(viewModel: viewModel)
                .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct V4ResearchHomeView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let home = viewModel.researchHomeSnapshot
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Research Home", systemImage: "house.fill").font(.title2)
                Spacer()
                Button("完成") { dismiss() }
            }
            Text("本地工作队列 · \(home.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], spacing: 10) {
                HomeMetric(title: "Radar 待确认", value: home.radarUnacknowledged, systemImage: "dot.radiowaves.left.and.right", identifier: "homeMetric-radar")
                HomeMetric(title: "未读 / Inbox", value: home.unread, systemImage: "tray", identifier: "homeMetric-inbox")
                HomeMetric(title: "收藏", value: home.favorites, systemImage: "star", identifier: "homeMetric-favorites")
                HomeMetric(title: "过期 evidence", value: home.staleEvidence, systemImage: "exclamationmark.triangle", identifier: "homeMetric-staleEvidence")
                HomeMetric(title: "导入冲突", value: home.importConflicts, systemImage: "arrow.triangle.branch", identifier: "homeMetric-importConflicts")
                HomeMetric(title: "可恢复 job", value: home.resumableJobs, systemImage: "arrow.clockwise", identifier: "homeMetric-resumableJobs")
            }
            GroupBox("Reading Inbox") {
                let inbox = viewModel.papers.filter { !$0.isRead }.prefix(8)
                if inbox.isEmpty { Text("当前没有来自本地 library 的未读论文。").foregroundStyle(.secondary) }
                else {
                    ForEach(Array(inbox)) { paper in
                        LocalMarkdownTeXInlineText(source: paper.displayTitle)
                            .lineLimit(1)
                            .accessibilityIdentifier("inboxPaper-\(paper.literatureID)")
                    }
                }
            }
            GroupBox("最近工作区 / 导出") {
                Text("workspaces \(home.recentWorkspaceIDs.count) · exports \(home.recentExportIDs.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
        .accessibilityIdentifier("researchHome")
    }
}

private struct HomeMetric: View {
    let title: String
    let value: Int
    let systemImage: String
    let identifier: String
    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(title).font(.caption)
                // Put the stable identifier on the rendered number, rather
                // than the composite Label.  AppKit exposes a Label's
                // accessibility value inconsistently across macOS releases,
                // while this text is both the visible metric and the precise
                // value assistive clients need to announce and query.
                Text("\(value)")
                    .font(.title3.monospacedDigit())
                    .accessibilityIdentifier(identifier)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(value)")
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.tint)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AuthorSidebar: View {
    @ObservedObject var viewModel: AppViewModel
    // Search is intentionally UI-local: changing it must only derive a new
    // sidebar projection from the current author snapshot.  In particular it
    // must not publish a broader AppViewModel update while AppKit is editing
    // NSSearchField, reload the durable snapshot, or restart a sync task.
    @State private var localAuthorSearch: String

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _localAuthorSearch = State(initialValue: AppLaunchConfiguration.fixtureInitialAuthorSearch ?? "")
    }

    private var sections: [(String, [Author])] {
        // Name filtering is purely view-local.  The backing author snapshot is
        // never reloaded as the user types, so search cannot start a request,
        // reset a selection, or briefly leave an out-of-date A-Z row visible.
        let ordinary = viewModel.authors.filter {
            !$0.isSelf && !$0.isTracked && $0.matches(search: localAuthorSearch)
        }
        let grouped = Dictionary(grouping: ordinary, by: \Author.sectionKey)
        return grouped.keys.sorted().map { key in
            (key, grouped[key]!.sorted {
                if $0.stableSortKey != $1.stableSortKey { return $0.stableSortKey < $1.stableSortKey }
                return $0.preferredName.localizedStandardCompare($1.preferredName) == .orderedAscending
            })
        }
    }

    private var trackedAuthors: [Author] {
        viewModel.authors
            .filter { !$0.isSelf && $0.isTracked && $0.matches(search: localAuthorSearch) }
            .sorted {
                if $0.stableSortKey != $1.stableSortKey { return $0.stableSortKey < $1.stableSortKey }
                return $0.preferredName.localizedStandardCompare($1.preferredName) == .orderedAscending
            }
    }

    var body: some View {
        // Evaluate the local projection once per body pass.  Besides avoiding
        // repeated sorting while a 300+ author fixture is visible, this gives
        // a keyboard/VoiceOver user a stable selection action when a precise
        // search has one unambiguous ordinary-author result.
        let authorSections = sections
        let ordinarySearchResultCount = authorSections.reduce(into: 0) { count, section in count += section.1.count }
        let singleOrdinarySearchMatch = ordinarySearchResultCount == 1
            ? authorSections.lazy.flatMap(\.1).first
            : nil
        VStack(spacing: 0) {
            // Keep this native editable control inside the sidebar rather
            // than using `.searchable`, which macOS may relocate into the
            // window toolbar when a split-view column narrows.  The product
            // contract requires both the pinned self card and author search
            // to remain visible at 820pt; toolbar relocation breaks that
            // guarantee and makes keyboard focus ambiguous.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索姓名、native name 或 BAI", text: $localAuthorSearch)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("authorSearch")
                    .accessibilityLabel("搜索姓名、native name 或 BAI")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if let match = singleOrdinarySearchMatch {
                // Keep the native List row below as the rendered search
                // result, but expose this exact-match action in the fixed
                // header.  An AppKit List virtualizes a row that has just
                // been filtered into view, so putting the only keyboard and
                // VoiceOver action in its bottom safe-area inset can leave
                // it absent from the accessibility tree.
                Button("选择匹配作者：\(match.preferredName)") {
                    scheduleAuthorSelection(match.recid)
                }
                // Selection changes durable workspace state, so use a
                // standard command button rather than a link-styled button.
                // On macOS the latter is exported as AXLink, which makes the
                // action needlessly hard to discover as a command in
                // VoiceOver's Buttons rotor.
                .buttonStyle(.bordered)
                .accessibilityIdentifier("selectAuthorSearchResult-\(match.recid)")
                .accessibilityLabel("选择匹配作者 \(match.preferredName)，INSPIRE \(match.recid)")
                .accessibilityHint("选择唯一的本地作者搜索结果")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }

            ScrollViewReader { proxy in
                List(selection: Binding(get: { viewModel.selectedAuthorID }, set: { recid in
                    scheduleAuthorSelection(recid)
                })) {
                    Section("我的主页") {
                        if let me = viewModel.authors.first(where: \.isSelf) {
                            AuthorRow(author: me).tag(me.recid).id(me.recid)
                        } else {
                            Label("正在加载作者记录", systemImage: "person.crop.circle.badge.clock")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !trackedAuthors.isEmpty {
                        Section("置顶作者") {
                            ForEach(trackedAuthors) { AuthorRow(author: $0).tag($0.recid).id($0.recid) }
                        }
                    }
                    ForEach(authorSections.filter { $0.0 != "#" }, id: \.0) { section, authors in
                        Section(section) {
                            ForEach(authors) { AuthorRow(author: $0).tag($0.recid).id($0.recid) }
                        }
                    }
                    if let hashes = authorSections.first(where: { $0.0 == "#" })?.1, !hashes.isEmpty {
                        Section("#") { ForEach(hashes) { AuthorRow(author: $0).tag($0.recid).id($0.recid) } }
                    }
                }
                .scrollIndicators(.visible)
                .accessibilityIdentifier("authorsScrollableList")
                .accessibilityLabel("Authors scrollable list")
                .onChange(of: localAuthorSearch) { _, query in
                    // Filtering a long native List may retain the prior A-Z
                    // scroll position.  Preserve the durable selected author,
                    // but bring the first matching ordinary author into the
                    // visible/accessibility tree so a search result is not
                    // merely counted below the fold.
                    guard !query.isEmpty,
                          let firstMatch = authorSections.lazy.flatMap(\.1).first else { return }
                    proxy.scrollTo(firstMatch.recid, anchor: .top)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    if let progress = viewModel.authorIndexProgress {
                        Text("页 \(progress.completedPages) · 已验证 \(progress.verified) / 候选 \(progress.candidates) / 合格 \(progress.qualified) / 失败 \(progress.failed)")
                    } else { Text("作者索引尚未构建") }
                    Text(viewModel.authorIndexStatus.message)
                        .accessibilityIdentifier("authorIndexStatus")
                    if !localAuthorSearch.isEmpty {
                        // This uses the same dedicated AX-element pattern as
                        // the paper search provenance below.  Without the
                        // frame and ignored children, AppKit coalesces this
                        // status with the surrounding index text and drops
                        // the identifier even though the rendered count is
                        // right.
                        Text("普通作者匹配 \(ordinarySearchResultCount)")
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("authorSearchMatchCount")
                        .accessibilityLabel("普通作者匹配 \(ordinarySearchResultCount)")
                        .accessibilityValue("\(ordinarySearchResultCount)")
                        Button("清除搜索") { localAuthorSearch = "" }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("clearAuthorSearch")
                    }
                    Button("构建 hep-lat / hep-th 作者索引") { viewModel.buildAuthorIndex() }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("buildAuthorIndex")
                    if viewModel.isAuthorIndexRunning {
                        Button("暂停索引") { viewModel.pauseAuthorIndex() }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("pauseAuthorIndex")
                        Button("取消索引") { viewModel.cancelAuthorIndex() }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("cancelAuthorIndex")
                    } else if viewModel.authorIndexStatus.phase == .cancelled || viewModel.authorIndexStatus.phase == .partial || viewModel.authorIndexStatus.phase == .stale || viewModel.authorIndexStatus.phase == .failed {
                        Button("继续索引") { viewModel.buildAuthorIndex() }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("resumeAuthorIndex")
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.bar)
            }
        }
        .navigationTitle("AUTHORS")
    }

    /// AppKit delivers a List selection while SwiftUI is reconciling the
    /// selection binding.  Deferring the larger view-model transition avoids
    /// publishing authors/papers/insight state from inside that reconciliation.
    private func scheduleAuthorSelection(_ recid: Int?) {
        guard recid != viewModel.selectedAuthorID else { return }
        Task { @MainActor in
            await Task.yield()
            viewModel.selectAuthor(recid)
        }
    }
}

private struct SyncCenterView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Sync Center").font(.title3).accessibilityIdentifier("syncCenter")
                Spacer()
                Button("完成") { dismiss() }
            }
            // Keep the dismissal action above a native, independently
            // scrollable job region. At the smallest supported window size,
            // job state and recovery guidance must remain reachable without
            // moving the only close action out of view.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    SyncJobRow(title: "hep-lat / hep-th 作者索引", status: viewModel.authorIndexStatus.message) {
                        if viewModel.isAuthorIndexRunning {
                            Button("暂停") { viewModel.pauseAuthorIndex() }
                            Button("取消", role: .destructive) { viewModel.cancelAuthorIndex() }
                        } else {
                            Button("继续") { viewModel.buildAuthorIndex() }
                        }
                    }
                    SyncJobRow(title: "当前作者文献", status: viewModel.syncStatus.message) {
                        Button("同步") { viewModel.syncSelectedAuthor() }.disabled(viewModel.selectedAuthor == nil)
                        if viewModel.isSelectedPaperSyncRunning { Button("取消", role: .destructive) { viewModel.cancelSelectedPaperSync() } }
                    }
                    SyncJobRow(title: "全文下载/提取", status: viewModel.fullTextStatusMessage ?? "没有活跃全文 job") {
                        Button("取消", role: .destructive) { viewModel.cancelFullTextDownload() }
                            .disabled(viewModel.fullTextStatusMessage == nil)
                    }
                    SyncJobRow(title: "LLM text insight", status: viewModel.insightStateDescription) {
                        if viewModel.isInsightRunning { Button("取消") { viewModel.cancelInsight() } }
                    }
                    SyncJobRow(title: "Evidence / Vision", status: viewModel.evidenceAndVisionStatusDescription) {
                        if viewModel.isEvidenceInsightRunning { Button("取消 evidence") { viewModel.cancelEvidenceInsight() } }
                        if viewModel.isVisionRunning { Button("取消 vision") { viewModel.cancelVision() } }
                    }
                    GroupBox("Durable job owners") {
                        VStack(alignment: .leading, spacing: 4) {
                            let snapshot = viewModel.workbenchSnapshot
                            Text("tracked authors \(snapshot.authors.values.filter { $0.isTracked }.count) · saved queries \(snapshot.savedInspireQueries.count)")
                                .accessibilityIdentifier("syncCenterDurableSummary")
                            Text("batches \(snapshot.syncBatchesV3.count) · job events \(snapshot.syncJobEvents.count) · Radar events \(snapshot.radarEvents.count)")
                            if let checkpoint = snapshot.checkpoints.values.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
                                Text("last checkpoint \(checkpoint.jobID) · \(checkpoint.state.rawValue) · page \(checkpoint.completedPages) · pending \(checkpoint.pendingIDs.count)")
                            } else {
                                Text("暂无 durable checkpoint")
                            }
                        }
                        .font(.caption)
                    }
                    Text("暂停/取消均保留已成功写入的页、论文与 checkpoint；继续只请求未完成部分。provider、PDF 和 Vision 请求不在此处自动重试。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .scrollIndicators(.visible)
            .accessibilityIdentifier("syncCenterScrollableContent")
            .accessibilityLabel("Sync Center scrollable content")
        }
        .padding().frame(width: 560, height: 360)
    }
}

private struct SyncJobRow<Controls: View>: View {
    let title: String
    let status: String
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                Text(status).font(.caption).foregroundStyle(.secondary)
                HStack { controls() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AuthorRow: View {
    let author: Author

    var body: some View {
        HStack(spacing: 8) {
            if author.isSelf { Image(systemName: "star.fill").foregroundStyle(.tint) }
            VStack(alignment: .leading, spacing: 2) {
                Text(author.preferredName)
                if author.isSelf { Text("recid \(author.recid)").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            if let h = author.hIndex {
                Text("h \(h.all)").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .help("INSPIRE h(all), self-citations included, updated \(h.fetchedAt.formatted())")
            } else if author.hIndexState == .failed { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            if author.isTracked {
                Image(systemName: "star.fill").foregroundStyle(.tint)
                    .accessibilityLabel("已置顶作者")
            }
        }
        .accessibilityIdentifier("authorRow-\(author.recid)")
        .accessibilityLabel(author.isTracked ? "置顶作者 \(author.preferredName)" : author.preferredName)
        .accessibilityValue(author.hIndex.map { "h-index \($0.all)" } ?? "h-index 未验证")
    }
}

private struct PaperTimeline: View {
    @ObservedObject var viewModel: AppViewModel

    private var yearSections: [(Int, [Paper])] {
        let grouped = Dictionary(grouping: viewModel.filteredPapers, by: \Paper.timelineYear)
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!.sorted { ($0.timelineDate ?? .distantPast) > ($1.timelineDate ?? .distantPast) }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let author = viewModel.selectedAuthor {
                HStack {
                    VStack(alignment: .leading) {
                        Text(author.preferredName).font(.headline)
                        Text(authorSummary(author))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(author.lastSyncedAt.map { "上次同步 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未同步文献")
                            .font(.caption2).foregroundStyle(.secondary)
                        if let url = URL(string: "https://inspirehep.net/authors/\(author.recid)") {
                            Link("在 INSPIRE 打开作者记录", destination: url)
                                .font(.caption2)
                                .accessibilityIdentifier("openInspireAuthor")
                        }
                    }
                    Spacer()
                    Button { Task { await viewModel.toggleTrackedSelectedAuthor() } } label: {
                        Label(author.isTracked ? "已关注" : "关注", systemImage: author.isTracked ? "star.fill" : "star")
                    }
                    Button { viewModel.syncSelectedAuthor() } label: { Label("同步", systemImage: "arrow.clockwise") }
                        .accessibilityIdentifier("syncAuthor")
                    if viewModel.isSelectedPaperSyncRunning {
                        Button("取消同步") { viewModel.cancelSelectedPaperSync() }
                            .accessibilityIdentifier("cancelAuthorSync")
                    }
                }
                .padding()
                // A selection confirmation must be independently observable:
                // a long List row can be bridged as a non-hittable child by
                // AppKit even when its row receives the click.  This compact
                // durable-ID summary lets keyboard and UI automation verify
                // the resulting author selection rather than infer it from
                // a stale row proxy.
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("selectedAuthorSummary")
                .accessibilityLabel("当前作者 \(author.preferredName)，INSPIRE \(author.recid)")
                .accessibilityValue("\(author.recid)")
                Divider()
            }
            HStack {
                TextField("全局搜索 title、author、arXiv、DOI、tag、collection 或 note", text: $viewModel.globalPaperSearch)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { viewModel.refreshGlobalPaperSearch() }
                    .onChange(of: viewModel.globalPaperSearch) { _, _ in viewModel.refreshGlobalPaperSearch() }
                    .accessibilityIdentifier("globalPaperSearch")
                if !viewModel.globalPaperSearch.isEmpty {
                    Button("清除") { viewModel.globalPaperSearch = ""; viewModel.refreshGlobalPaperSearch() }
                        .accessibilityIdentifier("clearGlobalPaperSearch")
                }
            }
            .padding(.horizontal).padding(.vertical, 6)
            if !viewModel.globalPaperSearch.isEmpty {
                let sources = Array(Set(viewModel.globalSearchHits.map(\.source))).sorted().joined(separator: "、")
                let provenanceSummary = "本地命中：\(viewModel.globalPaperResults.count) 篇 · 来源：\(sources.isEmpty ? "检索中" : sources)"
                Text(provenanceSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(provenanceSummary)
                    .accessibilityIdentifier("searchProvenanceSummary")
            }
            if viewModel.syncStatus.phase == .ready || viewModel.syncStatus.phase == .stale || viewModel.syncStatus.phase == .cancelled {
                Text("本轮：new \(viewModel.syncStatus.newRecords) · metadata updated \(viewModel.syncStatus.metadataUpdatedRecords) · unchanged \(viewModel.syncStatus.unchangedRecords)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .accessibilityIdentifier("authorSyncBatchSummary")
            }
            Picker("过滤", selection: $viewModel.paperFilter) {
                ForEach(PaperFilter.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
            .accessibilityIdentifier("paperFilter")
            List(selection: Binding(get: { viewModel.selectedPaperID }, set: { paperID in
                schedulePaperSelection(paperID)
            })) {
                if !viewModel.globalPaperSearch.isEmpty {
                    Section("全局搜索") {
                        ForEach(viewModel.globalPaperResults) { paper in
                            VStack(alignment: .leading, spacing: 3) {
                                PaperRow(paper: paper).tag(paper.literatureID)
                                let sources = viewModel.globalSearchHits.filter { $0.paperID == paper.literatureID }.map(\.source)
                                if !sources.isEmpty {
                                    Text("命中：\(Array(Set(sources)).sorted().joined(separator: "、"))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .accessibilityIdentifier("searchProvenance-\(paper.literatureID)")
                                }
                            }
                        }
                    }
                }
                ForEach(yearSections, id: \.0) { year, papers in
                    Section(String(year)) { ForEach(papers) { PaperRow(paper: $0) } }
                }
            }
            .scrollIndicators(.visible)
            .accessibilityIdentifier("papersScrollableList")
            .accessibilityLabel("Papers scrollable list")
        }
        .navigationTitle(viewModel.selectedAuthor?.preferredName ?? "文献时间线")
    }

    /// See AuthorSidebar.scheduleAuthorSelection(_:): choosing a paper starts
    /// several independent, cancellable jobs, so it must not publish while
    /// List is applying its selection update.
    private func schedulePaperSelection(_ paperID: Int?) {
        // During an incremental paper-sync commit AppKit can transiently send
        // a nil List selection while it reconciles the inserted rows.  It is
        // not a user request to abandon the visible paper, and treating it as
        // one would cancel/restart its LLM task.  Preserve the current paper
        // until an explicit author switch has cleared selectedPaperID.
        if paperID == nil, viewModel.selectedPaperID != nil {
            // During an incremental metadata/detail refresh AppKit can emit a
            // transient nil while List rebuilds its rows.  A real author
            // switch clears selectedPaperID before publishing its own nil, so
            // any nil seen while a paper is still selected is reconciliation
            // noise and must not cancel an in-flight LLM request.
            return
        }
        guard paperID != viewModel.selectedPaperID else { return }
        Task { @MainActor in
            await Task.yield()
            viewModel.selectPaper(paperID)
        }
    }

    private func authorSummary(_ author: Author) -> String {
        guard let h = author.hIndex else { return "\(viewModel.papers.count) papers · h-index 未验证" }
        let published = h.published.map { " · h(published) \($0)" } ?? " · h(published) 未提供"
        return "\(viewModel.papers.count) papers · h(all) \(h.all)\(published)"
    }
}

private struct PaperRow: View {
    let paper: Paper
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if !paper.isRead { Circle().fill(.blue).frame(width: 7, height: 7).accessibilityLabel("新增未读") }
                LocalMarkdownTeXInlineText(source: paper.displayTitle).lineLimit(2)
            }
            HStack(spacing: 6) {
                if let arxiv = paper.arxivID { Text("arXiv:\(arxiv)") }
                if let category = paper.arxivCategories.first { Text(category) }
                if let publicationYear = paper.publicationYear { Text("发表 \(publicationYear)") }
                if let count = paper.citationCount { Text("引用 \(count)") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("paperRow-\(paper.literatureID)")
    }
}
