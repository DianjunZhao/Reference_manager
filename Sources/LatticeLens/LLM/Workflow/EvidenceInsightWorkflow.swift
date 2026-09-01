import Foundation

/// v2 evidence analysis is separate from the v1 title/abstract artifact.  It
/// can run only after local full-text extraction produced retrievable anchors.
actor EvidenceInsightWorkflow {
    private let store: any LibraryStoring
    private let client: any LLMCompleting
    private let retriever: LocalEvidenceRetriever
    private let timeouts: V4AnalysisTimeouts

    init(
        store: any LibraryStoring,
        client: any LLMCompleting = OpenAICompatibleClient(),
        retriever: LocalEvidenceRetriever = LocalEvidenceRetriever(),
        timeouts: V4AnalysisTimeouts = .evidence
    ) {
        self.store = store
        self.client = client
        self.retriever = retriever
        self.timeouts = timeouts
    }

    func generate(
        for paper: Paper,
        settings: LLMSettings,
        apiKey: String,
        onState: @escaping @Sendable (InsightWorkflowState) async -> Void
    ) async throws -> EvidenceInsightArtifact {
        // Evidence generation is an interactive, single-paper action. Do not
        // decode the complete V8/V9 repository here: a large library can make
        // the button appear frozen before the first state callback is emitted.
        let context = await store.paperContext(paperID: paper.literatureID, insightCacheKey: nil)
        guard let retrieved = retriever.retrieve(paper: paper, context: context) else {
            throw LatticeLensError.schemaViolation("尚无可回查的本地全文 anchors；请先读取 ar5iv HTML（或使用 PDF 回退）并提取全文。")
        }
        let source = EvidenceInputPayload(
            paper: paper,
            document: retrieved.document,
            chunks: retrieved.chunks,
            anchors: retrieved.anchors
        )
        guard !source.chunks.isEmpty, !source.anchors.isEmpty else {
            throw LatticeLensError.schemaViolation("全文检索没有产生可发送的受限 evidence payload。")
        }
        let profile = settings.activeProfile
        let payloadData = try JSONEncoder.latticeLens.encode(source)
        let baseURL = try APIEndpointBuilder.normalizedBaseURL(from: profile.baseURL, provider: profile.provider).absoluteString
        let key = EvidenceInsightCacheKey(
            paperID: paper.literatureID,
            paperUpdated: paper.updated,
            documentHash: retrieved.document.sha256,
            chunkIDs: source.chunks.map(\.id),
            promptVersion: EvidenceInsightPrompt.version,
            schemaVersion: PaperInsightV2Validator.schemaVersion,
            sourceScope: PaperInsightV2Validator.sourceScope,
            provider: settings.activeProvider.rawValue,
            normalizedBaseURL: baseURL,
            model: profile.effectiveModel,
            credentialRevision: settings.credentialRevision,
            mode: settings.mode,
            detailLevel: settings.detailLevel,
            maximumFigures: settings.maximumFigures,
            terminologyHash: StableHash.sha256(settings.terminology.map { "\($0.source)|\($0.preferredZH)|\($0.note)" }.sorted().joined(separator: "\n")),
            providerCapabilityHash: StableHash.sha256("stream=\(profile.usesStreaming)|vision=\(profile.supportsVision)")
        )
        if let cached = context.evidenceInsights.first(where: { $0.cacheKey == key.value }) {
            await onState(.completed(cacheHit: true, requestCount: 0))
            return cached
        }

        await onState(.connecting)
        let counter = EvidenceCharacterCounter()
        let receive: @Sendable (String) async -> Void = { delta in
            // Coalesce UI updates to at most ~4 per second.  The transport
            // still accumulates every delta, but avoiding one MainActor update
            // per token materially reduces back-pressure on slow streams.
            if let progress = await counter.append(delta) {
                await onState(.receiving(characters: progress.characters, bytes: progress.bytes))
            }
        }
        let transport: @Sendable (LLMTransportState) async -> Void = { state in
            if state == .waitingFirstContent { await onState(.waitingFirstContent) }
        }
        do {
            let response: String
            let requestCount: Int
            if settings.mode == .deep, paper.preferredAbstract != nil {
                let translationPayload = try PaperInsightPrompt.translationPayload(source: InsightSourcePayload(paper: paper))
                let translationResponse = try await completeRequest(
                    system: PaperInsightPrompt.translationSystemInstruction,
                    userPayload: translationPayload,
                    profile: profile,
                    apiKey: apiKey,
                    maximumResponseBytes: PaperInsightValidator.maximumResponseBytes,
                    onTransportState: transport,
                    onDelta: receive
                )
                let translation = try PaperInsightPrompt.decodeTranslation(Data(translationResponse.utf8))
                await onState(.connecting)
                let payload = try EvidenceInsightPrompt.userPayload(
                    source: source,
                    detail: settings.detailLevel,
                    maximumFigures: settings.maximumFigures,
                    terminology: settings.terminology,
                    frozenTranslation: translation
                )
                response = try await completeRequest(
                    system: EvidenceInsightPrompt.systemInstruction,
                    userPayload: payload,
                    profile: profile,
                    apiKey: apiKey,
                    maximumResponseBytes: PaperInsightValidator.maximumResponseBytes,
                    onTransportState: transport,
                    onDelta: receive
                )
                requestCount = 2
            } else {
                let payload = try EvidenceInsightPrompt.userPayload(
                    source: source,
                    detail: settings.detailLevel,
                    maximumFigures: settings.maximumFigures,
                    terminology: settings.terminology
                )
                response = try await completeRequest(
                    system: EvidenceInsightPrompt.systemInstruction,
                    userPayload: payload,
                    profile: profile,
                    apiKey: apiKey,
                    maximumResponseBytes: PaperInsightValidator.maximumResponseBytes,
                    onTransportState: transport,
                    onDelta: receive
                )
                requestCount = 1
            }
            try Task.checkCancellation()
            if let progress = await counter.flush() {
                await onState(.receiving(characters: progress.characters, bytes: progress.bytes))
            }
            await onState(.validating)
            let insight = try PaperInsightV2Validator.decode(
                Data(response.utf8), source: source, maximumFigures: settings.maximumFigures
            )
            let artifact = EvidenceInsightArtifact(
                cacheKey: key.value,
                paperID: paper.literatureID,
                documentHash: retrieved.document.sha256,
                chunkIDs: source.chunks.map(\.id),
                insight: insight,
                createdAt: Date(),
                retrievalQuery: source.retrievalQuery,
                rankerVersion: source.rankerVersion,
                selectedChunkIDs: source.chunks.map(\.id),
                promptVersion: EvidenceInsightPrompt.version,
                schemaVersion: PaperInsightV2Validator.schemaVersion,
                payloadHash: StableHash.sha256(payloadData),
                payloadByteCount: source.payloadByteCount,
                payloadScalarCount: source.payloadScalarCount
            )
            try await store.saveEvidenceInsight(artifact)
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

    /// Evidence snippets disclose local PDF-derived text.  They therefore use
    /// the same phase-specific deadline and no-retry contract as the title /
    /// abstract workflow: a timeout never creates an implicit second POST or
    /// silently changes a streaming request into a different transport.
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
            if let configurable = client as? any LLMRequestTimeoutConfiguring {
                // A nil request timeout is deliberate: Evidence has no total
                // application deadline. The enforcer still applies finite
                // connect/first-content/idle phases and user cancellation.
                return try await configurable.complete(
                    system: system, userPayload: userPayload, profile: profile, apiKey: apiKey,
                    maximumResponseBytes: maximumResponseBytes, requestTimeout: nil,
                    onTransportState: transport, onDelta: delta
                )
            }
            return try await client.complete(system: system, userPayload: userPayload, profile: profile, apiKey: apiKey,
                                             maximumResponseBytes: maximumResponseBytes,
                                             onTransportState: transport, onDelta: delta)
        }
    }
}

private struct EvidenceProgress: Sendable {
    let characters: Int
    let bytes: Int
}

private actor EvidenceCharacterCounter {
    private var characters = 0
    private var bytes = 0
    private var lastPublishedAt = Date.distantPast

    func append(_ text: String) -> EvidenceProgress? {
        characters += text.count
        bytes += text.lengthOfBytes(using: .utf8)
        let now = Date()
        guard now.timeIntervalSince(lastPublishedAt) >= 0.25 else { return nil }
        lastPublishedAt = now
        return EvidenceProgress(characters: characters, bytes: bytes)
    }

    func flush() -> EvidenceProgress? {
        guard characters > 0 else { return nil }
        lastPublishedAt = Date()
        return EvidenceProgress(characters: characters, bytes: bytes)
    }
}
