// swift-tools-version: 5.9
import Foundation
import PackageDescription

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .path

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
                    "-F", "\(repoRoot)/deps-frameworks",
                    "-I", "\(repoRoot)/deps-modules",
                    "-I", "\(repoRoot)/deps-modules/FastClusterWrapper",
                    "-I", "\(repoRoot)/deps-modules/MachTaskSelfWrapper",
                    "-I", "\(repoRoot)/deps-modules/yyjson",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F\(repoRoot)/deps-frameworks",
                    "-L\(repoRoot)/deps-libs",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "\(repoRoot)/deps-frameworks",
                    "-lDraftDeps",
                    "-lc++",
                ]),
                .linkedFramework("ESpeakNG"),
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
