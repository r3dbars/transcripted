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
        var results = JSONSidecarValidator(directory: pathOpts.resolved.meetingsDir).validate()
        results += TimelineValidator(directory: pathOpts.resolved.timelineDir).validate()
        try runValidation(results: results, format: formatOpts.format)
    }
}
