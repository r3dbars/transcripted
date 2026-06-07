import ArgumentParser
import Foundation

private func transcriptedQAApplicationSupportDirectory(fileManager: FileManager = .default) -> URL {
    fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
}

struct QADataDirectories {
    let meetingsDir: URL
    let stateDir: URL
    let logFilePath: String

    static func resolve(
        meetingsDir: String? = nil,
        stateDir: String? = nil,
        logPath: String? = nil,
        fileManager: FileManager = .default
    ) -> QADataDirectories {
        let appSupport = transcriptedQAApplicationSupportDirectory(fileManager: fileManager)
        let home = fileManager.homeDirectoryForCurrentUser

        let currentRoot = appSupport.appendingPathComponent("Transcripted", isDirectory: true)
        let current = QADataDirectories(
            meetingsDir: currentRoot.appendingPathComponent("captures/meetings", isDirectory: true),
            stateDir: currentRoot.appendingPathComponent("state", isDirectory: true),
            logFilePath: currentRoot.appendingPathComponent("logs/app.jsonl", isDirectory: false).path
        )

        let draftRoot = appSupport.appendingPathComponent("Draft", isDirectory: true)
        let legacyDraft = QADataDirectories(
            meetingsDir: draftRoot.appendingPathComponent("meetings/transcripts", isDirectory: true),
            stateDir: draftRoot.appendingPathComponent("meetings", isDirectory: true),
            logFilePath: home.appendingPathComponent("Library/Logs/Transcripted/app.jsonl", isDirectory: false).path
        )

        let legacySharedRoot = home.appendingPathComponent("Documents/Transcripted", isDirectory: true)
        let legacyShared = QADataDirectories(
            meetingsDir: legacySharedRoot,
            stateDir: legacySharedRoot,
            logFilePath: home.appendingPathComponent("Library/Logs/Transcripted/app.jsonl", isDirectory: false).path
        )

        let selectedBase: QADataDirectories
        if let meetingsDir, !meetingsDir.isEmpty {
            let normalizedMeetings = normalizeMeetingsDirectory(URL(fileURLWithPath: meetingsDir), fileManager: fileManager)
            let inferredBase = inferBaseLayout(
                for: normalizedMeetings,
                current: current,
                legacyDraft: legacyDraft,
                legacyShared: legacyShared
            )
            selectedBase = QADataDirectories(
                meetingsDir: normalizedMeetings,
                stateDir: stateDir.map { URL(fileURLWithPath: $0).standardizedFileURL } ?? inferredBase.stateDir,
                logFilePath: logPath ?? inferredBase.logFilePath
            )
        } else {
            let defaultBase: QADataDirectories
            if fileManager.fileExists(atPath: current.meetingsDir.path) || fileManager.fileExists(atPath: current.stateDir.path) {
                defaultBase = current
            } else if fileManager.fileExists(atPath: legacyDraft.meetingsDir.path) || fileManager.fileExists(atPath: legacyDraft.stateDir.path) {
                defaultBase = legacyDraft
            } else if fileManager.fileExists(atPath: legacyShared.meetingsDir.path) {
                defaultBase = legacyShared
            } else {
                defaultBase = current
            }

            selectedBase = QADataDirectories(
                meetingsDir: defaultBase.meetingsDir,
                stateDir: stateDir.map { URL(fileURLWithPath: $0).standardizedFileURL } ?? defaultBase.stateDir,
                logFilePath: logPath ?? defaultBase.logFilePath
            )
        }

        return selectedBase
    }

    var logsDirectory: URL {
        URL(fileURLWithPath: logFilePath).deletingLastPathComponent()
    }

    private static func normalizeMeetingsDirectory(_ candidate: URL, fileManager: FileManager) -> URL {
        let standardized = candidate.standardizedFileURL
        if standardized.lastPathComponent == "meetings" {
            let legacyTranscriptSubdir = standardized.appendingPathComponent("transcripts", isDirectory: true)
            if fileManager.fileExists(atPath: legacyTranscriptSubdir.path) {
                return legacyTranscriptSubdir
            }
        }
        return standardized
    }

    private static func inferBaseLayout(
        for meetingsDir: URL,
        current: QADataDirectories,
        legacyDraft: QADataDirectories,
        legacyShared: QADataDirectories
    ) -> QADataDirectories {
        let path = meetingsDir.standardizedFileURL.path
        if path.hasPrefix(legacyDraft.stateDir.standardizedFileURL.path) {
            return legacyDraft
        }
        if path.hasPrefix(legacyShared.meetingsDir.standardizedFileURL.path) {
            return legacyShared
        }
        return current
    }
}

@main
struct TranscriptedQA: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcripted-qa",
        abstract: "Validate Transcripted on-disk meeting artifacts, state databases, and logs.",
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
            UISmoke.self,
        ],
        defaultSubcommand: ValidateAll.self
    )
}

// MARK: - Shared Options

struct PathOptions: ParsableArguments {
    @Option(name: .long, help: "Path to the meetings capture directory. Defaults to ~/Library/Application Support/Transcripted/captures/meetings, with legacy Draft/Documents fallback.")
    var path: String?

    @Option(name: .long, help: "Path to the state directory containing speakers.sqlite and stats.sqlite. Defaults follow the selected layout.")
    var stateDir: String?

    @Option(name: .long, help: "Path to app.jsonl. Defaults follow the selected layout.")
    var logPath: String?

    var resolved: QADataDirectories {
        QADataDirectories.resolve(meetingsDir: path, stateDir: stateDir, logPath: logPath)
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
