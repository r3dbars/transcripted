// swift-tools-version: 5.9
import PackageDescription

// TranscriptedCore — SPM library target extracted from Transcripted.
//
// Consumed by:
//   1. Draft (via path: dependency) — see Draft/Package.swift
//   2. Transcripted.xcodeproj app target (via "Add Package Dependency" on local path)
//
// Binary dependency layout:
//   .deps-libs/libDraftDeps.a        — prebuilt mega-library (FluidAudio 0.7.9 + MLX + deps)
//   .deps-modules/*.swiftmodule      — Swift interface files for FluidAudio et al.
//   .deps-modules/FastClusterWrapper — C header for fast-cluster C++ wrapper
//   .deps-modules/MachTaskSelfWrapper — C header for mach_task_self helper
//   .deps-modules/yyjson             — C header for yyjson JSON parser
//
// Both .deps-libs and .deps-modules are symlinks pointing at Draft's build artifacts:
//   .deps-libs    -> ../../../../Draft/deps-libs
//   .deps-modules -> ../../../../Draft/deps-modules

let repoRoot = "."

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
            swiftSettings: [
                .unsafeFlags([
                    "-I", "\(repoRoot)/.deps-modules",
                    "-I", "\(repoRoot)/.deps-modules/FastClusterWrapper",
                    "-I", "\(repoRoot)/.deps-modules/MachTaskSelfWrapper",
                    "-I", "\(repoRoot)/.deps-modules/yyjson",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(repoRoot)/.deps-libs",
                    "-lDraftDeps",
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
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "TranscriptedCoreTests",
            dependencies: ["TranscriptedCore"],
            path: "Tests/TranscriptedCoreTests"
        ),
    ]
)
