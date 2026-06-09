// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GPXVideo",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GPXVideo", targets: ["GPXVideo"])
    ],
    dependencies: [
        .package(path: "../GPXCore"),
        .package(path: "../GPXMapKit")
    ],
    targets: [
        // Mode Swift 5 : code AVFoundation/AppKit hérité de la cible app, non audité Swift 6.
        .target(name: "GPXVideo", dependencies: ["GPXCore", "GPXMapKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "GPXVideoTests", dependencies: ["GPXVideo"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
