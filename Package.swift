// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DocLens",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DocLensCore", targets: ["DocLensCore"]),
        .executable(name: "doclens", targets: ["doclens"]),
    ],
    targets: [
        .target(
            name: "DocLensCore",
            resources: [.copy("Resources/docling_worker.py")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "doclens",
            dependencies: ["DocLensCore"]
        ),
        .testTarget(
            name: "DocLensCoreTests",
            dependencies: ["DocLensCore"]
        ),
    ]
)
