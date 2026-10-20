// lint-fixture-path: Tools/SpeakerEvalHarness/Sources/speaker-eval-harness/Fixture.swift
// Shape of the speaker lab before 4e6942113: stale results are removed by series id
// with no check that `setDir/<id>` stays inside the set folder (an id of `../x` escapes).
import Foundation

func runSeries(_ args: [String]) async {
    let setDir = URL(fileURLWithPath: argValue("--set", in: args) ?? "eval/sets/default", isDirectory: true)
    let series = loadSeries(setDir)
    let fm = FileManager.default
    let finished = Set(series.meetings.map(\.id).filter { id in
        fm.fileExists(atPath: setDir.appendingPathComponent(id).appendingPathComponent("lab_result.json").path)
    })
    for id in finished {
        try? fm.removeItem(at: setDir.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("lab_result.json"))
    }
}
