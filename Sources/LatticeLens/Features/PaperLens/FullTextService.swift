import Foundation
import PDFKit

enum FullTextServiceError: LocalizedError, Equatable {
    case invalidSource
    case unsupportedMIME
    case fileTooLarge
    case noText
    case unableToOpenPDF

    var errorDescription: String? {
        switch self {
        case .invalidSource: "全文 URL 必须是受信任的 HTTPS PDF 或 ar5iv HTML 来源。"
        case .unsupportedMIME: "服务器未返回受支持的 PDF 或 HTML MIME type。"
        case .fileTooLarge: "全文文件超过本地下载上限。"
        case .noText: "全文没有可提取文本；v2 不执行 OCR。"
        case .unableToOpenPDF: "PDF 无法由本地 PDFKit 打开。"
        }
    }
}

/// The production downloader preserves the streaming byte limit, while UI
/// fixtures can supply deterministic PDF bytes without constructing a network
/// session.  `FullTextService` remains responsible for validating the final
/// response URL, MIME type, extraction and persistence in both cases.
struct FullTextDownload: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

/// A HEAD-derived, user-visible estimate.  `advertisedByteCount == nil`
/// means the server did not disclose a length; it never means an unlimited
/// download, because the same hard byte limit is enforced on the GET stream.
struct FullTextDownloadPreflight: Sendable, Equatable {
    let sourceURL: URL
    let finalURL: URL
    let sourceKind: FullTextSourceKind
    let expectedMIME: String
    let advertisedByteCount: Int?
    let hardByteLimit: Int
    let cacheCategory: String
}

protocol FullTextDownloading: Sendable {
    func preflight(request: URLRequest) async throws -> HTTPURLResponse
    func download(request: URLRequest, maximumBytes: Int) async throws -> FullTextDownload
}

struct URLSessionFullTextDownloader: FullTextDownloading, Sendable {
    private let session: URLSession

    init(session: URLSession) { self.session = session }

    func preflight(request: URLRequest) async throws -> HTTPURLResponse {
        var head = request
        head.httpMethod = "HEAD"
        let (bytes, response) = try await session.bytes(for: head)
        // A compliant HEAD has no body.  Consume any unexpected bounded
        // response stream rather than using `data(for:)` on an untrusted
        // endpoint; the request is still protected by the app-owned session
        // resource timeout and redirect delegate.
        var observed = 0
        for try await _ in bytes {
            observed += 1
            guard observed <= 4_096 else { throw FullTextServiceError.fileTooLarge }
        }
        guard let http = response as? HTTPURLResponse else { throw FullTextServiceError.invalidSource }
        return http
    }

    func download(request: URLRequest, maximumBytes: Int) async throws -> FullTextDownload {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FullTextServiceError.invalidSource
        }
        if let advertised = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), advertised > maximumBytes {
            throw FullTextServiceError.fileTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 1_048_576))
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= maximumBytes else { throw FullTextServiceError.fileTooLarge }
        }
        return FullTextDownload(data: data, response: http)
    }

}

typealias FullTextExtraction = (
    document: FullTextDocument,
    chunks: [EvidenceChunk],
    anchors: [EvidenceAnchor],
    formulaInventory: FormulaInventory?
)

struct FullTextService: Sendable {
    static let maximumBytes = 40 * 1024 * 1024
    static let maximumChunkScalars = 3_000
    /// Bump this only when the deterministic ar5iv display-equation extractor
    /// changes. A persisted document without this exact marker is treated as
    /// an old extraction and is re-indexed locally before an all-equations
    /// request; it is never silently treated as complete.
    static let numberedEquationIndexVersion = 3

    let store: any LibraryStoring
    let cacheDirectory: URL
    private let downloader: any FullTextDownloading

    static var defaultCacheDirectory: URL {
        if usesFixtureLaunch {
            if let storeURL = AppLaunchConfiguration.diskBackedLargeFixtureStoreURL {
                return diskBackedFixtureCacheDirectory(storeURL: storeURL)
            }
            if let rawRoot = AppLaunchConfiguration.fixtureCacheRoot {
                return processLocalFixtureCacheDirectory(
                    root: URL(fileURLWithPath: rawRoot, isDirectory: true),
                    processIdentifier: ProcessInfo.processInfo.processIdentifier
                )
            }
            if ProcessInfo.processInfo.environment["LATTICELENS_REQUIRE_PROJECT_LOCAL_TEST_ROOTS"] == "1" {
                guard let rawRoot = ProcessInfo.processInfo.environment["LATTICELENS_TEST_TMP_ROOT"],
                      rawRoot.hasPrefix("/") else {
                    preconditionFailure("The isolated fixture launch requires LATTICELENS_TEST_TMP_ROOT")
                }
                return processLocalFixtureCacheDirectory(
                    root: URL(fileURLWithPath: rawRoot, isDirectory: true),
                    processIdentifier: ProcessInfo.processInfo.processIdentifier
                )
            }
            return processLocalFixtureCacheDirectory(
                root: FileManager.default.temporaryDirectory,
                processIdentifier: ProcessInfo.processInfo.processIdentifier
            )
        }
        return (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appending(path: "LatticeLens/FullText")
    }

    static func diskBackedFixtureCacheDirectory(storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent()
            .appending(path: "FullText", directoryHint: .isDirectory)
    }

    static func processLocalFixtureCacheDirectory(root: URL, processIdentifier: Int32) -> URL {
        root.appending(path: "LatticeLens-UIFixture-\(processIdentifier)/FullText",
                       directoryHint: .isDirectory)
    }

    /// Process-local fixtures are disposable at app exit. A disk-backed
    /// fixture keeps its content-addressed source beside the isolated store
    /// so quit/relaunch and offline reindexing can read the same bytes.
    static func removeFixtureCacheIfPresent() {
        guard usesFixtureLaunch, !AppLaunchConfiguration.requestsDiskBackedLargeFixture else { return }
        let root = defaultCacheDirectory.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: root)
    }

    init(
        store: any LibraryStoring,
        cacheDirectory: URL? = nil,
        session: URLSession? = nil,
        downloader: (any FullTextDownloading)? = nil
    ) {
        self.store = store
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory
        self.downloader = downloader ?? URLSessionFullTextDownloader(session: session ?? Self.makeSafeSession())
    }

    /// Performs no GET.  The UI must show this result and wait for a separate
    /// explicit confirmation before calling `downloadAndExtract`.
    func preflight(sourceURL: URL, sourceKind: FullTextSourceKind = .inspireDocument) async throws -> FullTextDownloadPreflight {
        guard Self.isAllowedSourceURL(sourceURL, sourceKind: sourceKind) else { throw FullTextServiceError.invalidSource }
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "HEAD"
        request.setValue(Self.acceptHeader(for: sourceKind), forHTTPHeaderField: "Accept")
        let response = try await downloader.preflight(request: request)
        guard (200..<300).contains(response.statusCode), Self.isAllowedFinalURL(response.url, sourceURL: sourceURL, sourceKind: sourceKind) else {
            throw FullTextServiceError.invalidSource
        }
        let advertised = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init)
        guard advertised.map({ $0 >= 0 && $0 <= Self.maximumBytes }) ?? true else { throw FullTextServiceError.fileTooLarge }
        return FullTextDownloadPreflight(sourceURL: sourceURL, finalURL: response.url ?? sourceURL,
                                         sourceKind: sourceKind, expectedMIME: Self.expectedMIME(for: sourceKind),
                                         advertisedByteCount: advertised, hardByteLimit: Self.maximumBytes,
                                         cacheCategory: "app-owned full-text cache")
    }

    /// Call only after a user explicitly requests a particular paper document.
    /// The service never crawls or downloads documents as part of metadata sync.
    func downloadAndExtract(paperID: Int, sourceURL: URL, sourceKind: FullTextSourceKind) async throws -> FullTextDocument {
        // Retry only app-owned filenames recorded after a committed reference
        // retirement.  A retry never scans cache directories or infers that an
        // arbitrary PDF is orphaned.
        await retryOrphanedBlobDeletions()
        guard Self.isAllowedSourceURL(sourceURL, sourceKind: sourceKind) else { throw FullTextServiceError.invalidSource }
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "GET"
        request.setValue(Self.acceptHeader(for: sourceKind), forHTTPHeaderField: "Accept")
        let download = try await downloader.download(request: request, maximumBytes: Self.maximumBytes)
        let http = download.response
        guard
              (200..<300).contains(http.statusCode),
              Self.isAllowedFinalURL(http.url, sourceURL: sourceURL, sourceKind: sourceKind) else { throw FullTextServiceError.invalidSource }
        let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let expectedMIME = Self.expectedMIME(for: sourceKind)
        guard mime.contains(expectedMIME) else { throw FullTextServiceError.unsupportedMIME }
        let data = download.data
        guard data.count <= Self.maximumBytes else { throw FullTextServiceError.fileTooLarge }
        let hash = StableHash.sha256(data)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let filename = "\(hash).\(sourceKind == .arxivHTML ? "html" : "pdf")"
        let localURL = cacheDirectory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: localURL.path) { try data.write(to: localURL, options: .atomic) }
        let provisional = FullTextDocument(paperID: paperID, sourceURL: sourceURL, sourceKind: sourceKind, sha256: hash,
                                           byteCount: data.count, localFilename: filename, pageCount: nil,
                                           extractionState: .downloaded, downloadedAt: Date(), lastErrorCategory: nil)
        let provisionalPlan = try await store.saveFullTextAndPlan(document: provisional, chunks: [], anchors: [])
        try await retireCommittedBlobs(provisionalPlan)
        do {
            let extracted = try sourceKind == .arxivHTML
                ? extractHTML(paperID: paperID, sourceURL: sourceURL, sourceKind: sourceKind, localURL: localURL, hash: hash, byteCount: data.count)
                : extract(paperID: paperID, sourceURL: sourceURL, sourceKind: sourceKind, localURL: localURL, hash: hash, byteCount: data.count)
            return try await commit(extraction: extracted)
        } catch {
            var failed = provisional
            failed.extractionState = error as? FullTextServiceError == .noText ? .textExtractionUnavailable : .failed
            failed.lastErrorCategory = String(describing: error)
            let failedPlan = try await store.saveFullTextAndPlan(document: failed, chunks: [], anchors: [])
            try await retireCommittedBlobs(failedPlan)
            throw error
        }
    }

    /// Rebuilds structured numbered-equation chunks from an already cached
    /// ar5iv HTML file. This performs no HEAD/GET, does not enumerate cache
    /// directories, and validates the content-addressed filename, byte count
    /// and SHA-256 before replacing only this document's extracted chunks.
    func reindexNumberedEquations(document: FullTextDocument) async throws -> FullTextDocument {
        guard document.sourceKind == .arxivHTML,
              let filename = document.localFilename else {
            throw FullTextServiceError.invalidSource
        }
        let localURL = try V4OwnedPath.canonicalFile(named: filename, root: cacheDirectory)
        let data = try Data(contentsOf: localURL, options: [.mappedIfSafe])
        guard data.count == document.byteCount, StableHash.sha256(data) == document.sha256 else {
            throw FullTextServiceError.invalidSource
        }
        var extraction = try extractHTML(
            paperID: document.paperID,
            sourceURL: document.sourceURL,
            sourceKind: document.sourceKind,
            localURL: localURL,
            hash: document.sha256,
            byteCount: document.byteCount
        )
        // Re-indexing is not a new download. Preserve the original receipt
        // timestamp while upgrading only its deterministic local extraction.
        extraction.document.downloadedAt = document.downloadedAt
        return try await commit(extraction: extraction)
    }

    func delete(document: FullTextDocument) async throws {
        // Validate the filename before touching durable state.  The actual
        // content-addressed file is removed only after the store mutation has
        // committed and its reference count reaches zero.
        let validatedURL: URL?
        if let filename = document.localFilename {
            validatedURL = try V4OwnedPath.canonicalFile(named: filename, root: cacheDirectory)
        } else {
            validatedURL = nil
        }
        let plan = try await store.deleteFullTextAndPlan(documentID: document.id)
        guard plan.shouldDeleteFile, let filename = plan.localFilename else { return }
        let localURL = try V4OwnedPath.canonicalFile(named: filename, root: cacheDirectory)
        // Prefer the prevalidated URL when it refers to the same canonical
        // path; a store may supply the blob filename when the document row did
        // not carry one.
        let target = validatedURL?.path == localURL.path ? validatedURL! : localURL
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            // The durable reference is already gone.  Keep a bounded retry
            // journal inside the app-owned cache instead of resurrecting an
            // invalid active reference or hiding the orphan.
            try await recordOrphanDeletion(path: target, blobHash: plan.blobHash, error: error)
        }
    }

    /// Replays only previously journaled, canonical cache filenames.  Entries
    /// stay durable when deletion still fails; callers can surface that state
    /// instead of silently losing the cleanup obligation.
    func retryOrphanedBlobDeletions() async {
        let entries = await store.orphanedBlobDeletions()
        for var entry in entries.prefix(128) {
            do {
                let url = try V4OwnedPath.canonicalFile(named: entry.filename, root: cacheDirectory)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    try await store.removeOrphanedBlobDeletion(blobHash: entry.blobHash)
                    continue
                }
                // A filename is never sufficient authorization to delete a
                // cache entry.  Recheck both immutable content hash and byte
                // count after relaunch, so a replaced/symlink-adjacent file
                // cannot be deleted merely because it reused an old name.
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard data.count == entry.byteCount, StableHash.sha256(data) == entry.blobHash else { throw FullTextServiceError.invalidSource }
                try FileManager.default.removeItem(at: url)
                try await store.removeOrphanedBlobDeletion(blobHash: entry.blobHash)
            } catch {
                entry.retryCount += 1
                entry.lastErrorCategory = String(reflecting: type(of: error))
                entry.updatedAt = Date()
                try? await store.saveOrphanedBlobDeletion(entry)
            }
        }
    }

    private func retireCommittedBlobs(_ plan: BlobMutationPlan) async throws {
        for filename in plan.retiredLocalFilenames {
            let url = try V4OwnedPath.canonicalFile(named: filename, root: cacheDirectory)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { try FileManager.default.removeItem(at: url) }
            catch {
                // Content-addressed names are produced only by this service.
                // Derive the exact matching hash rather than associating a
                // multi-retirement plan with its first sorted hash.
                let hash = Self.contentHash(fromCanonicalFilename: filename)
                try await recordOrphanDeletion(path: url, blobHash: hash, error: error)
            }
        }
    }

    /// Typed inventory persistence is a separate V10 repository transaction.
    /// Publish the document as incomplete first, then make it complete only
    /// after the inventory and all item rows have committed. A crash between
    /// those saves therefore leaves a recoverable, explicitly incomplete
    /// document rather than a false complete receipt.
    private func commit(extraction: FullTextExtraction) async throws -> FullTextDocument {
        guard let inventory = extraction.formulaInventory,
              let inventoryStore = store as? any FormulaInventoryStoring else {
            let plan = try await store.saveFullTextAndPlan(document: extraction.document,
                chunks: extraction.chunks, anchors: extraction.anchors)
            try await retireCommittedBlobs(plan)
            return extraction.document
        }

        var stagedDocument = extraction.document
        if inventory.isComplete {
            stagedDocument.numberedEquationIndexComplete = false
            stagedDocument.numberedEquationInventoryHash = nil
            stagedDocument.numberedEquationIndexFailure = "typed_inventory_persistence_pending"
        }
        let stagedPlan = try await store.saveFullTextAndPlan(document: stagedDocument,
            chunks: extraction.chunks, anchors: extraction.anchors)
        try await retireCommittedBlobs(stagedPlan)

        do {
            try await inventoryStore.saveFormulaInventory(inventory, paperID: extraction.document.paperID)
        } catch {
            stagedDocument.numberedEquationIndexComplete = false
            stagedDocument.numberedEquationInventoryHash = nil
            stagedDocument.numberedEquationIndexFailure =
                "typed_inventory_persistence_failure:\(String(reflecting: type(of: error)))"
            if let repairPlan = try? await store.saveFullTextAndPlan(document: stagedDocument,
                    chunks: extraction.chunks, anchors: extraction.anchors) {
                try? await retireCommittedBlobs(repairPlan)
            }
            return stagedDocument
        }

        guard inventory.isComplete else { return extraction.document }
        let finalizedPlan = try await store.saveFullTextAndPlan(document: extraction.document,
            chunks: extraction.chunks, anchors: extraction.anchors)
        try await retireCommittedBlobs(finalizedPlan)
        return extraction.document
    }

    private func recordOrphanDeletion(path: URL, blobHash: String?, error: Error) async throws {
        guard let blobHash, Self.contentHash(fromCanonicalFilename: path.lastPathComponent) == blobHash else {
            throw FullTextServiceError.invalidSource
        }
        let data = try Data(contentsOf: path, options: [.mappedIfSafe])
        guard StableHash.sha256(data) == blobHash else { throw FullTextServiceError.invalidSource }
        let now = Date()
        try await store.saveOrphanedBlobDeletion(OrphanedBlobDeletion(blobHash: blobHash, filename: path.lastPathComponent,
                                                                       byteCount: data.count, retryCount: 0,
                                                                       lastErrorCategory: String(reflecting: type(of: error)),
                                                                       createdAt: now, updatedAt: now))
    }

    private static func contentHash(fromCanonicalFilename filename: String) -> String? {
        guard filename.hasSuffix(".pdf") || filename.hasSuffix(".html") else { return nil }
        let suffixLength = filename.hasSuffix(".pdf") ? 4 : 5
        let candidate = String(filename.dropLast(suffixLength))
        guard candidate.count == 64,
              candidate.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else { return nil }
        return candidate
    }

    func extract(paperID: Int, sourceURL: URL, sourceKind: FullTextSourceKind, localURL: URL, hash: String, byteCount: Int) throws -> FullTextExtraction {
        guard let pdf = PDFDocument(url: localURL) else { throw FullTextServiceError.unableToOpenPDF }
        var chunks: [EvidenceChunk] = []
        var anchors: [EvidenceAnchor] = []
        for pageIndex in 0..<pdf.pageCount {
            guard let text = pdf.page(at: pageIndex)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            for (chunkIndex, fragment) in Self.chunkRanges(text).enumerated() {
                let textChunk = fragment.text
                let quoteHash = StableHash.sha256(textChunk)
                let identifier = V3EvidenceIdentity.chunkID(paperID: paperID, documentHash: hash,
                                                           page: pageIndex + 1, ordinal: chunkIndex + 1, quoteHash: quoteHash)
                let chunk = EvidenceChunk(id: identifier, paperID: paperID, documentHash: hash, page: pageIndex + 1,
                                          section: Self.guessSection(in: text), characterRangeStart: fragment.start,
                                          characterRangeEnd: fragment.end, text: textChunk, textHash: quoteHash)
                chunks.append(chunk)
                anchors.append(EvidenceAnchor(id: identifier, paperID: paperID, sourceKind: .pdf, page: pageIndex + 1,
                                              section: chunk.section, quote: textChunk, quoteHash: chunk.textHash, figureKey: nil))
            }
        }
        guard !chunks.isEmpty else { throw FullTextServiceError.noText }
        let document = FullTextDocument(paperID: paperID, sourceURL: sourceURL, sourceKind: sourceKind, sha256: hash,
                                        byteCount: byteCount, localFilename: localURL.lastPathComponent, pageCount: pdf.pageCount,
                                        extractionState: .extracted, downloadedAt: Date(), lastErrorCategory: nil)
        return (document, chunks, anchors, nil)
    }

    /// ar5iv exposes the TeX source as semantic HTML/MathML. Preserve the
    /// source TeX annotation in each bounded text chunk and additionally make
    /// one independent, hash-bound chunk for every structurally labelled
    /// display equation. The latter is the complete coverage inventory; it is
    /// deliberately independent of title relevance ranking.
    private func extractHTML(paperID: Int, sourceURL: URL, sourceKind: FullTextSourceKind, localURL: URL, hash: String, byteCount: Int) throws -> FullTextExtraction {
        guard let data = try? Data(contentsOf: localURL),
              let html = String(data: data, encoding: .utf8) else { throw FullTextServiceError.noText }
        let text = Self.plainTextFromArxivHTML(html)
        guard !text.isEmpty else { throw FullTextServiceError.noText }
        // The inventory identity must follow the bytes that were actually
        // downloaded and hash-verified above. A constant such as
        // "local-html" would let two different documents reuse equation IDs.
        let numberedFormulaExtraction = Self.numberedEquations(from: html, documentHash: hash)
        let numberedFormulas = numberedFormulaExtraction.formulas
        var chunks: [EvidenceChunk] = []
        var anchors: [EvidenceAnchor] = []
        for (chunkIndex, fragment) in Self.chunkRanges(text).enumerated() {
            let quoteHash = StableHash.sha256(fragment.text)
            let identifier = V3EvidenceIdentity.chunkID(paperID: paperID, documentHash: hash,
                                                         page: 1, ordinal: chunkIndex + 1, quoteHash: quoteHash)
            let chunk = EvidenceChunk(id: identifier, paperID: paperID, documentHash: hash, page: 1,
                                      section: Self.guessSection(in: fragment.text), characterRangeStart: fragment.start,
                                      characterRangeEnd: fragment.end, text: fragment.text, textHash: quoteHash)
            chunks.append(chunk)
            // EvidenceSourceKind.pdf is the existing full-text anchor contract;
            // page is nil here because HTML has sections, not PDF coordinates.
            anchors.append(EvidenceAnchor(id: identifier, paperID: paperID, sourceKind: .pdf, page: nil,
                                          section: chunk.section, quote: fragment.text, quoteHash: quoteHash, figureKey: nil))
        }
        for formula in numberedFormulas {
            // Preserve source TeX as a distinct full-text quote. The display
            // delimiters make this exact anchor legible in the local reader;
            // `equationTeX` itself stays delimiter-free for the schema.
            let quote = "编号公式 \(formula.label)\n$$\(formula.tex)$$"
            let quoteHash = StableHash.sha256(quote)
            let identifier = "ar5iv-equation:\(paperID):\(hash):q\(formula.ordinal):\(quoteHash)"
            let chunk = EvidenceChunk(
                id: identifier, paperID: paperID, documentHash: hash, page: 1,
                section: formula.section, characterRangeStart: formula.ordinal,
                characterRangeEnd: formula.ordinal + quote.unicodeScalars.count,
                text: quote, textHash: quoteHash,
                equationID: "ar5iv:\(hash):\(formula.ordinal)", equationLabel: formula.label,
                equationTeX: formula.tex, equationOrdinal: formula.ordinal
            )
            chunks.append(chunk)
            // EvidenceSourceKind.pdf is the existing full-text anchor contract;
            // page remains nil because ar5iv HTML has no PDF coordinate.
            anchors.append(EvidenceAnchor(id: identifier, paperID: paperID, sourceKind: .pdf, page: nil,
                                          section: formula.section, quote: quote, quoteHash: quoteHash, figureKey: nil))
        }
        guard !chunks.isEmpty else { throw FullTextServiceError.noText }
        let document = FullTextDocument(paperID: paperID, sourceURL: sourceURL, sourceKind: sourceKind, sha256: hash,
                                        byteCount: byteCount, localFilename: localURL.lastPathComponent, pageCount: nil,
                                        extractionState: .extracted, downloadedAt: Date(), lastErrorCategory: nil,
                                        numberedEquationIndexVersion: Self.numberedEquationIndexVersion,
                                        numberedEquationCount: numberedFormulas.count,
                                        numberedEquationIndexComplete: numberedFormulaExtraction.isComplete,
                                        numberedEquationIndexFailure: numberedFormulaExtraction.failure,
                                        numberedEquationInventoryHash: numberedFormulaExtraction.inventoryHash)
        return (document, chunks, anchors, numberedFormulaExtraction.inventory)
    }

    private struct NumberedHTMLFormula: Sendable {
        let label: String
        let tex: String
        let ordinal: Int
        let section: String?
    }

    private struct NumberedHTMLFormulaExtraction: Sendable {
        let inventory: FormulaInventory
        let formulas: [NumberedHTMLFormula]
        let labelledEquationCount: Int
        let explicitFailure: String?
        let inventoryHash: String

        var isComplete: Bool { formulas.count == labelledEquationCount }

        var failure: String? {
            if let explicitFailure { return explicitFailure }
            guard !isComplete else { return nil }
            return "ar5iv HTML 中检测到 \(labelledEquationCount) 条带编号公式，但仅能为 \(formulas.count) 条建立 TeX/evidence 记录；不会生成部分覆盖结果。"
        }
    }

    /// ar5iv's LaTeXML display equations use a `ltx_equation` container and a
    /// `ltx_tag_equation` label. This is a deliberately narrow structural
    /// extractor, not a heuristic search for parenthesized text: each emitted
    /// result has both a visible label containing a numeral and a semantic TeX
    /// annotation/alttext source.
    private static func numberedEquations(from html: String, documentHash: String) -> NumberedHTMLFormulaExtraction {
        let inventory = FormulaInventoryParser.parse(html: html, documentHash: documentHash)
        let formulas = inventory.items.map { item in
            NumberedHTMLFormula(label: item.label, tex: item.sourceTeX, ordinal: item.ordinal,
                                section: nil)
        }
        return NumberedHTMLFormulaExtraction(inventory: inventory,
                                             formulas: formulas,
                                             labelledEquationCount: inventory.labelledEquationCount,
                                             explicitFailure: inventory.failureReason,
                                             inventoryHash: inventory.inventoryHash)
    }

    private static func firstCapture(in value: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let captured = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[captured])
    }

    private static func htmlSection(before index: String.Index, in html: String) -> String? {
        let prefix = String(html[..<index])
        let pattern = #"(?is)<h[1-6]\b[^>]*>(.*?)</h[1-6]>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(prefix.startIndex..<prefix.endIndex, in: prefix)
        guard let match = regex.matches(in: prefix, range: range).last,
              let captured = Range(match.range(at: 1), in: prefix) else { return nil }
        let section = htmlText(String(prefix[captured]))
        guard !section.isEmpty else { return nil }
        return String(section.unicodeScalars.prefix(240))
    }

    private static func htmlText(_ html: String) -> String {
        var value = replacing(html, pattern: #"(?is)<[^>]+>"#, with: " ")
        value = decodeHTMLEntities(value)
        value = value.replacingOccurrences(of: #"[ \t\r\n\f\v]+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func plainTextFromArxivHTML(_ html: String) -> String {
        var value = html
        value = replacing(value, pattern: #"(?is)<(script|style|noscript|svg)\b[^>]*>.*?</\1>"#, with: " ")
        // Keep the TeX annotation as real delimiters in the extracted quote.
        // The local renderer can then show native math glyphs while the
        // selectable source remains available through its raw disclosure;
        // a literal `[formula: …]` marker would leak transport syntax into
        // evidence and would not render as mathematics.
        value = replacingFormula(value, pattern: #"(?is)<math\b[^>]*>.*?<annotation[^>]*encoding=[\"']application/x-tex[\"'][^>]*>(.*?)</annotation>.*?</math>"#, display: false)
        value = replacingFormula(value, pattern: #"(?is)<math\b[^>]*alttext=[\"']([^\"']+)[\"'][^>]*>.*?</math>"#, display: false)
        value = replacing(value, pattern: #"(?is)<br\s*/?>"#, with: "\n")
        value = replacing(value, pattern: #"(?is)</(p|div|section|article|h[1-6]|li|tr|figcaption|table)>"#, with: "\n")
        value = replacing(value, pattern: #"(?is)<[^>]+>"#, with: " ")
        value = decodeHTMLEntities(value)
        value = value.replacingOccurrences(of: #"[ \t\r\f\v]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #" *\n+ *"#, with: "\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")
        ]
        return entities.reduce(value) { partial, mapping in
            partial.replacingOccurrences(of: mapping.0, with: mapping.1)
        }
    }

    private static func replacing(_ value: String, pattern: String, with replacement: String? = nil, withTemplate template: String? = nil) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        if let template { return regex.stringByReplacingMatches(in: value, range: range, withTemplate: template) }
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement ?? "")
    }

    private static func replacingFormula(_ value: String, pattern: String, display: Bool) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.matches(in: value, range: fullRange)
        guard !matches.isEmpty else { return value }
        var output = ""
        var cursor = value.startIndex
        for match in matches {
            guard let whole = Range(match.range, in: value),
                  let capture = Range(match.range(at: 1), in: value) else { continue }
            output += value[cursor..<whole.lowerBound]
            let payload = String(value[capture]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !payload.isEmpty { output += display ? "$$\(payload)$$" : "$\(payload)$" }
            cursor = whole.upperBound
        }
        output += value[cursor..<value.endIndex]
        return output
    }

    static func chunk(_ text: String) -> [String] {
        chunkRanges(text).map(\.text)
    }

    static func chunkRanges(_ text: String) -> [(start: Int, end: Int, text: String)] {
        var output: [(start: Int, end: Int, text: String)] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let limit = text.index(cursor, offsetBy: maximumChunkScalars, limitedBy: text.endIndex) ?? text.endIndex
            var rawEnd = limit
            if limit < text.endIndex,
               let boundary = text[cursor..<limit].lastIndex(where: { $0 == "\n" || $0 == "." || $0 == " " }),
               boundary > cursor {
                rawEnd = text.index(after: boundary)
            }
            var start = cursor
            var end = rawEnd
            while start < end, text[start].isWhitespace { start = text.index(after: start) }
            while end > start {
                let beforeEnd = text.index(before: end)
                guard text[beforeEnd].isWhitespace else { break }
                end = beforeEnd
            }
            if start < end {
                output.append((
                    start: text.distance(from: text.startIndex, to: start),
                    end: text.distance(from: text.startIndex, to: end),
                    text: String(text[start..<end])
                ))
            }
            cursor = rawEnd
        }
        return output
    }

    private static func guessSection(in text: String) -> String? {
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return firstLine.count <= 120 ? firstLine : nil
    }

    private static func makeSafeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: PDFRedirectDelegate(), delegateQueue: nil)
    }

    private static func isAllowedFinalURL(_ finalURL: URL?, sourceURL: URL, sourceKind: FullTextSourceKind) -> Bool {
        guard let finalURL,
              finalURL.scheme?.lowercased() == "https",
              finalURL.port == nil || finalURL.port == 443,
              finalURL.user == nil, finalURL.password == nil, finalURL.query == nil, finalURL.fragment == nil,
              let finalHost = finalURL.host?.lowercased(), let sourceHost = sourceURL.host?.lowercased() else { return false }
        let publicAllowlist = Set(["inspirehep.net", "arxiv.org", "export.arxiv.org", "cds.cern.ch", "ar5iv.labs.arxiv.org", "fixture.invalid"])
        guard publicAllowlist.contains(sourceHost), publicAllowlist.contains(finalHost) else { return false }
        if sourceKind == .arxivHTML {
            guard sourceHost == "ar5iv.labs.arxiv.org", finalHost == "ar5iv.labs.arxiv.org" else { return false }
        }
        return isAllowedPath(finalURL.path, sourceKind: sourceKind)
    }

    private static func isAllowedSourceURL(_ url: URL, sourceKind: FullTextSourceKind) -> Bool {
        let allowedHosts = Set(["inspirehep.net", "arxiv.org", "export.arxiv.org", "cds.cern.ch", "ar5iv.labs.arxiv.org", "fixture.invalid"])
        guard url.scheme?.lowercased() == "https", (url.port == nil || url.port == 443),
            url.host.map({ allowedHosts.contains($0.lowercased()) }) == true &&
            url.user == nil && url.password == nil && url.query == nil && url.fragment == nil,
            isAllowedPath(url.path, sourceKind: sourceKind) else { return false }
        if sourceKind == .arxivHTML { return url.host?.lowercased() == "ar5iv.labs.arxiv.org" }
        return true
    }

    fileprivate static func isPDFPath(_ path: String) -> Bool {
        let normalized = path.lowercased()
        return normalized.hasSuffix(".pdf") || normalized.contains("/files/") || normalized.contains("/pdf/")
    }

    private static func isAllowedPath(_ path: String, sourceKind: FullTextSourceKind) -> Bool {
        if sourceKind == .arxivHTML { return path.lowercased().contains("/html/") }
        return isPDFPath(path)
    }

    private static func acceptHeader(for sourceKind: FullTextSourceKind) -> String {
        sourceKind == .arxivHTML ? "text/html" : "application/pdf"
    }

    private static func expectedMIME(for sourceKind: FullTextSourceKind) -> String {
        sourceKind == .arxivHTML ? "text/html" : "application/pdf"
    }

    private static var usesFixtureLaunch: Bool { AppLaunchConfiguration.usesFixtureDependencies }
}

private final class PDFRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              ((task.originalRequest?.url?.host?.lowercased() == "ar5iv.labs.arxiv.org") ? url.path.lowercased().contains("/html/") : FullTextService.isPDFPath(url.path)),
              let originalHost = task.originalRequest?.url?.host?.lowercased(),
              let redirectHost = url.host?.lowercased(),
              ["inspirehep.net", "arxiv.org", "export.arxiv.org", "cds.cern.ch", "ar5iv.labs.arxiv.org"].contains(originalHost),
              ["inspirehep.net", "arxiv.org", "export.arxiv.org", "cds.cern.ch", "ar5iv.labs.arxiv.org"].contains(redirectHost) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
