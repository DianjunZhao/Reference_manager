import Foundation

/// v2 evidence analysis is separate from the v1 title/abstract artifact.  It
/// can run only after local full-text extraction produced retrievable anchors.
actor EvidenceInsightWorkflow {
    private let store: any LibraryStoring
    private let client: any LLMCompleting
    private let retriever: LocalEvidenceRetriever
    private let timeouts: V4AnalysisTimeouts?
    private let formulaJobs: any FormulaJobStoring

    init(
        store: any LibraryStoring,
        client: any LLMCompleting = OpenAICompatibleClient(),
        retriever: LocalEvidenceRetriever = LocalEvidenceRetriever(),
        timeouts: V4AnalysisTimeouts? = nil,
        formulaJobs: (any FormulaJobStoring)? = nil
    ) {
        self.store = store
        self.client = client
        self.retriever = retriever
        self.timeouts = timeouts
        self.formulaJobs = formulaJobs ?? (store as? any FormulaJobStoring) ?? InMemoryFormulaJobStore()
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
        guard source.numberedEquationCoverageComplete else {
            throw LatticeLensError.schemaViolation(
                source.numberedEquationCoverageFailure ?? "编号公式索引不完整；不会生成部分覆盖结果。"
            )
        }
        let profile = settings.activeProfile
        let payloadData = try JSONEncoder.latticeLens.encode(source)
        let baseURL = try APIEndpointBuilder.normalizedBaseURL(from: profile.baseURL, provider: profile.provider).absoluteString
        let key = EvidenceInsightCacheKey(
            paperID: paper.literatureID,
            paperUpdated: paper.updated,
            documentHash: retrieved.document.sha256,
            chunkIDs: source.chunks.map(\.id),
            promptVersion: "\(EvidenceInsightPrompt.version)|\(FormulaDerivationPrompt.version)|\(source.inventoryHash ?? "missing-inventory")",
            schemaVersion: PaperInsightV2Validator.schemaVersion,
            sourceScope: PaperInsightV2Validator.sourceScope,
            provider: settings.activeProvider.rawValue,
            normalizedBaseURL: baseURL,
            model: profile.effectiveModel,
            credentialRevision: settings.credentialRevision,
            mode: settings.mode,
            detailLevel: settings.detailLevel,
            maxOutputTokens: profile.maxOutputTokens,
            maximumFigures: settings.maximumFigures,
            terminologyHash: StableHash.sha256(settings.terminology.map { "\($0.source)|\($0.preferredZH)|\($0.note)" }.sorted().joined(separator: "\n")),
            providerCapabilityHash: StableHash.sha256("stream=\(profile.usesStreaming)|vision=\(profile.supportsVision)")
        )
        let publicationContext = EvidenceInsightPublicationContext(
            cacheKey: key.value,
            paperID: paper.literatureID,
            documentHash: retrieved.document.sha256,
            inventoryHash: source.inventoryHash ?? FormulaInventory.payloadHash(
                documentHash: source.documentHash, equations: source.numberedEquations
            ),
            sourcePayloadHash: StableHash.sha256(payloadData),
            provider: profile.provider.rawValue,
            providerProfileFingerprint: FormulaDerivationWorkflow.executionFingerprint(
                profile: profile, settingsFingerprint: settings.sessionFingerprint
            ),
            modelID: profile.effectiveModel,
            promptVersion: key.promptVersion,
            schemaVersion: PaperInsightV2Validator.schemaVersion,
            sourceScope: PaperInsightV2Validator.sourceScope
        )
        if let cached = context.evidenceInsights.first(where: { $0.cacheKey == key.value }) {
            if let publicationStore = formulaJobs as? any EvidenceInsightPublicationStoring {
                try? await publicationStore.removeReadyEvidenceInsightPublication(cacheKey: key.value)
            }
            await onState(.completed(cacheHit: true, requestCount: 0))
            return cached
        }

        guard let publicationStore = formulaJobs as? any EvidenceInsightPublicationStoring else {
            throw LatticeLensError.persistenceUnavailable(
                "当前公式作业存储不支持 ready-to-publish 持久化；为避免不可恢复的最终写入，不会发送 LLM 请求。"
            )
        }
        do {
            if let pending = try await publicationStore.readyEvidenceInsightPublication(cacheKey: key.value) {
                guard pending.context == publicationContext,
                      pending.hasConsistentIdentity,
                      pending.artifact.numberedEquationIDs == source.numberedEquations.map(\.equationID) else {
                    throw LatticeLensError.schemaViolation(
                        "待发布 evidence artifact 的 cache/source/inventory/model 上下文不匹配；已停止恢复且不会重发 provider 请求。"
                    )
                }
                try Task.checkCancellation()
                await onState(.validating)
                try await store.saveEvidenceInsight(pending.artifact)
                try? await publicationStore.removeReadyEvidenceInsightPublication(cacheKey: key.value)
                await onState(.completed(cacheHit: true, requestCount: 0))
                return pending.artifact
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
            let response: String
            let requestCount: Int
            let proseSource = source.proseOnly()
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
                let translation = try PaperInsightPrompt.decodeTranslation(
                    Data(translationResponse.utf8), sourceTitle: paper.displayTitle,
                    sourceAbstract: paper.preferredAbstract
                )
                await onState(.connecting)
                let payload = try EvidenceInsightPrompt.userPayload(
                    source: proseSource,
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
                    source: proseSource,
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
            let proseInsight = try PaperInsightV2Validator.decode(
                Data(response.utf8), source: proseSource, maximumFigures: settings.maximumFigures
            )
            let profile = settings.activeProfile
            let formulaExecutionFingerprint = FormulaDerivationWorkflow.executionFingerprint(
                profile: profile, settingsFingerprint: settings.sessionFingerprint
            )
            let formulaJobID = FormulaDerivationWorkflow.durableJobID(
                paperID: paper.literatureID,
                documentHash: source.documentHash,
                inventoryHash: source.inventoryHash ?? FormulaInventory.payloadHash(
                    documentHash: source.documentHash, equations: source.numberedEquations
                ),
                executionFingerprint: formulaExecutionFingerprint
            )
            let formula = try await FormulaDerivationWorkflow(client: client, store: formulaJobs, timeouts: timeouts)
                .run(source: source, profile: profile, apiKey: apiKey,
                     executionFingerprint: formulaExecutionFingerprint, jobID: formulaJobID) { progress in
                    await onState(.formulaProgress(completedBatches: progress.completedBatches,
                                                   totalBatches: progress.totalBatches,
                                                   bytes: progress.receivedBytes,
                                                   characters: progress.receivedCharacters))
                }
            let physics = InsightPhysicsV2(researchQuestion: proseInsight.physics.researchQuestion,
                                           methodAndDataFlow: proseInsight.physics.methodAndDataFlow,
                                           mainResults: proseInsight.physics.mainResults,
                                           reasonableInferences: proseInsight.physics.reasonableInferences,
                                           missingInformation: proseInsight.physics.missingInformation,
                                           caveats: proseInsight.physics.caveats,
                                           importantFormulaDerivations: formula.claims)
            let insight = PaperInsightV2(schemaVersion: proseInsight.schemaVersion,
                                         sourceScope: proseInsight.sourceScope,
                                         titleZH: proseInsight.titleZH,
                                         abstractZH: proseInsight.abstractZH,
                                         physics: physics,
                                         importantFigures: proseInsight.importantFigures,
                                         terminology: proseInsight.terminology)
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
                promptVersion: key.promptVersion,
                schemaVersion: PaperInsightV2Validator.schemaVersion,
                payloadHash: StableHash.sha256(payloadData),
                payloadByteCount: source.payloadByteCount,
                payloadScalarCount: source.payloadScalarCount,
                numberedEquationIDs: source.numberedEquations.map(\.equationID),
                numberedEquationCoverageComplete: source.numberedEquationCoverageComplete
            )
            let publication = ReadyEvidenceInsightPublication(context: publicationContext, artifact: artifact)
            guard publication.hasConsistentIdentity else {
                throw LatticeLensError.schemaViolation("completed evidence artifact failed ready-publication identity validation")
            }
            try await publicationStore.saveReadyEvidenceInsightPublication(publication)
            try await store.saveEvidenceInsight(artifact)
            try? await publicationStore.removeReadyEvidenceInsightPublication(cacheKey: key.value)
            await onState(.completed(cacheHit: false, requestCount: requestCount + formula.attemptedRequestsThisRun))
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
        let requestTimeouts: V4AnalysisTimeouts
        if let timeouts {
            requestTimeouts = timeouts
        } else {
            requestTimeouts = V4AnalysisTimeouts.evidence.usingHardTimeout(
                TimeInterval(profile.requestTimeoutSeconds))
        }
        let requestTimeout = requestTimeouts.hard
        return try await V4AnalysisDeadlineEnforcer.perform(
            timeouts: requestTimeouts,
            maximumResponseBytes: maximumResponseBytes,
            onTransportState: onTransportState,
            onDelta: onDelta
        ) { transport, delta in
            if let configurable = client as? any LLMRequestTimeoutConfiguring {
                // The job has no aggregate wall-clock deadline, but each
                // provider request receives a finite resource deadline.
                return try await configurable.complete(
                    system: system, userPayload: userPayload, profile: profile, apiKey: apiKey,
                    maximumResponseBytes: maximumResponseBytes, requestTimeout: requestTimeout,
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
