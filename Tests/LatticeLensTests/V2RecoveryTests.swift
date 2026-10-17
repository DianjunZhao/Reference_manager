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
        let next = try XCTUnwrap(URL(string: "https://inspirehep.net/api/authors/?q=%28arxiv_categories%3Ahep-lat+OR+arxiv_categories%3Ahep-th%29+AND+control_number%3A%5B3000000+TO+%2A%5D&size=250&page=2"))
        try await store.save(checkpoint: SyncCheckpoint(jobID: AuthorIndexService.candidateJobID,
                                                         jobKind: "author-candidates", query: AuthorIndexService.candidateQueryCheckpoint,
                                                         generationID: "resume", nextURL: next, completedPages: 1,
                                                         successfulRecords: 2, state: .failed))
        let client = InspireClient(transport: SequentialTransport([try fixtureData("authors-page-2")]))
        let service = AuthorIndexService(client: client, store: store, categories: SupportedArxivCategory.legacyV1)
        let progress = try await service.rebuildCandidateIndex()
        let checkpoint = try await store.checkpoint(jobID: AuthorIndexService.candidateJobID)
        XCTAssertEqual(progress.completedPages, 2)
        XCTAssertEqual(checkpoint?.state, .completed)
        XCTAssertEqual(checkpoint?.completedPages, 2)
        let resumedSnapshot = await store.snapshot()
        XCTAssertNotNil(resumedSnapshot.authors[22])
    }

    func testCandidatePageTwoFailurePreservesProfileCheckpointAndResumesThatPage() async throws {
        let store = InMemoryLibraryStore()
        let profile = CategoryProfile(categories: [.hepLat, .hepPh], revision: 6)
        let existing = makeAuthor(recid: 80, name: "Previously, Committed")
        try await store.upsert(authors: [existing])

        var components = URLComponents()
        components.scheme = "https"
        components.host = "inspirehep.net"
        components.path = "/api/authors/"
        components.queryItems = [
            URLQueryItem(name: "q", value: "(\(profile.query)) AND control_number:[0 TO 999999]"),
            URLQueryItem(name: "size", value: "250"),
            URLQueryItem(name: "page", value: "2"),
            URLQueryItem(name: "fields", value: "name,native_names,ids,arxiv_categories")
        ]
        let nextURL = try XCTUnwrap(components.url)
        let generationID = "profile-page-two-recovery"
        let checkpoint = SyncCheckpoint(
            jobID: profile.jobID(),
            jobKind: "author-candidates",
            query: profile.checkpointIdentity,
            generationID: generationID,
            nextURL: nextURL,
            completedPages: 1,
            successfulRecords: 1,
            stagingMembership: [existing.recid],
            state: .paused
        )
        let generation = AuthorIndexGeneration(
            id: generationID,
            query: profile.checkpointIdentity,
            startedAt: checkpoint.startedAt,
            completedAt: nil,
            state: .active,
            activeMembership: [],
            stagingMembership: [existing.recid],
            pageCount: 1,
            hQueueCompleted: 0,
            hQueuePending: 0,
            hQueueFailed: 0,
            hQueueCancelled: 0,
            lastCheckpointAt: checkpoint.updatedAt
        )
        try await store.save(checkpoint: checkpoint)
        try await store.applyV3(.saveGeneration(generation))

        let failedTransport = FixedStatusHTTPTransport(statusCode: 400)
        let failedService = AuthorIndexService(
            client: InspireClient(transport: failedTransport, retrySleeper: { _ in }),
            store: store,
            categoryProfile: profile
        )
        let failedProgress = try await failedService.rebuildCandidateIndex()

        XCTAssertEqual(failedProgress.state, .paused)
        let paused = try await store.checkpoint(jobID: profile.jobID())
        XCTAssertEqual(paused?.state, .paused)
        XCTAssertEqual(paused?.completedPages, 1)
        XCTAssertEqual(paused?.nextURL, nextURL)
        XCTAssertEqual(paused?.stagingMembership, [existing.recid])
        let failedRequestURLs = await failedTransport.requestURLs()
        XCTAssertTrue(failedRequestURLs.allSatisfy { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "q" })?.value?.contains("hep-ph") == true
        })

        let resumedTransport = SequentialTransport([
            Data("""
            {"hits":{"total":1,"hits":[{"id":81,"metadata":{"name":{"value":"New, Hep Ph"},"arxiv_categories":["hep-ph"]}}]},"links":{}}
            """.utf8)
        ] + Array(repeating: Data(#"{"hits":{"total":0,"hits":[]},"links":{}}"#.utf8), count: 6))
        let resumedService = AuthorIndexService(
            client: InspireClient(transport: resumedTransport),
            store: store,
            categoryProfile: profile
        )
        _ = try await resumedService.rebuildCandidateIndex()

        let completed = try await store.checkpoint(jobID: profile.jobID())
        XCTAssertEqual(completed?.state, .completed)
        XCTAssertEqual(completed?.query, profile.checkpointIdentity)
        XCTAssertEqual(completed?.completedPages, 8,
                       "resume must continue at page 2, then cover the remaining six disjoint ranges")
        XCTAssertEqual(completed?.stagingMembership, [existing.recid, 81])
    }

    func testIncompleteAuthorPartitionPausesAndPreservesTheLastCompletedGeneration() async throws {
        let store = InMemoryLibraryStore()
        let existingRecid = 91
        var existing = makeAuthor(recid: existingRecid, name: "Previous, Qualified")
        existing.hIndex = HIndexSnapshot(authorRecid: existingRecid, all: 31, published: 30,
                                         excludesSelfCitations: false, source: "INSPIRE", query: "fixture",
                                         fetchedAt: Date(), rawSchemaHash: "prior")
        existing.hIndexState = .qualified
        try await store.upsert(authors: [existing])

        let baselineClient = InspireClient(transport: SequentialTransport([]))
        let baselineService = AuthorIndexService(client: baselineClient, store: store)
        let previousID = "previous-completed-generation"
        let previousQuery = baselineService.configuredCandidateQueryCheckpoint
        let previousCheckpoint = SyncCheckpoint(
            jobID: baselineService.configuredCandidateJobID,
            jobKind: "author-candidates",
            query: previousQuery,
            generationID: previousID,
            completedPages: 4,
            successfulRecords: 1,
            activeMembership: [existingRecid],
            state: .completed
        )
        let previousGeneration = AuthorIndexGeneration(
            id: previousID,
            query: previousQuery,
            startedAt: previousCheckpoint.startedAt,
            completedAt: previousCheckpoint.completedAt,
            state: .completed,
            activeMembership: [existingRecid],
            stagingMembership: [],
            pageCount: previousCheckpoint.completedPages,
            hQueueCompleted: 1,
            hQueuePending: 0,
            hQueueFailed: 0,
            hQueueCancelled: 0,
            lastCheckpointAt: previousCheckpoint.updatedAt
        )
        try await store.save(checkpoint: previousCheckpoint)
        try await store.applyV3(.saveGeneration(previousGeneration))

        let overWindow = Data(#"{"hits":{"hits":[],"total":10001},"links":{"next":"https://inspirehep.net/api/authors/?page=41&size=250"}}"#.utf8)
        let service = AuthorIndexService(
            client: InspireClient(transport: SequentialTransport([overWindow])),
            store: store
        )
        let progress = try await service.rebuildCandidateIndex()

        XCTAssertEqual(progress.state, .paused)
        XCTAssertTrue(progress.failureReason?.contains("control_number:[0 TO 999999]") == true)
        XCTAssertTrue(progress.failureReason?.contains("10,000") == true)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.authorIndexGenerations[previousID]?.state, .completed)
        XCTAssertEqual(snapshot.authorIndexGenerations[previousID]?.activeMembership, [existingRecid])
        XCTAssertEqual(snapshot.authors[existingRecid]?.hIndexState, .qualified)
        let paused = try await store.checkpoint(jobID: baselineService.configuredCandidateJobID)
        XCTAssertEqual(paused?.state, .paused)
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

        let service = AuthorIndexService(client: InspireClient(transport: SequentialTransport([])), store: store,
                                         categories: SupportedArxivCategory.legacyV1)
        let progress = try await service.rebuildCandidateIndex()
        XCTAssertEqual(progress.completedPages, 40)
        let resumed = try await store.checkpoint(jobID: AuthorIndexService.candidateJobID)
        XCTAssertEqual(resumed?.state, .active)
        XCTAssertEqual(resumed?.completedPages, 40)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.authorIndexGenerations[generationID]?.hQueuePending, 1)
        XCTAssertEqual(snapshot.authorIndexGenerations[generationID]?.state, .active)
    }

    func testHIndexQueueRejectsActiveGenerationFromDifferentCategoryProfile() async throws {
        let store = InMemoryLibraryStore()
        var legacyAuthor = makeAuthor(recid: 91, name: "Legacy, Hep Th")
        legacyAuthor.arxivCategories = ["hep-th"]
        try await store.upsert(authors: [legacyAuthor])

        let legacyProfile = CategoryProfile(categories: [.hepLat, .hepTh], revision: 3)
        let activeGeneration = AuthorIndexGeneration(
            id: "active-legacy-profile-generation",
            query: legacyProfile.checkpointIdentity,
            startedAt: Date(timeIntervalSince1970: 1),
            completedAt: nil,
            state: .active,
            activeMembership: [],
            stagingMembership: [legacyAuthor.recid],
            pageCount: 1,
            hQueueCompleted: 0,
            hQueuePending: 1,
            hQueueFailed: 0,
            hQueueCancelled: 0,
            lastCheckpointAt: Date(timeIntervalSince1970: 2)
        )
        try await store.applyV3(.saveGeneration(activeGeneration))

        let currentProfile = CategoryProfile(categories: [.hepLat, .hepPh], revision: 4)
        let service = AuthorIndexService(
            client: InspireClient(transport: SequentialTransport([try fixtureData("h-index")])),
            store: store,
            categoryProfile: currentProfile
        )

        do {
            _ = try await service.refreshHIndices()
            XCTFail("h-index work must not attach a legacy generation to the current category profile")
        } catch let error as LatticeLensError {
            XCTAssertEqual(error, .categoryProfileMismatch)
        } catch {
            XCTFail("expected a typed category-profile boundary error, got: \(error)")
        }

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.authorIndexGenerations[activeGeneration.id], activeGeneration,
                       "a rejected cross-profile job must leave its old generation untouched")
        XCTAssertNil(snapshot.authors[legacyAuthor.recid]?.hIndex,
                     "a rejected cross-profile job must not query h-index for an old-profile member")
        XCTAssertNil(snapshot.checkpoints[currentProfile.jobID(kind: "author-h-index")],
                     "a rejected cross-profile job must not create a current-profile checkpoint")
    }

    @MainActor
    func testRapidCategoryToggleCancelsTheFrozenAuthorRunBeforeHIndexPhase() async throws {
        let store = InMemoryLibraryStore()
        let profile = CategoryProfile(categories: [.hepLat, .hepPh], revision: 7)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "inspirehep.net"
        components.path = "/api/authors/"
        components.queryItems = [
            URLQueryItem(name: "q", value: "(\(profile.query)) AND control_number:[3000000 TO *]"),
            URLQueryItem(name: "size", value: "250"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "fields", value: "name,native_names,ids,arxiv_categories")
        ]
        let nextURL = try XCTUnwrap(components.url)
        let generationID = "rapid-toggle-frozen-generation"
        let checkpoint = SyncCheckpoint(
            jobID: profile.jobID(),
            jobKind: "author-candidates",
            query: profile.checkpointIdentity,
            generationID: generationID,
            nextURL: nextURL,
            state: .paused
        )
        let generation = AuthorIndexGeneration(
            id: generationID,
            query: profile.checkpointIdentity,
            startedAt: checkpoint.startedAt,
            completedAt: nil,
            state: .active,
            activeMembership: [],
            stagingMembership: [],
            pageCount: 0,
            hQueueCompleted: 0,
            hQueuePending: 0,
            hQueueFailed: 0,
            hQueueCancelled: 0,
            lastCheckpointAt: checkpoint.updatedAt
        )
        try await store.save(checkpoint: checkpoint)
        try await store.applyV3(.saveGeneration(generation))

        let transport = BlockingAuthorCandidateTransport(
            candidatePage: Data("""
            {"hits":{"total":1,"hits":[{"id":91,"metadata":{"name":{"value":"Candidate, Final"},"arxiv_categories":["hep-lat"]}}]},"links":{}}
            """.utf8)
        )
        let viewModel = AppViewModel(
            store: store,
            client: InspireClient(transport: transport, retrySleeper: { _ in }),
            categoryProfile: profile
        )

        viewModel.buildAuthorIndex()
        var candidateStarted = false
        for _ in 0..<300 {
            let urls = await transport.requestedURLs()
            if urls.contains(where: { $0.path == "/api/authors" || $0.path == "/api/authors/" }) {
                candidateStarted = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard candidateStarted else {
            viewModel.cancelAuthorIndex()
            let observedPaths = await transport.requestedURLs().map(\.path)
            XCTFail("the frozen author run did not reach its candidate page; observed request paths: \(observedPaths)")
            return
        }
        viewModel.setCategoryEnabled(.hepTh, enabled: true)
        XCTAssertEqual(viewModel.categoryProfile.categories, [.hepLat, .hepPh, .hepTh])

        await transport.releaseCandidatePage()
        for _ in 0..<100 where viewModel.authorIndexStatus.phase == .syncingMetadata {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(viewModel.authorIndexStatus.phase, .cancelled,
                       "a profile change during the final candidate page must stop before h-index work")
        let oldCheckpoint = try await store.checkpoint(jobID: profile.jobID())
        XCTAssertEqual(oldCheckpoint?.state, .cancelled,
                       "cancellation must be persisted under the profile that owned the in-flight page")
        let newProfile = viewModel.categoryProfile
        let newCheckpoint = try await store.checkpoint(jobID: newProfile.jobID())
        XCTAssertNil(newCheckpoint,
                     "the abandoned run must not create a checkpoint for the newly selected profile")
        let requestedURLs = await transport.requestedURLs()
        XCTAssertEqual(requestedURLs.count, 2,
                       "the self lookup and candidate page are allowed; no h-index request may start")
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
            hIndexQueue: HIndexQueue(maximumConcurrentRequests: 1),
            categories: SupportedArxivCategory.legacyV1
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
            hIndexQueue: HIndexQueue(maximumConcurrentRequests: 1),
            categories: SupportedArxivCategory.legacyV1
        )
        let progress = try await resumed.refreshHIndices()
        let finalSnapshot = await store.snapshot()
        XCTAssertEqual(progress.verified, 2)
        XCTAssertNotNil(finalSnapshot.authors[21]?.hIndex, "已完成的第一项不得因继续而丢失")
        XCTAssertNotNil(finalSnapshot.authors[22]?.hIndex, "继续只处理尚未完成的第二项")
        let completedCheckpoint = try await store.checkpoint(jobID: AuthorIndexService.hIndexJobID)
        XCTAssertEqual(completedCheckpoint?.state, .completed)
    }

    func testHIndexProgressUsesGenerationMembershipAndExcludesSelf() async throws {
        let store = InMemoryLibraryStore()
        let candidate = makeAuthor(recid: 91, name: "Member, Candidate")
        let legacy = makeAuthor(recid: 92, name: "Legacy, OutsideGeneration")
        let selfAuthor = makeAuthor(recid: ProductContract.selfAuthorRecid, name: "Zhao, Dian-Jun")
        try await store.upsert(authors: [candidate, legacy, selfAuthor])

        let generationID = "progress-membership"
        let generation = AuthorIndexGeneration(
            id: generationID,
            query: AuthorIndexService.candidateQueryCheckpoint,
            startedAt: Date(),
            completedAt: nil,
            state: .active,
            activeMembership: [],
            stagingMembership: [candidate.recid, selfAuthor.recid],
            pageCount: 1,
            hQueueCompleted: 0,
            hQueuePending: 1,
            hQueueFailed: 0,
            hQueueCancelled: 0,
            lastCheckpointAt: Date()
        )
        try await store.applyV3(.saveGeneration(generation))

        let service = AuthorIndexService(
            client: InspireClient(transport: SequentialTransport([try fixtureData("h-index")])),
            store: store,
            hIndexQueue: HIndexQueue(maximumConcurrentRequests: 1),
            categories: SupportedArxivCategory.legacyV1
        )
        let progress = try await service.refreshHIndices()

        XCTAssertEqual(progress.verified, 1)
        XCTAssertEqual(progress.candidates, 1)
        XCTAssertEqual(progress.remaining, 0)
        XCTAssertEqual(progress.failed, 0)
        let snapshot = await store.snapshot()
        XCTAssertNil(snapshot.authors[legacy.recid]?.hIndex)
        XCTAssertNil(snapshot.authors[selfAuthor.recid]?.hIndex)
    }

    func testSelfSearchInvariantAndOrdinaryZSection() async throws {
        let store = InMemoryLibraryStore()
        var zed = makeAuthor(recid: 77, name: "Zebra, Zed")
        zed.hIndex = HIndexSnapshot(authorRecid: 77, all: 21, published: nil, excludesSelfCitations: false,
                                    source: "INSPIRE", query: "fixture", fetchedAt: Date(), rawSchemaHash: "z")
        zed.hIndexState = .qualified
        try await store.upsert(authors: [makeAuthor(recid: ProductContract.selfAuthorRecid, name: "Zhao, Dian-Jun"), zed])
        let service = AuthorIndexService(client: InspireClient(transport: SequentialTransport([])), store: store,
                                         categories: SupportedArxivCategory.legacyV1)
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

private actor BlockingAuthorCandidateTransport: HTTPTransport {
    private let candidatePage: Data
    private var candidateURL: URL?
    private var candidateContinuation: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    private var urls: [URL] = []

    init(candidatePage: Data) {
        self.candidatePage = candidatePage
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw LatticeLensError.invalidResponse }
        urls.append(url)
        if url.path == "/api/authors/\(ProductContract.selfAuthorRecid)" {
            return (Data("""
            {"id":2010363,"metadata":{"name":{"value":"Self, Author"},"arxiv_categories":["hep-lat"]}}
            """.utf8), try response(for: url))
        }
        guard url.path == "/api/authors" || url.path == "/api/authors/" else {
            throw LatticeLensError.invalidResponse
        }
        candidateURL = url
        return await withCheckedContinuation { continuation in
            candidateContinuation = continuation
        }
    }

    func releaseCandidatePage() {
        guard let url = candidateURL, let continuation = candidateContinuation,
              let response = try? response(for: url) else { return }
        candidateContinuation = nil
        continuation.resume(returning: (candidatePage, response))
    }

    func requestedURLs() -> [URL] { urls }

    private func response(for url: URL) throws -> HTTPURLResponse {
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            throw LatticeLensError.invalidResponse
        }
        return response
    }
}

private actor FixedStatusHTTPTransport: HTTPTransport {
    private let statusCode: Int
    private var urls: [URL] = []

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil) else {
            throw LatticeLensError.invalidResponse
        }
        urls.append(url)
        return (Data(), response)
    }

    func requestURLs() -> [URL] { urls }
}
