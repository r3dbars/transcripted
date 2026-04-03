// swift-tools-version: 5.9
import PackageDescription

let repoRoot = "../.."

let package = Package(
    name: "TranscriptedCLI",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "transcripted-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/TranscriptedCLI",
            swiftSettings: [
                .unsafeFlags([
                    "-I", "\(repoRoot)/fluidaudio-modules",
                    "-I", "\(repoRoot)/fluidaudio-modules/FastClusterWrapper",
                    "-I", "\(repoRoot)/fluidaudio-modules/MachTaskSelfWrapper",
                    "-I", "\(repoRoot)/fluidaudio-modules/yyjson",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(repoRoot)/Tools/TranscriptedCLI",
                    "-lFluidAudioCLI",
                    "-lc++",
                ]),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Network"),
            ]
        ),
    ]
)
