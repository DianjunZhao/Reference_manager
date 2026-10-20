import Foundation

enum LLMClientError: LocalizedError, Equatable, Sendable {
    case malformedSSE
    case invalidResponse
    case providerError
    case redirectRejected
    case outputLimitReached

    var errorDescription: String? {
        switch self {
        case .malformedSSE: "模型流式响应格式无效。"
        case .invalidResponse: "模型响应格式无效。"
        case .providerError: "模型服务拒绝了请求。"
        case .redirectRejected: "模型 endpoint 的重定向已被安全策略拒绝。"
        case .outputLimitReached:
            "模型返回 finish_reason=length：输出 token 上限或上下文长度已达到；不完整结果未保存，也未自动重试。可提高最大输出 token 数或缩短输入后重新生成。"
        }
    }
}

/// A transport diagnosis deliberately exposes only the configured origin's
/// host and effective port.  In particular, it never incorporates a request
/// URL, Authorization value, prompt, or provider response into UI text.
enum LLMTransportError: LocalizedError, Equatable, Sendable {
    case tlsHandshakeRejected(endpoint: String)

    var errorDescription: String? {
        switch self {
        case .tlsHandshakeRejected(let endpoint):
            "无法与模型服务 \(endpoint) 建立受信任的 TLS 连接；macOS 已拒绝证书或 TLS 协商。未自动重发任何全文证据。请在设置中使用“测试连接”，检查 API Base URL、系统时间及 VPN/代理的 HTTPS 证书；不要改为 HTTP 或关闭证书校验。"
        }
    }

    /// Leave all non-TLS errors unchanged.  A TLS failure happens before a
    /// valid response is available, so this is a diagnosis only—not a reason
    /// to relax trust evaluation or transparently submit the disclosure again.
    static func classify(_ error: Error, endpoint: URL) -> Error {
        guard let urlError = urlError(from: error), isTLSFailure(urlError.code) else { return error }
        return LLMTransportError.tlsHandshakeRejected(endpoint: endpointLabel(for: endpoint))
    }

    private static func urlError(from error: Error) -> URLError? {
        if let urlError = error as? URLError { return urlError }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return nil }
        return URLError(URLError.Code(rawValue: nsError.code))
    }

    private static func isTLSFailure(_ code: URLError.Code) -> Bool {
        switch code {
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            true
        default:
            false
        }
    }

    private static func endpointLabel(for endpoint: URL) -> String {
        guard let host = endpoint.host?.lowercased(), !host.isEmpty else { return "已配置 endpoint" }
        let port = endpoint.port ?? (endpoint.scheme?.lowercased() == "https" ? 443 : 0)
        return port > 0 ? "\(host):\(port)" : host
    }
}

enum LLMTransportState: String, Equatable, Sendable {
    /// HTTPS response headers have arrived from the configured origin.
    case connected
    /// The request is waiting for the first response-body byte.
    case waitingFirstContent
    /// A response-body byte or transport heartbeat arrived. This cannot satisfy
    /// the first-content deadline, but after the first decoded delta it refreshes
    /// the stream-idle deadline so active reasoning/keep-alives are not mistaken
    /// for a stalled transport.
    case receivedTransportActivity
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

/// Optional transport capability used to apply each workflow's finite
/// resource deadline to the URL request as well as its phase monitor.
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
        requestTimeout: TimeInterval,
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
enum OpenAICompatiblePayloadDecoder {
    static func textDeltas(from data: Data) throws -> [String] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = root.objectValue else { throw LLMClientError.malformedSSE }
        if object["error"]?.objectValue != nil { throw LLMClientError.providerError }
        guard let choices = object["choices"]?.arrayValue else { return [] }
        if choices.contains(where: { $0.objectValue?["finish_reason"]?.stringValue == "length" }) {
            throw LLMClientError.outputLimitReached
        }
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
        if first["finish_reason"]?.stringValue == "length" {
            throw LLMClientError.outputLimitReached
        }
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

/// The exact JSON body shared by request execution and formula-job planning.
/// Hashing this value binds a durable batch to the same model, mode and message
/// bytes that `URLSession` will send, without ever persisting an API key.
struct OpenAICompatibleCompletionRequestBody: Encodable, Sendable {
    /// Bump when request-body byte encoding changes so durable formula jobs
    /// cannot collide with checkpoints created under a different contract.
    static let serializationContractVersion = "openai-json-sorted-keys-v2-output-limit"

    struct Message: Encodable, Sendable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable, Sendable {
        let type: String
    }

    let model: String
    let messages: [Message]
    let stream: Bool
    let maxTokens: Int?
    let maxCompletionTokens: Int?
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case responseFormat = "response_format"
    }

    init(system: String, userPayload: String, profile: ProviderProfile) {
        model = profile.effectiveModel
        messages = [Message(role: "system", content: system), Message(role: "user", content: userPayload)]
        stream = profile.usesStreaming
        if profile.provider == .openAI {
            maxTokens = nil
            maxCompletionTokens = profile.maxOutputTokens
        } else {
            maxTokens = profile.maxOutputTokens
            maxCompletionTokens = nil
        }
        // Keep this in sync with the provider-specific JSON-mode contract used
        // by OpenAICompatibleClient.complete.
        responseFormat = profile.provider == .deepSeek ? ResponseFormat(type: "json_object") : nil
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

struct OpenAICompatibleClient: Sendable, LLMCompleting, LLMRequestTimeoutConfiguring, VisionCompleting, ModelDiscovering, ProviderConnectionTesting {
    private let session: URLSession
    private static let modelCache = ModelDiscoveryCache()
    /// Used only when a caller explicitly requests an unbounded completion.
    /// Phase deadlines and user cancellation still bound the interactive
    /// workflow; this avoids URLSession cutting off a healthy long stream.
    private static let defaultRequestTimeout = V4AnalysisTimeouts.default.hard
    static let urlSessionTimeoutGraceSeconds: TimeInterval = 60
    static let maximumURLSessionRequestTimeout: TimeInterval =
        TimeInterval(ProviderProfile.maximumRequestTimeoutSeconds) + urlSessionTimeoutGraceSeconds

    init(session: URLSession? = nil) { self.session = session ?? Self.makeSafeSession() }

    func discoverModels(profile: ProviderProfile, provider: LLMProvider, apiKey: String) async throws -> [String] {
        let normalizedBaseURL = try APIEndpointBuilder.normalizedBaseURL(from: profile.baseURL, provider: provider)
        let url = try APIEndpointBuilder.endpoint(baseURL: profile.baseURL, path: "models", provider: provider)
        let cacheKey = "\(provider.rawValue)|\(normalizedBaseURL.absoluteString)|credential-revision:\(profile.discoveryCredentialRevision)"
        if let cached = await Self.modelCache.value(for: cacheKey) { return cached }
        var request = Self.authorizedRequest(url: url, apiKey: apiKey, provider: provider)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMTransportError.classify(error, endpoint: url)
        }
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
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMTransportError.classify(error, endpoint: url)
        }
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
        var request = Self.authorizedRequest(url: url, apiKey: apiKey, provider: profile.provider)
        request.httpMethod = "POST"
        let boundedRequestTimeout = Self.boundedHardTimeout(requestTimeout)
        // URLRequest.timeoutInterval is an inactivity bound. The workflow's
        // connect/first-content/idle/hard monitor remains authoritative; leave
        // a small transport grace so URLSession cannot win the race at the
        // exact application deadline.
        request.timeoutInterval = min(boundedRequestTimeout + Self.urlSessionTimeoutGraceSeconds,
                                      Self.maximumURLSessionRequestTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try OpenAICompatibleCompletionRequestBody(
            system: system, userPayload: userPayload, profile: profile
        ).encoded()
        do {
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
                    await onTransportState(.receivedTransportActivity)
                    lastActivityNotification = Date()
                } else if Date().timeIntervalSince(lastActivityNotification) >= 1 {
                    // SSE keep-alives/comments are transport activity even
                    // when they do not yield a decoded delta.  Feed a bounded
                    // heartbeat to the deadline monitor so a healthy stream
                    // is not misclassified as idle during long generations.
                    await onTransportState(.receivedTransportActivity)
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
                    if let delta = try Self.appendDeltas(parser.consume(buffered), to: &result,
                                                         responseBytes: &responseBytes,
                                                         maximumResponseBytes: maximumResponseBytes) {
                        await onDelta(delta)
                    }
                    lastParserFlush = now
                }
            }
            if !inputBuffer.isEmpty {
                if let delta = try Self.appendDeltas(parser.consume(inputBuffer), to: &result,
                                                     responseBytes: &responseBytes,
                                                     maximumResponseBytes: maximumResponseBytes) {
                    await onDelta(delta)
                }
            }
            if let delta = try Self.appendDeltas(parser.finish(), to: &result,
                                                 responseBytes: &responseBytes,
                                                 maximumResponseBytes: maximumResponseBytes) {
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
                    await onTransportState(.receivedTransportActivity)
                    lastActivityNotification = Date()
                } else if Date().timeIntervalSince(lastActivityNotification) >= 1 {
                    await onTransportState(.receivedTransportActivity)
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
        } catch {
            throw LLMTransportError.classify(error, endpoint: url)
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
        requestTimeout: TimeInterval = V4AnalysisTimeouts.default.hard,
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
        let boundedRequestTimeout = Self.boundedHardTimeout(requestTimeout)
        request.timeoutInterval = min(boundedRequestTimeout + Self.urlSessionTimeoutGraceSeconds,
                                      Self.maximumURLSessionRequestTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        await onTransportState(.waitingFirstContent)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMTransportError.classify(error, endpoint: url)
        }
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

    private static func boundedHardTimeout(_ requested: TimeInterval?) -> TimeInterval {
        guard let requested, requested.isFinite, requested > 0 else {
            return min(Self.defaultRequestTimeout, TimeInterval(ProviderProfile.maximumRequestTimeoutSeconds))
        }
        return min(requested, TimeInterval(ProviderProfile.maximumRequestTimeoutSeconds))
    }

    /// Combines parser output from one bounded input block into one workflow
    /// update. The assembled response and byte-limit semantics are unchanged;
    /// only redundant actor/MainActor hops for adjacent SSE events are removed.
    private static func appendDeltas(_ deltas: [String], to result: inout String,
                                     responseBytes: inout Int,
                                     maximumResponseBytes: Int) throws -> String? {
        guard !deltas.isEmpty else { return nil }
        let combined = deltas.joined()
        let (nextByteCount, overflow) = responseBytes.addingReportingOverflow(combined.utf8.count)
        guard !overflow, nextByteCount <= maximumResponseBytes else {
            throw LatticeLensError.schemaViolation("流式响应超过本地字节上限")
        }
        responseBytes = nextByteCount
        result += combined
        return combined
    }

    static func safeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        // The app's per-request hard limit is at most 3,600 s. Give both
        // URLSession timers a grace margin so they cannot truncate a stream
        // before that deadline; the app's phase/idle monitors remain tighter.
        configuration.timeoutIntervalForRequest = Self.maximumURLSessionRequestTimeout
        configuration.timeoutIntervalForResource = Self.maximumURLSessionRequestTimeout
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    private static func makeSafeSession() -> URLSession {
        URLSession(configuration: Self.safeSessionConfiguration(), delegate: RedirectBlockingDelegate(), delegateQueue: nil)
    }
}
