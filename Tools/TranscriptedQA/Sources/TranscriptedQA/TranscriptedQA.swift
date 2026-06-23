import ArgumentParser
import Foundation

private func transcriptedQAApplicationSupportDirectory(fileManager: FileManager = .default) -> URL {
    fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
}

struct QADataDirectories {
    let meetingsDir: URL
    let dictationsDir: URL
    let stateDir: URL
    let logFilePath: String

    static func resolve(
        meetingsDir: String? = nil,
        dictationsDir: String? = nil,
        stateDir: String? = nil,
        logPath: String? = nil,
        fileManager: FileManager = .default
    ) -> QADataDirectories {
        let appSupport = transcriptedQAApplicationSupportDirectory(fileManager: fileManager)
        let home = fileManager.homeDirectoryForCurrentUser

        let currentRoot = appSupport.appendingPathComponent("Transcripted", isDirectory: true)
        let current = QADataDirectories(
            meetingsDir: currentRoot.appendingPathComponent("captures/meetings", isDirectory: true),
            dictationsDir: currentRoot.appendingPathComponent("captures/dictations", isDirectory: true),
            stateDir: currentRoot.appendingPathComponent("state", isDirectory: true),
            logFilePath: currentRoot.appendingPathComponent("logs/app.jsonl", isDirectory: false).path
        )

        let draftRoot = appSupport.appendingPathComponent("Draft", isDirectory: true)
        let legacyDraft = QADataDirectories(
            meetingsDir: draftRoot.appendingPathComponent("meetings/transcripts", isDirectory: true),
            dictationsDir: draftRoot.appendingPathComponent("transcripts", isDirectory: true),
            stateDir: draftRoot.appendingPathComponent("meetings", isDirectory: true),
            logFilePath: home.appendingPathComponent("Library/Logs/Transcripted/app.jsonl", isDirectory: false).path
        )

        let legacySharedRoot = home.appendingPathComponent("Documents/Transcripted", isDirectory: true)
        let legacyShared = QADataDirectories(
            meetingsDir: legacySharedRoot,
            dictationsDir: legacySharedRoot,
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
                dictationsDir: resolveDictationsDirectory(
                    explicit: dictationsDir,
                    meetingsDir: normalizedMeetings,
                    inferredBase: inferredBase,
                    fileManager: fileManager
                ),
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
                dictationsDir: dictationsDir.map { URL(fileURLWithPath: $0).standardizedFileURL } ?? defaultBase.dictationsDir,
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

    private static func resolveDictationsDirectory(
        explicit dictationsDir: String?,
        meetingsDir: URL,
        inferredBase: QADataDirectories,
        fileManager: FileManager
    ) -> URL {
        if let dictationsDir, !dictationsDir.isEmpty {
            return URL(fileURLWithPath: dictationsDir).standardizedFileURL
        }

        let standardized = meetingsDir.standardizedFileURL

        if standardized.lastPathComponent == "meetings" {
            return standardized.deletingLastPathComponent().appendingPathComponent("dictations", isDirectory: true)
        }

        let childDictations = standardized.appendingPathComponent("dictations", isDirectory: true)
        if fileManager.fileExists(atPath: childDictations.path) {
            return childDictations
        }

        if containsDictationDayMarkdown(in: standardized, fileManager: fileManager) {
            return standardized
        }

        if standardized.path.hasPrefix(inferredBase.meetingsDir.standardizedFileURL.path)
            || standardized.path.hasPrefix(inferredBase.stateDir.standardizedFileURL.path) {
            return inferredBase.dictationsDir
        }

        return childDictations
    }

    private static func containsDictationDayMarkdown(in directory: URL, fileManager: FileManager) -> Bool {
        guard let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        return files.contains { $0.hasPrefix("Dictations_") && $0.hasSuffix(".md") }
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
            PermissionState.self,
            GenerateFixtures.self,
            RoundTrip.self,
            StressTest.self,
            ImportedAudioSmoke.self,
            UISmoke.self,
            PackagedAppSmoke.self,
        ],
        defaultSubcommand: ValidateAll.self
    )
}

// MARK: - Shared Options

struct PathOptions: ParsableArguments {
    @Option(name: .long, help: "Path to the meetings capture directory. Defaults to ~/Library/Application Support/Transcripted/captures/meetings, with legacy Draft/Documents fallback.")
    var path: String?

    @Option(name: .long, help: "Path to the dictations capture directory. Defaults follow the selected layout.")
    var dictationsPath: String?

    @Option(name: .long, help: "Path to the state directory containing speakers.sqlite and stats.sqlite. Defaults follow the selected layout.")
    var stateDir: String?

    @Option(name: .long, help: "Path to app.jsonl. Defaults follow the selected layout.")
    var logPath: String?

    var resolved: QADataDirectories {
        QADataDirectories.resolve(meetingsDir: path, dictationsDir: dictationsPath, stateDir: stateDir, logPath: logPath)
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
