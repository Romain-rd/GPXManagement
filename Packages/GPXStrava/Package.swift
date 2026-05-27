// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GPXStrava",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GPXStrava", targets: ["GPXStrava"])
    ],
    targets: [
        .target(name: "GPXStrava"),
        .testTarget(name: "GPXStravaTests", dependencies: ["GPXStrava"])
    ]
)
