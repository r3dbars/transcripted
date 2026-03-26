import ArgumentParser
import Foundation

struct ValidateArtifacts: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate-artifacts",
        abstract: "Validate .json sidecar files for schema and consistency."
    )

    @OptionGroup var pathOpts: PathOptions
    @OptionGroup var formatOpts: FormatOptions

    func run() throws {
        let results = JSONSidecarValidator(directory: pathOpts.resolvedPath).validate()
        runValidation(results: results, format: formatOpts.format)
    }
}
