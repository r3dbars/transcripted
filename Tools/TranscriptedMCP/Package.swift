// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TranscriptedMCP",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.0"),
        .package(path: "../TranscriptedCaptureParsing"),
    ],
    targets: [
        .executableTarget(
            name: "transcripted-mcp",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "TranscriptedCaptureParsing", package: "TranscriptedCaptureParsing"),
            ],
            path: "Sources/TranscriptedMCP",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "TranscriptedMCPTests",
            dependencies: ["transcripted-mcp"],
            path: "Tests/TranscriptedMCPTests",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
