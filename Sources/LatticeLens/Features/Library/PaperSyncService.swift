import Foundation

struct PaperSyncService: Sendable {
    let client: InspireClient
    let store: any LibraryStoring

    init(client: InspireClient, store: any LibraryStoring) {
        self.client = client
        self.store = store
    }

    func papers(for authorRecid: Int) async -> [Paper] {
        let snapshot = await store.snapshot()
        let ids = Set(snapshot.paperAuthorLinks.filter { $0.authorRecid == authorRecid }.map(\.paperID))
        return ids.compactMap { snapshot.papers[$0] }
            .sorted { lhs, rhs in
                (lhs.timelineDate ?? .distantPast) > (rhs.timelineDate ?? .distantPast)
            }
    }

    func markRead(_ read: Bool, paperID: Int) async throws {
        try await store.markRead(read, paperID: paperID, at: read ? Date() : nil)
    }

    /// A failed/cancelled run resumes from the durable page URL. A completed
    /// manual sync begins a fresh generation at page one and compares `updated`
    /// to distinguish new, metadata-updated, and unchanged records.
    func sync(authorRecid: Int, forceFreshGeneration: Bool = false) async -> SyncStatus {
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
                let before = await store.snapshot()
                var revisions: [PaperRevisionSnapshot] = []
                var radarEvents: [RadarEvent] = []
                for paper in page.papers {
                    let revision = V3RevisionHasher.snapshot(for: paper, syncBatchID: batchID)
                    revisions.append(revision)
                    radarEvents.append(contentsOf: V4RadarDiff.events(before: before.papers[paper.literatureID], after: paper,
                                                                        authorRecids: [authorRecid], batchID: batchID,
                                                                        observedAt: revision.observedAt))
                }
                running.completedPages += 1
                running.successfulRecords += page.papers.count
                running.nextURL = page.nextURL
                running.updatedAt = Date()
                running.lastCheckpointAt = running.updatedAt
                if page.nextURL == nil {
                    running.state = .completed
                    running.completedAt = running.updatedAt
                }
                let jobEvent = SyncJobEvent(id: UUID(), batchID: batchID, jobID: jobID,
                                            kind: page.nextURL == nil ? .completed : .pageCompleted,
                                            page: running.completedPages, completed: running.successfulRecords,
                                            qualified: 0, rejected: 0, failed: running.failedRecords,
                                            remaining: page.nextURL == nil ? 0 : nil, observedAt: running.updatedAt, message: nil)
                let pageReport = try await store.commitPaperSyncPage(PaperSyncPageCommit(
                    authorRecid: authorRecid, papers: page.papers, revisions: revisions,
                    radarEvents: radarEvents, checkpoint: running, jobEvent: jobEvent
                ))
                report = report + pageReport
            } while running.nextURL != nil
            let completedAt = Date()
            if var author = (await store.snapshot()).authors[authorRecid] {
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
