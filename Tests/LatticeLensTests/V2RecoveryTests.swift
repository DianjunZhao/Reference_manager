import XCTest
@testable import LatticeLens

final class V2RecoveryTests: XCTestCase {
    func testNestedEnvelopeIsRequiredAndFlattenedFixtureIsRejected() throws {
        let flattened = Data("{\"hits\":[],\"links\":{}}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(InspireSearchPage<InspireAuthorHit>.self, from: flattened))
        let nested = try JSONDecoder().decode(InspireSearchPage<InspireAuthorHit>.self, from: fixtureData("authors-page-1"))
        XCTAssertEqual(nested.hits.total, 3)
        XCTAssertEqual(nested.hits.hits.count, 2)
    }

    func testCandidateCheckpointResumesAtDurableNextURL() async throws {
        let store = InMemoryLibraryStore()
        // Use the final declared partition so an empty `links.next` is a
        // genuine end-of-index in this one-page fixture.  Earlier partitions
        // intentionally advance to the following disjoint range when the
        // service omits `links.next`.
        let next = try XCTUnwrap(URL(string: "https://inspirehep.net/api/authors/?q=%28arxiv_categories%3Ahep-lat+OR+arxiv_categories%3Ahep-th%29+AND+control_number%3A%5B3000000+TO+3999999%5D&size=250&page=2"))
        try await store.save(checkpoint: SyncCheckpoint(jobID: AuthorIndexService.candidateJobID,
                                                         jobKind: "author-candidates", query: AuthorIndexService.candidateQueryCheckpoint,
                                                         generationID: "resume", nextURL: next, completedPages: 1,
                                                         successfulRecords: 2, state: .failed))
        let client = InspireClient(transport: SequentialTransport([try fixtureData("authors-page-2")]))
        let service = AuthorIndexService(client: client, store: store)
        let progress = try await service.rebuildCandidateIndex()
        let checkpoint = try await store.checkpoint(jobID: AuthorIndexService.candidateJobID)
        XCTAssertEqual(progress.completedPages, 2)
        XCTAssertEqual(checkpoint?.state, .completed)
        XCTAssertEqual(checkpoint?.completedPages, 2)
        let resumedSnapshot = await store.snapshot()
        XCTAssertNotNil(resumedSnapshot.authors[22])
    }

    func testCandidateResumeSkipsCompletedPagesWhenOnlyHIndexRetryRemains() async throws {
        let store = InMemoryLibraryStore()
        let author = makeAuthor(recid: 91, name: "Retry, Author")
        try await store.upsert(authors: [author])
        let generationID = "generation-with-h-retry"
        let candidate = SyncCheckpoint(jobID: AuthorIndexService.candidateJobID,
                                       jobKind: "author-candidates",
                                       query: AuthorIndexService.candidateQueryCheckpoint,
                                       generationID: generationID,
                                       nextURL: nil,
                                       completedPages: 40,
                                       successfulRecords: 1,
                                       activeMembership: [],
                                       stagingMembership: [author.recid],
                                       state: .completed)
        let generation = AuthorIndexGeneration(id: generationID,
                                               query: candidate.query,
                                               startedAt: candidate.startedAt,
                                               completedAt: nil,
                                               state: .active,
                                               activeMembership: [],
                                               stagingMembership: [author.recid],
                                               pageCount: candidate.completedPages,
                                               hQueueCompleted: 0,
                                               hQueuePending: 1,
                                               hQueueFailed: 1,
                                               hQueueCancelled: 0,
                                               lastCheckpointAt: candidate.updatedAt)
        try await store.save(checkpoint: candidate)
        try await store.applyV3(.saveGeneration(generation))
        let hIndex = SyncCheckpoint(jobID: AuthorIndexService.hIndexJobID,
                                    jobKind: "author-h-index",
                                    query: AuthorIndexService.candidateQueryCheckpoint,
                                    generationID: generationID,
                                    pendingIDs: [author.recid],
                                    state: .failed)
        try await store.save(checkpoint: hIndex)

        let service = AuthorIndexService(client: InspireClient(transport: SequentialTransport([])), store: store)
        let progress = try await service.rebuildCandidateIndex()
        XCTAssertEqual(progress.completedPages, 40)
        let resumed = try await store.checkpoint(jobID: AuthorIndexService.candidateJobID)
        XCTAssertEqual(resumed?.state, .active)
        XCTAssertEqual(resumed?.completedPages, 40)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.authorIndexGenerations[generationID]?.hQueuePending, 1)
        XCTAssertEqual(snapshot.authorIndexGenerations[generationID]?.state, .active)
    }

    func testCandidateRefreshRetainsExistingVerifiedHIndex() async throws {
        let store = InMemoryLibraryStore()
        let oldH = HIndexSnapshot(authorRecid: 21, all: 31, published: 30, excludesSelfCitations: false,
                                  source: "INSPIRE", query: "fixture", fetchedAt: Date(), rawSchemaHash: "old")
        var existing = makeAuthor(recid: 21, name: "Zed, Existing")
        existing.hIndex = oldH
        existing.hIndexState = .qualified
        try await store.upsert(authors: [existing])
        try await store.upsert(authors: [makeAuthor(recid: 21, name: "Zed, Refreshed")])
        let value = (await store.snapshot()).authors[21]
        XCTAssertEqual(value?.hIndex, oldH)
        XCTAssertEqual(value?.hIndexState, .qualified)
        XCTAssertEqual(value?.preferredName, "Zed, Refreshed")
    }

    func testHIndexCancellationPreservesCompletedOutcomeAndPausedResumeSkipsIt() async throws {
        let store = InMemoryLibraryStore()
        try await store.upsert(authors: [
            makeAuthor(recid: 21, name: "Able, First"),
            makeAuthor(recid: 22, name: "Baker, Second")
        ])
        let blockedTransport = FirstThenBlockingHIndexTransport(firstResponse: try fixtureData("h-index"))
        let interrupted = AuthorIndexService(
            client: InspireClient(transport: blockedTransport),
            store: store,
            hIndexQueue: HIndexQueue(maximumConcurrentRequests: 1)
        )
        let task = Task { try await interrupted.refreshHIndices() }
        await blockedTransport.waitUntilSecondRequestStarts()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("取消 h-index 队列必须传播 cancellation，而不能伪装成完成")
        } catch is CancellationError {
            // Expected: the first result is already durable, the second is not.
        } catch {
            XCTFail("期望 CancellationError，实际为 \(error)")
        }

        let interruptedSnapshot = await store.snapshot()
        XCTAssertNotNil(interruptedSnapshot.authors[21]?.hIndex)
        XCTAssertNil(interruptedSnapshot.authors[22]?.hIndex)
        let checkpointBeforePause = try await store.checkpoint(jobID: AuthorIndexService.hIndexJobID)
        var paused = try XCTUnwrap(checkpointBeforePause)
        XCTAssertEqual(paused.successfulRecords, 1)
        XCTAssertEqual(paused.state, .cancelled)
        paused.state = .paused // AppViewModel's user-visible pause terminal state.
        try await store.save(checkpoint: paused)

        let resumed = AuthorIndexService(
            client: InspireClient(transport: SequentialTransport([try fixtureData("h-index")])),
            store: store,
            hIndexQueue: HIndexQueue(maximumConcurrentRequests: 1)
        )
        let progress = try await resumed.refreshHIndices()
        let finalSnapshot = await store.snapshot()
        XCTAssertEqual(progress.verified, 2)
        XCTAssertNotNil(finalSnapshot.authors[21]?.hIndex, "已完成的第一项不得因继续而丢失")
        XCTAssertNotNil(finalSnapshot.authors[22]?.hIndex, "继续只处理尚未完成的第二项")
        let completedCheckpoint = try await store.checkpoint(jobID: AuthorIndexService.hIndexJobID)
        XCTAssertEqual(completedCheckpoint?.state, .completed)
    }

    func testSelfSearchInvariantAndOrdinaryZSection() async throws {
        let store = InMemoryLibraryStore()
        var zed = makeAuthor(recid: 77, name: "Zebra, Zed")
        zed.hIndex = HIndexSnapshot(authorRecid: 77, all: 21, published: nil, excludesSelfCitations: false,
                                    source: "INSPIRE", query: "fixture", fetchedAt: Date(), rawSchemaHash: "z")
        zed.hIndexState = .qualified
        try await store.upsert(authors: [makeAuthor(recid: ProductContract.selfAuthorRecid, name: "Zhao, Dian-Jun"), zed])
        let service = AuthorIndexService(client: InspireClient(transport: SequentialTransport([])), store: store)
        let search = await service.visibleAuthors(search: "Bali")
        XCTAssertEqual(search.map(\.recid), [ProductContract.selfAuthorRecid])
        let noSearch = await service.visibleAuthors(search: "")
        XCTAssertEqual(noSearch.map(\.recid), [ProductContract.selfAuthorRecid, 77])
        XCTAssertEqual(noSearch.last?.sectionKey, "Z")
    }

    func testPaperSyncResumesAndClassifiesNewVersusUnchanged() async throws {
        let store = InMemoryLibraryStore()
        let next = try XCTUnwrap(URL(string: "https://inspirehep.net/api/literature/?page=2"))
        try await store.save(checkpoint: SyncCheckpoint(jobID: "literature:21", jobKind: "literature", query: "authors.recid:21",
                                                         generationID: "resume", nextURL: next, completedPages: 1,
                                                         successfulRecords: 0, state: .failed))
        let client = InspireClient(transport: SequentialTransport([try fixtureData("literature-page")]))
        let service = PaperSyncService(client: client, store: store)
        let progress = V2PaperSyncProgressRecorder()
        let first = await service.sync(authorRecid: 21, onPageCommitted: { status in await progress.record(status) })
        XCTAssertEqual(first.phase, .ready)
        XCTAssertEqual(first.newRecords, 1)
        let visiblePage = await progress.values().only
        XCTAssertEqual(visiblePage?.phase, .syncingMetadata)
        XCTAssertEqual(visiblePage?.successfulRecords, 1)
        XCTAssertEqual(visiblePage?.completedPages, 2)
        let second = await service.sync(authorRecid: 21, forceFreshGeneration: true)
        // No second scripted response is intentionally available: failure must
        // retain the first durable page as stale rather than clear it.
        XCTAssertEqual(second.phase, .stale)
        let retained = await service.papers(for: 21)
        XCTAssertEqual(retained.count, 1)
    }

    private func makeAuthor(recid: Int, name: String) -> Author {
        Author(recid: recid, preferredName: name, nativeNames: [], bai: nil, arxivCategories: ["hep-lat"],
               hIndex: nil, hIndexState: .unknown, isTracked: false, lastSyncedAt: nil)
    }
}

private actor V2PaperSyncProgressRecorder {
    private var recorded: [SyncStatus] = []
    func record(_ status: SyncStatus) { recorded.append(status) }
    func values() -> [SyncStatus] { recorded }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

private actor FirstThenBlockingHIndexTransport: HTTPTransport {
    private let firstResponse: Data
    private var requestCount = 0
    private var secondRequestStarted = false
    private var secondRequestWaiters: [CheckedContinuation<Void, Never>] = []

    init(firstResponse: Data) { self.firstResponse = firstResponse }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        defer { requestCount += 1 }
        guard let url = request.url else { throw LatticeLensError.invalidResponse }
        if requestCount == 0 {
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                throw LatticeLensError.invalidResponse
            }
            return (firstResponse, response)
        }
        secondRequestStarted = true
        let waiters = secondRequestWaiters
        secondRequestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        try await Task.sleep(for: .seconds(60))
        throw LatticeLensError.invalidResponse
    }

    func waitUntilSecondRequestStarts() async {
        if secondRequestStarted { return }
        await withCheckedContinuation { continuation in
            secondRequestWaiters.append(continuation)
        }
    }
}
