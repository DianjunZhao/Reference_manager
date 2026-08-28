import Foundation

enum InsightWorkflowState: Equatable, Sendable {
    case idle
    case connecting
    case waitingFirstContent
    case receiving(characters: Int, bytes: Int)
    case validating
    case completed(cacheHit: Bool, requestCount: Int)
    case cancelled
    case failed(String)
}

actor InsightWorkflow {
    private let store: any LibraryStoring
    private let client: any LLMCompleting
    private let timeouts: V4AnalysisTimeouts

    init(store: any LibraryStoring, client: any LLMCompleting = OpenAICompatibleClient(),
         timeouts: V4AnalysisTimeouts = .default) {
        self.store = store
        self.client = client
        self.timeouts = timeouts
    }

    func generate(
        for paper: Paper,
        settings: LLMSettings,
        apiKey: String,
        onState: @escaping @Sendable (InsightWorkflowState) async -> Void
    ) async throws -> InsightArtifact {
        let profile = settings.activeProfile
        let baseURL = try APIEndpointBuilder.normalizedBaseURL(from: profile.baseURL, provider: profile.provider).absoluteString
        let source = InsightSourcePayload(paper: paper)
        let cacheKey = InsightCacheKey(paperID: paper.literatureID, paperUpdated: paper.updated,
                                      promptVersion: PaperInsightPrompt.version, insightSchemaVersion: ProductContract.insightSchemaVersion,
                                      sourceScope: ProductContract.sourceScope, provider: settings.activeProvider.rawValue,
                                      normalizedBaseURL: baseURL, model: profile.effectiveModel, credentialRevision: settings.credentialRevision, mode: settings.mode,
                                      detailLevel: settings.detailLevel,
                                      figureSetHash: StableHash.sha256(source.figures.map(\.key).sorted().joined(separator: "|")),
                                      maximumFigures: settings.maximumFigures,
                                      terminologyHash: StableHash.sha256(settings.terminology.map { "\($0.source)|\($0.preferredZH)|\($0.note)" }.sorted().joined(separator: "\n")),
                                      providerCapabilityHash: StableHash.sha256("stream=\(profile.usesStreaming)|vision=\(profile.supportsVision)"))
        if let cached = await store.snapshot().insights[cacheKey.value] {
            await onState(.completed(cacheHit: true, requestCount: 0))
            return cached
        }
        await onState(.connecting)
        let characterCounter = CharacterCounter()
        do {
            let receive: @Sendable (String) async -> Void = { delta in
                let received = await characterCounter.append(delta)
                await onState(.receiving(characters: received.characters, bytes: received.bytes))
            }
            let transport: @Sendable (LLMTransportState) async -> Void = { state in
                if state == .waitingFirstContent { await onState(.waitingFirstContent) }
            }
            if paper.preferredAbstract == nil {
                let titleRequest = try PaperInsightPrompt.titleTranslationPayload(source: source)
                let titleResponse = try await completeRequest(system: PaperInsightPrompt.titleTranslationSystemInstruction,
                                                              userPayload: titleRequest, profile: profile, apiKey: apiKey,
                                                              maximumResponseBytes: PaperInsightValidator.maximumResponseBytes,
                                                              onTransportState: transport, onDelta: receive)
                let titleZH = try PaperInsightPrompt.decodeTitleTranslation(Data(titleResponse.utf8))
                let insight = titleOnlyInsight(titleZH: titleZH)
                let artifact = InsightArtifact(cacheKey: cacheKey.value, paperID: paper.literatureID, insight: insight, createdAt: Date())
                try await store.save(insight: artifact)
                await onState(.completed(cacheHit: false, requestCount: 1))
                return artifact
            }
            let response: String
            let requestCount: Int
            if settings.mode == .deep {
                let translationRequest = try PaperInsightPrompt.translationPayload(source: source)
                let translationResponse = try await completeRequest(system: PaperInsightPrompt.translationSystemInstruction,
                                                                      userPayload: translationRequest, profile: profile, apiKey: apiKey,
                                                                      maximumResponseBytes: PaperInsightValidator.maximumResponseBytes,
                                                                      onTransportState: transport, onDelta: receive)
                let translation = try PaperInsightPrompt.decodeTranslation(Data(translationResponse.utf8))
                await onState(.connecting)
                let analysisRequest = try PaperInsightPrompt.userPayload(source: source, detail: settings.detailLevel,
                                                                          maximumFigures: settings.maximumFigures,
                                                                          terminology: settings.terminology, frozenTranslation: translation)
                response = try await completeRequest(system: PaperInsightPrompt.systemInstruction, userPayload: analysisRequest,
                                                     profile: profile, apiKey: apiKey,
                                                     maximumResponseBytes: PaperInsightValidator.maximumResponseBytes,
                                                     onTransportState: transport, onDelta: receive)
                requestCount = 2
            } else {
                let prompt = try PaperInsightPrompt.userPayload(source: source, detail: settings.detailLevel,
                                                                 maximumFigures: settings.maximumFigures,
                                                                 terminology: settings.terminology)
                response = try await completeRequest(system: PaperInsightPrompt.systemInstruction, userPayload: prompt,
                                                     profile: profile, apiKey: apiKey,
                                                     maximumResponseBytes: PaperInsightValidator.maximumResponseBytes,
                                                     onTransportState: transport, onDelta: receive)
                requestCount = 1
            }
            try Task.checkCancellation()
            await onState(.validating)
            let insight = try PaperInsightValidator.decode(Data(response.utf8), source: source, maximumFigures: settings.maximumFigures)
            let artifact = InsightArtifact(cacheKey: cacheKey.value, paperID: paper.literatureID, insight: insight, createdAt: Date())
            try await store.save(insight: artifact)
            await onState(.completed(cacheHit: false, requestCount: requestCount))
            return artifact
        } catch is CancellationError {
            await onState(.cancelled)
            throw LatticeLensError.cancelled
        } catch {
            await onState(.failed(error.localizedDescription))
            throw error
        }
    }

    private func titleOnlyInsight(titleZH: String) -> PaperInsightV1 {
        PaperInsightV1(
            schemaVersion: ProductContract.insightSchemaVersion,
            sourceScope: ProductContract.sourceScope,
            titleZH: titleZH,
            abstractZH: "原始 INSPIRE record 未提供摘要。",
            physics: InsightPhysics(
                researchQuestion: "原始 record 未提供摘要，无法可靠判定研究问题。",
                background: "仅完成标题翻译，未基于标题扩写物理背景。",
                methodAndDataFlow: [],
                mainResults: [],
                latticeConventionsReported: [],
                missingInformation: ["原始 record 未提供摘要；未生成物理解释。"],
                caveats: ["此结果只含标题翻译，不是摘要级或全文级论文解读。"]
            ),
            importantFigures: [],
            terminology: []
        )
    }

    /// Executes one and only one provider request.  Deadline errors propagate
    /// to the caller as a terminal run outcome; this function never retries or
    /// changes a streaming request into a non-streaming request.
    private func completeRequest(
        system: String,
        userPayload: String,
        profile: ProviderProfile,
        apiKey: String,
        maximumResponseBytes: Int,
        onTransportState: @escaping @Sendable (LLMTransportState) async -> Void,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let client = self.client
        return try await V4AnalysisDeadlineEnforcer.perform(
            timeouts: timeouts,
            maximumResponseBytes: maximumResponseBytes,
            onTransportState: onTransportState,
            onDelta: onDelta
        ) { transport, delta in
            try await client.complete(system: system, userPayload: userPayload, profile: profile, apiKey: apiKey,
                                      maximumResponseBytes: maximumResponseBytes, onTransportState: transport, onDelta: delta)
        }
    }
}

private actor CharacterCounter {
    private var value = 0

    private var bytes = 0

    func append(_ text: String) -> (characters: Int, bytes: Int) {
        value += text.count
        bytes += text.lengthOfBytes(using: .utf8)
        return (value, bytes)
    }
}
