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
        let paths = pathOpts.resolved
        let results = IndexValidator(directory: paths.meetingsDir).validate()
        try runValidation(results: results, format: formatOpts.format, command: "validate-index", paths: paths)
    }
}
