import ArgumentParser
import Foundation

struct ValidateTranscripts: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate-transcripts",
        abstract: "Validate .md transcript files for YAML frontmatter and content."
    )

    @OptionGroup var pathOpts: PathOptions
    @OptionGroup var formatOpts: FormatOptions

    func run() throws {
        let results = TranscriptValidator(directory: pathOpts.resolvedPath).validate()
        runValidation(results: results, format: formatOpts.format)
    }
}
