// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GPXMapKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GPXMapKit", targets: ["GPXMapKit"])
    ],
    targets: [
        .target(name: "GPXMapKit"),
        .testTarget(name: "GPXMapKitTests", dependencies: ["GPXMapKit"])
    ]
)
