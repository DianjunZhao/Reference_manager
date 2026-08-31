import Foundation

enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var integerValue: Int? {
        switch self {
        case .number(let value): Int(exactly: value)
        case .string(let value): Int(value)
        default: nil
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    func values(forKey wanted: String) -> [JSONValue] {
        switch self {
        case .object(let object):
            let local = object.compactMap { $0.key == wanted ? $0.value : nil }
            return local + object.values.flatMap { $0.values(forKey: wanted) }
        case .array(let values): return values.flatMap { $0.values(forKey: wanted) }
        default: return []
        }
    }
}

struct InspireLinks: Codable, Sendable {
    let next: String?
    let `self`: String?
}

/// INSPIRE search replies have a nested `hits` object.  A flattened `[Hit]`
/// shape is deliberately not accepted: accepting it would silently mask a
/// public API contract regression in fixtures and in the live client.
struct InspireSearchHits<Hit: Decodable & Sendable>: Decodable, Sendable {
    let hits: [Hit]
    let total: Int

    /// INSPIRE has emitted both the legacy integer form and the Elasticsearch
    /// `{ "value": ..., "relation": ... }` form for `hits.total`.  The
    /// latter is now common on `/api/literature`; decoding it as an `Int`
    /// makes a valid page look like a failed refresh and also breaks the
    /// bounded local h-index fallback after a citation-summary 400.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hits = try values.decode([Hit].self, forKey: .hits)
        if let integer = try? values.decode(Int.self, forKey: .total) {
            total = integer
        } else {
            let object = try values.decode(TotalObject.self, forKey: .total)
            total = object.value
        }
    }

    private struct TotalObject: Decodable {
        let value: Int

        enum CodingKeys: String, CodingKey { case value }
    }

    private enum CodingKeys: String, CodingKey { case hits, total }
}

struct InspireSearchPage<Hit: Decodable & Sendable>: Decodable, Sendable {
    let hits: InspireSearchHits<Hit>
    let links: InspireLinks?
}

struct InspireAuthorHit: Decodable, Sendable {
    let id: JSONValue
    let metadata: Metadata

    struct Metadata: Decodable, Sendable {
        let name: Name?
        let nativeNames: [NativeName]?
        let ids: [ExternalID]?
        let arxivCategories: [String]?

        enum CodingKeys: String, CodingKey {
            case name
            case nativeNames = "native_names"
            case ids
            case arxivCategories = "arxiv_categories"
        }
    }

    struct Name: Codable, Sendable {
        let value: String
        let nativeNames: [String]?

        enum CodingKeys: String, CodingKey {
            case value
            case nativeNames = "native_names"
        }
    }

    struct NativeName: Codable, Sendable {
        let value: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                value = string
            } else if let name = try? container.decode(Name.self) {
                value = name.value
            } else {
                throw DecodingError.typeMismatch(NativeName.self, .init(codingPath: decoder.codingPath, debugDescription: "native name must be string or name object"))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }

    struct ExternalID: Codable, Sendable {
        let schema: String?
        let value: String?
    }
}

struct InspireLiteratureHit: Decodable, Sendable {
    let id: JSONValue
    let updated: String?
    let metadata: Metadata

    struct Metadata: Decodable, Sendable {
        let titles: [SourcedText]?
        let abstracts: [SourcedText]?
        let arxivEprints: [ArxivEprint]?
        let citationCount: Int?
        let preprintDate: String?
        let earliestDate: String?
        let dois: [DOI]?
        let publicationInfo: [PublicationInfo]?
        let imprints: [Imprint]?
        let figures: [Figure]?
        let authors: [Contributor]?
        let documents: [Document]?

        enum CodingKeys: String, CodingKey {
            case titles, abstracts, dois, figures, authors, documents
            case arxivEprints = "arxiv_eprints"
            case citationCount = "citation_count"
            case preprintDate = "preprint_date"
            case earliestDate = "earliest_date"
            case publicationInfo = "publication_info"
            case imprints
        }
    }

    struct SourcedText: Codable, Sendable {
        let title: String?
        let value: String?
        let source: String?
    }

    struct ArxivEprint: Codable, Sendable {
        let value: String?
        let categories: [String]?
    }

    struct DOI: Codable, Sendable {
        let value: String?
    }

    struct PublicationInfo: Codable, Sendable {
        let pubinfoFreetext: String?
        let material: String?
        /// INSPIRE normally sends an integer, but older records and mirrors
        /// have emitted a decimal year as a string.  Decode both forms while
        /// ignoring malformed values instead of rejecting the whole paper.
        let year: Int?

        enum CodingKeys: String, CodingKey {
            case pubinfoFreetext = "pubinfo_freetext", material, year
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pubinfoFreetext = try container.decodeIfPresent(String.self, forKey: .pubinfoFreetext)
            material = try container.decodeIfPresent(String.self, forKey: .material)
            year = (try? container.decodeIfPresent(Int.self, forKey: .year)) ??
                (try? container.decodeIfPresent(String.self, forKey: .year).flatMap(Int.init))
        }
    }

    struct Imprint: Codable, Sendable {
        /// INSPIRE uses an ISO date here (for example, `2023-01-04`).  Some
        /// older mirrors expose only the four-digit year, so the mapper
        /// accepts both bounded forms and ignores malformed values.
        let date: String?
    }

    struct Figure: Codable, Sendable {
        let key: String?
        let url: String?
        let label: String?
        let caption: String?
        let source: String?
        let filename: String?
    }

    struct Contributor: Codable, Sendable {
        let recid: JSONValue?
        let fullName: String?

        enum CodingKeys: String, CodingKey {
            case recid
            case fullName = "full_name"
        }
    }

    struct Document: Codable, Sendable {
        let key: String?
        let url: String?
        let source: String?
        let filename: String?
        let fulltext: Bool?
    }
}

enum InspireMapper {
    static func author(from hit: InspireAuthorHit) throws -> Author {
        guard let recid = hit.id.integerValue else { throw LatticeLensError.malformedPayload }
        let metadata = hit.metadata
        let bai = metadata.ids?.first { $0.schema?.caseInsensitiveCompare("INSPIRE BAI") == .orderedSame }?.value
        return Author(
            recid: recid,
            preferredName: metadata.name?.value ?? "Unknown author \(recid)",
            nativeNames: Array(Set((metadata.name?.nativeNames ?? []) + (metadata.nativeNames?.map(\.value) ?? []))).sorted(),
            bai: bai,
            arxivCategories: Set(metadata.arxivCategories ?? []),
            hIndex: nil,
            hIndexState: .unknown,
            isTracked: false,
            lastSyncedAt: nil
        )
    }

    static func paper(from hit: InspireLiteratureHit, now: Date) throws -> Paper {
        guard let literatureID = hit.id.integerValue else { throw LatticeLensError.malformedPayload }
        let metadata = hit.metadata
        let titles = (metadata.titles ?? []).compactMap { item -> PaperTitle? in
            guard let title = item.title ?? item.value, !title.isEmpty else { return nil }
            return PaperTitle(value: title, source: item.source)
        }
        let abstracts = (metadata.abstracts ?? []).compactMap { item -> PaperAbstract? in
            guard let value = item.value ?? item.title, !value.isEmpty else { return nil }
            return PaperAbstract(value: value, source: item.source)
        }
        let eprint = metadata.arxivEprints?.first
        let publicationYear = metadata.publicationInfo?
            .compactMap(\.year)
            .first(where: { (1900...2200).contains($0) }) ??
            metadata.imprints?.compactMap { parseYear($0.date) }
                .first(where: { (1900...2200).contains($0) })
        let figures = (metadata.figures ?? []).compactMap { figure -> PaperFigure? in
            guard let key = figure.key, !key.isEmpty else { return nil }
            let url = figure.url.flatMap(URL.init(string:)).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
            return PaperFigure(key: key, url: url, label: figure.label, caption: figure.caption,
                               source: figure.source, filename: figure.filename)
        }
        let contributors = (metadata.authors ?? []).enumerated().compactMap { offset, author -> PaperContributor? in
            guard let fullName = author.fullName, !fullName.isEmpty else { return nil }
            return PaperContributor(recid: author.recid?.integerValue, fullName: fullName, position: offset)
        }
        let documents = (metadata.documents ?? []).enumerated().compactMap { offset, document -> PaperDocument? in
            guard let key = document.key ?? document.filename ?? document.url ?? (document.source.map { "document-\(offset)-\($0)" }), !key.isEmpty else { return nil }
            let url = document.url.flatMap(URL.init(string:)).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
            return PaperDocument(key: key, url: url, source: document.source, filename: document.filename,
                                 isFullText: document.fulltext ?? false)
        }
        return Paper(
            literatureID: literatureID,
            titles: titles,
            abstracts: abstracts,
            preprintDate: parseDate(metadata.preprintDate),
            earliestDate: parseDate(metadata.earliestDate),
            publicationYear: publicationYear,
            arxivID: eprint?.value,
            arxivCategories: eprint?.categories ?? [],
            doi: metadata.dois?.compactMap(\.value).first,
            citationCount: metadata.citationCount,
            publicationStatus: metadata.publicationInfo?.compactMap { $0.material ?? $0.pubinfoFreetext }.first,
            updated: parseDateTime(hit.updated),
            figures: figures,
            contributors: contributors,
            documents: documents,
            firstSeenAt: now,
            isRead: false
        )
    }

    static func hIndex(from payload: JSONValue, authorRecid: Int, query: String, now: Date, rawSchemaHash: String? = nil) throws -> HIndexSnapshot {
        let hIndexObjects = payload.values(forKey: "h-index") + payload.values(forKey: "h_index")
        guard let hIndex = hIndexObjects.compactMap(asObject).first,
              let valueObject = hIndex["value"].flatMap(asObject),
              let all = valueObject["all"]?.integerValue else {
            throw LatticeLensError.malformedPayload
        }
        return HIndexSnapshot(
            authorRecid: authorRecid,
            all: all,
            published: valueObject["published"]?.integerValue,
            excludesSelfCitations: false,
            source: "INSPIRE",
            query: query,
            fetchedAt: now,
            rawSchemaHash: rawSchemaHash ?? StableHash.sha256(String(describing: payload))
        )
    }

    private static func asObject(_ value: JSONValue) -> [String: JSONValue]? {
        if case .object(let object) = value { return object }
        return nil
    }

    private static func parseDate(_ value: String?) -> Date? {
        value.flatMap(DateFormatter.inspireDate.date(from:))
    }

    private static func parseDateTime(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value) ?? parseDate(value)
    }

    private static func parseYear(_ value: String?) -> Int? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 4 || trimmed.count >= 5 else { return nil }
        let prefix = String(trimmed.prefix(4))
        guard prefix.allSatisfy(\.isNumber), let year = Int(prefix) else { return nil }
        // Do not let an arbitrary numeric mirror field become a timeline year.
        guard (1900...2200).contains(year) else { return nil }
        if trimmed.count > 4 {
            guard trimmed.first(where: { !$0.isNumber }) == "-" else { return nil }
        }
        return year
    }
}
