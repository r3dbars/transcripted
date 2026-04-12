import ArgumentParser
import Foundation

struct ValidateIndex: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate-index",
        abstract: "Validate the legacy transcripted.json index file if it exists."
    )

    @OptionGroup var pathOpts: PathOptions
    @OptionGroup var formatOpts: FormatOptions

    func run() throws {
        let results = IndexValidator(directory: pathOpts.resolved.meetingsDir).validate()
        try runValidation(results: results, format: formatOpts.format)
    }
}
