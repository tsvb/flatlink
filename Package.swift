// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "flatlink",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "flatlink", targets: ["flatlink"]),
        .library(name: "FlatlinkCore", targets: ["FlatlinkCore"]),
    ],
    targets: [
        .target(name: "FlatlinkCore"),
        .executableTarget(name: "flatlink", dependencies: ["FlatlinkCore"]),
        .testTarget(name: "FlatlinkCoreTests", dependencies: ["FlatlinkCore"]),
    ]
)
