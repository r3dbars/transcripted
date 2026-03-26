import ArgumentParser
import Foundation

struct ValidateAll: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run all validators against the Transcripted data directory."
    )

    @OptionGroup var pathOpts: PathOptions
    @OptionGroup var formatOpts: FormatOptions

    func run() throws {
        let dir = pathOpts.resolvedPath
        let home = FileManager.default.homeDirectoryForCurrentUser

        var results: [ValidationResult] = []

        results += TranscriptValidator(directory: dir).validate()
        results += JSONSidecarValidator(directory: dir).validate()
        results += SpeakerDBValidator(dbPath: dir.appendingPathComponent("speakers.sqlite").path).validate()
        results += StatsDBValidator(dbPath: dir.appendingPathComponent("stats.sqlite").path).validate()
        results += LogValidator(logPath: home.appendingPathComponent("Library/Logs/Transcripted/app.jsonl").path).validate()
        results += IndexValidator(directory: dir).validate()
        results += HealthChecker().validate()

        runValidation(results: results, format: formatOpts.format)
    }
}
