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
        let dir = pathOpts.resolvedPath
        var results: [ValidationResult] = []
        results += SpeakerDBValidator(dbPath: dir.appendingPathComponent("speakers.sqlite").path).validate()
        results += StatsDBValidator(dbPath: dir.appendingPathComponent("stats.sqlite").path).validate()
        runValidation(results: results, format: formatOpts.format)
    }
}
