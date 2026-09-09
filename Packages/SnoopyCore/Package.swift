// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SnoopyCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SnoopyCore", targets: ["SnoopyCore"]),
        .library(name: "SnoopyIPC", targets: ["SnoopyIPC"]),
    ],
    targets: [
        .target(name: "SnoopyCore"),
        .target(name: "SnoopyIPC", dependencies: ["SnoopyCore"]),
        .testTarget(name: "SnoopyCoreTests", dependencies: ["SnoopyCore", "SnoopyIPC"]),
    ]
)
