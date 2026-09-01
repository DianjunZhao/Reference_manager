import Foundation

enum LLMClientError: LocalizedError, Equatable, Sendable {
    case malformedSSE
    case invalidResponse
    case providerError
    case redirectRejected

    var errorDescription: String? {
        switch self {
        case .malformedSSE: "模型流式响应格式无效。"
        case .invalidResponse: "模型响应格式无效。"
        case .providerError: "模型服务拒绝了请求。"
        case .redirectRejected: "模型 endpoint 的重定向已被安全策略拒绝。"
        }
    }
}

enum LLMTransportState: String, Equatable, Sendable {
    /// HTTPS response headers have arrived from the configured origin.
    case connected
    /// The request is waiting for the first response-body byte.
    case waitingFirstContent
    /// At least one response-body byte arrived.  This is distinct from a
    /// decoded delta, particularly for non-streaming JSON responses.
    case receivedFirstContent
}

/// The workflow owns provenance and schema validation; the provider client is
/// deliberately reduced to this small transport surface so fixture tests can
/// exercise those rules without a credential, network connection, or a real
/// model response.
protocol LLMCompleting: Sendable {
    func complete(
        system: String,
        userPayload: String,
        profile: ProviderProfile,
        apiKey: String,
        maximumResponseBytes: Int,
        onTransportState: @escaping @Sendable (LLMTransportState) async -> Void,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String
}

/// Optional transport capability used by the interactive Evidence workflow.
/// The regular protocol remains source-compatible with fixture clients, while
/// the production client can opt out of URLSession's finite request deadline
/// when the workflow itself intentionally has no total hard timeout.
protocol LLMRequestTimeoutConfiguring: Sendable {
    func complete(
        system: String,
        userPayload: String,
        profile: ProviderProfile,
        apiKey: String,
        maximumResponseBytes: Int,
        requestTimeout: TimeInterval?,
        onTransportState: @escaping @Sendable (LLMTransportState) async -> Void,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String
}

/// Kept separate from completion so the Settings screen can use the same
/// fixture boundary as the analysis workflows.  A UI fixture must never turn
/// a model-discovery tap into a request to a real provider.
protocol ModelDiscovering: Sendable {
    /// `provider` belongs to the cache scope even if two profiles currently
    /// normalize to the same endpoint. A discovery result must not leak
    /// between independently configured provider profiles.
    func discoverModels(profile: ProviderProfile, provider: LLMProvider, apiKey: String) async throws -> [String]
}

/// A connection probe is intentionally distinct from model discovery in the
/// Settings UI.  It verifies the configured endpoint/credential policy but
/// does not publish a model list or alter discovery cache state.
struct ProviderConnectionProbe: Sendable, Equatable {
    let normalizedEndpoint: String
}

protocol ProviderConnectionTesting: Sendable {
    func testConnection(profile: ProviderProfile, provider: LLMProvider, apiKey: String) async throws -> ProviderConnectionProbe
}

struct VisionInputImage: Sendable {
    let figureKey: String
    let originalHash: String
    let mimeType: String
    let data: Data
    let originalPixelWidth: Int?
    let originalPixelHeight: Int?
    let resizedPixelWidth: Int?
    let resizedPixelHeight: Int?

    init(figureKey: String, originalHash: String, mimeType: String, data: Data,
         originalPixelWidth: Int? = nil, originalPixelHeight: Int? = nil,
         resizedPixelWidth: Int? = nil, resizedPixelHeight: Int? = nil) {
        self.figureKey = figureKey
        self.originalHash = originalHash
        self.mimeType = mimeType
        self.data = data
        self.originalPixelWidth = originalPixelWidth
        self.originalPixelHeight = originalPixelHeight
        self.resizedPixelWidth = resizedPixelWidth
        self.resizedPixelHeight = resizedPixelHeight
    }

    var byteCount: Int { data.count }
}

protocol VisionCompleting: Sendable {
    func completeVision(
        system: String,
        userPayload: String,
        images: [VisionInputImage],
        profile: ProviderProfile,
        apiKey: String,
        maximumResponseBytes: Int,
        onTransportState: @escaping @Sendable (LLMTransportState) async -> Void,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String
}

/// A credential belongs only to the endpoint whose URL passed local policy.
/// A redirect could change that endpoint, so it is rejected before any follow-up
/// request can carry an Authorization header.
private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private actor ModelDiscoveryCache {
    private struct Entry: Sendable { let values: [String]; let expiresAt: Date }
    private var entries: [String: Entry] = [:]

    func value(for key: String, now: Date = Date()) -> [String]? {
        guard let entry = entries[key], entry.expiresAt > now else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.values
    }

    func insert(_ values: [String], for key: String, now: Date = Date()) {
        entries[key] = Entry(values: values, expiresAt: now.addingTimeInterval(10 * 60))
    }
}

struct OpenAICompatibleSSEParser: Sendable {
    static let maximumLineBytes = 256 * 1024
    private var lineBuffer = Data()
    private var eventData: [Data] = []
    private var sawDone = false
    private var sawValidPayload = false

    mutating func consume(_ bytes: Data) throws -> [String] {
        var completed = [String]()
        for byte in bytes {
            lineBuffer.append(byte)
            guard lineBuffer.count <= Self.maximumLineBytes else { throw LLMClientError.malformedSSE }
            guard byte == 0x0A else { continue }
            var line = lineBuffer
            lineBuffer.removeAll(keepingCapacity: true)
            if line.last == 0x0A { line.removeLast() }
            if line.last == 0x0D { line.removeLast() }
            if line.isEmpty {
                completed += try finishEvent()
                continue
            }
            // SSE comments and event metadata are legal keep-alives.  They
            // are not model content and must neither reset the first-content
            // deadline nor be treated as malformed provider JSON.
            if line.first == 0x3A || line.starts(with: Data("event:".utf8)) ||
                line.starts(with: Data("id:".utf8)) || line.starts(with: Data("retry:".utf8)) {
                continue
            }
            guard line.starts(with: Data("data:".utf8)) else { throw LLMClientError.malformedSSE }
            var payload = line.dropFirst(5)
            if payload.first == 0x20 { payload = payload.dropFirst() }
            eventData.append(Data(payload))
        }
        return completed
    }

    /// Finish an SSE stream even when a compatible local server omits the
    /// optional `[DONE]` marker or the final blank dispatch line.  We only
    /// accept an EOF after at least one valid JSON payload; the workflow's
    /// strict schema validator still rejects truncated/incomplete JSON.
    mutating func finish() throws -> [String] {
        guard lineBuffer.isEmpty else { throw LLMClientError.malformedSSE }
        let trailing = try finishEvent()
        guard sawDone || sawValidPayload else { throw LLMClientError.malformedSSE }
        return trailing
    }

    private mutating func finishEvent() throws -> [String] {
        guard !eventData.isEmpty else { return [] }
        let payload = eventData.enumerated().reduce(into: Data()) { data, pair in
            if pair.offset > 0 { data.append(0x0A) }
            data.append(pair.element)
        }
        eventData.removeAll(keepingCapacity: true)
        if payload == Data("[DONE]".utf8) { sawDone = true; return [] }
        sawValidPayload = true
        return try OpenAICompatiblePayloadDecoder.textDeltas(from: payload)
    }
}

/// OpenAI-compatible servers do not all agree on the exact JSON type used for
/// streamed content.  In addition to the canonical `delta.content` string,
/// local Ollama/LM Studio builds and newer gateways may emit `choices[].text`
/// or a content-part array such as `[{'type':'text','text':'...'}]`.
private enum OpenAICompatiblePayloadDecoder {
    static func textDeltas(from data: Data) throws -> [String] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = root.objectValue else { throw LLMClientError.malformedSSE }
        if object["error"]?.objectValue != nil { throw LLMClientError.providerError }
        guard let choices = object["choices"]?.arrayValue else { return [] }
        return choices.compactMap { choice in
            guard let value = choice.objectValue else { return nil }
            let content = value["delta"]?.objectValue?["content"] ??
                value["message"]?.objectValue?["content"] ?? value["text"]
            return text(from: content)
        }
    }

    static func completionText(from data: Data) throws -> String {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = root.objectValue else {
            throw LLMClientError.invalidResponse
        }
        if object["error"]?.objectValue != nil { throw LLMClientError.providerError }
        guard let choices = object["choices"]?.arrayValue,
              let first = choices.first?.objectValue else { throw LLMClientError.invalidResponse }
        let content = first["message"]?.objectValue?["content"] ?? first["text"]
        guard let value = text(from: content), !value.isEmpty else { throw LLMClientError.invalidResponse }
        return value
    }

    private static func text(from value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let string = value.stringValue { return string }
        guard let parts = value.arrayValue else { return nil }
        let values = parts.compactMap { part -> String? in
            if let string = part.stringValue { return string }
            return part.objectValue?["text"]?.stringValue
        }
        return values.isEmpty ? nil : values.joined()
    }
}

struct OpenAICompatibleClient: Sendable, LLMCompleting, LLMRequestTimeoutConfiguring, VisionCompleting, ModelDiscovering, ProviderConnectionTesting {
    private let session: URLSession
    private static let modelCache = ModelDiscoveryCache()
    /// Used only when a caller explicitly requests an unbounded completion.
    /// Phase deadlines and user cancellation still bound the interactive
    /// workflow; this avoids URLSession cutting off a healthy long stream.
    private static let unboundedRequestTimeout: TimeInterval = 24 * 60 * 60

    init(session: URLSession? = nil) { self.session = session ?? Self.makeSafeSession() }

    func discoverModels(profile: ProviderProfile, provider: LLMProvider, apiKey: String) async throws -> [String] {
        let normalizedBaseURL = try APIEndpointBuilder.normalizedBaseURL(from: profile.baseURL, provider: provider)
        let url = try APIEndpointBuilder.endpoint(baseURL: profile.baseURL, path: "models", provider: provider)
        let cacheKey = "\(provider.rawValue)|\(normalizedBaseURL.absoluteString)|credential-revision:\(profile.discoveryCredentialRevision)"
        if let cached = await Self.modelCache.value(for: cacheKey) { return cached }
        var request = Self.authorizedRequest(url: url, apiKey: apiKey, provider: provider)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        guard data.count <= 2_000_000 else { throw LLMClientError.invalidResponse }
        struct Models: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        let models = Array(Set(try JSONDecoder().decode(Models.self, from: data).data.map(\.id)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })).sorted()
        await Self.modelCache.insert(models, for: cacheKey)
        return models
    }

    func testConnection(profile: ProviderProfile, provider: LLMProvider, apiKey: String) async throws -> ProviderConnectionProbe {
        let normalizedBaseURL = try APIEndpointBuilder.normalizedBaseURL(from: profile.baseURL, provider: provider)
        let url = try APIEndpointBuilder.endpoint(baseURL: profile.baseURL, path: "models", provider: provider)
        var request = Self.authorizedRequest(url: url, apiKey: apiKey, provider: provider)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        guard data.count <= 2_000_000 else { throw LLMClientError.invalidResponse }
        return ProviderConnectionProbe(normalizedEndpoint: normalizedBaseURL.absoluteString)
    }

    func complete(
        system: String,
        userPayload: String,
        profile: ProviderProfile,
        apiKey: String,
        maximumResponseBytes: Int = PaperInsightValidator.maximumResponseBytes,
        onTransportState: @escaping @Sendable (LLMTransportState) async -> Void = { _ in },
        onDelta: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> String {
        try await complete(system: system, userPayload: userPayload, profile: profile, apiKey: apiKey,
                           maximumResponseBytes: maximumResponseBytes,
                           requestTimeout: V4AnalysisTimeouts.default.hard,
                           onTransportState: onTransportState, onDelta: onDelta)
    }

    func complete(
        system: String,
        userPayload: String,
        profile: ProviderProfile,
        apiKey: String,
        maximumResponseBytes: Int,
        requestTimeout: TimeInterval?,
        onTransportState: @escaping @Sendable (LLMTransportState) async -> Void = { _ in },
        onDelta: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> String {
        guard !profile.effectiveModel.isEmpty else { throw LatticeLensError.missingCredential }
        guard !profile.provider.apiKeyIsRequired || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LatticeLensError.missingCredential }
        let url = try APIEndpointBuilder.endpoint(baseURL: profile.baseURL, path: "chat/completions", provider: profile.provider)
        struct Message: Codable { let role: String; let content: String }
        struct ResponseFormat: Codable { let type: String }
        struct RequestBody: Codable {
            let model: String
            let messages: [Message]
            let stream: Bool
            let responseFormat: ResponseFormat?

            enum CodingKeys: String, CodingKey {
                case model, messages, stream
                case responseFormat = "response_format"
            }
        }
        let body = RequestBody(model: profile.effectiveModel,
                               messages: [Message(role: "system", content: system), Message(role: "user", content: userPayload)],
                               stream: profile.usesStreaming,
                               // DeepSeek's documented OpenAI-compatible JSON
                               // mode asks the provider to emit an object, not
                               // a prose/fenced completion.  The app still
                               // runs its exact-root, duplicate-key, source
                               // scope, figure and numeric-anchor validators;
                               // JSON mode never turns an invalid claim into a
                               // successful artifact.  Custom/local providers
                               // keep their existing compatibility contract.
                               responseFormat: profile.provider == .deepSeek ? ResponseFormat(type: "json_object") : nil)
        var request = Self.authorizedRequest(url: url, apiKey: apiKey, provider: profile.provider)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout ?? Self.unboundedRequestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        if profile.usesStreaming {
            let (bytes, response) = try await session.bytes(for: request)
            try validateResponse(response)
            await onTransportState(.connected)
            await onTransportState(.waitingFirstContent)
            var parser = OpenAICompatibleSSEParser()
            var result = ""
            var responseBytes = 0
            var receivedFirstByte = false
            var lastActivityNotification = Date.distantPast
            var inputBuffer = Data()
            inputBuffer.reserveCapacity(16 * 1024)
            var lastParserFlush = Date()
            for try await byte in bytes {
                if !receivedFirstByte {
                    receivedFirstByte = true
                    await onTransportState(.receivedFirstContent)
                    lastActivityNotification = Date()
                } else if Date().timeIntervalSince(lastActivityNotification) >= 1 {
                    // SSE keep-alives/comments are transport activity even
                    // when they do not yield a decoded delta.  Feed a bounded
                    // heartbeat to the deadline monitor so a healthy stream
                    // is not misclassified as idle during long generations.
                    await onTransportState(.receivedFirstContent)
                    lastActivityNotification = Date()
                }
                inputBuffer.append(byte)
                // Feed the parser in blocks instead of allocating a Data
                // value for every network byte. This reduces CPU and actor
                // scheduling overhead for long formula derivations.
                let now = Date()
                if inputBuffer.count >= 16 * 1024 || now.timeIntervalSince(lastParserFlush) >= 0.1 {
                    let buffered = inputBuffer
                    inputBuffer.removeAll(keepingCapacity: true)
                    for delta in try parser.consume(buffered) {
                        responseBytes += delta.lengthOfBytes(using: .utf8)
                        guard responseBytes <= maximumResponseBytes else { throw LatticeLensError.schemaViolation("流式响应超过本地字节上限") }
                        result += delta
                        await onDelta(delta)
                    }
                    lastParserFlush = now
                }
            }
            if !inputBuffer.isEmpty {
                for delta in try parser.consume(inputBuffer) {
                    responseBytes += delta.lengthOfBytes(using: .utf8)
                    guard responseBytes <= maximumResponseBytes else { throw LatticeLensError.schemaViolation("流式响应超过本地字节上限") }
                    result += delta
                    await onDelta(delta)
                }
            }
            for delta in try parser.finish() {
                responseBytes += delta.lengthOfBytes(using: .utf8)
                guard responseBytes <= maximumResponseBytes else { throw LatticeLensError.schemaViolation("流式响应超过本地字节上限") }
                result += delta
                await onDelta(delta)
            }
            return result
        } else {
            // URLSession.data(for:) does not expose a first-byte boundary, so
            // use the same bounded byte stream as SSE.  The decoded JSON is
            // still delivered as one delta, but connect/first-content/idle
            // deadlines remain independently observable.
            let (bytes, response) = try await session.bytes(for: request)
            try validateResponse(response)
            await onTransportState(.connected)
            await onTransportState(.waitingFirstContent)
            var data = Data()
            var receivedFirstByte = false
            var lastActivityNotification = Date.distantPast
            for try await byte in bytes {
                if !receivedFirstByte {
                    receivedFirstByte = true
                    await onTransportState(.receivedFirstContent)
                    lastActivityNotification = Date()
                } else if Date().timeIntervalSince(lastActivityNotification) >= 1 {
                    await onTransportState(.receivedFirstContent)
                    lastActivityNotification = Date()
                }
                data.append(byte)
                guard data.count <= maximumResponseBytes else { throw LatticeLensError.schemaViolation("非流式响应超过本地字节上限") }
            }
            guard receivedFirstByte else { throw LLMClientError.invalidResponse }
            let content = try OpenAICompatiblePayloadDecoder.completionText(from: data)
            await onDelta(content)
            return content
        }
    }

    /// One explicit multimodal request. It is intentionally non-streaming:
    /// text streaming and image-pixel disclosure have separate failure and
    /// accounting semantics, and a failure here never overwrites text-only
    /// caption/full-text artifacts.
    func completeVision(
        system: String,
        userPayload: String,
        images: [VisionInputImage],
        profile: ProviderProfile,
        apiKey: String,
        maximumResponseBytes: Int = PaperInsightValidator.maximumResponseBytes,
        onTransportState: @escaping @Sendable (LLMTransportState) async -> Void = { _ in },
        onDelta: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> String {
        guard profile.supportsVision, !images.isEmpty else {
            throw LatticeLensError.schemaViolation("当前 provider profile 未经用户确认支持 vision，或没有可发送图像。")
        }
        guard !profile.effectiveModel.isEmpty else { throw LatticeLensError.missingCredential }
        guard !profile.provider.apiKeyIsRequired || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LatticeLensError.missingCredential }
        let url = try APIEndpointBuilder.endpoint(baseURL: profile.baseURL, path: "chat/completions", provider: profile.provider)
        let imageParts: [[String: Any]] = images.map {
            ["type": "image_url", "image_url": ["url": "data:\($0.mimeType);base64,\($0.data.base64EncodedString())", "detail": "low"]]
        }
        let userContent: [[String: Any]] = [["type": "text", "text": userPayload]] + imageParts
        let body: [String: Any] = [
            "model": profile.effectiveModel,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent]
            ]
        ]
        var request = Self.authorizedRequest(url: url, apiKey: apiKey, provider: profile.provider)
        request.httpMethod = "POST"
        request.timeoutInterval = V4AnalysisTimeouts.default.hard
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        await onTransportState(.waitingFirstContent)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        guard data.count <= maximumResponseBytes else { throw LatticeLensError.schemaViolation("vision 响应超过本地字节上限") }
        struct Completion: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }
            let choices: [Choice]
        }
        guard let content = try JSONDecoder().decode(Completion.self, from: data).choices.first?.message.content else {
            throw LLMClientError.invalidResponse
        }
        await onDelta(content)
        return content
    }

    /// Kept internal for contract tests.  The key is omitted, rather than sent
    /// as an empty Bearer value, for an explicit local no-key profile.
    static func authorizedRequest(url: URL, apiKey: String, provider: LLMProvider) -> URLRequest {
        var request = URLRequest(url: url)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw LLMClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if (300..<400).contains(http.statusCode) { throw LLMClientError.redirectRejected }
            throw LLMClientError.providerError
        }
    }

    private static func makeSafeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.unboundedRequestTimeout
        configuration.timeoutIntervalForResource = Self.unboundedRequestTimeout + 60
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: RedirectBlockingDelegate(), delegateQueue: nil)
    }
}
