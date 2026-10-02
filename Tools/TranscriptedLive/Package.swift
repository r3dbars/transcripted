// swift-tools-version: 6.0
import PackageDescription

// Experiment: live meeting transcription for the Claude Code mod in claude-mod/.
// Standalone on purpose. It pulls FluidAudio straight from SwiftPM (same pin as
// build-deps.sh) instead of the app's prebuilt archives, and never links the app.
let package = Package(
    name: "TranscriptedLive",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "transcripted-live", targets: ["TranscriptedLive"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.0")
    ],
    targets: [
        .target(
            name: "TranscriptedLiveCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TranscriptedLive",
            dependencies: ["TranscriptedLiveCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TranscriptedLiveTests",
            dependencies: ["TranscriptedLiveCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
