// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "iosef",
    platforms: [
        .macOS(.v13)
    ],
    traits: [
        // Compiles in the HID reboot-recovery test suite, which creates, reboots,
        // and deletes a throwaway simulator (~2 min) — too slow and stateful for a
        // plain `swift test`. Run it via scripts/test-reboot-recovery.sh.
        .trait(
            name: "RebootTests",
            description: "Enable the simulator reboot-recovery test suite"
        ),
    ],
    dependencies: [
        // 0.x minor bumps of swift-sdk are breaking (e.g. 0.11 changed Tool.Content
        // tuple arities), so constrain to the tested minor. Package.resolved is also
        // committed so fresh clones build the exact pinned revision.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
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
            name: "iosef",
            dependencies: [
                "SimulatorKit",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/iosef"
        ),
        .testTarget(
            name: "SimulatorKitTests",
            dependencies: ["SimulatorKit"],
            path: "Tests/SimulatorKitTests"
        ),
    ]
)
