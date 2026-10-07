// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DocLens",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DocLensCore", targets: ["DocLensCore"]),
    ],
    targets: [
        .target(name: "DocLensCore"),
    ]
)
