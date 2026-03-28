import ArgumentParser
import Foundation

@main
struct TranscriptedQA: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcripted-qa",
        abstract: "Validate Transcripted on-disk artifacts — transcripts, databases, logs, sidecars.",
        subcommands: [
            ValidateAll.self,
            ValidateTranscripts.self,
            ValidateDatabase.self,
            ValidateLogs.self,
            ValidateArtifacts.self,
            ValidateIndex.self,
            CheckHealth.self,
        ],
        defaultSubcommand: ValidateAll.self
    )
}

// MARK: - Shared Options

struct PathOptions: ParsableArguments {
    @Option(name: .long, help: "Path to the Transcripted data directory")
    var path: String?

    var resolvedPath: URL {
        if let path = path {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Transcripted")
    }
}

enum OutputFormat: String, ExpressibleByArgument {
    case text
    case json
}

struct FormatOptions: ParsableArguments {
    @Option(name: .long, help: "Output format: text or json")
    var format: OutputFormat = .text
}

// MARK: - Helper

func runValidation(results: [ValidationResult], format: OutputFormat) {
    let report = ValidationReport(results: results)
    switch format {
    case .text: report.printText()
    case .json: report.printJSON()
    }
    if report.exitCode != 0 {
        Darwin.exit(report.exitCode)
    }
}
