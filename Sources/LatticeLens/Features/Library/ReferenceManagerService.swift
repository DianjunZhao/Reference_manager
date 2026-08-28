import Foundation

struct BibTeXHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let finalURL: URL
    let contentType: String?
}

protocol BibTeXRequesting: Sendable {
    func fetchBibTeX(at url: URL) async throws -> BibTeXHTTPResponse
}

struct URLSessionBibTeXRequester: BibTeXRequesting {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration, delegate: BibTeXRedirectDelegate(), delegateQueue: nil)
        }
    }

    func fetchBibTeX(at url: URL) async throws -> BibTeXHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/x-bibtex, text/x-bibtex;q=0.9, text/plain;q=0.5", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else { throw LatticeLensError.invalidResponse }
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), length > 1_000_000 {
            throw BibTeXExportError.responseTooLarge
        }
        var data = Data(); data.reserveCapacity(min(1_000_000, 64 * 1024))
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= 1_000_000 else { throw BibTeXExportError.responseTooLarge }
        }
        return BibTeXHTTPResponse(data: data, statusCode: http.statusCode, finalURL: finalURL,
                                  contentType: http.value(forHTTPHeaderField: "Content-Type"))
    }
}

private final class BibTeXRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let target = request.url,
              target.scheme?.lowercased() == "https", target.host?.lowercased() == original.host?.lowercased(),
              target.user == nil, target.password == nil, target.fragment == nil,
              (target.port ?? 443) == (original.port ?? 443), target.path.hasPrefix("/api/literature") else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

enum BibTeXExportError: LocalizedError, Equatable {
    case invalidEndpointResponse
    case responseTooLarge
    case malformedBibTeX

    var errorDescription: String? {
        switch self {
        case .invalidEndpointResponse: "INSPIRE BibTeX endpoint 未返回受信任的成功响应。"
        case .responseTooLarge: "INSPIRE BibTeX response 超过本地安全上限。"
        case .malformedBibTeX: "INSPIRE response 不是可导出的 BibTeX；未生成替代条目。"
        }
    }
}

struct ReferenceManagerService: Sendable {
    let store: any LibraryStoring
    let bibTeXRequester: any BibTeXRequesting

    init(store: any LibraryStoring, bibTeXRequester: any BibTeXRequesting = URLSessionBibTeXRequester()) {
        self.store = store
        self.bibTeXRequester = bibTeXRequester
    }

    func searchPapers(_ query: String) async -> [Paper] {
        await store.searchPapers(query, limit: 500)
    }

    func toggleFavorite(paperID: Int, current: Bool) async throws {
        try await store.applyReferenceMutation(.setFavorite(paperID: paperID, isFavorite: !current, at: Date()))
    }

    func saveNote(id: UUID? = nil, paperID: Int, body: String, existingCreatedAt: Date? = nil) async throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count <= 40_000 else { throw LatticeLensError.schemaViolation("用户 note 超过本地上限") }
        let existing = await store.snapshot().notes.values.filter { $0.paperID == paperID }.max { $0.updatedAt < $1.updatedAt }
        let now = Date()
        try await store.applyReferenceMutation(.upsertNote(UserNote(id: id ?? existing?.id ?? UUID(), paperID: paperID, body: trimmed,
                                                                     createdAt: existingCreatedAt ?? existing?.createdAt ?? now, updatedAt: now)))
    }

    func deleteNote(_ id: UUID) async throws {
        try await store.applyReferenceMutation(.deleteNote(id))
    }

    func createTag(named name: String, colorName: String? = nil) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 120 else {
            throw LatticeLensError.schemaViolation("tag 名称必须为 1–120 个字符")
        }
        let snapshot = await store.snapshot()
        guard !snapshot.tags.values.contains(where: { SearchNormalizer.normalize($0.name) == SearchNormalizer.normalize(trimmed) }) else {
            throw LatticeLensError.schemaViolation("已存在同名 local tag")
        }
        try await store.applyReferenceMutation(.upsertTag(LibraryTag(id: UUID(), name: trimmed, colorName: colorName, createdAt: Date())))
    }

    func createCollection(named name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 120 else {
            throw LatticeLensError.schemaViolation("collection 名称必须为 1–120 个字符")
        }
        let snapshot = await store.snapshot()
        guard !snapshot.collections.values.contains(where: { SearchNormalizer.normalize($0.name) == SearchNormalizer.normalize(trimmed) }) else {
            throw LatticeLensError.schemaViolation("已存在同名 collection")
        }
        try await store.applyReferenceMutation(.upsertCollection(PaperCollection(id: UUID(), name: trimmed, createdAt: Date())))
    }

    func renameTag(_ id: UUID, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 120 else { throw LatticeLensError.schemaViolation("tag 名称必须为 1–120 个字符") }
        let snapshot = await store.snapshot()
        guard let old = snapshot.tags[id] else { throw LatticeLensError.malformedPayload }
        try await store.applyReferenceMutation(.upsertTag(LibraryTag(id: old.id, name: trimmed, colorName: old.colorName, createdAt: old.createdAt)))
    }

    func deleteTag(_ id: UUID) async throws -> Int {
        let count = await store.snapshot().paperTags.filter { $0.tagID == id }.count
        try await store.applyReferenceMutation(.deleteTag(id))
        return count
    }

    func renameCollection(_ id: UUID, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 120 else { throw LatticeLensError.schemaViolation("collection 名称必须为 1–120 个字符") }
        let snapshot = await store.snapshot()
        guard let old = snapshot.collections[id] else { throw LatticeLensError.malformedPayload }
        try await store.applyReferenceMutation(.upsertCollection(PaperCollection(id: old.id, name: trimmed, createdAt: old.createdAt)))
    }

    func deleteCollection(_ id: UUID) async throws -> Int {
        let count = await store.snapshot().collectionPapers.filter { $0.collectionID == id }.count
        try await store.applyReferenceMutation(.deleteCollection(id))
        return count
    }

    func setTags(_ tagIDs: Set<UUID>, paperID: Int) async throws {
        try await store.applyReferenceMutation(.setTags(paperID: paperID, tagIDs: tagIDs))
    }

    func setCollection(_ paperIDs: Set<Int>, collectionID: UUID) async throws {
        try await store.applyReferenceMutation(.setCollectionPapers(collectionID: collectionID, paperIDs: paperIDs, at: Date()))
    }

    /// This export contains visible bibliographic/validated evidence content;
    /// it intentionally has no provider setting, endpoint, key, prompt, or log.
    func markdownNote(for paperID: Int) async throws -> String {
        let snapshot = await store.snapshot()
        guard let paper = snapshot.papers[paperID] else { throw LatticeLensError.malformedPayload }
        var lines = ["# \(paper.displayTitle)", "", "- INSPIRE: https://inspirehep.net/literature/\(paper.literatureID)"]
        if let arxiv = paper.arxivID { lines.append("- arXiv: \(arxiv)") }
        if let doi = paper.doi { lines.append("- DOI: \(doi)") }
        if let abstract = paper.preferredAbstract { lines += ["", "## Original abstract", "", abstract] }
        if let artifact = snapshot.insights.values.first(where: { $0.paperID == paperID }) {
            lines += ["", "## 中文标题", "", artifact.insight.titleZH, "", "## 中文摘要", "", artifact.insight.abstractZH]
        }
        if let evidence = snapshot.evidenceInsights.values.first(where: { $0.paperID == paperID }) {
            lines += ["", "## Evidence-backed claims"]
            let claims = [evidence.insight.physics.researchQuestion] + evidence.insight.physics.methodAndDataFlow + evidence.insight.physics.mainResults +
                evidence.insight.physics.reasonableInferences + evidence.insight.physics.missingInformation + evidence.insight.physics.caveats
            for claim in claims {
                let labels = claim.evidenceIDs.compactMap { id in snapshot.evidenceAnchors[id].map { "\(id) (\($0.sourceKind.rawValue) \($0.page.map { "p\($0)" } ?? "metadata"))" } }
                lines.append("- [\(claim.epistemicStatus.rawValue)] \(claim.textZH)\(labels.isEmpty ? "" : " · evidence: \(labels.joined(separator: ", "))")")
            }
        }
        let notes = snapshot.notes.values.filter { $0.paperID == paperID }.sorted { $0.updatedAt < $1.updatedAt }
        if !notes.isEmpty {
            lines += ["", "## Local reading notes"]
            for note in notes { lines += ["", note.body] }
        }
        let tags = Set(snapshot.paperTags.filter { $0.paperID == paperID }.compactMap { snapshot.tags[$0.tagID]?.name }).sorted()
        if !tags.isEmpty { lines += ["", "- Local tags: \(tags.joined(separator: ", "))"] }
        for figure in paper.figures {
            lines.append("- Figure \(figure.key): \(figure.source ?? "unknown") / \(figure.filename ?? "unknown") · provenance: INSPIRE record")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// INSPIRE owns citation formatting.  The app never manufactures a partial
    /// BibTeX entry when the endpoint cannot supply one.
    func bibTeXURL(for paperID: Int) -> URL? {
        URL(string: "https://inspirehep.net/api/literature/\(paperID)?format=bibtex")
    }

    /// Keeps the authoritative INSPIRE content and fetch time together.  An
    /// error leaves any previously cached, verified endpoint response intact.
    func fetchAndCacheBibTeX(for paperID: Int, now: Date = Date()) async throws -> BibTeXRecord {
        guard let endpoint = bibTeXURL(for: paperID) else { throw BibTeXExportError.invalidEndpointResponse }
        let response = try await bibTeXRequester.fetchBibTeX(at: endpoint)
        guard (200..<300).contains(response.statusCode),
              response.finalURL.scheme?.lowercased() == "https",
              response.finalURL.host?.lowercased() == endpoint.host?.lowercased(),
              response.finalURL.user == nil, response.finalURL.password == nil, response.finalURL.fragment == nil else {
            throw BibTeXExportError.invalidEndpointResponse
        }
        guard response.data.count <= 1_000_000 else { throw BibTeXExportError.responseTooLarge }
        guard let contents = String(data: response.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              contents.hasPrefix("@") else { throw BibTeXExportError.malformedBibTeX }
        let record = BibTeXRecord(paperID: paperID, sourceURL: endpoint, sourceFetchedAt: now, contents: contents + "\n")
        try await store.saveBibTeXRecord(record)
        return record
    }

    func exportV3(paperIDs: [Int], format: V3ExportFormat, includeLocalPDFPath: Bool = false,
                  destinationCategory: String = "user-selected") async throws -> (String, ExportRecord) {
        try await V3WorkbenchService(store: store).export(V3NotebookExportRequest(paperIDs: paperIDs, format: format,
                                                                                    includeLocalPDFPath: includeLocalPDFPath,
                                                                                    destinationCategory: destinationCategory))
    }

    /// Prepare bytes without writing a success ledger row.  The caller must
    /// invoke `recordExportOutcome` only from the system file-export callback.
    func prepareExportContents(paperIDs: [Int], format: V3ExportFormat, includeLocalPDFPath: Bool = false) async throws -> String {
        let snapshot = await store.snapshot()
        return try V3NotebookExporter.render(request: V3NotebookExportRequest(paperIDs: paperIDs, format: format,
                                                                                includeLocalPDFPath: includeLocalPDFPath,
                                                                                destinationCategory: "pending"), snapshot: snapshot)
    }

    func recordExportOutcome(paperIDs: [Int], format: V3ExportFormat, contents: String,
                             succeeded: Bool, destinationCategory: String, errorCategory: String? = nil) async throws {
        let snapshot = await store.snapshot()
        let record = ExportRecord(id: UUID(), format: format, paperIDs: paperIDs,
                                  destinationCategory: destinationCategory,
                                  sourceHashes: paperIDs.compactMap { snapshot.papers[$0]?.updated?.ISO8601Format() },
                                  createdAt: Date(), payloadHash: StableHash.sha256(contents), succeeded: succeeded,
                                  errorCategory: errorCategory)
        try await store.applyV3(.saveExport(record))
    }
}
