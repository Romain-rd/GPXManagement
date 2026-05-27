// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GPXCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GPXCore", targets: ["GPXCore"])
    ],
    targets: [
        .target(name: "GPXCore"),
        .testTarget(name: "GPXCoreTests", dependencies: ["GPXCore"])
    ]
)
