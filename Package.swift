// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ios-simulator-mcp",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),
    ],
    targets: [
        .target(
            name: "SimulatorKit",
            dependencies: [],
            path: "Sources/SimulatorKit"
        ),
        .executableTarget(
            name: "ios-simulator-mcp",
            dependencies: [
                "SimulatorKit",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/SimulatorMCP"
        ),
        .testTarget(
            name: "SimulatorKitTests",
            dependencies: ["SimulatorKit"],
            path: "Tests/SimulatorKitTests"
        ),
    ]
)
