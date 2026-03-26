import ArgumentParser
import Foundation

struct ValidateLogs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate-logs",
        abstract: "Validate app.jsonl log file format and health."
    )

    @Option(name: .long, help: "Path to app.jsonl")
    var path: String?

    @OptionGroup var formatOpts: FormatOptions

    func run() throws {
        let logPath = path ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Transcripted/app.jsonl").path
        let results = LogValidator(logPath: logPath).validate()
        runValidation(results: results, format: formatOpts.format)
    }
}
