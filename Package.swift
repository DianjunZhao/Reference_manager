// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LatticeLens",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LatticeLens", targets: ["LatticeLens"])
    ],
    targets: [
        .executableTarget(
            name: "LatticeLens",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "LatticeLensTests",
            dependencies: ["LatticeLens"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "LatticeLensUITests",
            dependencies: ["LatticeLens"],
            // XCUIApplication requires an Xcode UI-test host.  The real test
            // remains in this directory for LatticeLens.xcodeproj, while the
            // package target retains only host-free accessibility contracts.
            exclude: ["LatticeLensUITests.swift"]
        )
    ]
)
