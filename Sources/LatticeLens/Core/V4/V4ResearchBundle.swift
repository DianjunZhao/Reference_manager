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

enum V4ResearchBundleError: LocalizedError, Equatable, Sendable {
    case invalidRoot
    case missingManifest
    case hashMismatch(String)
    case unsupportedSchema(Int)
    case duplicatePaperID(Int)
    case activeTargetExists
    case malformedLibrary

    var errorDescription: String? {
        switch self {
        case .invalidRoot: "bundle 路径必须是目录 package"
        case .missingManifest: "bundle 缺少 manifest.json"
        case .hashMismatch(let path): "bundle 文件 hash 不匹配：\(path)"
        case .unsupportedSchema(let version): "bundle schema 不受支持：\(version)"
        case .duplicatePaperID(let id): "bundle 包含重复 paper id：\(id)"
        case .activeTargetExists: "恢复目标已存在；不会覆盖 active library"
        case .malformedLibrary: "bundle library.json 无法解码"
        }
    }
}

enum V4ResearchBundle {
    static let schemaVersion = 5

    static func export(snapshot: LibrarySnapshot, to destination: URL, includePDFBytes: Bool = false,
                       pdfRoot: URL? = nil, appVersion: String = "LatticeLens-v4") throws -> V4BundleManifest {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { throw V4ResearchBundleError.activeTargetExists }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
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
        if includePDFBytes, let pdfRoot {
            let pdfDirectory = destination.appendingPathComponent("pdf", isDirectory: true)
            try manager.createDirectory(at: pdfDirectory, withIntermediateDirectories: true)
            let filenames = Set(snapshot.contentBlobs.values.compactMap(\.localFilename))
            for filename in filenames {
                let source = try V4OwnedPath.canonicalFile(named: filename, root: pdfRoot)
                guard manager.fileExists(atPath: source.path) else { continue }
                let data = try Data(contentsOf: source)
                let relative = "pdf/\(source.lastPathComponent)"
                try data.write(to: destination.appendingPathComponent(relative), options: .atomic)
                files[relative] = data
            }
        }
        let counts = ["papers": sanitized.papers.count, "authors": sanitized.authors.count,
                      "notes": sanitized.notes.count, "annotations": sanitized.userEvidenceAnchors.count,
                      "workspaces": sanitized.workspaces.count, "imports": sanitized.importedBibliographies.count]
        let manifest = V4BundleManifest.make(schemaVersion: schemaVersion, files: files, recordCounts: counts,
                                              includesPDFBytes: includePDFBytes, appVersion: appVersion, createdAt: Date())
        let manifestData = try JSONEncoder.latticeLens.encode(manifest)
        try manifestData.write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
        return manifest
    }

    static func verify(_ bundle: URL) throws -> V4BundleManifest {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bundle.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw V4ResearchBundleError.invalidRoot }
        let manifestURL = bundle.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL), let manifest = try? JSONDecoder.latticeLens.decode(V4BundleManifest.self, from: data) else {
            throw V4ResearchBundleError.missingManifest
        }
        guard manifest.schemaVersion <= schemaVersion else { throw V4ResearchBundleError.unsupportedSchema(manifest.schemaVersion) }
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
        let conflicts = incoming.papers.keys.filter { activeSnapshot.papers[$0] != nil }.sorted()
        return V4BundleDryRun(schemaVersion: manifest.schemaVersion, paperCount: incoming.papers.count,
                              noteCount: incoming.notes.count, annotationCount: incoming.userEvidenceAnchors.count,
                              conflictPaperIDs: conflicts, missingFiles: [], tamperedFiles: [])
    }

    /// Restore only into a new, caller-selected target directory.  The active
    /// store is never replaced by this helper; a higher-level coordinator can
    /// atomically switch after its own migration and rollback checks.
    static func restoreToNewStore(_ bundle: URL, target: URL, activeSnapshot: LibrarySnapshot? = nil) throws -> V4BundleDryRun {
        guard !FileManager.default.fileExists(atPath: target.path) else { throw V4ResearchBundleError.activeTargetExists }
        let dryRun = try dryRun(bundle, activeSnapshot: activeSnapshot ?? LibrarySnapshot())
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
}
