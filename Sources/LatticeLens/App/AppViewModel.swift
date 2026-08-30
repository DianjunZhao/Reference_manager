import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var authors: [Author] = []
    @Published private(set) var papers: [Paper] = []
    @Published var selectedAuthorID: Int?
    @Published var selectedPaperID: Int?
    @Published var authorSearch = ""
    @Published var paperFilter: PaperFilter = .all
    @Published private(set) var authorIndexProgress: AuthorIndexProgress?
    @Published private(set) var syncStatus = SyncStatus.idle
    @Published private(set) var authorIndexStatus = SyncStatus.idle
    @Published private(set) var insightArtifact: InsightArtifact?
    @Published private(set) var insightState: InsightWorkflowState = .idle
    @Published private(set) var insightStartedAt: Date?
    @Published private(set) var analysisRunState: V4AnalysisRunState?
    @Published private(set) var evidenceInsightArtifact: EvidenceInsightArtifact?
    @Published private(set) var evidenceInsightState: InsightWorkflowState = .idle
    @Published private(set) var evidenceInsightStartedAt: Date?
    @Published private(set) var visionArtifact: VisionArtifact?
    @Published private(set) var visionState: InsightWorkflowState = .idle
    @Published private(set) var visionStartedAt: Date?
    @Published private(set) var visionPreflight: VisionPreflight?
    @Published private(set) var selectedFullTextDocument: FullTextDocument?
    @Published private(set) var selectedEvidenceAnchors: [EvidenceAnchor] = []
    @Published private(set) var evidenceJumpAnchor: EvidenceAnchor?
    @Published private(set) var selectedNotes: [UserNote] = []
    @Published private(set) var selectedTags: [LibraryTag] = []
    @Published private(set) var selectedBibTeXRecord: BibTeXRecord? = nil
    @Published private(set) var availableTags: [LibraryTag] = []
    @Published private(set) var availableCollections: [PaperCollection] = []
    @Published private(set) var selectedCollectionIDs: Set<UUID> = []
    @Published private(set) var globalPaperResults: [Paper] = []
    @Published private(set) var globalSearchHits: [V4SearchHit] = []
    @Published var globalPaperSearch = ""
    @Published private(set) var fullTextStatusMessage: String?
    /// Annotation creation is an asynchronous local transaction.  Publish
    /// only its coarse transaction state—not quote text or a document path—so
    /// a person can distinguish a completed durable annotation from a click
    /// that is still waiting on the store actor.
    @Published private(set) var annotationStatusMessage: String?
    @Published private(set) var compareExtractionStatus: String?
    @Published private(set) var fullTextPreflight: FullTextDownloadPreflight?
    @Published private(set) var paperDetailStatusMessage: String?
    @Published var settings: LLMSettings
    @Published var presentSettings = false
    /// Each presentation receives a fresh identity so a cancelled Settings
    /// draft can never be reused by SwiftUI when the sheet is reopened.
    @Published private(set) var settingsPresentationID = UUID()
    @Published var presentSyncCenter = false
    @Published var presentWorkbench = false
    @Published var presentResearchHome = false
    @Published var presentPrivacyDisclosure = false
    @Published var presentEvidencePrivacyDisclosure = false
    @Published var presentVisionPrivacyDisclosure = false
    @Published var presentFullTextPreflight = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var workbenchSnapshot = LibrarySnapshot()
    /// The large-fixture sentinel may become visible only after all fixture
    /// rows have been written and the first local projections are loaded.
    /// It is intentionally not an environment echo: UI cases use it to avoid
    /// interacting with a partially seeded list.
    @Published private(set) var isLargeFixtureReady = false
    /// UI-local projections bridge the actor persistence round trip for the
    /// active reference record.  They are not an alternative datastore: a
    /// failed write removes the projection and reloads authoritative state.
    @Published private var favoriteStateProjections: [Int: Bool] = [:]

    private let store: any LibraryStoring
    private let inspireClient: InspireClient
    private let authorIndex: AuthorIndexService
    private let paperSync: PaperSyncService
    private let insightWorkflow: InsightWorkflow
    private let evidenceInsightWorkflow: EvidenceInsightWorkflow
    private let visionWorkflow: VisionWorkflow
    private let fullTextService: FullTextService
    private let referenceManager: ReferenceManagerService
    private let keychain: any KeychainStoring
    private let modelDiscoverer: any ModelDiscovering
    private let connectionTester: any ProviderConnectionTesting
    private let workbench: V3WorkbenchService
    private let usesFixtureDependencies: Bool

    private var authorIndexTask: Task<Void, Never>?
    private var authorIndexSessionID = UUID()
    private var authorIndexStopIntent: SyncCheckpointState = .cancelled
    private var paperSyncTasks: [Int: Task<Void, Never>] = [:]
    private var paperSyncSessions: [Int: UUID] = [:]
    private var paperDetailTask: Task<Void, Never>?
    private var paperDetailSessionID = UUID()
    private var insightTask: Task<Void, Never>?
    private var insightSessionID = UUID()
    private var evidenceInsightTask: Task<Void, Never>?
    private var evidenceInsightSessionID = UUID()
    private var visionTask: Task<Void, Never>?
    private var visionPreflightTask: Task<Void, Never>?
    private var visionSessionID = UUID()
    private var modelDiscoverySessionID = UUID()
    private var modelDiscoveryTask: Task<[String], Error>?
    private var fullTextTask: Task<Void, Never>?
    private var fullTextSessionID = UUID()
    private var analysisDebounceTask: Task<Void, Never>?
    /// The active task is keyed by the exact same frozen cache identity used
    /// by InsightWorkflow.  It prevents selection/reconciliation noise from
    /// sending the same title/abstract a second time while a request is live.
    private var activeInsightCacheKey: String?
    /// Failed/cancelled automatic work is paused for this exact frozen input.
    /// Only an explicit "重新生成" action (or a changed cache key) can send it
    /// again, so clicking elsewhere cannot silently create another disclosure.
    private var automaticInsightTerminalMessages: [String: String] = [:]
    private var pendingInsightPaper: Paper?
    private var pendingEvidencePaper: Paper?
    private var pendingVisionPaper: Paper?
    private var pendingVisionRequest: VisionPreparedRequest?
    private var pendingFullTextSource: PaperDocument?
    private let jobOwners = V4JobOwnerRegistry()
    // Tracked author refreshes are foreground work, but still need the same
    // single-owner and bounded-concurrency semantics as an explicit author
    // sync.  These collections are process-local scheduling state; the
    // durable checkpoint/batch remains the recovery source after relaunch.
    private var queuedTrackedAuthorRefreshes: [Int] = []
    private var activeTrackedAuthorRefreshes: [Int: UUID] = [:]
    private var pendingBibTeXExport: (paperIDs: [Int], format: V3ExportFormat, contents: String)?
    private var pendingMarkdownExport: (paperIDs: [Int], format: V3ExportFormat, contents: String)?
    private var pendingWorkbenchExport: (paperIDs: [Int], format: V3ExportFormat, contents: String)?

    private static let settingsKey = "LatticeLens.LLMSettings.v2"
    private static let keychainService = "org.latticelens.app"
    private let staleInterval: TimeInterval = 15 * 60
    private let maximumTrackedAuthorSyncConcurrency = 2

    init(
        store: (any LibraryStoring)? = nil,
        client: InspireClient = InspireClient(),
        keychain: any KeychainStoring = KeychainStore(),
        llmClient: (any LLMCompleting)? = nil,
        modelDiscoverer: (any ModelDiscovering)? = nil,
        connectionTester: (any ProviderConnectionTesting)? = nil,
        useFixtureDependencies: Bool? = nil
    ) {
        let usesFixtures = (useFixtureDependencies ?? AppLaunchConfiguration.usesFixtureDependencies) && store == nil
        let concreteStore: any LibraryStoring = store ?? (usesFixtures ? InMemoryLibraryStore() : LibraryStoreFactory.makeDefault())
        let configuredClient = usesFixtures ? InspireClient(transport: AppFixtureTransport()) : client
        let configuredLLMClient: any LLMCompleting = usesFixtures ? AppFixtureLLMClient() : (llmClient ?? OpenAICompatibleClient())
        let configuredVisionClient: any VisionCompleting = usesFixtures ? AppFixtureLLMClient() : OpenAICompatibleClient()
        let configuredModelDiscoverer: any ModelDiscovering = usesFixtures ? AppFixtureModelDiscoverer() : (modelDiscoverer ?? OpenAICompatibleClient())
        let configuredConnectionTester: any ProviderConnectionTesting = usesFixtures ? AppFixtureModelDiscoverer() : (connectionTester ?? OpenAICompatibleClient())
        let configuredKeychain: any KeychainStoring
        if usesFixtures {
            let fixtureKeychain = UIFixtureKeychainStore()
            try? fixtureKeychain.save("fixture-ui-key", service: Self.keychainService, account: LLMProvider.openAI.rawValue)
            try? fixtureKeychain.save("fixture-ui-key", service: Self.keychainService, account: LLMProvider.localOpenAICompatible.rawValue)
            configuredKeychain = fixtureKeychain
        } else {
            configuredKeychain = keychain
        }
        self.store = concreteStore
        self.inspireClient = configuredClient
        self.authorIndex = AuthorIndexService(client: configuredClient, store: concreteStore)
        self.paperSync = PaperSyncService(client: configuredClient, store: concreteStore)
        self.insightWorkflow = InsightWorkflow(store: concreteStore, client: configuredLLMClient)
        self.evidenceInsightWorkflow = EvidenceInsightWorkflow(store: concreteStore, client: configuredLLMClient)
        self.visionWorkflow = VisionWorkflow(
            store: concreteStore,
            client: configuredVisionClient,
            loader: usesFixtures ? AppFixtureVisionImageLoader() : URLVisionImageLoader()
        )
        self.fullTextService = FullTextService(
            store: concreteStore,
            cacheDirectory: usesFixtures ? FullTextService.defaultCacheDirectory : nil,
            downloader: usesFixtures ? AppFixtureFullTextDownloader() : nil
        )
        self.referenceManager = ReferenceManagerService(store: concreteStore)
        self.workbench = V3WorkbenchService(store: concreteStore, client: configuredClient)
        self.keychain = configuredKeychain
        self.modelDiscoverer = configuredModelDiscoverer
        self.connectionTester = configuredConnectionTester
        self.usesFixtureDependencies = usesFixtures
        self.settings = usesFixtures ? AppLaunchConfiguration.fixtureSettings() : Self.loadSettings()
    }

    deinit {
        authorIndexTask?.cancel()
        analysisDebounceTask?.cancel()
        insightTask?.cancel()
        evidenceInsightTask?.cancel()
        visionTask?.cancel()
        visionPreflightTask?.cancel()
        fullTextTask?.cancel()
        paperDetailTask?.cancel()
        for task in paperSyncTasks.values { task.cancel() }
        modelDiscoveryTask?.cancel()
        jobOwners.cancelAll()
        if usesFixtureDependencies { FullTextService.removeFixtureCacheIfPresent() }
    }

    var selectedAuthor: Author? { authors.first { $0.recid == selectedAuthorID } }

    func openSettings() {
        settingsPresentationID = UUID()
        presentSettings = true
    }

    /// Workbench is the one surface that intentionally consumes the complete
    /// durable projection.  Present it first; its own task then performs the
    /// expensive read, so normal browsing and Settings stay responsive.
    func openWorkbench() {
        presentWorkbench = true
    }

    /// Settings edit only a local draft until Save.  Drive the binding rather
    /// than relying on an ambient nested-sheet dismiss action so Cancel is a
    /// deterministic zero-write exit even after the model selector was open.
    func cancelSettings() { presentSettings = false }
    /// Exposed only as an accessibility-visible isolation sentinel for the
    /// Xcode UI target.  It does not reveal a production configuration.
    var isUsingFixtureDependencies: Bool { usesFixtureDependencies }
    var selectedPaper: Paper? {
        papers.first { $0.literatureID == selectedPaperID } ?? globalPaperResults.first { $0.literatureID == selectedPaperID }
    }
    func isFavorite(_ paper: Paper) -> Bool {
        favoriteStateProjections[paper.literatureID] ?? paper.isFavorite
    }
    var isAuthorIndexRunning: Bool { authorIndexStatus.phase == .syncingMetadata }
    var isSelectedPaperSyncRunning: Bool { selectedAuthorID.flatMap { paperSyncTasks[$0] } != nil }
    var isInsightRunning: Bool { if case .idle = insightState { return false }; if case .completed = insightState { return false }; if case .cancelled = insightState { return false }; if case .failed = insightState { return false }; return true }
    var isEvidenceInsightRunning: Bool { if case .idle = evidenceInsightState { return false }; if case .completed = evidenceInsightState { return false }; if case .cancelled = evidenceInsightState { return false }; if case .failed = evidenceInsightState { return false }; return true }
    var isVisionRunning: Bool { if case .idle = visionState { return false }; if case .completed = visionState { return false }; if case .cancelled = visionState { return false }; if case .failed = visionState { return false }; return true }
    var insightStateDescription: String { describe(insightState) }
    var evidenceAndVisionStatusDescription: String { "evidence: \(describe(evidenceInsightState)) · vision: \(describe(visionState))" }
    /// This is deliberately a last-observed sync status, never a permanent
    /// claim that INSPIRE is currently online.
    var connectivityDescription: String {
        let timestamp = syncStatus.lastUpdatedAt?.formatted(date: .omitted, time: .shortened) ?? "未探测"
        return "最近 INSPIRE 同步：\(syncStatus.message) · \(timestamp)"
    }

    /// A short rendering for the constrained principal toolbar.  The complete,
    /// timestamped status remains available as the control's AX value/help and
    /// in Sync Center instead of overflowing a narrow toolbar item.
    var syncToolbarStatus: String {
        switch syncStatus.phase {
        case .syncingMetadata:
            return "同步中 · \(syncStatus.successfulRecords) 篇"
        case .ready:
            return "已同步 · \(syncStatus.successfulRecords) 篇"
        case .stale:
            return "本地结果 · 刷新失败"
        case .partial:
            return "部分完成 · \(syncStatus.successfulRecords) 篇"
        case .cancelled:
            return "已取消 · \(syncStatus.successfulRecords) 篇"
        case .failed:
            return "同步失败"
        case .loadingLocal:
            return "读取本地资料"
        case .idle:
            return "未同步"
        }
    }

    var syncStatusSymbol: String {
        switch syncStatus.phase {
        case .syncingMetadata, .loadingLocal: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle"
        case .stale, .partial: "exclamationmark.arrow.triangle.2.circlepath"
        case .cancelled: "pause.circle"
        case .failed: "exclamationmark.triangle"
        case .idle: "circle.dashed"
        }
    }

    var researchHomeSnapshot: V4ResearchHomeSnapshot {
        V4ResearchHomeSnapshot.make(snapshot: workbenchSnapshot)
    }

    private func describe(_ state: InsightWorkflowState) -> String {
        switch state {
        case .idle: "idle"
        case .connecting: "connecting"
        case .waitingFirstContent: "waiting first content"
        case .receiving(let characters, let bytes): "receiving \(characters) chars / \(bytes) bytes"
        case .validating: "validating"
        case .completed(let cacheHit, let requests): cacheHit ? "completed (cache)" : "completed \(requests) request(s)"
        case .cancelled: "cancelled"
        case .failed(let message): "failed: \(message)"
        }
    }

    var filteredPapers: [Paper] {
        papers.filter { paper in
            switch paperFilter {
            case .all: true
            case .hepLat: paper.arxivCategories.contains("hep-lat")
            case .published: paper.publicationStatus != nil
            case .unread: !paper.isRead
            case .figures: !paper.figures.isEmpty
            case .updates:
                workbenchSnapshot.radarEvents.values.contains { $0.paperID == paper.literatureID && !$0.isAcknowledged } ||
                    workbenchSnapshot.paperRevisionSnapshots.values.contains { $0.paperID == paper.literatureID }
            case .favorites: isFavorite(paper)
            case .needsReview:
                workbenchSnapshot.userEvidenceAnchors.values.contains { $0.paperID == paper.literatureID && $0.status != .valid } ||
                    workbenchSnapshot.importConflicts.values.contains { $0.paperID == paper.literatureID && $0.status == .pending } ||
                    workbenchSnapshot.radarEvents.values.contains { $0.paperID == paper.literatureID && !$0.isAcknowledged }
            }
        }
    }

    /// First paint uses only local state. Network work is scheduled after the
    /// view can render and never blocks offline browsing.
    func start() async {
        if case .readOnlyFailure(let reason) = await store.initializationState() {
            errorMessage = "本地资料库只读：\(reason)"
        }
        if usesFixtureDependencies && AppLaunchConfiguration.usesLargeFixture {
            do {
                try await AppFixtureLargeData.seed(into: store)
                await reloadAuthors()
                await refreshWorkbench()
                selectedAuthorID = ProductContract.selfAuthorRecid
                await loadPapers(for: ProductContract.selfAuthorRecid, syncIfNeeded: false)
                syncStatus = SyncStatus(phase: .ready,
                                        message: "large fixture 已从进程内存加载",
                                        completedPages: 0,
                                        successfulRecords: papers.count,
                                        failedRecords: 0,
                                        lastUpdatedAt: Date(),
                                        remainingRecords: 0)
                authorIndexStatus = SyncStatus(phase: .ready,
                                               message: "large fixture 作者索引已从进程内存加载",
                                               completedPages: 0,
                                               successfulRecords: authors.count,
                                               failedRecords: 0,
                                               lastUpdatedAt: Date(),
                                               remainingRecords: 0)
                // Do not run launch/foreground Radar or tracked-author tasks
                // here.  Large fixtures are a local reachability corpus, not
                // a request to exercise fixture transport in the background.
                isLargeFixtureReady = true
            } catch {
                errorMessage = "large fixture 初始化失败：\(error.localizedDescription)"
            }
            return
        }
        await reloadAuthors()
        if authors.first(where: { $0.isSelf }) == nil { await refreshPinnedSelf() }
        // A new library is empty on the first pass through `reloadAuthors()`;
        // `refreshPinnedSelf()` then publishes the durable self record.  Pick
        // the author only after that refresh as well, otherwise the optional
        // selection stays nil and the initial literature load is skipped,
        // leaving a freshly installed app with an apparently blank workspace.
        if selectedAuthorID == nil {
            selectedAuthorID = authors.first(where: \.isSelf)?.recid ?? authors.first?.recid
        }
        if let selectedAuthorID { await loadPapers(for: selectedAuthorID, syncIfNeeded: true) }
        Task { [weak self] in
            // Let the first local projection and the window's event loop
            // settle before background tracked-author refreshes.  Starting
            // several network jobs during first paint made the app feel
            // frozen on a cold SwiftData open and could compete with the
            // selected author's own first page.
            try? await Task.sleep(for: .seconds(2))
            await self?.refreshTrackedAuthorsInForeground()
        }
    }

    func selectAuthor(_ recid: Int?) {
        cancelInsight()
        paperDetailTask?.cancel()
        paperDetailSessionID = UUID()
        paperDetailStatusMessage = nil
        selectedAuthorID = recid
        selectedPaperID = nil
        papers = []
        insightArtifact = nil
        insightState = .idle
        insightStartedAt = nil
        guard let recid else { return }
        Task { [weak self] in await self?.loadPapers(for: recid, syncIfNeeded: true) }
    }

    func selectPaper(_ paperID: Int?) {
        // This method is also called by keyboard/list/Workbench routes.  A
        // repeated delivery of the same selection has no semantic work to do
        // and must not cancel/restart analysis or resend its frozen source.
        guard paperID != selectedPaperID else { return }
        analysisDebounceTask?.cancel()
        paperDetailTask?.cancel()
        // A document/anchor projection is paper-scoped.  Clear and cancel it
        // before publishing the next selection so a completed download for
        // paper A cannot be displayed as the state of paper B (or make a
        // cross-paper Compare action race against stale UI status).
        fullTextTask?.cancel()
        fullTextSessionID = UUID()
        pendingFullTextSource = nil
        fullTextPreflight = nil
        presentFullTextPreflight = false
        fullTextStatusMessage = nil
        selectedFullTextDocument = nil
        selectedEvidenceAnchors = []
        paperDetailSessionID = UUID()
        paperDetailStatusMessage = nil
        cancelInsight()
        cancelEvidenceInsight()
        cancelVision()
        selectedPaperID = paperID
        // Never let a completed artifact for paper A remain visible while the
        // asynchronous context restore for paper B is still in flight.
        insightArtifact = nil
        insightState = .idle
        insightStartedAt = nil
        analysisRunState = nil
        guard let paperID, let paper = selectedPaper else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await self.store.saveEvidenceAnchors(EvidenceAnchorFactory.metadataAnchors(for: paper))
            await self.reloadSelectedPaperContext(for: paperID)
            await self.fetchSelectedPaperDetail(paperID: paperID, authorRecid: self.selectedAuthorID)
        }
        guard settings.automaticAnalysis else { return }
        analysisDebounceTask = Task { [weak self, paper] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.requestAutomaticInsight(for: paper)
        }
    }

    func refreshPinnedSelf() async {
        do {
            try await authorIndex.refreshPinnedSelf()
            await reloadAuthors()
        } catch {
            errorMessage = "无法加载我的作者记录：\(error.localizedDescription)"
        }
    }

    func buildAuthorIndex(force: Bool = false) {
        authorIndexTask?.cancel()
        authorIndexStopIntent = .cancelled
        let session = UUID()
        authorIndexSessionID = session
        authorIndexStatus = SyncStatus(phase: .syncingMetadata, message: "正在构建 hep-lat / hep-th 作者索引", completedPages: 0,
                                       successfulRecords: 0, failedRecords: 0, lastUpdatedAt: Date())
        authorIndexTask = Task { [weak self] in
            guard let self else { return }
            await self.runAuthorIndex(force: force, session: session)
        }
    }

    func pauseAuthorIndex() {
        authorIndexStopIntent = .paused
        authorIndexTask?.cancel()
    }

    func cancelAuthorIndex() {
        authorIndexStopIntent = .cancelled
        authorIndexTask?.cancel()
    }

    func syncSelectedAuthor(forceFreshGeneration: Bool = false) {
        guard let recid = selectedAuthorID else { return }
        // This visible action is the explicit opt-in to a complete author
        // history.  Automatic first paint commits just one durable page.
        startPaperSync(for: recid, forceFreshGeneration: forceFreshGeneration, pageBudget: nil)
    }

    func cancelSelectedPaperSync() {
        guard let recid = selectedAuthorID else { return }
        jobOwners.cancel(key: paperSyncOwnerKey(recid))
        paperSyncTasks[recid]?.cancel()
    }

    func toggleTrackedSelectedAuthor() async {
        guard let author = selectedAuthor else { return }
        do {
            try await store.setTracked(!author.isTracked, authorRecid: author.recid)
            if author.isTracked {
                // Untracking is an ownership boundary: a foreground tracked
                // refresh must not outlive its durable user preference.
                jobOwners.cancel(key: paperSyncOwnerKey(author.recid))
                paperSyncTasks[author.recid]?.cancel()
                paperSyncTasks.removeValue(forKey: author.recid)
                activeTrackedAuthorRefreshes.removeValue(forKey: author.recid)
                queuedTrackedAuthorRefreshes.removeAll { $0 == author.recid }
                startQueuedTrackedAuthorRefreshes()
            }
            await reloadAuthors()
        } catch { errorMessage = "无法更新关注状态。" }
    }

    func toggleReadSelectedPaper() {
        guard let paper = selectedPaper else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.paperSync.markRead(!paper.isRead, paperID: paper.literatureID)
                // Research Home is projected from the same durable library
                // snapshot as Radar and Notebook.  Refresh it immediately
                // after the local read-state write so the Inbox metric cannot
                // lag behind the active paper detail.
                await self.refreshWorkbench()
                if let author = self.selectedAuthorID { await self.loadPapers(for: author, syncIfNeeded: false) }
            } catch { self.errorMessage = "无法更新已读状态。" }
        }
    }

    func generateSelectedInsight() {
        guard let paper = selectedPaper else { return }
        requestInsight(for: paper, trigger: .manual)
    }

    func cancelInsight() {
        analysisDebounceTask?.cancel()
        analysisDebounceTask = nil
        if let activeInsightCacheKey {
            automaticInsightTerminalMessages[activeInsightCacheKey] = "已取消；不会自动重试。请使用“重新生成”明确重试。"
        }
        insightTask?.cancel()
        insightSessionID = UUID()
        activeInsightCacheKey = nil
        if isInsightRunning { insightState = .cancelled }
        insightStartedAt = nil
    }

    func cancelEvidenceInsight() {
        evidenceInsightTask?.cancel()
        evidenceInsightTask = nil
        evidenceInsightSessionID = UUID()
        if case .idle = evidenceInsightState {} else { evidenceInsightState = .cancelled }
        evidenceInsightStartedAt = nil
    }

    func cancelVision() {
        visionPreflightTask?.cancel()
        visionTask?.cancel()
        visionTask = nil
        visionSessionID = UUID()
        pendingVisionPaper = nil
        pendingVisionRequest = nil
        visionPreflight = nil
        if case .idle = visionState {} else { visionState = .cancelled }
        visionStartedAt = nil
    }

    func acceptPrivacyDisclosure() {
        var updated = settings
        updated.recordConsent(for: updated.activeProvider)
        saveSettings(updated, apiKey: nil)
        presentPrivacyDisclosure = false
        guard let paper = pendingInsightPaper, selectedPaperID == paper.literatureID else { return }
        pendingInsightPaper = nil
        requestInsight(for: paper, trigger: .manual)
    }

    func acceptEvidencePrivacyDisclosure() {
        var updated = settings
        updated.recordConsent(for: updated.activeProvider, sourceScope: PaperInsightV2Validator.sourceScope, sendsImagePixels: false)
        saveSettings(updated, apiKey: nil)
        presentEvidencePrivacyDisclosure = false
        guard let paper = pendingEvidencePaper, selectedPaperID == paper.literatureID else { return }
        pendingEvidencePaper = nil
        startEvidenceInsightTask(for: paper)
    }

    func declineEvidencePrivacyDisclosure() {
        pendingEvidencePaper = nil
        presentEvidencePrivacyDisclosure = false
        evidenceInsightState = .idle
    }

    func acceptVisionPrivacyDisclosure() {
        var updated = settings
        updated.recordConsent(for: updated.activeProvider, sourceScope: "fulltext_plus_vision", sendsImagePixels: true)
        saveSettings(updated, apiKey: nil)
        presentVisionPrivacyDisclosure = false
        guard let paper = pendingVisionPaper, let prepared = pendingVisionRequest,
              selectedPaperID == paper.literatureID, prepared.paperID == paper.literatureID,
              prepared.preflight == visionPreflight else { return }
        pendingVisionPaper = nil
        pendingVisionRequest = nil
        startVisionTask(for: paper, prepared: prepared)
    }

    func declineVisionPrivacyDisclosure() {
        pendingVisionPaper = nil
        pendingVisionRequest = nil
        visionPreflight = nil
        presentVisionPrivacyDisclosure = false
        visionState = .idle
    }

    func declinePrivacyDisclosure() {
        pendingInsightPaper = nil
        presentPrivacyDisclosure = false
        insightState = .idle
    }

    func saveSettings(_ values: LLMSettings, apiKey: String?) {
        var updated = values
        do { try LLMSettings.validate(profile: updated.activeProfile) }
        catch { errorMessage = "设置未保存：\(error.localizedDescription)"; return }
        if let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                try keychain.save(apiKey, service: Self.keychainService, account: values.activeProvider.rawValue)
                updated.credentialRevision += 1
            } catch { errorMessage = "无法保存 API Key 到钥匙串。" }
        }
        // Configuration changes invalidate every in-flight frozen prompt or
        // discovery session; a late callback is also rejected by its session
        // id before it can publish state/cache data.
        if updated.sessionFingerprint != settings.sessionFingerprint {
            cancelInsight(); cancelEvidenceInsight(); cancelVision(); cancelModelDiscovery()
        }
        settings = updated
        if !usesFixtureDependencies, let data = try? JSONEncoder.latticeLens.encode(updated) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    /// Returns whether the Keychain deletion committed. Callers must preserve
    /// their visible saved state when this returns `false`; otherwise a UI
    /// could incorrectly claim that a credential was removed after a denied
    /// or unavailable Keychain operation.
    @discardableResult
    func clearAPIKey(for provider: LLMProvider) -> Bool {
        do {
            try keychain.delete(service: Self.keychainService, account: provider.rawValue)
            // `settings` is an @Published value type.  Do not mutate its
            // nested field through the wrapper here: on some SwiftUI/AppKit
            // sheet paths that does not reliably invalidate a conditional
            // accessibility subtree.  A complete value reassignment makes
            // the successful Keychain commit observable before SettingsView
            // re-reads the Keychain-authoritative saved/missing state.
            var updated = settings
            updated.credentialRevision += 1
            settings = updated
            cancelInsight(); cancelEvidenceInsight(); cancelVision(); cancelModelDiscovery()
            if !usesFixtureDependencies, let data = try? JSONEncoder.latticeLens.encode(settings) {
                UserDefaults.standard.set(data, forKey: Self.settingsKey)
            }
            return true
        } catch {
            errorMessage = "无法清除钥匙串中的 API Key。"
            return false
        }
    }

    func apiKeyIsSaved(for provider: LLMProvider) -> Bool {
        (try? keychain.contains(service: Self.keychainService, account: provider.rawValue)) ?? false
    }

    /// Resolves only a non-secret saved/missing status for Settings.  Keychain
    /// reads can synchronously wait for SecurityServer; never perform that
    /// work from a SwiftUI `body` evaluation or the AppKit main thread can
    /// enter a render loop while the sheet is being presented.
    func apiKeySavedStatus(for provider: LLMProvider) async -> Bool {
        let keychain = keychain
        let service = Self.keychainService
        return await Task.detached(priority: .userInitiated) {
            (try? keychain.contains(service: service, account: provider.rawValue)) ?? false
        }.value
    }

    /// Discovery can use a newly typed (not-yet-saved) key or the selected
    /// provider's saved Keychain key, so users need not re-enter a secret just
    /// to refresh a model list.
    func discoverModels(profile: ProviderProfile, provider: LLMProvider, apiKey: String? = nil) async throws -> [String] {
        modelDiscoveryTask?.cancel()
        let session = UUID()
        modelDiscoverySessionID = session
        let credential = try await providerCredential(provider: provider, typedAPIKey: apiKey)
        let discoverer = modelDiscoverer
        let task = Task { try await discoverer.discoverModels(profile: profile, provider: provider, apiKey: credential) }
        modelDiscoveryTask = task
        defer {
            if modelDiscoverySessionID == session { modelDiscoveryTask = nil }
        }
        let models = try await task.value
        guard modelDiscoverySessionID == session else { throw CancellationError() }
        return models
    }

    /// A probe is not discovery: it has no model-list side effect and does
    /// not turn a successful endpoint response into a claim about available
    /// model IDs.  The same endpoint and credential guards nevertheless
    /// apply before any request is built.
    func testProviderConnection(profile: ProviderProfile, provider: LLMProvider, apiKey: String? = nil) async throws -> ProviderConnectionProbe {
        let credential = try await providerCredential(provider: provider, typedAPIKey: apiKey)
        return try await connectionTester.testConnection(profile: profile, provider: provider, apiKey: credential)
    }

    func cancelModelDiscovery() {
        modelDiscoverySessionID = UUID()
        modelDiscoveryTask?.cancel()
        modelDiscoveryTask = nil
    }

    /// `SecItemCopyMatching` can synchronously wait on SecurityServer.  Every
    /// caller starts from an interactive Settings or analysis action on the
    /// main actor, so move the secret read to a detached task.  This helper
    /// never logs or persists the credential bytes.
    private func storedAPIKey(for provider: LLMProvider) async throws -> String? {
        let keychain = keychain
        let service = Self.keychainService
        let account = provider.rawValue
        return try await Task.detached(priority: .userInitiated) {
            try keychain.read(service: service, account: account)
        }.value
    }

    private func providerCredential(provider: LLMProvider, typedAPIKey: String?) async throws -> String {
        let typedKey = typedAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !typedKey.isEmpty { return typedKey }
        if let saved = try await storedAPIKey(for: provider),
           !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return saved
        }
        if provider.apiKeyIsRequired { throw LatticeLensError.missingCredential }
        // Local OpenAI-compatible endpoints may intentionally have no
        // credential. The transport omits Authorization entirely.
        return ""
    }

    func dismissError() { errorMessage = nil }

    func fetchBibTeXForSelectedPaper() {
        guard let paper = selectedPaper else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let record = try await self.referenceManager.fetchAndCacheBibTeX(for: paper.literatureID)
                self.selectedBibTeXRecord = record
            } catch { self.errorMessage = "BibTeX 获取失败；旧的 verified record 保持不变：\(error.localizedDescription)" }
        }
    }

    func prepareSelectedBibTeXExport() async -> String? {
        guard let paper = selectedPaper else { return nil }
        do {
            let contents = try await referenceManager.prepareExportContents(paperIDs: [paper.literatureID], format: .bibtex)
            pendingBibTeXExport = ([paper.literatureID], .bibtex, contents)
            return contents
        }
        catch { errorMessage = "BibTeX 导出失败：\(error.localizedDescription)"; return nil }
    }

    func finishSelectedBibTeXExport(_ result: Result<URL, Error>) {
        guard let pending = pendingBibTeXExport else { return }
        pendingBibTeXExport = nil
        Task { [weak self] in
            guard let self else { return }
            let succeeded: Bool
            let category: String
            let error: String?
            switch result {
            case .success(let url): succeeded = true; category = url.pathExtension.isEmpty ? "user-selected" : "user-selected.\(url.pathExtension)"; error = nil
            case .failure(let failure): succeeded = false; category = "user-selected"; error = (failure as NSError).code == NSUserCancelledError ? "cancelled" : String(describing: failure)
            }
            try? await self.referenceManager.recordExportOutcome(paperIDs: pending.paperIDs, format: pending.format,
                                                                 contents: pending.contents, succeeded: succeeded,
                                                                 destinationCategory: category, errorCategory: error)
            await self.refreshWorkbench()
        }
    }

    func prepareSelectedMarkdownExport() async throws -> String {
        guard let paper = selectedPaper else { throw LatticeLensError.malformedPayload }
        let contents = try await referenceManager.prepareExportContents(paperIDs: [paper.literatureID], format: .markdownNotebook)
        pendingMarkdownExport = ([paper.literatureID], .markdownNotebook, contents)
        return contents
    }

    func finishSelectedMarkdownExport(_ result: Result<URL, Error>) {
        guard let pending = pendingMarkdownExport else { return }
        pendingMarkdownExport = nil
        Task { [weak self] in
            guard let self else { return }
            let succeeded: Bool; let category: String; let error: String?
            switch result {
            case .success(let url): succeeded = true; category = url.pathExtension.isEmpty ? "user-selected" : "user-selected.\(url.pathExtension)"; error = nil
            case .failure(let failure): succeeded = false; category = "user-selected"; error = (failure as NSError).code == NSUserCancelledError ? "cancelled" : String(describing: failure)
            }
            try? await self.referenceManager.recordExportOutcome(paperIDs: pending.paperIDs, format: pending.format,
                                                                 contents: pending.contents, succeeded: succeeded,
                                                                 destinationCategory: category, errorCategory: error)
            await self.refreshWorkbench()
        }
    }

    func createUserAnnotation(from anchor: EvidenceAnchor, label: String = "local annotation", note: String = "") {
        annotationStatusMessage = "正在保存本地 annotation…"
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await store.snapshot()
            // Metadata anchors do not carry a PDF character range.  A PDF
            // chunk does, so annotations created from it retain the exact
            // extraction range and quote/hash rather than a fuzzy search key.
            let chunk = snapshot.evidenceChunks[anchor.id]
            let now = Date()
            let annotation = UserEvidenceAnchor(id: UUID(), paperID: anchor.paperID,
                                                documentHash: chunk?.documentHash ?? self.selectedFullTextDocument?.sha256,
                                                sourceKind: anchor.sourceKind, page: anchor.page,
                                                characterRangeStart: chunk?.characterRangeStart,
                                                characterRangeEnd: chunk?.characterRangeEnd,
                                                quote: anchor.quote, quoteHash: anchor.quoteHash,
                                                colorName: "yellow", label: label, note: note, status: .valid,
                                                createdAt: now, updatedAt: now)
            do {
                try await store.applyV3(.saveUserAnchor(annotation))
                await refreshWorkbench()
                annotationStatusMessage = "本地 annotation 已保存"
            } catch {
                annotationStatusMessage = "本地 annotation 保存失败"
                errorMessage = "无法保存 annotation：\(error.localizedDescription)"
            }
        }
    }

    /// PDFKit emits a selection only after the reader proved it maps to a
    /// unique exact page range.  Recheck the currently selected document here
    /// so a late sheet callback cannot attach a quote to a newly selected
    /// paper/document.
    func createUserAnnotation(fromPDFSelection selection: PDFTextSelectionAnchor, document: FullTextDocument?,
                              label: String = "PDF selection", note: String = "") {
        guard let document, document.paperID == selectedPaperID,
              document.sha256 == selectedFullTextDocument?.sha256,
              !selection.quote.isEmpty,
              StableHash.sha256(selection.quote) == selection.quoteHash else {
            errorMessage = "PDF selection 已过期或无法验证；未创建 annotation。"
            return
        }
        let annotation = UserEvidenceAnchor(id: UUID(), paperID: document.paperID, documentHash: document.sha256,
                                            sourceKind: .pdf, page: selection.page,
                                            characterRangeStart: selection.characterRangeStart,
                                            characterRangeEnd: selection.characterRangeEnd,
                                            quote: selection.quote, quoteHash: selection.quoteHash,
                                            colorName: "yellow", label: label, note: note, status: .valid,
                                            createdAt: Date(), updatedAt: Date())
        Task { [weak self] in
            guard let self else { return }
            do { try await self.store.applyV3(.saveUserAnchor(annotation)); await self.refreshWorkbench() }
            catch { self.errorMessage = "无法保存 PDF selection annotation：\(error.localizedDescription)" }
        }
    }

    func updateUserAnnotation(_ annotation: UserEvidenceAnchor) {
        Task { [weak self] in
            guard let self else { return }
            do { try await self.store.applyV3(.saveUserAnchor(annotation)); await self.refreshWorkbench() }
            catch { self.errorMessage = "annotation 未保存：\(error.localizedDescription)" }
        }
    }

    func deleteUserAnnotation(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do { try await self.store.applyV3(.deleteUserAnchor(id)); await self.refreshWorkbench() }
            catch { self.errorMessage = "annotation 未删除：\(error.localizedDescription)" }
        }
    }

    /// Cross-surface evidence navigation used by Compare/Radar/Notebook.  It
    /// carries the concrete quote/page—not merely a paper ID—so the reader
    /// can open the exact local PDF anchor after the paper context reloads.
    func openEvidenceAnchor(_ anchor: EvidenceAnchor) {
        evidenceJumpAnchor = anchor
        if selectedPaperID != anchor.paperID { selectPaper(anchor.paperID) }
    }

    func consumeEvidenceJump(_ anchorID: String) {
        guard evidenceJumpAnchor?.id == anchorID else { return }
        evidenceJumpAnchor = nil
    }

    // MARK: Evidence Workbench (v3)

    func refreshWorkbench() async {
        workbenchSnapshot = await store.snapshot()
    }

    func refreshRadarQuery(_ query: SavedInspireQuery) {
        let key = radarOwnerKey(query.id)
        let token = jobOwners.begin(key: key)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.jobOwners.finish(key: key, token: token) }
            do {
                _ = try await self.workbench.refreshSavedQuery(query)
                await self.refreshWorkbench()
            } catch is CancellationError {
                // A user cancellation is visible through the durable batch;
                // it is not reported as a network failure.
            } catch {
                self.errorMessage = "Radar refresh 失败：\(error.localizedDescription)"
                await self.refreshWorkbench()
            }
        }
        jobOwners.install(key: key, token: token, task: task)
    }

    func runDueRadarQueries() {
        let now = Date()
        for query in workbenchSnapshot.savedInspireQueries.values where !query.isPaused && query.refreshPolicy != .manual {
            guard query.nextRunAt == nil || query.nextRunAt! <= now else { continue }
            refreshRadarQuery(query)
        }
    }

    func acknowledgeRadarEvent(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await workbench.acknowledgeRadarEvent(id)
                await refreshWorkbench()
            } catch { errorMessage = "无法确认 Radar event：\(error.localizedDescription)" }
        }
    }

    func saveRadarQuery(name: String, query: String, policy: SavedQueryRefreshPolicy) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedQuery.isEmpty, trimmedName.unicodeScalars.count <= 120,
              trimmedQuery.unicodeScalars.count <= 1_000 else {
            errorMessage = "Radar query 名称和查询不能为空且必须在本地上限内。"
            return
        }
        let now = Date()
        let saved = SavedInspireQuery(id: UUID(), name: trimmedName, query: trimmedQuery, refreshPolicy: policy,
                                      isPaused: false, lastRunAt: nil, nextRunAt: nil, createdAt: now)
        Task { [weak self] in
            guard let self else { return }
            do { try await store.applyV3(.saveQuery(saved)); await refreshWorkbench() }
            catch { errorMessage = "无法保存 Radar query：\(error.localizedDescription)" }
        }
    }

    func setRadarQueryPaused(_ query: SavedInspireQuery, paused: Bool) {
        var updated = query
        updated.isPaused = paused
        if paused { jobOwners.cancel(key: radarOwnerKey(query.id)) }
        // Publish the requested durable state immediately so the active Radar
        // row changes from Pause to Resume without waiting for the actor hop.
        // A persistence failure still refreshes from authoritative storage.
        var optimistic = workbenchSnapshot
        optimistic.savedInspireQueries[updated.id] = updated
        workbenchSnapshot = optimistic
        Task { [weak self] in
            guard let self else { return }
            do { try await store.applyV3(.saveQuery(updated)); await refreshWorkbench() }
            catch {
                await refreshWorkbench()
                errorMessage = "无法更新 Radar query：\(error.localizedDescription)"
            }
        }
    }

    func deleteRadarQuery(_ id: UUID) {
        jobOwners.cancel(key: radarOwnerKey(id))
        Task { [weak self] in
            guard let self else { return }
            do { try await store.applyV3(.deleteQuery(id)); await refreshWorkbench() }
            catch { errorMessage = "无法删除 Radar query：\(error.localizedDescription)" }
        }
    }

    func dryRunNotebookImport(url: URL, format: V3ExportFormat) async throws -> V3ImportResult {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= V3NotebookImporter.maximumBytes else {
            throw LatticeLensError.schemaViolation("导入文件不是普通文件或超过 5 MiB 本地上限")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try V3NotebookImporter.parse(data: data, format: format, snapshot: await store.snapshot(),
                                            sourceCategory: "local-user-selected")
    }

    func commitNotebookImport(_ result: V3ImportResult) {
        Task { [weak self] in
            guard let self else { return }
            do {
                // Commit only the dry-run records the user just confirmed.
                // The parser never applies imported metadata over an INSPIRE
                // paper, so conflict review remains explicit and non-lossy.
                for record in result.records { try await self.store.applyV3(.saveImportedBibliography(record)) }
                for conflict in result.conflicts { try await self.store.applyV3(.saveImportConflict(conflict)) }
                await self.refreshWorkbench()
            } catch { self.errorMessage = "Bibliography 导入提交失败；未将失败标为已导入：\(error.localizedDescription)" }
        }
    }

    /// Compatibility action retained for older callers.  UI product paths use
    /// `dryRunNotebookImport` and explicit `commitNotebookImport` instead.
    func importNotebookFile(url: URL, format: V3ExportFormat) {
        Task { [weak self] in
            guard let self else { return }
            do { self.commitNotebookImport(try await self.dryRunNotebookImport(url: url, format: format)) }
            catch { self.errorMessage = "Bibliography 导入预检失败：\(error.localizedDescription)" }
        }
    }

    func setImportConflictStatus(_ conflict: V3ImportConflict, status: V3ImportReviewStatus) {
        Task { [weak self] in
            guard let self else { return }
            do { try await self.workbench.setImportConflictStatus(importedID: conflict.importedID, status: status); await self.refreshWorkbench() }
            catch { self.errorMessage = "导入冲突状态未保存：\(error.localizedDescription)" }
        }
    }

    func acceptImportConflict(_ conflict: V3ImportConflict, acceptedFields: Set<String>) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.workbench.acceptImportConflict(importedID: conflict.importedID, acceptedFields: acceptedFields)
                await self.refreshWorkbench()
            } catch {
                self.errorMessage = "导入字段未合并：\(error.localizedDescription)"
            }
        }
    }

    func saveNotebookEntry(id: UUID? = nil, paperID: Int, title: String, body: String, anchorIDs: [String]) {
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.workbench.saveNotebookEntry(id: id, paperID: paperID, title: title, body: body, anchorIDs: anchorIDs); await self.refreshWorkbench() }
            catch { self.errorMessage = "Notebook entry 未保存：\(error.localizedDescription)" }
        }
    }

    func deleteNotebookEntry(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do { try await self.workbench.deleteNotebookEntry(id); await self.refreshWorkbench() }
            catch { self.errorMessage = "Notebook entry 未删除：\(error.localizedDescription)" }
        }
    }

    func updatePhysicsCell(_ cell: PhysicsContractCell) {
        Task { [weak self] in
            guard let self else { return }
            do { try await self.workbench.updatePhysicsCell(cell); await self.refreshWorkbench() }
            catch { self.errorMessage = "Physics cell 未保存：\(error.localizedDescription)" }
        }
    }

    func createCompareWorkspace(name: String, paperIDs: [Int]) {
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await workbench.createWorkspace(name: name, paperIDs: paperIDs); await refreshWorkbench() }
            catch { errorMessage = "无法创建 Compare workspace：\(error.localizedDescription)" }
        }
    }

    func extractLocalCompareWorkspace(_ workspaceID: UUID) {
        compareExtractionStatus = "正在以本地 evidence anchors 提取 Compare matrix…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let cells = try await workbench.extractLocalCompareMatrix(workspaceID: workspaceID)
                await refreshWorkbench()
                compareExtractionStatus = "已从本地 evidence anchors 提取 \(cells.count) 个 Compare cells。"
            } catch {
                // The service keeps the last accepted matrix intact on every
                // rejection; this message deliberately does not claim a
                // partial extraction was saved.
                compareExtractionStatus = "本地 Compare 提取被证据契约拒绝；旧矩阵未改动。"
                errorMessage = "本地 Compare 提取被证据契约拒绝；旧矩阵未改动：\(error.localizedDescription)"
                await refreshWorkbench()
            }
        }
    }

    func prepareWorkbenchExport(paperIDs: [Int], format: V3ExportFormat, includeLocalPDFPath: Bool = false) async -> String? {
        do {
            let contents = try await referenceManager.prepareExportContents(paperIDs: paperIDs, format: format, includeLocalPDFPath: includeLocalPDFPath)
            pendingWorkbenchExport = (paperIDs, format, contents)
            return contents
        }
        catch { errorMessage = "无法准备 \(format.rawValue) 导出：\(error.localizedDescription)"; return nil }
    }

    func finishWorkbenchExport(_ result: Result<URL, Error>) {
        guard let pending = pendingWorkbenchExport else { return }
        pendingWorkbenchExport = nil
        Task { [weak self] in
            guard let self else { return }
            let succeeded: Bool; let category: String; let error: String?
            switch result {
            case .success(let url):
                succeeded = true; category = url.pathExtension.isEmpty ? "user-selected" : "user-selected.\(url.pathExtension)"; error = nil
            case .failure(let failure):
                succeeded = false; category = "user-selected"
                error = (failure as NSError).code == NSUserCancelledError ? "cancelled" : String(describing: failure)
            }
            do {
                try await self.referenceManager.recordExportOutcome(paperIDs: pending.paperIDs, format: pending.format,
                                                                     contents: pending.contents, succeeded: succeeded,
                                                                     destinationCategory: category, errorCategory: error)
                await self.refreshWorkbench()
            } catch {
                self.errorMessage = "无法写入导出结果账本；不会把导出标记为成功：\(error.localizedDescription)"
            }
        }
    }

    func reportUserError(_ message: String) { errorMessage = message }

    /// Compatibility entry point for callers that need the current durable
    /// author snapshot.  Search itself is derived by AuthorSidebar from this
    /// snapshot and deliberately does not call this method.
    func refreshVisibleAuthors() async { await reloadAuthors() }

    func clearAIResults() async {
        await clearAIResults(scope: .all)
    }

    func aiClearPreview(scope: AIArtifactClearScope) async -> V4AIClearPreview {
        V4AIClearPreview.make(scope: scope, snapshot: await store.snapshot())
    }

    func clearAIResults(scope: AIArtifactClearScope) async {
        do {
            let snapshot = await store.snapshot()
            let preview = V4AIClearPreview.make(scope: scope, snapshot: snapshot)
            if scope == .insight || scope == .all {
                try await store.removeInsights()
                insightArtifact = nil; insightState = .idle
            }
            if scope == .evidenceInsight || scope == .all {
                for key in snapshot.evidenceInsights.keys { try await store.applyV3(.deleteEvidenceInsight(key)) }
                evidenceInsightArtifact = nil; evidenceInsightState = .idle
            }
            if scope == .vision || scope == .all {
                for key in snapshot.visionArtifacts.keys { try await store.applyV3(.deleteVisionArtifact(key)) }
                visionArtifact = nil; visionState = .idle
            }
            // This ledger intentionally records only scope, count and paper
            // IDs—not prompt/response contents, provider credentials or local
            // paths.  It lets a user audit a destructive cache action after a
            // relaunch while preserving the artifact privacy boundary.
            let now = Date()
            let batchID = UUID()
            let jobID = "ai-clear:\(scope.rawValue)"
            let batch = SyncBatchV3(id: batchID, jobID: jobID, generationID: "local-cache",
                                    startedAt: now, completedAt: now, state: .completed,
                                    newRecords: 0, metadataUpdated: 0, citationChanged: 0,
                                    unchanged: 0, failed: 0, durationMilliseconds: 0)
            try await store.applyV3(.saveBatch(batch))
            let paperSet = preview.paperIDs.map(String.init).joined(separator: ",")
            try await store.applyV3(.saveJobEvent(SyncJobEvent(id: UUID(), batchID: batchID, jobID: jobID, kind: .completed,
                                                                page: nil, completed: preview.deletionCount, qualified: 0,
                                                                rejected: 0, failed: 0, remaining: 0, observedAt: now,
                                                                message: "scope=\(scope.rawValue); papers=\(paperSet)")))
            await refreshWorkbench()
        } catch { errorMessage = "无法清除本地 AI 结果；未把失败写成已删除。" }
    }

    /// Produces a deliberately secret-free, validated reading note. The caller
    /// chooses whether to copy it or to export it to a user-selected location.
    func selectedPaperMarkdownNote() async throws -> String {
        guard let paper = selectedPaper else { throw LatticeLensError.malformedPayload }
        return try await referenceManager.markdownNote(for: paper.literatureID)
    }

    /// Clipboard is an explicit user action. UI fixtures must remain isolated
    /// from the user's general pasteboard, so the test app rejects this path.
    func copySelectedPaperMarkdownNote() {
        guard !usesFixtureDependencies else {
            errorMessage = "UI fixture 不访问通用剪贴板。"
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let markdown = try await self.selectedPaperMarkdownNote()
                guard self.selectedPaper != nil else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown, forType: .string)
            } catch {
                self.errorMessage = "无法复制 Markdown note：\(error.localizedDescription)"
            }
        }
    }

    func refreshGlobalPaperSearch() {
        let query = globalPaperSearch
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.store.snapshot()
            let index = V4LocalSearchIndex.rebuild(snapshot: snapshot)
            let hits = index.search(query, snapshot: snapshot)
            let resultIDs = Set(hits.map(\.paperID))
            let results = snapshot.papers.values.filter { resultIDs.contains($0.literatureID) }
                .sorted { $0.literatureID < $1.literatureID }
            guard self.globalPaperSearch == query else { return }
            self.globalPaperResults = results
            self.globalSearchHits = hits
        }
    }

    func toggleFavoriteSelectedPaper() {
        guard let paper = selectedPaper else { return }
        let current = isFavorite(paper)
        var optimisticPaper = paper
        optimisticPaper.isFavorite = !current
        favoriteStateProjections[paper.literatureID] = !current
        var updatedPapers = papers
        if let index = updatedPapers.firstIndex(where: { $0.literatureID == paper.literatureID }) {
            // Publish an immediate local projection for the active detail
            // view.  The durable store mutation below remains authoritative;
            // on failure we reload that authoritative paper list.
            updatedPapers[index] = optimisticPaper
            papers = updatedPapers
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.referenceManager.toggleFavorite(paperID: paper.literatureID, current: current)
                // Favorite state is also shown by Research Home.  The detail
                // view has an optimistic projection, but Home must continue
                // to reflect the authoritative fixture/SwiftData snapshot.
                await self.refreshWorkbench()
                await self.reloadSelectedPaperContext(for: paper.literatureID)
                if let author = self.selectedAuthorID { await self.loadPapers(for: author, syncIfNeeded: false) }
                self.refreshGlobalPaperSearch()
            } catch {
                self.favoriteStateProjections.removeValue(forKey: paper.literatureID)
                if let author = self.selectedAuthorID { await self.loadPapers(for: author, syncIfNeeded: false) }
                self.errorMessage = "无法更新收藏状态。"
            }
        }
    }

    func saveSelectedPaperNote(_ body: String, existing: UserNote? = nil) {
        guard let paper = selectedPaper else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.referenceManager.saveNote(id: existing?.id, paperID: paper.literatureID, body: body,
                                                         existingCreatedAt: existing?.createdAt)
                await self.reloadSelectedPaperContext(for: paper.literatureID)
            } catch { self.errorMessage = "无法保存本地 note：\(error.localizedDescription)" }
        }
    }

    func deleteNote(_ note: UserNote) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.referenceManager.deleteNote(note.id)
                await self.reloadSelectedPaperContext(for: note.paperID)
            } catch { self.errorMessage = "无法删除本地 note。" }
        }
    }

    func createTag(named name: String, colorName: String? = nil) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.referenceManager.createTag(named: name, colorName: colorName)
                await self.reloadSelectedPaperContext(for: self.selectedPaperID)
            } catch { self.errorMessage = "无法创建 tag：\(error.localizedDescription)" }
        }
    }

    func renameTag(_ tag: LibraryTag, to name: String) {
        Task { [weak self] in
            guard let self else { return }
            do { try await self.referenceManager.renameTag(tag.id, to: name); await self.reloadSelectedPaperContext(for: self.selectedPaperID) }
            catch { self.errorMessage = "无法重命名 tag：\(error.localizedDescription)" }
        }
    }

    func deleteTag(_ tag: LibraryTag) {
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.referenceManager.deleteTag(tag.id); await self.reloadSelectedPaperContext(for: self.selectedPaperID) }
            catch { self.errorMessage = "无法删除 tag：\(error.localizedDescription)" }
        }
    }

    func setSelectedPaperTags(_ tagIDs: Set<UUID>) {
        guard let paper = selectedPaper else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.referenceManager.setTags(tagIDs, paperID: paper.literatureID)
                await self.reloadSelectedPaperContext(for: paper.literatureID)
            } catch { self.errorMessage = "无法更新 tags。" }
        }
    }

    func createCollection(named name: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.referenceManager.createCollection(named: name)
                await self.reloadSelectedPaperContext(for: self.selectedPaperID)
            } catch { self.errorMessage = "无法创建 collection：\(error.localizedDescription)" }
        }
    }

    func renameCollection(_ collection: PaperCollection, to name: String) {
        Task { [weak self] in
            guard let self else { return }
            do { try await self.referenceManager.renameCollection(collection.id, to: name); await self.reloadSelectedPaperContext(for: self.selectedPaperID) }
            catch { self.errorMessage = "无法重命名 collection：\(error.localizedDescription)" }
        }
    }

    func deleteCollection(_ collection: PaperCollection) {
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.referenceManager.deleteCollection(collection.id); await self.reloadSelectedPaperContext(for: self.selectedPaperID) }
            catch { self.errorMessage = "无法删除 collection：\(error.localizedDescription)" }
        }
    }

    func setSelectedPaperCollection(_ collectionID: UUID, contains: Bool) {
        guard let paper = selectedPaper else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = await self.store.snapshot()
                var ids = Set(snapshot.collectionPapers.filter { $0.collectionID == collectionID }.map(\.paperID))
                if contains { ids.insert(paper.literatureID) } else { ids.remove(paper.literatureID) }
                try await self.referenceManager.setCollection(ids, collectionID: collectionID)
                await self.reloadSelectedPaperContext(for: paper.literatureID)
            } catch { self.errorMessage = "无法更新 collection。" }
        }
    }

    /// Applies the checkbox draft from the collection-management sheet.  The
    /// draft itself is UI-local; this method is reached only after an explicit
    /// Apply action, so Cancel cannot mutate the selected paper's durable
    /// collection links.
    func setSelectedPaperCollections(_ collectionIDs: Set<UUID>) {
        guard let paper = selectedPaper else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = await self.store.snapshot()
                for collectionID in snapshot.collections.keys {
                    var paperIDs = Set(snapshot.collectionPapers.filter { $0.collectionID == collectionID }.map(\.paperID))
                    if collectionIDs.contains(collectionID) { paperIDs.insert(paper.literatureID) }
                    else { paperIDs.remove(paper.literatureID) }
                    try await self.referenceManager.setCollection(paperIDs, collectionID: collectionID)
                }
                await self.reloadSelectedPaperContext(for: paper.literatureID)
            } catch {
                self.errorMessage = "无法更新 collections。"
            }
        }
    }

    /// HEAD-only, bounded preflight.  It deliberately runs before the GET and
    /// freezes the selected source for the following consent alert.
    func requestFullTextPreflight(_ source: PaperDocument) {
        guard let paper = selectedPaper, let url = source.url else { return }
        guard source.isFullText else { errorMessage = "该 INSPIRE document 未标记为可用全文。"; return }
        fullTextStatusMessage = "正在读取 PDF 下载预检（未发送 GET）…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let preflight = try await self.fullTextService.preflight(sourceURL: url)
                guard self.selectedPaperID == paper.literatureID else { return }
                self.pendingFullTextSource = source
                self.fullTextPreflight = preflight
                self.fullTextStatusMessage = "PDF 下载预检完成；等待确认。"
                self.presentFullTextPreflight = true
            } catch {
                self.fullTextStatusMessage = "PDF 下载预检失败；未开始下载：\(error.localizedDescription)"
            }
        }
    }

    func confirmFullTextDownload() {
        guard let source = pendingFullTextSource else { return }
        pendingFullTextSource = nil
        presentFullTextPreflight = false
        downloadFullText(source)
    }

    func cancelFullTextPreflight() {
        pendingFullTextSource = nil
        fullTextPreflight = nil
        presentFullTextPreflight = false
        fullTextStatusMessage = "已取消全文下载；未开始 GET。"
    }

    /// Performs the user-confirmed GET after `requestFullTextPreflight`.  It
    /// is also kept as a narrow programmatic entry for existing local tests.
    func downloadFullText(_ source: PaperDocument) {
        guard let paper = selectedPaper, let url = source.url else { return }
        guard source.isFullText else { errorMessage = "该 INSPIRE document 未标记为可用全文。"; return }
        let sourceKind: FullTextSourceKind = (source.source?.lowercased().contains("arxiv") ?? false) ? .arxivPDF : .inspireDocument
        fullTextTask?.cancel()
        let session = UUID()
        fullTextSessionID = session
        fullTextStatusMessage = "正在按用户请求下载全文…"
        fullTextTask = Task { [weak self] in
            guard let self else { return }
            do {
                let document = try await self.fullTextService.downloadAndExtract(paperID: paper.literatureID, sourceURL: url, sourceKind: sourceKind)
                guard self.fullTextSessionID == session else { return }
                await self.reloadSelectedPaperContext(for: paper.literatureID)
                guard self.fullTextSessionID == session else { return }
                // This success message is an observable completion boundary:
                // its page-level anchors and local document must already be
                // present in the selected-paper projection when it appears.
                self.fullTextStatusMessage = document.extractionState == .extracted ? "全文已提取为页级 evidence anchors。" : "全文下载完成，但无法提取文本。"
            } catch is CancellationError {
                guard self.fullTextSessionID == session else { return }
                self.fullTextStatusMessage = "全文下载已取消。"
            } catch {
                guard self.fullTextSessionID == session else { return }
                self.fullTextStatusMessage = "全文下载/提取失败：\(error.localizedDescription)"
            }
        }
    }

    func deleteSelectedFullText() {
        guard let document = selectedFullTextDocument else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.fullTextService.delete(document: document)
                self.fullTextStatusMessage = "已删除本地全文、PDF chunks 和依赖的 v2 evidence artifact；metadata anchors 被保留。"
                await self.reloadSelectedPaperContext(for: document.paperID)
            } catch { self.errorMessage = "无法删除本地全文：\(error.localizedDescription)" }
        }
    }

    func cancelFullTextDownload() { fullTextTask?.cancel() }

    func generateSelectedEvidenceInsight() {
        guard let paper = selectedPaper else { return }
        guard selectedFullTextDocument?.extractionState == .extracted else {
            errorMessage = "请先由用户明确下载全文，并成功生成 PDF page anchors。"
            return
        }
        guard settings.hasConsent(for: settings.activeProvider, sourceScope: PaperInsightV2Validator.sourceScope, sendsImagePixels: false) else {
            pendingEvidencePaper = paper
            presentEvidencePrivacyDisclosure = true
            return
        }
        startEvidenceInsightTask(for: paper)
    }

    func generateSelectedVisionInsight() {
        guard let paper = selectedPaper else { return }
        guard settings.activeProfile.supportsVision else {
            errorMessage = "请先在设置中手工确认当前 provider/model 支持 vision；不会从模型名称猜测。"
            return
        }
        guard paper.figures.contains(where: { $0.url != nil }) else {
            errorMessage = "当前论文没有来自 INSPIRE record 的可用 figure URL。"
            return
        }
        guard settings.maximumFigures > 0 else {
            errorMessage = "Vision maximumFigures=0：按钮已禁用，provider 请求数保持 0。"
            return
        }
        visionPreflightTask?.cancel()
        visionTask?.cancel()
        let session = UUID()
        visionSessionID = session
        visionState = .connecting
        visionPreflightTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await self.visionWorkflow.prepare(for: paper, settings: self.settings)
                guard self.visionSessionID == session, self.selectedPaperID == paper.literatureID else { return }
                // Every pixel-bearing request is bound to this freshly frozen
                // payload, even if the provider had been consented earlier.
                self.pendingVisionPaper = paper
                self.pendingVisionRequest = prepared
                self.visionPreflight = prepared.preflight
                self.visionState = .idle
                self.presentVisionPrivacyDisclosure = true
            } catch is CancellationError {
                guard self.visionSessionID == session else { return }
                self.visionState = .cancelled
            } catch {
                guard self.visionSessionID == session else { return }
                self.visionState = .failed("Vision 本地预检失败；未发送像素：\(error.localizedDescription)")
            }
        }
    }

    func clearViewedImageCache() {
        // Figure rendering never clears URLCache.shared: that cache may belong
        // to metadata or provider traffic.  This build keeps no persistent
        // LatticeLens-owned image-byte cache, so there is deliberately no
        // unrelated cache to erase.
        // There is no app-owned image cache to clear in this configuration.
    }

    private func runAuthorIndex(force: Bool, session: UUID) async {
        do {
            await refreshPinnedSelf()
            _ = try await authorIndex.rebuildCandidateIndex(force: force)
            let progress = try await authorIndex.refreshHIndices(force: force)
            guard !Task.isCancelled, authorIndexSessionID == session else { return }
            authorIndexProgress = progress
            let isPartial = progress.state == .paused
            authorIndexStatus = SyncStatus(phase: isPartial ? .partial : .ready,
                                           message: isPartial
                                               ? "作者索引已部分完成；合格作者已保留，可继续重试失败项"
                                               : "作者索引已更新", completedPages: progress.completedPages,
                                           successfulRecords: progress.verified, failedRecords: progress.failed, lastUpdatedAt: Date(),
                                           remainingRecords: progress.remaining)
            await reloadAuthors()
        } catch is CancellationError {
            let stopState = authorIndexStopIntent
            await persistAuthorIndexStopState(stopState)
            authorIndexStatus = SyncStatus(phase: stopState == .paused ? .partial : .cancelled,
                                           message: stopState == .paused ? "作者索引已暂停；可从 checkpoint 继续" : "作者索引已取消；已保存完成页", completedPages: 0,
                                           successfulRecords: 0, failedRecords: 0, lastUpdatedAt: Date())
        } catch {
            authorIndexStatus = SyncStatus(phase: .stale, message: "索引刷新失败，正在保留旧列表", completedPages: 0,
                                           successfulRecords: 0, failedRecords: 1, lastUpdatedAt: Date())
            errorMessage = "作者索引刷新失败：\(error.localizedDescription)"
        }
    }

    private func startPaperSync(for recid: Int, forceFreshGeneration: Bool,
                                isTrackedRefresh: Bool = false, pageBudget: Int? = 1) {
        let ownerKey = paperSyncOwnerKey(recid)
        let ownerToken = jobOwners.begin(key: ownerKey)
        if isTrackedRefresh {
            activeTrackedAuthorRefreshes[recid] = ownerToken
        } else {
            // A user-selected/manual sync supersedes a queued background
            // refresh for the same author.  Keep a single task owner rather
            // than allowing two syncs to publish competing checkpoints.
            activeTrackedAuthorRefreshes.removeValue(forKey: recid)
            queuedTrackedAuthorRefreshes.removeAll { $0 == recid }
        }
        paperSyncTasks[recid]?.cancel()
        let session = UUID()
        paperSyncSessions[recid] = session
        if selectedAuthorID == recid {
            syncStatus = SyncStatus(phase: .syncingMetadata, message: "正在同步文献", completedPages: 0,
                                    successfulRecords: 0, failedRecords: 0, lastUpdatedAt: Date())
        }
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.jobOwners.finish(key: ownerKey, token: ownerToken)
                if isTrackedRefresh { self.finishTrackedAuthorRefresh(recid: recid, token: ownerToken) }
            }
            let result = await self.paperSync.sync(
                authorRecid: recid,
                forceFreshGeneration: forceFreshGeneration,
                pageBudget: pageBudget,
                updateSearchIndex: pageBudget == nil,
                onPageCommitted: { [weak self] status in
                    await self?.publishPaperSyncPage(status, authorRecid: recid, session: session)
                }
            )
            guard self.paperSyncSessions[recid] == session else { return }
            self.paperSyncTasks.removeValue(forKey: recid)
            if self.selectedAuthorID == recid {
                self.syncStatus = result
                await self.loadPapers(for: recid, syncIfNeeded: false)
            }
            if isTrackedRefresh { await self.reloadAuthors() }
        }
        paperSyncTasks[recid] = task
        jobOwners.install(key: ownerKey, token: ownerToken, task: task)
    }

    private func paperSyncOwnerKey(_ authorRecid: Int) -> String { "paper-sync:\(authorRecid)" }

    /// Only the task/session that owns the selected author can publish a
    /// durable page to the visible timeline.  A late callback for an author
    /// selected previously stays in the store but cannot overwrite the
    /// current author/status surface.
    private func publishPaperSyncPage(_ status: SyncStatus, authorRecid: Int, session: UUID) async {
        guard paperSyncSessions[authorRecid] == session, selectedAuthorID == authorRecid else { return }
        syncStatus = status
        await loadPapers(for: authorRecid, syncIfNeeded: false)
    }
    private func radarOwnerKey(_ queryID: UUID) -> String { "radar-query:\(queryID.uuidString)" }

    private func refreshTrackedAuthorsInForeground() async {
        let tracked = await store.trackedAuthorRecids()
        // Do not retain jobs for authors that were untracked while this app
        // was suspended.  Their durable checkpoint remains untouched; only
        // the in-process owner is cancelled.
        for recid in Array(activeTrackedAuthorRefreshes.keys) where !tracked.contains(recid) {
            jobOwners.cancel(key: paperSyncOwnerKey(recid))
            paperSyncTasks[recid]?.cancel()
            activeTrackedAuthorRefreshes.removeValue(forKey: recid)
        }
        queuedTrackedAuthorRefreshes.removeAll { !tracked.contains($0) }
        for recid in tracked.sorted()
            where activeTrackedAuthorRefreshes[recid] == nil && !queuedTrackedAuthorRefreshes.contains(recid) {
            queuedTrackedAuthorRefreshes.append(recid)
        }
        startQueuedTrackedAuthorRefreshes()
    }

    private func startQueuedTrackedAuthorRefreshes() {
        while activeTrackedAuthorRefreshes.count < maximumTrackedAuthorSyncConcurrency,
              let recid = queuedTrackedAuthorRefreshes.first {
            queuedTrackedAuthorRefreshes.removeFirst()
            guard activeTrackedAuthorRefreshes[recid] == nil else { continue }
            startPaperSync(for: recid, forceFreshGeneration: false, isTrackedRefresh: true)
        }
    }

    private func finishTrackedAuthorRefresh(recid: Int, token: UUID) {
        guard activeTrackedAuthorRefreshes[recid] == token else { return }
        activeTrackedAuthorRefreshes.removeValue(forKey: recid)
        startQueuedTrackedAuthorRefreshes()
    }

    /// Detail enrichment is deliberately best-effort.  The timeline metadata
    /// remains immediately readable if the single-record endpoint is offline,
    /// changes schema, or the user has already selected another paper.
    private func fetchSelectedPaperDetail(paperID: Int, authorRecid: Int?) async {
        paperDetailTask?.cancel()
        let session = UUID()
        paperDetailSessionID = session
        paperDetailStatusMessage = "正在更新 INSPIRE 单篇详情…"
        paperDetailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let detail = try await self.inspireClient.literatureDetail(for: paperID)
                // Global paper selection is not evidence that the current
                // sidebar author authored this record. Enrichment updates
                // only the paper row; authoritative links come from INSPIRE
                // author metadata/literature sync.
                try await self.store.upsert(detail: detail)
                guard self.paperDetailSessionID == session, self.selectedPaperID == paperID else { return }
                if let authorRecid, self.selectedAuthorID == authorRecid {
                    await self.loadPapers(for: authorRecid, syncIfNeeded: false)
                }
                let updatedRows = await self.store.papers(forIDs: [paperID])
                if let current = updatedRows[paperID],
                   let index = self.globalPaperResults.firstIndex(where: { $0.literatureID == paperID }) {
                    self.globalPaperResults[index] = current
                }
                if let current = updatedRows[paperID] {
                    try? await self.store.saveEvidenceAnchors(EvidenceAnchorFactory.metadataAnchors(for: current))
                }
                await self.reloadSelectedPaperContext(for: paperID)
                self.paperDetailStatusMessage = "INSPIRE 单篇详情已更新。"
            } catch is CancellationError {
                // A newly selected paper owns the next task; do not publish a
                // cancellation state into its Source tab.
            } catch {
                guard self.paperDetailSessionID == session, self.selectedPaperID == paperID else { return }
                self.paperDetailStatusMessage = "INSPIRE 单篇详情不可用；继续显示已同步的索引 metadata。"
            }
        }
    }

    private func loadPapers(for recid: Int, syncIfNeeded: Bool) async {
        let localPapers = await paperSync.papers(for: recid)
        guard selectedAuthorID == recid else { return }
        papers = localPapers
        guard syncIfNeeded else { return }
        // A durable partial checkpoint takes precedence over freshness.  A
        // recently successful page must not mask a failed page-2 job after an
        // app restart or author re-selection.
        let checkpoint = try? await store.checkpoint(jobID: "literature:\(recid)")
        if V4CheckpointRecovery.shouldResume(checkpoint) {
            // A relaunch must preserve the precise resume URL, but it must
            // not immediately monopolise the restored UI when a prior page
            // is already readable.  The visible Sync action resumes exactly
            // this durable checkpoint; an empty first visit still fetches one
            // small page automatically so a newly selected author is useful.
            if localPapers.isEmpty {
                startPaperSync(for: recid, forceFreshGeneration: false)
            } else if let checkpoint {
                syncStatus = SyncStatus(phase: .partial,
                                        message: "已显示 \(localPapers.count) 篇；点击同步继续",
                                        completedPages: checkpoint.completedPages,
                                        successfulRecords: checkpoint.successfulRecords,
                                        failedRecords: checkpoint.failedRecords,
                                        lastUpdatedAt: checkpoint.updatedAt,
                                        remainingRecords: nil)
            }
            return
        }
        let author = await store.author(recid: recid)
        let isStale = author?.lastSyncedAt.map { Date().timeIntervalSince($0) > staleInterval } ?? true
        if localPapers.isEmpty || isStale { startPaperSync(for: recid, forceFreshGeneration: false) }
    }

    private enum InsightRequestTrigger { case automatic, manual }

    private func requestAutomaticInsight(for paper: Paper) async {
        guard selectedPaperID == paper.literatureID else { return }
        let cacheKey: String
        do {
            cacheKey = try InsightWorkflow.cacheKey(for: paper, settings: settings).value
        } catch {
            insightState = .failed("分析设置无效：\(error.localizedDescription)")
            insightStartedAt = nil
            return
        }
        // Context restoration normally populated this first.  Keep this
        // second cache check at the dispatch boundary because a store reload
        // can race the 600 ms debounce without ever requiring a provider call.
        if let cached = await store.insight(cacheKey: cacheKey) {
            insightArtifact = cached
            insightState = .completed(cacheHit: true, requestCount: 0)
            insightStartedAt = nil
            return
        }
        if let terminal = automaticInsightTerminalMessages[cacheKey] {
            insightState = .failed(terminal)
            insightStartedAt = nil
            return
        }
        requestInsight(for: paper, trigger: .automatic, cacheKey: cacheKey)
    }

    private func requestInsight(for paper: Paper, trigger: InsightRequestTrigger, cacheKey: String? = nil) {
        let resolvedCacheKey: String
        if let cacheKey {
            resolvedCacheKey = cacheKey
        } else {
            do {
                resolvedCacheKey = try InsightWorkflow.cacheKey(for: paper, settings: settings).value
            } catch {
                insightState = .failed("分析设置无效：\(error.localizedDescription)")
                insightStartedAt = nil
                return
            }
        }
        // A selection-list reconciliation, an automatic debounce, and a user
        // click may all arrive on the main actor.  Coalesce them before any
        // Keychain read or provider request is scheduled.
        if activeInsightCacheKey == resolvedCacheKey, isInsightRunning { return }
        if trigger == .automatic, let terminal = automaticInsightTerminalMessages[resolvedCacheKey] {
            insightState = .failed(terminal)
            insightStartedAt = nil
            return
        }
        if trigger == .manual { automaticInsightTerminalMessages.removeValue(forKey: resolvedCacheKey) }
        guard settings.hasConsent(for: settings.activeProvider) else {
            pendingInsightPaper = paper
            presentPrivacyDisclosure = true
            return
        }
        // Without an abstract the workflow sends only the title, obtains a
        // strict title-only translation, and creates no model physics claim.
        startInsightTask(for: paper, cacheKey: resolvedCacheKey, trigger: trigger)
    }

    private func startInsightTask(for paper: Paper, cacheKey: String, trigger: InsightRequestTrigger) {
        insightTask?.cancel()
        let session = UUID()
        insightSessionID = session
        activeInsightCacheKey = cacheKey
        insightStartedAt = Date()
        let runID = UUID()
        let started = insightStartedAt ?? Date()
        let timeouts = V4AnalysisTimeouts.default
        let sourceHash = StableHash.sha256((try? JSONEncoder.latticeLens.encode(InsightSourcePayload(paper: paper))) ?? Data())
        let requestTotal = settings.mode == .deep ? 2 : 1
        analysisRunState = V4AnalysisRunState(runID: runID, paperIDs: [paper.literatureID], requestIndex: 1,
                                              requestTotal: requestTotal, phase: .connecting, receivedBytes: 0,
                                              receivedCharacters: 0, startedAt: started, elapsedMilliseconds: 0,
                                              connectDeadline: started.addingTimeInterval(timeouts.connect),
                                              firstContentDeadline: started.addingTimeInterval(timeouts.firstContent),
                                              idleDeadline: started.addingTimeInterval(timeouts.idle),
                                              hardDeadline: started.addingTimeInterval(timeouts.hard), sourceHash: sourceHash,
                                              provider: settings.activeProvider.rawValue, model: settings.activeProfile.effectiveModel)
        insightTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.insightSessionID == session {
                    self.insightTask = nil
                    self.activeInsightCacheKey = nil
                }
            }
            let apiKey: String
            do { apiKey = try await self.storedAPIKey(for: self.settings.activeProvider) ?? "" }
            catch {
                self.insightState = .failed("无法读取钥匙串中的 API Key。")
                self.automaticInsightTerminalMessages[cacheKey] = "无法读取钥匙串中的 API Key；不会自动重试。"
                self.insightStartedAt = nil
                return
            }
            do {
                let artifact = try await self.insightWorkflow.generate(for: paper, settings: self.settings, apiKey: apiKey) { @MainActor [weak self] state in
                    guard let self, self.insightSessionID == session else { return }
                    self.insightState = state
                    self.updateAnalysisRun(runID: runID, workflowState: state, startedAt: started)
                }
                guard self.insightSessionID == session, self.selectedPaperID == paper.literatureID else { return }
                self.insightArtifact = artifact
                let completion: InsightWorkflowState
                if case .completed = self.insightState {
                    completion = self.insightState
                } else {
                    completion = .completed(cacheHit: false, requestCount: requestTotal)
                }
                self.updateAnalysisRun(runID: runID, workflowState: completion, startedAt: started)
                self.insightStartedAt = nil
            } catch is CancellationError {
                guard self.insightSessionID == session else { return }
                self.insightState = .cancelled
                self.updateAnalysisRun(runID: runID, workflowState: .cancelled, startedAt: started)
                self.automaticInsightTerminalMessages[cacheKey] = "已取消；不会自动重试。请使用“重新生成”明确重试。"
                self.insightStartedAt = nil
            } catch let error as LatticeLensError where error == .cancelled {
                guard self.insightSessionID == session else { return }
                self.insightState = .cancelled
                self.updateAnalysisRun(runID: runID, workflowState: .cancelled, startedAt: started)
                self.automaticInsightTerminalMessages[cacheKey] = "已取消；不会自动重试。请使用“重新生成”明确重试。"
                self.insightStartedAt = nil
            } catch {
                guard self.insightSessionID == session else { return }
                if case .failed = self.insightState {} else { self.insightState = .failed(error.localizedDescription) }
                self.updateAnalysisRun(runID: runID, workflowState: .failed(error.localizedDescription), startedAt: started)
                let triggerLabel: String
                switch trigger {
                case .automatic: triggerLabel = "上次自动分析失败"
                case .manual: triggerLabel = "上次分析失败"
                }
                self.automaticInsightTerminalMessages[cacheKey] = "\(triggerLabel)：\(error.localizedDescription)；不会自动重试。请使用“重新生成”明确重试。"
                self.insightStartedAt = nil
            }
        }
    }

    private func updateAnalysisRun(runID: UUID, workflowState: InsightWorkflowState, startedAt: Date) {
        guard var current = analysisRunState, current.runID == runID else { return }
        switch workflowState {
        case .connecting:
            if current.phase != .connecting && current.requestIndex < current.requestTotal {
                current.requestIndex += 1
            }
            current.phase = .connecting
        case .waitingFirstContent: current.phase = .waitingFirstContent
        case .receiving(let characters, let bytes):
            current.receivedCharacters = characters
            current.receivedBytes = bytes
            current.idleDeadline = Date().addingTimeInterval(V4AnalysisTimeouts.default.idle)
            current.phase = .receiving
        case .validating: current.phase = .validating
        case .completed: current.phase = .completed
        case .cancelled: current.phase = .cancelled
        case .failed: current.phase = .failed
        case .idle: break
        }
        current.elapsedMilliseconds = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        analysisRunState = current
    }

    private func startEvidenceInsightTask(for paper: Paper) {
        evidenceInsightTask?.cancel()
        let session = UUID()
        evidenceInsightSessionID = session
        evidenceInsightStartedAt = Date()
        evidenceInsightTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.evidenceInsightSessionID == session {
                    self.evidenceInsightTask = nil
                    if !self.isEvidenceInsightRunning { self.evidenceInsightStartedAt = nil }
                }
            }
            let apiKey: String
            do {
                apiKey = try await self.storedAPIKey(for: self.settings.activeProvider) ?? ""
            } catch {
                self.evidenceInsightState = .failed("无法读取钥匙串中的 API Key。")
                return
            }
            do {
                let artifact = try await self.evidenceInsightWorkflow.generate(for: paper, settings: self.settings, apiKey: apiKey) { @MainActor [weak self] state in
                    guard let self, self.evidenceInsightSessionID == session else { return }
                    self.evidenceInsightState = state
                }
                guard self.evidenceInsightSessionID == session, self.selectedPaperID == paper.literatureID else { return }
                self.evidenceInsightArtifact = artifact
                await self.reloadSelectedPaperContext(for: paper.literatureID)
            } catch is CancellationError {
                guard self.evidenceInsightSessionID == session else { return }
                self.evidenceInsightState = .cancelled
            } catch let error as LatticeLensError where error == .cancelled {
                guard self.evidenceInsightSessionID == session else { return }
                self.evidenceInsightState = .cancelled
            } catch {
                guard self.evidenceInsightSessionID == session else { return }
                if case .failed = self.evidenceInsightState {} else {
                    self.evidenceInsightState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func startVisionTask(for paper: Paper, prepared: VisionPreparedRequest) {
        visionTask?.cancel()
        let session = UUID()
        visionSessionID = session
        visionStartedAt = Date()
        visionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.visionSessionID == session {
                    self.visionTask = nil
                    if !self.isVisionRunning { self.visionStartedAt = nil }
                }
            }
            let apiKey: String
            do {
                apiKey = try await self.storedAPIKey(for: self.settings.activeProvider) ?? ""
            } catch {
                self.visionState = .failed("无法读取钥匙串中的 API Key。")
                return
            }
            do {
                let artifact = try await self.visionWorkflow.generate(for: paper, prepared: prepared, settings: self.settings, apiKey: apiKey) { @MainActor [weak self] state in
                    guard let self, self.visionSessionID == session else { return }
                    self.visionState = state
                }
                guard self.visionSessionID == session, self.selectedPaperID == paper.literatureID else { return }
                self.visionArtifact = artifact
                await self.reloadSelectedPaperContext(for: paper.literatureID)
            } catch is CancellationError {
                guard self.visionSessionID == session else { return }
                self.visionState = .cancelled
            } catch let error as LatticeLensError where error == .cancelled {
                guard self.visionSessionID == session else { return }
                self.visionState = .cancelled
            } catch {
                guard self.visionSessionID == session else { return }
                if case .failed = self.visionState {} else { self.visionState = .failed(error.localizedDescription) }
            }
        }
    }

    private func reloadSelectedPaperContext(for paperID: Int?) async {
        guard let paperID else {
            selectedFullTextDocument = nil
            selectedEvidenceAnchors = []
            selectedNotes = []
            selectedTags = []
            selectedBibTeXRecord = nil
            availableTags = []
            availableCollections = []
            selectedCollectionIDs = []
            evidenceInsightArtifact = nil
            visionArtifact = nil
            return
        }
        let paperRows = await store.papers(forIDs: [paperID])
        let paper = paperRows[paperID]
        let key = paper.flatMap { try? InsightWorkflow.cacheKey(for: $0, settings: settings).value }
        let context = await store.paperContext(paperID: paperID, insightCacheKey: key)
        guard selectedPaperID == paperID else { return }
        if let cached = context.insight {
            insightArtifact = cached
            // This is a presentation of an already schema-validated artifact;
            // it does not imply a new provider call or restart its timer.
            insightState = .completed(cacheHit: true, requestCount: 0)
            insightStartedAt = nil
        }
        selectedFullTextDocument = context.fullTextDocuments
            .sorted { ($0.downloadedAt ?? .distantPast) > ($1.downloadedAt ?? .distantPast) }
            .first
        selectedEvidenceAnchors = context.evidenceAnchors
            .sorted { lhs, rhs in
                if lhs.sourceKind != rhs.sourceKind { return lhs.sourceKind.rawValue < rhs.sourceKind.rawValue }
                if lhs.page != rhs.page { return (lhs.page ?? 0) < (rhs.page ?? 0) }
                return lhs.id < rhs.id
            }
        evidenceInsightArtifact = context.evidenceInsights
            .sorted { $0.createdAt > $1.createdAt }
            .first
        visionArtifact = context.visionArtifacts
            .sorted { $0.createdAt > $1.createdAt }
            .first
        selectedNotes = context.notes.sorted { $0.updatedAt > $1.updatedAt }
        selectedBibTeXRecord = context.bibTeXRecord
        selectedTags = context.tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        availableTags = context.availableTags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        availableCollections = context.availableCollections.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selectedCollectionIDs = context.selectedCollectionIDs
    }

    private func persistAuthorIndexStopState(_ stopState: SyncCheckpointState) async {
        for jobID in [AuthorIndexService.candidateJobID, AuthorIndexService.hIndexJobID] {
            guard var checkpoint = try? await store.checkpoint(jobID: jobID) else { continue }
            checkpoint.state = stopState
            checkpoint.updatedAt = Date()
            try? await store.save(checkpoint: checkpoint)
        }
    }

    private func reloadAuthors() async {
        // Keep the complete qualified local snapshot in the view model.  The
        // sidebar applies its own synchronous search predicate so typing never
        // races an actor reload or changes the selected author/paper state.
        let projection = await store.authorSidebarProjection()
        authors = projection.visibleAuthors(search: "")
        let candidates = projection.authors.filter(\.isHIndexCandidate)
        authorIndexProgress = AuthorIndexProgress(verified: candidates.filter { $0.hIndex != nil }.count,
                                                  candidates: candidates.count,
                                                  failed: candidates.filter { $0.hIndexState == .failed }.count,
                                                  qualified: candidates.filter { $0.hIndexState == .qualified }.count,
                                                  rejected: candidates.filter { $0.hIndexState == .rejected }.count,
                                                  remaining: candidates.filter { $0.hIndex == nil }.count,
                                                  state: .active)
    }

    private static func loadSettings() -> LLMSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let values = try? JSONDecoder.latticeLens.decode(LLMSettings.self, from: data) else { return LLMSettings() }
        return values
    }
}

enum PaperFilter: String, CaseIterable, Identifiable {
    case all, updates, favorites, needsReview, hepLat, published, unread, figures
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all: "Papers"
        case .updates: "Updates"
        case .favorites: "Favorites"
        case .needsReview: "Needs Review"
        case .hepLat: "hep-lat"
        case .published: "已发表"
        case .unread: "新增（未读）"
        case .figures: "有图像"
        }
    }
}
