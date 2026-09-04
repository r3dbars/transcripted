import Foundation

public enum LabCommandBuilder {
    public static func build(
        configuration: LabRunConfiguration,
        runID: UUID,
        artifactDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> LabCommand? {
        let repo = URL(fileURLWithPath: configuration.repositoryPath, isDirectory: true).standardizedFileURL
        guard LabRepositoryLocator.isTranscriptedRepository(repo, fileManager: fileManager) else {
            throw LabRunnerError.invalidRepository(configuration.repositoryPath)
        }

        switch configuration.bench {
        case .runtimeSnapshot:
            return nil

        case .dictationStop:
            let script = repo.appendingPathComponent("scripts/ops/dictation-stop-autoeval.sh")
            try requireFile(script, fileManager: fileManager)
            let label = LabShell.safeLabel(configuration.name) + "-" + runID.uuidString.lowercased().prefix(8)
            var arguments = [
                script.path,
                "--label", String(label),
                "--variant", configuration.dictationVariant.rawValue,
                "--iterations", String(max(1, configuration.repetitions)),
                "--chunk-seconds", String(configuration.chunkSeconds),
                "--finalization-order", configuration.dictationFinalizationOrder.rawValue,
                "--encoder-compute", configuration.encoderComputeMode.rawValue,
            ]
            if configuration.skipBuild { arguments.append("--skip-build") }
            if configuration.includeSilence { arguments.append("--include-silence") }
            if !configuration.simulateAutoEnter { arguments.append("--no-auto-enter") }
            return LabCommand(
                executable: "/bin/bash",
                arguments: arguments,
                environment: [
                    "TRANSCRIPTED_DICTATION_STOP_BENCH_WORK_DIR": artifactDirectory.appendingPathComponent("dictation", isDirectory: true).path,
                    "TRANSCRIPTED_DISABLE_FILE_LOGGER": "1",
                    "TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS": "1",
                ],
                workingDirectory: repo.path,
                summary: "Replay dictation fixtures through Transcripted's production finalization path."
            )

        case .transcriptionCorpus:
            let script = repo.appendingPathComponent("scripts/ops/transcripted-qa-bench.sh")
            try requireFile(script, fileManager: fileManager)
            guard !configuration.corpusRoot.isEmpty else {
                throw LabRunnerError.invalidConfiguration("Transcription Bench needs a corpus root.")
            }
            let outputRoot = artifactDirectory.appendingPathComponent("transcription", isDirectory: true)
            var arguments = [
                script.path,
                "--mode", "corpus-compare",
                "--run-id", runID.uuidString.lowercased(),
                "--out-root", outputRoot.path,
                "--corpus-root", configuration.corpusRoot,
                "--corpus-min-recall", String(configuration.corpusMinimumRecall),
                "--corpus-min-content-recall", String(configuration.corpusMinimumContentRecall),
            ]
            if !configuration.corpusIDs.isEmpty {
                arguments += ["--corpus-ids", configuration.corpusIDs]
            }
            if !configuration.corpusOutputDirectory.isEmpty {
                arguments += ["--corpus-output-dir", configuration.corpusOutputDirectory]
            }
            if !configuration.corpusCandidateMap.isEmpty {
                arguments += ["--corpus-candidate-map", configuration.corpusCandidateMap]
            }
            return LabCommand(
                executable: "/bin/bash",
                arguments: arguments,
                environment: ["TRANSCRIPTED_DISABLE_FILE_LOGGER": "1"],
                workingDirectory: repo.path,
                summary: "Validate a local meeting corpus and compare Transcripted Markdown against its truth transcript."
            )

        case .speakerIdentity:
            switch configuration.speakerMode {
            case .thresholdSweep:
                let script = repo.appendingPathComponent("scripts/run_speaker_eval.sh")
                try requireFile(script, fileManager: fileManager)
                var environment = [
                    "CORPUS": configuration.speakerCorpus.rawValue,
                    "CONSOLIDATION": configuration.consolidationThresholds,
                    "MATCH": configuration.matchThresholds,
                    "COLLAR": String(configuration.speakerCollar),
                    "ALLOW_PARTIAL_CORPUS": configuration.allowPartialCorpus ? "1" : "0",
                ]
                if !configuration.speakerSeries.isEmpty {
                    environment["SERIES"] = configuration.speakerSeries
                }
                return LabCommand(
                    executable: "/bin/bash",
                    arguments: [script.path],
                    environment: environment,
                    workingDirectory: repo.path,
                    summary: "Run labeled-audio speaker diarization, clustering, and cross-meeting identity threshold sweeps."
                )

            case .autoResearch:
                let script = repo.appendingPathComponent("scripts/run_speaker_autoresearch.py")
                try requireFile(script, fileManager: fileManager)
                guard !configuration.speakerManifestPath.isEmpty else {
                    throw LabRunnerError.invalidConfiguration("Speaker auto-research needs a frozen manifest.")
                }
                guard !configuration.speakerInputRoot.isEmpty else {
                    throw LabRunnerError.invalidConfiguration("Speaker auto-research needs an input root.")
                }
                let stateDirectory = configuration.speakerStateDirectory.isEmpty
                    ? artifactDirectory.appendingPathComponent("speaker-autoresearch", isDirectory: true).path
                    : configuration.speakerStateDirectory
                var arguments = [
                    "python3", script.path,
                    "--manifest", configuration.speakerManifestPath,
                    "--input-root", configuration.speakerInputRoot,
                    "--state-dir", stateDirectory,
                    "--phase", configuration.speakerResearchPhase.rawValue,
                    "--top-k", String(max(1, configuration.speakerTopK)),
                ]
                if configuration.skipBuild { arguments.append("--skip-build") }
                return LabCommand(
                    executable: "/usr/bin/env",
                    arguments: arguments,
                    environment: [:],
                    workingDirectory: repo.path,
                    summary: "Run the frozen ASK / SUGGEST / AUTO speaker-identity research loop with locked holdout validation."
                )
            }

        case .qa:
            let script = repo.appendingPathComponent("scripts/ops/transcripted-qa-bench.sh")
            try requireFile(script, fileManager: fileManager)
            let outputRoot = artifactDirectory.appendingPathComponent("qa", isDirectory: true)
            var arguments = [
                script.path,
                "--mode", configuration.qaMode.rawValue,
                "--run-id", runID.uuidString.lowercased(),
                "--out-root", outputRoot.path,
            ]
            if configuration.skipBuild { arguments.append("--skip-build") }
            return LabCommand(
                executable: "/bin/bash",
                arguments: arguments,
                environment: ["TRANSCRIPTED_DISABLE_FILE_LOGGER": "1"],
                workingDirectory: repo.path,
                summary: "Run Transcripted's existing QA orchestrator in \(configuration.qaMode.rawValue) mode."
            )
        }
    }

    public static func expectedArtifacts(
        configuration: LabRunConfiguration,
        runID: UUID,
        artifactDirectory: URL
    ) -> [LabArtifact] {
        switch configuration.bench {
        case .runtimeSnapshot:
            return [LabArtifact(label: "Runtime events", path: configuration.runtimeEventsPath)]
        case .dictationStop:
            let label = LabShell.safeLabel(configuration.name) + "-" + runID.uuidString.lowercased().prefix(8)
            let stem = "\(label)-\(configuration.dictationVariant.rawValue)-\(configuration.encoderComputeMode.rawValue)"
            let resultRoot = artifactDirectory.appendingPathComponent("dictation/results", isDirectory: true)
            return [
                LabArtifact(label: "Raw dictation results", path: resultRoot.appendingPathComponent("\(stem).jsonl").path),
                LabArtifact(label: "Dictation summary", path: resultRoot.appendingPathComponent("\(stem).summary.md").path),
            ]
        case .transcriptionCorpus:
            let root = artifactDirectory
                .appendingPathComponent("transcription", isDirectory: true)
                .appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true)
            return [
                LabArtifact(label: "Transcription QA report", path: root.appendingPathComponent("qa-report.md").path),
                LabArtifact(label: "Transcription QA results", path: root.appendingPathComponent("results.tsv").path),
            ]
        case .speakerIdentity:
            if configuration.speakerMode == .thresholdSweep {
                let root = URL(fileURLWithPath: configuration.repositoryPath, isDirectory: true)
                    .appendingPathComponent("data/eval/\(configuration.speakerCorpus.rawValue)/reports", isDirectory: true)
                return [LabArtifact(label: "Speaker sweep", path: root.appendingPathComponent("SWEEP.md").path)]
            }
            let root = configuration.speakerStateDirectory.isEmpty
                ? artifactDirectory.appendingPathComponent("speaker-autoresearch", isDirectory: true)
                : URL(fileURLWithPath: configuration.speakerStateDirectory, isDirectory: true)
            return [
                LabArtifact(label: "Speaker auto-research report", path: root.appendingPathComponent("final-report.md").path),
                LabArtifact(label: "Speaker experiment ledger", path: root.appendingPathComponent("results.tsv").path),
            ]
        case .qa:
            let root = artifactDirectory
                .appendingPathComponent("qa", isDirectory: true)
                .appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true)
            return [
                LabArtifact(label: "QA report", path: root.appendingPathComponent("qa-report.md").path),
                LabArtifact(label: "QA results", path: root.appendingPathComponent("results.tsv").path),
            ]
        }
    }

    private static func requireFile(_ url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw LabRunnerError.missingInput(url.path)
        }
    }
}
