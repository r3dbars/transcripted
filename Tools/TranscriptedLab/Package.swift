// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [
    .library(name: "TranscriptedLabKit", targets: ["TranscriptedLabKit"]),
    .executable(name: "transcripted-lab", targets: ["TranscriptedLabCLI"]),
]

var targets: [Target] = [
    .target(
        name: "TranscriptedLabKit",
        path: "Sources/TranscriptedLabKit"
    ),
    .executableTarget(
        name: "TranscriptedLabCLI",
        dependencies: ["TranscriptedLabKit"],
        path: "Sources/transcripted-lab"
    ),
    .testTarget(
        name: "TranscriptedLabKitTests",
        dependencies: ["TranscriptedLabKit"],
        path: "Tests/TranscriptedLabKitTests"
    ),
]

#if os(macOS)
products.append(.executable(name: "TranscriptedLab", targets: ["TranscriptedLab"]))
targets.append(
    .executableTarget(
        name: "TranscriptedLab",
        dependencies: ["TranscriptedLabKit"],
        path: "Sources/TranscriptedLab"
    )
)
#endif

let package = Package(
    name: "TranscriptedLab",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
