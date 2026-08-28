import Foundation
import Security

enum LLMProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A user-operated process on this Mac.  It is deliberately a distinct
    /// provider instead of a permissive switch on arbitrary custom endpoints:
    /// only this profile may use loopback HTTP in a Release build.
    case localOpenAICompatible
    case openAI
    case deepSeek
    case customOpenAICompatible

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .localOpenAICompatible: "Local OpenAI-compatible"
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        case .customOpenAICompatible: "Custom OpenAI-compatible"
        }
    }
    var defaultBaseURL: String {
        switch self {
        case .localOpenAICompatible: "http://127.0.0.1:11434/v1"
        case .openAI: "https://api.openai.com/v1"
        case .deepSeek: "https://api.deepseek.com/v1"
        case .customOpenAICompatible: "https://example.invalid/v1"
        }
    }

    /// A local process may be configured without a credential.  A manually
    /// entered local token still follows the normal Keychain-only path.
    var apiKeyIsRequired: Bool { self != .localOpenAICompatible }
}

struct ProviderProfile: Codable, Hashable, Sendable {
    /// This value is part of the profile's runtime policy.  `activeProfile`
    /// always resets it from `LLMSettings.activeProvider`, preventing an old
    /// serialized custom profile from gaining loopback privileges.
    var provider: LLMProvider
    var baseURL: String
    var selectedModel: String
    var manualModel: String
    var usesStreaming: Bool
    /// Vision is a user-confirmed capability, never inferred from a model id.
    var supportsVision: Bool
    /// Injected by LLMSettings.activeProfile; this is a non-secret cache
    /// generation and is never serialized as a credential or key hash.
    var discoveryCredentialRevision: Int

    init(provider: LLMProvider = .customOpenAICompatible, baseURL: String, selectedModel: String = "", manualModel: String = "", usesStreaming: Bool = true, supportsVision: Bool = false,
         discoveryCredentialRevision: Int = 0) {
        self.provider = provider
        self.baseURL = baseURL
        self.selectedModel = selectedModel
        self.manualModel = manualModel
        self.usesStreaming = usesStreaming
        self.supportsVision = supportsVision
        self.discoveryCredentialRevision = max(0, discoveryCredentialRevision)
    }

    var effectiveModel: String {
        let selected = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? manualModel.trimmingCharacters(in: .whitespacesAndNewlines) : selected
    }

    private enum CodingKeys: String, CodingKey { case provider, baseURL, selectedModel, manualModel, usesStreaming, supportsVision, discoveryCredentialRevision }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decodeIfPresent(LLMProvider.self, forKey: .provider) ?? .customOpenAICompatible
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        selectedModel = try values.decodeIfPresent(String.self, forKey: .selectedModel) ?? ""
        manualModel = try values.decodeIfPresent(String.self, forKey: .manualModel) ?? ""
        usesStreaming = try values.decodeIfPresent(Bool.self, forKey: .usesStreaming) ?? true
        supportsVision = try values.decodeIfPresent(Bool.self, forKey: .supportsVision) ?? false
        discoveryCredentialRevision = try values.decodeIfPresent(Int.self, forKey: .discoveryCredentialRevision) ?? 0
    }
}

struct PrivacyConsent: Codable, Hashable, Sendable {
    let provider: LLMProvider
    let normalizedBaseURL: String
    let sourceScope: String
    let sendsImagePixels: Bool
}

struct TerminologyEntry: Codable, Hashable, Identifiable, Sendable {
    /// The 1.0 settings contract deliberately permits a substantial local
    /// glossary while keeping every entry and every generated prompt bounded.
    /// Prompt builders may still apply their own byte limits before sending a
    /// request; this count is not permission to emit an unbounded payload.
    static let maximumItems = 500
    static let maximumScalars = 160

    let id: UUID
    var source: String
    var preferredZH: String
    var note: String

    init(id: UUID = UUID(), source: String, preferredZH: String, note: String = "") {
        self.id = id
        self.source = source
        self.preferredZH = preferredZH
        self.note = note
    }

    var isValid: Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !preferredZH.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        source.unicodeScalars.count <= Self.maximumScalars &&
        preferredZH.unicodeScalars.count <= Self.maximumScalars &&
        note.unicodeScalars.count <= Self.maximumScalars
    }
}

struct LLMSettings: Codable, Sendable {
    var activeProvider: LLMProvider
    var profiles: [String: ProviderProfile]
    var automaticAnalysis: Bool
    var mode: InsightMode
    var detailLevel: InsightDetailLevel
    var maximumFigures: Int
    /// Changes only after a successful Keychain write. It participates in the
    /// insight cache key without exposing a credential or a credential hash.
    var credentialRevision: Int
    /// Legacy bool is retained only for decoding old settings. New consent is
    /// endpoint/source-scope/capability-bound and therefore cannot be reused
    /// after a provider/Base URL/vision change.
    var privacyDisclosureAcknowledged: Bool
    var privacyConsents: Set<PrivacyConsent>
    var terminology: [TerminologyEntry]

    init(
        activeProvider: LLMProvider = .localOpenAICompatible,
        profiles: [String: ProviderProfile]? = nil,
        automaticAnalysis: Bool = true,
        mode: InsightMode = .fast,
        detailLevel: InsightDetailLevel = .standard,
        maximumFigures: Int = 3,
        credentialRevision: Int = 0,
        privacyDisclosureAcknowledged: Bool = false,
        privacyConsents: Set<PrivacyConsent> = [],
        terminology: [TerminologyEntry] = []
    ) {
        var values = profiles ?? [:]
        // A pre-1.0 encoded settings document can contain only the historic
        // OpenAI profile.  Treat that as an explicit migrated selection rather
        // than silently switching it to a newly introduced local endpoint.
        // Fresh settings (no supplied profiles) still default to Local.
        let migratedActiveProvider: LLMProvider
        if activeProvider == .localOpenAICompatible,
           profiles?[LLMProvider.localOpenAICompatible.rawValue] == nil,
           profiles?[LLMProvider.openAI.rawValue] != nil {
            migratedActiveProvider = .openAI
        } else {
            migratedActiveProvider = activeProvider
        }
        self.activeProvider = migratedActiveProvider
        for provider in LLMProvider.allCases where values[provider.rawValue] == nil {
            values[provider.rawValue] = ProviderProfile(provider: provider, baseURL: provider.defaultBaseURL)
        }
        self.profiles = values
        self.automaticAnalysis = automaticAnalysis
        self.mode = mode
        self.detailLevel = detailLevel
        self.maximumFigures = [0, 3, 5].contains(maximumFigures) ? maximumFigures : 3
        self.credentialRevision = max(0, credentialRevision)
        self.privacyDisclosureAcknowledged = privacyDisclosureAcknowledged
        self.privacyConsents = privacyConsents
        self.terminology = Array(terminology.filter(\.isValid).prefix(TerminologyEntry.maximumItems))
    }

    var activeProfile: ProviderProfile {
        var profile = profiles[activeProvider.rawValue] ?? ProviderProfile(provider: activeProvider, baseURL: activeProvider.defaultBaseURL)
        profile.provider = activeProvider
        profile.discoveryCredentialRevision = credentialRevision
        return profile
    }

    var sessionFingerprint: String {
        let profile = activeProfile
        let normalized = (try? APIEndpointBuilder.normalizedBaseURL(from: profile.baseURL, provider: profile.provider).absoluteString) ?? "invalid"
        let terms = terminology.map { "\($0.source)|\($0.preferredZH)|\($0.note)" }.sorted().joined(separator: "\n")
        return StableHash.sha256([activeProvider.rawValue, normalized, profile.effectiveModel, String(profile.usesStreaming),
                                  String(profile.supportsVision), String(credentialRevision), mode.rawValue,
                                  detailLevel.rawValue, String(maximumFigures), terms].joined(separator: "|"))
    }

    func hasConsent(for provider: LLMProvider, sourceScope: String = ProductContract.sourceScope, sendsImagePixels: Bool = false) -> Bool {
        guard let profile = profiles[provider.rawValue],
              let baseURL = try? APIEndpointBuilder.normalizedBaseURL(from: profile.baseURL, provider: provider).absoluteString else { return false }
        return privacyConsents.contains(PrivacyConsent(provider: provider, normalizedBaseURL: baseURL,
                                                        sourceScope: sourceScope, sendsImagePixels: sendsImagePixels))
    }

    func modelOptions(discovered: [String], query: String = "") -> [String] {
        let saved = activeProfile.effectiveModel
        var values = Set(discovered.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        if !saved.isEmpty { values.insert(saved) }
        let needle = SearchNormalizer.normalize(query)
        return values.sorted().map { value in
            let status = discovered.contains(value) ? "" : " (saved / currently undiscovered)"
            return "\(value)\(status)"
        }.filter { needle.isEmpty || SearchNormalizer.normalize($0).contains(needle) }
    }

    mutating func addTerminology(source: String, preferredZH: String, note: String = "") throws {
        let entry = TerminologyEntry(source: source, preferredZH: preferredZH, note: note)
        guard entry.isValid else { throw LatticeLensError.schemaViolation("terminology entry 超限或为空") }
        guard terminology.count < TerminologyEntry.maximumItems else { throw LatticeLensError.schemaViolation("terminology 已达到上限") }
        terminology.append(entry)
    }

    mutating func updateTerminology(_ entry: TerminologyEntry) throws {
        guard entry.isValid, let index = terminology.firstIndex(where: { $0.id == entry.id }) else {
            throw LatticeLensError.schemaViolation("terminology entry 不存在或无效")
        }
        terminology[index] = entry
    }

    mutating func deleteTerminology(_ id: UUID) { terminology.removeAll { $0.id == id } }

    func exportTerminologyJSON() throws -> Data {
        try JSONEncoder.latticeLens.encode(terminology)
    }

    mutating func importTerminologyJSON(_ data: Data) throws {
        let values = try JSONDecoder.latticeLens.decode([TerminologyEntry].self, from: data)
        guard values.count <= TerminologyEntry.maximumItems, values.allSatisfy(\.isValid) else {
            throw LatticeLensError.schemaViolation("导入术语超过本地 bounded contract 或包含无效字段")
        }
        terminology = values
    }

    static func validate(profile: ProviderProfile) throws {
        _ = try APIEndpointBuilder.normalizedBaseURL(from: profile.baseURL, provider: profile.provider)
        guard !profile.effectiveModel.isEmpty else { throw LatticeLensError.schemaViolation("必须选择模型或填写 manual model") }
    }

    mutating func recordConsent(for provider: LLMProvider, sourceScope: String = ProductContract.sourceScope, sendsImagePixels: Bool = false) {
        guard let profile = profiles[provider.rawValue],
              let baseURL = try? APIEndpointBuilder.normalizedBaseURL(from: profile.baseURL, provider: provider).absoluteString else { return }
        privacyConsents.insert(PrivacyConsent(provider: provider, normalizedBaseURL: baseURL,
                                               sourceScope: sourceScope, sendsImagePixels: sendsImagePixels))
        privacyDisclosureAcknowledged = true
    }

    private enum CodingKeys: String, CodingKey {
        case activeProvider, profiles, automaticAnalysis, mode, detailLevel, maximumFigures, credentialRevision, privacyDisclosureAcknowledged, privacyConsents, terminology
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            activeProvider: try values.decodeIfPresent(LLMProvider.self, forKey: .activeProvider) ?? .openAI,
            profiles: try values.decodeIfPresent([String: ProviderProfile].self, forKey: .profiles),
            automaticAnalysis: try values.decodeIfPresent(Bool.self, forKey: .automaticAnalysis) ?? true,
            mode: try values.decodeIfPresent(InsightMode.self, forKey: .mode) ?? .fast,
            detailLevel: try values.decodeIfPresent(InsightDetailLevel.self, forKey: .detailLevel) ?? .standard,
            maximumFigures: try values.decodeIfPresent(Int.self, forKey: .maximumFigures) ?? 3,
            credentialRevision: try values.decodeIfPresent(Int.self, forKey: .credentialRevision) ?? 0,
            privacyDisclosureAcknowledged: try values.decodeIfPresent(Bool.self, forKey: .privacyDisclosureAcknowledged) ?? false,
            privacyConsents: try values.decodeIfPresent(Set<PrivacyConsent>.self, forKey: .privacyConsents) ?? [],
            terminology: try values.decodeIfPresent([TerminologyEntry].self, forKey: .terminology) ?? []
        )
    }
}

enum APIEndpointBuilder {
    enum EndpointError: LocalizedError, Equatable {
        case emptyURL
        case invalidURL
        case insecureScheme
        case credentialsNotAllowed
        case queryOrFragmentNotAllowed

        var errorDescription: String? {
            switch self {
            case .emptyURL: "API Base URL 不能为空。"
            case .invalidURL: "API Base URL 无效。"
            case .insecureScheme: "API Base URL 必须使用 HTTPS（Debug 本地测试除外）。"
            case .credentialsNotAllowed: "API Base URL 不得包含用户名或密码。"
            case .queryOrFragmentNotAllowed: "API Base URL 不得包含 query 或 fragment。"
            }
        }
    }

    /// Endpoint policy is intentionally provider-aware.  Do not add a generic
    /// `allowLocalHTTP` escape hatch: it would let a custom/remote profile turn
    /// an HTTP typo into an unencrypted network request.
    static func normalizedBaseURL(from input: String, provider: LLMProvider = .customOpenAICompatible) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EndpointError.emptyURL }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty else {
            throw EndpointError.invalidURL
        }
        guard components.user == nil, components.password == nil else { throw EndpointError.credentialsNotAllowed }
        guard components.query == nil, components.fragment == nil else { throw EndpointError.queryOrFragmentNotAllowed }
        // URLComponents represents an IPv6 literal differently across
        // Foundation releases (with or without brackets in `host`). Normalize
        // only that syntactic wrapper before exact loopback comparison.
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let isLocal = normalizedHost == "localhost" || normalizedHost == "127.0.0.1" || normalizedHost == "::1"
        let localHTTPAllowed = provider == .localOpenAICompatible && isLocal
        guard scheme == "https" || (scheme == "http" && localHTTPAllowed) else { throw EndpointError.insecureScheme }
        components.scheme = scheme
        components.host = normalizedHost == "::1" ? "[::1]" : normalizedHost
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.isEmpty ? "/v1" : "/\(path)"
        guard let url = components.url else { throw EndpointError.invalidURL }
        return url
    }

    static func endpoint(baseURL: String, path: String, provider: LLMProvider = .customOpenAICompatible) throws -> URL {
        let normalized = try normalizedBaseURL(from: baseURL, provider: provider)
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return cleanPath.isEmpty ? normalized : normalized.appending(path: cleanPath)
    }

    static func redactionVariants(for baseURL: String) -> [String] {
        guard let normalized = try? normalizedBaseURL(from: baseURL) else { return [] }
        return [normalized.absoluteString, normalized.deletingLastPathComponent().absoluteString]
    }
}

protocol KeychainStoring: Sendable {
    func save(_ value: String, service: String, account: String) throws
    func read(service: String, account: String) throws -> String?
    /// Checks only for a credential entry.  Callers that merely render saved
    /// versus missing status must not request the secret bytes.
    func contains(service: String, account: String) throws -> Bool
    func delete(service: String, account: String) throws
}

extension KeychainStoring {
    /// Test doubles that only model `read` retain their existing behavior.
    /// The production store overrides this with a metadata-only Security
    /// query, so no API-key bytes are decrypted for Settings status.
    func contains(service: String, account: String) throws -> Bool {
        guard let value = try read(service: service, account: account) else { return false }
        return !value.isEmpty
    }
}

enum KeychainStoreError: LocalizedError {
    case invalidData
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData: "钥匙串中保存的 API Key 数据无效。"
        case .unexpectedStatus: "无法访问钥匙串。"
        }
    }
}

final class KeychainStore: KeychainStoring, @unchecked Sendable {
    func save(_ value: String, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let attributes: [CFString: Any] = [kSecValueData: Data(value.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainStoreError.unexpectedStatus(updateStatus) }
        var addQuery = query
        addQuery[kSecValueData] = Data(value.utf8)
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(addStatus) }
    }

    func read(service: String, account: String) throws -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw KeychainStoreError.invalidData }
        return value
    }

    func contains(service: String, account: String) throws -> Bool {
        // Do not set `kSecReturnData`: this query is intentionally limited to
        // existence metadata and must not request/decrypt an API key merely to
        // render a Settings disclosure.
        let status = SecItemCopyMatching(baseQuery(service: service, account: account) as CFDictionary, nil)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound { return false }
        throw KeychainStoreError.unexpectedStatus(status)
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainStoreError.unexpectedStatus(status) }
    }

    private func baseQuery(service: String, account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }
}
