import SwiftUI
import UniformTypeIdentifiers
import AppKit

private struct SettingsTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var draft: LLMSettings
    @State private var apiKey = ""
    @State private var models: [String] = []
    @State private var presentModelSelector = false
    @State private var terminologySource = ""
    @State private var terminologyZH = ""
    @State private var terminologyNote = ""
    @State private var terminologySearch = ""
    /// Keep the initial settings accessibility tree bounded.  The complete
    /// terminology set remains available through search and explicit batches;
    /// opening Settings must not instantiate hundreds of off-screen controls.
    @State private var terminologyDisplayLimit = 50
    @State private var editingTerminologyID: UUID?
    @State private var terminologyDocument: SettingsTextDocument?
    @State private var exportingTerminology = false
    @State private var importingTerminology = false
    @State private var discoveryMessage: String?
    @State private var connectionMessage: String?
    @State private var confirmClearAI = false
    @State private var confirmClearImages = false
    @State private var clearScope: AIArtifactClearScope = .all
    @State private var clearPreview: V4AIClearPreview?
    /// This changes only after the sheet itself changes credential state.
    /// The saved/missing snapshot below is re-read from Keychain by an async
    /// task, never from the view-rendering path.
    @State private var credentialStatusRefresh = 0
    /// `nil` means that this provider's non-secret Keychain status is still
    /// being resolved.  This stores neither an API key nor a key hash.
    @State private var savedAPIKey: Bool?

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _draft = State(initialValue: viewModel.settings)
        // A large fixture is already an explicit process-local launch gate.
        // Preload only its deterministic substitute so the model-selection
        // surface can be accessibility-tested without manufacturing a
        // provider request or depending on a toolbar/Form click race.
        _models = State(initialValue: AppLaunchConfiguration.usesLargeFixture
                        ? AppFixtureModelDiscoverer.largeFixtureModelIDs
                        : [])
    }

    var body: some View {
        let terminologyNeedle = SearchNormalizer.normalize(terminologySearch)
        let visibleTerminology = draft.terminology.filter {
            terminologyNeedle.isEmpty || SearchNormalizer.normalize($0.source).contains(terminologyNeedle) ||
                SearchNormalizer.normalize($0.preferredZH).contains(terminologyNeedle) ||
                SearchNormalizer.normalize($0.note).contains(terminologyNeedle)
        }
        let hasSingleTerminologyMatch = visibleTerminology.count == 1
        let singleTerminologyMatchID = hasSingleTerminologyMatch ? visibleTerminology.first?.id : nil
        let displayedTerminology = visibleTerminology.prefix(terminologyDisplayLimit)
        let remainingTerminologyCount = max(0, visibleTerminology.count - displayedTerminology.count)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Settings").font(.title3)
                    Spacer()
                    // Do not use `role: .cancel` here.  On the current macOS
                    // XCTest/AppKit bridge it can receive a mouse event without
                    // invoking the SwiftUI closure, leaving a dead modal AX
                    // layer above the main toolbar.  This ordinary Button keeps
                    // the same Escape shortcut while guaranteeing the explicit
                    // state and presentation paths both retire the sheet.
                    Button("取消") { closeSettings() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("cancelSettings")
                    Button("保存") {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        viewModel.saveSettings(draft, apiKey: apiKey)
                        closeSettings(resignFirstResponder: false)
                    }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("saveSettings")
                }
                // This is an independent accessibility cue for the native
                // scrolling Form below.  Applying an identifier directly to
                // `Form` makes the current macOS bridge inherit that ID onto
                // every contained control, which would hide the stable IDs
                // for provider, model, and terminology actions.
                Text("设置内容可滚动")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settingsScrollableForm")
                    .accessibilityLabel("Settings scrollable form")
                if hasSingleTerminologyMatch, let entry = visibleTerminology.first {
                    // Keep the sole filtered result's real action in the
                    // non-scrolling header.  The Form below may consume all
                    // remaining height at the 820×640 acceptance size, so a
                    // duplicate action in that region is not a reachability
                    // guarantee even when AppKit leaves it in the AX tree.
                    Button {
                        editingTerminologyID = entry.id
                        terminologySource = entry.source
                        terminologyZH = entry.preferredZH
                        terminologyNote = entry.note
                    } label: {
                        Label("编辑匹配术语：\(entry.source)", systemImage: "pencil")
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("editTerminology-\(entry.id.uuidString)")
                    .accessibilityLabel("编辑术语 \(entry.source) → \(entry.preferredZH)")
                    .accessibilityHint("打开筛选术语编辑")
                }
            }
            .padding()
            // Terminology search belongs to the fixed control band, not the
            // Form's independently scrolling data region.  Native macOS
            // accessibility can synthesize text into an off-screen Form
            // field, which makes an AX-only implementation appear usable
            // even though its result and edit action are physically below
            // the sheet fold.  Keep the query and its unique result beside
            // the persistent Save/Cancel actions instead.
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("搜索术语", text: $terminologySearch)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("terminologySearch")
                }
                Text(terminologySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "术语：显示 \(displayedTerminology.count) / \(draft.terminology.count) 条"
                     : "术语：匹配 \(visibleTerminology.count) / \(draft.terminology.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("terminologySearchCount")
                    .accessibilityValue("\(visibleTerminology.count)")
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .background(.bar)
            // Do not use macOS Form here.  Its fixed label column makes a long
            // localized Keychain disclosure consume the field's entire value
            // column on an ordinary 620 pt Settings sheet.  Each label now
            // occupies its own line and its control gets the full available
            // width, while this one native ScrollView owns overflow.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsSection("Provider") {
                        SettingsControlRow("服务") {
                            Picker("服务", selection: $draft.activeProvider) {
                                ForEach(LLMProvider.allCases) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("providerPicker")
                            .accessibilityLabel("服务")
                        }
                        SettingsControlRow("Base URL") {
                            TextField("https://…/v1", text: activeProfileBinding(\.baseURL))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("providerBaseURL")
                        }
                        SettingsControlRow(draft.activeProvider.apiKeyIsRequired ? "API Key（仅存储于 macOS Keychain）" : "API Key（可选；仅存储于 macOS Keychain）") {
                            SecureField("本次输入仅在保存时写入 Keychain", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("providerAPIKey")
                        }
                        if !draft.activeProvider.apiKeyIsRequired {
                            Text("API Key optional · Local process not bundled")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("localProviderDisclosure")
                        }
                    // The refresh value changes only after a successful
                    // Keychain mutation, so it gives the non-secret status
                    // region a new identity without caching or exposing a
                    // credential.
                    Group {
                        if savedAPIKey == true {
                            HStack {
                                Text("当前 provider 已保存 API Key")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("apiKeyStorageStatus-saved")
                                    .accessibilityLabel("API Key 保存状态")
                                    .accessibilityValue("已保存")
                                Spacer()
                                // A Form-local `role: .destructive` button is
                                // exposed by current macOS XCTest as an action
                                // that can receive a pointer event without
                                // invoking its closure.  Preserve the destructive
                                // visual cue explicitly, while using the normal
                                // Button activation path shared by Save/Cancel.
                                Button("清除已保存的 API Key") {
                                    if viewModel.clearAPIKey(for: draft.activeProvider) {
                                        credentialStatusRefresh &+= 1
                                        savedAPIKey = false
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                                .accessibilityIdentifier("clearAPIKey")
                            }
                        } else if savedAPIKey == false {
                            Text("当前 provider 未保存 API Key")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("apiKeyStorageStatus-missing")
                                .accessibilityLabel("API Key 保存状态")
                                    .accessibilityValue("未保存")
                        } else {
                            Text("正在检查当前 provider 的 API Key 保存状态…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("apiKeyStorageStatus-checking")
                                .accessibilityLabel("API Key 保存状态")
                                .accessibilityValue("正在检查")
                        }
                    }
                    .id("api-key-status-\(credentialStatusRefresh)")
                        SettingsControlRow("模型 ID（可手工填写）") {
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("model id", text: activeProfileBinding(\.manualModel))
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityIdentifier("providerManualModel")
                                HStack {
                                    Button("测试连接") { Task { await testConnection() } }
                                        .accessibilityIdentifier("testProviderConnection")
                                    Button("发现模型") { Task { await discoverModels() } }
                                        .accessibilityIdentifier("discoverModels")
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        SettingsControlRow("已发现/已保存模型") {
                            Button {
                                presentModelSelector = true
                            } label: {
                                HStack {
                                    let selected = draft.activeProfile.effectiveModel
                                    Text(selected.isEmpty ? "不选择" : selected)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundStyle(selected.isEmpty ? .secondary : .primary)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("selectProviderModel")
                            .accessibilityLabel("选择已发现或已保存模型")
                            .accessibilityValue(draft.activeProfile.effectiveModel.isEmpty ? "未选择" : draft.activeProfile.effectiveModel)
                        }
                        Toggle("Streaming", isOn: activeProfileBinding(\.usesStreaming))
                        Toggle("当前 provider/model 支持 Vision（需手工确认）", isOn: activeProfileBinding(\.supportsVision))
                            .accessibilityIdentifier("providerSupportsVision")
                        if let connectionMessage { Text(connectionMessage).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("providerConnectionStatus") }
                        if let discoveryMessage { Text(discoveryMessage).font(.caption).foregroundStyle(.secondary) }
                    }
                    SettingsSection("论文分析") {
                        Toggle("选择论文后自动分析（稳定 600 ms）", isOn: $draft.automaticAnalysis)
                        SettingsControlRow("模式") {
                            Picker("模式", selection: $draft.mode) { ForEach(InsightMode.allCases) { Text($0.displayName).tag($0) } }
                                .labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        SettingsControlRow("详细度") {
                            Picker("详细度", selection: $draft.detailLevel) { ForEach(InsightDetailLevel.allCases) { Text($0.displayName).tag($0) } }
                                .labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        SettingsControlRow("重要图像") {
                            Picker("重要图像", selection: $draft.maximumFigures) { Text("0").tag(0); Text("3").tag(3); Text("5").tag(5) }
                                .labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        SettingsControlRow("证据范围") { Text("标题 + 摘要 + captions") }
                    }
                    SettingsSection("术语表（bounded，作为 JSON prompt data）") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("source", text: $terminologySource).textFieldStyle(.roundedBorder)
                            TextField("中文", text: $terminologyZH).textFieldStyle(.roundedBorder)
                            TextField("备注", text: $terminologyNote).textFieldStyle(.roundedBorder)
                            HStack {
                        Button("添加") {
                            do {
                                var copy = draft
                                if let editingTerminologyID,
                                   let old = copy.terminology.first(where: { $0.id == editingTerminologyID }) {
                                    try copy.updateTerminology(TerminologyEntry(id: old.id, source: terminologySource, preferredZH: terminologyZH, note: terminologyNote))
                                    self.editingTerminologyID = nil
                                } else {
                                    try copy.addTerminology(source: terminologySource, preferredZH: terminologyZH, note: terminologyNote)
                                }
                                draft = copy
                                terminologySource = ""; terminologyZH = ""; terminologyNote = ""
                            } catch { discoveryMessage = "术语未添加：\(error.localizedDescription)" }
                        }
                                .disabled(terminologySource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || terminologyZH.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Spacer(minLength: 0)
                            }
                        }
                    HStack {
                        Button("导出术语 JSON") {
                            if let data = try? draft.exportTerminologyJSON() { terminologyDocument = SettingsTextDocument(data: data); exportingTerminology = true }
                        }
                        Button("导入术语 JSON") { importingTerminology = true }
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                if draft.terminology.isEmpty {
                                    Text("尚无术语；术语只会进入受限 JSON prompt data。")
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(displayedTerminology) { entry in
                                    if hasSingleTerminologyMatch {
                                        // Keep one visual result in the list for orientation, but
                                        // give it a distinct non-action identity.  The immediately
                                        // preceding fixed result button is the single accessible
                                        // edit target; duplicating its AX identifier here lets the
                                        // bridge return an obsolete, off-screen element.
                                        terminologyRowLabel(for: entry)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .accessibilityIdentifier("terminologyListRow-\(entry.id.uuidString)")
                                            .padding(.vertical, 3)
                                    } else {
                                        VStack(alignment: .leading, spacing: 5) {
                                            terminologyRowLabel(for: entry)
                                            HStack(spacing: 8) {
                                                Button("编辑") {
                                                    editingTerminologyID = entry.id
                                                    terminologySource = entry.source
                                                    terminologyZH = entry.preferredZH
                                                    terminologyNote = entry.note
                                                }
                                                .buttonStyle(.bordered)
                                                .controlSize(.small)
                                                .accessibilityIdentifier("editTerminology-\(entry.id.uuidString)")
                                                Button("删除", role: .destructive) { draft.deleteTerminology(entry.id) }
                                                    .buttonStyle(.bordered)
                                                    .controlSize(.small)
                                                    .accessibilityIdentifier("deleteTerminology-\(entry.id.uuidString)")
                                            }
                                        }
                                        .accessibilityIdentifier("terminology-\(entry.id.uuidString)")
                                        .padding(.vertical, 3)
                                    }
                                    Divider()
                                }
                                if remainingTerminologyCount > 0 {
                                    Button("显示更多（还有 \(remainingTerminologyCount) 条）") {
                                        terminologyDisplayLimit = min(
                                            visibleTerminology.count,
                                            terminologyDisplayLimit + 50
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("terminologyLoadMore")
                                    .accessibilityLabel("显示更多术语")
                                    .accessibilityValue("还有 \(remainingTerminologyCount) 条")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 3)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                        // A virtualized inner ScrollView can retain its old
                        // offset after a 500-row list is filtered.  Always
                        // bring an exact result into its own visible region;
                        // discovery in the AX tree is not sufficient if the
                        // focused person cannot actually operate the row.
                        .onChange(of: terminologySearch) { _, _ in
                            terminologyDisplayLimit = 50
                            guard let singleTerminologyMatchID else { return }
                            DispatchQueue.main.async {
                                proxy.scrollTo(singleTerminologyMatchID, anchor: .top)
                            }
                        }
                    }
                    .frame(height: 210)
                    .scrollIndicators(.visible)
                    .accessibilityIdentifier("terminologyScrollableList")
                    .accessibilityLabel("Terminology scrollable list")
                }
                    SettingsSection("隐私提示") {
                        let normalizedEndpoint = (try? APIEndpointBuilder.normalizedBaseURL(from: draft.activeProfile.baseURL, provider: draft.activeProvider).absoluteString) ?? "invalid endpoint"
                        Text("请求范围：title_abstract_figure_captions；provider：\(draft.activeProvider.displayName)；model：\(draft.activeProfile.effectiveModel.isEmpty ? "manual/未选择" : draft.activeProfile.effectiveModel)。normalized endpoint：\(normalizedEndpoint)。")
                        Text("本地会记录 request count、bounded bytes/token estimate、prompt/schema hash 和 frozen payload class；不发送作者邮箱/职位。Vision 仅在显式开启且发送 pixels 时单独同意。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    SettingsSection("本地缓存") {
                        SettingsControlRow("清除 AI 结果范围") {
                            Picker("清除 AI 结果范围", selection: $clearScope) {
                        Text("Insight").tag(AIArtifactClearScope.insight)
                        Text("Evidence insight").tag(AIArtifactClearScope.evidenceInsight)
                        Text("Vision artifact").tag(AIArtifactClearScope.vision)
                        Text("全部").tag(AIArtifactClearScope.all)
                            }
                            .labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    Button("清除 AI 结果…", role: .destructive) {
                        Task {
                            clearPreview = await viewModel.aiClearPreview(scope: clearScope)
                            confirmClearAI = true
                        }
                    }
                    .accessibilityIdentifier("clearAIResults")
                    Button("检查已查看图像缓存…") { confirmClearImages = true }
                    Text("清除 AI 结果只删除本机保存的 InsightArtifact。当前版本不持久化应用专属图像字节，因此绝不调用 URLCache.shared 或影响论文 metadata、作者索引、网络响应缓存或钥匙串 API Key。")
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.visible)
        }
        // `.keyboardShortcut(.cancelAction)` advertises Escape in the
        // control hierarchy, but an AppKit text responder can consume that
        // key before the button's action is reached.  Handle the command at
        // the sheet root as well so Escape and the visible Cancel button
        // share the same zero-write closure path.
        .onExitCommand { closeSettings() }
        .task(id: "\(draft.activeProvider.rawValue)|\(credentialStatusRefresh)") {
            let provider = draft.activeProvider
            savedAPIKey = nil
            let isSaved = await viewModel.apiKeySavedStatus(for: provider)
            guard !Task.isCancelled, provider == draft.activeProvider else { return }
            savedAPIKey = isSaved
        }
        // The fixed header remains reachable at the product's hard minimum
        // size; the responsive body above owns all vertical overflow.
        .frame(width: 620, height: 560, alignment: .top)
        .sheet(isPresented: $presentModelSelector) {
            ModelSelectionSheet(selectedModel: activeProfileBinding(\.selectedModel), discoveredModels: models,
                                isPresented: $presentModelSelector)
        }
        .fileExporter(isPresented: $exportingTerminology, document: terminologyDocument, contentType: .json, defaultFilename: "LatticeLens-terminology.json") { _ in }
        .fileImporter(isPresented: $importingTerminology, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first, let data = try? Data(contentsOf: url) else { return }
            do { try draft.importTerminologyJSON(data) } catch { discoveryMessage = "术语导入失败：\(error.localizedDescription)" }
        }
        .alert("清除 AI 结果？", isPresented: $confirmClearAI) {
            Button("取消", role: .cancel) {}
            Button("按所选范围清除", role: .destructive) { Task { await viewModel.clearAIResults(scope: clearScope) } }
        } message: {
            Text((clearPreview?.summary ?? "正在读取本地 artifact 计数；尚未删除任何内容。") +
                 " 不会删除 INSPIRE metadata、作者索引、全文 anchors、用户 note 或 API Key。")
        }
        .alert("清除图像缓存？", isPresented: $confirmClearImages) {
            Button("好", role: .cancel) {}
        } message: { Text("当前版本不持久化 LatticeLens 图像字节，且不会清理 URLCache.shared；因此没有应用专属图像缓存可删除。") }
    }

    private func activeProfileBinding<Value>(_ keyPath: WritableKeyPath<ProviderProfile, Value>) -> Binding<Value> {
        Binding(
            get: { draft.profiles[draft.activeProvider.rawValue]?[keyPath: keyPath] ?? ProviderProfile(baseURL: draft.activeProvider.defaultBaseURL)[keyPath: keyPath] },
            set: { value in
                var profile = draft.profiles[draft.activeProvider.rawValue] ?? ProviderProfile(baseURL: draft.activeProvider.defaultBaseURL)
                profile[keyPath: keyPath] = value
                profile.provider = draft.activeProvider
                draft.profiles[draft.activeProvider.rawValue] = profile
            }
        )
    }

    private func closeSettings(resignFirstResponder: Bool = true) {
        if resignFirstResponder {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        // `presentSettings` is the owning sheet binding.  Do not combine its
        // transition with an ambient nested `dismiss()` call: AppKit/XCTest
        // can otherwise retain a stale modal accessibility surface while the
        // SwiftUI hierarchy is rebuilding.  The owner transition is the one
        // durable, zero-write dismissal path for both Cancel and Escape.
        viewModel.cancelSettings()
    }

    @ViewBuilder
    private func terminologyRowLabel(for entry: TerminologyEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(entry.source) → \(entry.preferredZH)")
                .lineLimit(1)
                .truncationMode(.tail)
            if !entry.note.isEmpty {
                Text(entry.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func discoverModels() async {
        let profile = draft.activeProfile
        do {
            models = try await viewModel.discoverModels(profile: profile, provider: draft.activeProvider, apiKey: apiKey)
            discoveryMessage = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "已使用当前 provider 已保存的 API Key 发现 \(models.count) 个模型。"
                : "已使用本次输入的 API Key 发现 \(models.count) 个模型。"
        } catch {
            discoveryMessage = "模型发现失败；请先保存 API Key，或继续手工输入 model ID。"
        }
    }

    private func testConnection() async {
        let profile = draft.activeProfile
        do {
            let result = try await viewModel.testProviderConnection(profile: profile, provider: draft.activeProvider, apiKey: apiKey)
            connectionMessage = "连接成功：\(result.normalizedEndpoint)。未读取或更新模型列表。"
        } catch {
            connectionMessage = "连接失败：\(error.localizedDescription)"
        }
    }
}

/// A Settings row deliberately places its label above the value rather than
/// asking AppKit Form to reserve a fixed leading column.  This is what keeps
/// long localized privacy labels and their editable field inside a narrow
/// Settings sheet.
private struct SettingsControlRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: () -> Control

    init(_ title: String, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.control = control
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 12, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Model discovery can legitimately return hundreds of records.  This sheet
/// keeps the search and current selection fixed while only the native List
/// scrolls.  Selection edits the Settings draft, not persisted settings; the
/// parent sheet's Cancel remains a zero-write exit.
private struct ModelSelectionSheet: View {
    @Binding var selectedModel: String
    let discoveredModels: [String]
    @Binding var isPresented: Bool
    @State private var query = ""

    private var allModels: [String] {
        var values = Set(discoveredModels.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        if !selectedModel.isEmpty { values.insert(selectedModel) }
        return values.sorted()
    }

    private var filteredModels: [String] {
        let needle = SearchNormalizer.normalize(query)
        guard !needle.isEmpty else { return allModels }
        return allModels.filter { SearchNormalizer.normalize($0).contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择模型").font(.title3)
                Spacer()
                // Drive the explicit presentation binding.  In a nested
                // macOS sheet, an ambient dismiss may retire a responder but
                // leave the parent sheet behind a modal accessibility layer.
                Button("完成") { isPresented = false }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("dismissModelSelector")
            }
            .padding()
            VStack(alignment: .leading, spacing: 5) {
                TextField("搜索模型", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("modelSearch")
                Text(selectedModel.isEmpty ? "当前：未选择" : "当前：\(selectedModel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("selectedProviderModel")
                    .accessibilityValue(selectedModel.isEmpty ? "未选择" : selectedModel)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            List {
                if !selectedModel.isEmpty {
                    Section("当前选择（即使搜索不匹配也保留）") {
                        modelRow(selectedModel, current: true)
                    }
                }
                Section("可选模型（\(filteredModels.count)）") {
                    Button("不选择") { selectedModel = "" }
                        .accessibilityIdentifier("modelOption-none")
                    ForEach(filteredModels.filter { $0 != selectedModel }, id: \.self) { model in
                        modelRow(model, current: false)
                    }
                }
            }
            .scrollIndicators(.visible)
            .accessibilityIdentifier("modelScrollableList")
            .accessibilityLabel("Discovered models scrollable list")
        }
        .frame(minWidth: 520, minHeight: 520)
    }

    @ViewBuilder
    private func modelRow(_ model: String, current: Bool) -> some View {
        Button {
            selectedModel = model
        } label: {
            HStack {
                Text(model)
                Spacer()
                if current { Image(systemName: "checkmark.circle.fill").accessibilityLabel("当前选择") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("modelOption-\(model)")
        .accessibilityValue(current ? "selected" : "unselected")
    }
}
