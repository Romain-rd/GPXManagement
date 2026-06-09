// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GPXRender",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GPXRender", targets: ["GPXRender"])
    ],
    dependencies: [
        .package(path: "../GPXCore"),
        .package(path: "../GPXMapKit")
    ],
    targets: [
        .target(name: "GPXRender", dependencies: ["GPXCore", "GPXMapKit"]),
        .testTarget(name: "GPXRenderTests", dependencies: ["GPXRender"])
    ]
)
