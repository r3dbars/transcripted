import ArgumentParser
import Foundation

func transcriptedAppSupportDirectory() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    return appSupport.appendingPathComponent("Draft", isDirectory: true)
}

func transcriptedMeetingDirectory() -> URL {
    transcriptedAppSupportDirectory().appendingPathComponent("meetings", isDirectory: true)
}

func transcriptedTranscriptDirectory(relativeTo meetingsRoot: URL = transcriptedMeetingDirectory()) -> URL {
    meetingsRoot.appendingPathComponent("transcripts", isDirectory: true)
}

func transcriptedLogFilePath(relativeTo meetingsRoot: URL = transcriptedMeetingDirectory()) -> String {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Transcripted", isDirectory: true)
        .appendingPathComponent("app.jsonl").path
}

@main
struct TranscriptedQA: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcripted-qa",
        abstract: "Validate Transcripted on-disk artifacts under the Draft app support tree.",
        subcommands: [
            ValidateAll.self,
            ValidateTranscripts.self,
            ValidateDatabase.self,
            ValidateLogs.self,
            ValidateArtifacts.self,
            ValidateIndex.self,
            CheckHealth.self,
            GenerateFixtures.self,
            RoundTrip.self,
            StressTest.self,
        ],
        defaultSubcommand: ValidateAll.self
    )
}

// MARK: - Shared Options

struct PathOptions: ParsableArguments {
    @Option(name: .long, help: "Path to the Transcripted meetings root (defaults to ~/Library/Application Support/Draft/meetings)")
    var path: String?

    var resolvedPath: URL {
        if let path = path {
            return URL(fileURLWithPath: path)
        }
        return transcriptedMeetingDirectory()
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

func runValidation(results: [ValidationResult], format: OutputFormat) throws {
    let report = ValidationReport(results: results)
    switch format {
    case .text: report.printText()
    case .json: report.printJSON()
    }
    if report.exitCode != 0 {
        throw ExitCode(report.exitCode)
    }
}
