import Foundation
import TranscriptedLabKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct TranscriptedLabCLI {
    static func main() async {
        do {
            let code = try await run(arguments: Array(CommandLine.arguments.dropFirst()))
            exit(code)
        } catch {
            fputs("transcripted-lab: \(error.localizedDescription)\n", stderr)
            exit(2)
        }
    }

    private static func run(arguments: [String]) async throws -> Int32 {
        guard let command = arguments.first else {
            printHelp()
            return 0
        }
        switch command {
        case "help", "-h", "--help":
            printHelp()
            return 0
        case "run":
            return try await runExperiment(Array(arguments.dropFirst()))
        case "snapshot":
            return try await runExperiment([LabBench.runtimeSnapshot.rawValue] + Array(arguments.dropFirst()))
        case "doctor":
            return try doctor(Array(arguments.dropFirst()))
        case "list":
            return try listReports(Array(arguments.dropFirst()))
        case "show":
            return try showReport(Array(arguments.dropFirst()))
        case "compare":
            return try compareReports(Array(arguments.dropFirst()))
        default:
            throw LabRunnerError.invalidConfiguration("Unknown command '\(command)'. Run transcripted-lab help.")
        }
    }

    private static func runExperiment(_ arguments: [String]) async throws -> Int32 {
        guard let benchValue = arguments.first, let bench = LabBench(rawValue: benchValue) else {
            throw LabRunnerError.invalidConfiguration("Run needs a bench: \(LabBench.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let locatedRepo = LabRepositoryLocator.locate()?.path ?? FileManager.default.currentDirectoryPath
        var configuration = LabRunConfiguration.defaults(repositoryPath: locatedRepo)
        configuration.bench = bench
        configuration.name = bench.title
        var outputJSON = false
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--repo": configuration.repositoryPath = try value(after: option, in: arguments, index: &index)
            case "--name": configuration.name = try value(after: option, in: arguments, index: &index)
            case "--repetitions": configuration.repetitions = try integer(after: option, in: arguments, index: &index)
            case "--timeout": configuration.timeoutSeconds = try number(after: option, in: arguments, index: &index)
            case "--skip-build": configuration.skipBuild = true
            case "--events": configuration.runtimeEventsPath = try value(after: option, in: arguments, index: &index)
            case "--window-hours": configuration.runtimeWindowHours = try number(after: option, in: arguments, index: &index)
            case "--minimum-samples": configuration.minimumSamples = try integer(after: option, in: arguments, index: &index)
            case "--no-strict-gates": configuration.strictGates = false
            case "--variant": configuration.dictationVariant = try enumValue(after: option, in: arguments, index: &index)
            case "--finalization-order": configuration.dictationFinalizationOrder = try enumValue(after: option, in: arguments, index: &index)
            case "--encoder-compute": configuration.encoderComputeMode = try enumValue(after: option, in: arguments, index: &index)
            case "--chunk-seconds": configuration.chunkSeconds = try number(after: option, in: arguments, index: &index)
            case "--include-silence": configuration.includeSilence = true
            case "--exclude-silence": configuration.includeSilence = false
            case "--no-auto-enter": configuration.simulateAutoEnter = false
            case "--corpus-root": configuration.corpusRoot = try value(after: option, in: arguments, index: &index)
            case "--corpus-ids": configuration.corpusIDs = try value(after: option, in: arguments, index: &index)
            case "--corpus-output-dir": configuration.corpusOutputDirectory = try value(after: option, in: arguments, index: &index)
            case "--corpus-candidate-map": configuration.corpusCandidateMap = try value(after: option, in: arguments, index: &index)
            case "--minimum-recall": configuration.corpusMinimumRecall = try number(after: option, in: arguments, index: &index)
            case "--minimum-content-recall": configuration.corpusMinimumContentRecall = try number(after: option, in: arguments, index: &index)
            case "--speaker-mode": configuration.speakerMode = try enumValue(after: option, in: arguments, index: &index)
            case "--speaker-corpus": configuration.speakerCorpus = try enumValue(after: option, in: arguments, index: &index)
            case "--series": configuration.speakerSeries = try value(after: option, in: arguments, index: &index)
            case "--consolidation": configuration.consolidationThresholds = try value(after: option, in: arguments, index: &index)
            case "--match": configuration.matchThresholds = try value(after: option, in: arguments, index: &index)
            case "--collar": configuration.speakerCollar = try number(after: option, in: arguments, index: &index)
            case "--allow-partial-corpus": configuration.allowPartialCorpus = true
            case "--manifest": configuration.speakerManifestPath = try value(after: option, in: arguments, index: &index)
            case "--input-root": configuration.speakerInputRoot = try value(after: option, in: arguments, index: &index)
            case "--state-dir": configuration.speakerStateDirectory = try value(after: option, in: arguments, index: &index)
            case "--phase": configuration.speakerResearchPhase = try enumValue(after: option, in: arguments, index: &index)
            case "--top-k": configuration.speakerTopK = try integer(after: option, in: arguments, index: &index)
            case "--qa-mode": configuration.qaMode = try enumValue(after: option, in: arguments, index: &index)
            case "--json": outputJSON = true
            case "-h", "--help":
                printRunHelp()
                return 0
            default:
                throw LabRunnerError.invalidConfiguration("Unknown run option '\(option)'.")
            }
            index += 1
        }

        let runner = LabExperimentRunner()
        let report = await runner.run(configuration)
        if outputJSON {
            try printJSON(report)
        } else {
            printReport(report)
        }
        return report.status == .failed ? 1 : 0
    }

    private static func doctor(_ arguments: [String]) throws -> Int32 {
        var repositoryPath = LabRepositoryLocator.locate()?.path ?? FileManager.default.currentDirectoryPath
        var outputJSON = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--repo": repositoryPath = try value(after: "--repo", in: arguments, index: &index)
            case "--json": outputJSON = true
            default: throw LabRunnerError.invalidConfiguration("Unknown doctor option '\(arguments[index])'.")
            }
            index += 1
        }
        let checks = LabDoctor.inspect(repositoryPath: repositoryPath)
        if outputJSON {
            try printJSON(checks)
        } else {
            print("Transcripted Lab doctor — \(repositoryPath)")
            checks.forEach { print("\($0.passed ? "PASS" : "FAIL")  \($0.name): \($0.detail)") }
        }
        return checks.allSatisfy(\.passed) ? 0 : 1
    }

    private static func listReports(_ arguments: [String]) throws -> Int32 {
        let outputJSON = arguments.contains("--json")
        let reports = try LabReportStore().loadAll()
        if outputJSON {
            try printJSON(reports)
        } else if reports.isEmpty {
            print("No Transcripted Lab runs yet.")
        } else {
            for report in reports {
                let score = report.scorecard.overallScore.map(String.init) ?? "—"
                print("\(report.id.uuidString.lowercased())  \(report.status.rawValue.uppercased())  \(score)  \(report.configuration.bench.title)  \(report.configuration.name)")
            }
        }
        return 0
    }

    private static func showReport(_ arguments: [String]) throws -> Int32 {
        guard let token = arguments.first else {
            throw LabRunnerError.invalidConfiguration("show needs a report UUID or prefix.")
        }
        let report = try findReport(token)
        if arguments.contains("--json") {
            try printJSON(report)
        } else {
            printReport(report)
        }
        return report.status == .failed ? 1 : 0
    }

    private static func compareReports(_ arguments: [String]) throws -> Int32 {
        guard arguments.count >= 2 else {
            throw LabRunnerError.invalidConfiguration("compare needs BASELINE_ID CANDIDATE_ID.")
        }
        let baseline = try findReport(arguments[0])
        let candidate = try findReport(arguments[1])
        let comparison = LabReportComparator.compare(baseline: baseline, candidate: candidate)
        if arguments.contains("--json") {
            try printJSON(comparison)
        } else {
            print("Baseline:  \(baseline.id.uuidString.lowercased())")
            print("Candidate: \(candidate.id.uuidString.lowercased())")
            print("Score delta: \(comparison.scoreDelta.map { $0 >= 0 ? "+\($0)" : "\($0)" } ?? "n/a")")
            for metric in comparison.metricDeltas {
                let sign = metric.delta >= 0 ? "+" : ""
                print("\(metric.label): \(numberString(metric.baseline)) → \(numberString(metric.candidate)) \(metric.unit) (\(sign)\(numberString(metric.delta)))")
            }
            if !comparison.newHardGateFailures.isEmpty {
                print("New hard failures:")
                comparison.newHardGateFailures.forEach { print("- \($0)") }
            }
            if !comparison.resolvedHardGateFailures.isEmpty {
                print("Resolved hard failures:")
                comparison.resolvedHardGateFailures.forEach { print("- \($0)") }
            }
        }
        return comparison.newHardGateFailures.isEmpty ? 0 : 1
    }

    private static func findReport(_ token: String) throws -> LabRunReport {
        let normalized = token.lowercased()
        let matches = try LabReportStore().loadAll().filter {
            $0.id.uuidString.lowercased().hasPrefix(normalized)
        }
        guard matches.count == 1, let report = matches.first else {
            throw LabRunnerError.reportNotFound(matches.isEmpty ? token : "Ambiguous prefix \(token)")
        }
        return report
    }

    private static func value(after option: String, in arguments: [String], index: inout Int) throws -> String {
        let next = index + 1
        guard next < arguments.count else {
            throw LabRunnerError.invalidConfiguration("\(option) needs a value.")
        }
        index = next
        return arguments[next]
    }

    private static func integer(after option: String, in arguments: [String], index: inout Int) throws -> Int {
        let raw = try value(after: option, in: arguments, index: &index)
        guard let value = Int(raw) else { throw LabRunnerError.invalidConfiguration("\(option) needs an integer.") }
        return value
    }

    private static func number(after option: String, in arguments: [String], index: inout Int) throws -> Double {
        let raw = try value(after: option, in: arguments, index: &index)
        guard let value = Double(raw) else { throw LabRunnerError.invalidConfiguration("\(option) needs a number.") }
        return value
    }

    private static func enumValue<T: RawRepresentable>(after option: String, in arguments: [String], index: inout Int) throws -> T where T.RawValue == String {
        let raw = try value(after: option, in: arguments, index: &index)
        guard let value = T(rawValue: raw) else { throw LabRunnerError.invalidConfiguration("Unknown value '\(raw)' for \(option).") }
        return value
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    private static func printReport(_ report: LabRunReport) {
        print("\(report.configuration.name)")
        print("Bench: \(report.configuration.bench.title)")
        print("Status: \(report.status.rawValue.uppercased())")
        print("Score: \(report.scorecard.overallScore.map(String.init) ?? "n/a")")
        print(report.summary)
        if !report.scorecard.hardGateFailures.isEmpty {
            print("Hard failures:")
            report.scorecard.hardGateFailures.forEach { print("- \($0)") }
        }
        if !report.scorecard.warnings.isEmpty {
            print("Warnings:")
            report.scorecard.warnings.forEach { print("- \($0)") }
        }
        if !report.metrics.isEmpty {
            print("Metrics:")
            report.metrics.forEach { print("- \($0.label): \(numberString($0.value)) \($0.unit)") }
        }
        print("Run ID: \(report.id.uuidString.lowercased())")
    }

    private static func numberString(_ value: Double) -> String {
        if abs(value) >= 100 { return String(format: "%.0f", value) }
        if abs(value) >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.3f", value)
    }

    private static func printHelp() {
        print("""
        Transcripted Lab — experiment workbench for Transcripted

        Usage:
          transcripted-lab run BENCH [options]
          transcripted-lab snapshot [options]
          transcripted-lab doctor [--repo PATH] [--json]
          transcripted-lab list [--json]
          transcripted-lab show RUN_ID [--json]
          transcripted-lab compare BASELINE_ID CANDIDATE_ID [--json]

        Benches:
          runtime-snapshot       Score recent events.jsonl latency and reliability
          dictation-stop         Run the production dictation stop benchmark
          transcription-corpus   Compare Transcripted output with a local truth corpus
          speaker-identity       Sweep speaker thresholds or run speaker auto-research
          qa                     Run the existing QA bench

        Run `transcripted-lab run runtime-snapshot --help` for the main knob list.
        """)
    }

    private static func printRunHelp() {
        print("""
        Common:
          --repo PATH --name NAME --timeout SECONDS --skip-build --json

        Runtime Snapshot:
          --events PATH --window-hours N --minimum-samples N --no-strict-gates

        Dictation Bench:
          --variant production|native|pre_resampled|chunked
          --repetitions N --finalization-order saveBeforeAutoEnter|saveAfterAutoEnter
          --encoder-compute default|cpu-and-gpu|all --chunk-seconds N
          --include-silence|--exclude-silence --no-auto-enter

        Transcription Bench:
          --corpus-root PATH --corpus-ids IDS --corpus-output-dir PATH
          --corpus-candidate-map PATH --minimum-recall N --minimum-content-recall N

        Speaker Bench:
          --speaker-mode threshold-sweep|auto-research
          --speaker-corpus ami|icsi|voxconverse|voxceleb
          --series "IDS" --consolidation "GRID" --match "GRID" --collar N
          --allow-partial-corpus
          Auto-research: --manifest PATH --input-root PATH --state-dir PATH
                         --phase prepare|discover|validate|all --top-k N

        QA Bench:
          --qa-mode quick|deep|full|ui|imported-audio-native|packaged|artifact|audio-synthetic|pasteback-synthetic|live
        """)
    }
}
