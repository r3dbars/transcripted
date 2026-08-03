import ArgumentParser
import Foundation

struct ValidateAll: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run all validators against the Transcripted data directory."
    )

    @OptionGroup var pathOpts: PathOptions
    @OptionGroup var formatOpts: FormatOptions

    func run() throws {
        let paths = pathOpts.resolved

        var results: [ValidationResult] = []

        for directory in paths.meetingDirs {
            results += TranscriptValidator(directory: directory).validate()
        }
        for directory in paths.dictationDirs {
            results += DictationValidator(directory: directory).validate()
        }
        results += SpeakerDBValidator(dbPath: paths.stateDir.appendingPathComponent("speakers.sqlite").path).validate()
        results += StatsDBValidator(dbPath: paths.stateDir.appendingPathComponent("stats.sqlite").path).validate()
        results += LogValidator(logPath: paths.logFilePath).validate()
        results += HealthChecker(paths: paths).validate()

        try runValidation(results: results, format: formatOpts.format)
    }
}
