// swift-tools-version: 5.9
import PackageDescription
import Foundation

// SpeakerEvalHarness — headless eval harness for the speaker-naming pipeline.
//
// Reuses the app's diarizer and voiceprint embedding implementations through
// TranscriptedCore (linked to FluidAudio via the prebuilt deps archive): WeSpeaker,
// ERes2Net, or an injected Core ML model. Calibration depends on the selected model.
//
// Depends on the root TranscriptedCore package (compiled from source). The unsafe
// search/link flags mirror Package.swift + Tools/TranscriptedCLI/Package.swift so the
// FluidAudio / Accelerate / CoreML symbols pulled in transitively resolve at link time.
//
// Requires the prebuilt dependency artifacts produced by `build-deps.sh`:
//   deps-libs/libExternalDeps.a, deps-modules/*.swiftmodule, deps-frameworks/*.framework
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // SpeakerEvalHarness
    .deletingLastPathComponent()   // Tools
    .deletingLastPathComponent()   // repo root
    .path

let depsModules = "\(repoRoot)/deps-modules"
let depsFrameworks = "\(repoRoot)/deps-frameworks"
let depsLibs = "\(repoRoot)/deps-libs"

// SwiftPM derives a path-dependency's identity from the parent directory's basename
// (e.g. "transcripted", or a git-worktree name like "cranky-borg-bcb19f"). Compute it
// so this manifest builds from the main checkout or any worktree unchanged.
let rootPackageIdentity = URL(fileURLWithPath: repoRoot).lastPathComponent

let package = Package(
    name: "SpeakerEvalHarness",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "speaker-eval-harness",
            dependencies: [
                .product(name: "TranscriptedCore", package: rootPackageIdentity),
            ],
            path: "Sources/speaker-eval-harness",
            swiftSettings: [
                .unsafeFlags([
                    "-parse-as-library",
                    "-F", depsFrameworks,
                    "-I", depsModules,
                    "-I", "\(depsModules)/FastClusterWrapper",
                    "-I", "\(depsModules)/MachTaskSelfWrapper",
                    "-I", "\(depsModules)/yyjson",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F\(depsFrameworks)",
                    "-L\(depsLibs)",
                    "-lExternalDeps",
                    "-lc++",
                    "-Xlinker", "-rpath",
                    "-Xlinker", depsFrameworks,
                ]),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
    ]
)
