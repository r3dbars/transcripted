// lint-fixture-path: Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/Fixture.swift
// A command that wipes whatever --output names: `--output ~` deletes the home folder.
import ArgumentParser
import Foundation

struct MakeSamples: ParsableCommand {
    @Option(name: .long, help: "Output directory")
    var output: String = "/tmp/sample-data"

    func run() throws {
        let outputURL = URL(fileURLWithPath: output)
        let fm = FileManager.default
        if fm.fileExists(atPath: output) {
            try fm.removeItem(at: outputURL)
        }
    }
}
