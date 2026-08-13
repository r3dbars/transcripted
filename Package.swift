// swift-tools-version: 5.9
import PackageDescription
import Foundation

// TranscriptedCore — shared library target used by Transcripted's meeting pipeline.
//
// Consumed by:
//   1. Transcripted's app build through build-deps.sh
//   2. `swift test` for the TranscriptedCore smoke tests in this repo
//
// Binary dependency layout:
//   deps-libs/libDraftDeps.a          — legacy-named prebuilt library (FluidAudio + MLX + deps + TranscriptedCore)
//   deps-libs/libExternalDeps.a       — external-only archive for SPM tests (no TranscriptedCore objects)
//   deps-modules/*.swiftmodule        — Swift interface files for FluidAudio et al.
//   deps-modules/FastClusterWrapper   — C header for fast-cluster C++ wrapper
//   deps-modules/MachTaskSelfWrapper  — C header for mach_task_self helper
//   deps-modules/yyjson               — C header for yyjson JSON parser
//
// `#filePath` resolves to Package.swift's absolute location on disk, so the -I/-L
// flags work whether swiftc is invoked from the package root (`swift test`) or from
// a consumer like Xcode's SPM integration which sets -working-directory elsewhere.

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// TranscriptedCoreTests used to be ONE monolithic test target covering the
// entire package, so every one-file change paid the whole suite's compile +
// link + run cost. It is now split per source subsystem
// (Sources/TranscriptedCore/{Audio,Speaker,Pipeline,Storage,Logging,Utilities,...})
// so `swift test --filter <Target>Tests` (or Xcode's per-target test navigator)
// gives a fast, scoped loop, while `swift test` with no filter still runs every
// target — CI and `swift test --filter TranscriptionTaskManagerMetadataTests`
// (still a valid class-name filter: PipelineTests splits that class across
// several files via same-target extensions) behave exactly as before.
//
// Each split-out test target is its own xctest bundle, so every target repeats
// the same deps-frameworks/deps-modules/deps-libs flags the old single target
// used — @testable import TranscriptedCore transitively re-exports
// FluidAudio/MLX module interfaces in every target that imports it, and each
// target's xctest binary needs to resolve those symbols at link time.
let coreTestUnsafeSwiftFlags: [String] = [
    "-F", "\(repoRoot)/deps-frameworks",
    "-I", "\(repoRoot)/deps-modules",
    "-I", "\(repoRoot)/deps-modules/FastClusterWrapper",
    "-I", "\(repoRoot)/deps-modules/MachTaskSelfWrapper",
    "-I", "\(repoRoot)/deps-modules/yyjson",
]

let coreTestLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-F\(repoRoot)/deps-frameworks",
        "-L\(repoRoot)/deps-libs",
        "-lExternalDeps",
        "-lc++",
        "-Xlinker", "-rpath",
        "-Xlinker", "\(repoRoot)/deps-frameworks",
    ]),
    .linkedFramework("Metal"),
    .linkedFramework("MetalKit"),
    .linkedFramework("Accelerate"),
    .linkedFramework("CoreML"),
    .linkedFramework("CoreAudio"),
    .linkedFramework("AVFoundation"),
    .linkedFramework("Network"),
    .linkedFramework("ScreenCaptureKit"),
]

func coreTestTarget(_ name: String, _ path: String) -> Target {
    .testTarget(
        name: name,
        dependencies: ["TranscriptedCore"],
        path: path,
        swiftSettings: [.unsafeFlags(coreTestUnsafeSwiftFlags)],
        linkerSettings: coreTestLinkerSettings
    )
}

// Per-subsystem test targets, mapped from Tests/TranscriptedCoreTests/ contents
// (see the directory split alongside this file). There is no separate "Common"
// target: none of the current test files share a fixture or helper across
// subsystem boundaries (every helper type/fixture in the old monolithic target
// was already `private`/file-scoped, or — for the ERes2Net JSON fixture — has
// exactly one consumer), so a resource-only shared target would add SPM
// ceremony with no current benefit. Revisit if a future fixture needs sharing
// across these targets.
let coreTestTargets: [Target] = [
    coreTestTarget("AudioTests", "Tests/TranscriptedCoreTests/AudioTests"),
    coreTestTarget("SpeakerTests", "Tests/TranscriptedCoreTests/SpeakerTests"),
    coreTestTarget("PipelineTests", "Tests/TranscriptedCoreTests/PipelineTests"),
    coreTestTarget("StorageTests", "Tests/TranscriptedCoreTests/StorageTests"),
    coreTestTarget("UtilitiesTests", "Tests/TranscriptedCoreTests/UtilitiesTests"),
]

let package = Package(
    name: "TranscriptedCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(
            name: "TranscriptedCore",
            targets: ["TranscriptedCore"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TranscriptedCore",
            dependencies: [],
            path: "Sources/TranscriptedCore",
            exclude: ["CLAUDE.md"],
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
                    "-lExternalDeps",
                    "-lc++",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "\(repoRoot)/deps-frameworks",
                ]),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Network"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
    ] + coreTestTargets
)
