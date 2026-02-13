// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ios_simulator_cli",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "IndigoCTypes",
            path: "Sources/IndigoCTypes",
            publicHeadersPath: "include"
        ),
        .target(
            name: "AXPTranslationBridge",
            path: "Sources/AXPTranslationBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SimulatorKit",
            dependencies: ["IndigoCTypes", "AXPTranslationBridge"],
            path: "Sources/SimulatorKit"
        ),
        .executableTarget(
            name: "ios_simulator_cli",
            dependencies: [
                "SimulatorKit",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ios_simulator_cli"
        ),
        .testTarget(
            name: "SimulatorKitTests",
            dependencies: ["SimulatorKit"],
            path: "Tests/SimulatorKitTests"
        ),
    ]
)
