import ArgumentParser
import Foundation

struct ValidateDatabase: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate-database",
        abstract: "Validate speakers.sqlite and stats.sqlite integrity and schema."
    )

    @OptionGroup var pathOpts: PathOptions
    @OptionGroup var formatOpts: FormatOptions

    func run() throws {
        let paths = pathOpts.resolved
        var results: [ValidationResult] = []
        results += SpeakerDBValidator(dbPath: paths.stateDir.appendingPathComponent("speakers.sqlite").path).validate()
        results += StatsDBValidator(dbPath: paths.stateDir.appendingPathComponent("stats.sqlite").path).validate()
        try runValidation(results: results, format: formatOpts.format, command: "validate-database", paths: paths)
    }
}
