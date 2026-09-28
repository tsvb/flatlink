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
        .target(name: "FlatlinkCommand", dependencies: ["FlatlinkCore"]),
        .executableTarget(name: "flatlink", dependencies: ["FlatlinkCommand"]),
        .testTarget(name: "FlatlinkCoreTests", dependencies: ["FlatlinkCore"]),
        .testTarget(name: "FlatlinkCommandTests", dependencies: ["FlatlinkCommand", "FlatlinkCore"]),
    ]
)
