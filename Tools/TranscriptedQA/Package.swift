// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TranscriptedQA",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "transcripted-qa",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/TranscriptedQA",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
