// lint-fixture-path: Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/Fixture.swift
// Shape of the update smoke before 5b84fe3d2: a stale report is deleted through a
// scenario folder named by run id and state, which may be a symlink out of the run root.
import Foundation

struct ScenarioRunner {
    let fileManager = FileManager.default

    func runScenario(outputURL: URL, runID: String, state: String) throws {
        let scenarioDirectory = outputURL
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
            .appendingPathComponent(state, isDirectory: true)
        let reportURL = scenarioDirectory.appendingPathComponent("launch-ui-smoke.json", isDirectory: false)
        try fileManager.createDirectory(at: scenarioDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: reportURL.path) {
            try fileManager.removeItem(at: reportURL)
        }
    }
}
