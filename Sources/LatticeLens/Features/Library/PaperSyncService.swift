import Foundation

struct PaperSyncService: Sendable {
    let client: InspireClient
    let store: any LibraryStoring

    init(client: InspireClient, store: any LibraryStoring) {
        self.client = client
        self.store = store
    }

    func papers(for authorRecid: Int) async -> [Paper] {
        await store.papers(forAuthorRecid: authorRecid)
    }

    func markRead(_ read: Bool, paperID: Int) async throws {
        try await store.markRead(read, paperID: paperID, at: read ? Date() : nil)
    }

    /// A failed/cancelled run resumes from the durable page URL. A completed
    /// manual sync begins a fresh generation at page one and compares `updated`
    /// to distinguish new, metadata-updated, and unchanged records.
    /// Called only after a complete page has been durably committed.  It lets
    /// the UI surface real papers during a long author history without ever
    /// showing an uncommitted network page as local library state.
    func sync(
        authorRecid: Int,
        forceFreshGeneration: Bool = false,
        /// Automatic foreground refreshes deliberately stop after a small
        /// durable page.  This makes the first real papers usable while a
        /// person can choose whether a long author history should continue.
        /// `nil` retains the explicit user-requested full sync behavior.
        pageBudget: Int? = nil,
        /// V9 token writes are intentionally deferred for an automatic first
        /// page on a large existing library.  This never defers the paper,
        /// author link, checkpoint, revision or Radar event itself.
        updateSearchIndex: Bool = true,
        onPageCommitted: (@Sendable (SyncStatus) async -> Void)? = nil
    ) async -> SyncStatus {
        let jobID = "literature:\(authorRecid)"
        let query = "authors.recid:\(authorRecid)"
        let batchID = UUID()
        let batchStartedAt = Date()
        let checkpoint: SyncCheckpoint
        do {
            if let previous = try await store.checkpoint(jobID: jobID), !forceFreshGeneration, previous.state != .completed {
                checkpoint = previous
            } else {
                checkpoint = SyncCheckpoint(jobID: jobID, jobKind: "literature", query: query)
            }
            try await store.save(checkpoint: checkpoint)
        } catch {
            return SyncStatus(phase: .failed, message: "无法创建同步 checkpoint", completedPages: 0,
                              successfulRecords: 0, failedRecords: 1, lastUpdatedAt: Date())
        }

        var running = checkpoint
        running.state = .active
        running.lastCheckpointAt = running.updatedAt
        var report = PaperUpsertReport.empty
        do {
            repeat {
                try Task.checkCancellation()
                guard running.completedPages < 1_000 else { throw LatticeLensError.paginationLimitExceeded }
                let page = try await client.literaturePage(for: authorRecid, nextURL: running.nextURL)
                // A page-local diff must not require a full compatibility
                // snapshot.  On a real V9 library that snapshot decodes every
                // paper/artifact and can postpone Yang's first visible page.
                let before = await store.papers(forIDs: page.papers.map(\.literatureID))
                var revisions: [PaperRevisionSnapshot] = []
                var radarEvents: [RadarEvent] = []
                for paper in page.papers {
                    let revision = V3RevisionHasher.snapshot(for: paper, syncBatchID: batchID)
                    revisions.append(revision)
                    radarEvents.append(contentsOf: V4RadarDiff.events(before: before[paper.literatureID], after: paper,
                                                                        authorRecids: [authorRecid], batchID: batchID,
                                                                        observedAt: revision.observedAt))
                }
                running.completedPages += 1
                running.successfulRecords += page.papers.count
                running.nextURL = page.nextURL
                running.updatedAt = Date()
                running.lastCheckpointAt = running.updatedAt
                let hasReachedPageBudget = pageBudget.map { running.completedPages >= max(1, $0) } ?? false
                if page.nextURL == nil {
                    running.state = .completed
                    running.completedAt = running.updatedAt
                } else if hasReachedPageBudget {
                    // The complete page, its resume URL, and this paused
                    // state are published in one transaction.  A relaunch or
                    // explicit Sync can therefore resume at the next page
                    // without treating the first visible page as final.
                    running.state = .paused
                }
                let jobEvent = SyncJobEvent(id: UUID(), batchID: batchID, jobID: jobID,
                                            kind: page.nextURL == nil ? .completed : .pageCompleted,
                                            page: running.completedPages, completed: running.successfulRecords,
                                            qualified: 0, rejected: 0, failed: running.failedRecords,
                                            remaining: page.nextURL == nil ? 0 : nil, observedAt: running.updatedAt, message: nil)
                let pageReport = try await store.commitPaperSyncPage(PaperSyncPageCommit(
                    authorRecid: authorRecid, papers: page.papers, revisions: revisions,
                    radarEvents: radarEvents, checkpoint: running, jobEvent: jobEvent,
                    updateSearchIndex: updateSearchIndex
                ))
                report = report + pageReport
                if let onPageCommitted {
                    await onPageCommitted(SyncStatus(
                        phase: running.state == .paused ? .partial : .syncingMetadata,
                        message: running.state == .paused
                            ? "已显示第 \(running.completedPages) 页；点击同步继续"
                            : "正在同步文献；已显示第 \(running.completedPages) 页",
                        completedPages: running.completedPages,
                        successfulRecords: running.successfulRecords,
                        failedRecords: running.failedRecords,
                        lastUpdatedAt: running.updatedAt,
                        newRecords: report.inserted,
                        metadataUpdatedRecords: report.metadataUpdated,
                        unchangedRecords: report.unchanged,
                        remainingRecords: max(0, page.total - running.successfulRecords)
                    ))
                }
            } while running.nextURL != nil && running.state != .paused
            if running.state == .paused {
                return SyncStatus(phase: .partial, message: "已显示 \(running.successfulRecords) 篇；点击同步继续",
                                  completedPages: running.completedPages, successfulRecords: running.successfulRecords,
                                  failedRecords: running.failedRecords, lastUpdatedAt: running.updatedAt,
                                  newRecords: report.inserted, metadataUpdatedRecords: report.metadataUpdated,
                                  unchangedRecords: report.unchanged, remainingRecords: nil)
            }
            let completedAt = Date()
            if var author = await store.author(recid: authorRecid) {
                author.lastCheckpointAt = running.lastCheckpointAt
                author.lastSuccessfulSyncAt = completedAt
                author.lastSyncedAt = completedAt
                try await store.upsert(authors: [author])
            }
            let batch = SyncBatchV3(id: batchID, jobID: jobID, generationID: running.generationID,
                                    startedAt: batchStartedAt, completedAt: completedAt, state: .completed,
                                    newRecords: report.inserted, metadataUpdated: report.metadataUpdated,
                                    citationChanged: report.citationChanged, unchanged: report.unchanged,
                                    failed: running.failedRecords, durationMilliseconds: Int(completedAt.timeIntervalSince(batchStartedAt) * 1_000))
            try await store.applyV3(.saveBatch(batch))
            return SyncStatus(phase: .ready, message: "已同步 \(running.successfulRecords) 篇文献",
                              completedPages: running.completedPages, successfulRecords: running.successfulRecords,
                              failedRecords: running.failedRecords, lastUpdatedAt: running.updatedAt,
                              newRecords: report.inserted, metadataUpdatedRecords: report.metadataUpdated,
                              unchangedRecords: report.unchanged, remainingRecords: 0)
        } catch is CancellationError {
            running.state = .cancelled
            running.updatedAt = Date()
            try? await store.save(checkpoint: running)
            let cancelledBatch = SyncBatchV3(id: batchID, jobID: jobID, generationID: running.generationID,
                                              startedAt: batchStartedAt, completedAt: nil, state: .cancelled,
                                              newRecords: report.inserted, metadataUpdated: report.metadataUpdated,
                                              citationChanged: report.citationChanged, unchanged: report.unchanged,
                                              failed: running.failedRecords, durationMilliseconds: nil)
            try? await store.applyV3(.saveBatch(cancelledBatch))
            return SyncStatus(phase: .cancelled, message: "已取消；已保存 \(running.successfulRecords) 篇文献",
                              completedPages: running.completedPages, successfulRecords: running.successfulRecords,
                              failedRecords: running.failedRecords, lastUpdatedAt: running.updatedAt,
                              newRecords: report.inserted, metadataUpdatedRecords: report.metadataUpdated,
                              unchangedRecords: report.unchanged)
        } catch {
            running.state = .failed
            running.failedRecords += 1
            running.updatedAt = Date()
            try? await store.save(checkpoint: running)
            let failedBatch = SyncBatchV3(id: batchID, jobID: jobID, generationID: running.generationID,
                                          startedAt: batchStartedAt, completedAt: nil, state: .failed,
                                          newRecords: report.inserted, metadataUpdated: report.metadataUpdated,
                                          citationChanged: report.citationChanged, unchanged: report.unchanged,
                                          failed: running.failedRecords, durationMilliseconds: nil)
            try? await store.applyV3(.saveBatch(failedBatch))
            let localCount = await papers(for: authorRecid).count
            return SyncStatus(phase: localCount > 0 ? .stale : .failed,
                              message: localCount > 0 ? "刷新失败，正在显示本地文献" : "首次同步失败，可重试或打开 INSPIRE",
                              completedPages: running.completedPages, successfulRecords: running.successfulRecords,
                              failedRecords: running.failedRecords, lastUpdatedAt: running.updatedAt,
                              newRecords: report.inserted, metadataUpdatedRecords: report.metadataUpdated,
                              unchangedRecords: report.unchanged)
        }
    }
}
