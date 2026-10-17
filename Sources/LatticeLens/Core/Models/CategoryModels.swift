import Foundation

protocol CategoryProfileStoring: Sendable {
    func loadCategoryProfile() async throws -> CategoryProfile?
    func saveCategoryProfile(_ profile: CategoryProfile) async throws
}

/// arXiv categories that are part of the supported author-index product
/// contract.  INSPIRE may return additional categories; those values remain
/// in `Author.arxivCategories` but are not silently treated as an enabled
/// candidate category.
enum SupportedArxivCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case hepLat = "hep-lat"
    case hepPh = "hep-ph"
    case hepTh = "hep-th"

    var displayNameZH: String {
        switch self {
        case .hepLat: "hep-lat（格点）"
        case .hepPh: "hep-ph（唯象）"
        case .hepTh: "hep-th（理论）"
        }
    }

    /// Stable wire ordering.  Never use `Set`'s iteration order in a query,
    /// cache key, checkpoint or accessibility value.
    static func canonical(_ categories: some Collection<SupportedArxivCategory>) -> [SupportedArxivCategory] {
        Array(Set(categories)).sorted { $0.rawValue < $1.rawValue }
    }

    static let defaultEnabled: Set<SupportedArxivCategory> = [.hepLat, .hepPh]
    static let legacyV1: Set<SupportedArxivCategory> = [.hepLat, .hepTh]
}

/// A view-only facet. Changing a facet must not mutate the durable enabled
/// set or invalidate a pagination checkpoint.
enum CategoryFacet: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case allEnabled = "all-enabled"
    case hepLat = "hep-lat"
    case hepPh = "hep-ph"
    case hepTh = "hep-th"
    case multiCategory = "multi-category"

    var id: String { rawValue }

    var displayNameZH: String {
        switch self {
        case .allEnabled: "全部已启用"
        case .hepLat: "hep-lat"
        case .hepPh: "hep-ph"
        case .hepTh: "hep-th"
        case .multiCategory: "多分类"
        }
    }

    func matches(categories: some Collection<String>, enabled: Set<SupportedArxivCategory>) -> Bool {
        let supported = Set(categories.compactMap(SupportedArxivCategory.init(rawValue:)))
        switch self {
        case .allEnabled:
            return !supported.isDisjoint(with: enabled)
        case .hepLat:
            return supported.contains(.hepLat)
        case .hepPh:
            return supported.contains(.hepPh)
        case .hepTh:
            return supported.contains(.hepTh)
        case .multiCategory:
            return supported.intersection(enabled).count > 1
        }
    }
}

/// Durable category preferences.  The revision is part of every derived
/// query identity so changing the enabled set cannot resume an incompatible
/// pagination checkpoint.
struct CategoryProfile: Codable, Hashable, Sendable, Identifiable {
    static let currentRevision = 3

    var categories: Set<SupportedArxivCategory>
    var revision: Int

    init(categories: Set<SupportedArxivCategory> = SupportedArxivCategory.defaultEnabled,
         revision: Int = CategoryProfile.currentRevision) {
        self.categories = Set(categories)
        self.revision = max(1, revision)
    }

    var id: String { queryIdentity }
    var canonicalCategories: [SupportedArxivCategory] { SupportedArxivCategory.canonical(categories) }
    var rawValues: [String] { canonicalCategories.map(\.rawValue) }
    var key: String { rawValues.joined(separator: "-") }
    var query: String { ArxivCategoryQueryBuilder.query(categories: categories) }
    /// These revisions belong to different contracts: `revision` changes
    /// when the user's enabled category set changes, the query revision
    /// changes when INSPIRE query semantics change, and pagination has its
    /// own revision when partition/window behavior changes.
    var profileRevision: Int { revision }
    var queryContractRevision: Int { ArxivCategoryQueryBuilder.revision }
    var paginationRevision: Int { AuthorCandidatePaginationContract.revision }
    var queryIdentity: String {
        "author-candidates:\(key)-profile-v\(profileRevision)-query-v\(queryContractRevision)-pagination-v\(paginationRevision)"
    }
    var checkpointIdentity: String {
        "\(query) [profile-v\(profileRevision);query-v\(queryContractRevision);pagination-v\(paginationRevision)]"
    }
    func jobID(kind: String = "author-candidates") -> String {
        "\(kind):\(key)-profile-v\(profileRevision)-query-v\(queryContractRevision)-pagination-v\(paginationRevision)"
    }
    /// Stable, non-secret identity for caches, checkpoints and migration
    /// receipts. It is computed from canonical values rather than Set's
    /// unspecified Codable order.
    var selectionHash: String {
        StableHash.sha256("profile-v\(profileRevision)|query-v\(queryContractRevision)|pagination-v\(paginationRevision)|\(rawValues.joined(separator: ","))")
    }
    var provenance: String { "category-profile:\(key):profile-v\(profileRevision):query-v\(queryContractRevision):pagination-v\(paginationRevision):\(selectionHash)" }

    func contains(_ category: SupportedArxivCategory) -> Bool { categories.contains(category) }

    /// A profile loaded from a pre-2.0 store keeps the historical selection,
    /// while making the revision explicit.  It never adds hep-ph behind the
    /// user's back, so old pages cannot be resumed as a new union.
    static func migratingLegacy(categories: Set<String>, revision: Int? = nil) -> CategoryProfile {
        let parsed = Set(categories.compactMap(SupportedArxivCategory.init(rawValue:)))
        return CategoryProfile(categories: parsed.isEmpty ? SupportedArxivCategory.legacyV1 : parsed,
                               revision: revision ?? currentRevision)
    }
}

/// The sole source of truth for INSPIRE arXiv category query strings.  UI,
/// fixtures and pagination code can all use this value without each spelling
/// a subtly different OR expression.
enum ArxivCategoryQueryBuilder {
    /// Bump only when the generated INSPIRE query semantics change.
    static let revision = 3

    static func query(categories: Set<SupportedArxivCategory>) -> String {
        let values = SupportedArxivCategory.canonical(categories).map { "arxiv_categories:\($0.rawValue)" }
        switch values.count {
        case 0: return ""
        case 1: return values[0]
        default: return values.joined(separator: " OR ")
        }
    }

    static func canonicalQuery(categories: Set<SupportedArxivCategory>) -> String {
        query(categories: categories)
    }

    static func queryIdentity(categories: Set<SupportedArxivCategory>) -> String {
        CategoryProfile(categories: categories).queryIdentity
    }

    static func checkpointJobID(categories: Set<SupportedArxivCategory>, kind: String = "author-candidates") -> String {
        CategoryProfile(categories: categories).jobID(kind: kind)
    }

    static func checkpointJobID(profile: CategoryProfile, kind: String = "author-candidates") -> String {
        profile.jobID(kind: kind)
    }

    /// Returns true only when a persisted checkpoint was generated for the
    /// exact same canonical category set and revision.
    static func checkpointMatches(_ query: String, categories: Set<SupportedArxivCategory>) -> Bool {
        checkpointMatches(query, profile: CategoryProfile(categories: categories))
    }

    static func checkpointMatches(_ query: String, profile: CategoryProfile) -> Bool {
        query == profile.checkpointIdentity
    }

    /// Old 1.0 query identities are intentionally recognizable so migration
    /// can mark them invalid rather than accidentally treating them as the new
    /// hep-lat/hep-ph union.
    static func isLegacyQuery(_ query: String) -> Bool {
        let normalized = query.replacingOccurrences(of: " ", with: "").lowercased()
        return normalized.contains("arxiv_categories:hep-lat") &&
            normalized.contains("arxiv_categories:hep-th") &&
            !normalized.contains("hep-ph")
    }
}

/// Author-index partition/window semantics have a separate revision from the
/// INSPIRE query builder. Increment it when control-number partitions, page
/// windows, or next-page trust rules change; the revision is bound into every
/// modern profile/job/checkpoint identity without being sent over the wire.
enum AuthorCandidatePaginationContract {
    static let revision = 7
}

struct CategoryCheckpointMigration: Codable, Hashable, Sendable {
    let originalQuery: String
    let replacementQuery: String
    let categorySet: [SupportedArxivCategory]
    let status: Status
    let migratedAt: Date

    enum Status: String, Codable, Sendable { case invalidatedByQueryRevision, compatible }

    static func evaluate(query: String, categories: Set<SupportedArxivCategory>, now: Date = Date()) -> CategoryCheckpointMigration {
        evaluate(query: query, profile: CategoryProfile(categories: categories), now: now)
    }

    static func evaluate(query: String, profile: CategoryProfile, now: Date = Date()) -> CategoryCheckpointMigration {
        let compatible = query == profile.checkpointIdentity
        return CategoryCheckpointMigration(originalQuery: query, replacementQuery: profile.checkpointIdentity,
                                           categorySet: profile.canonicalCategories,
                                           status: compatible ? .compatible : .invalidatedByQueryRevision,
                                           migratedAt: now)
    }
}
