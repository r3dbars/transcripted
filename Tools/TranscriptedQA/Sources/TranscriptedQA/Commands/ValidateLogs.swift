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
        let paths = QADataDirectories.resolve(logPath: path)
        let logPath = paths.logFilePath
        let results = LogValidator(logPath: logPath).validate()
        try runValidation(results: results, format: formatOpts.format, command: "validate-logs", paths: paths)
    }
}
