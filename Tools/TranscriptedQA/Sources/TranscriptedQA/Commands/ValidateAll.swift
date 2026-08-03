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

        results += validateTranscripts(in: paths.meetingDirs)
        results += validateDictations(in: paths.dictationDirs)
        results += SpeakerDBValidator(dbPath: paths.stateDir.appendingPathComponent("speakers.sqlite").path).validate()
        results += StatsDBValidator(dbPath: paths.stateDir.appendingPathComponent("stats.sqlite").path).validate()
        results += LogValidator(logPath: paths.logFilePath).validate()
        results += HealthChecker(paths: paths).validate()

        try runValidation(results: results, format: formatOpts.format)
    }
}

func validateTranscripts(in directories: [URL]) -> [ValidationResult] {
    directories.reduce(into: [ValidationResult]()) { results, directory in
        results += TranscriptValidator(directory: directory).validate()
    }
}

func validateDictations(in directories: [URL]) -> [ValidationResult] {
    directories.reduce(into: [ValidationResult]()) { results, directory in
        results += DictationValidator(directory: directory).validate()
    }
}
