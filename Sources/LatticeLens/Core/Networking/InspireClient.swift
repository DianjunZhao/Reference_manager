import Foundation

protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Endpoint callers provide a hard byte bound.  Test transports inherit a
    /// deterministic checked implementation; the URLSession transport below
    /// overrides it with incremental `bytes(for:)` collection so an oversized
    /// response is rejected before an unbounded body is materialized.
    func boundedData(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse)
}

extension HTTPTransport {
    func boundedData(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard data.count <= maximumBytes else { throw LatticeLensError.invalidResponse }
        return (data, response)
    }
}

/// A validator-bearing response is retained only in process memory.  It lets
/// a `304 Not Modified` response reuse bytes that have already passed the
/// endpoint and size checks, without treating an empty 304 body as JSON.
private struct ConditionalGETCacheEntry: Sendable {
    let data: Data
    let eTag: String?
    let lastModified: String?
    let bodyExpiresAt: Date
}

private actor ConditionalGETCache {
    private var entries: [URL: ConditionalGETCacheEntry] = [:]

    func entry(for url: URL) -> ConditionalGETCacheEntry? { entries[url] }

    func store(_ entry: ConditionalGETCacheEntry, for url: URL) {
        entries[url] = entry
    }

    func freshUnvalidatedBody(for url: URL, now: Date = Date()) -> Data? {
        guard let entry = entries[url],
              entry.eTag == nil, entry.lastModified == nil,
              entry.bodyExpiresAt > now else { return nil }
        return entry.data
    }
}

struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    init(session: URLSession? = nil, origin: URL = InspireClient.defaultOrigin) {
        self.session = session ?? Self.makeSafeSession(origin: origin)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LatticeLensError.invalidResponse }
        return (data, http)
    }

    func boundedData(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LatticeLensError.invalidResponse }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 1_048_576))
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= maximumBytes else { throw LatticeLensError.invalidResponse }
        }
        return (data, http)
    }

    private static func makeSafeSession(origin: URL) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration,
                          delegate: InspireRedirectDelegate(origin: origin), delegateQueue: nil)
    }
}

private final class InspireRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL
    init(origin: URL) { self.origin = origin }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let target = request.url,
              target.scheme?.lowercased() == origin.scheme?.lowercased(),
              target.host?.lowercased() == origin.host?.lowercased(),
              target.user == nil, target.password == nil,
              target.fragment == nil,
              InspireRedirectDelegate.effectivePort(target) == InspireRedirectDelegate.effectivePort(origin),
              target.path.hasPrefix("/api/") else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    static func effectivePort(_ url: URL) -> Int {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "http" ? 80 : 443
    }
}

struct InspireClient: Sendable {
    static let defaultOrigin = URL(string: "https://inspirehep.net")!
    static let defaultMaximumResponseBytes = 8 * 1024 * 1024
    static let defaultMaximumGETAttempts = 3
    private let transport: any HTTPTransport
    private let origin: URL
    private let decoder: JSONDecoder
    private let maximumResponseBytes: Int
    private let maximumGETAttempts: Int
    private let retrySleeper: @Sendable (Duration) async throws -> Void
    private let conditionalCache: ConditionalGETCache
    /// A short process-local reuse window prevents repeated view-driven
    /// refreshes from blocking the main timeline when INSPIRE omits validators.
    /// Validator-bearing responses still use conditional GET on every call.
    private let unvalidatedBodyTTL: TimeInterval

    /// The list endpoint otherwise returns very large embedded payloads.
    /// These are the only metadata fields required by the paper mapper, so an
    /// explicit selection keeps first paint responsive without changing the
    /// detail endpoint used after a paper is selected.
    private static let literatureFields = [
        "titles", "abstracts", "arxiv_eprints", "citation_count", "preprint_date",
        "earliest_date", "dois", "publication_info", "imprints", "figures", "authors",
        "documents"
    ].joined(separator: ",")

    /// H-index fallback only needs citation counts.  Reusing the full paper
    /// metadata projection here can pull megabytes of figures/documents for a
    /// highly cited author and turn an otherwise recoverable facet 400 into a
    /// timeout/oversized response.  Keep this request deliberately narrow so
    /// every author remains verifiable and the queue can make progress.
    private static let hIndexLiteratureFields = "citation_count"

    init(
        transport: any HTTPTransport = URLSessionTransport(),
        origin: URL = InspireClient.defaultOrigin,
        maximumResponseBytes: Int = InspireClient.defaultMaximumResponseBytes,
        maximumGETAttempts: Int = InspireClient.defaultMaximumGETAttempts,
        retrySleeper: @escaping @Sendable (Duration) async throws -> Void = { duration in try await Task.sleep(for: duration) },
        unvalidatedBodyTTL: TimeInterval = 15
    ) {
        self.transport = transport
        self.origin = origin
        self.decoder = JSONDecoder()
        self.maximumResponseBytes = max(1, maximumResponseBytes)
        self.maximumGETAttempts = max(1, maximumGETAttempts)
        self.retrySleeper = retrySleeper
        self.conditionalCache = ConditionalGETCache()
        self.unvalidatedBodyTTL = max(0, unvalidatedBodyTTL)
    }

    func selfAuthor() async throws -> Author {
        let url = origin.appending(path: "/api/authors/\(ProductContract.selfAuthorRecid)")
        let data = try await get(url)
        let hit = try decoder.decode(InspireAuthorHit.self, from: data)
        return try InspireMapper.author(from: hit)
    }

    func authorCandidatesPage(nextURL: URL? = nil) async throws -> (authors: [Author], nextURL: URL?, total: Int) {
        let url: URL
        if let nextURL {
            url = try validatedNextURL(nextURL, expectedPath: "/api/authors")
        } else {
            url = try authorCandidateURL(partition: 0, page: 1)
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let pageNumber = Int(components?.queryItems?.first(where: { $0.name == "page" })?.value ?? "1") ?? 1
        let queryValue = components?.queryItems?.first(where: { $0.name == "q" })?.value
        // URLComponents intentionally preserves `+` in query values and a
        // checkpoint copied through a proxy may contain a second percent-
        // encoding pass.  Decode the value before deciding whether it belongs
        // to a control-number partition; otherwise a valid page-41 repair can
        // be misclassified as an unpartitioned query and the next request is
        // sent to INSPIRE unchanged (HTTP 400).
        let decodedQuery = decodeAuthorQuery(queryValue)
        let isPartitioned = decodedQuery.localizedCaseInsensitiveContains("control_number")
        let partition = authorCandidatePartition(for: decodedQuery)

        // A checkpoint written by an older build may already contain the
        // server's page-41 URL.  INSPIRE rejects that URL with HTTP 400 before
        // returning a JSON page, so repair it locally instead of sending the
        // known-invalid request.  The current writer normally prevents this
        // state; this guard is for interrupted upgrades and hand-copied
        // checkpoints.
        if pageNumber > 40 {
            if isPartitioned, partition + 1 < Self.authorCandidatePartitions.count {
                return ([], try authorCandidateURL(partition: partition + 1, page: 1), 0)
            }
            if !isPartitioned {
                return ([], try authorCandidateURL(partition: 0, page: 1), 0)
            }
            return ([], nil, 0)
        }
        let responseData: Data
        do {
            responseData = try await getAuthorCandidateData(url)
        } catch let error as LatticeLensError where error == .httpStatus(400) {
            // A persisted checkpoint can have a semantically correct query
            // but stale/foreign escaping.  Retry with a small, bounded set of
            // canonical forms before declaring the page unavailable.  The
            // lower page sizes are accepted by older INSPIRE deployments and
            // also reduce the chance that a transient proxy limit is reported
            // as a deterministic 400.  Never silently skip a partition: the
            // caller must retain its previous generation and expose a retry
            // state rather than publishing an index with missing hep-th rows.
            // Every recovery request must remain inside the same disjoint
            // control-number partition.  Falling back to the unpartitioned
            // union here looks attractive, but its `links.next` would then
            // lose the range clause; the next iteration would walk the
            // global page-1…40 window and silently omit later hep-th rows.
            // Keep the partition identity in every variant and let the
            // caller persist a paused checkpoint if the service still
            // rejects all canonical forms.
            let variants = [
                try authorCandidateURL(partition: partition, page: pageNumber, size: 100, grouped: true),
                try authorCandidateURL(partition: partition, page: pageNumber, size: 250, grouped: false),
                try authorCandidateURL(partition: partition, page: pageNumber, size: 100, grouped: false)
            ]
            var recovered: Data?
            var lastError: Error = error
            for candidate in variants where candidate != url {
                do {
                    recovered = try await getAuthorCandidateData(candidate)
                    break
                } catch {
                    lastError = error
                }
            }
            guard let recovered else { throw lastError }
            responseData = recovered
        }
        let responsePage = try decoder.decode(InspireSearchPage<InspireAuthorHit>.self, from: responseData)
        let authors = try responsePage.hits.hits.map(InspireMapper.author)

        // INSPIRE rejects offsets beyond its 10,000-result window.  The
        // hep-lat/hep-th union currently contains more than that, so never
        // follow the server's page-41 link.  Advance to a disjoint
        // control-number range instead; each range remains below the API
        // window and the durable checkpoint still stores an ordinary trusted
        // INSPIRE URL.
        // Prefer the explicit `size` sent in the request.  A few fixture and
        // older proxy responses omit it while still returning a valid `next`
        // link; in that case the observed hit count is the only bounded page
        // size available.  Using a hard-coded 250 for such a response makes a
        // short final page look incomplete and can follow the same partition
        // until the global safety limit (the production symptom was a blank
        // refresh ending in "分页超过安全上限").
        let requestedPageSize = components?.queryItems?
            .first(where: { $0.name == "size" })?.value.flatMap(Int.init)
        let pageSize = max(1, requestedPageSize ?? responsePage.hits.hits.count)
        // Treat the total as authoritative when the server's advertised next
        // URL carries the same explicit page size (the shape emitted by the
        // live INSPIRE API).  Tiny contract fixtures and older mirrors often
        // omit `size` from their next URL; retain their link in that case so a
        // valid page-1 -> page-2 response is not discarded merely because its
        // synthetic total is smaller than the product's default page size.
        let advertisedNextURL = responsePage.links?.next.flatMap { URL(string: $0) }
        let advertisedNextComponents = advertisedNextURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let advertisedNextSize = advertisedNextComponents?.queryItems?
            .first(where: { $0.name == "size" })?.value.flatMap(Int.init)
        let hasMoreByTotal: Bool
        if let requestedPageSize, let advertisedNextSize, requestedPageSize == advertisedNextSize {
            hasMoreByTotal = responsePage.hits.total > pageNumber * pageSize
        } else {
            hasMoreByTotal = responsePage.links?.next != nil
        }
        let exhaustedWindow = pageNumber >= 40 && hasMoreByTotal
        let advertisedNextPage = advertisedNextComponents
            .flatMap { Int($0.queryItems?.first(where: { $0.name == "page" })?.value ?? "") }
        let nextBeyondWindow = advertisedNextPage.map { $0 > 40 } ?? false
        let serverNext = (!hasMoreByTotal || exhaustedWindow || nextBeyondWindow) ? nil :
            try trustedNextURL(responsePage.links?.next, expectedPath: "/api/authors")
        let next: URL?
        if let serverNext {
            next = serverNext
        } else if isPartitioned && partition + 1 < Self.authorCandidatePartitions.count {
            next = try authorCandidateURL(partition: partition + 1, page: 1)
        } else {
            next = nil
        }
        return (authors, next, responsePage.hits.total)
    }

    /// Disjoint INSPIRE author control-number ranges.  The largest range is
    /// intentionally below the service's 10,000-result offset ceiling; the
    /// final range is kept explicit so a future increase in record IDs cannot
    /// silently reintroduce an unbounded page walk.
    private static let authorCandidatePartitions: [(Int, Int)] = [
        (0, 999_999), (1_000_000, 1_249_999), (1_250_000, 1_499_999),
        (1_500_000, 1_749_999), (1_750_000, 1_999_999),
        (2_000_000, 2_999_999), (3_000_000, 3_999_999)
    ]

    private func authorCandidateURL(partition: Int, page: Int, size: Int = 250, grouped: Bool = true) throws -> URL {
        guard Self.authorCandidatePartitions.indices.contains(partition) else { throw LatticeLensError.paginationLimitExceeded }
        let range = Self.authorCandidatePartitions[partition]
        let categoryQuery = grouped
            ? "(arxiv_categories:hep-lat OR arxiv_categories:hep-th)"
            : "(arxiv_categories:hep-lat AND control_number:[\(range.0) TO \(range.1)]) OR (arxiv_categories:hep-th AND control_number:[\(range.0) TO \(range.1)])"
        let query = grouped
            ? "\(categoryQuery) AND control_number:[\(range.0) TO \(range.1)]"
            : categoryQuery
        return try makeURL(path: "/api/authors", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "size", value: String(max(1, min(size, 250)))),
            URLQueryItem(name: "page", value: String(max(1, page)))
        ])
    }

    /// A 400 from the author endpoint is usually a stale pagination URL, but
    /// it can also be a short-lived proxy/service rejection.  Give the same
    /// canonical request one finite retry without broadening the global GET
    /// retry policy (where 400 remains a deterministic client error).
    private func getAuthorCandidateData(_ url: URL) async throws -> Data {
        do {
            return try await get(url)
        } catch let error as LatticeLensError where error == .httpStatus(400) {
            try await retrySleeper(.milliseconds(500))
            return try await get(url)
        }
    }

    private func authorCandidatePartition(for query: String?) -> Int {
        guard let query else { return 0 }
        // URLComponents keeps `+` as a literal plus in query-item values
        // (rather than decoding it to a space).  INSPIRE's pagination links
        // commonly mix `+` and `%20` for the spaces around `OR`, `AND`, and
        // `TO`.  Decode once, then canonicalize all whitespace before matching
        // the durable control-number range.  This also handles a checkpoint
        // copied from a proxy that percent-encoded the query value twice.
        let normalizedQuery = decodeAuthorQuery(query)
            .split { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
            .joined(separator: " ")
        for (index, range) in Self.authorCandidatePartitions.enumerated() {
            if normalizedQuery.contains("control_number:[\(range.0) TO \(range.1)]") {
                return index
            }
        }
        // A pre-partition checkpoint has no control-number clause.  Treat it
        // as the first partition; AuthorIndexService invalidates such a
        // checkpoint before calling us, so this is only a defensive bound.
        return 0
    }

    /// Bounded decoding for persisted INSPIRE query values.  Four passes are
    /// enough for URLComponents plus one or two proxy encoders, while keeping
    /// the interpretation of an untrusted checkpoint finite and auditable.
    private func decodeAuthorQuery(_ query: String?) -> String {
        guard var value = query else { return "" }
        for _ in 0..<4 {
            guard let next = value.removingPercentEncoding, next != value else { break }
            value = next
        }
        return value.replacingOccurrences(of: "+", with: " ")
    }

    func hIndex(for authorRecid: Int, now: Date = Date()) async throws -> HIndexSnapshot {
        let query = "authors.recid:\(authorRecid)"
        // The production INSPIRE deployment currently distinguishes the
        // hyphenated facet selector from the JSON aggregation key: requesting
        // `citation-summary` yields `aggregations.citation_summary.h-index`,
        // while requesting `citation_summary` may return HTTP 200 with only
        // the default facets (no h-index at all).  Treat the latter as a
        // schema miss and try it only as a bounded compatibility variant for
        // older mirrors; otherwise every author falls into the expensive
        // literature crawl and a large refresh appears blank.
        let facetNames = ["citation-summary", "citation_summary"]
        var lastError: Error?
        for facetName in facetNames {
            let url = try makeURL(path: "/api/literature/facets", query: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "facet_name", value: facetName)
            ])
            do {
                let data = try await get(url)
                let payload = try decoder.decode(JSONValue.self, from: data)
                do {
                    return try InspireMapper.hIndex(from: payload, authorRecid: authorRecid, query: query, now: now,
                                                    rawSchemaHash: StableHash.sha256(data))
                } catch let error as LatticeLensError where error == .malformedPayload {
                    lastError = error
                    continue
                }
            } catch let error as LatticeLensError where error == .endpointChanged || error == .malformedPayload {
                lastError = error
                continue
            } catch let error as LatticeLensError where error == .httpStatus(400) {
                // A deterministic HTTP 400 is the signal used by the
                // bounded literature fallback.  Do not consume the next
                // scripted/live request as a compatibility facet: older
                // deployments may reject the facet endpoint while their
                // literature endpoint remains available for local h-index
                // computation.
                throw error
            }
        }
        throw lastError ?? LatticeLensError.malformedPayload
    }

    /// Fallback when the live citation-summary facet changes or is unavailable.
    /// It deliberately records a different source rather than impersonating the
    /// INSPIRE official summary.  INSPIRE rejects offsets beyond its 10,000-row
    /// window (page 41 at size 250) with HTTP 400.  Keep the fallback bounded to
    /// the first 10,000 most-cited rows: that is sufficient for every h-index
    /// up to 10,000 and, crucially, never turns one author into a fatal index
    /// refresh when a large collaboration record crosses the service window.
    func locallyComputedHIndex(for authorRecid: Int, now: Date = Date()) async throws -> HIndexSnapshot {
        var nextURL: URL?
        var counts: [Int] = []
        var totalPapers = 0
        var pages = 0
        let pageSize = 250
        let maximumPages = 40
        repeat {
            try Task.checkCancellation()
            guard pages < maximumPages else { break }
            let url = try nextURL.map { try validatedNextURL($0, expectedPath: "/api/literature") } ?? makeURL(path: "/api/literature", query: [
                URLQueryItem(name: "q", value: "authors.recid:\(authorRecid)"),
                URLQueryItem(name: "sort", value: "mostcited"),
                URLQueryItem(name: "size", value: String(pageSize)),
                URLQueryItem(name: "fields", value: Self.hIndexLiteratureFields)
            ])
            let data = try await get(url)
            let page = try decoder.decode(InspireSearchPage<InspireLiteratureHit>.self, from: data)
            totalPapers += page.hits.hits.count
            counts.append(contentsOf: page.hits.hits.compactMap(\.metadata.citationCount).filter { $0 >= 0 })
            pages += 1
            guard pages < maximumPages, page.hits.hits.count == pageSize else {
                nextURL = nil
                continue
            }
            let candidateNext = try trustedNextURL(page.links?.next, expectedPath: "/api/literature")
            if let candidateNext,
               let nextPage = URLComponents(url: candidateNext, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "page" })?.value.flatMap(Int.init),
               nextPage > maximumPages {
                // Do not send the known-invalid page-41 request.
                nextURL = nil
            } else {
                nextURL = candidateNext
            }
        } while nextURL != nil
        let sorted = counts.sorted(by: >)
        let h = sorted.enumerated().reduce(0) { current, item in item.element >= item.offset + 1 ? item.offset + 1 : current }
        return HIndexSnapshot(authorRecid: authorRecid, all: h, published: nil, excludesSelfCitations: false,
                              source: "locally-computed", query: "authors.recid:\(authorRecid) sort:mostcited",
                              fetchedAt: now, rawSchemaHash: StableHash.sha256(sorted.map(String.init).joined(separator: ",")),
                              inputPaperCount: totalPapers, missingCitationCount: totalPapers - counts.count,
                              pageCount: pages, computationFormulaVersion: "h-index-counts-v1-capped-10000")
    }

    func literaturePage(for authorRecid: Int, nextURL: URL? = nil, now: Date = Date()) async throws -> (papers: [Paper], nextURL: URL?, total: Int) {
        try await literaturePage(query: "authors.recid:\(authorRecid)", nextURL: nextURL, now: now)
    }

    /// Bounded arbitrary-query literature page used by saved Research Radar
    /// queries. The endpoint/path and pagination link are still validated by
    /// the same trusted GET contract as author literature.
    func literaturePage(query: String, nextURL: URL? = nil, now: Date = Date()) async throws -> (papers: [Paper], nextURL: URL?, total: Int) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty, normalizedQuery.unicodeScalars.count <= 1_000 else { throw LatticeLensError.malformedPayload }
        let url = try nextURL.map { try validatedNextURL($0, expectedPath: "/api/literature") } ?? makeURL(path: "/api/literature", query: [
            URLQueryItem(name: "q", value: normalizedQuery),
            URLQueryItem(name: "sort", value: "mostrecent"),
            // Live author records can contain unusually large figure/document
            // metadata.  A 100-record page for Yang, Yi-Bo exceeded both the
            // product's 8 MiB body ceiling and its 30 s request deadline in
            // real INSPIRE use.  Ten records is intentionally conservative:
            // each page is committed and surfaced immediately by PaperSync,
            // rather than leaving the user with an empty list until an entire
            // author's history finishes downloading.
                URLQueryItem(name: "size", value: "10"),
                URLQueryItem(name: "fields", value: Self.literatureFields)
            ])
        let page = try decoder.decode(InspireSearchPage<InspireLiteratureHit>.self, from: await get(url))
        return (try page.hits.hits.map { try InspireMapper.paper(from: $0, now: now) }, try trustedNextURL(page.links?.next, expectedPath: "/api/literature"), page.hits.total)
    }

    /// Fetches one current INSPIRE literature record after the user selects a
    /// locally listed paper.  Callers must merge this result by record id and
    /// retain their existing metadata if this optional enrichment fails.
    func literatureDetail(for literatureID: Int, now: Date = Date()) async throws -> Paper {
        guard literatureID > 0 else { throw LatticeLensError.malformedPayload }
        let url = origin.appending(path: "/api/literature/\(literatureID)")
        let hit = try decoder.decode(InspireLiteratureHit.self, from: await get(url))
        guard hit.id.integerValue == literatureID else { throw LatticeLensError.malformedPayload }
        return try InspireMapper.paper(from: hit, now: now)
    }

    private func get(_ url: URL) async throws -> Data {
        guard isTrustedInspireURL(url) else { throw LatticeLensError.endpointChanged }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let cached = await conditionalCache.entry(for: url)
        if unvalidatedBodyTTL > 0,
           let freshBody = await conditionalCache.freshUnvalidatedBody(for: url) {
            return freshBody
        }
        if let eTag = cached?.eTag {
            request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
        } else if let lastModified = cached?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        var lastError: Error = LatticeLensError.invalidResponse
        for attempt in 1...maximumGETAttempts {
            try Task.checkCancellation()
            do {
                let (data, response) = try await transport.boundedData(for: request, maximumBytes: maximumResponseBytes)
                if response.statusCode == 304 {
                    guard let cached else { throw LatticeLensError.invalidResponse }
                    return cached.data
                }
                guard (200..<300).contains(response.statusCode) else {
                    let error = LatticeLensError.httpStatus(response.statusCode)
                    guard attempt < maximumGETAttempts, Self.isRetryableGETStatus(response.statusCode) else { throw error }
                    lastError = error
                    try await retrySleeper(Self.retryDelay(response: response, attempt: attempt))
                    continue
                }
                await conditionalCache.store(
                    ConditionalGETCacheEntry(data: data,
                                             eTag: response.value(forHTTPHeaderField: "ETag"),
                                             lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
                                             bodyExpiresAt: Date().addingTimeInterval(unvalidatedBodyTTL)),
                    for: url
                )
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LatticeLensError {
                // Status retries are handled above. Contract, payload, and
                // endpoint failures are deterministic and must fail closed.
                throw error
            } catch {
                lastError = error
                guard attempt < maximumGETAttempts, Self.isRetryableTransportError(error) else { throw error }
                try await retrySleeper(Self.retryDelay(response: nil, attempt: attempt))
            }
        }
        throw lastError
    }

    private static func isRetryableGETStatus(_ status: Int) -> Bool {
        status == 429 || status == 502 || status == 503 || status == 504
    }

    private static func isRetryableTransportError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
             .timedOut, .dnsLookupFailed, .cannotFindHost:
            return true
        default:
            return false
        }
    }

    /// Retry-After is honored within a finite resource budget. Without an
    /// explicit server hint, use a small bounded backoff with no rate-limit
    /// assumptions beyond the observed retryable response.
    static func retryDelay(response: HTTPURLResponse?, attempt: Int, now: Date = Date()) -> Duration {
        if let raw = response?.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
           let seconds = Int(raw), seconds >= 0 {
            return .seconds(min(seconds, 30))
        }
        if let raw = response?.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
           let retryAt = parseRetryAfterHTTPDate(raw) {
            let remaining = max(0, retryAt.timeIntervalSince(now))
            return .seconds(min(30, Int(ceil(remaining))))
        }
        return .milliseconds(min(250 * max(1, attempt), 1_000))
    }

    /// RFC 9110 IMF-fixdate form used by `Retry-After`.  We intentionally do
    /// not accept locale-dependent date strings from an untrusted endpoint.
    private static func parseRetryAfterHTTPDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value)
    }

    private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        var components = URLComponents(url: origin.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let url = components?.url else { throw LatticeLensError.invalidResponse }
        return url
    }

    private func trustedNextURL(_ source: String?, expectedPath: String) throws -> URL? {
        guard let source, !source.isEmpty else { return nil }
        guard let url = URL(string: source) else { throw LatticeLensError.endpointChanged }
        return try validatedNextURL(url, expectedPath: expectedPath)
    }

    private func validatedNextURL(_ url: URL, expectedPath: String) throws -> URL {
        guard isTrustedInspireURL(url),
              url.user == nil, url.password == nil,
              url.fragment == nil,
              matchesEndpointPath(url.path, expected: expectedPath) else { throw LatticeLensError.endpointChanged }
        return url
    }

    /// INSPIRE currently emits `/api/authors/` and `/api/literature/` in
    /// pagination links while entry requests may use the slashless form.  The
    /// two forms denote the same endpoint; no other path rewriting is allowed.
    private func matchesEndpointPath(_ path: String, expected: String) -> Bool {
        path == expected || path == expected + "/"
    }

    private func isTrustedInspireURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == origin.host?.lowercased() &&
        InspireRedirectDelegate.effectivePort(url) == InspireRedirectDelegate.effectivePort(origin)
    }
}
