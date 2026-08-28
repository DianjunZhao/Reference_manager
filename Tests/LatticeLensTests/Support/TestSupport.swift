import Foundation
import XCTest
@testable import LatticeLens

func fixtureData(_ name: String) throws -> Data {
    #if SWIFT_PACKAGE
    let bundle = Bundle.module
    #else
    let bundle = Bundle(for: FixtureBundleToken.self)
    #endif
    let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"))
    return try Data(contentsOf: url)
}

private final class FixtureBundleToken {}

/// File-backed tests must never fall back to the XCTest runner's current
/// directory: Xcode currently starts that runner at `/` on this host.  Prefer
/// the verifier-provided task scratch when it is demonstrably inside this
/// checkout; otherwise derive the checkout from this compiled test source and
/// create a uniquely named, project-local directory.  Both paths keep fixtures
/// away from Application Support, a real library, and the system temp area.
enum ProjectLocalTestScratchError: LocalizedError {
    case sourceRootUnavailable(String)
    case untrustedEnvironmentRoot(String)

    var errorDescription: String? {
        switch self {
        case .sourceRootUnavailable(let path):
            "无法从测试源码路径确定项目根目录：\(path)"
        case .untrustedEnvironmentRoot(let path):
            "LATTICELENS_TEST_STORE_ROOT 必须位于当前项目目录内：\(path)"
        }
    }
}

func makeProjectLocalTestDirectory(prefix: String) throws -> URL {
    let fileManager = FileManager.default
    let sourceURL = URL(fileURLWithPath: #filePath).standardizedFileURL.resolvingSymlinksInPath()
    var cursor = sourceURL.deletingLastPathComponent()
    while cursor.lastPathComponent != "Tests" {
        let parent = cursor.deletingLastPathComponent()
        guard parent.path != cursor.path else {
            throw ProjectLocalTestScratchError.sourceRootUnavailable(sourceURL.path)
        }
        cursor = parent
    }
    let projectRoot = cursor.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()

    let base: URL
    if let rawRoot = ProcessInfo.processInfo.environment["LATTICELENS_TEST_STORE_ROOT"], !rawRoot.isEmpty {
        guard rawRoot.hasPrefix("/") else {
            throw ProjectLocalTestScratchError.untrustedEnvironmentRoot(rawRoot)
        }
        let supplied = URL(fileURLWithPath: rawRoot, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard supplied.path == projectRoot.path || supplied.path.hasPrefix(projectRoot.path + "/") else {
            throw ProjectLocalTestScratchError.untrustedEnvironmentRoot(supplied.path)
        }
        base = supplied
    } else {
        base = projectRoot
    }

    let directory = base.appendingPathComponent(".codex-task-tmp-\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

actor SequentialTransport: HTTPTransport {
    private var values: [Data]

    init(_ values: [Data]) { self.values = values }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !values.isEmpty else { throw LatticeLensError.invalidResponse }
        let data = values.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}
