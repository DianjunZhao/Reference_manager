import Foundation

// MARK: - v4 local product state

enum V4ReadingWorkflowState: String, Codable, CaseIterable, Sendable {
    case inbox
    case reading
    case done
    case archived
}

enum V4SearchFacet: String, Codable, CaseIterable, Sendable {
    case unread
    case favorite
    case updated
    case hasPDF
    case validatedClaims
    case staleEvidence
    case needsImportReview
}

struct V4ReadingWorkflow: Codable, Hashable, Sendable {
    let paperID: Int
    var state: V4ReadingWorkflowState
    var priority: Int
    var updatedAt: Date
}

struct V4SearchIndexEntry: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let paperID: Int
    let field: String
    let text: String
    let normalizedText: String
    let page: Int?
    let quote: String?
    let quoteHash: String?
}

struct V4SearchHit: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let paperID: Int
    let title: String
    let source: String
    let field: String
    let snippet: String
    let page: Int?
    let quote: String?
    let score: Int
}

struct V4LocalSearchIndex: Codable, Sendable {
    var entries: [String: V4SearchIndexEntry] = [:]
    var version: Int = 1
    var rebuiltAt: Date = Date()

    static func rebuild(snapshot: LibrarySnapshot, now: Date = Date()) -> V4LocalSearchIndex {
        var index = V4LocalSearchIndex(entries: [:], version: 1, rebuiltAt: now)
        for paper in snapshot.papers.values {
            index.add(paper: paper)
            for authorLink in snapshot.paperAuthorLinks where authorLink.paperID == paper.literatureID {
                if let author = snapshot.authors[authorLink.authorRecid] {
                    index.add(V4SearchIndexEntry(id: "author:\(paper.literatureID):\(author.recid)", paperID: paper.literatureID,
                                                  field: "author", text: author.preferredName,
                                                  normalizedText: SearchNormalizer.normalize(author.preferredName), page: nil, quote: nil, quoteHash: nil))
                    for native in author.nativeNames {
                        index.add(V4SearchIndexEntry(id: "author-native:\(paper.literatureID):\(author.recid):\(native)", paperID: paper.literatureID,
                                                      field: "author", text: native,
                                                      normalizedText: SearchNormalizer.normalize(native), page: nil, quote: nil, quoteHash: nil))
                    }
                }
            }
            if let doi = paper.doi {
                index.add(V4SearchIndexEntry(id: "doi:\(paper.literatureID)", paperID: paper.literatureID,
                                              field: "doi", text: doi, normalizedText: SearchNormalizer.normalize(doi), page: nil, quote: nil, quoteHash: nil))
            }
            if let arxiv = paper.arxivID {
                index.add(V4SearchIndexEntry(id: "arxiv:\(paper.literatureID)", paperID: paper.literatureID,
                                              field: "arxiv", text: arxiv, normalizedText: SearchNormalizer.normalize(arxiv), page: nil, quote: nil, quoteHash: nil))
            }
            for tag in snapshot.paperTags where tag.paperID == paper.literatureID {
                if let value = snapshot.tags[tag.tagID] {
                    index.add(V4SearchIndexEntry(id: "tag:\(paper.literatureID):\(tag.tagID.uuidString)", paperID: paper.literatureID,
                                                  field: "tag", text: value.name, normalizedText: SearchNormalizer.normalize(value.name), page: nil, quote: nil, quoteHash: nil))
                }
            }
            for link in snapshot.collectionPapers where link.paperID == paper.literatureID {
                if let value = snapshot.collections[link.collectionID] {
                    index.add(V4SearchIndexEntry(id: "collection:\(paper.literatureID):\(link.collectionID.uuidString)", paperID: paper.literatureID,
                                                  field: "collection", text: value.name, normalizedText: SearchNormalizer.normalize(value.name), page: nil, quote: nil, quoteHash: nil))
                }
            }
            for note in snapshot.notes.values where note.paperID == paper.literatureID {
                index.add(V4SearchIndexEntry(id: "note:\(note.id.uuidString)", paperID: paper.literatureID,
                                              field: "note", text: note.body, normalizedText: SearchNormalizer.normalize(note.body), page: nil, quote: note.body, quoteHash: StableHash.sha256(note.body)))
            }
            for anchor in snapshot.evidenceAnchors.values where anchor.paperID == paper.literatureID {
                index.add(V4SearchIndexEntry(id: "anchor:\(anchor.id)", paperID: paper.literatureID,
                                              field: "annotation", text: anchor.quote, normalizedText: SearchNormalizer.normalize(anchor.quote),
                                              page: anchor.page, quote: anchor.quote, quoteHash: anchor.quoteHash))
            }
            for chunk in snapshot.evidenceChunks.values where chunk.paperID == paper.literatureID {
                index.add(V4SearchIndexEntry(id: "chunk:\(chunk.id)", paperID: paper.literatureID,
                                              field: "pdf", text: chunk.text, normalizedText: SearchNormalizer.normalize(chunk.text),
                                              page: chunk.page, quote: chunk.text, quoteHash: chunk.textHash))
            }
        }
        for note in snapshot.notes.values where snapshot.papers[note.paperID] == nil {
            index.add(V4SearchIndexEntry(id: "orphan-note:\(note.id.uuidString)", paperID: note.paperID,
                                          field: "note", text: note.body, normalizedText: SearchNormalizer.normalize(note.body), page: nil,
                                          quote: note.body, quoteHash: StableHash.sha256(note.body)))
        }
        return index
    }

    mutating func add(paper: Paper) {
        add(V4SearchIndexEntry(id: "title:\(paper.literatureID)", paperID: paper.literatureID, field: "title",
                               text: paper.displayTitle, normalizedText: SearchNormalizer.normalize(paper.displayTitle), page: nil, quote: nil, quoteHash: nil))
        for (index, abstract) in paper.abstracts.enumerated() {
            add(V4SearchIndexEntry(id: "abstract:\(paper.literatureID):\(index)", paperID: paper.literatureID, field: "abstract",
                                   text: abstract.value, normalizedText: SearchNormalizer.normalize(abstract.value), page: nil,
                                   quote: abstract.value, quoteHash: StableHash.sha256(abstract.value)))
        }
    }

    mutating func add(_ entry: V4SearchIndexEntry) { entries[entry.id] = entry }

    mutating func remove(paperID: Int) { entries = entries.filter { $0.value.paperID != paperID } }

    func search(_ query: String, snapshot: LibrarySnapshot, facets: Set<V4SearchFacet> = []) -> [V4SearchHit] {
        let normalized = SearchNormalizer.normalize(query)
        guard !normalized.isEmpty else { return [] }
        let matches = entries.values.filter { $0.normalizedText.contains(normalized) }
        var output: [V4SearchHit] = []
        for entry in matches {
            guard let paper = snapshot.papers[entry.paperID] else { continue }
            guard Self.matchesFacets(paper: paper, snapshot: snapshot, facets: facets) else { continue }
            let score = entry.field == "title" ? 100 : (entry.field == "abstract" ? 80 : 60)
            output.append(V4SearchHit(id: entry.id, paperID: entry.paperID, title: paper.displayTitle,
                                      source: entry.field == "pdf" ? "PDF chunk" : entry.field,
                                      field: entry.field, snippet: String(entry.text.prefix(240)), page: entry.page,
                                      quote: entry.quote, score: score))
        }
        return output.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.paperID != rhs.paperID { return lhs.paperID < rhs.paperID }
            return lhs.id < rhs.id
        }
    }

    private static func matchesFacets(paper: Paper, snapshot: LibrarySnapshot, facets: Set<V4SearchFacet>) -> Bool {
        for facet in facets {
            switch facet {
            case .unread where paper.isRead: return false
            case .favorite where !paper.isFavorite: return false
            case .updated:
                guard let updated = paper.updated, Date().timeIntervalSince(updated) <= 30 * 24 * 3600 else { return false }
            case .hasPDF where !snapshot.fullTextDocuments.values.contains(where: { $0.paperID == paper.literatureID && $0.extractionState != .deleted }): return false
            case .validatedClaims:
                guard snapshot.physicsContractCells.values.contains(where: { $0.paperID == paper.literatureID && $0.status == .direct && !$0.evidenceAnchorIDs.isEmpty }) else { return false }
            case .staleEvidence:
                guard snapshot.userEvidenceAnchors.values.contains(where: { $0.paperID == paper.literatureID && ($0.status == .stale || $0.status == .quarantined) }) else { return false }
            case .needsImportReview:
                guard snapshot.importConflicts.values.contains(where: { $0.paperID == paper.literatureID && $0.status == .pending }) else { return false }
            default: continue
            }
        }
        return true
    }
}

struct V4ResearchHomeSnapshot: Codable, Hashable, Sendable {
    let updatedAt: Date
    let radarUnacknowledged: Int
    let unread: Int
    let favorites: Int
    let staleEvidence: Int
    let importConflicts: Int
    let activeJobs: Int
    let resumableJobs: Int
    let recentWorkspaceIDs: [UUID]
    let recentExportIDs: [UUID]

    static func make(snapshot: LibrarySnapshot, workflows: [Int: V4ReadingWorkflow] = [:], now: Date = Date()) -> V4ResearchHomeSnapshot {
        let active = snapshot.checkpoints.values.filter { $0.state == .active || $0.state == .paused }.count
        let resumable = snapshot.checkpoints.values.filter { $0.state != .completed && ($0.nextURL != nil || !$0.pendingIDs.isEmpty || !$0.retryableIDs.isEmpty) }.count
        let readingStates = snapshot.papers.values.map { workflows[$0.literatureID]?.state ?? ($0.isRead ? .reading : .inbox) }
        return V4ResearchHomeSnapshot(updatedAt: now,
                                      radarUnacknowledged: snapshot.radarEvents.values.filter { !$0.isAcknowledged }.count,
                                      // Research Home labels this metric "未读 / Inbox".
                                      // A paper transitions out of Inbox as soon as it is
                                      // marked read (the compatibility projection is
                                      // `.reading`), even though it may not yet be `.done`.
                                      unread: readingStates.filter { $0 == .inbox }.count,
                                      favorites: snapshot.papers.values.filter(\.isFavorite).count,
                                      staleEvidence: snapshot.userEvidenceAnchors.values.filter { $0.status != .valid }.count,
                                      importConflicts: snapshot.importConflicts.values.filter { $0.status == .pending }.count,
                                      activeJobs: active,
                                      resumableJobs: resumable,
                                      recentWorkspaceIDs: snapshot.workspaces.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(5).map(\.id),
                                      recentExportIDs: snapshot.exportRecords.values.sorted { $0.createdAt > $1.createdAt }.prefix(5).map(\.id))
    }
}

struct V4BundleFileEntry: Codable, Hashable, Sendable {
    let relativePath: String
    let byteCount: Int
    let sha256: String
}

struct V4BundleManifest: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let appVersion: String
    let createdAt: Date
    let recordCounts: [String: Int]
    let files: [V4BundleFileEntry]
    let includesPDFBytes: Bool
    let manifestHash: String

    static func make(schemaVersion: Int, files: [String: Data], recordCounts: [String: Int] = [:], includesPDFBytes: Bool = false,
                     appVersion: String = "LatticeLens-v4", createdAt: Date) -> V4BundleManifest {
        let entries = files.keys.sorted().map { path in
            let data = files[path] ?? Data()
            return V4BundleFileEntry(relativePath: path, byteCount: data.count, sha256: StableHash.sha256(data))
        }
        let basis = (try? JSONEncoder.latticeLens.encode(entries)) ?? Data()
        return V4BundleManifest(schemaVersion: schemaVersion, appVersion: appVersion, createdAt: createdAt,
                                 recordCounts: recordCounts, files: entries, includesPDFBytes: includesPDFBytes,
                                 manifestHash: StableHash.sha256(basis))
    }
}

// MARK: - R03 export transaction

enum V4ExportPhase: String, Codable, Sendable { case prepared, presenting, succeeded, cancelled, failed }

struct V4ExportTransaction: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let format: V3ExportFormat
    let paperIDs: [Int]
    let payloadHash: String
    let preparedAt: Date
    var phase: V4ExportPhase
    var destination: String?
    var errorCategory: String?
    var completedAt: Date?
}

actor V4ExportCoordinator {
    private var transactions: [UUID: V4ExportTransaction] = [:]

    func prepare(format: V3ExportFormat, paperIDs: [Int], contents: String, at date: Date = Date()) -> V4ExportTransaction {
        let value = V4ExportTransaction(id: UUID(), format: format, paperIDs: paperIDs, payloadHash: StableHash.sha256(contents), preparedAt: date,
                                        phase: .prepared, destination: nil, errorCategory: nil, completedAt: nil)
        transactions[value.id] = value
        return value
    }

    func markPresenting(_ id: UUID) throws -> V4ExportTransaction { try transition(id, to: .presenting) }

    func finish(_ id: UUID, result: Result<URL, Error>, at date: Date = Date()) throws -> V4ExportTransaction {
        var value = try transaction(id)
        switch result {
        case .success(let url): value.phase = .succeeded; value.destination = url.path; value.errorCategory = nil
        case .failure(let error):
            if (error as NSError).code == NSUserCancelledError { value.phase = .cancelled } else { value.phase = .failed }
            value.errorCategory = String(describing: error)
        }
        value.completedAt = date
        transactions[id] = value
        return value
    }

    func transaction(_ id: UUID) throws -> V4ExportTransaction {
        guard let value = transactions[id] else { throw V4LocalError.notFound }
        return value
    }

    private func transition(_ id: UUID, to phase: V4ExportPhase) throws -> V4ExportTransaction {
        var value = try transaction(id)
        guard value.phase == .prepared || (value.phase == .presenting && phase != .prepared) else { throw V4LocalError.invalidTransition }
        value.phase = phase; transactions[id] = value; return value
    }
}

// MARK: - R05 auditable AI-artifact clearing

struct V4AIClearPreview: Hashable, Sendable {
    let scope: AIArtifactClearScope
    let insightCount: Int
    let evidenceInsightCount: Int
    let visionCount: Int
    let paperIDs: [Int]

    var deletionCount: Int { insightCount + evidenceInsightCount + visionCount }

    var summary: String {
        "将删除 \(deletionCount) 个本机 artifact（Insight \(insightCount)，Evidence \(evidenceInsightCount)，Vision \(visionCount)）；论文集：\(paperIDs.isEmpty ? "无" : paperIDs.map(String.init).joined(separator: ", "))。"
    }

    static func make(scope: AIArtifactClearScope, snapshot: LibrarySnapshot) -> V4AIClearPreview {
        let insights = scope == .insight || scope == .all ? Array(snapshot.insights.values) : []
        let evidence = scope == .evidenceInsight || scope == .all ? Array(snapshot.evidenceInsights.values) : []
        let vision = scope == .vision || scope == .all ? Array(snapshot.visionArtifacts.values) : []
        return V4AIClearPreview(scope: scope, insightCount: insights.count, evidenceInsightCount: evidence.count, visionCount: vision.count,
                                paperIDs: Set(insights.map(\.paperID) + evidence.map(\.paperID) + vision.map(\.paperID)).sorted())
    }
}

// MARK: - R05 observable request state

enum V4AnalysisPhase: String, Codable, Equatable, Sendable { case connecting, waitingFirstContent, receiving, validating, completed, cancelled, failed }

struct V4AnalysisRunState: Codable, Hashable, Sendable {
    let runID: UUID
    let paperIDs: [Int]
    var requestIndex: Int
    let requestTotal: Int
    var phase: V4AnalysisPhase
    var receivedBytes: Int
    var receivedCharacters: Int
    let startedAt: Date
    var elapsedMilliseconds: Int
    let connectDeadline: Date
    let firstContentDeadline: Date
    var idleDeadline: Date
    let hardDeadline: Date
    let sourceHash: String
    let provider: String
    let model: String
}

struct V4AnalysisTimeouts: Sendable, Equatable {
    let connect: TimeInterval
    let firstContent: TimeInterval
    let idle: TimeInterval
    let hard: TimeInterval
    /// Real providers may spend more than 30 s preparing a long paper report
    /// or pause between SSE chunks.  These finite budgets avoid false idle
    /// failures while retaining a hard upper bound and the one-request
    /// fail-closed contract.
    static let `default` = V4AnalysisTimeouts(connect: 30, firstContent: 120, idle: 120, hard: 600)
    /// Evidence is initiated from a foreground paper tab. Keep its budget
    /// short enough that a stalled provider cannot look like an indefinitely
    /// hung button, while retaining enough time for a normal stream to start.
    /// Evidence has no application-imposed total deadline.  Connection,
    /// first-content and idle deadlines still fail closed; once a healthy
    /// stream is producing bytes it may run until completion or cancellation.
    static let evidence = V4AnalysisTimeouts(connect: 120, firstContent: 180, idle: 120, hard: .infinity)
}

/// A deadline identifies the transport phase that failed.  It deliberately
/// does not imply a retry: re-sending an analysis request could disclose the
/// same local source a second time and would make request accounting false.
enum V4AnalysisDeadlineError: LocalizedError, Equatable, Sendable {
    case connect
    case firstContent
    case idle
    case hard
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .connect: "LLM connect deadline exceeded before response headers"
        case .firstContent: "LLM first-content deadline exceeded"
        case .idle: "LLM stream idle deadline exceeded"
        case .hard: "LLM hard request deadline exceeded"
        case .responseTooLarge: "LLM response exceeded the local byte limit"
        }
    }
}

/// One request's deadline state machine.  The monitor is shared by the
/// transport task and the deadline task, so a callback arriving after timeout
/// is ignored before it reaches ObservableObject/UI state.
private actor V4AnalysisDeadlineMonitor {
    private let startedAt: Date
    private let timeouts: V4AnalysisTimeouts
    private let maximumResponseBytes: Int
    private var connectedAt: Date?
    private var firstContentAt: Date?
    private var lastContentAt: Date?
    private var receivedBytes = 0
    private var terminalFailure: V4AnalysisDeadlineError?

    init(timeouts: V4AnalysisTimeouts, maximumResponseBytes: Int, startedAt: Date = Date()) {
        self.timeouts = timeouts
        self.maximumResponseBytes = maximumResponseBytes
        self.startedAt = startedAt
    }

    /// Returns false when a previously terminal request produced a late
    /// callback.  The caller must then avoid publishing that callback.
    func recordTransport(_ state: LLMTransportState, at date: Date = Date()) -> Bool {
        evaluate(at: date)
        guard terminalFailure == nil else { return false }
        switch state {
        case .connected:
            connectedAt = connectedAt ?? date
        case .waitingFirstContent:
            break
        case .receivedFirstContent:
            firstContentAt = firstContentAt ?? date
            lastContentAt = date
        }
        evaluate(at: date)
        return terminalFailure == nil
    }

    func recordDelta(_ value: String, at date: Date = Date()) -> Bool {
        evaluate(at: date)
        guard terminalFailure == nil else { return false }
        let byteCount = value.lengthOfBytes(using: .utf8)
        receivedBytes += byteCount
        if receivedBytes > maximumResponseBytes {
            terminalFailure = .responseTooLarge
            return false
        }
        firstContentAt = firstContentAt ?? date
        lastContentAt = date
        evaluate(at: date)
        return terminalFailure == nil
    }

    func failure(at date: Date = Date()) -> V4AnalysisDeadlineError? {
        evaluate(at: date)
        return terminalFailure
    }

    func waitForFailure() async throws -> String {
        while true {
            if let error = failure() { throw error }
            try await Task.sleep(nanoseconds: 1_000_000) // 1 ms: deterministic fixture injection without a busy loop
        }
    }

    private func evaluate(at date: Date) {
        guard terminalFailure == nil else { return }
        if timeouts.hard.isFinite && date >= startedAt.addingTimeInterval(timeouts.hard) {
            terminalFailure = .hard
        } else if connectedAt == nil, date >= startedAt.addingTimeInterval(timeouts.connect) {
            terminalFailure = .connect
        } else if firstContentAt == nil, date >= startedAt.addingTimeInterval(timeouts.firstContent) {
            terminalFailure = .firstContent
        } else if let lastContentAt, date >= lastContentAt.addingTimeInterval(timeouts.idle) {
            terminalFailure = .idle
        }
    }
}

/// A one-shot completion gate used by the deadline race below.  It deliberately
/// lives outside a structured task group: URLSession's byte stream can ignore
/// cancellation until the remote peer closes, and waiting for that child at a
/// task-group scope exit would keep the visible UI in "waiting" forever after
/// a deadline.  The gate resumes the caller once, cancels both children, and
/// ignores any late child result.
private final class V4AnalysisCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private var continuation: CheckedContinuation<String, Error>?
    private var operationTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func install(operationTask: Task<Void, Never>, deadlineTask: Task<Void, Never>) {
        lock.lock()
        if resolved {
            lock.unlock()
            operationTask.cancel()
            deadlineTask.cancel()
            return
        }
        self.operationTask = operationTask
        self.deadlineTask = deadlineTask
        lock.unlock()
    }

    func resolve(_ result: Result<String, Error>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        let continuation = self.continuation
        self.continuation = nil
        let operationTask = self.operationTask
        let deadlineTask = self.deadlineTask
        self.operationTask = nil
        self.deadlineTask = nil
        lock.unlock()

        operationTask?.cancel()
        deadlineTask?.cancel()
        continuation?.resume(with: result)
    }

    func cancel() {
        resolve(.failure(CancellationError()))
    }
}

private final class V4AnalysisCompletionGateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: V4AnalysisCompletionGate?

    func install(_ gate: V4AnalysisCompletionGate) {
        lock.lock()
        self.gate = gate
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let gate = self.gate
        lock.unlock()
        gate?.cancel()
    }
}

/// Wraps exactly one provider call.  The wrapper has no retry or streaming
/// fallback path, and cancellation of either child task cancels the other.
/// A deadline returns immediately even if the underlying byte stream is slow
/// to observe cancellation; late callbacks are rejected by the monitor.
enum V4AnalysisDeadlineEnforcer {
    static func perform(
        timeouts: V4AnalysisTimeouts,
        maximumResponseBytes: Int,
        onTransportState: @escaping @Sendable (LLMTransportState) async -> Void,
        onDelta: @escaping @Sendable (String) async -> Void,
        operation: @escaping @Sendable (@escaping @Sendable (LLMTransportState) async -> Void,
                                        @escaping @Sendable (String) async -> Void) async throws -> String
    ) async throws -> String {
        guard maximumResponseBytes > 0 else { throw V4AnalysisDeadlineError.responseTooLarge }
        let monitor = V4AnalysisDeadlineMonitor(timeouts: timeouts, maximumResponseBytes: maximumResponseBytes)
        let gateBox = V4AnalysisCompletionGateBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let gate = V4AnalysisCompletionGate(continuation)
                gateBox.install(gate)
                let operationTask = Task { @Sendable in
                    do {
                        let response = try await operation(
                            { state in
                                guard await monitor.recordTransport(state) else { return }
                                await onTransportState(state)
                            },
                            { value in
                                guard await monitor.recordDelta(value) else { return }
                                await onDelta(value)
                            }
                        )
                        if let failure = await monitor.failure() {
                            gate.resolve(.failure(failure))
                        } else {
                            gate.resolve(.success(response))
                        }
                    } catch {
                        gate.resolve(.failure(error))
                    }
                }
                let deadlineTask = Task { @Sendable in
                    do {
                        _ = try await monitor.waitForFailure()
                    } catch is CancellationError {
                        return
                    } catch {
                        gate.resolve(.failure(error))
                    }
                }
                gate.install(operationTask: operationTask, deadlineTask: deadlineTask)
                if Task.isCancelled { gate.cancel() }
            }
        } onCancel: {
            gateBox.cancel()
        }
    }
}

// MARK: - R06 strict numeric/evidence contract

struct V4ParsedNumber: Hashable, Sendable {
    let raw: String
    let normalized: String
    let unit: String?
}

enum V4LocalError: LocalizedError, Equatable, Sendable {
    case invalidTransition
    case notFound
    case invalidEvidence(String)
    case invalidBundle(String)
    case pathEscape
    case bundleConflict

    var errorDescription: String? {
        switch self {
        case .invalidTransition: "export transaction 状态转换非法"
        case .notFound: "记录不存在"
        case .invalidEvidence(let message): message
        case .invalidBundle(let message): message
        case .pathEscape: "路径不在 app-owned root 内"
        case .bundleConflict: "bundle 与当前资料库存在未解决冲突"
        }
    }
}

enum V4NumericParser {
    private static let number = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"#
    private static let scalar = #"^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?(?:\s*\(\s*\d+(?:\.\d*)?\s*\))?(?:\s*(?:±|\+/-)\s*[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)?(?:\s*(?:-|–|to)\s*[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)?$"#
    private static let geometry = #"^\d+\s*[×x]\s*\d+(?:\s*[×x]\s*\d+){1,2}$"#
    private static let symbolicGeometry = #"^L\^3\s*[×x*]\s*T$"#
    private static let allowedUnit = #"^(?:%|[kMGT]?eV(?:\^(?:\{?[-+]?\d+\}?)|\^2)?|fm(?:\^(?:\{?[-+]?\d+\}?)|\^-?\d+)?|a(?:\^(?:\{?[-+]?\d+\}?)|\^-?\d+)?|L(?:\^[-+]?\d+)?|T(?:\^[-+]?\d+)?|L\^3\s*[×x*]\s*T|cfgs?|config(?:uration)?s?|ensembles?|lattice\s+units?)$"#
    private static let inlineUnit = #"(?:%|[kMGT]?eV(?:\^[-+]?\d+)?|fm(?:\^[-+]?\d+)?|a(?:\^[-+]?\d+)?|cfgs?|config(?:uration)?s?|ensembles?|lattice\s+units?)"#

    static func parse(value: String?, unit: String?) -> V4ParsedNumber? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160 else { return nil }
        let normalized = trimmed.replacingOccurrences(of: "±", with: "+/-")
        let normalizedUnit = unit?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveUnit = normalizedUnit?.isEmpty == true ? nil : normalizedUnit
        guard effectiveUnit == nil || effectiveUnit!.range(of: allowedUnit, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }

        let isGeometry = normalized.range(of: geometry, options: .regularExpression) != nil ||
            normalized.range(of: symbolicGeometry, options: [.regularExpression, .caseInsensitive]) != nil
        let isScalar = normalized.range(of: scalar, options: .regularExpression) != nil
        guard isGeometry || isScalar else { return nil }
        // A bare decimal can be a year, reference, equation label, or page.
        // It is only a physics cell when the caller supplies a recognized
        // unit/count category, or the value itself carries one explicitly.
        if !isGeometry, effectiveUnit == nil,
           normalized.range(of: inlineUnit, options: [.regularExpression, .caseInsensitive]) == nil {
            return nil
        }
        return V4ParsedNumber(raw: value, normalized: normalized, unit: effectiveUnit)
    }

    static func containsValueAndUnit(_ value: String, unit: String?, in quote: String) -> Bool {
        guard let parsed = parse(value: value, unit: unit) else { return false }
        let normalizedQuote = quote.replacingOccurrences(of: "±", with: "+/-")
        guard normalizedQuote.range(of: parsed.normalized, options: .caseInsensitive) != nil else { return false }
        guard let unit = parsed.unit, !unit.isEmpty else { return true }
        let unitPattern = NSRegularExpression.escapedPattern(for: unit).replacingOccurrences(of: "\\ ", with: "\\s+")
        let valuePattern = NSRegularExpression.escapedPattern(for: parsed.normalized)
        let pattern = valuePattern + "\\s{0,12}" + unitPattern
        return normalizedQuote.range(of: pattern, options: .regularExpression) != nil
    }
}

enum V4PhysicsValidator {
    static func validate(_ cell: PhysicsContractCell, snapshot: LibrarySnapshot) throws {
        let ids = cell.evidenceAnchorIDs
        guard Set(ids).count == ids.count else { throw V4LocalError.invalidEvidence("evidence anchor ID 不得重复") }
        switch cell.status {
        case .missing:
            guard cell.value == nil, cell.unit == nil, ids.isEmpty else { throw V4LocalError.invalidEvidence("missing cell 不得带值或 anchor") }
            return
        case .caveat:
            guard cell.value != nil || cell.unit == nil else {
                throw V4LocalError.invalidEvidence("无值 caveat 不得单独携带单位")
            }
            if let value = cell.value,
               V4NumericParser.parse(value: value, unit: cell.unit) == nil {
                throw V4LocalError.invalidEvidence("caveat 中的物理值或单位不可解析")
            }
            // A non-factual caveat (for example a stated limitation with no
            // numerical claim) must not manufacture a provenance anchor just
            // to populate this enum.  A factual caveat follows below through
            // the same-paper anchor/value checks.
            if cell.value == nil, ids.isEmpty { return }
            guard !ids.isEmpty else { throw V4LocalError.invalidEvidence("含物理值的 caveat 必须带 current-paper anchor") }
        case .stale:
            throw V4LocalError.invalidEvidence("stale cell 不得写入为有效物理值")
        case .direct, .inference, .crossPaperInference:
            guard let value = cell.value, V4NumericParser.parse(value: value, unit: cell.unit) != nil else { throw V4LocalError.invalidEvidence("物理值或单位不可解析") }
            guard !ids.isEmpty else { throw V4LocalError.invalidEvidence("direct/inference 必须带 anchor") }
        }
        var samePaperContext = false
        var samePaperValueAndUnit = false
        var foreignValueAndUnit = false
        for id in ids {
            guard let anchor = snapshot.evidenceAnchors[id] else { throw V4LocalError.invalidEvidence("缺失 evidence anchor") }
            let belongsToCurrentPaper = anchor.paperID == cell.paperID
            guard belongsToCurrentPaper || cell.status == .crossPaperInference else { throw V4LocalError.invalidEvidence("cross-paper anchor 不得冒充 direct") }
            guard StableHash.sha256(anchor.quote) == anchor.quoteHash else { throw V4LocalError.invalidEvidence("quote hash mismatch") }
            guard !snapshot.quarantinedEvidenceIDs.contains(id) else { throw V4LocalError.invalidEvidence("quarantined evidence 不可使用") }
            if belongsToCurrentPaper {
                if let expectedHash = cell.sourceDocumentHash {
                    // A cell declaring a PDF document must be grounded in that
                    // exact active extracted document.  Metadata anchors do
                    // not prove a value attributed to a frozen PDF revision.
                    guard anchor.sourceKind == .pdf,
                          anchor.id.hasPrefix("v3pdf:\(cell.paperID):\(expectedHash):"),
                          snapshot.fullTextDocuments.values.contains(where: {
                              $0.paperID == cell.paperID && $0.sha256 == expectedHash && $0.extractionState == .extracted
                          }) else {
                        throw V4LocalError.invalidEvidence("stale 或非 active document anchor")
                    }
                }
                samePaperContext = true
                if let value = cell.value, V4NumericParser.containsValueAndUnit(value, unit: cell.unit, in: anchor.quote) { samePaperValueAndUnit = true }
            } else if let value = cell.value,
                      V4NumericParser.containsValueAndUnit(value, unit: cell.unit, in: anchor.quote) {
                foreignValueAndUnit = true
            }
        }
        guard samePaperContext else { throw V4LocalError.invalidEvidence("必须至少有同 paper context anchor") }
        switch cell.status {
        case .direct, .inference:
            guard samePaperValueAndUnit else { throw V4LocalError.invalidEvidence("值与单位必须共同出现在同一 current-paper anchor") }
        case .crossPaperInference:
            // A foreign value is visible only as an explicitly cross-paper
            // inference. The contemporaneous current-paper context anchor
            // prevents a Compare cell from silently substituting a result.
            guard foreignValueAndUnit else { throw V4LocalError.invalidEvidence("cross-paper inference 必须有 foreign value/unit anchor") }
        case .caveat:
            if cell.value != nil {
                guard samePaperValueAndUnit else { throw V4LocalError.invalidEvidence("含物理值的 caveat 必须在同一 current-paper anchor 中可核验") }
            }
        case .missing, .stale:
            break
        }
    }
}

// MARK: - R10 semantic Radar diff

enum V4RadarChangeKind: String, Codable, CaseIterable, Sendable {
    case added, removed, modified

    var displayNameZH: String {
        switch self {
        case .added: "新增"
        case .removed: "移除"
        case .modified: "修改"
        }
    }
}

struct V4RadarFieldChange: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let paperID: Int
    let field: String
    let kind: V4RadarChangeKind
    let beforeFieldHash: String?
    let afterFieldHash: String?
    let beforeDisplay: String?
    let afterDisplay: String?
    let sourceURL: URL
    let observedAt: Date
    let batchID: UUID

    /// A stable retry-dedup key.  `batchID` and observed time intentionally do
    /// not participate: a restarted query must not re-notify the same field
    /// transition merely because it was fetched again.
    var semanticKey: String { id }

    /// Legacy RadarEvent has a bounded `changedFields` storage column.  Keep
    /// the complete field-level evidence there as an opaque, Codable marker
    /// so old snapshots remain decodable without widening their schema.
    var storageMarker: String {
        let data = (try? JSONEncoder.latticeLens.encode(self)) ?? Data()
        return "v4field:" + data.base64EncodedString()
    }

    static func decodeStorageMarker(_ marker: String) -> V4RadarFieldChange? {
        guard marker.hasPrefix("v4field:"),
              let data = Data(base64Encoded: String(marker.dropFirst("v4field:".count))) else { return nil }
        return try? JSONDecoder.latticeLens.decode(V4RadarFieldChange.self, from: data)
    }
}

enum V4RadarDiff {
    static func diff(before: Paper?, after: Paper, batchID: UUID, observedAt: Date = Date()) -> [V4RadarFieldChange] {
        let source = URL(string: "https://inspirehep.net/api/literature/\(after.literatureID)")!
        // Avoid optional-chaining's nested Optional for nullable metadata.  A
        // nil -> value transition must remain `.added` (and value -> nil
        // `.removed`) instead of being treated as a modified `Optional` box.
        let oldCitation: String? = before.flatMap { $0.citationCount.map(String.init) }
        let oldDOI: String? = before.flatMap { $0.doi }
        let oldArxiv: String? = before.flatMap { $0.arxivID }
        let fields: [(String, String?, String?)] = [
            ("title", before?.displayTitle, after.displayTitle),
            ("abstract", before?.preferredAbstract, after.preferredAbstract),
            ("citationCount", oldCitation, after.citationCount.map(String.init)),
            ("doi", oldDOI, after.doi),
            ("arxivID", oldArxiv, after.arxivID),
            ("documents", before.map { $0.documents.map { "\($0.key)|\($0.url?.absoluteString ?? "")" }.sorted().joined(separator: "\n") }, after.documents.map { "\($0.key)|\($0.url?.absoluteString ?? "")" }.sorted().joined(separator: "\n")),
            ("figures", before.map { $0.figures.map { "\($0.key)|\($0.url?.absoluteString ?? "")|\($0.caption ?? "")" }.sorted().joined(separator: "\n") }, after.figures.map { "\($0.key)|\($0.url?.absoluteString ?? "")|\($0.caption ?? "")" }.sorted().joined(separator: "\n"))
        ]
        return fields.compactMap { field, old, new in
            guard old != new else { return nil }
            let kind: V4RadarChangeKind
            // Citation counts have an explicit "unknown" state.  Transition
            // unknown <-> known is a modification of the same field, never an
            // insertion/removal and never a fabricated zero.  Identifier-like
            // fields (DOI/arXiv) retain added/removed semantics.
            if field == "citationCount" {
                kind = .modified
            } else {
                switch (old, new) { case (nil, _): kind = .added; case (_, nil): kind = .removed; default: kind = .modified }
            }
            return V4RadarFieldChange(id: "\(after.literatureID):\(field):\(kind.rawValue):\(old.map(StableHash.sha256) ?? "nil"):\(new.map(StableHash.sha256) ?? "nil")",
                                      paperID: after.literatureID, field: field, kind: kind,
                                      beforeFieldHash: old.map(StableHash.sha256), afterFieldHash: new.map(StableHash.sha256),
                                      beforeDisplay: old.map { String($0.prefix(160)) }, afterDisplay: new.map { String($0.prefix(160)) },
                                      sourceURL: source, observedAt: observedAt, batchID: batchID)
        }
    }

    /// The production Radar representation is one event per canonical field
    /// transition.  The event ID is derived from the semantic dedup key (not
    /// from a refresh batch), so a retry/relaunch replaces the same row rather
    /// than notifying a second legacy event for the same change.
    static func events(before: Paper?, after: Paper, authorRecids: [Int], batchID: UUID,
                       observedAt: Date = Date()) -> [RadarEvent] {
        diff(before: before, after: after, batchID: batchID, observedAt: observedAt).map { change in
            let kind: RadarEventKind = switch change.kind {
            case .added: .fieldAdded
            case .removed: .fieldRemoved
            case .modified: .fieldModified
            }
            return RadarEvent(id: deterministicEventID(for: change.semanticKey), paperID: change.paperID,
                              authorRecids: authorRecids.sorted(), eventKind: kind,
                              beforeHash: change.beforeFieldHash, afterHash: change.afterFieldHash ?? "nil",
                              changedFields: [change.storageMarker], syncBatchID: batchID,
                              observedAt: change.observedAt, sourceURL: change.sourceURL, isAcknowledged: false,
                              beforeCitationCount: before?.citationCount, afterCitationCount: after.citationCount)
        }
    }

    private static func deterministicEventID(for semanticKey: String) -> UUID {
        let hash = StableHash.sha256(semanticKey)
        let value = "\(hash.prefix(8))-\(hash.dropFirst(8).prefix(4))-\(hash.dropFirst(12).prefix(4))-\(hash.dropFirst(16).prefix(4))-\(hash.dropFirst(20).prefix(12))"
        // SHA-256 has sufficient hexadecimal characters for the UUID layout.
        // Keep the fallback deterministic in case a future hash provider
        // changes its textual format.
        return UUID(uuidString: value) ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }
}

// MARK: - R11 deterministic Compare extractor

struct V4ExtractedPhysicsCell: Sendable, Equatable {
    let paperID: Int
    let rowKey: String
    let value: String?
    let unit: String?
    let status: PhysicsCellStatus
    let anchorID: String?
    let extractionVersion: String
}

struct V4CompareExtractor: Sendable {
    static let version = "v4-local-rules-1"

    static func extract(workspace: PaperWorkspace, snapshot: LibrarySnapshot) -> [V4ExtractedPhysicsCell] {
        workspace.sortOrder.flatMap { paperID in
            PhysicsContract.defaultRows.map { rowKey in extract(paperID: paperID, rowKey: rowKey, snapshot: snapshot) }
        }
    }

    private static func extract(paperID: Int, rowKey: String, snapshot: LibrarySnapshot) -> V4ExtractedPhysicsCell {
        let anchors = snapshot.evidenceAnchors.values.filter { $0.paperID == paperID }.sorted { $0.id < $1.id }
        let patterns: [String: String] = [
            "lattice_spacing": #"(?:a\s*=\s*)([-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)\s*(fm|GeV\s*\^?-?1)"#,
            "pion_hadron_mass": #"(?:m[_ ]?\w+|mass)\s*=\s*([-+]?\d+(?:\.\d+)?)\s*(MeV|GeV)"#,
            "source_sink_tsep_operator": #"t[_ ]?sep\s*=\s*([-+]?\d+(?:\.\d+)?)\s*(?:a|fm)"#,
            "lattice_geometry": #"(\d+\s*[×x]\s*\d+(?:\s*[×x]\s*\d+){1,2})"#
        ]
        guard let pattern = patterns[rowKey], let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return V4ExtractedPhysicsCell(paperID: paperID, rowKey: rowKey, value: nil, unit: nil, status: .missing, anchorID: nil, extractionVersion: version)
        }
        for anchor in anchors {
            let range = NSRange(anchor.quote.startIndex..<anchor.quote.endIndex, in: anchor.quote)
            guard let match = expression.firstMatch(in: anchor.quote, options: [], range: range) else { continue }
            let valueRange = match.range(at: 1)
            let value = Range(valueRange, in: anchor.quote).map { String(anchor.quote[$0]) }
            let unit = match.numberOfRanges > 2 ? Range(match.range(at: 2), in: anchor.quote).map { String(anchor.quote[$0]) } : nil
            guard let value else { continue }
            return V4ExtractedPhysicsCell(paperID: paperID, rowKey: rowKey, value: value, unit: unit, status: .direct, anchorID: anchor.id, extractionVersion: version)
        }
        return V4ExtractedPhysicsCell(paperID: paperID, rowKey: rowKey, value: nil, unit: nil, status: .missing, anchorID: nil, extractionVersion: version)
    }
}

// MARK: - R01 path ownership

enum V4OwnedPath {
    static func canonicalFile(named filename: String, root: URL, fileManager: FileManager = .default) throws -> URL {
        guard !filename.isEmpty, !filename.contains(".."), !filename.hasPrefix("/") else { throw V4LocalError.pathEscape }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(filename).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path == canonicalRoot.path || candidate.path.hasPrefix(canonicalRoot.path + "/") else { throw V4LocalError.pathEscape }
        return candidate
    }
}

// MARK: - R02 checkpoint helper

enum V4CheckpointRecovery {
    static func shouldResume(_ checkpoint: SyncCheckpoint?) -> Bool {
        guard let checkpoint else { return false }
        guard checkpoint.state != .completed else { return false }
        return checkpoint.nextURL != nil || !checkpoint.pendingIDs.isEmpty || !checkpoint.retryableIDs.isEmpty || checkpoint.completedPages > 0
    }
}

// MARK: - R04 durable foreground job ownership

/// The app has one foreground owner for each durable job key.  The durable
/// checkpoint/batch is written by the corresponding service; this registry
/// owns only the in-process Task so that pause, untrack, query deletion and
/// app teardown all cancel the same task rather than leaving a detached
/// refresh alive to publish stale UI state.
final class V4JobOwnerRegistry: @unchecked Sendable {
    struct Entry: Identifiable, Equatable {
        let key: String
        let token: UUID
        let startedAt: Date
        var id: String { key }
    }

    private struct OwnedTask {
        let token: UUID
        var task: Task<Void, Never>?
        let startedAt: Date
    }

    private var tasks: [String: OwnedTask] = [:]

    func begin(key: String) -> UUID {
        tasks[key]?.task?.cancel()
        let token = UUID()
        // Reserve the key before creating the task.  Swift concurrency may
        // run a very short task before `install`; without this reservation a
        // late install could retain an already-completed owner indefinitely.
        tasks[key] = OwnedTask(token: token, task: nil, startedAt: Date())
        return token
    }

    func install(key: String, token: UUID, task: Task<Void, Never>) {
        // A cancelled predecessor must never replace the new task if its
        // closure resumes late after a same-key restart.
        guard var entry = tasks[key], entry.token == token else {
            task.cancel()
            return
        }
        entry.task = task
        tasks[key] = entry
    }

    func finish(key: String, token: UUID) {
        guard tasks[key]?.token == token else { return }
        tasks.removeValue(forKey: key)
    }

    func cancel(key: String) {
        tasks[key]?.task?.cancel()
        tasks.removeValue(forKey: key)
    }

    func cancel(prefix: String) {
        for key in tasks.keys.filter({ $0.hasPrefix(prefix) }) { cancel(key: key) }
    }

    func cancelAll() {
        for task in tasks.values { task.task?.cancel() }
        tasks.removeAll()
    }

    var entries: [Entry] {
        tasks.map { Entry(key: $0.key, token: $0.value.token, startedAt: $0.value.startedAt) }.sorted { $0.key < $1.key }
    }
}
