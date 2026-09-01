import Foundation

/// The author sidebar is intentionally a small projection.  Loading it must
/// never require the V8/V9 repository to decode every paper, AI artifact, or
/// search-token row just to paint the first window.
struct LibraryAuthorSidebarProjection: Sendable {
    let authors: [Author]
    let activeMembership: Set<Int>?

    func visibleAuthors(search: String) -> [Author] {
        authors
            .filter { author in
                author.isSelf || (author.matches(search: search) &&
                    ((author.isTracked && author.hIndexState != .rejected) ||
                     // A qualified row is independently verified by its
                     // h-index snapshot.  Keep it visible even when the
                     // latest candidate generation is still partial or its
                     // membership promotion was interrupted; otherwise a
                     // failed page/400 could hide a valid hep-th author
                     // forever behind the previous generation.  The active
                     // membership remains useful for compatibility rows whose
                     // snapshot predates the generation boundary.
                     ((activeMembership == nil || activeMembership!.contains(author.recid) ||
                       author.hIndexState == .qualified) && author.isVisibleInQualifiedList)))
            }
            .sorted { lhs, rhs in
                if lhs.isSelf != rhs.isSelf { return lhs.isSelf }
                if lhs.isTracked != rhs.isTracked { return lhs.isTracked }
                if lhs.stableSortKey != rhs.stableSortKey { return lhs.stableSortKey < rhs.stableSortKey }
                return lhs.preferredName.localizedStandardCompare(rhs.preferredName) == .orderedAscending
            }
    }
}

/// A bounded projection for the active paper inspector.  It contains only
/// rows belonging to the selected paper plus the small tag/collection lists;
/// it deliberately excludes the rest of the library and the V9 index.
struct LibraryPaperContextProjection: Sendable {
    let paper: Paper?
    let insight: InsightArtifact?
    let fullTextDocuments: [FullTextDocument]
    let evidenceAnchors: [EvidenceAnchor]
    let evidenceInsights: [EvidenceInsightArtifact]
    let visionArtifacts: [VisionArtifact]
    let notes: [UserNote]
    let bibTeXRecord: BibTeXRecord?
    let tags: [LibraryTag]
    let availableTags: [LibraryTag]
    let availableCollections: [PaperCollection]
    let selectedCollectionIDs: Set<UUID>
}

protocol LibraryStoring: Sendable {
    func initializationState() async -> LibraryInitializationState
    func snapshot() async -> LibrarySnapshot
    /// Startup/sidebar projection.  Production stores override the default
    /// snapshot compatibility path with a bounded typed-row query.
    func authorSidebarProjection() async -> LibraryAuthorSidebarProjection
    /// State of the most recent author-index generation.  This is kept
    /// separate from the sidebar membership projection so a completed queue
    /// is not painted as perpetually active after relaunch.
    func authorIndexProgressState() async -> SyncCheckpointState?
    func author(recid: Int) async -> Author?
    func papers(forAuthorRecid authorRecid: Int) async -> [Paper]
    func papers(forIDs: [Int]) async -> [Int: Paper]
    func trackedAuthorRecids() async -> Set<Int>
    func insight(cacheKey: String) async -> InsightArtifact?
    func paperContext(paperID: Int, insightCacheKey: String?) async -> LibraryPaperContextProjection
    func upsert(authors: [Author]) async throws
    func upsert(papers: [Paper], for authorRecid: Int) async throws -> PaperUpsertReport
    func upsert(detail paper: Paper) async throws
    func save(checkpoint: SyncCheckpoint?) async throws
    func checkpoint(jobID: String) async throws -> SyncCheckpoint?
    func completeCheckpoint(jobID: String, at: Date) async throws
    func deleteCheckpoint(jobID: String) async throws
    /// A candidate page, its durable resume position, and the staging
    /// generation must become visible together.  The V8 repository performs
    /// this in one typed SwiftData save; compatibility stores retain the same
    /// ordering through the default implementation below.
    func commitAuthorIndexPage(authors: [Author], checkpoint: SyncCheckpoint,
                               generation: AuthorIndexGeneration) async throws
    /// A completed h-index lookup changes one author, the durable queue, and
    /// the generation counters as a single publication boundary.
    func commitHIndexOutcome(author: Author, checkpoint: SyncCheckpoint,
                             generation: AuthorIndexGeneration) async throws
    /// Saves a non-publishing generation transition (pause/failure/relaunch
    /// preparation) without allowing its checkpoint and generation to drift.
    func commitAuthorIndexState(checkpoint: SyncCheckpoint,
                                generation: AuthorIndexGeneration) async throws
    /// Final promotion cannot expose membership after only one of the queue
    /// checkpoint or generation rows has committed.
    func commitAuthorIndexCompletion(checkpoint: SyncCheckpoint,
                                     generation: AuthorIndexGeneration) async throws
    /// A literature page is one durable observation: paper/link rows, their
    /// revision snapshots and semantic Radar events, the resume checkpoint,
    /// and its job event must become visible together.  In particular, a
    /// relaunch must never observe a Radar event for a page whose checkpoint
    /// still points at that page.
    func commitPaperSyncPage(_ commit: PaperSyncPageCommit) async throws -> PaperUpsertReport
    func save(insight: InsightArtifact) async throws
    func removeInsights() async throws
    func setTracked(_ tracked: Bool, authorRecid: Int) async throws
    /// A product-local search must be allowed to use the active repository's
    /// bounded index.  Compatibility stores use the default snapshot
    /// implementation below; the final V9-indexed typed store overrides it.
    func searchPapers(_ query: String, limit: Int) async -> [Paper]
    func markRead(_ read: Bool, paperID: Int, at: Date?) async throws
    func applyReferenceMutation(_ mutation: ReferenceMutation) async throws
    func saveFullText(document: FullTextDocument, chunks: [EvidenceChunk], anchors: [EvidenceAnchor]) async throws
    func saveEvidenceAnchors(_ anchors: [EvidenceAnchor]) async throws
    func deleteFullText(documentID: String) async throws
    /// Durable deletion first, followed by a plan that tells the caller
    /// whether the content-addressed file has become orphaned.  The default
    /// implementation keeps older stores source-compatible while preserving
    /// the required mutation-before-filesystem ordering.
    func deleteFullTextAndPlan(documentID: String) async throws -> FullTextDeletionPlan
    /// V8 implements this as one typed document/blob/reference transaction;
    /// older compatibility stores use the safe default below.
    func saveFullTextAndPlan(document: FullTextDocument, chunks: [EvidenceChunk], anchors: [EvidenceAnchor]) async throws -> BlobMutationPlan
    /// Stores a post-commit cleanup obligation for a content-addressed blob.
    /// It contains filenames only and must never authorize a root escape.
    func saveOrphanedBlobDeletion(_ record: OrphanedBlobDeletion) async throws
    func orphanedBlobDeletions() async -> [OrphanedBlobDeletion]
    func removeOrphanedBlobDeletion(blobHash: String) async throws
    func saveEvidenceInsight(_ artifact: EvidenceInsightArtifact) async throws
    func saveVisionArtifact(_ artifact: VisionArtifact) async throws
    func saveBibTeXRecord(_ record: BibTeXRecord) async throws
    /// A confirmed bibliography merge changes one paper and its conflict audit
    /// row together.  The caller has already validated the selected fields.
    func commitAcceptedImport(paper: Paper, conflict: V3ImportConflict) async throws
    /// A notebook entry and its complete ordered multi-anchor link set share
    /// one publication boundary; an entry must never become visible with only
    /// a prefix of its selected evidence.
    func commitNotebookEntry(_ entry: NotebookEntry, links: [NotebookAnchorLink]) async throws
    func applyV3(_ mutation: V3Mutation) async throws
    func snapshotResult() async -> LibrarySnapshotReadResult
}

struct FullTextDeletionPlan: Sendable, Equatable {
    let documentID: String
    let blobHash: String?
    let localFilename: String?
    let remainingReferenceCount: Int
    let shouldDeleteFile: Bool
}

/// A durable-store mutation commits first; only then may the caller remove a
/// content-addressed cache file.  This makes supersede and explicit delete use
/// one lifecycle boundary and prevents a failed write from destroying the
/// last readable blob.  The plan is deliberately filenames-only: it never
/// carries an arbitrary path out of the repository.
struct BlobMutationPlan: Sendable, Equatable {
    let documentID: String
    let retiredBlobHashes: [String]
    let retiredLocalFilenames: [String]

    static let empty = BlobMutationPlan(documentID: "", retiredBlobHashes: [], retiredLocalFilenames: [])
}

/// The bounded write-set for one INSPIRE literature response page.  This is
/// deliberately a value object rather than a closure so that the sync service
/// computes semantic diffs before persistence and the typed repository can
/// publish all affected stable rows with exactly one save.
struct PaperSyncPageCommit: Sendable {
    let authorRecid: Int
    let papers: [Paper]
    let revisions: [PaperRevisionSnapshot]
    let radarEvents: [RadarEvent]
    let checkpoint: SyncCheckpoint
    let jobEvent: SyncJobEvent
    /// The bounded author timeline can be made durable before its optional
    /// V9 local-search projection is refreshed.  Automatic first paint uses
    /// `false`; an explicit full Sync uses the default `true`.
    let updateSearchIndex: Bool

    init(authorRecid: Int, papers: [Paper], revisions: [PaperRevisionSnapshot],
         radarEvents: [RadarEvent], checkpoint: SyncCheckpoint, jobEvent: SyncJobEvent,
         updateSearchIndex: Bool = true) {
        self.authorRecid = authorRecid
        self.papers = papers
        self.revisions = revisions
        self.radarEvents = radarEvents
        self.checkpoint = checkpoint
        self.jobEvent = jobEvent
        self.updateSearchIndex = updateSearchIndex
    }
}

extension LibraryStoring {
    func authorIndexProgressState() async -> SyncCheckpointState? {
        // Compatibility stores predate the typed generation projection.  A
        // nil result deliberately avoids forcing a whole-library snapshot on
        // the first paint; callers use a bounded count-based fallback.
        nil
    }

    func authorSidebarProjection() async -> LibraryAuthorSidebarProjection {
        let snapshot = await snapshot()
        let activeMembership = snapshot.authorIndexGenerations.values
            .filter { $0.state == .completed }
            .max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }?
            .activeMembership
        return LibraryAuthorSidebarProjection(authors: Array(snapshot.authors.values), activeMembership: activeMembership)
    }

    func author(recid: Int) async -> Author? {
        (await snapshot()).authors[recid]
    }

    func papers(forAuthorRecid authorRecid: Int) async -> [Paper] {
        let snapshot = await snapshot()
        let ids = Set(snapshot.paperAuthorLinks.filter { $0.authorRecid == authorRecid }.map(\.paperID))
        return ids.compactMap { snapshot.papers[$0] }
            .sorted { lhs, rhs in
                if (lhs.timelineDate ?? Date.distantPast) != (rhs.timelineDate ?? Date.distantPast) {
                    return (lhs.timelineDate ?? Date.distantPast) > (rhs.timelineDate ?? Date.distantPast)
                }
                return lhs.literatureID < rhs.literatureID
            }
    }

    func papers(forIDs: [Int]) async -> [Int: Paper] {
        let values = (await snapshot()).papers
        return Dictionary(uniqueKeysWithValues: Set(forIDs).compactMap { id in values[id].map { (id, $0) } })
    }

    func trackedAuthorRecids() async -> Set<Int> {
        Set((await snapshot()).authors.values.filter(\.isTracked).map(\.recid))
    }

    func insight(cacheKey: String) async -> InsightArtifact? {
        (await snapshot()).insights[cacheKey]
    }

    func paperContext(paperID: Int, insightCacheKey: String?) async -> LibraryPaperContextProjection {
        let snapshot = await snapshot()
        return LibraryPaperContextProjection(
            paper: snapshot.papers[paperID],
            insight: insightCacheKey.flatMap { snapshot.insights[$0] },
            fullTextDocuments: snapshot.fullTextDocuments.values.filter { $0.paperID == paperID },
            evidenceAnchors: snapshot.evidenceAnchors.values.filter { $0.paperID == paperID },
            evidenceInsights: snapshot.evidenceInsights.values.filter { $0.paperID == paperID },
            visionArtifacts: snapshot.visionArtifacts.values.filter { $0.paperID == paperID },
            notes: snapshot.notes.values.filter { $0.paperID == paperID },
            bibTeXRecord: snapshot.bibTeXRecords[paperID],
            tags: Set(snapshot.paperTags.filter { $0.paperID == paperID }.map(\.tagID)).compactMap { snapshot.tags[$0] },
            availableTags: Array(snapshot.tags.values),
            availableCollections: Array(snapshot.collections.values),
            selectedCollectionIDs: Set(snapshot.collectionPapers.filter { $0.paperID == paperID }.map(\.collectionID))
        )
    }

    func searchPapers(_ query: String, limit: Int = 500) async -> [Paper] {
        let needle = SearchNormalizer.normalize(query)
        let snapshot = await snapshot()
        let maximum = max(1, limit)
        guard !needle.isEmpty else {
            return Array(snapshot.papers.values.sorted { $0.displayTitle < $1.displayTitle }.prefix(maximum))
        }
        let taggedPaperIDs = Set(snapshot.paperTags.compactMap { link -> Int? in
            guard let tag = snapshot.tags[link.tagID], SearchNormalizer.normalize(tag.name).contains(needle) else { return nil }
            return link.paperID
        })
        let collectionPaperIDs = Set(snapshot.collectionPapers.compactMap { link -> Int? in
            guard let collection = snapshot.collections[link.collectionID], SearchNormalizer.normalize(collection.name).contains(needle) else { return nil }
            return link.paperID
        })
        let notedPaperIDs = Set(snapshot.notes.values.compactMap { note in
            SearchNormalizer.normalize(note.body).contains(needle) ? note.paperID : nil
        })
        return Array(snapshot.papers.values.filter { paper in
            taggedPaperIDs.contains(paper.literatureID) || collectionPaperIDs.contains(paper.literatureID) || notedPaperIDs.contains(paper.literatureID) ||
            SearchNormalizer.normalize(paper.displayTitle).contains(needle) ||
            paper.titles.contains { SearchNormalizer.normalize($0.value).contains(needle) } ||
            paper.contributors.contains { SearchNormalizer.normalize($0.fullName).contains(needle) } ||
            SearchNormalizer.normalize(paper.arxivID ?? "").contains(needle) ||
            SearchNormalizer.normalize(paper.doi ?? "").contains(needle)
        }
        .sorted { ($0.timelineDate ?? .distantPast) > ($1.timelineDate ?? .distantPast) }
        .prefix(maximum))
    }

    func saveOrphanedBlobDeletion(_ record: OrphanedBlobDeletion) async throws {
        try await applyV3(.saveOrphanedBlobDeletion(record))
    }

    func orphanedBlobDeletions() async -> [OrphanedBlobDeletion] {
        Array((await snapshot()).orphanedBlobDeletions.values)
            .sorted { $0.createdAt < $1.createdAt }
    }

    func removeOrphanedBlobDeletion(blobHash: String) async throws {
        try await applyV3(.deleteOrphanedBlobDeletion(blobHash: blobHash))
    }

    func commitAuthorIndexPage(authors: [Author], checkpoint: SyncCheckpoint,
                               generation: AuthorIndexGeneration) async throws {
        try await upsert(authors: authors)
        try await save(checkpoint: checkpoint)
        try await applyV3(.saveGeneration(generation))
    }

    func commitHIndexOutcome(author: Author, checkpoint: SyncCheckpoint,
                             generation: AuthorIndexGeneration) async throws {
        try await upsert(authors: [author])
        try await save(checkpoint: checkpoint)
        try await applyV3(.saveGeneration(generation))
    }

    func commitAuthorIndexState(checkpoint: SyncCheckpoint,
                                generation: AuthorIndexGeneration) async throws {
        try await save(checkpoint: checkpoint)
        try await applyV3(.saveGeneration(generation))
    }

    func commitAuthorIndexCompletion(checkpoint: SyncCheckpoint,
                                     generation: AuthorIndexGeneration) async throws {
        try await save(checkpoint: checkpoint)
        try await applyV3(.saveGeneration(generation))
    }

    /// Compatibility stores retain the write order, while the V8 active
    /// repository overrides this with a single SwiftData transaction.  The
    /// default must not be used as evidence of V8 transactionality.
    func commitPaperSyncPage(_ commit: PaperSyncPageCommit) async throws -> PaperUpsertReport {
        let report = try await upsert(papers: commit.papers, for: commit.authorRecid)
        for revision in commit.revisions { try await applyV3(.saveRevision(revision)) }
        for event in commit.radarEvents { try await applyV3(.saveRadarEvent(event)) }
        try await save(checkpoint: commit.checkpoint)
        try await applyV3(.saveJobEvent(commit.jobEvent))
        return report
    }

    func commitAcceptedImport(paper: Paper, conflict: V3ImportConflict) async throws {
        try await upsert(detail: paper)
        try await applyV3(.saveImportConflict(conflict))
    }

    func commitNotebookEntry(_ entry: NotebookEntry, links: [NotebookAnchorLink]) async throws {
        try await applyV3(.saveNotebookEntry(entry))
        try await applyV3(.replaceNotebookAnchorLinks(entryID: entry.id, links: links))
    }

    func deleteFullTextAndPlan(documentID: String) async throws -> FullTextDeletionPlan {
        let before = await snapshot()
        let document = before.fullTextDocuments[documentID]
        let reference = before.documentReferences[documentID]
        let blobHash = reference?.contentBlobHash ?? document?.sha256
        let filename = reference.flatMap { before.contentBlobs[$0.contentBlobHash]?.localFilename }
            ?? document?.localFilename
        try await deleteFullText(documentID: documentID)
        let after = await snapshot()
        let remaining = blobHash.flatMap { after.contentBlobs[$0]?.referenceCount } ?? 0
        return FullTextDeletionPlan(documentID: documentID, blobHash: blobHash, localFilename: filename,
                                    remainingReferenceCount: remaining, shouldDeleteFile: remaining == 0)
    }

    /// Compatibility implementation for existing repositories.  The active
    /// SwiftData final repository overrides this with its own row transaction;
    /// this bounded before/after bridge nevertheless guarantees the essential
    /// order for current stores: snapshot the identities, commit the document
    /// mutation, then return only blobs whose committed refcount is zero.
    func saveFullTextAndPlan(document: FullTextDocument, chunks: [EvidenceChunk], anchors: [EvidenceAnchor]) async throws -> BlobMutationPlan {
        let before = await snapshot()
        let superseded = before.fullTextDocuments.values.filter {
            $0.paperID == document.paperID && $0.sourceKind == document.sourceKind &&
                $0.sourceURL == document.sourceURL && $0.id != document.id
        }
        try await saveFullText(document: document, chunks: chunks, anchors: anchors)
        let after = await snapshot()
        var hashes: [String] = []
        var filenames: [String] = []
        for old in superseded {
            let reference = before.documentReferences[old.id]
            let hash = reference?.contentBlobHash ?? old.sha256
            guard (after.contentBlobs[hash]?.referenceCount ?? 0) == 0 else { continue }
            hashes.append(hash)
            if let filename = before.contentBlobs[hash]?.localFilename ?? old.localFilename { filenames.append(filename) }
        }
        return BlobMutationPlan(documentID: document.id,
                                retiredBlobHashes: Array(Set(hashes)).sorted(),
                                retiredLocalFilenames: Array(Set(filenames)).sorted())
    }
}

enum LibraryInitializationState: Equatable, Sendable {
    case ready
    case migrated
    case recovered(String)
    case readOnlyFailure(String)
    case jsonFallback(String)
}

enum ReferenceMutation: Sendable {
    case setFavorite(paperID: Int, isFavorite: Bool, at: Date)
    case upsertNote(UserNote)
    case deleteNote(UUID)
    case upsertTag(LibraryTag)
    case deleteTag(UUID)
    case setTags(paperID: Int, tagIDs: Set<UUID>)
    case upsertCollection(PaperCollection)
    case deleteCollection(UUID)
    case setCollectionPapers(collectionID: UUID, paperIDs: Set<Int>, at: Date)
}

extension LibrarySnapshot {
    mutating func merge(authors incoming: [Author]) {
        for author in incoming {
            let prior = authors[author.recid]
            var merged = author
            merged.isTracked = prior?.isTracked ?? author.isTracked
            merged.lastSyncedAt = author.lastSyncedAt ?? prior?.lastSyncedAt
            merged.lastCheckpointAt = author.lastCheckpointAt ?? prior?.lastCheckpointAt
            merged.lastSuccessfulSyncAt = author.lastSuccessfulSyncAt ?? prior?.lastSuccessfulSyncAt
            // Candidate pages do not carry citation summaries. Keep the prior
            // verified value/state until an explicit h-index outcome arrives.
            if merged.hIndex == nil, let prior {
                merged.hIndex = prior.hIndex
                if merged.hIndexState == .unknown { merged.hIndexState = prior.hIndexState }
            }
            authors[merged.recid] = merged
        }
    }

    mutating func merge(papers incoming: [Paper], for authorRecid: Int) -> PaperUpsertReport {
        var report = PaperUpsertReport.empty
        for (position, paper) in incoming.enumerated() {
            var merged = paper
            if let prior = papers[paper.literatureID] {
                merged.firstSeenAt = prior.firstSeenAt
                merged.isRead = prior.isRead
                merged.readAt = prior.readAt
                merged.isFavorite = prior.isFavorite
                if paperMetadataChanged(from: prior, to: paper) { report.metadataUpdated += 1 }
                if let oldCitation = prior.citationCount, let newCitation = paper.citationCount, oldCitation != newCitation {
                    report.citationChanged += 1
                    let now = Date()
                    let latest = citationSnapshots.values.filter { $0.paperID == paper.literatureID }.max { $0.fetchedAt < $1.fetchedAt }
                    if latest?.citationCount != newCitation {
                        let snapshot = CitationSnapshot(paperID: paper.literatureID, citationCount: newCitation, fetchedAt: now)
                        citationSnapshots[snapshot.id] = snapshot
                    }
                }
                else { report.unchanged += 1 }
            } else {
                report.inserted += 1
            }
            papers[paper.literatureID] = merged
            paperAuthorLinks.insert(PaperAuthorLink(paperID: paper.literatureID, authorRecid: authorRecid, position: position))
            if let citationCount = paper.citationCount {
                let latest = citationSnapshots.values.filter { $0.paperID == paper.literatureID }.max { $0.fetchedAt < $1.fetchedAt }
                if latest?.citationCount != citationCount {
                    let citation = CitationSnapshot(paperID: paper.literatureID, citationCount: citationCount, fetchedAt: Date())
                    citationSnapshots[citation.id] = citation
                }
            }
        }
        return report
    }

    /// In-memory and JSON compatibility stores use one actor-local snapshot
    /// publication.  V8 has an independent bounded-row implementation below;
    /// this helper must never be called from its hot path.
    mutating func commit(paperSyncPage page: PaperSyncPageCommit) -> PaperUpsertReport {
        let report = merge(papers: page.papers, for: page.authorRecid)
        for revision in page.revisions { paperRevisionSnapshots[revision.id] = revision }
        for event in page.radarEvents { radarEvents[event.id] = event }
        checkpoints[page.checkpoint.id] = page.checkpoint
        syncJobEvents[page.jobEvent.id] = page.jobEvent
        return report
    }

    mutating func updateRead(_ read: Bool, paperID: Int, at: Date?) {
        guard var paper = papers[paperID] else { return }
        paper.isRead = read
        paper.readAt = read ? (at ?? Date()) : nil
        papers[paperID] = paper
        readingStates[paperID] = ReadingState(paperID: paperID, isRead: paper.isRead, readAt: paper.readAt,
                                              isFavorite: paper.isFavorite, updatedAt: at ?? Date())
    }

    mutating func apply(_ mutation: ReferenceMutation) {
        switch mutation {
        case .setFavorite(let paperID, let isFavorite, let at):
            guard var paper = papers[paperID] else { return }
            paper.isFavorite = isFavorite
            papers[paperID] = paper
            readingStates[paperID] = ReadingState(paperID: paperID, isRead: paper.isRead, readAt: paper.readAt,
                                                  isFavorite: isFavorite, updatedAt: at)
        case .upsertNote(let note): notes[note.id] = note
        case .deleteNote(let id): notes.removeValue(forKey: id)
        case .upsertTag(let tag): tags[tag.id] = tag
        case .deleteTag(let id):
            tags.removeValue(forKey: id)
            paperTags = paperTags.filter { $0.tagID != id }
        case .setTags(let paperID, let tagIDs):
            paperTags = paperTags.filter { $0.paperID != paperID }
            paperTags.formUnion(tagIDs.map { PaperTagLink(paperID: paperID, tagID: $0) })
        case .upsertCollection(let collection): collections[collection.id] = collection
        case .deleteCollection(let id):
            collections.removeValue(forKey: id)
            collectionPapers = collectionPapers.filter { $0.collectionID != id }
        case .setCollectionPapers(let collectionID, let paperIDs, let at):
            collectionPapers = collectionPapers.filter { $0.collectionID != collectionID }
            collectionPapers.formUnion(paperIDs.map { CollectionPaperLink(collectionID: collectionID, paperID: $0, addedAt: at) })
        }
    }

    mutating func storeFullText(document: FullTextDocument, chunks: [EvidenceChunk], anchors: [EvidenceAnchor]) {
        // Re-extracting the same document is an idempotent replacement.  Do
        // not retain quotes/chunks from an older extraction pass.
        let chunksByQuote = Dictionary(grouping: chunks, by: { $0.textHash })
        // FullTextDocument.id contains the hash for backward compatibility,
        // so a changed download creates a new id. Retire an older document
        // with the same paper/source URL before installing the replacement.
        let superseded = fullTextDocuments.values.filter {
            $0.paperID == document.paperID && $0.sourceKind == document.sourceKind &&
            $0.sourceURL == document.sourceURL && $0.sha256 != document.sha256
        }
        for old in superseded {
            let oldPrefix = "v3pdf:\(old.paperID):\(old.sha256):"
            let oldChunkIDs = Set(evidenceChunks.values.filter { $0.paperID == old.paperID && $0.documentHash == old.sha256 }.map(\.id))
            evidenceChunks = evidenceChunks.filter { !($0.value.paperID == old.paperID && $0.value.documentHash == old.sha256) }
            evidenceAnchors = evidenceAnchors.filter { !($0.value.paperID == old.paperID && $0.value.sourceKind == .pdf && (oldChunkIDs.contains($0.key) || $0.key.hasPrefix(oldPrefix))) }
            fullTextDocuments.removeValue(forKey: old.id)
            if var reference = documentReferences[old.id] {
                reference.isDeleted = true
                documentReferences[old.id] = reference
                if var blob = contentBlobs[reference.contentBlobHash] {
                    blob.referenceCount = max(0, blob.referenceCount - 1)
                    contentBlobs[reference.contentBlobHash] = blob
                }
            }
        }
        // A re-download may produce a new document hash (and therefore a new
        // FullTextDocument id). Relocate only a unique exact quote match
        // across the paper's previous documents; never guess by proximity.
        for (id, annotation) in userEvidenceAnchors where annotation.paperID == document.paperID && annotation.sourceKind == .pdf {
            let matches = chunksByQuote[annotation.quoteHash] ?? []
            let exact = matches.filter { $0.text == annotation.quote }
            let replacement = exact.count == 1 ? exact[0] : nil
            let nextStatus: UserEvidenceAnchorStatus = replacement == nil ? .stale : .valid
            guard let replacement else {
                userEvidenceAnchors[id] = UserEvidenceAnchor(id: annotation.id, paperID: annotation.paperID,
                                                              documentHash: annotation.documentHash, sourceKind: annotation.sourceKind,
                                                              page: annotation.page, characterRangeStart: annotation.characterRangeStart,
                                                              characterRangeEnd: annotation.characterRangeEnd, quote: annotation.quote,
                                                              quoteHash: annotation.quoteHash, colorName: annotation.colorName,
                                                              label: annotation.label, note: annotation.note, status: .stale,
                                                              createdAt: annotation.createdAt, updatedAt: Date())
                continue
            }
            userEvidenceAnchors[id] = UserEvidenceAnchor(id: annotation.id, paperID: annotation.paperID,
                                                          documentHash: document.sha256, sourceKind: annotation.sourceKind,
                                                          page: replacement.page, characterRangeStart: replacement.characterRangeStart,
                                                          characterRangeEnd: replacement.characterRangeEnd, quote: annotation.quote,
                                                          quoteHash: annotation.quoteHash, colorName: annotation.colorName,
                                                          label: annotation.label, note: annotation.note, status: nextStatus,
                                                          createdAt: annotation.createdAt, updatedAt: Date())
        }
        let documentPrefix = "v3pdf:\(document.paperID):\(document.sha256):"
        let documentChunkIDs = Set(evidenceChunks.values.filter { $0.paperID == document.paperID && $0.documentHash == document.sha256 }.map(\.id))
        evidenceChunks = evidenceChunks.filter { !($0.value.paperID == document.paperID && $0.value.documentHash == document.sha256) }
        evidenceAnchors = evidenceAnchors.filter { anchor in
            !(anchor.value.paperID == document.paperID && anchor.value.sourceKind == .pdf && (documentChunkIDs.contains(anchor.key) || anchor.key.hasPrefix(documentPrefix)))
        }
        if let oldReference = documentReferences[document.id], oldReference.contentBlobHash != document.sha256,
           var oldBlob = contentBlobs[oldReference.contentBlobHash] {
            oldBlob.referenceCount = max(0, oldBlob.referenceCount - 1)
            contentBlobs[oldReference.contentBlobHash] = oldBlob
        }
        // Every active document reference contributes exactly once to its
        // current blob, including replacement of a reference with a new hash.
        if documentReferences[document.id]?.contentBlobHash != document.sha256 {
            var blob = contentBlobs[document.sha256] ?? ContentBlob(hash: document.sha256, byteCount: document.byteCount,
                                                                     localFilename: document.localFilename, referenceCount: 0, createdAt: Date())
            blob.referenceCount += 1
            contentBlobs[document.sha256] = blob
        }
        documentReferences[document.id] = DocumentReference(id: document.id, paperID: document.paperID,
                                                             documentHash: document.sha256, sourceURL: document.sourceURL,
                                                             sourceKind: document.sourceKind, contentBlobHash: document.sha256,
                                                             isDeleted: false)
        fullTextDocuments[document.id] = document
        for chunk in chunks { evidenceChunks[chunk.id] = chunk }
        for anchor in anchors { evidenceAnchors[anchor.id] = anchor }
    }

    mutating func storeEvidenceAnchors(_ anchors: [EvidenceAnchor]) {
        for anchor in anchors { evidenceAnchors[anchor.id] = anchor }
    }

    mutating func deleteFullText(documentID: String) {
        guard let document = fullTextDocuments.removeValue(forKey: documentID) else { return }
        for (id, annotation) in userEvidenceAnchors where annotation.paperID == document.paperID && annotation.documentHash == document.sha256 {
            userEvidenceAnchors[id] = UserEvidenceAnchor(id: annotation.id, paperID: annotation.paperID,
                                                          documentHash: annotation.documentHash, sourceKind: annotation.sourceKind,
                                                          page: annotation.page, characterRangeStart: annotation.characterRangeStart,
                                                          characterRangeEnd: annotation.characterRangeEnd, quote: annotation.quote,
                                                          quoteHash: annotation.quoteHash, colorName: annotation.colorName,
                                                          label: annotation.label, note: annotation.note, status: .stale,
                                                          createdAt: annotation.createdAt, updatedAt: Date())
        }
        let documentPrefix = "v3pdf:\(document.paperID):\(document.sha256):"
        let documentChunkIDs = Set(evidenceChunks.values.filter { $0.paperID == document.paperID && $0.documentHash == document.sha256 }.map(\.id))
        evidenceChunks = evidenceChunks.filter { !($0.value.paperID == document.paperID && $0.value.documentHash == document.sha256) }
        evidenceAnchors = evidenceAnchors.filter { anchor in
            !(anchor.value.paperID == document.paperID && anchor.value.sourceKind == .pdf && (documentChunkIDs.contains(anchor.key) || anchor.key.hasPrefix(documentPrefix)))
        }
        evidenceInsights = evidenceInsights.filter { !($0.value.paperID == document.paperID && $0.value.documentHash == document.sha256) }
        if var reference = documentReferences[documentID] {
            reference.isDeleted = true
            documentReferences[documentID] = reference
            if var blob = contentBlobs[reference.contentBlobHash] {
                blob.referenceCount = max(0, blob.referenceCount - 1)
                contentBlobs[reference.contentBlobHash] = blob
            }
        }
    }

    mutating func apply(v3 mutation: V3Mutation) {
        switch mutation {
        case .deleteInsight(let key): insights.removeValue(forKey: key)
        case .deleteEvidenceInsight(let key): evidenceInsights.removeValue(forKey: key)
        case .deleteVisionArtifact(let key): visionArtifacts.removeValue(forKey: key)
        case .saveGeneration(let value): authorIndexGenerations[value.id] = value
        case .saveRevision(let value): paperRevisionSnapshots[value.id] = value
        case .saveRadarEvent(let value): radarEvents[value.id] = value
        case .acknowledgeRadarEvent(let id): radarEvents[id]?.isAcknowledged = true
        case .saveQuery(let value): savedInspireQueries[value.id] = value
        case .deleteQuery(let id): savedInspireQueries.removeValue(forKey: id)
        case .saveBatch(let value): syncBatchesV3[value.id] = value
        case .saveJobEvent(let value): syncJobEvents[value.id] = value
        case .saveBlob(let value): contentBlobs[value.hash] = value
        case .saveOrphanedBlobDeletion(let value): orphanedBlobDeletions[value.blobHash] = value
        case .deleteOrphanedBlobDeletion(let blobHash): orphanedBlobDeletions.removeValue(forKey: blobHash)
        case .saveDocumentReference(let value): documentReferences[value.id] = value
        case .saveUserAnchor(let value): userEvidenceAnchors[value.id] = value
        case .deleteUserAnchor(let id): userEvidenceAnchors.removeValue(forKey: id)
        case .saveNotebookEntry(let value): notebookEntries[value.id] = value
        case .deleteNotebookEntry(let id):
            notebookEntries.removeValue(forKey: id)
            notebookAnchorLinks = notebookAnchorLinks.filter { $0.entryID != id }
        case .replaceNotebookAnchorLinks(let entryID, let links):
            notebookAnchorLinks = notebookAnchorLinks.filter { $0.entryID != entryID }
            notebookAnchorLinks.formUnion(links)
        case .saveWorkspace(let value): workspaces[value.id] = value
        case .deleteWorkspace(let id):
            workspaces.removeValue(forKey: id)
            workspacePaperLinks = workspacePaperLinks.filter { $0.workspaceID != id }
            physicsContracts = physicsContracts.filter { $0.value.workspaceID != id }
            physicsContractCells = physicsContractCells.filter { $0.value.workspaceID != id }
        case .saveWorkspaceLink(let value):
            workspacePaperLinks = workspacePaperLinks.filter { !($0.workspaceID == value.workspaceID && $0.paperID == value.paperID) }
            workspacePaperLinks.insert(value)
        case .deleteWorkspaceLink(let workspaceID, let paperID):
            workspacePaperLinks = workspacePaperLinks.filter { !($0.workspaceID == workspaceID && $0.paperID == paperID) }
        case .savePhysicsContract(let value): physicsContracts[value.id] = value
        case .savePhysicsCell(let value): physicsContractCells[value.id] = value
        case .replacePhysicsMatrix(let workspaceID, let cells):
            physicsContractCells = physicsContractCells.filter { $0.value.workspaceID != workspaceID }
            for cell in cells { physicsContractCells[cell.id] = cell }
        case .saveCitationEdge(let value): citationEdges[value.id] = value
        case .saveCoauthorEdge(let value): coauthorEdges[value.id] = value
        case .saveExport(let value): exportRecords[value.id] = value
        case .saveCloudState(let value): cloudSyncStates[value.id] = value
        case .saveConflict(let value): conflictCopies[value.id] = value
        case .saveMigrationJournal(let value): migrationJournal[value.id] = value
        case .saveImportedBibliography(let value): importedBibliographies[value.id] = value
        case .saveImportConflict(let value): importConflicts[value.importedID] = value
        case .setImportConflictStatus(let importedID, let status):
            guard var conflict = importConflicts[importedID] else { return }
            conflict.status = status
            if status != .accepted { conflict.acceptedFields = [] }
            importConflicts[importedID] = conflict
        case .quarantineEvidence(let id): quarantinedEvidenceIDs.insert(id)
        }
    }

    private func paperMetadataChanged(from old: Paper, to new: Paper) -> Bool {
        old.updated != new.updated || old.titles != new.titles || old.abstracts != new.abstracts ||
        old.citationCount != new.citationCount || old.figures != new.figures ||
        old.documents != new.documents || old.contributors != new.contributors ||
        old.publicationStatus != new.publicationStatus || old.publicationYear != new.publicationYear
    }
}

actor InMemoryLibraryStore: LibraryStoring {
    private var value = LibrarySnapshot()
    private var snapshotReads = 0

    func snapshot() -> LibrarySnapshot { snapshotReads += 1; return value }
    /// Test instrumentation only.  Production V8 reads use typed projections;
    /// this makes the same first-paint invariant observable in host-free tests.
    func snapshotReadCount() -> Int { snapshotReads }
    func resetSnapshotReadCount() { snapshotReads = 0 }
    func snapshotResult() -> LibrarySnapshotReadResult {
        LibrarySnapshotReadResult(state: .ready, snapshot: value, message: nil)
    }
    func initializationState() -> LibraryInitializationState { .ready }

    func authorSidebarProjection() -> LibraryAuthorSidebarProjection {
        let activeMembership = value.authorIndexGenerations.values
            .filter { $0.state == .completed }
            .max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }?
            .activeMembership
        return LibraryAuthorSidebarProjection(authors: Array(value.authors.values), activeMembership: activeMembership)
    }

    func author(recid: Int) -> Author? { value.authors[recid] }

    func papers(forAuthorRecid authorRecid: Int) -> [Paper] {
        let ids = Set(value.paperAuthorLinks.filter { $0.authorRecid == authorRecid }.map(\.paperID))
        return ids.compactMap { value.papers[$0] }
            .sorted { lhs, rhs in
                if (lhs.timelineDate ?? Date.distantPast) != (rhs.timelineDate ?? Date.distantPast) {
                    return (lhs.timelineDate ?? Date.distantPast) > (rhs.timelineDate ?? Date.distantPast)
                }
                return lhs.literatureID < rhs.literatureID
            }
    }

    func papers(forIDs: [Int]) -> [Int: Paper] {
        Dictionary(uniqueKeysWithValues: Set(forIDs).compactMap { id in value.papers[id].map { (id, $0) } })
    }

    func trackedAuthorRecids() -> Set<Int> {
        Set(value.authors.values.filter(\.isTracked).map(\.recid))
    }

    func insight(cacheKey: String) -> InsightArtifact? { value.insights[cacheKey] }

    func paperContext(paperID: Int, insightCacheKey: String?) -> LibraryPaperContextProjection {
        LibraryPaperContextProjection(
            paper: value.papers[paperID],
            insight: insightCacheKey.flatMap { value.insights[$0] },
            fullTextDocuments: value.fullTextDocuments.values.filter { $0.paperID == paperID },
            evidenceAnchors: value.evidenceAnchors.values.filter { $0.paperID == paperID },
            evidenceInsights: value.evidenceInsights.values.filter { $0.paperID == paperID },
            visionArtifacts: value.visionArtifacts.values.filter { $0.paperID == paperID },
            notes: value.notes.values.filter { $0.paperID == paperID },
            bibTeXRecord: value.bibTeXRecords[paperID],
            tags: Set(value.paperTags.filter { $0.paperID == paperID }.map(\.tagID)).compactMap { value.tags[$0] },
            availableTags: Array(value.tags.values),
            availableCollections: Array(value.collections.values),
            selectedCollectionIDs: Set(value.collectionPapers.filter { $0.paperID == paperID }.map(\.collectionID))
        )
    }

    func upsert(authors: [Author]) throws {
        value.merge(authors: authors)
    }

    func upsert(papers: [Paper], for authorRecid: Int) throws -> PaperUpsertReport {
        value.merge(papers: papers, for: authorRecid)
    }

    func upsert(detail paper: Paper) throws {
        var merged = paper
        if let prior = value.papers[paper.literatureID] {
            merged.firstSeenAt = prior.firstSeenAt
            merged.isRead = prior.isRead
            merged.readAt = prior.readAt
            merged.isFavorite = prior.isFavorite
        }
        value.papers[paper.literatureID] = merged
    }

    func save(checkpoint: SyncCheckpoint?) throws {
        guard let checkpoint else { return }
        value.checkpoints[checkpoint.id] = checkpoint
    }

    func checkpoint(jobID: String) throws -> SyncCheckpoint? { value.checkpoints[jobID] }

    func completeCheckpoint(jobID: String, at: Date) throws {
        guard var checkpoint = value.checkpoints[jobID] else { return }
        checkpoint.nextURL = nil
        checkpoint.state = .completed
        checkpoint.updatedAt = at
        checkpoint.completedAt = at
        value.checkpoints[jobID] = checkpoint
    }

    func deleteCheckpoint(jobID: String) throws { value.checkpoints.removeValue(forKey: jobID) }

    func commitAuthorIndexPage(authors: [Author], checkpoint: SyncCheckpoint,
                               generation: AuthorIndexGeneration) throws {
        value.merge(authors: authors)
        value.checkpoints[checkpoint.id] = checkpoint
        value.authorIndexGenerations[generation.id] = generation
    }

    func commitHIndexOutcome(author: Author, checkpoint: SyncCheckpoint,
                             generation: AuthorIndexGeneration) throws {
        value.merge(authors: [author])
        value.checkpoints[checkpoint.id] = checkpoint
        value.authorIndexGenerations[generation.id] = generation
    }

    func commitAuthorIndexState(checkpoint: SyncCheckpoint,
                                generation: AuthorIndexGeneration) throws {
        value.checkpoints[checkpoint.id] = checkpoint
        value.authorIndexGenerations[generation.id] = generation
    }

    func commitAuthorIndexCompletion(checkpoint: SyncCheckpoint,
                                     generation: AuthorIndexGeneration) throws {
        value.checkpoints[checkpoint.id] = checkpoint
        value.authorIndexGenerations[generation.id] = generation
    }

    func commitPaperSyncPage(_ commit: PaperSyncPageCommit) throws -> PaperUpsertReport {
        value.commit(paperSyncPage: commit)
    }

    func save(insight: InsightArtifact) throws { value.insights[insight.cacheKey] = insight }
    func removeInsights() throws { value.insights.removeAll() }

    func setTracked(_ tracked: Bool, authorRecid: Int) throws {
        guard var author = value.authors[authorRecid] else { return }
        author.isTracked = tracked
        value.authors[authorRecid] = author
    }

    func markRead(_ read: Bool, paperID: Int, at: Date?) throws { value.updateRead(read, paperID: paperID, at: at) }
    func applyReferenceMutation(_ mutation: ReferenceMutation) throws { value.apply(mutation) }
    func saveFullText(document: FullTextDocument, chunks: [EvidenceChunk], anchors: [EvidenceAnchor]) throws { value.storeFullText(document: document, chunks: chunks, anchors: anchors) }
    func saveEvidenceAnchors(_ anchors: [EvidenceAnchor]) throws { value.storeEvidenceAnchors(anchors) }
    func deleteFullText(documentID: String) throws { value.deleteFullText(documentID: documentID) }
    func saveEvidenceInsight(_ artifact: EvidenceInsightArtifact) throws { value.evidenceInsights[artifact.cacheKey] = artifact }
    func saveVisionArtifact(_ artifact: VisionArtifact) throws { value.visionArtifacts[artifact.cacheKey] = artifact }
    func saveBibTeXRecord(_ record: BibTeXRecord) throws { value.bibTeXRecords[record.paperID] = record }
    func commitAcceptedImport(paper: Paper, conflict: V3ImportConflict) throws {
        var merged = paper
        if let prior = value.papers[paper.literatureID] {
            merged.firstSeenAt = prior.firstSeenAt
            merged.isRead = prior.isRead
            merged.readAt = prior.readAt
            merged.isFavorite = prior.isFavorite
        }
        value.papers[merged.literatureID] = merged
        value.importConflicts[conflict.importedID] = conflict
    }
    func commitNotebookEntry(_ entry: NotebookEntry, links: [NotebookAnchorLink]) throws {
        value.notebookEntries[entry.id] = entry
        value.notebookAnchorLinks = value.notebookAnchorLinks.filter { $0.entryID != entry.id }
        value.notebookAnchorLinks.formUnion(links)
    }
    func applyV3(_ mutation: V3Mutation) throws { value.apply(v3: mutation) }
}

/// A small, schema-versioned on-disk store used by the first package build.
/// The API remains actor-isolated so it can be replaced by a SwiftData repository
/// without exposing a mutable model context to SwiftUI.
actor JSONLibraryStore: LibraryStoring {
    private let fileURL: URL
    private var value: LibrarySnapshot
    private let state: LibraryInitializationState

    init(fileURL: URL) {
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            value = LibrarySnapshot()
            state = .jsonFallback("SwiftData container unavailable; no existing JSON library")
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder.latticeLens.decode(LibrarySnapshot.self, from: data)
            let originalSchema = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int ?? 1
            let needsV3Migration = decoded.evidenceChunks.values.contains { !$0.id.hasPrefix("v3pdf:\($0.paperID):\($0.documentHash):") }
            if originalSchema < 2 || needsV3Migration {
                let checksum = StableHash.sha256(data)
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let suffix = needsV3Migration ? "v3" : "v1"
                let backup = fileURL.deletingLastPathComponent().appendingPathComponent("\(fileURL.lastPathComponent).\(suffix)-\(stamp)-\(checksum.prefix(12)).backup")
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: backup, options: .atomic)
                let migratedSnapshot = needsV3Migration ? V3MigrationService.migrate(decoded).snapshot : decoded
                let migrated = try JSONEncoder.latticeLens.encode(migratedSnapshot)
                try migrated.write(to: fileURL, options: .atomic)
                value = migratedSnapshot
                state = .migrated
            } else {
                value = decoded
                state = .jsonFallback("SwiftData container unavailable; JSON library loaded")
            }
        } catch {
            // A corrupt primary never becomes an empty writable library. Try
            // the latest validated backup, otherwise remain read-only with the
            // last in-memory value (empty only when no valid backup exists).
            let directory = fileURL.deletingLastPathComponent()
            let prefix = fileURL.lastPathComponent + "."
            let backupURLs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]))?
                .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "backup" }
                .sorted { lhs, rhs in
                    let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return l > r
                } ?? []
            let canonicalBackup = fileURL.appendingPathExtension("backup")
            let candidates = [canonicalBackup] + backupURLs
            if let backupData = candidates.lazy.compactMap({ try? Data(contentsOf: $0) }).first,
               let recovered = try? JSONDecoder.latticeLens.decode(LibrarySnapshot.self, from: backupData) {
                value = recovered
                state = .recovered("primary JSON 损坏；已读取校验通过的 latest backup，primary 未覆盖")
            } else {
                var failure = LibrarySnapshot()
                failure.readErrorMessage = "JSON decode/migration failed; primary and backups left untouched"
                value = failure
                state = .readOnlyFailure("JSON decode/migration failed; original and backup files left untouched")
            }
        }
    }

    func initializationState() -> LibraryInitializationState { state }

    func snapshotResult() -> LibrarySnapshotReadResult {
        switch state {
        case .readOnlyFailure(let message):
            return LibrarySnapshotReadResult(state: .readOnlyFailure, snapshot: value, message: message)
        case .migrated, .recovered:
            return LibrarySnapshotReadResult(state: .recovered, snapshot: value, message: "JSON migration completed")
        default:
            return LibrarySnapshotReadResult(state: .ready, snapshot: value, message: nil)
        }
    }

    private func requireWritable() throws {
        if case .readOnlyFailure(let reason) = state { throw LatticeLensError.persistenceUnavailable(reason) }
    }

    func snapshot() -> LibrarySnapshot { value }

    func upsert(authors: [Author]) throws {
        try requireWritable()
        value.merge(authors: authors)
        try persist()
    }

    func upsert(papers: [Paper], for authorRecid: Int) throws -> PaperUpsertReport {
        try requireWritable()
        let report = value.merge(papers: papers, for: authorRecid)
        try persist()
        return report
    }

    func commitPaperSyncPage(_ commit: PaperSyncPageCommit) throws -> PaperUpsertReport {
        try requireWritable()
        let report = value.commit(paperSyncPage: commit)
        try persist()
        return report
    }

    func upsert(detail paper: Paper) throws {
        try requireWritable()
        var merged = paper
        if let prior = value.papers[paper.literatureID] {
            merged.firstSeenAt = prior.firstSeenAt
            merged.isRead = prior.isRead
            merged.readAt = prior.readAt
            merged.isFavorite = prior.isFavorite
        }
        value.papers[paper.literatureID] = merged
        try persist()
    }

    func commitAcceptedImport(paper: Paper, conflict: V3ImportConflict) throws {
        try requireWritable()
        var merged = paper
        if let prior = value.papers[paper.literatureID] {
            merged.firstSeenAt = prior.firstSeenAt
            merged.isRead = prior.isRead
            merged.readAt = prior.readAt
            merged.isFavorite = prior.isFavorite
        }
        value.papers[merged.literatureID] = merged
        value.importConflicts[conflict.importedID] = conflict
        try persist()
    }

    func commitNotebookEntry(_ entry: NotebookEntry, links: [NotebookAnchorLink]) throws {
        try requireWritable()
        value.notebookEntries[entry.id] = entry
        value.notebookAnchorLinks = value.notebookAnchorLinks.filter { $0.entryID != entry.id }
        value.notebookAnchorLinks.formUnion(links)
        try persist()
    }

    func save(checkpoint: SyncCheckpoint?) throws {
        try requireWritable()
        guard let checkpoint else { return }
        value.checkpoints[checkpoint.id] = checkpoint
        try persist()
    }

    func checkpoint(jobID: String) throws -> SyncCheckpoint? { value.checkpoints[jobID] }

    func completeCheckpoint(jobID: String, at: Date) throws {
        try requireWritable()
        guard var checkpoint = value.checkpoints[jobID] else { return }
        checkpoint.nextURL = nil
        checkpoint.state = .completed
        checkpoint.updatedAt = at
        checkpoint.completedAt = at
        value.checkpoints[jobID] = checkpoint
        try persist()
    }

    func deleteCheckpoint(jobID: String) throws {
        try requireWritable()
        value.checkpoints.removeValue(forKey: jobID)
        try persist()
    }

    func save(insight: InsightArtifact) throws {
        try requireWritable()
        value.insights[insight.cacheKey] = insight
        try persist()
    }

    func removeInsights() throws {
        try requireWritable()
        value.insights.removeAll()
        try persist()
    }

    func setTracked(_ tracked: Bool, authorRecid: Int) throws {
        try requireWritable()
        guard var author = value.authors[authorRecid] else { return }
        author.isTracked = tracked
        value.authors[authorRecid] = author
        try persist()
    }

    func markRead(_ read: Bool, paperID: Int, at: Date?) throws {
        try requireWritable()
        value.updateRead(read, paperID: paperID, at: at)
        try persist()
    }

    func applyReferenceMutation(_ mutation: ReferenceMutation) throws {
        try requireWritable()
        value.apply(mutation)
        try persist()
    }

    func saveFullText(document: FullTextDocument, chunks: [EvidenceChunk], anchors: [EvidenceAnchor]) throws {
        try requireWritable()
        value.storeFullText(document: document, chunks: chunks, anchors: anchors)
        try persist()
    }

    func saveEvidenceAnchors(_ anchors: [EvidenceAnchor]) throws {
        try requireWritable()
        value.storeEvidenceAnchors(anchors)
        try persist()
    }

    func deleteFullText(documentID: String) throws {
        try requireWritable()
        value.deleteFullText(documentID: documentID)
        try persist()
    }

    func saveEvidenceInsight(_ artifact: EvidenceInsightArtifact) throws {
        try requireWritable()
        value.evidenceInsights[artifact.cacheKey] = artifact
        try persist()
    }

    func saveVisionArtifact(_ artifact: VisionArtifact) throws {
        try requireWritable()
        value.visionArtifacts[artifact.cacheKey] = artifact
        try persist()
    }

    func saveBibTeXRecord(_ record: BibTeXRecord) throws {
        try requireWritable()
        value.bibTeXRecords[record.paperID] = record
        try persist()
    }

    func applyV3(_ mutation: V3Mutation) throws {
        try requireWritable()
        value.apply(v3: mutation)
        try persist()
    }

    private func persist() throws {
        try requireWritable()
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backupURL = fileURL.appendingPathExtension("backup")
        let manager = FileManager.default
        if manager.fileExists(atPath: fileURL.path) {
            let stagedBackup = directory.appendingPathComponent(".\(fileURL.lastPathComponent).backup-\(UUID().uuidString)")
            defer { try? manager.removeItem(at: stagedBackup) }
            try manager.copyItem(at: fileURL, to: stagedBackup)
            if manager.fileExists(atPath: backupURL.path) {
                _ = try manager.replaceItemAt(backupURL, withItemAt: stagedBackup, backupItemName: nil, options: .usingNewMetadataOnly)
            } else {
                try manager.moveItem(at: stagedBackup, to: backupURL)
            }
        }
        let data = try JSONEncoder.latticeLens.encode(value)
        try data.write(to: fileURL, options: .atomic)
    }
}

extension JSONEncoder {
    static let latticeLens: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let latticeLens: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
