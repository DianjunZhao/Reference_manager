import Foundation

struct AuthorIndexProgress: Sendable, Equatable {
    let verified: Int
    let candidates: Int
    let failed: Int
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
            default:
                throw error
            }
        }
    }
}

struct HIndexQueue: Sendable {
    let maximumConcurrentRequests: Int

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

    init(store: any LibraryStoring, checkpoint: SyncCheckpoint, generationID: String? = nil) {
        self.store = store; self.checkpoint = checkpoint; self.generationID = generationID
    }

    func record(_ outcome: HIndexOutcome) async throws {
        let snapshot = await store.snapshot()
        var updatedAuthor: Author?
        switch outcome {
        case .success(let recid, let hIndex):
            guard var updated = snapshot.authors[recid] else { return }
            updated.hIndex = hIndex
            updated.hIndexState = hIndex.isQualified ? .qualified : .rejected
            updatedAuthor = updated
            checkpoint.successfulRecords += 1
            checkpoint.pendingIDs.removeAll { $0 == recid }
            checkpoint.retryableIDs.removeAll { $0 == recid }
        case .failure(let recid):
            guard var updated = snapshot.authors[recid] else { return }
            // A failed refresh must retain a prior usable snapshot as stale.
            updated.hIndexState = updated.hIndex == nil ? .failed : .stale
            updatedAuthor = updated
            checkpoint.failedRecords += 1
            if !checkpoint.failedIDs.contains(recid) { checkpoint.failedIDs.append(recid) }
            if !checkpoint.retryableIDs.contains(recid) { checkpoint.retryableIDs.append(recid) }
            checkpoint.pendingIDs.removeAll { $0 == recid }
        case .cancelled(let recid):
            checkpoint.cancelledIDs.append(recid)
            checkpoint.pendingIDs.removeAll { $0 == recid }
        }
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
    static let candidateJobID = "author-candidates:hep-lat"
    static let hIndexJobID = "author-h-index:hep-lat"

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
    func rebuildCandidateIndex(force: Bool = false) async throws -> AuthorIndexProgress {
        let initialSnapshot = await store.snapshot()
        let previous = try await store.checkpoint(jobID: Self.candidateJobID)
        var checkpoint: SyncCheckpoint
        if force || previous == nil || previous?.state == .completed {
            let existingMembership = initialSnapshot.authorIndexGenerations.values
                .filter { $0.state == .completed }
                .max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }?
                .activeMembership
                ?? Set(initialSnapshot.authors.values.filter(\.isHepLatCandidate).map(\.recid))
            checkpoint = SyncCheckpoint(jobID: Self.candidateJobID, jobKind: "author-candidates",
                                        query: "arxiv_categories:hep-lat", activeMembership: existingMembership)
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
            checkpoint.state = .failed
            checkpoint.failedRecords += 1
            checkpoint.updatedAt = Date()
            generation.state = .failed
            generation.hQueueFailed = checkpoint.failedRecords
            generation.lastCheckpointAt = checkpoint.updatedAt
            try? await store.commitAuthorIndexState(checkpoint: checkpoint, generation: generation)
            throw error
        }
    }

    /// Processes only pending/stale/failed records by default. Each completed
    /// network outcome is durable before the queue advances.
    func refreshHIndices(force: Bool = false) async throws -> AuthorIndexProgress {
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
                guard (candidateIDs?.contains(author.recid) ?? author.isHepLatCandidate), !author.isSelf else { return false }
                if let resumeIDs { return resumeIDs.contains(author.recid) }
                return force || author.hIndex == nil || author.hIndexState == .stale || author.hIndexState == .failed || author.hIndexState == .unknown
            }
            .sorted { $0.recid < $1.recid }
        var checkpoint = canResume ? prior! : SyncCheckpoint(jobID: Self.hIndexJobID, jobKind: "author-h-index",
                                        query: "arxiv_categories:hep-lat", generationID: generation?.id ?? UUID().uuidString,
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
        let writer = HIndexCheckpointWriter(store: store, checkpoint: checkpoint,
                                            generationID: generation?.id == checkpoint.generationID ? checkpoint.generationID : nil)
        do {
            try await hIndexQueue.refresh(candidates, client: client) { outcome in
                try await writer.record(outcome)
            }
            try await writer.complete()
            return await indexProgress(state: .completed, pages: 0)
        } catch is CancellationError {
            try? await writer.cancel()
            throw CancellationError()
        }
    }

    func visibleAuthors(search: String) async -> [Author] {
        let snapshot = await store.snapshot()
        let activeMembership = snapshot.authorIndexGenerations.values
            .filter { $0.state == .completed }
            .max { $0.completedAt ?? .distantPast < $1.completedAt ?? .distantPast }?.activeMembership
        return snapshot.authors.values
            .filter { author in
                author.isSelf || ((activeMembership == nil || activeMembership!.contains(author.recid)) && author.isVisibleInQualifiedList && author.matches(search: search))
            }
            .sorted { lhs, rhs in
                if lhs.isSelf != rhs.isSelf { return lhs.isSelf }
                if lhs.stableSortKey != rhs.stableSortKey { return lhs.stableSortKey < rhs.stableSortKey }
                return lhs.preferredName.localizedStandardCompare(rhs.preferredName) == .orderedAscending
            }
    }

    private func indexProgress(state: SyncCheckpointState, pages: Int) async -> AuthorIndexProgress {
        let snapshot = await store.snapshot()
        let candidates = snapshot.authors.values.filter(\.isHepLatCandidate)
        let verified = candidates.filter { $0.hIndex != nil }.count
        let qualified = candidates.filter { $0.hIndexState == .qualified }.count
        let rejected = candidates.filter { $0.hIndexState == .rejected }.count
        let failed = candidates.filter { $0.hIndexState == .failed }.count
        return AuthorIndexProgress(verified: verified, candidates: candidates.count, failed: failed,
                                   qualified: qualified, rejected: rejected, completedPages: pages,
                                   remaining: max(0, candidates.count - verified), state: state)
    }
}
