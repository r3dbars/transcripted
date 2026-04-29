import ArgumentParser
import Foundation

struct ValidateArtifacts: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate-artifacts",
        abstract: "Validate optional legacy JSON artifacts for schema and consistency."
    )

    @OptionGroup var pathOpts: PathOptions
    @OptionGroup var formatOpts: FormatOptions

    func run() throws {
        let paths = pathOpts.resolved
        let results = JSONSidecarValidator(directory: paths.meetingsDir).validate()
        try runValidation(results: results, format: formatOpts.format, command: "validate-artifacts", paths: paths)
    }
}
