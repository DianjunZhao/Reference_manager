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
}

private actor ConditionalGETCache {
    private var entries: [URL: ConditionalGETCacheEntry] = [:]

    func entry(for url: URL) -> ConditionalGETCacheEntry? { entries[url] }

    func store(_ entry: ConditionalGETCacheEntry, for url: URL) {
        guard entry.eTag != nil || entry.lastModified != nil else {
            entries.removeValue(forKey: url)
            return
        }
        entries[url] = entry
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

    init(
        transport: any HTTPTransport = URLSessionTransport(),
        origin: URL = InspireClient.defaultOrigin,
        maximumResponseBytes: Int = InspireClient.defaultMaximumResponseBytes,
        maximumGETAttempts: Int = InspireClient.defaultMaximumGETAttempts,
        retrySleeper: @escaping @Sendable (Duration) async throws -> Void = { duration in try await Task.sleep(for: duration) }
    ) {
        self.transport = transport
        self.origin = origin
        self.decoder = JSONDecoder()
        self.maximumResponseBytes = max(1, maximumResponseBytes)
        self.maximumGETAttempts = max(1, maximumGETAttempts)
        self.retrySleeper = retrySleeper
        self.conditionalCache = ConditionalGETCache()
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
        let isPartitioned = queryValue?.contains("control_number") == true
        let partition = authorCandidatePartition(for: queryValue)
        let responsePage = try decoder.decode(InspireSearchPage<InspireAuthorHit>.self, from: await get(url))
        let authors = try responsePage.hits.hits.map(InspireMapper.author)

        // INSPIRE rejects offsets beyond its 10,000-result window.  The
        // hep-lat/hep-th union currently contains more than that, so never
        // follow the server's page-41 link.  Advance to a disjoint
        // control-number range instead; each range remains below the API
        // window and the durable checkpoint still stores an ordinary trusted
        // INSPIRE URL.
        let pageSize = 250
        let exhaustedWindow = pageNumber >= 40 && responsePage.hits.total > pageNumber * pageSize
        let advertisedNextPage = responsePage.links?.next.flatMap { URL(string: $0) }
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            .flatMap { Int($0.queryItems?.first(where: { $0.name == "page" })?.value ?? "") }
        let nextBeyondWindow = advertisedNextPage.map { $0 > 40 } ?? false
        let serverNext = (exhaustedWindow || nextBeyondWindow) ? nil :
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

    private func authorCandidateURL(partition: Int, page: Int) throws -> URL {
        guard Self.authorCandidatePartitions.indices.contains(partition) else { throw LatticeLensError.paginationLimitExceeded }
        let range = Self.authorCandidatePartitions[partition]
        let query = "(arxiv_categories:hep-lat OR arxiv_categories:hep-th) AND control_number:[\(range.0) TO \(range.1)]"
        return try makeURL(path: "/api/authors", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "size", value: "250"),
            URLQueryItem(name: "page", value: String(max(1, page)))
        ])
    }

    private func authorCandidatePartition(for query: String?) -> Int {
        guard let query else { return 0 }
        for (index, range) in Self.authorCandidatePartitions.enumerated() {
            if query.contains("control_number:[\(range.0) TO \(range.1)]") ||
               query.contains("control_number:[\(range.0)%20TO%20\(range.1)]") {
                return index
            }
        }
        // A pre-partition checkpoint has no control-number clause.  Treat it
        // as the first partition; AuthorIndexService invalidates such a
        // checkpoint before calling us, so this is only a defensive bound.
        return 0
    }

    func hIndex(for authorRecid: Int, now: Date = Date()) async throws -> HIndexSnapshot {
        let query = "authors.recid:\(authorRecid)"
        let url = try makeURL(path: "/api/literature/facets", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "facet_name", value: "citation-summary")
        ])
        let data = try await get(url)
        let payload = try decoder.decode(JSONValue.self, from: data)
        return try InspireMapper.hIndex(from: payload, authorRecid: authorRecid, query: query, now: now,
                                        rawSchemaHash: StableHash.sha256(data))
    }

    /// Fallback when the live citation-summary facet changes or is unavailable.
    /// It deliberately records a different source rather than impersonating the
    /// INSPIRE official summary.
    func locallyComputedHIndex(for authorRecid: Int, now: Date = Date()) async throws -> HIndexSnapshot {
        var nextURL: URL?
        var counts: [Int] = []
        var totalPapers = 0
        var pages = 0
        repeat {
            try Task.checkCancellation()
            guard pages < 1_000 else { throw LatticeLensError.paginationLimitExceeded }
            let url = try nextURL.map { try validatedNextURL($0, expectedPath: "/api/literature") } ?? makeURL(path: "/api/literature", query: [
                URLQueryItem(name: "q", value: "authors.recid:\(authorRecid)"),
                URLQueryItem(name: "sort", value: "mostcited"),
                URLQueryItem(name: "size", value: "250")
            ])
            let data = try await get(url)
            let page = try decoder.decode(InspireSearchPage<InspireLiteratureHit>.self, from: data)
            totalPapers += page.hits.hits.count
            counts.append(contentsOf: page.hits.hits.compactMap(\.metadata.citationCount).filter { $0 >= 0 })
            nextURL = try trustedNextURL(page.links?.next, expectedPath: "/api/literature")
            pages += 1
        } while nextURL != nil
        let sorted = counts.sorted(by: >)
        let h = sorted.enumerated().reduce(0) { current, item in item.element >= item.offset + 1 ? item.offset + 1 : current }
        return HIndexSnapshot(authorRecid: authorRecid, all: h, published: nil, excludesSelfCitations: false,
                              source: "locally-computed", query: "authors.recid:\(authorRecid) sort:mostcited",
                              fetchedAt: now, rawSchemaHash: StableHash.sha256(sorted.map(String.init).joined(separator: ",")),
                              inputPaperCount: totalPapers, missingCitationCount: totalPapers - counts.count,
                              pageCount: pages, computationFormulaVersion: "h-index-counts-v1")
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
            URLQueryItem(name: "size", value: "10")
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
                                             lastModified: response.value(forHTTPHeaderField: "Last-Modified")),
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
