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
        let transcriptsDir = transcriptedTranscriptDirectory(relativeTo: dir)
        let logsPath = transcriptedLogFilePath(relativeTo: dir)

        var results: [ValidationResult] = []

        results += TranscriptValidator(directory: transcriptsDir).validate()
        results += JSONSidecarValidator(directory: transcriptsDir).validate()
        results += SpeakerDBValidator(dbPath: dir.appendingPathComponent("speakers.sqlite").path).validate()
        results += StatsDBValidator(dbPath: dir.appendingPathComponent("stats.sqlite").path).validate()
        results += LogValidator(logPath: logsPath).validate()
        results += IndexValidator(directory: transcriptsDir).validate()
        results += HealthChecker(dataPath: dir).validate()

        try runValidation(results: results, format: formatOpts.format)
    }
}
