// swift-tools-version: 5.9
import Foundation
import PackageDescription

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .path
let fileManager = FileManager.default
let depsModulesRoot = "\(repoRoot)/deps-modules"
let depsFrameworksRoot = "\(repoRoot)/deps-frameworks"
let depsLibsRoot = "\(repoRoot)/deps-libs"
let enableDiarization = ProcessInfo.processInfo.environment["TRANSCRIPTEDCLI_ENABLE_DIARIZATION"] == "1"
let fluidAudioModuleCandidates = [
    "\(depsModulesRoot)/FluidAudio.swiftmodule",
    "\(depsModulesRoot)/FluidAudio.swiftmodule/arm64-apple-macos.swiftmodule",
]
let hasDiarizationDeps = enableDiarization
    && fluidAudioModuleCandidates.contains(where: { fileManager.fileExists(atPath: $0) })
    && fileManager.fileExists(atPath: "\(depsLibsRoot)/libDraftDeps.a")
    && fileManager.fileExists(atPath: "\(depsFrameworksRoot)/ESpeakNG.framework")

let package = Package(
    name: "TranscriptedCLI",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(path: "../TranscriptedCaptureKit"),
    ],
    targets: [
        .executableTarget(
            name: "transcripted-cli",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "TranscriptedCaptureKit", package: "TranscriptedCaptureKit"),
            ],
            path: "Sources/TranscriptedCLI",
            swiftSettings: hasDiarizationDeps ? [
                .define("TRANSCRIPTEDCLI_WITH_DIARIZATION"),
                .unsafeFlags([
                    "-F", depsFrameworksRoot,
                    "-I", depsModulesRoot,
                    "-I", "\(depsModulesRoot)/FastClusterWrapper",
                    "-I", "\(depsModulesRoot)/MachTaskSelfWrapper",
                    "-I", "\(depsModulesRoot)/yyjson",
                ]),
            ] : [],
            linkerSettings: hasDiarizationDeps ? [
                .unsafeFlags([
                    "-F\(depsFrameworksRoot)",
                    "-L\(depsLibsRoot)",
                    "-Xlinker", "-rpath",
                    "-Xlinker", depsFrameworksRoot,
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
            ] : []
        ),
        .testTarget(
            name: "TranscriptedCLITests",
            dependencies: [
                "transcripted-cli",
                .product(name: "TranscriptedCaptureKit", package: "TranscriptedCaptureKit"),
            ],
            path: "Tests/TranscriptedCLITests",
            swiftSettings: hasDiarizationDeps ? [
                .define("TRANSCRIPTEDCLI_WITH_DIARIZATION"),
                .unsafeFlags([
                    "-F", depsFrameworksRoot,
                    "-I", depsModulesRoot,
                    "-I", "\(depsModulesRoot)/FastClusterWrapper",
                    "-I", "\(depsModulesRoot)/MachTaskSelfWrapper",
                    "-I", "\(depsModulesRoot)/yyjson",
                ]),
            ] : []
        ),
    ]
)
