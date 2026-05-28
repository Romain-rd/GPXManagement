// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GPXMapKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GPXMapKit", targets: ["GPXMapKit"])
    ],
    dependencies: [
        .package(path: "../GPXCore")
    ],
    targets: [
        .target(name: "GPXMapKit", dependencies: ["GPXCore"]),
        .testTarget(name: "GPXMapKitTests", dependencies: ["GPXMapKit"])
    ]
)
