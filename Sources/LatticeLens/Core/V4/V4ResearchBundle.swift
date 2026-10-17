import Foundation
import SwiftData

/// Local, user-selected research bundle.  It is deliberately a directory
/// package so a cancelled export cannot leave a half-written zip that looks
/// valid.  The bundle contains a sanitized LibrarySnapshot plus a manifest;
/// PDF bytes can be opted in explicitly and are copied only from the
/// app-owned cache root.
struct V4BundleDryRun: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let paperCount: Int
    let noteCount: Int
    let annotationCount: Int
    let conflictPaperIDs: [Int]
    let missingFiles: [String]
    let tamperedFiles: [String]
}

struct V4ResearchBundleImportPreview: Identifiable, Sendable {
    let id: UUID
    let sourceURL: URL
    let manifest: V4BundleManifest
    let dryRun: V4BundleDryRun

    init(sourceURL: URL, manifest: V4BundleManifest, dryRun: V4BundleDryRun) {
        id = UUID()
        self.sourceURL = sourceURL
        self.manifest = manifest
        self.dryRun = dryRun
    }

    var includedPDFCount: Int {
        manifest.files.filter { $0.relativePath.hasPrefix("pdf/") }.count
    }
}

enum V4ResearchBundleError: LocalizedError, Equatable, Sendable {
    case invalidRoot
    case missingManifest
    case hashMismatch(String)
    case unsupportedSchema(Int)
    case duplicatePaperID(Int)
    case activeTargetExists
    case malformedLibrary
    case malformedTypedState(String)
    case missingPDFAsset(String)
    case invalidActiveLibraryDescriptor

    var errorDescription: String? {
        switch self {
        case .invalidRoot: "bundle 路径必须是目录 package"
        case .missingManifest: "bundle 缺少 manifest.json"
        case .hashMismatch(let path): "bundle 文件 hash 不匹配：\(path)"
        case .unsupportedSchema(let version): "bundle schema 不受支持：\(version)"
        case .duplicatePaperID(let id): "bundle 包含重复 paper id：\(id)"
        case .activeTargetExists: "恢复目标已存在；不会覆盖 active library"
        case .malformedLibrary: "bundle library.json 无法解码"
        case .malformedTypedState(let detail): "bundle V10 typed state 无效：\(detail)"
        case .missingPDFAsset(let filename): "bundle 缺少可验证的 PDF 文件：\(filename)"
        case .invalidActiveLibraryDescriptor: "active library descriptor 无效；当前资料库未切换"
        }
    }
}

enum V4BundleRestoreCheckpoint: String, CaseIterable, Sendable {
    case stagingStoreOpened
    case libraryMaterialized
    case searchIndexRebuilt
    case typedStateMaterialized
    case beforeSemanticComparison
}

enum V4ResearchBundle {
    static let legacySchemaVersion = 5
    static let firstTypedSchemaVersion = 6
    static let schemaVersion = 7

    static func export(snapshot: LibrarySnapshot, to destination: URL, includePDFBytes: Bool = false,
                       pdfRoot: URL? = nil, appVersion: String = "LatticeLens-v4") throws -> V4BundleManifest {
        try writeBundle(snapshot: snapshot, typedState: nil, to: destination, includePDFBytes: includePDFBytes,
                        pdfRoot: pdfRoot, appVersion: appVersion)
    }

    static func exportV2(snapshot: LibrarySnapshot, typedContext: ModelContext, to destination: URL,
                         includePDFBytes: Bool = false, pdfRoot: URL? = nil,
                         appVersion: String = "LatticeLens-2.0") throws -> V4BundleManifest {
        let typedState = try V10ResearchBundleState.capture(from: typedContext, snapshot: snapshot)
        return try writeBundle(snapshot: snapshot, typedState: typedState, to: destination,
                               includePDFBytes: includePDFBytes, pdfRoot: pdfRoot, appVersion: appVersion)
    }

    private static func writeBundle(snapshot: LibrarySnapshot, typedState: V10ResearchBundleState?,
                                    to destination: URL, includePDFBytes: Bool,
                                    pdfRoot: URL?, appVersion: String) throws -> V4BundleManifest {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { throw V4ResearchBundleError.activeTargetExists }
        guard !includePDFBytes || pdfRoot != nil else { throw V4ResearchBundleError.missingPDFAsset("PDF cache root") }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
        var sanitized = snapshot
        // PDF bytes and transient local paths are opt-in.  Metadata chunks and
        // annotations remain provenance-bearing but never reveal a filesystem
        // path in the default bundle.
        if !includePDFBytes {
            sanitized.fullTextDocuments = sanitized.fullTextDocuments.mapValues { value in
                var copy = value; copy.localFilename = nil; return copy
            }
            sanitized.contentBlobs = sanitized.contentBlobs.mapValues { value in
                var copy = value; copy.localFilename = nil; return copy
            }
        }
        let libraryData = try JSONEncoder.latticeLens.encode(sanitized)
        try libraryData.write(to: destination.appendingPathComponent("library.json"), options: .atomic)
        var files: [String: Data] = ["library.json": libraryData]
        if let typedState {
            let stateData = try JSONEncoder.latticeLens.encode(typedState)
            try stateData.write(to: destination.appendingPathComponent("v10-state.json"), options: .atomic)
            files["v10-state.json"] = stateData
        }
        if includePDFBytes, let pdfRoot {
            let pdfDirectory = destination.appendingPathComponent("pdf", isDirectory: true)
            try manager.createDirectory(at: pdfDirectory, withIntermediateDirectories: true)
            var blobsByFilename = [String: [ContentBlob]]()
            for blob in snapshot.contentBlobs.values {
                if let filename = blob.localFilename {
                    blobsByFilename[filename, default: []].append(blob)
                }
            }
            for (filename, blobs) in blobsByFilename.sorted(by: { $0.key < $1.key }) {
                guard Set(blobs.map(\.hash)).count == 1 else {
                    throw V4ResearchBundleError.missingPDFAsset("conflicting blob hashes for \(filename)")
                }
                let source = try V4OwnedPath.canonicalFile(named: filename, root: pdfRoot)
                guard manager.fileExists(atPath: source.path) else {
                    throw V4ResearchBundleError.missingPDFAsset(filename)
                }
                let data = try Data(contentsOf: source)
                guard StableHash.sha256(data) == blobs.first?.hash else {
                    throw V4ResearchBundleError.missingPDFAsset(filename)
                }
                let relative = "pdf/\(source.lastPathComponent)"
                try data.write(to: destination.appendingPathComponent(relative), options: .atomic)
                files[relative] = data
            }
        }
        let counts = ["papers": sanitized.papers.count, "authors": sanitized.authors.count,
                      "notes": sanitized.notes.count, "annotations": sanitized.userEvidenceAnchors.count,
                      "workspaces": sanitized.workspaces.count, "imports": sanitized.importedBibliographies.count]
        var recordCounts = counts
        if let typedState { recordCounts.merge(typedState.recordCounts) { _, typed in typed } }
        let manifest = V4BundleManifest.make(schemaVersion: typedState == nil ? legacySchemaVersion : schemaVersion,
                                              files: files, recordCounts: recordCounts,
                                              includesPDFBytes: includePDFBytes, appVersion: appVersion, createdAt: Date())
        let manifestData = try JSONEncoder.latticeLens.encode(manifest)
        try manifestData.write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
        return manifest
        } catch {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
            if let values = try? destination.resourceValues(forKeys: keys),
               values.isDirectory == true, values.isSymbolicLink != true {
                try? manager.removeItem(at: destination)
            }
            throw error
        }
    }

    static func verify(_ bundle: URL) throws -> V4BundleManifest {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bundle.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw V4ResearchBundleError.invalidRoot }
        let manifestURL = bundle.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL), let manifest = try? JSONDecoder.latticeLens.decode(V4BundleManifest.self, from: data) else {
            throw V4ResearchBundleError.missingManifest
        }
        guard manifest.schemaVersion <= schemaVersion else { throw V4ResearchBundleError.unsupportedSchema(manifest.schemaVersion) }
        if manifest.schemaVersion >= firstTypedSchemaVersion {
            guard manifest.files.contains(where: { $0.relativePath == "v10-state.json" }),
                  let stateData = try? Data(contentsOf: bundle.appendingPathComponent("v10-state.json")),
                  let state = try? JSONDecoder.latticeLens.decode(V10ResearchBundleState.self, from: stateData) else {
                throw V4ResearchBundleError.malformedTypedState("缺少或无法解码 v10-state.json")
            }
            try state.validate()
            guard state.recordCounts.allSatisfy({ manifest.recordCounts[$0.key] == $0.value }) else {
                throw V4ResearchBundleError.malformedTypedState("manifest typed record counts 不一致")
            }
        }
        let expectedHash = StableHash.sha256((try? JSONEncoder.latticeLens.encode(manifest.files)) ?? Data())
        guard expectedHash == manifest.manifestHash else { throw V4ResearchBundleError.hashMismatch("manifest.json") }
        for entry in manifest.files {
            let file = try V4OwnedPath.canonicalFile(named: entry.relativePath, root: bundle)
            guard FileManager.default.fileExists(atPath: file.path) else { throw V4ResearchBundleError.hashMismatch(entry.relativePath) }
            let fileData = try Data(contentsOf: file)
            guard fileData.count == entry.byteCount, StableHash.sha256(fileData) == entry.sha256 else {
                throw V4ResearchBundleError.hashMismatch(entry.relativePath)
            }
        }
        return manifest
    }

    static func dryRun(_ bundle: URL, activeSnapshot: LibrarySnapshot) throws -> V4BundleDryRun {
        let manifest = try verify(bundle)
        guard let libraryData = try? Data(contentsOf: bundle.appendingPathComponent("library.json")),
              let incoming = try? JSONDecoder.latticeLens.decode(LibrarySnapshot.self, from: libraryData) else {
            throw V4ResearchBundleError.malformedLibrary
        }
        var seen = Set<Int>()
        for id in incoming.papers.keys where !seen.insert(id).inserted { throw V4ResearchBundleError.duplicatePaperID(id) }
        let expectedCounts = ["papers": incoming.papers.count, "authors": incoming.authors.count,
            "notes": incoming.notes.count, "annotations": incoming.userEvidenceAnchors.count,
            "workspaces": incoming.workspaces.count, "imports": incoming.importedBibliographies.count]
        guard expectedCounts.allSatisfy({ key, value in
            manifest.recordCounts[key].map { $0 == value } ?? true
        }) else { throw V4ResearchBundleError.malformedLibrary }
        let conflicts = incoming.papers.keys.filter { activeSnapshot.papers[$0] != nil }.sorted()
        return V4BundleDryRun(schemaVersion: manifest.schemaVersion, paperCount: incoming.papers.count,
                              noteCount: incoming.notes.count, annotationCount: incoming.userEvidenceAnchors.count,
                              conflictPaperIDs: conflicts, missingFiles: [], tamperedFiles: [])
    }

    /// Copies explicitly included, content-addressed PDF assets into a unique
    /// caller-owned staging directory. Nothing is installed into the active
    /// cache until the user confirms the staged library activation.
    static func stagePDFAssets(from bundle: URL, into stagingDirectory: URL) throws -> V4BundlePDFStage {
        let manifest = try verify(bundle)
        guard manifest.includesPDFBytes else {
            guard !manifest.files.contains(where: { $0.relativePath.hasPrefix("pdf/") }) else {
                throw V4ResearchBundleError.malformedLibrary
            }
            return V4BundlePDFStage(directory: nil, assets: [])
        }
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("library.json")),
              let snapshot = try? JSONDecoder.latticeLens.decode(LibrarySnapshot.self, from: data) else {
            throw V4ResearchBundleError.malformedLibrary
        }
        var byFilename = [String: [ContentBlob]]()
        for blob in snapshot.contentBlobs.values {
            if let filename = blob.localFilename {
                byFilename[filename, default: []].append(blob)
            }
        }
        let referencedPDFs = Set(byFilename.keys.map { "pdf/\($0)" })
        let bundledPDFs = Set(manifest.files.map(\.relativePath).filter { $0.hasPrefix("pdf/") })
        guard referencedPDFs == bundledPDFs else {
            throw V4ResearchBundleError.missingPDFAsset("PDF file inventory does not match library content blobs")
        }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: stagingDirectory.path) else {
            throw V4ResearchBundleError.activeTargetExists
        }
        try manager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        do {
            var assets: [V4BundlePDFAsset] = []
            for (filename, matches) in byFilename.sorted(by: { $0.key < $1.key }) {
                guard !filename.isEmpty, !filename.contains("/"), !filename.contains("\\"),
                      !filename.contains(".."), !filename.hasPrefix("/") else {
                    throw V4ResearchBundleError.missingPDFAsset(filename)
                }
                let hashes = Set(matches.map(\.hash))
                guard hashes.count == 1,
                      let entry = manifest.files.first(where: { $0.relativePath == "pdf/\(filename)" }) else {
                    throw V4ResearchBundleError.missingPDFAsset(filename)
                }
                let source = try V4OwnedPath.canonicalFile(named: entry.relativePath, root: bundle)
                let pdfData = try Data(contentsOf: source)
                guard pdfData.count == entry.byteCount,
                      StableHash.sha256(pdfData) == entry.sha256,
                      StableHash.sha256(pdfData) == hashes.first else {
                    throw V4ResearchBundleError.hashMismatch(entry.relativePath)
                }
                let destination = stagingDirectory.appendingPathComponent(filename)
                try pdfData.write(to: destination, options: .atomic)
                assets.append(V4BundlePDFAsset(filename: filename, sha256: entry.sha256, byteCount: entry.byteCount))
            }
            return V4BundlePDFStage(directory: stagingDirectory, assets: assets)
        } catch {
            if manager.fileExists(atPath: stagingDirectory.path) { try? manager.removeItem(at: stagingDirectory) }
            throw error
        }
    }

    /// Installs only files absent from the cache. Existing content-addressed
    /// files are reused only when their hashes match; conflicting bytes fail
    /// closed and are never overwritten.
    static func installStagedPDFAssets(_ stage: V4BundlePDFStage, into cacheDirectory: URL) throws -> [URL] {
        guard !stage.assets.isEmpty else { return [] }
        guard let sourceDirectory = stage.directory else { throw V4ResearchBundleError.invalidRoot }
        let manager = FileManager.default
        try manager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        var installed: [URL] = []
        do {
            for asset in stage.assets {
                guard !asset.filename.isEmpty, !asset.filename.contains("/"), !asset.filename.contains("\\"),
                      !asset.filename.contains(".."), !asset.filename.hasPrefix("/") else {
                    throw V4ResearchBundleError.missingPDFAsset(asset.filename)
                }
                let source = try V4OwnedPath.canonicalFile(named: asset.filename, root: sourceDirectory)
                let destination = try V4OwnedPath.canonicalFile(named: asset.filename, root: cacheDirectory)
                if manager.fileExists(atPath: destination.path) {
                    let existing = try Data(contentsOf: destination)
                    guard existing.count == asset.byteCount, StableHash.sha256(existing) == asset.sha256 else {
                        throw V4ResearchBundleError.hashMismatch(asset.filename)
                    }
                    continue
                }
                try manager.copyItem(at: source, to: destination)
                let copied = try Data(contentsOf: destination)
                guard copied.count == asset.byteCount, StableHash.sha256(copied) == asset.sha256 else {
                    try? manager.removeItem(at: destination)
                    throw V4ResearchBundleError.hashMismatch(asset.filename)
                }
                installed.append(destination)
            }
            return installed
        } catch {
            for file in installed where manager.fileExists(atPath: file.path) {
                if let data = try? Data(contentsOf: file),
                   let expected = stage.assets.first(where: { $0.filename == file.lastPathComponent }),
                   StableHash.sha256(data) == expected.sha256 {
                    try? manager.removeItem(at: file)
                }
            }
            throw error
        }
    }

    static func removeInstalledPDFAssets(_ files: [URL], from stage: V4BundlePDFStage) {
        let manager = FileManager.default
        for file in files {
            guard let expected = stage.assets.first(where: { $0.filename == file.lastPathComponent }),
                  (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let data = try? Data(contentsOf: file), data.count == expected.byteCount,
                  StableHash.sha256(data) == expected.sha256 else { continue }
            try? manager.removeItem(at: file)
        }
    }

    static func discardPDFStage(_ stage: V4BundlePDFStage) {
        guard let directory = stage.directory,
              directory.lastPathComponent.hasPrefix(".latticelens-bundle-pdf-stage-"),
              UUID(uuidString: String(directory.lastPathComponent.dropFirst(".latticelens-bundle-pdf-stage-".count))) != nil else { return }
        let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Restore only into a new, caller-selected target directory.  The active
    /// store is never replaced by this helper; a higher-level coordinator can
    /// atomically switch after its own migration and rollback checks.
    static func restoreToNewStore(_ bundle: URL, target: URL, activeSnapshot: LibrarySnapshot? = nil) throws -> V4BundleDryRun {
        guard !FileManager.default.fileExists(atPath: target.path) else { throw V4ResearchBundleError.activeTargetExists }
        let dryRun = try dryRun(bundle, activeSnapshot: activeSnapshot ?? LibrarySnapshot())
        guard dryRun.schemaVersion <= legacySchemaVersion else {
            throw V4ResearchBundleError.unsupportedSchema(dryRun.schemaVersion)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        let source = bundle.appendingPathComponent("library.json")
        try manager.copyItem(at: source, to: target.appendingPathComponent("library.json"))
        let manifest = bundle.appendingPathComponent("manifest.json")
        try manager.copyItem(at: manifest, to: target.appendingPathComponent("manifest.json"))
        return dryRun
    }

    /// Builds a final typed SwiftData staging library from a verified bundle.
    /// It never opens or replaces an active library: the caller supplies a
    /// previously absent target, and semantic verification must succeed before
    /// this method returns it as usable.  A malformed/tampered bundle leaves
    /// both the active library and no partially trusted target behind.
    @MainActor
    static func restoreToNewTypedStore(_ bundle: URL, targetStoreURL: URL,
                                       activeSnapshot: LibrarySnapshot? = nil) throws -> V4BundleDryRun {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: targetStoreURL.path) else { throw V4ResearchBundleError.activeTargetExists }
        let dryRun = try dryRun(bundle, activeSnapshot: activeSnapshot ?? LibrarySnapshot())
        guard dryRun.schemaVersion <= legacySchemaVersion else {
            throw V4ResearchBundleError.unsupportedSchema(dryRun.schemaVersion)
        }
        guard let libraryData = try? Data(contentsOf: bundle.appendingPathComponent("library.json")),
              let incoming = try? JSONDecoder.latticeLens.decode(LibrarySnapshot.self, from: libraryData) else {
            throw V4ResearchBundleError.malformedLibrary
        }
        let targetParent = targetStoreURL.deletingLastPathComponent()
        try manager.createDirectory(at: targetParent, withIntermediateDirectories: true)
        do {
            let schema = Schema(versionedSchema: LatticeLensSchemaV9.self)
            let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV9.self,
                                               configurations: ModelConfiguration(schema: schema, url: targetStoreURL))
            try V8TypedStoreCodec.materialize(incoming, in: container.mainContext, sourceSchemaVersion: incoming.schemaVersion)
            _ = try V8TypedStoreCodec.verifyMigrationSemanticIntegrity(from: container.mainContext)
            try V9TypedSearchIndex.rebuild(in: container.mainContext)
            guard try V9TypedSearchIndex.isCurrent(in: container.mainContext) else {
                throw LatticeLensError.persistenceUnavailable("V9 local search index verification failed during bundle restore")
            }
            return dryRun
        } catch {
            // This method created the target only after confirming absence, so
            // it may clean up this exact family.  It never touches a caller's
            // pre-existing target or an active library.
            for suffix in ["", "-wal", "-shm"] {
                let member = URL(fileURLWithPath: targetStoreURL.path + suffix)
                if manager.fileExists(atPath: member.path) { try? manager.removeItem(at: member) }
            }
            throw error
        }
    }

    /// Restores schema-5 legacy or schema-6/7 typed bundles into an isolated
    /// V12 store. A schema-5 bundle predates category/formula rows, so its typed
    /// state starts empty while its library snapshot is upgraded.
    @MainActor
    static func restoreToNewTypedStoreV2(_ bundle: URL, targetStoreURL: URL,
                                         activeSnapshot: LibrarySnapshot? = nil,
                                         faultInjector: ((V4BundleRestoreCheckpoint) throws -> Void)? = nil) async throws -> V4BundleDryRun {
        // SwiftData work below is synchronous; observe cancellation at each
        // safe boundary so the exact-target catch can roll back staged rows.
        try Task.checkCancellation()
        let manager = FileManager.default
        guard !manager.fileExists(atPath: targetStoreURL.path) else { throw V4ResearchBundleError.activeTargetExists }
        let dryRun = try dryRun(bundle, activeSnapshot: activeSnapshot ?? LibrarySnapshot())
        try Task.checkCancellation()
        guard let libraryData = try? Data(contentsOf: bundle.appendingPathComponent("library.json")),
              let incoming = try? JSONDecoder.latticeLens.decode(LibrarySnapshot.self, from: libraryData) else {
            throw V4ResearchBundleError.malformedLibrary
        }
        let typedState: V10ResearchBundleState
        if dryRun.schemaVersion >= firstTypedSchemaVersion {
            guard let stateData = try? Data(contentsOf: bundle.appendingPathComponent("v10-state.json")),
                  let decodedState = try? JSONDecoder.latticeLens.decode(V10ResearchBundleState.self, from: stateData) else {
                throw V4ResearchBundleError.malformedTypedState("schema-\(dryRun.schemaVersion) typed state 無法解碼")
            }
            typedState = decodedState
        } else if dryRun.schemaVersion == legacySchemaVersion {
            typedState = V10ResearchBundleState(categoryProfile: nil, categoryMemberships: [],
                formulaInventories: [], formulaJobs: [])
        } else {
            throw V4ResearchBundleError.unsupportedSchema(dryRun.schemaVersion)
        }
        try typedState.validate()
        try typedState.validateCompleteJobs(against: incoming)
        try Task.checkCancellation()
        let targetParent = targetStoreURL.deletingLastPathComponent()
        try manager.createDirectory(at: targetParent, withIntermediateDirectories: true)
        do {
            try Task.checkCancellation()
            let schema = Schema(versionedSchema: LatticeLensSchemaV12.self)
            let container = try ModelContainer(for: schema, migrationPlan: LatticeLensMigrationPlanV12.self,
                                               configurations: ModelConfiguration(schema: schema, url: targetStoreURL))
            try Task.checkCancellation()
            try faultInjector?(.stagingStoreOpened)
            try V8TypedStoreCodec.materialize(incoming, in: container.mainContext,
                                              sourceSchemaVersion: incoming.schemaVersion)
            try Task.checkCancellation()
            try faultInjector?(.libraryMaterialized)
            _ = try V8TypedStoreCodec.verifyMigrationSemanticIntegrity(from: container.mainContext)
            try V9TypedSearchIndex.rebuild(in: container.mainContext)
            try Task.checkCancellation()
            guard try V9TypedSearchIndex.isCurrent(in: container.mainContext) else {
                throw LatticeLensError.persistenceUnavailable("V10 local search index verification failed during bundle restore")
            }
            try faultInjector?(.searchIndexRebuilt)
            try typedState.materialize(into: container.mainContext)
            try Task.checkCancellation()
            try faultInjector?(.typedStateMaterialized)
            let restoredState = try V10ResearchBundleState.capture(from: container.mainContext, snapshot: incoming)
            try faultInjector?(.beforeSemanticComparison)
            guard restoredState == typedState else {
                throw V4ResearchBundleError.malformedTypedState("V10 staging round-trip semantic comparison failed")
            }
            try Task.checkCancellation()
            return dryRun
        } catch {
            // This exact target was absent before this method created it.
            // Remove only its SQLite family; never touch a pre-existing store.
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let member = URL(fileURLWithPath: targetStoreURL.path + suffix)
                if manager.fileExists(atPath: member.path) { try? manager.removeItem(at: member) }
            }
            throw error
        }
    }
}

struct V4BundlePDFAsset: Codable, Equatable, Sendable {
    let filename: String
    let sha256: String
    let byteCount: Int
}

struct V4BundlePDFStage: Equatable, Sendable {
    let directory: URL?
    let assets: [V4BundlePDFAsset]
}

struct V4BundleActiveLibraryDescriptor: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let runID: UUID
    let storeName: String
    let previousStoreName: String
    let bundleManifestHash: String?
    let previousBundleManifestHash: String?
    let activatedAt: Date
}

/// A separate, same-directory descriptor selects a fully built Bundle store
/// only after the user confirms. The original store family is never replaced;
/// the descriptor is atomically swapped and is read on the next app launch.
enum V4BundleActivationCoordinator {
    static let descriptorFilename = ".latticelens-research-bundle-active.json"
    static let schemaVersion = 1

    static func descriptorURL(for baseStoreURL: URL) -> URL {
        baseStoreURL.deletingLastPathComponent().appendingPathComponent(descriptorFilename)
    }

    static func resolveActiveStoreURL(for baseStoreURL: URL,
                                      fileManager: FileManager = .default) throws -> URL? {
        let descriptorURL = descriptorURL(for: baseStoreURL)
        guard fileManager.fileExists(atPath: descriptorURL.path) else { return nil }
        guard try isNotSymbolicLink(descriptorURL, fileManager: fileManager),
              let data = try? Data(contentsOf: descriptorURL),
              let descriptor = try? JSONDecoder.latticeLens.decode(V4BundleActiveLibraryDescriptor.self, from: data),
              descriptor.schemaVersion == schemaVersion else {
            throw V4ResearchBundleError.invalidActiveLibraryDescriptor
        }
        let root = canonicalParent(of: baseStoreURL)
        return try validatedStoreURL(named: descriptor.storeName, in: root, fileManager: fileManager)
    }

    @MainActor
    static func activate(stagingStoreURL: URL, baseStoreURL: URL, bundleManifestHash: String,
                         at date: Date = Date(), fileManager: FileManager = .default) throws -> V4BundleActiveLibraryDescriptor {
        let root = canonicalParent(of: baseStoreURL)
        guard canonicalParent(of: stagingStoreURL) == root,
              stagingStoreURL.lastPathComponent.hasPrefix(".latticelens-bundle-stage-"),
              UUID(uuidString: String(stagingStoreURL.lastPathComponent.dropFirst(".latticelens-bundle-stage-".count)
                .dropLast(".store".count))) != nil else {
            throw V4ResearchBundleError.invalidActiveLibraryDescriptor
        }
        let staged = try validatedStoreURL(named: stagingStoreURL.lastPathComponent, in: root, fileManager: fileManager)
        try validateV12Store(at: staged)
        let existing = try readDescriptor(for: baseStoreURL, fileManager: fileManager)
        let previousURL: URL
        if let existing {
            previousURL = try validatedStoreURL(named: existing.storeName, in: root, fileManager: fileManager)
        } else if let migrated = try V10StoreMigrationCoordinator.resolveActiveStoreURL(
            for: baseStoreURL, targetSchemaVersion: 12, fileManager: fileManager) {
            previousURL = migrated
        } else {
            previousURL = baseStoreURL
        }
        guard previousURL.standardizedFileURL != staged.standardizedFileURL else {
            throw V4ResearchBundleError.invalidActiveLibraryDescriptor
        }
        let descriptor = V4BundleActiveLibraryDescriptor(
            schemaVersion: schemaVersion, runID: UUID(), storeName: staged.lastPathComponent,
            previousStoreName: previousURL.lastPathComponent, bundleManifestHash: bundleManifestHash,
            previousBundleManifestHash: existing?.bundleManifestHash, activatedAt: date
        )
        try write(descriptor, for: baseStoreURL, fileManager: fileManager)
        return descriptor
    }

    static func rollback(for baseStoreURL: URL, at date: Date = Date(),
                         fileManager: FileManager = .default) throws -> V4BundleActiveLibraryDescriptor {
        guard let current = try readDescriptor(for: baseStoreURL, fileManager: fileManager) else {
            throw V4ResearchBundleError.invalidActiveLibraryDescriptor
        }
        let root = canonicalParent(of: baseStoreURL)
        let previous = try validatedStoreURL(named: current.previousStoreName, in: root, fileManager: fileManager)
        let descriptor = V4BundleActiveLibraryDescriptor(
            schemaVersion: schemaVersion, runID: UUID(), storeName: previous.lastPathComponent,
            previousStoreName: current.storeName, bundleManifestHash: current.previousBundleManifestHash,
            previousBundleManifestHash: current.bundleManifestHash, activatedAt: date
        )
        try write(descriptor, for: baseStoreURL, fileManager: fileManager)
        return descriptor
    }

    static func discardStagingStore(at storeURL: URL, baseStoreURL: URL,
                                    fileManager: FileManager = .default) throws {
        let root = canonicalParent(of: baseStoreURL)
        guard canonicalParent(of: storeURL) == root,
              storeURL.lastPathComponent.hasPrefix(".latticelens-bundle-stage-"),
              UUID(uuidString: String(storeURL.lastPathComponent.dropFirst(".latticelens-bundle-stage-".count)
                .dropLast(".store".count))) != nil else {
            throw V4ResearchBundleError.invalidActiveLibraryDescriptor
        }
        if let current = try readDescriptor(for: baseStoreURL, fileManager: fileManager),
           current.storeName == storeURL.lastPathComponent || current.previousStoreName == storeURL.lastPathComponent {
            throw V4ResearchBundleError.invalidActiveLibraryDescriptor
        }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let member = URL(fileURLWithPath: storeURL.path + suffix)
            if fileManager.fileExists(atPath: member.path) {
                guard try isNotSymbolicLink(member, fileManager: fileManager) else {
                    throw V4ResearchBundleError.invalidActiveLibraryDescriptor
                }
                try fileManager.removeItem(at: member)
            }
        }
    }

    private static func readDescriptor(for baseStoreURL: URL,
                                      fileManager: FileManager) throws -> V4BundleActiveLibraryDescriptor? {
        let url = descriptorURL(for: baseStoreURL)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard try isNotSymbolicLink(url, fileManager: fileManager),
              let data = try? Data(contentsOf: url),
              let descriptor = try? JSONDecoder.latticeLens.decode(V4BundleActiveLibraryDescriptor.self, from: data),
              descriptor.schemaVersion == schemaVersion else {
            throw V4ResearchBundleError.invalidActiveLibraryDescriptor
        }
        return descriptor
    }

    private static func write(_ descriptor: V4BundleActiveLibraryDescriptor, for baseStoreURL: URL,
                              fileManager: FileManager) throws {
        let url = descriptorURL(for: baseStoreURL)
        guard try isNotSymbolicLink(url, fileManager: fileManager) else {
            throw V4ResearchBundleError.invalidActiveLibraryDescriptor
        }
        let data = try JSONEncoder.latticeLens.encode(descriptor)
        try data.write(to: url, options: .atomic)
    }

    @MainActor
    private static func validateV12Store(at storeURL: URL) throws {
        let schema = Schema(versionedSchema: LatticeLensSchemaV12.self)
        let configuration = ModelConfiguration(schema: schema, url: storeURL, allowsSave: false)
        let container = try ModelContainer(for: schema, configurations: configuration)
        guard let marker = try container.mainContext.fetch(FetchDescriptor<StoredV8StoreMarker>()).first,
              marker.schemaVersion >= 80 else {
            throw V4ResearchBundleError.malformedTypedState("V12 staging marker 缺失")
        }
        _ = try V10StoreSemanticSummary.make(from: container.mainContext, schemaVersion: 12)
    }

    private static func validatedStoreURL(named name: String, in root: URL,
                                          fileManager: FileManager) throws -> URL {
        guard !name.isEmpty, name.hasSuffix(".store"), name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("..") else {
            throw V4ResearchBundleError.invalidActiveLibraryDescriptor
        }
        let url = root.appendingPathComponent(name).standardizedFileURL
        guard url.deletingLastPathComponent().resolvingSymlinksInPath() == root,
              try isNotSymbolicLink(url, fileManager: fileManager) else {
            throw V4ResearchBundleError.invalidActiveLibraryDescriptor
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        guard values.isRegularFile == true || values.isDirectory == true else {
            throw V4ResearchBundleError.invalidActiveLibraryDescriptor
        }
        return url
    }

    private static func canonicalParent(of url: URL) -> URL {
        url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isNotSymbolicLink(_ url: URL, fileManager: FileManager) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return true }
        return try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
    }
}

private struct V10BundleCategoryProfile: Codable, Hashable, Sendable {
    let id: String
    let revision: Int
    let categories: [String]
    let updatedAt: Date
}

private struct V10BundleCategoryMembership: Codable, Hashable, Sendable {
    let id: String
    let authorID: Int
    let category: String
    let generationID: String
    let isCurrent: Bool
    let updatedAt: Date

    init(_ row: StoredV10AuthorCategoryMembership) {
        id = row.id; authorID = row.authorID; category = row.category
        generationID = row.generationID; isCurrent = row.isCurrent; updatedAt = row.updatedAt
    }

    func insert(into context: ModelContext) {
        context.insert(StoredV10AuthorCategoryMembership(id: id, authorID: authorID, category: category,
            generationID: generationID, isCurrent: isCurrent, updatedAt: updatedAt))
    }
}

private struct V10BundleInventoryItem: Codable, Hashable, Sendable {
    let id: String
    let equationID: String
    let label: String
    let ordinal: Int
    let sourceByteStart: Int
    let sourceByteEnd: Int
    let sourceTeXHash: String
    let anchorID: String?
    let status: String
    let payload: Data

    init(id: String, item: FormulaInventoryItem, status: String = "indexed") throws {
        self.id = id; equationID = item.equationID; label = item.label; ordinal = item.ordinal
        sourceByteStart = item.sourceByteStart; sourceByteEnd = item.sourceByteEnd
        sourceTeXHash = item.normalizedTeXHash; anchorID = item.evidenceID; self.status = status
        payload = try JSONEncoder.latticeLens.encode(item)
    }

    init(_ row: StoredV10FormulaInventoryItem) {
        id = row.id; equationID = row.equationID; label = row.label; ordinal = row.ordinal
        sourceByteStart = row.sourceByteStart; sourceByteEnd = row.sourceByteEnd
        sourceTeXHash = row.sourceTeXHash; anchorID = row.anchorID; status = row.status; payload = row.payload
    }

    func matches(_ item: FormulaInventoryItem) -> Bool {
        equationID == item.equationID && label == item.label && ordinal == item.ordinal &&
            sourceByteStart == item.sourceByteStart && sourceByteEnd == item.sourceByteEnd &&
            sourceTeXHash == item.normalizedTeXHash && anchorID == item.evidenceID &&
            (try? JSONDecoder.latticeLens.decode(FormulaInventoryItem.self, from: payload)) == item
    }

    func insert(paperID: Int, documentID: String, documentHash: String, inventoryHash: String,
                into context: ModelContext) {
        context.insert(StoredV10FormulaInventoryItem(id: id, paperID: paperID, documentID: documentID,
            documentHash: documentHash, inventoryHash: inventoryHash, equationID: equationID, label: label,
            ordinal: ordinal, sourceByteStart: sourceByteStart, sourceByteEnd: sourceByteEnd,
            sourceTeXHash: sourceTeXHash, anchorID: anchorID, status: status, payload: payload))
    }
}

private struct V10BundleFormulaInventory: Codable, Hashable, Sendable {
    let id: String
    let paperID: Int
    let documentID: String
    let documentHash: String
    let inventoryHash: String
    let status: String
    let updatedAt: Date
    let inventory: FormulaInventory
    let items: [V10BundleInventoryItem]

    init(_ row: StoredV10FormulaInventory, itemRows: [StoredV10FormulaInventoryItem]) throws {
        guard let inventory = try? JSONDecoder.latticeLens.decode(FormulaInventory.self, from: row.payload),
              inventory.documentHash == row.documentHash,
              inventory.inventoryHash == row.inventoryHash,
              inventory.parserVersion == row.parserVersion else {
            throw V4ResearchBundleError.malformedTypedState("formula inventory \(row.id) metadata/payload 不一致")
        }
        id = row.id; paperID = row.paperID; documentID = row.documentID
        documentHash = row.documentHash; inventoryHash = row.inventoryHash
        status = row.status; updatedAt = row.updatedAt; self.inventory = inventory
        let matchingRows = itemRows.filter { $0.paperID == row.paperID && $0.inventoryHash == row.inventoryHash }
        if matchingRows.isEmpty {
            items = try inventory.items.map {
                try V10BundleInventoryItem(id: "\(row.id):\($0.ordinal):\($0.equationID)", item: $0)
            }
        } else {
            guard matchingRows.count == inventory.items.count,
                  Set(matchingRows.map(\.equationID)).count == matchingRows.count else {
                throw V4ResearchBundleError.malformedTypedState("formula inventory \(row.id) item rows 不完整或重複")
            }
            var rowsByID = [String: V10BundleInventoryItem]()
            for matchingRow in matchingRows {
                let item = V10BundleInventoryItem(matchingRow)
                guard rowsByID.updateValue(item, forKey: item.equationID) == nil else {
                    throw V4ResearchBundleError.malformedTypedState("formula inventory \(row.id) equation ID 重複")
                }
            }
            guard inventory.items.allSatisfy({ item in rowsByID[item.equationID]?.matches(item) == true }) else {
                throw V4ResearchBundleError.malformedTypedState("formula inventory \(row.id) item payload 不一致")
            }
            items = inventory.items.compactMap { rowsByID[$0.equationID] }
        }
    }

    func insert(into context: ModelContext) throws {
        let payload = try JSONEncoder.latticeLens.encode(inventory)
        context.insert(StoredV10FormulaInventory(id: id, paperID: paperID, documentID: documentID,
            documentHash: documentHash, inventoryHash: inventoryHash, parserVersion: inventory.parserVersion,
            status: status, payload: payload, updatedAt: updatedAt))
        for item in items {
            item.insert(paperID: paperID, documentID: documentID, documentHash: documentHash,
                        inventoryHash: inventoryHash, into: context)
        }
    }
}

private struct V10BundleFormulaJob: Codable, Hashable, Sendable {
    var checkpoint: FormulaDerivationCheckpoint
    let createdAt: Date

    init(_ row: StoredV10FormulaDerivationJob, context: ModelContext) throws {
        let jobID = row.id
        let typedRows = try context.fetch(FetchDescriptor<StoredV11FormulaDerivationJob>(predicate: #Predicate { $0.id == jobID }))
        let segmentRows = try context.fetch(FetchDescriptor<StoredV12FormulaDerivationSegment>(
            predicate: #Predicate { $0.jobID == jobID }))
        let segmentStepRows = try context.fetch(FetchDescriptor<StoredV12FormulaDerivationSegmentStep>(
            predicate: #Predicate { $0.jobID == jobID }))
        guard typedRows.count <= 1 else {
            throw V4ResearchBundleError.malformedTypedState("formula job \(row.id) V11 typed identity 重複")
        }
        let checkpoint: FormulaDerivationCheckpoint
        if let typed = typedRows.first {
            checkpoint = try V10FormulaJobStore.canonicalCheckpoint(row: row, context: typed,
                segmentRows: segmentRows, segmentStepRows: segmentStepRows, modelContext: context)
        } else {
            guard let legacy = try? JSONDecoder.latticeLens.decode(FormulaDerivationCheckpoint.self, from: row.payload) else {
                throw V4ResearchBundleError.malformedTypedState("formula job \(row.id) missing typed rows and legacy Bundle projection")
            }
            checkpoint = legacy
        }
        guard checkpoint.job.jobID == row.id,
              checkpoint.job.paperID == row.paperID,
              checkpoint.job.documentHash == row.documentHash,
              checkpoint.job.inventoryHash == row.inventoryHash,
              checkpoint.job.state.rawValue == row.state,
              checkpoint.promptVersion == row.promptVersion,
              checkpoint.schemaVersion == row.schemaVersion,
              abs(checkpoint.updatedAt.timeIntervalSince(row.updatedAt)) < 1,
              abs(checkpoint.job.startedAt.timeIntervalSince(row.createdAt)) < 1 else {
            throw V4ResearchBundleError.malformedTypedState("formula job \(row.id) metadata/payload 不一致")
        }
        self.checkpoint = checkpoint; createdAt = row.createdAt
    }

    func markingIncomplete() -> Self {
        var copy = self
        copy.checkpoint.job.state = .incomplete
        return copy
    }

    func insert(into context: ModelContext) throws {
        let checkpoint = checkpoint
        let payload = try JSONEncoder.latticeLens.encode(checkpoint)
        context.insert(StoredV10FormulaDerivationJob(id: checkpoint.job.jobID, paperID: checkpoint.job.paperID,
            documentID: "\(checkpoint.job.paperID):\(checkpoint.job.documentHash)",
            documentHash: checkpoint.job.documentHash, inventoryHash: checkpoint.job.inventoryHash,
            state: checkpoint.job.state.rawValue, promptVersion: checkpoint.promptVersion,
            schemaVersion: checkpoint.schemaVersion, createdAt: createdAt,
            updatedAt: checkpoint.updatedAt, payload: payload))
        let encoder = JSONEncoder.latticeLens
        var insertedDependencyIDs = Set<String>()
        for batch in checkpoint.job.batches {
            let equationIDsData = try encoder.encode(batch.equationIDs)
            context.insert(StoredV10FormulaBatch(id: batch.id, jobID: batch.jobID,
                ordinal: batch.batchIndex, equationIDsData: equationIDsData,
                payloadHash: batch.payloadHash, status: batch.status.rawValue,
                updatedAt: batch.updatedAt))
            context.insert(StoredV10FormulaBatchCheckpoint(id: batch.id, jobID: batch.jobID,
                inventoryHash: checkpoint.job.inventoryHash, batchIndex: batch.batchIndex,
                batchTotal: batch.batchTotal, equationIDsData: equationIDsData, requestID: batch.requestID,
                attemptCount: batch.attemptCount, payloadHash: batch.payloadHash,
                receivedBytes: batch.receivedBytes, receivedCharacters: batch.receivedCharacters,
                firstContentAt: batch.firstContentAt, lastContentAt: batch.lastContentAt,
                status: batch.status.rawValue, errorCategory: batch.errorCategory, updatedAt: batch.updatedAt))
            for claim in checkpoint.completedClaimsByBatch[batch.batchIndex, default: []] {
                guard let equationID = claim.equationID else { continue }
                for (ordinal, stepText) in claim.derivationSteps.enumerated() {
                    context.insert(StoredV10FormulaDerivationStep(
                        id: "\(checkpoint.job.jobID):\(equationID):\(ordinal)",
                        jobID: checkpoint.job.jobID, equationID: equationID, ordinal: ordinal,
                        text: stepText, anchorID: claim.evidenceIDs.first,
                        status: "validated_batch_\(batch.batchIndex)"))
                }
                for step in claim.formulaDerivationSteps {
                    for targetID in step.referencedEquationIDs {
                        let dependencyID = V10FormulaJobStore.dependencyID(jobID: checkpoint.job.jobID,
                            equationID: equationID, dependsOnEquationID: targetID)
                        guard insertedDependencyIDs.insert(dependencyID).inserted else { continue }
                        context.insert(StoredV10EquationDependency(id: dependencyID,
                            jobID: checkpoint.job.jobID, equationID: equationID,
                            dependsOnEquationID: targetID, status: step.epistemicStatus.rawValue))
                    }
                }
            }
        }

        let segmentStates = checkpoint.derivationSegmentsByEquation ?? [:]
        guard Set(segmentStates.keys).isSubset(of: Set(checkpoint.job.equationIDs)) else {
            throw V4ResearchBundleError.malformedTypedState("V12 formula segment references an unknown equation")
        }
        let segmentEncoder = JSONEncoder.latticeLens
        segmentEncoder.outputFormatting.insert(.sortedKeys)
        for equationID in checkpoint.job.equationIDs {
            guard let storedState = segmentStates[equationID] else { continue }
            let state = try storedState.validatedCopy()
            guard state.equationID == equationID, !state.segments.isEmpty else {
                throw V4ResearchBundleError.malformedTypedState("V12 formula segment state is empty or mismatched")
            }
            var prefix = FormulaDerivationSegmentCheckpoint(equationID: equationID, sourceTeX: state.sourceTeX)
            for receipt in state.segments {
                let stepsHash = StableHash.sha256(try segmentEncoder.encode(receipt.steps))
                let receiptHash = try FormulaDerivationSegmentCheckpoint.provenanceHash(for: receipt)
                try prefix.appendSegment(index: receipt.index, steps: receipt.steps, isFinal: receipt.isFinal,
                    continuationSummary: receipt.continuationSummary, conclusionZH: receipt.conclusionZH,
                    requestID: receipt.requestID, requestPayloadHash: receipt.requestPayloadHash,
                    responseHash: receipt.responseHash, receivedBytes: receipt.receivedBytes,
                    receivedCharacters: receipt.receivedCharacters, firstContentAt: receipt.firstContentAt,
                    lastContentAt: receipt.lastContentAt)
                let chainHash = try prefix.provenanceHash()
                context.insert(StoredV12FormulaDerivationSegment(
                    id: "\(checkpoint.job.jobID):segment:\(StableHash.sha256(equationID)):\(receipt.index)",
                    jobID: checkpoint.job.jobID, paperID: checkpoint.job.paperID,
                    documentHash: checkpoint.job.documentHash, inventoryHash: checkpoint.job.inventoryHash,
                    equationID: equationID, sourceTeX: state.sourceTeX,
                    sourceTeXHash: StableHash.sha256(state.sourceTeX), segmentIndex: receipt.index,
                    firstOrdinal: receipt.steps[0].ordinal, stepCount: receipt.steps.count,
                    isFinal: receipt.isFinal, continuationSummary: receipt.continuationSummary,
                    conclusionZH: receipt.conclusionZH, requestID: receipt.requestID,
                    requestPayloadHash: receipt.requestPayloadHash, responseHash: receipt.responseHash,
                    receivedBytes: receipt.receivedBytes, receivedCharacters: receipt.receivedCharacters,
                    firstContentAt: receipt.firstContentAt, lastContentAt: receipt.lastContentAt,
                    stepsHash: stepsHash, receiptHash: receiptHash, chainHash: chainHash))
                for step in receipt.steps {
                    context.insert(StoredV12FormulaDerivationSegmentStep(
                        id: "\(checkpoint.job.jobID):segment-step:\(StableHash.sha256(equationID)):\(receipt.index):\(StableHash.sha256(step.stepID))",
                        jobID: checkpoint.job.jobID, equationID: equationID, segmentIndex: receipt.index,
                        stepID: step.stepID, ordinal: step.ordinal, textZH: step.textZH,
                        beforeTeX: step.beforeTeX, afterTeX: step.afterTeX,
                        ruleOrAssumption: step.ruleOrAssumption,
                        referencedEquationIDsData: try segmentEncoder.encode(step.referencedEquationIDs),
                        evidenceAnchorIDsData: try segmentEncoder.encode(step.evidenceAnchorIDs),
                        sourceDocumentHashesData: try segmentEncoder.encode(step.sourceDocumentHashes),
                        epistemicStatus: step.epistemicStatus.rawValue))
                }
            }
            guard prefix == state else {
                throw V4ResearchBundleError.malformedTypedState("V12 formula segment chain failed canonical validation")
            }
        }
    }
}

private struct V10ResearchBundleState: Codable, Hashable, Sendable {
    let categoryProfile: V10BundleCategoryProfile?
    let categoryMemberships: [V10BundleCategoryMembership]
    let formulaInventories: [V10BundleFormulaInventory]
    let formulaJobs: [V10BundleFormulaJob]
    let formulaAnalysisRuns: [V10BundleFormulaAnalysisRun]
    let analysisAttempts: [V10BundleAnalysisAttempt]
    let formulaValidationReports: [V10BundleFormulaValidationReport]
    let readyEvidenceInsightPublications: [V10BundleReadyEvidenceInsightPublication]

    private enum CodingKeys: String, CodingKey {
        case categoryProfile, categoryMemberships, formulaInventories, formulaJobs
        case formulaAnalysisRuns, analysisAttempts, formulaValidationReports, readyEvidenceInsightPublications
    }

    init(categoryProfile: V10BundleCategoryProfile?, categoryMemberships: [V10BundleCategoryMembership],
         formulaInventories: [V10BundleFormulaInventory], formulaJobs: [V10BundleFormulaJob],
         formulaAnalysisRuns: [V10BundleFormulaAnalysisRun] = [],
         analysisAttempts: [V10BundleAnalysisAttempt] = [],
         formulaValidationReports: [V10BundleFormulaValidationReport] = [],
         readyEvidenceInsightPublications: [V10BundleReadyEvidenceInsightPublication] = []) {
        let supersededJobIDs = Set(formulaValidationReports
            .filter { $0.validatorVersion == FormulaCoverageValidator.legacyVersion }
            .map(\.jobID))
        self.categoryProfile = categoryProfile
        self.categoryMemberships = categoryMemberships
        self.formulaInventories = formulaInventories
        self.formulaJobs = formulaJobs.map { job in
            supersededJobIDs.contains(job.checkpoint.job.jobID) && job.checkpoint.job.state == .complete
                ? job.markingIncomplete() : job
        }
        self.formulaAnalysisRuns = formulaAnalysisRuns.map { run in
            guard run.id.hasPrefix("formula:"),
                  supersededJobIDs.contains(String(run.id.dropFirst("formula:".count))) else { return run }
            return run.markingIncomplete()
        }
        self.analysisAttempts = analysisAttempts
        self.formulaValidationReports = formulaValidationReports.map { report in
            report.validatorVersion == FormulaCoverageValidator.legacyVersion ? report.markingStale() : report
        }
        self.readyEvidenceInsightPublications = readyEvidenceInsightPublications
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let categoryProfile = try values.decodeIfPresent(V10BundleCategoryProfile.self, forKey: .categoryProfile)
        let categoryMemberships = try values.decode([V10BundleCategoryMembership].self, forKey: .categoryMemberships)
        let formulaInventories = try values.decode([V10BundleFormulaInventory].self, forKey: .formulaInventories)
        let formulaJobs = try values.decode([V10BundleFormulaJob].self, forKey: .formulaJobs)
        // Schema-6 Bundles written before audit-row support remain readable;
        // absent additive collections are empty, not synthesized records.
        let formulaAnalysisRuns = try values.decodeIfPresent([V10BundleFormulaAnalysisRun].self,
                                                               forKey: .formulaAnalysisRuns) ?? []
        let analysisAttempts = try values.decodeIfPresent([V10BundleAnalysisAttempt].self,
                                                            forKey: .analysisAttempts) ?? []
        let formulaValidationReports = try values.decodeIfPresent([V10BundleFormulaValidationReport].self,
                                                                    forKey: .formulaValidationReports) ?? []
        // Schema-6 Bundles written before ready-publication support remain
        // readable and are not silently upgraded with synthetic records.
        let readyEvidenceInsightPublications = try values.decodeIfPresent(
            [V10BundleReadyEvidenceInsightPublication].self, forKey: .readyEvidenceInsightPublications
        ) ?? []
        self.init(categoryProfile: categoryProfile, categoryMemberships: categoryMemberships,
                  formulaInventories: formulaInventories, formulaJobs: formulaJobs,
                  formulaAnalysisRuns: formulaAnalysisRuns, analysisAttempts: analysisAttempts,
                  formulaValidationReports: formulaValidationReports,
                  readyEvidenceInsightPublications: readyEvidenceInsightPublications)
    }

    var recordCounts: [String: Int] {
        var counts = ["categoryProfiles": categoryProfile == nil ? 0 : 1,
                      "categoryMemberships": categoryMemberships.count,
                      "formulaInventories": formulaInventories.count,
                      "formulaInventoryItems": formulaInventories.reduce(0) { $0 + $1.items.count },
                      "formulaJobs": formulaJobs.count,
                      "formulaBatches": formulaJobs.reduce(0) { $0 + $1.checkpoint.job.batches.count },
                      "formulaClaims": formulaJobs.reduce(0) { count, job in
             count + job.checkpoint.completedClaimsByBatch.values.reduce(0) { $0 + $1.count }
         }]
        if !formulaAnalysisRuns.isEmpty { counts["formulaAnalysisRuns"] = formulaAnalysisRuns.count }
        if !analysisAttempts.isEmpty { counts["analysisAttempts"] = analysisAttempts.count }
        if !formulaValidationReports.isEmpty { counts["formulaValidationReports"] = formulaValidationReports.count }
        if !readyEvidenceInsightPublications.isEmpty {
            counts["readyEvidenceInsightPublications"] = readyEvidenceInsightPublications.count
        }
        let segmentStates = formulaJobs.flatMap { $0.checkpoint.derivationSegmentsByEquation?.values ?? [:].values }
        let segmentCount = segmentStates.reduce(0) { $0 + $1.segments.count }
        let segmentStepCount = segmentStates.reduce(0) { $0 + $1.completedSteps.count }
        if segmentCount > 0 { counts["formulaDerivationSegments"] = segmentCount }
        if segmentStepCount > 0 { counts["formulaDerivationSegmentSteps"] = segmentStepCount }
        return counts
    }

    static func capture(from context: ModelContext, snapshot: LibrarySnapshot) throws -> Self {
        let profiles = try context.fetch(FetchDescriptor<StoredV10CategoryProfile>())
        guard profiles.count <= 1 else { throw V4ResearchBundleError.malformedTypedState("多個 active category profiles") }
        let profile: V10BundleCategoryProfile?
        if let row = profiles.first {
            guard let rawValues = try? JSONDecoder.latticeLens.decode([String].self, from: row.categoriesData),
                  rawValues.count == Set(rawValues).count,
                  rawValues.allSatisfy({ SupportedArxivCategory(rawValue: $0) != nil }),
                  row.revision > 0 else {
                throw V4ResearchBundleError.malformedTypedState("active category profile 無法驗證")
            }
            let canonical = SupportedArxivCategory.canonical(Set(rawValues.compactMap(SupportedArxivCategory.init(rawValue:)))).map(\.rawValue)
            guard rawValues == canonical else { throw V4ResearchBundleError.malformedTypedState("category profile 非 canonical order") }
            profile = V10BundleCategoryProfile(id: row.id, revision: row.revision, categories: rawValues, updatedAt: row.updatedAt)
        } else { profile = nil }

        let selectedAuthorIDs = Set(snapshot.authors.keys)
        let memberships = try context.fetch(FetchDescriptor<StoredV10AuthorCategoryMembership>())
            .filter { selectedAuthorIDs.contains($0.authorID) }
            .map(V10BundleCategoryMembership.init)
            .sorted { $0.id < $1.id }
        guard memberships.allSatisfy({ SupportedArxivCategory(rawValue: $0.category) != nil }) else {
            throw V4ResearchBundleError.malformedTypedState("author category membership 含不支持的分类")
        }

        let selectedPaperIDs = Set(snapshot.papers.keys)
        let rawInventoryRows = try context.fetch(FetchDescriptor<StoredV10FormulaInventory>())
        let rawItemRows = try context.fetch(FetchDescriptor<StoredV10FormulaInventoryItem>())
        let inventories = try rawInventoryRows.filter { selectedPaperIDs.contains($0.paperID) }
            .map { try V10BundleFormulaInventory($0, itemRows: rawItemRows) }
            .sorted { $0.id < $1.id }
        let inventoryKeys = Set(inventories.map { "\($0.paperID)|\($0.inventoryHash)" })
        let orphanItems = rawItemRows.filter { selectedPaperIDs.contains($0.paperID) && !inventoryKeys.contains("\($0.paperID)|\($0.inventoryHash)") }
        guard orphanItems.isEmpty else { throw V4ResearchBundleError.malformedTypedState("發現沒有 inventory parent 的 formula item") }

        let jobs = try context.fetch(FetchDescriptor<StoredV10FormulaDerivationJob>())
            .filter { selectedPaperIDs.contains($0.paperID) }
            .map { try V10BundleFormulaJob($0, context: context) }
            .sorted { $0.checkpoint.job.jobID < $1.checkpoint.job.jobID }
        let publications = try context.fetch(FetchDescriptor<StoredV10AnalysisRun>())
            .filter { $0.workflowKind == "evidence_insight" && $0.phase == "ready_to_publish" }
            .map(V10BundleReadyEvidenceInsightPublication.init)
            .filter { selectedPaperIDs.contains($0.publication.context.paperID) }
            .sorted { $0.id < $1.id }
        let formulaRunIDs = Set(jobs.map { "formula:\($0.checkpoint.job.jobID)" })
        let formulaAnalysisRuns = try context.fetch(FetchDescriptor<StoredV10AnalysisRun>())
            .filter { formulaRunIDs.contains($0.id) }
            .map { row in
                guard let job = jobs.first(where: { "formula:\($0.checkpoint.job.jobID)" == row.id }) else {
                    throw V4ResearchBundleError.malformedTypedState("formula AnalysisRun 沒有選取範圍內的 job")
                }
                return try V10BundleFormulaAnalysisRun(row, checkpoint: job.checkpoint)
            }
            .sorted { $0.id < $1.id }
        let selectedRunIDs = formulaRunIDs.union(publications.map(\.id))
        let analysisAttempts = try context.fetch(FetchDescriptor<StoredV10AnalysisAttempt>())
            .filter { selectedRunIDs.contains($0.runID) }
            .map(V10BundleAnalysisAttempt.init)
            .sorted { $0.id < $1.id }
        let selectedJobIDs = Set(jobs.map { $0.checkpoint.job.jobID })
        let validationReports = try context.fetch(FetchDescriptor<StoredV10FormulaValidationReport>())
            .filter { selectedJobIDs.contains($0.jobID) }
            .map(V10BundleFormulaValidationReport.init)
            .sorted { $0.id < $1.id }
        let state = Self(categoryProfile: profile, categoryMemberships: memberships,
                         formulaInventories: inventories, formulaJobs: jobs,
                         formulaAnalysisRuns: formulaAnalysisRuns,
                         analysisAttempts: analysisAttempts,
                         formulaValidationReports: validationReports,
                         readyEvidenceInsightPublications: publications)
        try state.validate()
        try state.validateCompleteJobs(against: snapshot)
        return state
    }

    func validate() throws {
        if let categoryProfile {
            guard categoryProfile.id == "active", categoryProfile.revision > 0,
                  categoryProfile.categories.count == Set(categoryProfile.categories).count,
                  categoryProfile.categories == SupportedArxivCategory.canonical(
                    Set(categoryProfile.categories.compactMap(SupportedArxivCategory.init(rawValue:)))).map(\.rawValue),
                  categoryProfile.categories.allSatisfy({ SupportedArxivCategory(rawValue: $0) != nil }) else {
                throw V4ResearchBundleError.malformedTypedState("category profile contract 無效")
            }
        }
        guard Set(categoryMemberships.map(\.id)).count == categoryMemberships.count,
              Set(formulaInventories.map(\.id)).count == formulaInventories.count,
              Set(formulaJobs.map { $0.checkpoint.job.jobID }).count == formulaJobs.count,
              Set(formulaAnalysisRuns.map(\.id)).count == formulaAnalysisRuns.count,
              Set(analysisAttempts.map(\.id)).count == analysisAttempts.count,
              Set(formulaValidationReports.map(\.id)).count == formulaValidationReports.count,
              Set(readyEvidenceInsightPublications.map(\.id)).count == readyEvidenceInsightPublications.count,
              Set(readyEvidenceInsightPublications.map { $0.publication.context.cacheKey }).count == readyEvidenceInsightPublications.count else {
            throw V4ResearchBundleError.malformedTypedState("typed state 含重複 identity")
        }
        for membership in categoryMemberships where SupportedArxivCategory(rawValue: membership.category) == nil {
            throw V4ResearchBundleError.malformedTypedState("unsupported category membership")
        }
        for inventoryRecord in formulaInventories {
            guard inventoryRecord.inventory.documentHash == inventoryRecord.documentHash,
                  inventoryRecord.inventory.inventoryHash == inventoryRecord.inventoryHash,
                  inventoryRecord.items.count == inventoryRecord.inventory.items.count,
                  zip(inventoryRecord.items, inventoryRecord.inventory.items).allSatisfy({ $0.matches($1) }) else {
                throw V4ResearchBundleError.malformedTypedState("formula inventory/item identities 不一致")
            }
        }
        for job in formulaJobs {
            let checkpoint = job.checkpoint
            let validBatchIndices = Set(checkpoint.job.batches.map(\.batchIndex))
            let segmentStates = checkpoint.derivationSegmentsByEquation ?? [:]
            guard checkpoint.job.jobID == checkpoint.id,
                  Set(checkpoint.job.equationIDs).count == checkpoint.job.equationIDs.count,
                  Set(checkpoint.completedClaimsByBatch.keys).isSubset(of: validBatchIndices),
                  Set(segmentStates.keys).isSubset(of: Set(checkpoint.job.equationIDs)),
                  checkpoint.job.batches.allSatisfy({ batch in
                      batch.jobID == checkpoint.job.jobID && batch.batchTotal == checkpoint.job.batches.count &&
                          (batch.status == .completed) == (checkpoint.completedClaimsByBatch[batch.batchIndex] != nil)
                  }) else {
                throw V4ResearchBundleError.malformedTypedState("formula job checkpoint 不一致")
            }
            for (equationID, segmentState) in segmentStates {
                guard segmentState.equationID == equationID, !segmentState.segments.isEmpty else {
                    throw V4ResearchBundleError.malformedTypedState("V12 formula segment identity/state 無效")
                }
                do {
                    guard try segmentState.validatedCopy() == segmentState else {
                        throw V4ResearchBundleError.malformedTypedState("V12 formula segment chain changed during validation")
                    }
                    if segmentState.isComplete {
                        let claims = checkpoint.completedClaimsByBatch.values.flatMap { $0 }
                            .filter { $0.equationID == equationID }
                        let claim = claims.first
                        let stepsMatch = claim?.formulaDerivationSteps == segmentState.completedSteps
                        let conclusionMatches = claim?.conclusionZH == segmentState.conclusionZH
                        let provenanceMatches = claim?.derivationSegmentProvenanceHash == (try segmentState.provenanceHash())
                        guard claims.count == 1, stepsMatch, conclusionMatches, provenanceMatches else {
                            throw V4ResearchBundleError.malformedTypedState(
                                "completed V12 segment differs from its formula claim (claims=\(claims.count), steps=\(stepsMatch), conclusion=\(conclusionMatches), provenance=\(provenanceMatches))")
                        }
                    }
                } catch let error as V4ResearchBundleError {
                    throw error
                } catch {
                    throw V4ResearchBundleError.malformedTypedState("V12 formula segment receipt/step integrity invalid")
                }
            }
        }
        let knownRunIDs = Set(formulaAnalysisRuns.map(\.id)).union(readyEvidenceInsightPublications.map(\.id))
        guard analysisAttempts.allSatisfy({ knownRunIDs.contains($0.runID) }) else {
            throw V4ResearchBundleError.malformedTypedState("analysis attempt references a missing or excluded run")
        }
        let knownJobIDs = Set(formulaJobs.map { $0.checkpoint.job.jobID })
        guard formulaValidationReports.allSatisfy({ knownJobIDs.contains($0.jobID) }) else {
            throw V4ResearchBundleError.malformedTypedState("formula validation report references a missing job")
        }
        for attempt in analysisAttempts {
            do { try attempt.validate() }
            catch { throw V4ResearchBundleError.malformedTypedState("analysis attempt identifier/telemetry invalid") }
        }
        for publication in readyEvidenceInsightPublications {
            do { try publication.validate() }
            catch { throw V4ResearchBundleError.malformedTypedState("ready evidence publication hash/identity invalid") }
        }
        for report in formulaValidationReports {
            do { try report.validate() }
            catch { throw V4ResearchBundleError.malformedTypedState("formula validation report identity/hash invalid") }
        }
    }

    func validateCompleteJobs(against snapshot: LibrarySnapshot) throws {
        var inventoriesByKey = [String: FormulaInventory]()
        for record in formulaInventories {
            let key = "\(record.paperID)|\(record.inventoryHash)"
            guard inventoriesByKey.updateValue(record.inventory, forKey: key) == nil else {
                throw V4ResearchBundleError.malformedTypedState("formula inventory composite identity 重複")
            }
        }
        for record in formulaJobs {
            guard let segmentStates = record.checkpoint.derivationSegmentsByEquation,
                  !segmentStates.isEmpty else { continue }
            guard let inventory = inventoriesByKey["\(record.checkpoint.job.paperID)|\(record.checkpoint.job.inventoryHash)"] else {
                throw V4ResearchBundleError.malformedTypedState("V12 formula segments lack their matching inventory")
            }
            for (equationID, segmentState) in segmentStates {
                guard let item = inventory.items.first(where: { $0.equationID == equationID }),
                      item.sourceTeX == segmentState.sourceTeX else {
                    throw V4ResearchBundleError.malformedTypedState("V12 formula segment source TeX differs from inventory")
                }
            }
        }
        let anchors = snapshot.evidenceAnchors
        for record in formulaJobs where record.checkpoint.job.state == .complete {
            let checkpoint = record.checkpoint
            guard let inventory = inventoriesByKey["\(checkpoint.job.paperID)|\(checkpoint.job.inventoryHash)"] else {
                throw V4ResearchBundleError.malformedTypedState("complete formula job 缺少匹配 inventory")
            }
            let claims = checkpoint.job.batches.sorted { $0.batchIndex < $1.batchIndex }
                .flatMap { checkpoint.completedClaimsByBatch[$0.batchIndex] ?? [] }
            do { _ = try FormulaCoverageValidator.validate(inventory: inventory, claims: claims, anchors: anchors) }
            catch { throw V4ResearchBundleError.malformedTypedState("complete formula job coverage/anchor 驗證失敗") }
        }
        let jobsByID = Dictionary(uniqueKeysWithValues: formulaJobs.map { ($0.checkpoint.job.jobID, $0.checkpoint) })
        for run in formulaAnalysisRuns {
            guard let checkpoint = jobsByID[String(run.id.dropFirst("formula:".count))] else {
                throw V4ResearchBundleError.malformedTypedState("formula AnalysisRun references a missing job")
            }
            do { try run.validate(against: checkpoint) }
            catch { throw V4ResearchBundleError.malformedTypedState("formula AnalysisRun projection/job mismatch") }
        }
        for attempt in analysisAttempts where attempt.runID.hasPrefix("formula:") {
            let jobID = String(attempt.runID.dropFirst("formula:".count))
            guard let checkpoint = jobsByID[jobID], let batchIndex = attempt.batchIndex,
                  let batch = checkpoint.job.batches.first(where: { $0.batchIndex == batchIndex }),
                  attempt.requestIndex == batchIndex, attempt.attempt <= batch.attemptCount,
                  attempt.id == "\(attempt.runID):batch:\(batchIndex):attempt:\(attempt.attempt)" else {
                throw V4ResearchBundleError.malformedTypedState("formula AnalysisAttempt does not match its job/batch identity")
            }
            if attempt.attempt == batch.attemptCount {
                guard attempt.requestID == batch.requestID, attempt.status == batch.status.rawValue,
                      attempt.receivedBytes == batch.receivedBytes,
                      attempt.receivedCharacters == batch.receivedCharacters,
                      attempt.errorCategory == batch.errorCategory, attempt.updatedAt == batch.updatedAt else {
                    throw V4ResearchBundleError.malformedTypedState("latest AnalysisAttempt differs from its batch checkpoint")
                }
            }
        }
        for record in formulaValidationReports {
            guard let checkpoint = jobsByID[record.jobID] else {
                throw V4ResearchBundleError.malformedTypedState("formula validation report references a missing job")
            }
            if record.status != "stale" {
                guard record.validatorVersion == FormulaCoverageValidator.version,
                      record.inventoryHash == checkpoint.job.inventoryHash,
                      let inventory = inventoriesByKey["\(checkpoint.job.paperID)|\(record.inventoryHash)"] else {
                    throw V4ResearchBundleError.malformedTypedState("current formula validation report lacks its matching inventory/version")
                }
                let claims = checkpoint.job.batches.sorted { $0.batchIndex < $1.batchIndex }
                    .flatMap { checkpoint.completedClaimsByBatch[$0.batchIndex] ?? [] }
                let expected = FormulaCoverageValidator.report(inventory: inventory, claims: claims, anchors: anchors)
                let expectedStatus = checkpoint.job.state == .complete ? "complete" : "incomplete"
                guard record.report == expected, record.status == expectedStatus else {
                    throw V4ResearchBundleError.malformedTypedState("formula validation report differs from its persisted job evidence")
                }
            }
        }
        for record in readyEvidenceInsightPublications {
            let publication = record.publication
            let context = publication.context
            let artifact = publication.artifact
            guard artifact.numberedEquationIDs == artifact.insight.physics.importantFormulaDerivations.compactMap(\.equationID) else {
                throw V4ResearchBundleError.malformedTypedState("ready evidence publication formula IDs are incomplete")
            }
            guard !artifact.numberedEquationIDs.isEmpty else { continue }
            guard let inventory = inventoriesByKey["\(context.paperID)|\(context.inventoryHash)"],
                  inventory.items.map(\.equationID) == artifact.numberedEquationIDs else {
                throw V4ResearchBundleError.malformedTypedState("ready evidence publication lacks its matching complete inventory")
            }
            do {
                _ = try FormulaCoverageValidator.validate(
                    inventory: inventory,
                    claims: artifact.insight.physics.importantFormulaDerivations,
                    anchors: snapshot.evidenceAnchors
                )
            } catch {
                throw V4ResearchBundleError.malformedTypedState("ready evidence publication formula coverage/anchor validation failed")
            }
        }
    }

    @MainActor
    func materialize(into context: ModelContext) throws {
        if let categoryProfile {
            let categoriesData = try JSONEncoder.latticeLens.encode(categoryProfile.categories)
            context.insert(StoredV10CategoryProfile(id: categoryProfile.id, revision: categoryProfile.revision,
                categoriesData: categoriesData, updatedAt: categoryProfile.updatedAt))
        }
        categoryMemberships.forEach { $0.insert(into: context) }
        for inventory in formulaInventories { try inventory.insert(into: context) }
        for job in formulaJobs { try job.insert(into: context) }
        for run in formulaAnalysisRuns { try run.insert(into: context) }
        for report in formulaValidationReports { try report.insert(into: context) }
        for publication in readyEvidenceInsightPublications { try publication.insert(into: context) }
        for attempt in analysisAttempts { attempt.insert(into: context) }
        try context.save()
    }
}

private enum V10BundleFieldSanitizer {
    private static let tokenCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")
    private static let errorCategories: Set<String> = [
        "cancelled", "timeout_configuration_error", "connect_timeout", "first_content_timeout",
        "idle_timeout", "resource_limit", "provider_or_validation_error"
    ]

    static func isOpaqueToken(_ value: String, maximumLength: Int = 512) -> Bool {
        !value.isEmpty && value.count <= maximumLength && value.rangeOfCharacter(from: tokenCharacters.inverted) == nil
    }

    static func isSafeRequestID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    static func isSafeErrorCategory(_ value: String?) -> Bool {
        value.map(errorCategories.contains) ?? true
    }
}

private struct V10BundleFormulaAnalysisRun: Codable, Hashable, Sendable {
    let id: String
    let workflowKind: String
    var phase: String
    let providerRevision: String
    let modelID: String
    let promptVersion: String
    let schemaVersion: String
    let payloadHash: String
    let sourceDocumentHashes: [String]
    let inventoryHash: String?
    let updatedAt: Date

    init(_ row: StoredV10AnalysisRun, checkpoint: FormulaDerivationCheckpoint) throws {
        guard row.payload.isEmpty,
              let sourceHashes = try? JSONDecoder.latticeLens.decode([String].self, from: row.sourceDocumentHashesData) else {
            throw V4ResearchBundleError.malformedTypedState("formula AnalysisRun payload is not an empty safe projection")
        }
        id = row.id; workflowKind = row.workflowKind; phase = row.phase
        providerRevision = row.providerRevision; modelID = row.modelID
        promptVersion = row.promptVersion; schemaVersion = row.schemaVersion
        payloadHash = row.payloadHash; sourceDocumentHashes = sourceHashes
        inventoryHash = row.inventoryHash; updatedAt = row.updatedAt
        try validate(against: checkpoint)
    }

    func validate(against checkpoint: FormulaDerivationCheckpoint) throws {
        let job = checkpoint.job
        let expectedID = "formula:\(job.jobID)"
        let expectedPayloadHash = StableHash.sha256([job.jobID, job.documentHash, job.inventoryHash].joined(separator: "|"))
        guard id == expectedID, workflowKind == "formula_derivation", phase == job.state.rawValue,
              providerRevision == "not-recorded", modelID == "not-recorded",
              promptVersion == checkpoint.promptVersion, schemaVersion == checkpoint.schemaVersion,
              payloadHash == expectedPayloadHash, sourceDocumentHashes == [job.documentHash],
              inventoryHash == job.inventoryHash, updatedAt == checkpoint.updatedAt,
              V10BundleFieldSanitizer.isOpaqueToken(job.jobID),
              V10BundleFieldSanitizer.isOpaqueToken(job.documentHash),
              V10BundleFieldSanitizer.isOpaqueToken(job.inventoryHash),
              V10BundleFieldSanitizer.isOpaqueToken(promptVersion),
              V10BundleFieldSanitizer.isOpaqueToken(schemaVersion) else {
            throw V4ResearchBundleError.malformedTypedState("formula AnalysisRun metadata/hash/source identity mismatch")
        }
    }

    func markingIncomplete() -> Self {
        var copy = self
        copy.phase = FormulaJobState.incomplete.rawValue
        return copy
    }

    @MainActor
    func insert(into context: ModelContext) throws {
        let sourceDocumentHashesData = try JSONEncoder.latticeLens.encode(sourceDocumentHashes)
        context.insert(StoredV10AnalysisRun(id: id, workflowKind: workflowKind, phase: phase,
            providerRevision: providerRevision, modelID: modelID, promptVersion: promptVersion,
            schemaVersion: schemaVersion, payloadHash: payloadHash,
            sourceDocumentHashesData: sourceDocumentHashesData,
            inventoryHash: inventoryHash, updatedAt: updatedAt, payload: Data()))
    }
}

private struct V10BundleAnalysisAttempt: Codable, Hashable, Sendable {
    let id: String
    let runID: String
    let requestIndex: Int
    let batchIndex: Int?
    let requestID: String
    let attempt: Int
    let status: String
    let receivedBytes: Int
    let receivedCharacters: Int
    let errorCategory: String?
    let updatedAt: Date

    init(_ row: StoredV10AnalysisAttempt) {
        id = row.id; runID = row.runID; requestIndex = row.requestIndex
        batchIndex = row.batchIndex; requestID = row.requestID; attempt = row.attempt
        status = row.status; receivedBytes = row.receivedBytes
        receivedCharacters = row.receivedCharacters; errorCategory = row.errorCategory
        updatedAt = row.updatedAt
    }

    func validate() throws {
        guard V10BundleFieldSanitizer.isOpaqueToken(id),
              V10BundleFieldSanitizer.isOpaqueToken(runID),
              V10BundleFieldSanitizer.isSafeRequestID(requestID),
              requestIndex >= 0, batchIndex.map({ $0 >= 0 }) ?? true, attempt > 0,
              FormulaBatchStatus(rawValue: status) != nil,
              receivedBytes >= 0, receivedCharacters >= 0,
              V10BundleFieldSanitizer.isSafeErrorCategory(errorCategory) else {
            throw V4ResearchBundleError.malformedTypedState("analysis attempt contains unsafe or invalid telemetry")
        }
    }

    @MainActor
    func insert(into context: ModelContext) {
        context.insert(StoredV10AnalysisAttempt(id: id, runID: runID, requestIndex: requestIndex,
            batchIndex: batchIndex, requestID: requestID, attempt: attempt, status: status,
            receivedBytes: receivedBytes, receivedCharacters: receivedCharacters,
            errorCategory: errorCategory, updatedAt: updatedAt))
    }
}

private struct V10BundleFormulaValidationReport: Codable, Hashable, Sendable {
    let id: String
    let jobID: String
    let inventoryHash: String
    let claimHash: String
    let validatorVersion: String
    var status: String
    let report: FormulaCoverageReport
    let payloadHash: String
    let createdAt: Date

    init(_ row: StoredV10FormulaValidationReport) throws {
        guard let report = try? JSONDecoder.latticeLens.decode(FormulaCoverageReport.self, from: row.payload) else {
            throw V4ResearchBundleError.malformedTypedState("formula validation report payload cannot be decoded")
        }
        id = row.id; jobID = row.jobID; inventoryHash = row.inventoryHash
        claimHash = row.claimHash; validatorVersion = row.validatorVersion
        status = row.validatorVersion == FormulaCoverageValidator.legacyVersion ? "stale" : row.status
        self.report = report
        payloadHash = StableHash.sha256(row.payload); createdAt = row.createdAt
        try validate()
    }

    func markingStale() -> Self {
        var copy = self
        copy.status = "stale"
        return copy
    }

    func validate() throws {
        let encoded = try JSONEncoder.latticeLens.encode(report)
        guard id == "\(jobID):\(validatorVersion)",
              V10BundleFieldSanitizer.isOpaqueToken(jobID),
              V10BundleFieldSanitizer.isOpaqueToken(inventoryHash),
              V10BundleFieldSanitizer.isOpaqueToken(claimHash),
              V10BundleFieldSanitizer.isOpaqueToken(validatorVersion),
              report.inventoryHash == inventoryHash, report.claimHash == claimHash,
              StableHash.sha256(encoded) == payloadHash else {
            throw V4ResearchBundleError.malformedTypedState("formula validation report row/payload hash mismatch")
        }
        switch status {
        case "complete": guard report.isComplete else { throw V4ResearchBundleError.malformedTypedState("complete report is incomplete") }
        case "incomplete": guard !report.isComplete else { throw V4ResearchBundleError.malformedTypedState("incomplete report claims complete coverage") }
        case "stale": break
        default: throw V4ResearchBundleError.malformedTypedState("unknown formula validation report status")
        }
    }

    @MainActor
    func insert(into context: ModelContext) throws {
        let payload = try JSONEncoder.latticeLens.encode(report)
        guard StableHash.sha256(payload) == payloadHash else {
            throw V4ResearchBundleError.malformedTypedState("formula validation report changed during restore")
        }
        context.insert(StoredV10FormulaValidationReport(id: id, jobID: jobID,
            inventoryHash: inventoryHash, claimHash: claimHash,
            validatorVersion: validatorVersion, status: status,
            payload: payload, createdAt: createdAt))
    }
}

private struct V10BundleReadyEvidenceInsightPublication: Codable, Hashable, Sendable {
    let id: String
    let payloadHash: String
    let publication: ReadyEvidenceInsightPublication

    init(_ row: StoredV10AnalysisRun) throws {
        guard row.workflowKind == "evidence_insight", row.phase == "ready_to_publish",
              row.payloadHash == StableHash.sha256(row.payload) else {
            throw V4ResearchBundleError.malformedTypedState("ready evidence publication AnalysisRun metadata/hash invalid")
        }
        let publication = try JSONDecoder.latticeLens.decode(ReadyEvidenceInsightPublication.self, from: row.payload)
        self.id = row.id
        self.payloadHash = row.payloadHash
        self.publication = publication
        try validate(row: row)
    }

    func validate() throws {
        guard publication.hasConsistentIdentity,
              id == publication.context.analysisRunID,
              payloadHash == StableHash.sha256(try JSONEncoder.latticeLens.encode(publication)) else {
            throw V4ResearchBundleError.malformedTypedState("ready evidence publication payload digest mismatch")
        }
    }

    private func validate(row: StoredV10AnalysisRun) throws {
        try validate()
        let context = publication.context
        guard row.id == id, row.providerRevision == context.providerProfileFingerprint,
              row.modelID == context.modelID, row.promptVersion == context.promptVersion,
              row.schemaVersion == context.schemaVersion, row.inventoryHash == context.inventoryHash,
              let sourceHashes = try? JSONDecoder.latticeLens.decode([String].self, from: row.sourceDocumentHashesData),
              sourceHashes == [context.documentHash] else {
            throw V4ResearchBundleError.malformedTypedState("ready evidence publication AnalysisRun projection mismatch")
        }
    }

    @MainActor
    func insert(into context: ModelContext) throws {
        try validate()
        let value = publication
        context.insert(StoredV10AnalysisRun(
            id: id, workflowKind: "evidence_insight", phase: "ready_to_publish",
            providerRevision: value.context.providerProfileFingerprint, modelID: value.context.modelID,
            promptVersion: value.context.promptVersion, schemaVersion: value.context.schemaVersion,
            payloadHash: payloadHash,
            sourceDocumentHashesData: try JSONEncoder.latticeLens.encode([value.context.documentHash]),
            inventoryHash: value.context.inventoryHash, updatedAt: value.artifact.createdAt,
            payload: try JSONEncoder.latticeLens.encode(value)
        ))
    }
}
