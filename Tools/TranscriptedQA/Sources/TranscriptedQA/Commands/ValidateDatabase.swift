import ArgumentParser
import Foundation

struct ValidateDatabase: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate-database",
        abstract: "Validate all speaker databases and stats.sqlite integrity and schema."
    )

    @OptionGroup var pathOpts: PathOptions
    @OptionGroup var formatOpts: FormatOptions

    func run() throws {
        let paths = pathOpts.resolved
        var results: [ValidationResult] = []
        results += SpeakerDBValidator.validateAll(in: paths.stateDir)
        results += StatsDBValidator(dbPath: paths.stateDir.appendingPathComponent("stats.sqlite").path).validate()
        try runValidation(results: results, format: formatOpts.format)
    }
}
