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
// Diarization and transcription share the same prebuilt FluidAudio bundle;
// either env toggle links it and enables both offline audio command groups.
let enableDiarization = ProcessInfo.processInfo.environment["TRANSCRIPTEDCLI_ENABLE_DIARIZATION"] == "1"
let enableTranscription = ProcessInfo.processInfo.environment["TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION"] == "1"
// The app's shared meeting Core has a macOS 26 deployment target. Keep the
// original macOS 14 retrieval/basic-ASR build available as a separate mode.
let enableMeetingImport = ProcessInfo.processInfo.environment["TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT"] == "1"
func prebuiltModulePath(_ name: String) -> String? {
    let candidates = [
        "\(depsModulesRoot)/\(name).swiftmodule/arm64-apple-macos.swiftmodule",
        "\(depsModulesRoot)/\(name).swiftmodule",
    ]
    return candidates.first { path in
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
// SwiftPM's native and Swift Build engines export flat files and directories,
// respectively. Pin both parser modules so an older retrieval build left in
// .build cannot shadow the interfaces matching the prebuilt audio archive.
let argumentParserModules = ["ArgumentParser", "ArgumentParserToolInfo"].compactMap { name -> (name: String, path: String)? in
    guard let path = prebuiltModulePath(name) else { return nil }
    return (name, path)
}
let argumentParserModuleFlags = argumentParserModules.flatMap { module in
    ["-Xfrontend", "-swift-module-file=\(module.name)=\(module.path)"]
}
let hasAudioPipelineDeps = enableDiarization || enableTranscription || enableMeetingImport
let hasMeetingImportDeps = enableMeetingImport
// An explicit request must not silently produce a retrieval-only executable or
// a green test run without audio coverage when dependency exports are incomplete.
if hasAudioPipelineDeps {
    let requiredModules = ["FluidAudio", "ArgumentParser", "ArgumentParserToolInfo"]
        + (enableMeetingImport ? ["TranscriptedCore"] : [])
    var missing = requiredModules.filter { prebuiltModulePath($0) == nil }
    var archiveIsDirectory: ObjCBool = false
    if !fileManager.fileExists(atPath: "\(depsLibsRoot)/libDraftDeps.a", isDirectory: &archiveIsDirectory)
        || archiveIsDirectory.boolValue {
        missing.append("libDraftDeps.a")
    }
    if !missing.isEmpty {
        fatalError("Requested CLI audio mode is missing prebuilt dependencies: \(missing.joined(separator: ", ")). Run bash build-deps.sh --force from the repository root before rebuilding.")
    }
}
// libDraftDeps already contains ArgumentParser. Use its matching module in audio
// modes instead of linking a second SwiftPM copy (which can be another version).
let argumentParserTargets: [Target.Dependency] = hasAudioPipelineDeps ? [] : [
    .product(name: "ArgumentParser", package: "swift-argument-parser"),
]

let package = Package(
    name: "TranscriptedCLI",
    platforms: [.macOS(hasMeetingImportDeps ? "26.0" : "14.0")],
    // Keep the retrieval dependency declared so audio-mode builds do not remove
    // its checked-in resolution pin. Only retrieval targets link this product.
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(path: "../TranscriptedCaptureKit"),
    ],
    targets: [
        .executableTarget(
            name: "transcripted-cli",
            dependencies: argumentParserTargets + [
                .product(name: "TranscriptedCaptureKit", package: "TranscriptedCaptureKit"),
            ],
            path: "Sources/TranscriptedCLI",
            swiftSettings: (hasMeetingImportDeps ? [.define("TRANSCRIPTEDCLI_WITH_MEETING_IMPORT")] : []) + (hasAudioPipelineDeps ? [
                .define("TRANSCRIPTEDCLI_WITH_DIARIZATION"),
                .define("TRANSCRIPTEDCLI_WITH_TRANSCRIPTION"),
                .unsafeFlags([
                    "-F", depsFrameworksRoot,
                    "-I", depsModulesRoot,
                    "-I", "\(depsModulesRoot)/FastClusterWrapper",
                    "-I", "\(depsModulesRoot)/MachTaskSelfWrapper",
                    "-I", "\(depsModulesRoot)/yyjson",
                ] + argumentParserModuleFlags),
            ] : []),
            linkerSettings: [.linkedLibrary("sqlite3")] + (hasAudioPipelineDeps ? [
                .unsafeFlags([
                    "-F\(depsFrameworksRoot)",
                    "-L\(depsLibsRoot)",
                    "-Xlinker", "-rpath",
                    "-Xlinker", depsFrameworksRoot,
                    "-lDraftDeps",
                    "-lc++",
                ]),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Network"),
            ] : [])
        ),
        .testTarget(
            name: "TranscriptedCLITests",
            dependencies: argumentParserTargets + [
                "transcripted-cli",
            ],
            path: "Tests/TranscriptedCLITests",
            swiftSettings: (hasMeetingImportDeps ? [.define("TRANSCRIPTEDCLI_WITH_MEETING_IMPORT")] : []) + (hasAudioPipelineDeps ? [
                .define("TRANSCRIPTEDCLI_WITH_DIARIZATION"),
                .define("TRANSCRIPTEDCLI_WITH_TRANSCRIPTION"),
                .unsafeFlags([
                    "-F", depsFrameworksRoot,
                    "-I", depsModulesRoot,
                    "-I", "\(depsModulesRoot)/FastClusterWrapper",
                    "-I", "\(depsModulesRoot)/MachTaskSelfWrapper",
                    "-I", "\(depsModulesRoot)/yyjson",
                ] + argumentParserModuleFlags),
            ] : [])
        ),
    ]
)
