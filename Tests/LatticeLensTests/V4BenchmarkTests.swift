import Foundation
import Darwin
import SwiftData
import XCTest
@testable import LatticeLens

final class V4BenchmarkTests: XCTestCase {
    func testActualSwiftDataLargeStoreBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["LATTICELENS_RUN_V4_BENCHMARK"] == "1" else {
            throw XCTSkip("set LATTICELENS_RUN_V4_BENCHMARK=1 to run the actual SwiftData benchmark")
        }
        let environment = ProcessInfo.processInfo.environment
        let outputURL = environment["LATTICELENS_V4_BENCHMARK_OUTPUT"].map(URL.init(fileURLWithPath:))
        let manager = FileManager.default
        let diskRoot = try makeOwnedBenchmarkRoot(environment: environment, fileManager: manager)
        defer { try? manager.removeItem(at: diskRoot) }

        // Measure the active V7 cold-open before retaining the deliberately
        // large V6 in-memory harness below.  Otherwise an unrelated 20k
        // in-memory fixture can create memory pressure that contaminates an
        // on-disk V7 open sample.
        let activeV7 = try await benchmarkV7ActiveDomainStore(root: diskRoot)
        // The production factory now activates V9: V8 typed domain rows plus
        // a durable, incrementally maintained local token index.  Measure
        // this path separately so the older V6/V7 compatibility figures can
        // never be relabelled as final active-store evidence.
        let activeV9 = try await Self.benchmarkV9FinalTypedStore(root: diskRoot, expected: activeV7)
        if let syntheticSourcePath = environment["LATTICELENS_V5_SYNTHETIC_V7_SOURCE_OUTPUT"],
           !syntheticSourcePath.isEmpty {
            try await Self.exportVerifiedSyntheticV7Family(
                from: diskRoot.appendingPathComponent("benchmark-v7-active.store"),
                to: URL(fileURLWithPath: syntheticSourcePath),
                scratchRoot: diskRoot,
                expected: activeV7
            )
        }
        let store = try V4NormalizedStoreFactory.makeInMemory()
        let start = ContinuousClock.Instant.now
        try await store.insertSynthetic(authorCount: 2_000, paperCount: 20_000, linkCount: 100_000, chunkCount: 10_000)
        let insertMilliseconds = milliseconds(from: start)
        // Prime the SwiftData token row once.  The following distribution is
        // explicitly a warm-query p50/p95, not a cold first fault mislabeled
        // as warm performance.
        _ = try await store.searchPaperIDs("local", limit: 100)
        var warmSamples = [Int]()
        var warmResults = [Int]()
        for _ in 0..<7 {
            let warmStart = ContinuousClock.Instant.now
            warmResults = try await store.searchPaperIDs("local", limit: 100)
            warmSamples.append(milliseconds(from: warmStart))
        }
        let sortedWarmSamples = warmSamples.sorted()
        let warmSearchP50 = sortedWarmSamples[sortedWarmSamples.count / 2]
        let warmSearchP95 = sortedWarmSamples[min(sortedWarmSamples.count - 1, Int((Double(sortedWarmSamples.count - 1) * 0.95).rounded(.up)))]
        let inMemoryMutationSamples = try await markReadSamples(store: store, paperID: 10_001)
        let authors = try await store.authorCount()
        let papers = try await store.paperCount()
        let links = try await store.linkCount()
        let chunks = try await store.chunkCount()
        let disk = try await benchmarkDiskBackedStore(root: diskRoot)
        let result: [String: Any] = [
            "schema_version": "latticelens-benchmark-v4",
            "store": "SwiftData-in-memory-and-disk-backed",
            "build_configuration": "SwiftPM-debug-XCTest",
            "architecture": benchmarkArchitecture,
            "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
            "logical_cpu_count": ProcessInfo.processInfo.processorCount,
            "active_cpu_count": ProcessInfo.processInfo.activeProcessorCount,
            "warm_search_sample_count": 7,
            "cold_open_sample_count": 3,
            "single_row_mutation_sample_count": 7,
            "authors": authors,
            "papers": papers,
            "links": links,
            "chunks": chunks,
            "in_memory_insert_ms": insertMilliseconds,
            "in_memory_warm_search_p50_ms": warmSearchP50,
            "in_memory_warm_search_p95_ms": warmSearchP95,
            "in_memory_single_row_mutation_p50_ms": percentile(inMemoryMutationSamples, percentile: 0.50),
            "in_memory_single_row_mutation_p95_ms": percentile(inMemoryMutationSamples, percentile: 0.95),
            "warm_search_p50_ms": disk.warmSearchP50,
            "warm_search_p95_ms": disk.warmSearchP95,
            "warm_search_ms": disk.warmSearchP95,
            "single_row_mutation_ms": disk.singleRowMutationP95,
            "single_row_mutation_p50_ms": disk.singleRowMutationP50,
            "single_row_mutation_p95_ms": disk.singleRowMutationP95,
            "disk_backed": disk.jsonObject,
            "v7_active_domain": activeV7.jsonObject,
            "v9_final_typed": activeV9.jsonObject,
            "rss_max_bytes": maximumResidentSetSize(),
            "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory
        ]
        if let outputURL {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: outputURL, options: .atomic)
        }
        XCTAssertEqual(authors, 2_000)
        XCTAssertEqual(papers, 20_000)
        XCTAssertEqual(links, 100_000)
        XCTAssertEqual(chunks, 10_000)
        XCTAssertEqual(warmResults.count, 100, "warm query must retrieve bounded real candidate IDs from the normalized token index")
        XCTAssertEqual(disk.authors, 2_000)
        XCTAssertEqual(disk.papers, 20_000)
        XCTAssertEqual(disk.links, 100_000)
        XCTAssertEqual(disk.chunks, 10_000)
        XCTAssertEqual(disk.batchOutcome, V4BatchUpsertOutcome(inserted: 0, updated: 100))
        XCTAssertEqual(disk.migratedPaperCount, 20_000)
        XCTAssertTrue(disk.backupVerified)
        XCTAssertEqual(activeV7.authors, 2_000)
        XCTAssertEqual(activeV7.papers, 20_000)
        XCTAssertEqual(activeV7.links, 100_000)
        XCTAssertEqual(activeV7.chunks, 10_000)
        XCTAssertEqual(activeV7.warmResultCount, 100)
        XCTAssertEqual(activeV9.authors, 2_000)
        XCTAssertEqual(activeV9.papers, 20_000)
        XCTAssertEqual(activeV9.links, 100_000)
        XCTAssertEqual(activeV9.chunks, 10_000)
        XCTAssertEqual(activeV9.fullTextDocuments, 100)
        XCTAssertEqual(activeV9.radarEvents, 500)
        XCTAssertEqual(activeV9.userAnnotations, 200)
        XCTAssertEqual(activeV9.tags, 100)
        XCTAssertEqual(activeV9.collections, 100)
        XCTAssertEqual(activeV9.warmResultCount, 100)
    }

    /// Opt-in final performance gate. This deliberately runs in its own
    /// XCTest process from the legacy V4/V9 benchmark so its RSS high-water
    /// mark is not contaminated by the separate in-memory compatibility
    /// fixture. All stores and clones are synthetic and project-local.
    @MainActor
    func testActualSwiftDataV12FormulaStoreBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LATTICELENS_RUN_V12_FORMULA_BENCHMARK"] == "1" else {
            throw XCTSkip("set LATTICELENS_RUN_V12_FORMULA_BENCHMARK=1 to run the V12 final performance gate")
        }

        let manager = FileManager.default
        let benchmarkRoot: URL
        if let configured = environment["LATTICELENS_V12_FORMULA_BENCHMARK_ROOT"], !configured.isEmpty {
            guard let storeRoot = environment["LATTICELENS_TEST_STORE_ROOT"], !storeRoot.isEmpty else {
                throw BenchmarkFailure.untrustedBenchmarkRoot(configured)
            }
            let allowedRoot = URL(fileURLWithPath: storeRoot, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            let requestedRoot = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
            guard requestedRoot.deletingLastPathComponent().resolvingSymlinksInPath() == allowedRoot,
                  !manager.fileExists(atPath: requestedRoot.path) else {
                throw BenchmarkFailure.untrustedBenchmarkRoot(requestedRoot.path)
            }
            try manager.createDirectory(at: requestedRoot, withIntermediateDirectories: true)
            benchmarkRoot = requestedRoot
        } else {
            benchmarkRoot = try makeProjectLocalTestDirectory(prefix: "v12-formula-benchmark")
        }
        defer { try? manager.removeItem(at: benchmarkRoot) }

        let result = try await Self.benchmarkV12FormulaStore(
            root: benchmarkRoot,
            inputManifestSHA256: environment["LATTICELENS_BENCHMARK_INPUT_MANIFEST_SHA256"]
        )

        if let outputPath = environment["LATTICELENS_V12_FORMULA_BENCHMARK_OUTPUT"], !outputPath.isEmpty {
            let projectRoot = URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true).standardizedFileURL
            let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            guard outputURL.path.hasPrefix(projectRoot.path + "/") else {
                throw BenchmarkFailure.untrustedBenchmarkOutput(outputURL.path)
            }
            let data = try JSONSerialization.data(withJSONObject: result.jsonObject, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: outputURL, options: .atomic)
        }

        XCTAssertEqual(result.authors, 2_000)
        XCTAssertEqual(result.papers, 20_000)
        XCTAssertEqual(result.links, 100_000)
        XCTAssertEqual(result.chunks, 10_000)
        XCTAssertEqual(result.radarEvents, 500)
        XCTAssertEqual(result.formulaInventoryCount, 20)
        XCTAssertEqual(result.formulaCount, 5_000)
        XCTAssertTrue(result.backupVerified)
        XCTAssertEqual(result.coldReopenSamplesMs.count, 20)
        XCTAssertEqual(result.warmSearchSamplesMs.count, 100)
        XCTAssertEqual(result.readMutationSamplesMs.count, 100)
        XCTAssertEqual(result.favoriteMutationSamplesMs.count, 100)
        XCTAssertEqual(result.noteMutationSamplesMs.count, 100)
        XCTAssertEqual(result.formulaInventoryReadSamplesMs.count, 100)
        XCTAssertEqual(result.formulaJobReadSamplesMs.count, 100)
        XCTAssertEqual(result.formulaJobCommitSamplesMs.count, 100)
        XCTAssertEqual(result.formulaJobRows, 1)
        XCTAssertEqual(result.formulaClaimRows, 8)
        XCTAssertEqual(result.formulaStructuredStepRows, 8)
        XCTAssertEqual(result.formulaSegmentRows, 8)
        XCTAssertEqual(result.formulaSegmentStepRows, 8)
    }

    func testV10FormulaBenchmarkFixtureUsesCurrentParserAndBatchPlanner() throws {
        let fixture = try Self.makeV10FormulaFixture(
            paperID: 42,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertTrue(fixture.inventory.isComplete)
        XCTAssertEqual(fixture.inventory.items.count, 250)
        XCTAssertTrue(fixture.inventory.items.allSatisfy { $0.evidenceID != nil && $0.sourceByteEnd > $0.sourceByteStart })
        XCTAssertEqual(fixture.batches.count, 32)
        XCTAssertTrue(fixture.batches.allSatisfy { $0.equationIDs.count <= 8 })
    }

    @MainActor
    private static func benchmarkV12FormulaStore(root: URL, inputManifestSHA256: String?) async throws -> V12FormulaDiskBenchmark {
        let fileManager = FileManager.default
        let totalStart = ContinuousClock.Instant.now
        let sourceURL = root.appendingPathComponent("benchmark-v12-v7-source.store")
        let activeURL = root.appendingPathComponent("benchmark-v12-active.store")
        let seedStart = ContinuousClock.Instant.now
        try seedV7ActiveDomainStore(at: sourceURL)
        let v7SeedMilliseconds = measurementMilliseconds(from: seedStart)

        let v8MigrationStart = ContinuousClock.Instant.now
        let migration = try V8MigrationCoordinator.migrateV7ToV8(
            sourceURL: sourceURL,
            activeV8URL: activeURL,
            backupRoot: root.appendingPathComponent("v12-v8-backups", isDirectory: true)
        )
        let v7ToV8Milliseconds = measurementMilliseconds(from: v8MigrationStart)
        guard migration.journal.phase == .activated,
              migration.journal.preSummary == migration.journal.postSummary else {
            throw BenchmarkFailure.invalidSyntheticFormulaFixture("V7-to-V8 staged migration did not preserve the synthetic source summary")
        }

        let schema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let configuration = ModelConfiguration(schema: schema, url: activeURL)
        let schemaOpenStart = ContinuousClock.Instant.now
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
                                           configurations: configuration)
        let v8ToV12OpenMilliseconds = measurementMilliseconds(from: schemaOpenStart)
        let indexStart = ContinuousClock.Instant.now
        if try !V9TypedSearchIndex.isCurrent(in: container.mainContext) {
            try V9TypedSearchIndex.rebuild(in: container.mainContext)
        }
        let indexBuildMilliseconds = measurementMilliseconds(from: indexStart)
        guard try V9TypedSearchIndex.isCurrent(in: container.mainContext) else {
            throw BenchmarkFailure.invalidSyntheticFormulaFixture("The production V9 search projection is not current in the V12 store")
        }
        let semanticSummary = try V8TypedStoreCodec.verifyMigrationSemanticIntegrity(from: container.mainContext)
        let authors = semanticSummary.counts["authors"] ?? 0
        let papers = semanticSummary.counts["papers"] ?? 0
        let links = semanticSummary.counts["paperAuthorLinks"] ?? 0
        let chunks = semanticSummary.counts["chunks"] ?? 0
        let radarEvents = semanticSummary.counts["radarEvents"] ?? 0
        guard authors == 2_000, papers == 20_000, links == 100_000, chunks == 10_000, radarEvents == 500 else {
            throw BenchmarkFailure.invalidSyntheticFormulaFixture("V12 semantic counts do not match the declared 20k/100k/10k/500 dataset")
        }

        let library = V8TypedLibraryStore(modelContainer: container)
        var fixtures = [V10FormulaDocumentFixture]()
        for paperIndex in 0..<20 {
            // Coverage anchors are paper-scoped and reject non-positive IDs.
            // Reuse this benchmark's synthetic V7 paper range so every
            // formula proof is valid against the same persisted library.
            let paperID = 10_000 + paperIndex
            fixtures.append(try makeV10FormulaFixture(paperID: paperID, now: Date(timeIntervalSince1970: 1_700_000_000)))
        }
        let rssBeforeFormulaWork = benchmarkMaximumResidentSetSizeBytes()
        var inventoryWriteSamples = [Int]()
        let inventoryWriteTotalStart = ContinuousClock.Instant.now
        for fixture in fixtures {
            let writeStart = ContinuousClock.Instant.now
            try await library.saveFormulaInventory(fixture.inventory, paperID: fixture.paperID)
            inventoryWriteSamples.append(measurementMilliseconds(from: writeStart))
        }
        let inventoryWriteTotalMilliseconds = measurementMilliseconds(from: inventoryWriteTotalStart)
        let rssAfterFormulaSeed = benchmarkMaximumResidentSetSizeBytes()

        let storedInventoryCount = try container.mainContext.fetch(FetchDescriptor<StoredV10FormulaInventory>()).count
        let storedFormulaRows = try container.mainContext.fetch(FetchDescriptor<StoredV10FormulaInventoryItem>())
        let formulaCount = storedFormulaRows.count
        let inventoryPayloadBytes = try container.mainContext.fetch(FetchDescriptor<StoredV10FormulaInventory>())
            .reduce(0) { $0 + $1.payload.count }
        let itemPayloadBytes = storedFormulaRows.reduce(0) { $0 + $1.payload.count }
        guard storedInventoryCount == 20, formulaCount == 5_000 else {
            throw BenchmarkFailure.invalidSyntheticFormulaFixture("V12 disk store does not contain exactly 20 inventories and 5,000 formula rows")
        }

        let backupRoot = root.appendingPathComponent("v12-verified-backups", isDirectory: true)
        let backup = try V4StoreBackupCoordinator.createBackup(source: activeURL, destinationRoot: backupRoot, schemaVersion: 12)
        let backupVerified = try V4StoreBackupCoordinator.verify(backup, in: backupRoot)
        var coldReopenSamples = [Int]()
        for sample in 0..<20 {
            let cloneRoot = root.appendingPathComponent("v12-cold-reopen-\(sample)", isDirectory: true)
            try V4StoreBackupCoordinator.restore(backup, from: backupRoot, to: cloneRoot)
            let cloneURL = cloneRoot.appendingPathComponent(activeURL.lastPathComponent)
            coldReopenSamples.append(try await measureV12ColdReopen(at: cloneURL, paperID: fixtures[0].paperID,
                                                                     documentHash: fixtures[0].inventory.documentHash))
        }

        _ = await library.searchPapers("local", limit: 100)
        var warmSearchSamples = [Int]()
        var warmSearchResultCount = 0
        var searchBreakdowns = [V9SearchPerformanceBreakdown]()
        for _ in 0..<100 {
            let searchStart = ContinuousClock.Instant.now
            let measured = await library.searchPapersWithMetrics("local", limit: 100)
            warmSearchSamples.append(measurementMilliseconds(from: searchStart))
            guard measured.usedV9Projection else {
                throw BenchmarkFailure.invalidSyntheticFormulaFixture("Warm search fell back from the persisted V9 index")
            }
            warmSearchResultCount = measured.papers.count
            searchBreakdowns.append(measured.breakdown)
        }

        var readMutationSamples = [Int]()
        var favoriteMutationSamples = [Int]()
        var noteMutationSamples = [Int]()
        for index in 0..<100 {
            let at = Date(timeIntervalSince1970: 1_700_000_100 + Double(index))
            let readStart = ContinuousClock.Instant.now
            try await library.markRead(index.isMultiple(of: 2), paperID: 10_001, at: at)
            readMutationSamples.append(measurementMilliseconds(from: readStart))

            let favoriteStart = ContinuousClock.Instant.now
            try await library.applyReferenceMutation(.setFavorite(paperID: 10_001, isFavorite: index.isMultiple(of: 2), at: at))
            favoriteMutationSamples.append(measurementMilliseconds(from: favoriteStart))

            let note = UserNote(id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!, paperID: 10_001,
                                body: "synthetic benchmark note revision \(index)",
                                createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: at)
            let noteStart = ContinuousClock.Instant.now
            try await library.applyReferenceMutation(.upsertNote(note))
            noteMutationSamples.append(measurementMilliseconds(from: noteStart))
        }

        var formulaInventoryReadSamples = [Int]()
        var formulaInventoryReadCount = 0
        for index in 0..<100 {
            let fixture = fixtures[index % fixtures.count]
            let readStart = ContinuousClock.Instant.now
            guard let inventory = try await library.formulaInventory(paperID: fixture.paperID,
                                                                      documentHash: fixture.inventory.documentHash) else {
                throw BenchmarkFailure.invalidSyntheticFormulaFixture("Production formula repository lost a seeded inventory in V12")
            }
            formulaInventoryReadSamples.append(measurementMilliseconds(from: readStart))
            formulaInventoryReadCount = inventory.items.count
            guard inventory.isComplete, inventory.items.count == 250 else {
                throw BenchmarkFailure.invalidSyntheticFormulaFixture("A persisted formula inventory failed its full 250-item readback check")
            }
        }

        let first = fixtures[0]
        let jobID = "benchmark-v12-formula-job"
        let baseDate = Date(timeIntervalSince1970: 1_700_001_000)
        let firstBatchFixtures = try first.inventory.items.prefix(8).map { item -> (EvidenceClaim, FormulaDerivationSegmentCheckpoint) in
            guard let anchorID = item.evidenceID else {
                throw BenchmarkFailure.invalidSyntheticFormulaFixture("V12 benchmark claim is missing its source anchor")
            }
            let step = FormulaDerivationStep(stepID: "\(item.equationID):step:1", ordinal: 1,
                textZH: "保留合成來源公式 \(item.label)。", beforeTeX: item.sourceTeX,
                afterTeX: item.sourceTeX, ruleOrAssumption: "source-preserving benchmark fixture",
                evidenceAnchorIDs: [anchorID], sourceDocumentHashes: [first.inventory.documentHash],
                epistemicStatus: .inference)
            var segment = FormulaDerivationSegmentCheckpoint(equationID: item.equationID, sourceTeX: item.sourceTeX)
            try segment.appendSegment(index: 0, steps: [step], isFinal: true,
                continuationSummary: nil, conclusionZH: "僅保留合成 benchmark 原式。",
                requestID: "benchmark-v12-\(item.equationID)",
                requestPayloadHash: String(repeating: "a", count: 64),
                responseHash: String(repeating: "b", count: 64), receivedBytes: 64, receivedCharacters: 32,
                firstContentAt: baseDate, lastContentAt: baseDate.addingTimeInterval(1))
            let claim = EvidenceClaim(textZH: "合成來源公式 \(item.label)。", epistemicStatus: .direct,
                evidenceIDs: [anchorID], formulaTeX: item.sourceTeX, equationID: item.equationID,
                formulaDerivationSteps: [step], conclusionZH: "僅保留合成 benchmark 原式。",
                derivationSegmentProvenanceHash: try segment.provenanceHash())
            return (claim, segment)
        }
        let firstBatchClaims = firstBatchFixtures.map(\.0)
        let segmentStatesByEquation = Dictionary(uniqueKeysWithValues: firstBatchFixtures.map {
            ($0.1.equationID, $0.1)
        })
        let batchCheckpoints = first.batches.map { batch in
            FormulaBatchCheckpoint(jobID: jobID, batchIndex: batch.index, batchTotal: batch.total,
                                   equationIDs: batch.equationIDs, payloadHash: batch.payloadHash,
                                   status: batch.index == 0 ? .completed : .prepared, updatedAt: baseDate)
        }
        var checkpoint = FormulaDerivationCheckpoint(
            job: FormulaDerivationJob(jobID: jobID, paperID: first.paperID,
                                      documentHash: first.inventory.documentHash,
                                      inventoryHash: first.inventory.inventoryHash,
                                      equationIDs: first.inventory.equationIDs, batchSize: 8,
                                      state: .running, batches: batchCheckpoints, startedAt: baseDate, updatedAt: baseDate),
            completedClaimsByBatch: [0: firstBatchClaims],
            derivationSegmentsByEquation: segmentStatesByEquation,
            promptVersion: FormulaDerivationPrompt.version,
            schemaVersion: PaperInsightV2Validator.schemaVersion,
            contextFingerprint: "synthetic-benchmark-context", updatedAt: baseDate
        )
        try await library.saveFormulaJob(checkpoint)
        var formulaJobReadSamples = [Int]()
        for _ in 0..<100 {
            let readStart = ContinuousClock.Instant.now
            guard let saved = try await library.formulaJob(id: jobID),
                  saved.job.batches.count == first.batches.count,
                  saved.completedClaimsByBatch[0]?.count == 8,
                  saved.derivationSegmentsByEquation?.count == 8,
                  saved.derivationSegmentsByEquation?.values.allSatisfy({ $0.completedSteps.count == 1 }) == true else {
                throw BenchmarkFailure.invalidSyntheticFormulaFixture("V12 formula job/claim/step/segment rows did not survive repository readback")
            }
            formulaJobReadSamples.append(measurementMilliseconds(from: readStart))
        }

        var formulaJobCommitSamples = [Int]()
        for index in 0..<100 {
            let at = baseDate.addingTimeInterval(Double(index + 1))
            checkpoint.updatedAt = at
            checkpoint.job.updatedAt = at
            let batchIndex = 1 + index % max(1, checkpoint.job.batches.count - 1)
            checkpoint.job.batches[batchIndex].attemptCount += 1
            checkpoint.job.batches[batchIndex].updatedAt = at
            let commitStart = ContinuousClock.Instant.now
            try await library.saveFormulaJob(checkpoint)
            formulaJobCommitSamples.append(measurementMilliseconds(from: commitStart))
        }
        guard let savedCheckpoint = try await library.formulaJob(id: jobID),
              savedCheckpoint.job.batches.reduce(0, { $0 + $1.attemptCount }) == 100 else {
            throw BenchmarkFailure.invalidSyntheticFormulaFixture("Formula checkpoint mutation samples did not persist all 100 attempt updates")
        }

        let searchTokens = try container.mainContext.fetch(FetchDescriptor<StoredV9SearchToken>())
        let searchIndexPayloadBytes = searchTokens.reduce(0) { $0 + $1.token.utf8.count + $1.paperIDsData.count }
        let storeBytes = try benchmarkStoreFamilyByteCount(activeURL, fileManager: fileManager)
        let formulaJobRows = try container.mainContext.fetch(FetchDescriptor<StoredV11FormulaDerivationJob>()).count
        let formulaClaimRows = try container.mainContext.fetch(FetchDescriptor<StoredV11FormulaClaim>()).count
        let formulaStructuredStepRows = try container.mainContext.fetch(
            FetchDescriptor<StoredV11FormulaDerivationStep>()).count
        let formulaSegmentRows = try container.mainContext.fetch(
            FetchDescriptor<StoredV12FormulaDerivationSegment>()).count
        let formulaSegmentStepRows = try container.mainContext.fetch(
            FetchDescriptor<StoredV12FormulaDerivationSegmentStep>()).count
        let batchCheckpointRows = try container.mainContext.fetch(FetchDescriptor<StoredV10FormulaBatchCheckpoint>()).count
        let formulaRowsAfterWork = try container.mainContext.fetch(FetchDescriptor<StoredV10FormulaInventoryItem>()).count
        let result = V12FormulaDiskBenchmark(
            inputManifestSHA256: inputManifestSHA256 ?? "unbound-direct-run",
            authors: authors, papers: papers, links: links, chunks: chunks, radarEvents: radarEvents,
            formulaInventoryCount: storedInventoryCount, formulaCount: formulaCount,
            inventoryWriteSamplesMs: inventoryWriteSamples, inventoryWriteTotalMs: inventoryWriteTotalMilliseconds,
            formulaParseSamplesMs: fixtures.map(\.parseMilliseconds),
            batchPlanSamplesMs: fixtures.map(\.batchPlanMilliseconds),
            batchPlansPerInventory: fixtures.map { $0.batches.count },
            mergeValidationSamplesMs: fixtures.map(\.mergeValidationMilliseconds),
            coldReopenSamplesMs: coldReopenSamples, warmSearchSamplesMs: warmSearchSamples,
            warmSearchResultCount: warmSearchResultCount, searchBreakdowns: searchBreakdowns,
            readMutationSamplesMs: readMutationSamples, favoriteMutationSamplesMs: favoriteMutationSamples,
            noteMutationSamplesMs: noteMutationSamples,
            formulaInventoryReadSamplesMs: formulaInventoryReadSamples, formulaInventoryReadCount: formulaInventoryReadCount,
            formulaJobReadSamplesMs: formulaJobReadSamples, formulaJobCommitSamplesMs: formulaJobCommitSamples,
            formulaBatchCount: first.batches.count, backupVerified: backupVerified,
            v7SeedMilliseconds: v7SeedMilliseconds, v7ToV8Milliseconds: v7ToV8Milliseconds,
            v8ToV12OpenMilliseconds: v8ToV12OpenMilliseconds, indexBuildMilliseconds: indexBuildMilliseconds,
            storeBytes: storeBytes, searchIndexTokenRows: searchTokens.count,
            searchIndexPayloadBytes: searchIndexPayloadBytes,
            formulaInventoryPayloadBytes: inventoryPayloadBytes, formulaItemPayloadBytes: itemPayloadBytes,
            formulaJobRows: formulaJobRows, formulaClaimRows: formulaClaimRows,
            formulaStructuredStepRows: formulaStructuredStepRows,
            formulaSegmentRows: formulaSegmentRows, formulaSegmentStepRows: formulaSegmentStepRows,
            batchCheckpointRows: batchCheckpointRows,
            formulaRowsAfterWork: formulaRowsAfterWork,
            rssBeforeFormulaWorkBytes: rssBeforeFormulaWork, rssAfterFormulaSeedBytes: rssAfterFormulaSeed,
            rssPeakBytes: benchmarkMaximumResidentSetSizeBytes(),
            totalWallMilliseconds: measurementMilliseconds(from: totalStart)
        )
        return result
    }

    @MainActor
    private static func measureV12ColdReopen(at storeURL: URL, paperID: Int, documentHash: String) async throws -> Int {
        let schema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let start = ContinuousClock.Instant.now
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
                                           configurations: ModelConfiguration(schema: schema, url: storeURL))
        let elapsed = measurementMilliseconds(from: start)
        guard try V9TypedSearchIndex.isCurrent(in: container.mainContext),
              let inventory = try await V10FormulaInventoryStore(modelContainer: container)
                .formulaInventory(paperID: paperID, documentHash: documentHash),
              inventory.items.count == 250 else {
            throw BenchmarkFailure.invalidSyntheticFormulaFixture("A fresh V12 container did not reopen the indexed 250-formula inventory")
        }
        return elapsed
    }

    private static func makeV10FormulaFixture(paperID: Int, now: Date) throws -> V10FormulaDocumentFixture {
        let documentHash = StableHash.sha256("latticelens-v10-formula-benchmark-document-\(paperID)")
        let html = (1...250).map { index in
            #"<div class="ltx_equation"><math alttext="x_\#(index)=y_\#(index)"></math><span class="ltx_tag_equation">(\#(index))</span></div>"#
        }.joined(separator: "\n")
        let parseStart = ContinuousClock.Instant.now
        let inventory = FormulaInventoryParser.parse(html: html, documentHash: documentHash)
        let parseMilliseconds = measurementMilliseconds(from: parseStart)
        guard inventory.isComplete, inventory.items.count == 250 else {
            throw BenchmarkFailure.invalidSyntheticFormulaFixture("The generated 250-equation HTML did not parse as a complete source inventory")
        }
        let paper = makeV7BenchmarkPaper(paperID, now: now)
        let document = FullTextDocument(
            paperID: paperID, sourceURL: URL(string: "https://ar5iv.labs.arxiv.org/html/benchmark-\(paperID)")!,
            sourceKind: .arxivHTML, sha256: documentHash, byteCount: html.utf8.count,
            localFilename: nil, pageCount: nil, extractionState: .extracted, downloadedAt: now,
            lastErrorCategory: nil, numberedEquationIndexVersion: FullTextService.numberedEquationIndexVersion,
            numberedEquationCount: inventory.items.count, numberedEquationIndexComplete: true,
            numberedEquationInventoryHash: inventory.inventoryHash
        )
        let chunks = inventory.items.map { item in
            let quote = "编号公式 \(item.label)\n$$\(item.sourceTeX)$$"
            let anchorID = item.evidenceID!
            return EvidenceChunk(id: anchorID, paperID: paperID, documentHash: documentHash, page: 1,
                                 section: "synthetic-benchmark", characterRangeStart: 0,
                                 characterRangeEnd: quote.count, text: quote, textHash: StableHash.sha256(quote),
                                 equationID: item.equationID, equationLabel: item.label,
                                 equationTeX: item.sourceTeX, equationOrdinal: item.ordinal)
        }
        let anchors = Dictionary(uniqueKeysWithValues: chunks.map { chunk in
            (chunk.id, EvidenceAnchor(id: chunk.id, paperID: paperID, sourceKind: .pdf, page: nil,
                                      section: chunk.section, quote: chunk.text, quoteHash: chunk.textHash,
                                      figureKey: nil))
        })
        let payload = EvidenceInputPayload(paper: paper, document: document, chunks: chunks,
                                           anchors: Array(anchors.values))
        guard payload.numberedEquationCoverageComplete else {
            throw BenchmarkFailure.invalidSyntheticFormulaFixture(payload.numberedEquationCoverageFailure ?? "Evidence payload rejected complete synthetic formulas")
        }

        let planStart = ContinuousClock.Instant.now
        let benchmarkProfile = ProviderProfile(provider: .localOpenAICompatible,
            baseURL: "http://127.0.0.1:11434/v1", manualModel: "synthetic-benchmark", usesStreaming: false)
        let batches = try FormulaBatchPlanner.plan(source: payload, jobID: "benchmark-formula-\(paperID)",
                                                   batchSize: 8, profile: benchmarkProfile)
        let batchPlanMilliseconds = measurementMilliseconds(from: planStart)
        let claims = inventory.items.map { item in
            let anchorID = item.evidenceID!
            let step = FormulaDerivationStep(stepID: "\(item.equationID):step:1", ordinal: 1,
                textZH: "合成基准步骤，不代表物理论证。", beforeTeX: item.sourceTeX,
                afterTeX: item.sourceTeX, ruleOrAssumption: "synthetic benchmark fixture",
                evidenceAnchorIDs: [anchorID], sourceDocumentHashes: [documentHash],
                epistemicStatus: .inference)
            return EvidenceClaim(textZH: "合成來源公式 \(item.label)。", epistemicStatus: .direct,
                evidenceIDs: [anchorID], formulaTeX: item.sourceTeX, equationID: item.equationID,
                formulaDerivationSteps: [step], conclusionZH: "仅保留合成 benchmark 的原式；不表示物理推导结论。")
        }
        let mergeStart = ContinuousClock.Instant.now
        let coverage = try FormulaCoverageValidator.validate(inventory: inventory, claims: claims, anchors: anchors)
        let mergeValidationMilliseconds = measurementMilliseconds(from: mergeStart)
        guard coverage.isComplete, batches.count == 32 else {
            throw BenchmarkFailure.invalidSyntheticFormulaFixture("Formula batch plan or source-coverage merge is incomplete")
        }
        return V10FormulaDocumentFixture(paperID: paperID, inventory: inventory, batches: batches,
                                         parseMilliseconds: parseMilliseconds,
                                         batchPlanMilliseconds: batchPlanMilliseconds,
                                         mergeValidationMilliseconds: mergeValidationMilliseconds)
    }

    private func benchmarkDiskBackedStore(root: URL) async throws -> DiskBenchmark {
        let manager = FileManager.default
        let storeURL = root.appendingPathComponent("benchmark-v6.store")
        let seedStart = ContinuousClock.Instant.now
        try await seedDiskStore(at: storeURL)
        let seedMilliseconds = milliseconds(from: seedStart)

        let backupRoot = root.appendingPathComponent("verified-backups", isDirectory: true)
        let backupStart = ContinuousClock.Instant.now
        let manifest = try V4StoreBackupCoordinator.createBackup(source: storeURL, destinationRoot: backupRoot, schemaVersion: 6)
        let backupMilliseconds = milliseconds(from: backupStart)
        let backupVerified = try V4StoreBackupCoordinator.verify(manifest, in: backupRoot)

        var coldOpenSamples = [Int]()
        var warmSamples = [Int]()
        var mutationSamples = [Int]()
        var batchOutcome: V4BatchUpsertOutcome?
        var batchMilliseconds: Int?
        var observedCounts: (authors: Int, papers: Int, links: Int, chunks: Int)?
        for sample in 0..<3 {
            let cloneRoot = root.appendingPathComponent("cold-open-\(sample)", isDirectory: true)
            try V4StoreBackupCoordinator.restore(manifest, from: backupRoot, to: cloneRoot)
            let cloneURL = cloneRoot.appendingPathComponent(storeURL.lastPathComponent)
            let openStart = ContinuousClock.Instant.now
            let clone = try V4NormalizedStoreFactory.makeDiskBacked(at: cloneURL)
            coldOpenSamples.append(milliseconds(from: openStart))
            _ = try await clone.searchPaperIDs("local", limit: 100)
            for _ in 0..<7 {
                let searchStart = ContinuousClock.Instant.now
                let values = try await clone.searchPaperIDs("local", limit: 100)
                warmSamples.append(milliseconds(from: searchStart))
                XCTAssertEqual(values.count, 100)
            }
            let mutation = try await markReadSamples(store: clone, paperID: 10_001)
            mutationSamples.append(contentsOf: mutation)
            if sample == 0 {
                let batchStart = ContinuousClock.Instant.now
                batchOutcome = try await clone.upsertSyntheticBatch(startingAt: 0, count: 100)
                batchMilliseconds = milliseconds(from: batchStart)
                observedCounts = (try await clone.authorCount(), try await clone.paperCount(),
                                  try await clone.linkCount(), try await clone.chunkCount())
            }
        }
        guard let batchOutcome, let batchMilliseconds, let observedCounts, coldOpenSamples.count == 3 else {
            throw BenchmarkFailure.insufficientColdOpenSamples
        }
        let migration = try await benchmarkV5ToV6Migration(root: root)
        let byteCount = try storeFamilyByteCount(storeURL, fileManager: manager)
        return DiskBenchmark(authors: observedCounts.authors, papers: observedCounts.papers,
                             links: observedCounts.links, chunks: observedCounts.chunks,
                             seedMilliseconds: seedMilliseconds, coldOpenSamples: coldOpenSamples,
                             warmSamples: warmSamples, mutationSamples: mutationSamples,
                             batchMilliseconds: batchMilliseconds, batchOutcome: batchOutcome,
                             backupMilliseconds: backupMilliseconds, backupVerified: backupVerified,
                             backupFileCount: manifest.files.count, storeFamilyBytes: byteCount,
                             migration: migration)
    }

    private func seedDiskStore(at storeURL: URL) async throws {
        let store = try V4NormalizedStoreFactory.makeDiskBacked(at: storeURL)
        try await store.insertSynthetic(authorCount: 2_000, paperCount: 20_000, linkCount: 100_000, chunkCount: 10_000)
    }

    /// Exercise the current V7 production truth, not only the V6 normalized
    /// benchmark harness above.  The seed consists of independently encoded
    /// V7 domain records plus the product's V4 local-search projection; each
    /// measured read mutation then goes through `SwiftDataLibraryStore`'s
    /// active-domain path and commits one paper/reading-state transaction.
    private func benchmarkV7ActiveDomainStore(root: URL) async throws -> V7ActiveDomainBenchmark {
        let manager = FileManager.default
        let storeURL = root.appendingPathComponent("benchmark-v7-active.store")
        let seedStart = ContinuousClock.Instant.now
        try await Self.seedV7ActiveDomainStore(at: storeURL)
        let seedMilliseconds = milliseconds(from: seedStart)

        let backupRoot = root.appendingPathComponent("v7-verified-backups", isDirectory: true)
        let backupStart = ContinuousClock.Instant.now
        let manifest = try V4StoreBackupCoordinator.createBackup(source: storeURL, destinationRoot: backupRoot, schemaVersion: 7)
        let backupMilliseconds = milliseconds(from: backupStart)
        let backupVerified = try V4StoreBackupCoordinator.verify(manifest, in: backupRoot)

        var coldOpenSamples = [Int]()
        var snapshotMaterializationSamples = [Int]()
        var warmSamples = [Int]()
        var mutationSamples = [Int]()
        var observedCounts: (authors: Int, papers: Int, links: Int, chunks: Int)?
        var warmResultCount = 0
        for sample in 0..<3 {
            let cloneRoot = root.appendingPathComponent("v7-cold-open-\(sample)", isDirectory: true)
            try V4StoreBackupCoordinator.restore(manifest, from: backupRoot, to: cloneRoot)
            let cloneURL = cloneRoot.appendingPathComponent(storeURL.lastPathComponent)
            let openStart = ContinuousClock.Instant.now
            let container = try await Self.makeV7Container(at: cloneURL)
            let activeStore = SwiftDataLibraryStore(modelContainer: container)
            coldOpenSamples.append(milliseconds(from: openStart))
            // Keep the database-open measurement separate from the optional
            // all-domain materialization performed by the legacy snapshot
            // compatibility API.  The latter is reported verbatim below but
            // is not silently relabeled as SQLite/SwiftData cold-open time.
            let materializationStart = ContinuousClock.Instant.now
            let snapshot = await activeStore.snapshot()
            snapshotMaterializationSamples.append(milliseconds(from: materializationStart))
            observedCounts = (snapshot.authors.count, snapshot.papers.count,
                              snapshot.paperAuthorLinks.count, snapshot.evidenceChunks.count)

            let normalized = V4NormalizedLibraryStore(modelContainer: container)
            _ = try await normalized.searchPaperIDs("local", limit: 100)
            for _ in 0..<7 {
                let searchStart = ContinuousClock.Instant.now
                let values = try await normalized.searchPaperIDs("local", limit: 100)
                warmSamples.append(milliseconds(from: searchStart))
                warmResultCount = values.count
            }
            for index in 0..<7 {
                let mutationStart = ContinuousClock.Instant.now
                try await activeStore.markRead(index.isMultiple(of: 2), paperID: 10_001, at: Date())
                mutationSamples.append(milliseconds(from: mutationStart))
            }
        }
        guard let observedCounts, coldOpenSamples.count == 3 else {
            throw BenchmarkFailure.insufficientColdOpenSamples
        }
        return V7ActiveDomainBenchmark(authors: observedCounts.authors, papers: observedCounts.papers,
                                       links: observedCounts.links, chunks: observedCounts.chunks,
                                       seedMilliseconds: seedMilliseconds, coldOpenSamples: coldOpenSamples,
                                       snapshotMaterializationSamples: snapshotMaterializationSamples,
                                       warmSamples: warmSamples, mutationSamples: mutationSamples,
                                       warmResultCount: warmResultCount, backupMilliseconds: backupMilliseconds,
                                       backupVerified: backupVerified,
                                       storeFamilyBytes: try storeFamilyByteCount(storeURL, fileManager: manager))
    }

    /// Benchmarks the schema opened by `LibraryStoreFactory`: V8 typed domain
    /// rows plus the V9 durable local-search projection.  The V7 source is
    /// generated earlier in this same task-owned root, then migrated through
    /// the production staged coordinator; no user store is opened.
    @MainActor
    private static func benchmarkV9FinalTypedStore(root: URL, expected: V7ActiveDomainBenchmark) async throws -> V9FinalTypedBenchmark {
        let manager = FileManager.default
        let sourceURL = root.appendingPathComponent("benchmark-v7-active.store")
        let finalRoot = root.appendingPathComponent("v9-final", isDirectory: true)
        let activeURL = finalRoot.appendingPathComponent("benchmark-v8-core.store")
        let backupRoot = finalRoot.appendingPathComponent("backups", isDirectory: true)
        try manager.createDirectory(at: finalRoot, withIntermediateDirectories: true)

        let migrationStart = ContinuousClock.Instant.now
        let migration = try V8MigrationCoordinator.migrateV7ToV8(sourceURL: sourceURL, activeV8URL: activeURL, backupRoot: backupRoot)
        let migrationMilliseconds = measurementMilliseconds(from: migrationStart)
        XCTAssertEqual(migration.journal.phase, .activated)
        XCTAssertEqual(migration.journal.preSummary, migration.journal.postSummary)

        let schema = Schema(versionedSchema: LatticeLensSchemaV9.self)
        let configuration = ModelConfiguration(schema: schema, url: activeURL)
        let indexStart = ContinuousClock.Instant.now
        let activeContainer = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV9.self,
                                                 configurations: configuration)
        if try !V9TypedSearchIndex.isCurrent(in: activeContainer.mainContext) {
            try V9TypedSearchIndex.rebuild(in: activeContainer.mainContext)
        }
        let indexBuildMilliseconds = measurementMilliseconds(from: indexStart)
        XCTAssertTrue(try V9TypedSearchIndex.isCurrent(in: activeContainer.mainContext))
        let semanticSummary = try V8TypedStoreCodec.verifyMigrationSemanticIntegrity(from: activeContainer.mainContext)
        XCTAssertEqual(semanticSummary, migration.journal.postSummary)
        XCTAssertEqual(semanticSummary.counts["fullTextDocuments"], 100)
        XCTAssertEqual(semanticSummary.counts["radarEvents"], 500)
        XCTAssertEqual(semanticSummary.counts["annotations"], 200)
        XCTAssertEqual(semanticSummary.counts["tags"], 100)
        XCTAssertEqual(semanticSummary.counts["collections"], 100)

        let cloneBackupRoot = finalRoot.appendingPathComponent("v9-verified-backups", isDirectory: true)
        let backupStart = ContinuousClock.Instant.now
        let backup = try V4StoreBackupCoordinator.createBackup(source: activeURL, destinationRoot: cloneBackupRoot, schemaVersion: 9)
        let backupMilliseconds = measurementMilliseconds(from: backupStart)
        let backupVerified = try V4StoreBackupCoordinator.verify(backup, in: cloneBackupRoot)

        var coldOpenSamples = [Int]()
        var warmSamples = [Int]()
        var warmSearchBreakdowns = [V9SearchPerformanceBreakdown]()
        var mutationSamples = [Int]()
        var warmResultCount = 0
        for sample in 0..<3 {
            let cloneRoot = finalRoot.appendingPathComponent("cold-open-\(sample)", isDirectory: true)
            try V4StoreBackupCoordinator.restore(backup, from: cloneBackupRoot, to: cloneRoot)
            let cloneURL = cloneRoot.appendingPathComponent(activeURL.lastPathComponent)
            let openStart = ContinuousClock.Instant.now
            let clone = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV9.self,
                                           configurations: ModelConfiguration(schema: schema, url: cloneURL))
            coldOpenSamples.append(measurementMilliseconds(from: openStart))
            XCTAssertTrue(try V9TypedSearchIndex.isCurrent(in: clone.mainContext))
            let store = V8TypedLibraryStore(modelContainer: clone)
            let directResults = try V9TypedSearchIndex.searchPapers(query: "local", limit: 100, in: clone.mainContext)
            XCTAssertEqual(directResults.count, 100, "the persisted final token index must return the bounded 100-paper candidate set")
            let primedResults = await store.searchPapers("local", limit: 100)
            XCTAssertEqual(primedResults.count, 100, "the product repository must consume the persisted final token index after reopen")
            for _ in 0..<7 {
                let searchStart = ContinuousClock.Instant.now
                // Measure the actual V8 repository actor and its model
                // context.  This result exposes the same algorithm's bounded
                // stage counters without creating a fixture-only search path.
                let measured = await store.searchPapersWithMetrics("local", limit: 100)
                warmSamples.append(measurementMilliseconds(from: searchStart))
                XCTAssertTrue(measured.usedV9Projection)
                warmSearchBreakdowns.append(measured.breakdown)
                warmResultCount = measured.papers.count
            }
            // Do not label the first SQLite write/checkpoint after a cold
            // reopen as a steady-state single-row mutation sample. The
            // published metric is a warm p50/p95 distribution, analogous to
            // the warm-search samples above; this one state flip also proves
            // the pre-materialized workflow row is writable before timing.
            try await store.markRead(false, paperID: 10_001, at: Date())
            for index in 0..<7 {
                let mutationStart = ContinuousClock.Instant.now
                try await store.markRead(index.isMultiple(of: 2), paperID: 10_001, at: Date())
                mutationSamples.append(measurementMilliseconds(from: mutationStart))
            }
        }
        guard coldOpenSamples.count == 3 else { throw BenchmarkFailure.insufficientColdOpenSamples }
        return V9FinalTypedBenchmark(authors: semanticSummary.counts["authors"] ?? 0,
                                     papers: semanticSummary.counts["papers"] ?? 0,
                                     links: semanticSummary.counts["paperAuthorLinks"] ?? 0,
                                     chunks: semanticSummary.counts["chunks"] ?? 0,
                                     fullTextDocuments: semanticSummary.counts["fullTextDocuments"] ?? 0,
                                     radarEvents: semanticSummary.counts["radarEvents"] ?? 0,
                                     userAnnotations: semanticSummary.counts["annotations"] ?? 0,
                                     tags: semanticSummary.counts["tags"] ?? 0,
                                     collections: semanticSummary.counts["collections"] ?? 0,
                                     migrationMilliseconds: migrationMilliseconds,
                                     indexBuildMilliseconds: indexBuildMilliseconds,
                                     coldOpenSamples: coldOpenSamples,
                                     warmSamples: warmSamples,
                                     warmSearchBreakdowns: warmSearchBreakdowns,
                                     mutationSamples: mutationSamples,
                                     warmResultCount: warmResultCount,
                                     backupMilliseconds: backupMilliseconds,
                                     backupVerified: backupVerified,
                                     storeFamilyBytes: try finalStoreFamilyByteCount(activeURL, fileManager: manager),
                                     sourceStoreName: sourceURL.lastPathComponent,
                                     expectedSourceCounts: (expected.authors, expected.papers, expected.links, expected.chunks))
    }

    private static func measurementMilliseconds(from start: ContinuousClock.Instant) -> Int {
        let components = start.duration(to: .now).components
        return max(0, Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000))
    }

    private static func finalStoreFamilyByteCount(_ storeURL: URL, fileManager: FileManager) throws -> Int64 {
        var total: Int64 = 0
        for url in [storeURL, URL(fileURLWithPath: storeURL.path + "-wal"), URL(fileURLWithPath: storeURL.path + "-shm")]
        where fileManager.fileExists(atPath: url.path) {
            guard let size = try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else { continue }
            total += size.int64Value
        }
        return total
    }

    @MainActor
    private static func makeV7Container(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: LatticeLensSchemaV7.self)
        return try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV7.self,
                                  configurations: ModelConfiguration(url: url))
    }

    @MainActor
    private static func seedV7ActiveDomainStore(at storeURL: URL) throws {
        let container = try makeV7Container(at: storeURL)
        let context = container.mainContext
        let encoder = JSONEncoder.latticeLens
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(StoredV7StoreMarker(schemaVersion: 71, materializedAt: now, importedLegacyDocument: false))

        func insert<T: Encodable>(_ kind: String, recordID: String, _ value: T) throws {
            context.insert(StoredV7DomainRecord(key: "\(kind)|\(recordID)", kind: kind, recordID: recordID,
                                                payload: try encoder.encode(value), updatedAt: now))
        }

        for identifier in 0..<2_000 {
            let author = Author(recid: identifier, preferredName: "V7 benchmark author \(identifier)", nativeNames: [], bai: nil,
                                arxivCategories: ["hep-lat"], hIndex: nil, hIndexState: .unknown,
                                isTracked: false, lastSyncedAt: nil)
            try insert("author", recordID: String(identifier), author)
        }
        for identifier in 0..<20_000 {
            let paper = makeV7BenchmarkPaper(identifier, now: now)
            try insert("paper", recordID: String(identifier), paper)
            context.insert(StoredV4Paper(paper, workflow: nil))
        }
        for identifier in 0..<100_000 {
            let link = PaperAuthorLink(paperID: identifier % 20_000, authorRecid: (identifier / 20_000) % 2_000,
                                       position: identifier % 12)
            try insert("paperAuthorLink", recordID: "\(link.paperID):\(link.authorRecid)", link)
        }
        for identifier in 0..<10_000 {
            let text = "V7 local benchmark chunk \(identifier) a=0.09 fm"
            let chunk = EvidenceChunk(id: "v7-chunk-\(identifier)", paperID: identifier % 20_000,
                                      documentHash: "v7-hash-\(identifier % 100)", page: identifier % 10 + 1,
                                      section: "benchmark", characterRangeStart: 0, characterRangeEnd: text.count,
                                      text: text, textHash: StableHash.sha256(text))
            try insert("evidenceChunk", recordID: chunk.id, chunk)
        }
        // The V5 contract fixes these non-paper cardinalities as part of the
        // real SwiftData disk benchmark.  They are all synthetic metadata;
        // no PDF bytes, private annotations or network resource is read.
        for identifier in 0..<100 {
            let paperID = identifier
            let document = FullTextDocument(paperID: paperID,
                                            sourceURL: URL(string: "https://fixture.invalid/benchmark/\(paperID).pdf")!,
                                            sourceKind: .arxivPDF,
                                            sha256: "benchmark-pdf-\(identifier)", byteCount: 0,
                                            localFilename: nil, pageCount: nil,
                                            extractionState: .notDownloaded,
                                            downloadedAt: nil, lastErrorCategory: nil)
            try insert("fullTextDocument", recordID: document.id, document)

            let tagID = benchmarkUUID(namespace: 1, index: identifier)
            let tag = LibraryTag(id: tagID, name: "benchmark tag \(identifier)", colorName: nil, createdAt: now)
            try insert("tag", recordID: tagID.uuidString, tag)
            try insert("paperTagLink", recordID: "\(paperID):\(tagID.uuidString)",
                       PaperTagLink(paperID: paperID, tagID: tagID))

            let collectionID = benchmarkUUID(namespace: 2, index: identifier)
            let collection = PaperCollection(id: collectionID, name: "benchmark collection \(identifier)", createdAt: now)
            try insert("collection", recordID: collectionID.uuidString, collection)
            try insert("collectionPaperLink", recordID: "\(collectionID.uuidString):\(paperID)",
                       CollectionPaperLink(collectionID: collectionID, paperID: paperID, addedAt: now))
        }
        let radarBatchID = benchmarkUUID(namespace: 3, index: 1)
        for identifier in 0..<500 {
            let eventID = benchmarkUUID(namespace: 4, index: identifier)
            let event = RadarEvent(id: eventID, paperID: identifier, authorRecids: [identifier % 2_000],
                                   eventKind: .fieldModified, beforeHash: "benchmark-before-\(identifier)",
                                   afterHash: "benchmark-after-\(identifier)", changedFields: ["abstract"],
                                   syncBatchID: radarBatchID, observedAt: now,
                                   sourceURL: URL(string: "https://fixture.invalid/benchmark/\(identifier)")!,
                                   isAcknowledged: false)
            try insert("radarEvent", recordID: eventID.uuidString, event)
        }
        for identifier in 0..<200 {
            let annotationID = benchmarkUUID(namespace: 5, index: identifier)
            let quote = "benchmark annotation \(identifier)"
            let annotation = UserEvidenceAnchor(id: annotationID, paperID: identifier,
                                                documentHash: "benchmark-pdf-\(identifier % 100)", sourceKind: .pdf,
                                                page: 1, characterRangeStart: 0, characterRangeEnd: quote.count,
                                                quote: quote, quoteHash: StableHash.sha256(quote), colorName: "yellow",
                                                label: "benchmark", note: "synthetic", status: .valid,
                                                createdAt: now, updatedAt: now)
            try insert("userAnnotation", recordID: annotationID.uuidString, annotation)
        }
        context.insert(StoredV4SearchToken(token: "local", paperIDs: Array(0..<20_000)))
        try context.save()
    }

    private static func benchmarkUUID(namespace: Int, index: Int) -> UUID {
        // Stable IDs make the benchmark input reproducible without persisting
        // a random seed or any user identity into the disk fixture.
        UUID(uuidString: String(format: "00000000-0000-%04X-0000-%012X", namespace, index))!
    }

    private static func makeV7BenchmarkPaper(_ identifier: Int, now: Date) -> Paper {
        Paper(literatureID: identifier,
              titles: [PaperTitle(value: "V7 local lattice benchmark \(identifier)", source: "benchmark")],
              abstracts: [PaperAbstract(value: "local SwiftData active-domain benchmark", source: "benchmark")],
              preprintDate: now, earliestDate: nil, arxivID: "2608.\(identifier)", arxivCategories: ["hep-lat"],
              doi: nil, citationCount: nil, publicationStatus: nil, updated: now, figures: [],
              firstSeenAt: now, isRead: false)
    }

    /// Retains one explicitly requested, non-empty synthetic V7 family for a
    /// disposable migration drill.  It never copies a user library: the
    /// source was generated by `seedV7ActiveDomainStore` in this same test.
    /// The ordinary benchmark run remains unchanged unless the dedicated
    /// output environment variable is supplied by the project-local script.
    @MainActor
    private static func exportVerifiedSyntheticV7Family(from source: URL, to output: URL,
                                                         scratchRoot: URL, expected: V7ActiveDomainBenchmark) throws {
        let manager = FileManager.default
        let normalizedOutput = output.standardizedFileURL
        guard normalizedOutput.pathExtension == "store",
              normalizedOutput.deletingLastPathComponent().standardizedFileURL.path != scratchRoot.standardizedFileURL.path,
              !manager.fileExists(atPath: normalizedOutput.path),
              !manager.fileExists(atPath: normalizedOutput.path + "-wal"),
              !manager.fileExists(atPath: normalizedOutput.path + "-shm") else {
            throw BenchmarkFailure.rootAlreadyExists(normalizedOutput.path)
        }
        let destinationDirectory = normalizedOutput.deletingLastPathComponent()
        let destinationValues = try destinationDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard destinationValues.isDirectory == true, destinationValues.isSymbolicLink != true else {
            throw LatticeLensError.persistenceUnavailable("合成 V7 导出目录必须是现有 non-symlink directory")
        }

        let exportBackupRoot = scratchRoot.appendingPathComponent("synthetic-v7-export-backups", isDirectory: true)
        let backup = try V4StoreBackupCoordinator.createBackup(source: source, destinationRoot: exportBackupRoot, schemaVersion: 7)
        guard try V4StoreBackupCoordinator.verify(backup, in: exportBackupRoot) else {
            throw LatticeLensError.persistenceUnavailable("合成 V7 source 的临时验证 backup 失败")
        }
        let backupDirectory = exportBackupRoot.appendingPathComponent(backup.id.uuidString, isDirectory: true)
        for entry in backup.files {
            let suffix: String
            switch entry.relativePath {
            case source.lastPathComponent: suffix = ""
            case source.lastPathComponent + "-wal": suffix = "-wal"
            case source.lastPathComponent + "-shm": suffix = "-shm"
            default: throw LatticeLensError.persistenceUnavailable("合成 V7 导出发现不属于 SQLite family 的文件")
            }
            let sourceMember = try V4OwnedPath.canonicalFile(named: entry.relativePath, root: backupDirectory, fileManager: manager)
            let outputMember = URL(fileURLWithPath: normalizedOutput.path + suffix)
            try manager.copyItem(at: sourceMember, to: outputMember)
        }

        let exportedBackupRoot = scratchRoot.appendingPathComponent("synthetic-v7-export-verify", isDirectory: true)
        let exportedBackup = try V4StoreBackupCoordinator.createBackup(source: normalizedOutput, destinationRoot: exportedBackupRoot, schemaVersion: 7)
        func familySignature(_ files: [V4StoreBackupFile], storeName: String) throws -> [String] {
            try files.map { entry in
                let suffix: String
                switch entry.relativePath {
                case storeName: suffix = "main"
                case storeName + "-wal": suffix = "wal"
                case storeName + "-shm": suffix = "shm"
                default: throw LatticeLensError.persistenceUnavailable("合成 V7 backup 含不属于 SQLite family 的文件")
                }
                return "\(suffix):\(entry.byteCount):\(entry.sha256)"
            }.sorted()
        }
        guard try V4StoreBackupCoordinator.verify(exportedBackup, in: exportedBackupRoot),
              try familySignature(backup.files, storeName: source.lastPathComponent) ==
                familySignature(exportedBackup.files, storeName: normalizedOutput.lastPathComponent) else {
            throw LatticeLensError.persistenceUnavailable("合成 V7 导出后 family hash 验证失败")
        }
        let container = try Self.makeV7Container(at: normalizedOutput)
        let snapshot = try V7DomainRecordCodec.decode(rows: container.mainContext.fetch(FetchDescriptor<StoredV7DomainRecord>()))
        XCTAssertEqual(snapshot.authors.count, expected.authors)
        XCTAssertEqual(snapshot.papers.count, expected.papers)
        XCTAssertEqual(snapshot.paperAuthorLinks.count, expected.links)
        XCTAssertEqual(snapshot.evidenceChunks.count, expected.chunks)
    }

    private func benchmarkV5ToV6Migration(root: URL) async throws -> MigrationBenchmark {
        let migrationURL = root.appendingPathComponent("migration-v5.store")
        try await Self.seedV5MigrationStore(at: migrationURL, paperCount: 20_000)
        let migrationStart = ContinuousClock.Instant.now
        let migrated = try V4NormalizedStoreFactory.makeDiskBacked(at: migrationURL)
        let migrationMilliseconds = milliseconds(from: migrationStart)
        return MigrationBenchmark(milliseconds: migrationMilliseconds, migratedPaperCount: try await migrated.paperCount())
    }

    @MainActor
    private static func seedV5MigrationStore(at migrationURL: URL, paperCount: Int) throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV5.self)
        let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV5.self,
                                           configurations: ModelConfiguration(url: migrationURL))
        for identifier in 0..<paperCount {
            container.mainContext.insert(StoredV4Paper(literatureID: identifier,
                                                       title: "V5 migration seed \(identifier)",
                                                       abstractText: "normalized migration benchmark"))
        }
        try container.mainContext.save()
    }

    private func markReadSamples(store: V4NormalizedLibraryStore, paperID: Int) async throws -> [Int] {
        var samples = [Int]()
        for index in 0..<7 {
            let start = ContinuousClock.Instant.now
            try await store.markRead(paperID: paperID, read: index.isMultiple(of: 2))
            samples.append(milliseconds(from: start))
        }
        return samples
    }

    private func makeOwnedBenchmarkRoot(environment: [String: String], fileManager: FileManager) throws -> URL {
        if let configured = environment["LATTICELENS_V4_BENCHMARK_ROOT"], !configured.isEmpty {
            let root = URL(fileURLWithPath: configured, isDirectory: true)
            guard !fileManager.fileExists(atPath: root.path) else { throw BenchmarkFailure.rootAlreadyExists(root.path) }
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
        return try makeProjectLocalTestDirectory(prefix: "v4-disk-benchmark")
    }

    private func storeFamilyByteCount(_ storeURL: URL, fileManager: FileManager) throws -> Int64 {
        var total: Int64 = 0
        for url in [storeURL, URL(fileURLWithPath: storeURL.path + "-wal"), URL(fileURLWithPath: storeURL.path + "-shm")]
        where fileManager.fileExists(atPath: url.path) {
            guard let size = try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else { continue }
            total += size.int64Value
        }
        return total
    }

    private func percentile(_ values: [Int], percentile: Double) -> Int {
        precondition(!values.isEmpty)
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * percentile).rounded(.up)))]
    }

    private func milliseconds(from start: ContinuousClock.Instant) -> Int {
        let components = start.duration(to: .now).components
        return max(0, Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000))
    }

    private func maximumResidentSetSize() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
        // Darwin reports ru_maxrss in bytes (unlike Linux, where it is KiB).
        return Int64(usage.ru_maxrss)
    }

    private var benchmarkArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

private struct DiskBenchmark {
    let authors: Int
    let papers: Int
    let links: Int
    let chunks: Int
    let seedMilliseconds: Int
    let coldOpenSamples: [Int]
    let warmSamples: [Int]
    let mutationSamples: [Int]
    let batchMilliseconds: Int
    let batchOutcome: V4BatchUpsertOutcome
    let backupMilliseconds: Int
    let backupVerified: Bool
    let backupFileCount: Int
    let storeFamilyBytes: Int64
    let migration: MigrationBenchmark

    var warmSearchP50: Int { percentile(warmSamples, percentile: 0.50) }
    var warmSearchP95: Int { percentile(warmSamples, percentile: 0.95) }
    var singleRowMutationP50: Int { percentile(mutationSamples, percentile: 0.50) }
    var singleRowMutationP95: Int { percentile(mutationSamples, percentile: 0.95) }
    var coldOpenP50: Int { percentile(coldOpenSamples, percentile: 0.50) }
    var coldOpenP95: Int { percentile(coldOpenSamples, percentile: 0.95) }
    var migratedPaperCount: Int { migration.migratedPaperCount }

    var jsonObject: [String: Any] {
        [
            "store": "SwiftData-disk-backed",
            "authors": authors,
            "papers": papers,
            "links": links,
            "chunks": chunks,
            "seed_ms": seedMilliseconds,
            "cold_open_samples_ms": coldOpenSamples,
            "cold_open_p50_ms": coldOpenP50,
            "cold_open_p95_ms": coldOpenP95,
            "warm_search_p50_ms": warmSearchP50,
            "warm_search_p95_ms": warmSearchP95,
            "single_row_mutation_p50_ms": singleRowMutationP50,
            "single_row_mutation_p95_ms": singleRowMutationP95,
            "batch_upsert_count": batchOutcome.inserted + batchOutcome.updated,
            "batch_upsert_inserted": batchOutcome.inserted,
            "batch_upsert_updated": batchOutcome.updated,
            "batch_upsert_ms": batchMilliseconds,
            "backup_ms": backupMilliseconds,
            "backup_verified": backupVerified,
            "backup_file_count": backupFileCount,
            "store_family_bytes": storeFamilyBytes,
            "migration_v5_to_v6_seed_papers": migration.migratedPaperCount,
            "migration_v5_to_v6_ms": migration.milliseconds
        ]
    }

    private func percentile(_ values: [Int], percentile: Double) -> Int {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * percentile).rounded(.up)))]
    }
}

/// A compact, deterministic aggregate of real V9 query measurements.  The
/// raw benchmark JSON retains no source text and records enough stage detail
/// to distinguish an indexed posting lookup from an accidental full-row
/// SwiftData fault/decode.
private struct V9SearchBenchmarkBreakdownSummary {
    let samples: [V9SearchPerformanceBreakdown]

    var jsonObject: [String: Any] {
        [
            "sample_count": samples.count,
            "query_term_count_p95": percentile(samples.map(\.queryTermCount)),
            "posting_row_count_p95": percentile(samples.map(\.postingRowCount)),
            "posting_candidate_count_p95": percentile(samples.map(\.postingCandidateCount)),
            "candidate_paper_row_count_p95": percentile(samples.map(\.candidatePaperRowCount)),
            "decoded_paper_count_p95": percentile(samples.map(\.decodedPaperCount)),
            "posting_lookup_p95_ms": percentile(samples.map(\.postingLookupMilliseconds)),
            "posting_decode_and_intersection_p95_ms": percentile(samples.map(\.postingDecodeAndIntersectionMilliseconds)),
            "candidate_paper_fetch_p95_ms": percentile(samples.map(\.candidatePaperFetchMilliseconds)),
            "paper_decode_p95_ms": percentile(samples.map(\.paperDecodeMilliseconds)),
            "result_sort_p95_ms": percentile(samples.map(\.resultSortMilliseconds))
        ]
    }

    private func percentile(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.95).rounded(.up)))]
    }
}

/// Evidence for the active V7 domain store.  It intentionally remains a
/// distinct object in the benchmark JSON: V6 and V7 measurements are not
/// interchangeable, even when both use SwiftData and the same synthetic data
/// cardinalities.
private struct V7ActiveDomainBenchmark {
    let authors: Int
    let papers: Int
    let links: Int
    let chunks: Int
    let seedMilliseconds: Int
    let coldOpenSamples: [Int]
    let snapshotMaterializationSamples: [Int]
    let warmSamples: [Int]
    let mutationSamples: [Int]
    let warmResultCount: Int
    let backupMilliseconds: Int
    let backupVerified: Bool
    let storeFamilyBytes: Int64

    var coldOpenP95: Int { percentile(coldOpenSamples, percentile: 0.95) }
    var snapshotMaterializationP95: Int { percentile(snapshotMaterializationSamples, percentile: 0.95) }
    var warmSearchP95: Int { percentile(warmSamples, percentile: 0.95) }
    var singleRowMutationP95: Int { percentile(mutationSamples, percentile: 0.95) }

    var jsonObject: [String: Any] {
        [
            "store": "SwiftData-disk-backed-V7-active-domain",
            "authors": authors,
            "papers": papers,
            "links": links,
            "chunks": chunks,
            "seed_ms": seedMilliseconds,
            "cold_open_samples_ms": coldOpenSamples,
            "cold_open_p95_ms": coldOpenP95,
            "snapshot_materialization_samples_ms": snapshotMaterializationSamples,
            "snapshot_materialization_p95_ms": snapshotMaterializationP95,
            "warm_search_p95_ms": warmSearchP95,
            "single_row_mutation_p95_ms": singleRowMutationP95,
            "warm_search_result_count": warmResultCount,
            "backup_ms": backupMilliseconds,
            "backup_verified": backupVerified,
            "store_family_bytes": storeFamilyBytes
        ]
    }

    private func percentile(_ values: [Int], percentile: Double) -> Int {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * percentile).rounded(.up)))]
    }
}

/// Final product-store metrics.  They remain separate from V6/V7 legacy
/// compatibility figures so release evidence always names the active schema.
private struct V9FinalTypedBenchmark {
    let authors: Int
    let papers: Int
    let links: Int
    let chunks: Int
    let fullTextDocuments: Int
    let radarEvents: Int
    let userAnnotations: Int
    let tags: Int
    let collections: Int
    let migrationMilliseconds: Int
    let indexBuildMilliseconds: Int
    let coldOpenSamples: [Int]
    let warmSamples: [Int]
    let warmSearchBreakdowns: [V9SearchPerformanceBreakdown]
    let mutationSamples: [Int]
    let warmResultCount: Int
    let backupMilliseconds: Int
    let backupVerified: Bool
    let storeFamilyBytes: Int64
    let sourceStoreName: String
    let expectedSourceCounts: (Int, Int, Int, Int)

    var coldOpenP95: Int { percentile(coldOpenSamples, percentile: 0.95) }
    var coldOpenP50: Int { percentile(coldOpenSamples, percentile: 0.50) }
    var warmSearchP95: Int { percentile(warmSamples, percentile: 0.95) }
    var warmSearchP50: Int { percentile(warmSamples, percentile: 0.50) }
    var singleRowMutationP95: Int { percentile(mutationSamples, percentile: 0.95) }
    var singleRowMutationP50: Int { percentile(mutationSamples, percentile: 0.50) }

    var jsonObject: [String: Any] {
        [
            "store": "SwiftData-disk-backed-V9-final-typed-indexed",
            "source_store_name": sourceStoreName,
            "authors": authors,
            "papers": papers,
            "links": links,
            "chunks": chunks,
            "full_text_documents": fullTextDocuments,
            "radar_events": radarEvents,
            "user_annotations": userAnnotations,
            "tags": tags,
            "collections": collections,
            "expected_source_authors": expectedSourceCounts.0,
            "expected_source_papers": expectedSourceCounts.1,
            "expected_source_links": expectedSourceCounts.2,
            "expected_source_chunks": expectedSourceCounts.3,
            "v7_to_v8_staged_migration_ms": migrationMilliseconds,
            "v9_index_build_ms": indexBuildMilliseconds,
            "cold_open_samples_ms": coldOpenSamples,
            "cold_open_p50_ms": coldOpenP50,
            "cold_open_p95_ms": coldOpenP95,
            "warm_search_p50_ms": warmSearchP50,
            "warm_search_p95_ms": warmSearchP95,
            "warm_search_breakdown": V9SearchBenchmarkBreakdownSummary(samples: warmSearchBreakdowns).jsonObject,
            "single_row_mutation_p50_ms": singleRowMutationP50,
            "single_row_mutation_p95_ms": singleRowMutationP95,
            "warm_search_result_count": warmResultCount,
            "backup_ms": backupMilliseconds,
            "backup_verified": backupVerified,
            "store_family_bytes": storeFamilyBytes
        ]
    }

    private func percentile(_ values: [Int], percentile: Double) -> Int {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * percentile).rounded(.up)))]
    }
}

private struct MigrationBenchmark {
    let milliseconds: Int
    let migratedPaperCount: Int
}

private struct V10FormulaDocumentFixture {
    let paperID: Int
    let inventory: FormulaInventory
    let batches: [NumberedEquationBatch]
    let parseMilliseconds: Int
    let batchPlanMilliseconds: Int
    let mergeValidationMilliseconds: Int
}

private struct V12FormulaDiskBenchmark {
    let inputManifestSHA256: String
    let authors: Int
    let papers: Int
    let links: Int
    let chunks: Int
    let radarEvents: Int
    let formulaInventoryCount: Int
    let formulaCount: Int
    let inventoryWriteSamplesMs: [Int]
    let inventoryWriteTotalMs: Int
    let formulaParseSamplesMs: [Int]
    let batchPlanSamplesMs: [Int]
    let batchPlansPerInventory: [Int]
    let mergeValidationSamplesMs: [Int]
    let coldReopenSamplesMs: [Int]
    let warmSearchSamplesMs: [Int]
    let warmSearchResultCount: Int
    let searchBreakdowns: [V9SearchPerformanceBreakdown]
    let readMutationSamplesMs: [Int]
    let favoriteMutationSamplesMs: [Int]
    let noteMutationSamplesMs: [Int]
    let formulaInventoryReadSamplesMs: [Int]
    let formulaInventoryReadCount: Int
    let formulaJobReadSamplesMs: [Int]
    let formulaJobCommitSamplesMs: [Int]
    let formulaBatchCount: Int
    let backupVerified: Bool
    let v7SeedMilliseconds: Int
    let v7ToV8Milliseconds: Int
    let v8ToV12OpenMilliseconds: Int
    let indexBuildMilliseconds: Int
    let storeBytes: Int64
    let searchIndexTokenRows: Int
    let searchIndexPayloadBytes: Int
    let formulaInventoryPayloadBytes: Int
    let formulaItemPayloadBytes: Int
    let formulaJobRows: Int
    let formulaClaimRows: Int
    let formulaStructuredStepRows: Int
    let formulaSegmentRows: Int
    let formulaSegmentStepRows: Int
    let batchCheckpointRows: Int
    let formulaRowsAfterWork: Int
    let rssBeforeFormulaWorkBytes: Int64
    let rssAfterFormulaSeedBytes: Int64
    let rssPeakBytes: Int64
    let totalWallMilliseconds: Int

    private var coldReopenP50: Int { benchmarkPercentile(coldReopenSamplesMs, percentile: 0.50) }
    private var coldReopenP95: Int { benchmarkPercentile(coldReopenSamplesMs, percentile: 0.95) }
    private var warmSearchP50: Int { benchmarkPercentile(warmSearchSamplesMs, percentile: 0.50) }
    private var warmSearchP95: Int { benchmarkPercentile(warmSearchSamplesMs, percentile: 0.95) }
    private var readMutationP95: Int { benchmarkPercentile(readMutationSamplesMs, percentile: 0.95) }
    private var favoriteMutationP95: Int { benchmarkPercentile(favoriteMutationSamplesMs, percentile: 0.95) }
    private var noteMutationP95: Int { benchmarkPercentile(noteMutationSamplesMs, percentile: 0.95) }

    var jsonObject: [String: Any] {
        [
            "schema_version": "latticelens-benchmark-v12-formula",
            "persistence_schema_version": 12,
            "input_manifest_sha256": inputManifestSHA256,
            "build": ["configuration": "SwiftPM-debug-XCTest", "product_version": "2.0.0", "build_number": 211],
            "machine": [
                "architecture": benchmarkArchitectureName(),
                "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
                "logical_cpu_count": ProcessInfo.processInfo.processorCount,
                "active_cpu_count": ProcessInfo.processInfo.activeProcessorCount,
                "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory
            ],
            "dataset": [
                "authors": authors, "papers": papers, "paper_author_links": links,
                "evidence_chunks": chunks, "radar_events": radarEvents,
                "formula_inventories": formulaInventoryCount, "formulas": formulaCount,
                "formulas_per_inventory": 250
            ],
            "thresholds_ms": [
                "cold_reopen_p95": 5_000, "warm_search_p95": 250,
                "read_mutation_p95": 100, "favorite_mutation_p95": 100,
                "note_mutation_p95": 100
            ],
            "measurements": [
                "cold_reopen": ["sample_count": coldReopenSamplesMs.count,
                                 "samples_ms": coldReopenSamplesMs, "p50_ms": coldReopenP50,
                                 "p95_ms": coldReopenP95,
                                 "method": "20 separately restored byte-verified store-family clones; time covers new V12 ModelContainer construction and excludes clone restore and post-open integrity read; OS page cache was not flushed."],
                "warm_search": ["sample_count": warmSearchSamplesMs.count,
                                "samples_ms": warmSearchSamplesMs, "p50_ms": warmSearchP50,
                                "p95_ms": warmSearchP95, "result_count": warmSearchResultCount,
                                "v9_index_breakdown": V9SearchBenchmarkBreakdownSummary(samples: searchBreakdowns).jsonObject],
                "read_mutation": ["sample_count": readMutationSamplesMs.count,
                                  "samples_ms": readMutationSamplesMs,
                                  "p95_ms": readMutationP95, "operation": "V8TypedLibraryStore.markRead"],
                "favorite_mutation": ["sample_count": favoriteMutationSamplesMs.count,
                                      "samples_ms": favoriteMutationSamplesMs,
                                      "p95_ms": favoriteMutationP95, "operation": "V8TypedLibraryStore.applyReferenceMutation(setFavorite)"],
                "note_mutation": ["sample_count": noteMutationSamplesMs.count,
                                  "samples_ms": noteMutationSamplesMs,
                                  "p95_ms": noteMutationP95, "operation": "V8TypedLibraryStore.applyReferenceMutation(upsertNote)"],
                "formula_inventory_read": ["sample_count": formulaInventoryReadSamplesMs.count,
                                           "samples_ms": formulaInventoryReadSamplesMs,
                                           "p95_ms": benchmarkPercentile(formulaInventoryReadSamplesMs, percentile: 0.95),
                                           "items_per_result": formulaInventoryReadCount],
                "formula_job_read": ["sample_count": formulaJobReadSamplesMs.count,
                                     "samples_ms": formulaJobReadSamplesMs,
                                     "p95_ms": benchmarkPercentile(formulaJobReadSamplesMs, percentile: 0.95),
                                     "claims_per_result": formulaClaimRows,
                                     "structured_steps_per_result": formulaStructuredStepRows,
                                     "segments_per_result": formulaSegmentRows,
                                     "segment_steps_per_result": formulaSegmentStepRows],
                "formula_job_checkpoint_commit": ["sample_count": formulaJobCommitSamplesMs.count,
                                                   "samples_ms": formulaJobCommitSamplesMs,
                                                   "p50_ms": benchmarkPercentile(formulaJobCommitSamplesMs, percentile: 0.50),
                                                   "p95_ms": benchmarkPercentile(formulaJobCommitSamplesMs, percentile: 0.95)]
            ],
            "formula_work": [
                "html_parse_sample_count": formulaParseSamplesMs.count,
                "html_parse_samples_ms": formulaParseSamplesMs,
                "html_parse_p95_ms": benchmarkPercentile(formulaParseSamplesMs, percentile: 0.95),
                "inventory_write_sample_count": inventoryWriteSamplesMs.count,
                "inventory_write_samples_ms": inventoryWriteSamplesMs,
                "inventory_write_p50_ms": benchmarkPercentile(inventoryWriteSamplesMs, percentile: 0.50),
                "inventory_write_p95_ms": benchmarkPercentile(inventoryWriteSamplesMs, percentile: 0.95),
                "inventory_write_total_ms": inventoryWriteTotalMs,
                "batch_plan_sample_count": batchPlanSamplesMs.count,
                "batch_plan_samples_ms": batchPlanSamplesMs,
                "batch_plan_p95_ms": benchmarkPercentile(batchPlanSamplesMs, percentile: 0.95),
                "batch_size": 8,
                "batches_per_inventory": batchPlansPerInventory,
                "total_batch_plans": batchPlansPerInventory.reduce(0, +),
                "merge_validation_sample_count": mergeValidationSamplesMs.count,
                "merge_validation_samples_ms": mergeValidationSamplesMs,
                "merge_validation_p95_ms": benchmarkPercentile(mergeValidationSamplesMs, percentile: 0.95),
                "formula_job_batch_count": formulaBatchCount,
                "formula_inventory_limit_per_document": FormulaInventory.maximumItems,
                "claim_fixture_scope": "Eight canonical claims, structured steps, and append-only V12 segment receipts exercise source-coverage persistence; this synthetic coverage is not mathematical or physical correctness evidence."
            ],
            "setup_ms": [
                "v7_synthetic_seed": v7SeedMilliseconds,
                "v7_to_v8_staged_migration": v7ToV8Milliseconds,
                "v8_to_v12_schema_open_and_migration": v8ToV12OpenMilliseconds,
                "v9_search_index_build": indexBuildMilliseconds
            ],
            "storage": [
                "disk_backed": true,
                "backup_verified": backupVerified,
                "store_family_bytes": storeBytes,
                "search_index_token_rows": searchIndexTokenRows,
                "search_index_payload_bytes": searchIndexPayloadBytes,
                "formula_inventory_payload_bytes": formulaInventoryPayloadBytes,
                "formula_item_payload_bytes": formulaItemPayloadBytes,
                "formula_inventory_rows": formulaInventoryCount,
                "formula_item_rows": formulaRowsAfterWork,
                "formula_job_rows": formulaJobRows,
                "formula_claim_rows": formulaClaimRows,
                "formula_structured_step_rows": formulaStructuredStepRows,
                "formula_segment_rows": formulaSegmentRows,
                "formula_segment_step_rows": formulaSegmentStepRows,
                "batch_checkpoint_rows": batchCheckpointRows
            ],
            "row_commit_encode_work": [
                "inventory_upsert": "One production repository save per inventory, one ModelContext save, inventory payload encoded once and each of 250 item payloads encoded separately.",
                "formula_job_checkpoint_mutation": [
                    "samples": formulaJobCommitSamplesMs.count,
                    "job_rows_visited_per_commit": 1,
                    "canonical_claim_rows_touched_per_commit": formulaClaimRows,
                    "canonical_structured_step_rows_touched_per_commit": formulaStructuredStepRows,
                    "batch_checkpoint_rows_visited_per_commit": formulaBatchCount,
                    "context_save_calls_per_commit": 1,
                    "canonical_segment_rows_visited_per_commit": formulaSegmentRows,
                    "canonical_segment_step_rows_visited_per_commit": formulaSegmentStepRows,
                    "measurement_basis": "Source-derived from the V12 FormulaJobStoring implementation; row-family counts describe repository reads/upserts, not SQLite statement instrumentation."
                ],
                "read_mutation": ["logical domain rows per commit": 2, "context save calls per mutation": 1,
                                  "encoding": "typed scalar updates; no full Paper JSON re-encode"],
                "favorite_and_note_mutations": "Production LibraryStoring applyReferenceMutation paths; timing includes search-index maintenance."
            ],
            "rss": [
                "process_peak_bytes": rssPeakBytes,
                "before_formula_inventory_persistence_peak_bytes": rssBeforeFormulaWorkBytes,
                "after_formula_inventory_seed_peak_bytes": rssAfterFormulaSeedBytes,
                "additional_high_water_during_inventory_seed_bytes": max(0, rssAfterFormulaSeedBytes - rssBeforeFormulaWorkBytes),
                "scope": "Dedicated XCTest process high-water mark; includes synthetic V7 seed and schema/index setup, not a per-paper or per-formula isolated allocation measurement."
            ],
            "total_wall_ms": totalWallMilliseconds
        ]
    }
}

private func benchmarkPercentile(_ values: [Int], percentile: Double) -> Int {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * percentile).rounded(.up)))]
}

private func benchmarkMaximumResidentSetSizeBytes() -> Int64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
    return Int64(usage.ru_maxrss)
}

private func benchmarkStoreFamilyByteCount(_ storeURL: URL, fileManager: FileManager) throws -> Int64 {
    var total: Int64 = 0
    for url in [storeURL, URL(fileURLWithPath: storeURL.path + "-wal"), URL(fileURLWithPath: storeURL.path + "-shm")]
    where fileManager.fileExists(atPath: url.path) {
        guard let size = try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else { continue }
        total += size.int64Value
    }
    return total
}

private func benchmarkArchitectureName() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}

private enum BenchmarkFailure: LocalizedError {
    case rootAlreadyExists(String)
    case insufficientColdOpenSamples
    case untrustedBenchmarkRoot(String)
    case untrustedBenchmarkOutput(String)
    case invalidSyntheticFormulaFixture(String)

    var errorDescription: String? {
        switch self {
        case .rootAlreadyExists(let path): "Benchmark scratch already exists: \(path)"
        case .insufficientColdOpenSamples: "The disk benchmark did not collect its required cold-open samples."
        case .untrustedBenchmarkRoot(let path): "Benchmark root is outside the verifier-owned project scratch: \(path)"
        case .untrustedBenchmarkOutput(let path): "Benchmark receipt output is outside the current project: \(path)"
        case .invalidSyntheticFormulaFixture(let reason): reason
        }
    }
}
