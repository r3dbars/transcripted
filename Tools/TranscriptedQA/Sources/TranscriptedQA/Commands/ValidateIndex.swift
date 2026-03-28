import ArgumentParser
import Foundation

struct ValidateIndex: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate-index",
        abstract: "Validate transcripted.json index file cross-references."
    )

    @OptionGroup var pathOpts: PathOptions
    @OptionGroup var formatOpts: FormatOptions

    func run() throws {
        let results = IndexValidator(directory: pathOpts.resolvedPath).validate()
        runValidation(results: results, format: formatOpts.format)
    }
}
