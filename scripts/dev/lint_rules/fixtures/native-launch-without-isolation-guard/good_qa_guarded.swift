// lint-fixture-path: Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/OnboardingSmoke.swift
import Foundation

struct OnboardingSmokeRunner {
    func run(appBundleURL: URL) throws {
        guard NativeSmokeIsolation.isAllowed() else { return }
        let executableURL = appBundleURL.appendingPathComponent("Contents/MacOS/Transcripted")
        let process = Process()
        process.executableURL = executableURL
        try process.run()
    }
}
