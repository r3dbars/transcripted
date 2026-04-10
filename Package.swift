// swift-tools-version: 5.9
import PackageDescription
import Foundation

// TranscriptedCore — shared library target co-hosted with Draft.
//
// Consumed by:
//   1. Draft's meeting integration via build-deps.sh
//   2. `swift test` for the TranscriptedCore smoke tests in this repo
//
// Binary dependency layout:
//   deps-libs/libDraftDeps.a          — prebuilt mega-library (FluidAudio 0.7.9 + MLX + deps + TranscriptedCore)
//   deps-libs/libExternalDeps.a       — SwiftPM compatibility archive (currently mirrors libDraftDeps.a)
//   deps-modules/*.swiftmodule        — Swift interface files for FluidAudio et al.
//   deps-modules/FastClusterWrapper   — C header for fast-cluster C++ wrapper
//   deps-modules/MachTaskSelfWrapper  — C header for mach_task_self helper
//   deps-modules/yyjson               — C header for yyjson JSON parser
//
// `#filePath` resolves to Package.swift's absolute location on disk, so the -I/-L
// flags work whether swiftc is invoked from the package root (`swift test`) or from
// a consumer like Xcode's SPM integration which sets -working-directory elsewhere.

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "TranscriptedCore",
    platforms: [.macOS(.v14)],
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
                    "-I", "\(repoRoot)/deps-modules",
                    "-I", "\(repoRoot)/deps-modules/FastClusterWrapper",
                    "-I", "\(repoRoot)/deps-modules/MachTaskSelfWrapper",
                    "-I", "\(repoRoot)/deps-modules/yyjson",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(repoRoot)/deps-libs",
                    "-lExternalDeps",
                    "-lc++",
                ]),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
            ]
        ),
        .testTarget(
            name: "TranscriptedCoreTests",
            dependencies: ["TranscriptedCore"],
            path: "Tests/TranscriptedCoreTests",
            swiftSettings: [
                // @testable import TranscriptedCore transitively re-exports FluidAudio/MLX
                // module interfaces, so the test target needs the same -I search paths.
                .unsafeFlags([
                    "-I", "\(repoRoot)/deps-modules",
                    "-I", "\(repoRoot)/deps-modules/FastClusterWrapper",
                    "-I", "\(repoRoot)/deps-modules/MachTaskSelfWrapper",
                    "-I", "\(repoRoot)/deps-modules/yyjson",
                ]),
            ],
            linkerSettings: [
                // Mirror Core target linker flags so the xctest binary can resolve
                // FluidAudio symbols pulled in through @testable.
                .unsafeFlags([
                    "-L\(repoRoot)/deps-libs",
                    "-lExternalDeps",
                    "-lc++",
                ]),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
            ]
        ),
    ]
)
