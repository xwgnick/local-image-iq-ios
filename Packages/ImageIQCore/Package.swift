// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImageIQCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ImageIQCore", targets: ["ImageIQCore"])],
    dependencies: [],
    targets: [
        .target(name: "ImageIQCore"),
        .testTarget(name: "ImageIQCoreTests", dependencies: ["ImageIQCore"])
    ]
)