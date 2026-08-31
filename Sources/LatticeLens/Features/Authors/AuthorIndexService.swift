import Foundation

struct AuthorIndexProgress: Sendable, Equatable {
    var verified: Int
    let candidates: Int
    var failed: Int
    var qualified: Int = 0
    var rejected: Int = 0
    var completedPages: Int = 0
    var remaining: Int? = nil
    var state: SyncCheckpointState = .active
}

enum HIndexOutcome: Sendable {
    case success(Int, HIndexSnapshot)
    case failure(Int)
    case cancelled(Int)
}

/// Keeps `/facets` evolution isolated. A facets failure uses the auditable
/// local most-cited fallback and never labels it as INSPIRE official data.
struct HIndexProvider: Sendable {
    let client: InspireClient

    func snapshot(for authorRecid: Int) async throws -> HIndexSnapshot {
        do {
            return try await client.hIndex(for: authorRecid)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LatticeLensError {
            switch error {
            case .endpointChanged, .malformedPayload:
                // Only an explicit schema/endpoint incompatibility warrants
                // the bounded local fallback.  429/transport failures remain
                // retryable and never fan out into an expensive crawl.
                return try await client.locallyComputedHIndex(for: authorRecid)
            case .httpStatus(let status) where (400..<500).contains(status) && status != 429:
                // INSPIRE occasionally rejects citation-summary for an
                // individual author (the response is a deterministic 400,
                // not a transient rate-limit).  Treat that author exactly
                // like the documented endpoint-evolution path: compute the
                // same h(all) definition from its most-cited literature
                // pages and keep the generation eligible for publication.
                // Without this branch one 400 leaves a retryable ID and the
                // completion gate rejects the entire author generation,
                // making every newly discovered hep-th author invisible.
                return try await client.locallyComputedHIndex(for: authorRecid)
            default:
                throw error
            }
        }
    }
}

struct HIndexQueue: Sendable {
    let maximumConcurrentRequests: Int

    // INSPIRE's citation-summary endpoint is sensitive to bursty fan-out.
    // The v1 contract deliberately caps this queue at two concurrent
    // requests so a large hep-lat/hep-th generation keeps making progress
    // instead of turning transient service throttling into a seemingly empty
    // author index.
    init(maximumConcurrentRequests: Int = 2) {
        self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
    }

    /// Delivers outcomes as they complete. The caller persists each delivery,
    /// so killing the app cannot discard a completed h-index batch.
    func refresh(
        _ authors: [Author],
        client: InspireClient,
        onOutcome: @escaping @Sendable (HIndexOutcome) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: HIndexOutcome.self) { group in
            var iterator = authors.makeIterator()
            for _ in 0..<maximumConcurrentRequests {
                guard let author = iterator.next() else { break }
                group.addTask { await outcome(for: author, client: client) }
            }
            while let result = try await group.next() {
                try Task.checkCancellation()
                try await onOutcome(result)
                if let author = iterator.next() {
                    group.addTask { await outcome(for: author, client: client) }
                }
            }
        }
    }

    private func outcome(for author: Author, client: InspireClient) async -> HIndexOutcome {
        guard !Task.isCancelled else { return .cancelled(author.recid) }
        do {
            return .success(author.recid, try await HIndexProvider(client: client).snapshot(for: author.recid))
        } catch is CancellationError {
            return .cancelled(author.recid)
        } catch {
            return .failure(author.recid)
        }
    }
}

private actor HIndexCheckpointWriter {
    private let store: any LibraryStoring
    private let generationID: String?
    private var checkpoint: SyncCheckpoint
    private var progressValue: AuthorIndexProgress
    private var states: [Int: HIndexState]
    private var authorsWithHIndex: Set<Int>
    private var deliveredOutcomes = 0

    init(store: any LibraryStoring, checkpoint: SyncCheckpoint, generationID: String? = nil,
         baseline: AuthorIndexProgress, initialAuthors: [Author]) {
        self.store = store
        self.checkpoint = checkpoint
        self.generationID = generationID
        self.progressValue = baseline
        self.states = Dictionary(uniqueKeysWithValues: initialAuthors.map { ($0.recid, $0.hIndexState) })
        self.authorsWithHIndex = Set(initialAuthors.compactMap { $0.hIndex == nil ? nil : $0.recid })
    }

    func record(_ outcome: HIndexOutcome) async throws {
        let snapshot = await store.snapshot()
        var updatedAuthor: Author?
        switch outcome {
        case .success(let recid, let hIndex):
            guard var updated = snapshot.authors[recid] else { return }
            let priorState = states[recid] ?? updated.hIndexState
            if !authorsWithHIndex.contains(recid) {
                authorsWithHIndex.insert(recid)
                progressValue = AuthorIndexProgress(
                    verified: progressValue.verified + 1,
                    candidates: progressValue.candidates,
                    failed: progressValue.failed,
                    qualified: progressValue.qualified,
                    rejected: progressValue.rejected,
                    completedPages: progressValue.completedPages,
                    remaining: progressValue.remaining,
                    state: progressValue.state
                )
            }
            if priorState == .qualified { progressValue.qualified = max(0, progressValue.qualified - 1) }
            if priorState == .rejected { progressValue.rejected = max(0, progressValue.rejected - 1) }
            if priorState == .failed { progressValue.failed = max(0, progressValue.failed - 1) }
            updated.hIndex = hIndex
            updated.hIndexState = hIndex.isQualified ? .qualified : .rejected
            if updated.hIndexState == .qualified { progressValue.qualified += 1 }
            if updated.hIndexState == .rejected { progressValue.rejected += 1 }
            states[recid] = updated.hIndexState
            updatedAuthor = updated
            checkpoint.successfulRecords += 1
            checkpoint.pendingIDs.removeAll { $0 == recid }
            checkpoint.retryableIDs.removeAll { $0 == recid }
        case .failure(let recid):
            guard var updated = snapshot.authors[recid] else { return }
            let priorState = states[recid] ?? updated.hIndexState
            if priorState == .qualified { progressValue.qualified = max(0, progressValue.qualified - 1) }
            if priorState == .rejected { progressValue.rejected = max(0, progressValue.rejected - 1) }
            if priorState == .failed {
                progressValue = AuthorIndexProgress(
                    verified: progressValue.verified,
                    candidates: progressValue.candidates,
                    failed: max(0, progressValue.failed - 1),
                    qualified: progressValue.qualified,
                    rejected: progressValue.rejected,
                    completedPages: progressValue.completedPages,
                    remaining: progressValue.remaining,
                    state: progressValue.state
                )
            }
            // A failed refresh must retain a prior usable snapshot as stale.
            updated.hIndexState = updated.hIndex == nil ? .failed : .stale
            if updated.hIndexState == .failed { progressValue.failed += 1 }
            states[recid] = updated.hIndexState
            updatedAuthor = updated
            checkpoint.failedRecords += 1
            if !checkpoint.failedIDs.contains(recid) { checkpoint.failedIDs.append(recid) }
            if !checkpoint.retryableIDs.contains(recid) { checkpoint.retryableIDs.append(recid) }
            checkpoint.pendingIDs.removeAll { $0 == recid }
        case .cancelled(let recid):
            checkpoint.cancelledIDs.append(recid)
            checkpoint.pendingIDs.removeAll { $0 == recid }
        }
        progressValue.remaining = checkpoint.resumableIDs.count
        deliveredOutcomes += 1
        guard let author = updatedAuthor else { return }
        checkpoint.updatedAt = Date()
        if let generationID, var generation = snapshot.authorIndexGenerations[generationID] {
            switch outcome {
            case .success: generation.hQueueCompleted += 1
            case .failure: generation.hQueueFailed += 1
            case .cancelled: generation.hQueueCancelled += 1
            }
            generation.hQueuePending = checkpoint.pendingIDs.count
            generation.lastCheckpointAt = checkpoint.updatedAt
            try await store.commitHIndexOutcome(author: author, checkpoint: checkpoint, generation: generation)
        } else {
            // Compatibility source stores can contain an older checkpoint with
            // no generation row.  Preserve the durable author+queue outcome
            // but never fabricate a membership promotion.
            try await store.upsert(authors: [author])
            try await store.save(checkpoint: checkpoint)
        }
    }

    func progressIfDue() -> AuthorIndexProgress? {
        guard deliveredOutcomes == 1 || deliveredOutcomes % 8 == 0 else { return nil }
        return progressValue
    }

    func cancel() async throws {
        checkpoint.state = .cancelled
        checkpoint.updatedAt = Date()
        let snapshot = await store.snapshot()
        if let generationID, var generation = snapshot.authorIndexGenerations[generationID] {
            generation.state = .cancelled
            generation.hQueuePending = checkpoint.resumableIDs.count
            generation.lastCheckpointAt = checkpoint.updatedAt
            try await store.commitAuthorIndexState(checkpoint: checkpoint, generation: generation)
        } else {
            try await store.save(checkpoint: checkpoint)
        }
    }

    /// Keep every successful h-index row visible while preserving only the
    /// unresolved IDs for an explicit retry.  One deterministic 4xx must not
    /// turn an otherwise useful author index into a global failure state.
    func pause() async throws {
        checkpoint.state = .paused
        checkpoint.updatedAt = Date()
        let snapshot = await store.snapshot()
        if let generationID, var generation = snapshot.authorIndexGenerations[generationID] {
            generation.state = .active
            generation.hQueuePending = checkpoint.resumableIDs.count
            generation.lastCheckpointAt = checkpoint.updatedAt
            try await store.commitAuthorIndexState(checkpoint: checkpoint, generation: generation)
        } else {
            try await store.save(checkpoint: checkpoint)
        }
    }

    func hasResumableWork() -> Bool { !checkpoint.resumableIDs.isEmpty }

    func complete() async throws {
        guard checkpoint.isCompletionEligible else {
            // Persist the incomplete state before rejecting promotion.  This
            // makes the exact retry queue survive a crash/relaunch and keeps
            // the previous active generation visible.
            checkpoint.state = .failed
            checkpoint.updatedAt = Date()
            let snapshot = await store.snapshot()
            if let generationID, var generation = snapshot.authorIndexGenerations[generationID] {
                generation.state = .failed
                generation.hQueuePending = checkpoint.resumableIDs.count
                generation.lastCheckpointAt = checkpoint.updatedAt
                try await store.commitAuthorIndexState(checkpoint: checkpoint, generation: generation)
            } else {
                try await store.save(checkpoint: checkpoint)
            }
            throw LatticeLensError.persistenceUnavailable("h-index checkpoint 仍有 pending/retryable IDs；拒绝发布不完整 generation")
        }
        checkpoint.state = .completed
        checkpoint.nextURL = nil
        checkpoint.updatedAt = Date()
        checkpoint.completedAt = checkpoint.updatedAt
        checkpoint.lastSuccessfulSyncAt = checkpoint.updatedAt
        let snapshot = await store.snapshot()
        if let generationID, var generation = snapshot.authorIndexGenerations[generationID] {
            // Membership becomes visible only after the same generation's
            // metadata pages and h-index queue have reached terminal outcomes.
            generation.activeMembership = generation.stagingMembership
            generation.stagingMembership = []
            generation.state = .completed
            generation.completedAt = checkpoint.completedAt
            generation.hQueuePending = 0
            generation.lastCheckpointAt = checkpoint.updatedAt
            try await store.commitAuthorIndexCompletion(checkpoint: checkpoint, generation: generation)
        } else {
            try await store.save(checkpoint: checkpoint)
        }
    }
}

struct AuthorIndexService: Sendable {
    /// Exact category union used by both candidate and h-index generations.
    /// Keeping it in one contract also makes the durable checkpoint auditable.
    static let candidateQuery = "arxiv_categories:hep-lat OR arxiv_categories:hep-th"
    /// Durable checkpoint identity, bumped when pagination mechanics change.
    /// This is metadata only; the network client builds the actual partitioned
    /// INSPIRE queries and never sends this suffix to the service.
    static let candidateQueryCheckpoint = candidateQuery + " [pagination:control-number-v1]"
    static let candidateJobID = "author-candidates:hep-lat-or-hep-th"
    static let hIndexJobID = "author-h-index:hep-lat-or-hep-th"

    let client: InspireClient
    let store: any LibraryStoring
    let hIndexQueue: HIndexQueue

    init(client: InspireClient, store: any LibraryStoring, hIndexQueue: HIndexQueue = HIndexQueue()) {
        self.client = client
        self.store = store
        self.hIndexQueue = hIndexQueue
    }

    func refreshPinnedSelf() async throws {
        try Task.checkCancellation()
        var author = try await client.selfAuthor()
        author.hIndexState = .unknown
        try await store.upsert(authors: [author])
    }

    /// Resume a partial/failed/cancelled candidate job from the durable next
    /// URL. `force` starts a new generation without clearing the old h-index
    /// snapshots, so the A-Z list never flashes empty during a rebuild.
    /// Rebuilds the candidate generation and optionally reports durable page
    /// progress.  The callback is deliberately invoked only after the page,
    /// checkpoint, and staging-generation commit succeeds, so UI progress can
    /// never get ahead of the rows that survive a relaunch.
    func rebuildCandidateIndex(
        force: Bool = false,
        onProgress: (@MainActor @Sendable (AuthorIndexProgress) async -> Void)? = nil
    ) async throws -> AuthorIndexProgress {
        let initialSnapshot = await store.snapshot()
        let previous = try await store.checkpoint(jobID: Self.candidateJobID)
        // Candidate pagination and h-index verification are two durable
        // phases of one generation.  A process can finish the candidate
        // pages, then pause with only h-index retry IDs left.  In that state
        // starting pagination from page one again makes the visible refresh
        // button appear inert (and needlessly re-requests tens of pages).
        // Re-open the active generation directly and let refreshHIndices()
        // consume its persisted retry queue.
        if !force,
           let previous,
           previous.state == .completed,
           let activeGeneration = initialSnapshot.authorIndexGenerations[previous.generationID],
           activeGeneration.state == .active,
           let hIndexCheckpoint = try await store.checkpoint(jobID: Self.hIndexJobID),
           hIndexCheckpoint.generationID == previous.generationID,
           V4CheckpointRecovery.shouldResume(hIndexCheckpoint),
           !hIndexCheckpoint.resumableIDs.isEmpty {
            var resumedCheckpoint = previous
            resumedCheckpoint.state = .active
            resumedCheckpoint.updatedAt = Date()
            var resumedGeneration = activeGeneration
            resumedGeneration.state = .active
            resumedGeneration.completedAt = nil
            resumedGeneration.lastCheckpointAt = resumedCheckpoint.updatedAt
            resumedGeneration.hQueuePending = hIndexCheckpoint.resumableIDs.count
            try await store.commitAuthorIndexState(checkpoint: resumedCheckpoint, generation: resumedGeneration)
            return await indexProgress(state: .active, pages: resumedCheckpoint.completedPages)
        }
        var checkpoint: SyncCheckpoint
        // A checkpoint from the pre-hep-th release must not be resumed: its
        // URL is scoped to the old hep-lat-only query and would silently omit
        // the newly supported hep-th candidates.  Start a fresh generation
        // while retaining the previous completed membership as a fallback.
        let usesPartitionedPagination = previous?.nextURL?.query?.contains("control_number") ?? true
        if force || previous == nil || previous?.state == .completed || previous?.query != Self.candidateQueryCheckpoint || !usesPartitionedPagination {
            let existingMembership = initialSnapshot.authorIndexGenerations.values
                .filter { $0.state == .completed }
                .max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }?
                .activeMembership
                ?? Set(initialSnapshot.authors.values.filter(\.isHIndexCandidate).map(\.recid))
            checkpoint = SyncCheckpoint(jobID: Self.candidateJobID, jobKind: "author-candidates",
                                        query: Self.candidateQueryCheckpoint, activeMembership: existingMembership)
        } else {
            checkpoint = previous!
            checkpoint.state = .active
            checkpoint.updatedAt = Date()
        }
        var generation = initialSnapshot.authorIndexGenerations[checkpoint.generationID] ?? AuthorIndexGeneration(
            id: checkpoint.generationID, query: checkpoint.query, startedAt: checkpoint.startedAt,
            completedAt: nil, state: .active, activeMembership: checkpoint.activeMembership,
            stagingMembership: checkpoint.stagingMembership, pageCount: checkpoint.completedPages,
            hQueueCompleted: 0, hQueuePending: 0, hQueueFailed: checkpoint.failedRecords,
            hQueueCancelled: checkpoint.cancelledIDs.count, lastCheckpointAt: checkpoint.lastCheckpointAt)
        generation.state = .active
        generation.completedAt = nil
        generation.activeMembership = checkpoint.activeMembership
        generation.stagingMembership = checkpoint.stagingMembership
        generation.pageCount = checkpoint.completedPages
        generation.lastCheckpointAt = checkpoint.lastCheckpointAt
        // This initial empty commit establishes a generation/checkpoint pair
        // before the first network request.  A relaunch can therefore resume
        // the same stable ID without exposing staging membership.
        try await store.commitAuthorIndexState(checkpoint: checkpoint, generation: generation)
        do {
            repeat {
                try Task.checkCancellation()
                guard checkpoint.completedPages < 100 else { throw LatticeLensError.paginationLimitExceeded }
                let page = try await client.authorCandidatesPage(nextURL: checkpoint.nextURL)
                checkpoint.stagingMembership.formUnion(page.authors.map(\.recid))
                checkpoint.completedPages += 1
                checkpoint.successfulRecords += page.authors.count
                checkpoint.nextURL = page.nextURL
                checkpoint.updatedAt = Date()
                checkpoint.lastCheckpointAt = checkpoint.updatedAt
                if page.nextURL == nil {
                    checkpoint.state = .completed
                    checkpoint.completedAt = checkpoint.updatedAt
                    checkpoint.lastSuccessfulSyncAt = checkpoint.updatedAt
                }
                // Candidate pagination may finish before h-index verification,
                // but the generation itself remains active.  The previously
                // completed generation stays visible until HIndexCheckpointWriter
                // atomically publishes this staging membership.
                generation.state = .active
                generation.stagingMembership = checkpoint.stagingMembership
                generation.pageCount = checkpoint.completedPages
                generation.hQueueFailed = checkpoint.failedRecords
                generation.hQueueCancelled = checkpoint.cancelledIDs.count
                generation.lastCheckpointAt = checkpoint.lastCheckpointAt
                try await store.commitAuthorIndexPage(authors: page.authors, checkpoint: checkpoint, generation: generation)
                if let onProgress {
                    await onProgress(await indexProgress(state: .active, pages: checkpoint.completedPages))
                }
            } while checkpoint.nextURL != nil
            return await indexProgress(state: .active, pages: checkpoint.completedPages)
        } catch is CancellationError {
            checkpoint.state = .cancelled
            checkpoint.updatedAt = Date()
            generation.state = .cancelled
            generation.lastCheckpointAt = checkpoint.updatedAt
            try? await store.commitAuthorIndexState(checkpoint: checkpoint, generation: generation)
            throw CancellationError()
        } catch {
            // A page-level failure is recoverable: all previously committed
            // pages remain valid and `nextURL` is the exact resume boundary.
            // Mark the checkpoint paused rather than failed so callers can
            // keep durable staging rows and retry only this page.
            checkpoint.state = .paused
            checkpoint.failedRecords += 1
            checkpoint.updatedAt = Date()
            generation.state = .active
            generation.hQueueFailed = checkpoint.failedRecords
            generation.lastCheckpointAt = checkpoint.updatedAt
            try? await store.commitAuthorIndexState(checkpoint: checkpoint, generation: generation)
            return await indexProgress(state: .paused, pages: checkpoint.completedPages)
        }
    }

    /// Processes only pending/stale/failed records by default. Each completed
    /// network outcome is durable before the queue advances.
    /// Verifies candidate h-index values and optionally reports each durable
    /// outcome.  Reporting after `writer.record` keeps the displayed counts
    /// aligned with the persisted retry queue and author rows.
    func refreshHIndices(
        force: Bool = false,
        onProgress: (@MainActor @Sendable (AuthorIndexProgress) async -> Void)? = nil
    ) async throws -> AuthorIndexProgress {
        let snapshot = await store.snapshot()
        let generation = snapshot.authorIndexGenerations.values
            .filter { $0.state == .active }
            .max { $0.startedAt < $1.startedAt }
        let candidateIDs: Set<Int>? = generation?.stagingMembership
        let prior = try await store.checkpoint(jobID: Self.hIndexJobID)
        let canResume = !force && V4CheckpointRecovery.shouldResume(prior) &&
            (generation == nil || prior?.generationID == generation?.id)
        let resumeIDs = canResume ? Set(prior!.resumableIDs) : nil
        let candidates = snapshot.authors.values
            .filter { author in
                guard (candidateIDs?.contains(author.recid) ?? author.isHIndexCandidate), !author.isSelf else { return false }
                if let resumeIDs { return resumeIDs.contains(author.recid) }
                return force || author.hIndex == nil || author.hIndexState == .stale || author.hIndexState == .failed || author.hIndexState == .unknown
            }
            .sorted { $0.recid < $1.recid }
        var checkpoint = canResume ? prior! : SyncCheckpoint(jobID: Self.hIndexJobID, jobKind: "author-h-index",
                                        query: Self.candidateQueryCheckpoint, generationID: generation?.id ?? UUID().uuidString,
                                        nextURL: nil, successfulRecords: 0, failedRecords: 0,
                                        pendingIDs: candidates.map { $0.recid })
        // Promote exactly the persisted retry set into the new in-flight
        // queue. A crash after this save cannot make the previous completed
        // IDs visible as pending work.
        if resumeIDs != nil {
            checkpoint.pendingIDs = candidates.map(\.recid)
            checkpoint.retryableIDs = []
        }
        checkpoint.state = .active
        checkpoint.updatedAt = Date()
        if var activeGeneration = generation, activeGeneration.id == checkpoint.generationID {
            activeGeneration.hQueuePending = checkpoint.resumableIDs.count
            activeGeneration.lastCheckpointAt = checkpoint.updatedAt
            try await store.commitAuthorIndexState(checkpoint: checkpoint, generation: activeGeneration)
        } else {
            try await store.save(checkpoint: checkpoint)
        }
        let baseline = await indexProgress(state: .active, pages: 0)
        let writer = HIndexCheckpointWriter(
            store: store,
            checkpoint: checkpoint,
            generationID: generation?.id == checkpoint.generationID ? checkpoint.generationID : nil,
            baseline: baseline,
            initialAuthors: candidates
        )
        do {
            try await hIndexQueue.refresh(candidates, client: client) { outcome in
                try await writer.record(outcome)
                // Updating the durable checkpoint remains per outcome; throttle
                // the UI projection to keep a large h-index crawl from
                // rebuilding the entire sidebar on every response.
                if let onProgress, let progress = await writer.progressIfDue() {
                    await onProgress(progress)
                }
            }
            if await writer.hasResumableWork() {
                try await writer.pause()
                return await indexProgress(state: .paused, pages: 0)
            }
            try await writer.complete()
            return await indexProgress(state: .completed, pages: 0)
        } catch is CancellationError {
            try? await writer.cancel()
            throw CancellationError()
        }
    }

    func visibleAuthors(search: String) async -> [Author] {
        await store.authorSidebarProjection().visibleAuthors(search: search)
    }

    private func indexProgress(state: SyncCheckpointState, pages: Int) async -> AuthorIndexProgress {
        let snapshot = await store.snapshot()
        let candidates = snapshot.authors.values.filter(\.isHIndexCandidate)
        let verified = candidates.filter { $0.hIndex != nil }.count
        let qualified = candidates.filter { $0.hIndexState == .qualified }.count
        let rejected = candidates.filter { $0.hIndexState == .rejected }.count
        let failed = candidates.filter { $0.hIndexState == .failed }.count
        return AuthorIndexProgress(verified: verified, candidates: candidates.count, failed: failed,
                                   qualified: qualified, rejected: rejected, completedPages: pages,
                                   remaining: max(0, candidates.count - verified), state: state)
    }
}
