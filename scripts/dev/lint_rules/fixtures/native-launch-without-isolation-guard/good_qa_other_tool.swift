// lint-fixture-path: Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/PackagedAppCheck.swift
import Foundation

// NativeSmokeIsolation lives elsewhere; this file only checks the bundle.
struct PackagedAppCheck {
    func run(appBundleURL: URL) throws {
        let executableURL = appBundleURL.appendingPathComponent("Contents/MacOS/Transcripted")
        _ = FileManager.default.isExecutableFile(atPath: executableURL.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    }
}
