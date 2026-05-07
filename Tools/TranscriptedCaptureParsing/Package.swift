// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TranscriptedCaptureParsing",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "TranscriptedCaptureParsing",
            targets: ["TranscriptedCaptureParsing"]
        ),
    ],
    targets: [
        .target(
            name: "TranscriptedCaptureParsing",
            path: "Sources/TranscriptedCaptureParsing"
        ),
    ]
)
