import Foundation

public actor LabExperimentRunner {
    private let processRunner: LabProcessRunner
    private let reportStore: LabReportStore
    private let artifactRoot: URL
    private let fileManager: FileManager

    public init(
        processRunner: LabProcessRunner = LabProcessRunner(),
        reportStore: LabReportStore = LabReportStore(),
        artifactRoot: URL = LabPaths.artifactsRoot(),
        fileManager: FileManager = .default
    ) {
        self.processRunner = processRunner
        self.reportStore = reportStore
        self.artifactRoot = artifactRoot
        self.fileManager = fileManager
    }

    public func run(_ configuration: LabRunConfiguration) async -> LabRunReport {
        let id = UUID()
        let startedAt = Date()
        let runArtifacts = artifactRoot.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        do {
            try fileManager.createDirectory(at: runArtifacts, withIntermediateDirectories: true)
            let command = try LabCommandBuilder.build(
                configuration: configuration,
                runID: id,
                artifactDirectory: runArtifacts,
                fileManager: fileManager
            )
            let expected = LabCommandBuilder.expectedArtifacts(
                configuration: configuration,
                runID: id,
                artifactDirectory: runArtifacts
            )
            let processResult: LabProcessResult?
            if let command {
                processResult = try await processRunner.run(command, timeoutSeconds: configuration.timeoutSeconds)
            } else {
                processResult = nil
            }

            if let processResult, processResult.timedOut || processResult.exitCode != 0 {
                let failure = processResult.timedOut
                    ? "Experiment timed out after \(Int(configuration.timeoutSeconds)) seconds."
                    : "Experiment process exited with code \(processResult.exitCode)."
                let report = LabRunReport(
                    id: id,
                    startedAt: startedAt,
                    finishedAt: Date(),
                    status: .failed,
                    configuration: configuration,
                    summary: failure,
                    scorecard: LabScorecard(overallScore: 0, hardGateFailures: [failure]),
                    metrics: [],
                    command: command,
                    process: processResult,
                    artifacts: existingArtifacts(expected),
                    sourceRevision: gitRevision(repositoryPath: configuration.repositoryPath)
                )
                _ = try? reportStore.save(report, fileManager: fileManager)
                return report
            }

            let analysis = try analyze(
                configuration: configuration,
                runID: id,
                artifactDirectory: runArtifacts,
                expectedArtifacts: expected
            )
            let report = LabRunReport(
                id: id,
                startedAt: startedAt,
                finishedAt: Date(),
                status: status(for: analysis.scorecard),
                configuration: configuration,
                summary: analysis.summary,
                scorecard: analysis.scorecard,
                metrics: analysis.metrics,
                command: command,
                process: processResult,
                artifacts: uniqueArtifacts(analysis.artifacts + existingArtifacts(expected)),
                sourceRevision: gitRevision(repositoryPath: configuration.repositoryPath)
            )
            try reportStore.save(report, fileManager: fileManager)
            return report
        } catch {
            let message = error.localizedDescription
            let report = LabRunReport(
                id: id,
                startedAt: startedAt,
                finishedAt: Date(),
                status: .failed,
                configuration: configuration,
                summary: message,
                scorecard: LabScorecard(overallScore: 0, hardGateFailures: [message]),
                metrics: [],
                command: nil,
                process: nil,
                artifacts: [],
                sourceRevision: gitRevision(repositoryPath: configuration.repositoryPath)
            )
            _ = try? reportStore.save(report, fileManager: fileManager)
            return report
        }
    }

    private func analyze(
        configuration: LabRunConfiguration,
        runID: UUID,
        artifactDirectory: URL,
        expectedArtifacts: [LabArtifact]
    ) throws -> LabAnalysisResult {
        switch configuration.bench {
        case .runtimeSnapshot:
            return try RuntimeEventAnalyzer.analyze(
                eventsURL: URL(fileURLWithPath: configuration.runtimeEventsPath),
                windowHours: configuration.runtimeWindowHours,
                minimumSamples: max(1, configuration.minimumSamples),
                strictGates: configuration.strictGates
            )

        case .dictationStop:
            guard let raw = expectedArtifacts.first(where: { $0.label == "Raw dictation results" }) else {
                throw LabRunnerError.reportNotFound("dictation JSONL")
            }
            let summary = expectedArtifacts.first(where: { $0.label == "Dictation summary" })
            return try DictationBenchmarkAnalyzer.analyze(
                resultURL: URL(fileURLWithPath: raw.path),
                summaryURL: summary.map { URL(fileURLWithPath: $0.path) }
            )

        case .transcriptionCorpus:
            guard let report = expectedArtifacts.first(where: { $0.label == "Transcription QA report" }),
                  let results = expectedArtifacts.first(where: { $0.label == "Transcription QA results" }) else {
                throw LabRunnerError.reportNotFound("transcription corpus report")
            }
            return try QAResultsAnalyzer.analyze(
                resultsURL: URL(fileURLWithPath: results.path),
                reportURL: URL(fileURLWithPath: report.path),
                title: "Transcription corpus"
            )

        case .speakerIdentity:
            if configuration.speakerMode == .thresholdSweep {
                return try SpeakerSweepAnalyzer.analyze(configuration: configuration)
            }
            let stateDirectory = configuration.speakerStateDirectory.isEmpty
                ? artifactDirectory.appendingPathComponent("speaker-autoresearch", isDirectory: true)
                : URL(fileURLWithPath: configuration.speakerStateDirectory, isDirectory: true)
            return SpeakerAutoResearchAnalyzer.analyze(stateDirectory: stateDirectory)

        case .qa:
            guard let report = expectedArtifacts.first(where: { $0.label == "QA report" }),
                  let results = expectedArtifacts.first(where: { $0.label == "QA results" }) else {
                throw LabRunnerError.reportNotFound("QA report")
            }
            return try QAResultsAnalyzer.analyze(
                resultsURL: URL(fileURLWithPath: results.path),
                reportURL: URL(fileURLWithPath: report.path),
                title: "Transcripted QA"
            )
        }
    }

    private func status(for scorecard: LabScorecard) -> LabRunStatus {
        if !scorecard.hardGateFailures.isEmpty { return .failed }
        if !scorecard.warnings.isEmpty { return .warning }
        if scorecard.overallScore == nil { return .incomplete }
        return .passed
    }

    private func existingArtifacts(_ artifacts: [LabArtifact]) -> [LabArtifact] {
        artifacts.filter { fileManager.fileExists(atPath: $0.path) }
    }

    private func uniqueArtifacts(_ artifacts: [LabArtifact]) -> [LabArtifact] {
        var seen = Set<String>()
        return artifacts.filter { seen.insert($0.path).inserted }
    }

    private func gitRevision(repositoryPath: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repositoryPath, "rev-parse", "HEAD"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

public struct LabDoctorCheck: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let passed: Bool
    public let detail: String
}

public enum LabDoctor {
    public static func inspect(repositoryPath: String, fileManager: FileManager = .default) -> [LabDoctorCheck] {
        let root = URL(fileURLWithPath: repositoryPath, isDirectory: true)
        let checks: [(String, String)] = [
            ("Transcripted repository", "AGENTS.md"),
            ("QA bench", "scripts/ops/transcripted-qa-bench.sh"),
            ("Dictation benchmark", "scripts/ops/dictation-stop-autoeval.sh"),
            ("Speaker eval", "scripts/run_speaker_eval.sh"),
            ("Speaker auto-research", "scripts/run_speaker_autoresearch.py"),
            ("Speaker harness", "Tools/SpeakerEvalHarness/Package.swift"),
        ]
        var results = checks.map { name, relative in
            let url = root.appendingPathComponent(relative)
            return LabDoctorCheck(name: name, passed: fileManager.fileExists(atPath: url.path), detail: url.path)
        }
        for executable in ["/usr/bin/git", "/bin/bash", "/usr/bin/env"] {
            results.append(LabDoctorCheck(
                name: URL(fileURLWithPath: executable).lastPathComponent,
                passed: fileManager.isExecutableFile(atPath: executable),
                detail: executable
            ))
        }
        return results
    }
}
