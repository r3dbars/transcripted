// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TranscriptedCaptureKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TranscriptedCaptureKit", targets: ["TranscriptedCaptureKit"]),
    ],
    targets: [
        .target(
            name: "TranscriptedCaptureKit",
            path: "Sources/TranscriptedCaptureKit"
        ),
        .testTarget(
            name: "TranscriptedCaptureKitTests",
            dependencies: ["TranscriptedCaptureKit"],
            path: "Tests/TranscriptedCaptureKitTests"
        ),
    ]
)
