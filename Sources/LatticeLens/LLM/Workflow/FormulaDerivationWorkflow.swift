import Foundation

/// Durable boundary for formula jobs. Production can back this with SwiftData;
/// tests use the actor below. Each update contains completed batch claims, so a
/// relaunch resumes only missing/retryable batches and never resends successes.
protocol FormulaJobStoring: Sendable {
    func formulaJob(id: String) async throws -> FormulaDerivationCheckpoint?
    func saveFormulaJob(_ checkpoint: FormulaDerivationCheckpoint) async throws
    func saveFormulaJobWithValidation(_ checkpoint: FormulaDerivationCheckpoint,
                                     report: FormulaCoverageReport) async throws
    func formulaValidationReport(jobID: String) async throws -> FormulaCoverageReport?
}

/// Stores a completed evidence artifact between validation and publication so
/// a failed final library write can resume without repeating provider calls.
protocol EvidenceInsightPublicationStoring: FormulaJobStoring {
    func readyEvidenceInsightPublication(cacheKey: String) async throws -> ReadyEvidenceInsightPublication?
    func saveReadyEvidenceInsightPublication(_ publication: ReadyEvidenceInsightPublication) async throws
    func removeReadyEvidenceInsightPublication(cacheKey: String) async throws
}

actor InMemoryFormulaJobStore: EvidenceInsightPublicationStoring {
    private var jobs: [String: FormulaDerivationCheckpoint] = [:]
    private var validationReports: [String: FormulaCoverageReport] = [:]
    private var readyEvidencePublications: [String: ReadyEvidenceInsightPublication] = [:]

    func formulaJob(id: String) -> FormulaDerivationCheckpoint? { jobs[id] }
    func saveFormulaJob(_ checkpoint: FormulaDerivationCheckpoint) {
        jobs[checkpoint.job.jobID] = checkpoint
        if checkpoint.job.state != .complete { validationReports.removeValue(forKey: checkpoint.job.jobID) }
    }

    func saveFormulaJobWithValidation(_ checkpoint: FormulaDerivationCheckpoint,
                                      report: FormulaCoverageReport) {
        jobs[checkpoint.job.jobID] = checkpoint
        validationReports[checkpoint.job.jobID] = report
    }

    func formulaValidationReport(jobID: String) -> FormulaCoverageReport? { validationReports[jobID] }

    func readyEvidenceInsightPublication(cacheKey: String) -> ReadyEvidenceInsightPublication? {
        readyEvidencePublications[cacheKey]
    }

    func readyEvidenceInsightPublicationsForTesting() -> [ReadyEvidenceInsightPublication] {
        readyEvidencePublications.values.sorted { $0.context.cacheKey < $1.context.cacheKey }
    }

    func saveReadyEvidenceInsightPublication(_ publication: ReadyEvidenceInsightPublication) throws {
        guard publication.hasConsistentIdentity else {
            throw LatticeLensError.persistenceUnavailable("ready evidence publication identity/hash mismatch")
        }
        readyEvidencePublications[publication.context.cacheKey] = publication
    }

    func removeReadyEvidenceInsightPublication(cacheKey: String) {
        readyEvidencePublications.removeValue(forKey: cacheKey)
    }
}

struct FormulaDerivationCheckpoint: Codable, Hashable, Sendable, Identifiable {
    var job: FormulaDerivationJob
    var completedClaimsByBatch: [Int: [EvidenceClaim]]
    /// Formula/equation-keyed append-only continuation state. Optional to
    /// decode older checkpoints; old prompt versions are rejected for reuse.
    var derivationSegmentsByEquation: [String: FormulaDerivationSegmentCheckpoint]? = nil
    var promptVersion: String
    var schemaVersion: String
    /// Non-secret frozen execution identity. Older checkpoints decode as nil
    /// and are rejected for reuse rather than being attributed to today's
    /// provider/model/settings.
    var contextFingerprint: String? = nil
    var updatedAt: Date
    var id: String { job.jobID }
}

struct FormulaDerivationProgress: Sendable, Equatable {
    let jobID: String
    let state: FormulaJobState
    let completedBatches: Int
    let totalBatches: Int
    let activeBatch: Int?
    let receivedBytes: Int
    let receivedCharacters: Int
    let message: String?
}

struct FormulaDerivationResult: Sendable {
    let job: FormulaDerivationJob
    let claims: [EvidenceClaim]
    let coverage: FormulaCoverageReport
    let attemptedRequestsThisRun: Int
    let reusedValidatedBatches: Int
}

enum FormulaDerivationWorkflowError: LocalizedError {
    case staleCheckpoint
    case notResumable

    var errorDescription: String? {
        switch self {
        case .staleCheckpoint: "公式作业的文档、inventory、provider 或分析设置已变化；旧 checkpoint 不可复用。"
        case .notResumable: "公式作业状态不允许继续。"
        }
    }
}

/// Runs finite, independently validated requests. The job itself has no
/// deadline: a failed request preserves earlier batches and is resumable.
actor FormulaDerivationWorkflow {
    private let client: any LLMCompleting
    private let store: any FormulaJobStoring
    private let timeouts: V4AnalysisTimeouts

    init(client: any LLMCompleting = OpenAICompatibleClient(),
         store: any FormulaJobStoring = InMemoryFormulaJobStore(),
         timeouts: V4AnalysisTimeouts = .default) {
        self.client = client
        self.store = store
        self.timeouts = timeouts
    }

    /// Stable across app launches so an interrupted Evidence action can load
    /// the same durable SwiftData checkpoint when the user retries it. The
    /// contract versions are part of identity: incompatible work is never
    /// silently resumed under a new prompt, schema, or request-body encoding.
    nonisolated static func executionFingerprint(profile: ProviderProfile, settingsFingerprint: String? = nil) -> String {
        let endpoint = (try? APIEndpointBuilder.normalizedBaseURL(from: profile.baseURL,
                                                                   provider: profile.provider).absoluteString)
            ?? profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return StableHash.sha256([
            profile.provider.rawValue, endpoint, profile.effectiveModel,
            String(profile.usesStreaming), String(profile.supportsVision),
            String(profile.discoveryCredentialRevision),
            OpenAICompatibleCompletionRequestBody.serializationContractVersion,
            settingsFingerprint ?? ""
        ].joined(separator: "|"))
    }

    nonisolated static func durableJobID(paperID: Int, documentHash: String, inventoryHash: String,
                                         promptVersion: String = FormulaDerivationPrompt.version,
                                         schemaVersion: String = PaperInsightV2Validator.schemaVersion,
                                         executionFingerprint: String = "") -> String {
        let identity = [String(paperID), documentHash, inventoryHash, promptVersion, schemaVersion,
                        executionFingerprint]
            .joined(separator: "|")
        return "formula-\(paperID)-\(StableHash.sha256(identity))"
    }

    func run(source: EvidenceInputPayload, profile: ProviderProfile, apiKey: String,
             executionFingerprint: String? = nil,
             jobID: String? = nil, batchSize: Int = FormulaBatchPlanner.defaultBatchSize,
             onProgress: @escaping @Sendable (FormulaDerivationProgress) async -> Void = { _ in }) async throws -> FormulaDerivationResult {
        guard source.documentSourceKind == .arxivHTML,
              source.numberedEquationCoverageComplete,
              source.numberedEquations.count <= EvidenceInputPayload.maximumNumberedEquations else {
            throw LatticeLensError.schemaViolation(source.numberedEquationCoverageFailure ?? "公式工作流只接受完整且有界的 ar5iv inventory。")
        }
        try Task.checkCancellation()
        let identity = source.inventoryHash ?? FormulaInventory.payloadHash(documentHash: source.documentHash, equations: source.numberedEquations)
        let selectedExecutionFingerprint = executionFingerprint ?? Self.executionFingerprint(profile: profile)
        let selectedJobID = jobID ?? Self.durableJobID(paperID: source.paperID,
            documentHash: source.documentHash, inventoryHash: identity,
            executionFingerprint: selectedExecutionFingerprint)
        let batches = try FormulaBatchPlanner.plan(source: source, jobID: selectedJobID,
                                                   batchSize: batchSize, profile: profile)
        let inventory = FormulaInventory(documentHash: source.documentHash,
                                         items: source.numberedEquations.enumerated().map { index, equation in
            FormulaInventoryItem(equationID: equation.equationID, label: equation.label, sourceTeX: equation.tex,
                                 ordinal: index + 1, documentHash: source.documentHash, evidenceID: equation.evidenceID)
        }, declaredInventoryHash: identity)
        let anchors = Dictionary(uniqueKeysWithValues: source.anchors.map { ($0.id, $0) })
        var checkpoint: FormulaDerivationCheckpoint
        if let existing = try await store.formulaJob(id: selectedJobID) {
            guard existing.job.documentHash == source.documentHash,
                  existing.job.inventoryHash == identity,
                  existing.job.equationIDs == source.numberedEquations.map(\.equationID),
                  existing.promptVersion == FormulaDerivationPrompt.version,
                  existing.schemaVersion == PaperInsightV2Validator.schemaVersion,
                  existing.contextFingerprint == selectedExecutionFingerprint,
                  existing.job.batches.count == batches.count,
                  zip(existing.job.batches, batches).allSatisfy({ $0.payloadHash == $1.payloadHash && $0.equationIDs == $1.equationIDs }) else {
                throw FormulaDerivationWorkflowError.staleCheckpoint
            }
            let validBatchIndices = Set(batches.map(\.index))
            guard Set(existing.completedClaimsByBatch.keys).isSubset(of: validBatchIndices) else {
                throw FormulaDerivationWorkflowError.staleCheckpoint
            }
            let savedSegments = existing.derivationSegmentsByEquation ?? [:]
            guard Set(savedSegments.keys).isSubset(of: Set(existing.job.equationIDs)) else {
                throw FormulaDerivationWorkflowError.staleCheckpoint
            }
            for (equationID, savedSegment) in savedSegments {
                guard savedSegment.equationID == equationID,
                      inventory.items.first(where: { $0.equationID == equationID })?.sourceTeX == savedSegment.sourceTeX,
                      (try? savedSegment.validatedCopy()) == savedSegment else {
                    throw FormulaDerivationWorkflowError.staleCheckpoint
                }
            }
            for batch in batches {
                let savedBatch = existing.job.batches[batch.index]
                let savedClaims = existing.completedClaimsByBatch[batch.index]
                let savedEquationSegments = batch.equationIDs.compactMap { savedSegments[$0] }
                guard savedEquationSegments.isEmpty || savedEquationSegments.count == batch.equationIDs.count else {
                    throw FormulaDerivationWorkflowError.staleCheckpoint
                }
                if savedBatch.status == .completed {
                    guard let savedClaims,
                          Self.completedBatchClaimsAreValid(savedClaims, equationIDs: batch.equationIDs,
                                                            inventory: inventory, anchors: anchors),
                          savedEquationSegments.count == batch.equationIDs.count,
                          savedEquationSegments.allSatisfy(\.isComplete) else {
                        throw FormulaDerivationWorkflowError.staleCheckpoint
                    }
                } else if savedClaims != nil {
                    // Claims without a completed checkpoint row are ambiguous:
                    // do not silently reuse them or overwrite them with a retry.
                    throw FormulaDerivationWorkflowError.staleCheckpoint
                }
            }
            if existing.job.state == .complete {
                let expectedBatchIndices = Set(batches.map(\.index))
                guard existing.job.isComplete,
                      Set(existing.completedClaimsByBatch.keys) == expectedBatchIndices,
                      batches.allSatisfy({ batch in
                          existing.job.batches[batch.index].status == .completed &&
                          existing.completedClaimsByBatch[batch.index] != nil &&
                          batch.equationIDs.allSatisfy { savedSegments[$0]?.isComplete == true }
                      }) else {
                    throw FormulaDerivationWorkflowError.staleCheckpoint
                }
                let completeClaims = batches.sorted { $0.index < $1.index }
                    .flatMap { existing.completedClaimsByBatch[$0.index] ?? [] }
                do {
                    _ = try FormulaCoverageValidator.validate(inventory: inventory, claims: completeClaims, anchors: anchors)
                } catch {
                    throw FormulaDerivationWorkflowError.staleCheckpoint
                }
            }
            guard [.prepared, .queued, .running, .validating, .retryable, .paused, .cancelled, .incomplete, .complete].contains(existing.job.state) else {
                throw FormulaDerivationWorkflowError.notResumable
            }
            checkpoint = existing
        } else {
            let now = Date()
            let batchCheckpoints = batches.map {
                FormulaBatchCheckpoint(jobID: selectedJobID, batchIndex: $0.index, batchTotal: $0.total,
                                       equationIDs: $0.equationIDs, payloadHash: $0.payloadHash)
            }
            let job = FormulaDerivationJob(jobID: selectedJobID, paperID: source.paperID,
                                           documentHash: source.documentHash, inventoryHash: identity,
                                           equationIDs: source.numberedEquations.map(\.equationID),
                                           batchSize: batchSize, state: .queued, batches: batchCheckpoints,
                                           startedAt: now, updatedAt: now)
            checkpoint = FormulaDerivationCheckpoint(job: job, completedClaimsByBatch: [:],
                                                     derivationSegmentsByEquation: [:],
                                                     promptVersion: FormulaDerivationPrompt.version,
                                                     schemaVersion: PaperInsightV2Validator.schemaVersion,
                                                     contextFingerprint: selectedExecutionFingerprint,
                                                     updatedAt: now)
        }
        if checkpoint.job.state != .complete {
            checkpoint.job.state = .running
            try await persist(checkpoint)
        }

        var attemptedRequestsThisRun = 0
        var reusedValidatedBatches = 0
        for batch in batches {
            try Task.checkCancellation()
            if checkpoint.job.batches[batch.index].status == .completed,
               checkpoint.completedClaimsByBatch[batch.index] != nil {
                reusedValidatedBatches += 1
                continue
            }
            var batchState = checkpoint.job.batches[batch.index]
            batchState.status = .running
            batchState.errorCategory = nil
            checkpoint.job.batches[batch.index] = batchState
            checkpoint.job.updatedAt = Date()
            try await persist(checkpoint)
            await publish(checkpoint, activeBatch: batch.index, message: "正在准备公式批次 \(batch.index + 1)/\(batch.total)", onProgress: onProgress)

            do {
                var segmentStates = checkpoint.derivationSegmentsByEquation ?? [:]
                let savedForBatch = batch.equationIDs.compactMap { segmentStates[$0] }
                guard savedForBatch.isEmpty || savedForBatch.count == batch.equationIDs.count else {
                    throw FormulaDerivationWorkflowError.staleCheckpoint
                }

                if savedForBatch.isEmpty {
                    let batchSource = try source.batch(for: batch.equationIDs, index: batch.index, total: batch.total)
                    let expectations = try Self.initialSegmentExpectations(for: batchSource)
                    let prepared = try prepareFormulaRequest(source: batchSource, profile: profile,
                                                             plannedBatch: batch, continuationContext: nil)
                    let requestID = UUID().uuidString
                    batchState = checkpoint.job.batches[batch.index]
                    batchState.requestID = requestID
                    batchState.attemptCount += 1
                    batchState.errorCategory = nil
                    batchState.updatedAt = Date()
                    checkpoint.job.batches[batch.index] = batchState
                    checkpoint.job.updatedAt = Date()
                    try await persist(checkpoint)
                    attemptedRequestsThisRun += 1
                    let outcome = try await requestFormulaSegment(
                        prepared: prepared, requestID: requestID, profile: profile, apiKey: apiKey,
                        jobID: selectedJobID, batch: batch, batchCount: batches.count,
                        completedBatches: checkpoint.job.batches.filter { $0.status == .completed }.count,
                        onProgress: onProgress)
                    let insight = try PaperInsightV2Validator.decode(Data(outcome.response.utf8), source: batchSource,
                        maximumFigures: 0, expectedFormulaSegments: expectations)
                    let claimsByEquation = Dictionary(uniqueKeysWithValues: insight.physics.importantFormulaDerivations.compactMap {
                        claim in claim.equationID.map { ($0, claim) }
                    })
                    guard claimsByEquation.count == batch.equationIDs.count,
                          Set(claimsByEquation.keys) == Set(batch.equationIDs) else {
                        throw LatticeLensError.schemaViolation("公式初始 segment 返回数量或 equation ID 不符。")
                    }
                    for equationID in batch.equationIDs {
                        guard let equation = batchSource.numberedEquations.first(where: { $0.equationID == equationID }),
                              let claim = claimsByEquation[equationID],
                              let metadata = claim.derivationSegment else {
                            throw LatticeLensError.schemaViolation("公式初始 segment 缺少本地 equation/segment 身分。")
                        }
                        var segment = FormulaDerivationSegmentCheckpoint(equationID: equationID, sourceTeX: equation.tex)
                        try segment.appendSegment(index: metadata.index, steps: claim.formulaDerivationSteps,
                            isFinal: metadata.isFinal, continuationSummary: metadata.continuationSummary,
                            conclusionZH: claim.conclusionZH, requestID: outcome.requestID,
                            requestPayloadHash: outcome.requestPayloadHash, responseHash: outcome.responseHash,
                            receivedBytes: outcome.received.bytes, receivedCharacters: outcome.received.characters,
                            firstContentAt: outcome.received.firstAt, lastContentAt: outcome.received.lastAt)
                        segmentStates[equationID] = segment
                    }
                    checkpoint.derivationSegmentsByEquation = segmentStates
                    checkpoint.job.batches[batch.index] = Self.record(outcome, in: checkpoint.job.batches[batch.index])
                    checkpoint.job.updatedAt = Date()
                    try await persist(checkpoint)
                }

                while let equationID = batch.equationIDs.first(where: { segmentStates[$0]?.isComplete != true }) {
                    try Task.checkCancellation()
                    guard let savedSegment = segmentStates[equationID],
                          let precedingTeX = savedSegment.completedSteps.last?.afterTeX,
                          let continuationSummary = savedSegment.continuationSummary else {
                        throw FormulaDerivationWorkflowError.staleCheckpoint
                    }
                    let context = FormulaDerivationContinuationContext(
                        equationID: equationID, segmentIndex: savedSegment.segments.count,
                        startingOrdinal: savedSegment.completedSteps.count + 1,
                        precedingTeX: precedingTeX, previousSteps: savedSegment.completedSteps,
                        continuationSummary: continuationSummary,
                        priorSegmentHashes: savedSegment.segments.flatMap {
                            [$0.requestPayloadHash, $0.responseHash]
                        })
                    let continuationSource = try source.batch(for: [equationID], index: batch.index, total: batch.total)
                    let expectation = FormulaDerivationSegmentExpectation(index: context.segmentIndex,
                        startingOrdinal: context.startingOrdinal, precedingTeX: context.precedingTeX)
                    let prepared = try prepareFormulaRequest(source: continuationSource, profile: profile,
                                                             plannedBatch: nil, continuationContext: context)
                    let requestID = UUID().uuidString
                    batchState = checkpoint.job.batches[batch.index]
                    batchState.requestID = requestID
                    batchState.attemptCount += 1
                    batchState.errorCategory = nil
                    batchState.updatedAt = Date()
                    checkpoint.job.batches[batch.index] = batchState
                    checkpoint.job.updatedAt = Date()
                    try await persist(checkpoint)
                    attemptedRequestsThisRun += 1
                    let outcome = try await requestFormulaSegment(
                        prepared: prepared, requestID: requestID, profile: profile, apiKey: apiKey,
                        jobID: selectedJobID, batch: batch, batchCount: batches.count,
                        completedBatches: checkpoint.job.batches.filter { $0.status == .completed }.count,
                        onProgress: onProgress)
                    let insight = try PaperInsightV2Validator.decode(Data(outcome.response.utf8), source: continuationSource,
                        maximumFigures: 0, expectedFormulaSegments: [equationID: expectation])
                    guard let claim = insight.physics.importantFormulaDerivations.first,
                          claim.equationID == equationID, let metadata = claim.derivationSegment else {
                        throw LatticeLensError.schemaViolation("公式续写 segment 未返回唯一匹配的 equation claim。")
                    }
                    var advanced = savedSegment
                    try advanced.appendSegment(index: metadata.index, steps: claim.formulaDerivationSteps,
                        isFinal: metadata.isFinal, continuationSummary: metadata.continuationSummary,
                        conclusionZH: claim.conclusionZH, requestID: outcome.requestID,
                        requestPayloadHash: outcome.requestPayloadHash, responseHash: outcome.responseHash,
                        receivedBytes: outcome.received.bytes, receivedCharacters: outcome.received.characters,
                        firstContentAt: outcome.received.firstAt, lastContentAt: outcome.received.lastAt)
                    segmentStates[equationID] = advanced
                    checkpoint.derivationSegmentsByEquation = segmentStates
                    checkpoint.job.batches[batch.index] = Self.record(outcome, in: checkpoint.job.batches[batch.index])
                    checkpoint.job.updatedAt = Date()
                    try await persist(checkpoint)
                }

                let completedClaims = try batch.equationIDs.map { equationID in
                    guard let segment = segmentStates[equationID], segment.isComplete,
                          let item = inventory.items.first(where: { $0.equationID == equationID }),
                          let evidenceID = item.evidenceID else {
                        throw FormulaDerivationWorkflowError.staleCheckpoint
                    }
                    return try Self.completedClaim(item: item, segment: segment, evidenceID: evidenceID)
                }
                batchState = checkpoint.job.batches[batch.index]
                batchState.status = .completed
                batchState.errorCategory = nil
                batchState.updatedAt = Date()
                checkpoint.job.batches[batch.index] = batchState
                checkpoint.completedClaimsByBatch[batch.index] = completedClaims
                checkpoint.job.updatedAt = Date()
                try await persist(checkpoint)
                await publish(checkpoint, activeBatch: nil, message: "公式批次 \(batch.index + 1)/\(batch.total) 已驗證", onProgress: onProgress)
            } catch {
                batchState = checkpoint.job.batches[batch.index]
                batchState.status = error is CancellationError || Task.isCancelled ? .cancelled : .retryable
                batchState.errorCategory = Self.errorCategory(error)
                batchState.updatedAt = Date()
                checkpoint.job.batches[batch.index] = batchState
                checkpoint.job.state = error is CancellationError || Task.isCancelled ? .cancelled : .retryable
                checkpoint.job.updatedAt = Date()
                try? await persist(checkpoint)
                await publish(checkpoint, activeBatch: nil, message: batchState.errorCategory, onProgress: onProgress)
                if error is CancellationError || Task.isCancelled { throw LatticeLensError.cancelled }
                throw error
            }
        }

        checkpoint.job.state = .validating
        checkpoint.job.updatedAt = Date()
        try await persist(checkpoint)
        let orderedClaims = batches.sorted { $0.index < $1.index }.flatMap { checkpoint.completedClaimsByBatch[$0.index] ?? [] }
        do {
            let report = try FormulaCoverageValidator.validate(inventory: inventory, claims: orderedClaims, anchors: anchors)
            checkpoint.job.state = .complete
            checkpoint.job.updatedAt = Date()
            try await store.saveFormulaJobWithValidation(checkpoint, report: report)
            await publish(checkpoint, activeBatch: nil,
                           message: "編號公式 source coverage 完整；推導結構與物理核驗狀態分別記錄",
                           onProgress: onProgress)
            return FormulaDerivationResult(job: checkpoint.job, claims: orderedClaims, coverage: report,
                                           attemptedRequestsThisRun: attemptedRequestsThisRun,
                                           reusedValidatedBatches: reusedValidatedBatches)
        } catch {
            checkpoint.job.state = .incomplete
            checkpoint.job.updatedAt = Date()
            if let coverageError = error as? FormulaCoverageValidationError,
               case .incomplete(let report) = coverageError {
                try await store.saveFormulaJobWithValidation(checkpoint, report: report)
            } else {
                try await persist(checkpoint)
            }
            await publish(checkpoint, activeBatch: nil, message: "總 inventory coverage 未通過", onProgress: onProgress)
            throw error
        }
    }

    private func prepareFormulaRequest(source: EvidenceInputPayload, profile: ProviderProfile,
                                       plannedBatch: NumberedEquationBatch?,
                                       continuationContext: FormulaDerivationContinuationContext?) throws -> PreparedFormulaRequest {
        let payload = try FormulaDerivationPrompt.userPayload(source: source,
            continuationContext: continuationContext)
        let bytes = try OpenAICompatibleCompletionRequestBody(
            system: FormulaDerivationPrompt.systemInstruction, userPayload: payload, profile: profile
        ).encoded()
        let scalars = String(data: bytes, encoding: .utf8)?.unicodeScalars.count
        guard bytes.count <= EvidenceInputPayload.maximumPayloadBytes,
              let scalars, scalars <= EvidenceInputPayload.maximumPayloadScalars else {
            throw LatticeLensError.schemaViolation("公式 segment 的完整序列化请求超过本地 bytes/scalars 上限")
        }
        let hash = StableHash.sha256(bytes)
        if let plannedBatch {
            guard hash == plannedBatch.payloadHash, bytes.count == plannedBatch.estimatedBytes,
                  scalars == plannedBatch.estimatedScalars else {
                throw LatticeLensError.schemaViolation(
                    "公式批次请求与冻结 hash/计数不一致（hash匹配=\(hash == plannedBatch.payloadHash)，bytes=\(bytes.count)/\(plannedBatch.estimatedBytes)，scalars=\(scalars)/\(plannedBatch.estimatedScalars)）。"
                )
            }
        }
        return PreparedFormulaRequest(userPayload: payload, requestPayloadHash: hash)
    }

    private func requestFormulaSegment(
        prepared: PreparedFormulaRequest,
        requestID: String,
        profile: ProviderProfile,
        apiKey: String,
        jobID: String,
        batch: NumberedEquationBatch,
        batchCount: Int,
        completedBatches: Int,
        onProgress: @escaping @Sendable (FormulaDerivationProgress) async -> Void
    ) async throws -> FormulaRequestOutcome {
        let counter = FormulaBatchReceiveCounter()
        let transport: @Sendable (LLMTransportState) async -> Void = { _ in }
        let delta: @Sendable (String) async -> Void = { value in
            let received = await counter.append(value)
            await onProgress(FormulaDerivationProgress(jobID: jobID, state: .running,
                completedBatches: completedBatches, totalBatches: batchCount, activeBatch: batch.index,
                receivedBytes: received.bytes, receivedCharacters: received.characters,
                message: "公式批次 \(batch.index + 1)/\(batch.total) segment 正在接收"))
        }
        let provider = client
        let requestTimeout = timeouts.hard
        let response = try await V4AnalysisDeadlineEnforcer.perform(
            timeouts: timeouts,
            maximumResponseBytes: PaperInsightValidator.maximumResponseBytes,
            onTransportState: transport,
            onDelta: delta
        ) { transportState, received in
            if let configurable = provider as? any LLMRequestTimeoutConfiguring {
                return try await configurable.complete(system: FormulaDerivationPrompt.systemInstruction,
                    userPayload: prepared.userPayload, profile: profile, apiKey: apiKey,
                    maximumResponseBytes: PaperInsightValidator.maximumResponseBytes,
                    requestTimeout: requestTimeout,
                    onTransportState: transportState, onDelta: received)
            }
            return try await provider.complete(system: FormulaDerivationPrompt.systemInstruction,
                userPayload: prepared.userPayload, profile: profile, apiKey: apiKey,
                maximumResponseBytes: PaperInsightValidator.maximumResponseBytes,
                onTransportState: transportState, onDelta: received)
        }
        try Task.checkCancellation()
        return FormulaRequestOutcome(requestID: requestID, response: response,
            requestPayloadHash: prepared.requestPayloadHash,
            responseHash: StableHash.sha256(Data(response.utf8)), received: await counter.snapshot())
    }

    private static func initialSegmentExpectations(for source: EvidenceInputPayload) throws
        -> [String: FormulaDerivationSegmentExpectation] {
        guard !source.numberedEquations.isEmpty else {
            throw LatticeLensError.schemaViolation("公式 segment source 不得為空")
        }
        return Dictionary(uniqueKeysWithValues: source.numberedEquations.map { equation in
            (equation.equationID, FormulaDerivationSegmentExpectation(index: 0, startingOrdinal: 1,
                                                                       precedingTeX: equation.tex))
        })
    }

    private static func completedClaim(item: FormulaInventoryItem,
                                       segment: FormulaDerivationSegmentCheckpoint,
                                       evidenceID: String) throws -> EvidenceClaim {
        let steps = segment.completedSteps
        return EvidenceClaim(textZH: "原文直接给出编号公式 \(item.label)。",
            epistemicStatus: .direct, evidenceIDs: [evidenceID], formulaTeX: item.sourceTeX,
            equationID: item.equationID, derivationSteps: steps.map(\.textZH),
            formulaDerivationSteps: steps, conclusionZH: segment.conclusionZH,
            derivationSegmentProvenanceHash: try segment.provenanceHash())
    }

    private static func record(_ outcome: FormulaRequestOutcome,
                               in prior: FormulaBatchCheckpoint) -> FormulaBatchCheckpoint {
        var updated = prior
        updated.requestID = outcome.requestID
        updated.receivedBytes += outcome.received.bytes
        updated.receivedCharacters += outcome.received.characters
        if let first = outcome.received.firstAt,
           updated.firstContentAt == nil || first < updated.firstContentAt! {
            updated.firstContentAt = first
        }
        if let last = outcome.received.lastAt { updated.lastContentAt = last }
        updated.updatedAt = Date()
        return updated
    }

    private func persist(_ checkpoint: FormulaDerivationCheckpoint) async throws {
        try await store.saveFormulaJob(checkpoint)
    }

    private static func completedBatchClaimsAreValid(_ claims: [EvidenceClaim], equationIDs: [String],
                                                     inventory: FormulaInventory,
                                                     anchors: [String: EvidenceAnchor]) -> Bool {
        let claimIDs = claims.compactMap(\.equationID)
        guard claimIDs.count == claims.count, claimIDs == equationIDs else { return false }
        let report = FormulaCoverageValidator.report(inventory: inventory, claims: claims, anchors: anchors)
        return report.extraEquationIDs.isEmpty && report.duplicateEquationIDs.isEmpty && report.invalidEquationIDs.isEmpty
    }

    private func publish(_ checkpoint: FormulaDerivationCheckpoint, activeBatch: Int?, message: String?,
                         onProgress: @escaping @Sendable (FormulaDerivationProgress) async -> Void) async {
        await onProgress(FormulaDerivationProgress(jobID: checkpoint.job.jobID, state: checkpoint.job.state,
                                                   completedBatches: checkpoint.job.batches.filter { $0.status == .completed }.count,
                                                   totalBatches: checkpoint.job.batches.count, activeBatch: activeBatch,
                                                   receivedBytes: checkpoint.job.batches.reduce(0) { $0 + $1.receivedBytes },
                                                   receivedCharacters: checkpoint.job.batches.reduce(0) { $0 + $1.receivedCharacters },
                                                   message: message))
    }

    private static func errorCategory(_ error: Error) -> String {
        if Task.isCancelled || error is CancellationError || (error as? LatticeLensError) == .cancelled { return "cancelled" }
        return switch error as? V4AnalysisDeadlineError {
        case .invalidTimeoutConfiguration: "timeout_configuration_error"
        case .connect: "connect_timeout"
        case .firstContent: "first_content_timeout"
        case .idle: "idle_timeout"
        case .hard: "resource_limit"
        case .responseTooLarge: "resource_limit"
        case nil: "provider_or_validation_error"
        }
    }
}

private struct FormulaReceiveSnapshot: Sendable {
    let bytes: Int
    let characters: Int
    let firstAt: Date?
    let lastAt: Date?
}

private struct PreparedFormulaRequest: Sendable {
    let userPayload: String
    let requestPayloadHash: String
}

private struct FormulaRequestOutcome: Sendable {
    let requestID: String
    let response: String
    let requestPayloadHash: String
    let responseHash: String
    let received: FormulaReceiveSnapshot
}

private actor FormulaBatchReceiveCounter {
    private var bytes = 0
    private var characters = 0
    private var firstAt: Date?
    private var lastAt: Date?

    func append(_ value: String) -> FormulaReceiveSnapshot {
        let now = Date(); firstAt = firstAt ?? now; lastAt = now
        bytes += value.lengthOfBytes(using: .utf8); characters += value.count
        return FormulaReceiveSnapshot(bytes: bytes, characters: characters, firstAt: firstAt, lastAt: lastAt)
    }
    func snapshot() -> FormulaReceiveSnapshot { FormulaReceiveSnapshot(bytes: bytes, characters: characters, firstAt: firstAt, lastAt: lastAt) }
}
