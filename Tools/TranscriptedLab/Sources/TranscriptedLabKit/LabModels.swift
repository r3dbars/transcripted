import Foundation

public enum LabBench: String, Codable, CaseIterable, Identifiable, Sendable {
    case runtimeSnapshot = "runtime-snapshot"
    case dictationStop = "dictation-stop"
    case transcriptionCorpus = "transcription-corpus"
    case speakerIdentity = "speaker-identity"
    case qa = "qa"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .runtimeSnapshot: return "Runtime Snapshot"
        case .dictationStop: return "Dictation Bench"
        case .transcriptionCorpus: return "Transcription Bench"
        case .speakerIdentity: return "Speaker Bench"
        case .qa: return "QA Bench"
        }
    }

    public var summary: String {
        switch self {
        case .runtimeSnapshot:
            return "Score recent production telemetry for transcription, dictation start, dictation stop, and fallback behavior."
        case .dictationStop:
            return "Replay synthetic WAV fixtures through Transcripted's production dictation finalization path and measure decode, text-ready, save, and delivery latency."
        case .transcriptionCorpus:
            return "Compare Transcripted meeting output against a local truth corpus. Accuracy and artifact integrity are scored; runtime speed comes from the Runtime Snapshot."
        case .speakerIdentity:
            return "Run the app's real diarizer, voice embeddings, clustering, and cross-meeting identity matcher against labeled audio."
        case .qa:
            return "Run the existing Transcripted QA orchestrator and normalize its pass, warn, fail, and skip results into a Lab report."
        }
    }
}

public enum DictationVariant: String, Codable, CaseIterable, Identifiable, Sendable {
    case production
    case native
    case preResampled = "pre_resampled"
    case chunked

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .production: return "Production path"
        case .native: return "Native model input"
        case .preResampled: return "Pre-resampled"
        case .chunked: return "Chunked"
        }
    }
}

public enum DictationFinalizationOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case saveBeforeAutoEnter
    case saveAfterAutoEnter

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .saveBeforeAutoEnter: return "Save before Auto Enter"
        case .saveAfterAutoEnter: return "Save after Auto Enter"
        }
    }
}

public enum EncoderComputeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case `default`
    case cpuAndGPU = "cpu-and-gpu"
    case all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .default: return "Default"
        case .cpuAndGPU: return "CPU + GPU"
        case .all: return "All compute units"
        }
    }
}

public enum SpeakerExperimentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case thresholdSweep = "threshold-sweep"
    case autoResearch = "auto-research"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .thresholdSweep: return "Threshold sweep"
        case .autoResearch: return "ASK / SUGGEST / AUTO research"
        }
    }
}

public enum SpeakerCorpus: String, Codable, CaseIterable, Identifiable, Sendable {
    case ami
    case icsi
    case voxconverse
    case voxceleb

    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
}

public enum SpeakerResearchPhase: String, Codable, CaseIterable, Identifiable, Sendable {
    case prepare
    case discover
    case validate
    case all

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum QABenchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case quick
    case deep
    case full
    case ui
    case importedAudioNative = "imported-audio-native"
    case packaged
    case artifact
    case audioSynthetic = "audio-synthetic"
    case pastebackSynthetic = "pasteback-synthetic"
    case live

    public var id: String { rawValue }
    public var title: String { rawValue.replacingOccurrences(of: "-", with: " ").capitalized }
}

public struct LabRunConfiguration: Codable, Equatable, Sendable {
    public var name: String
    public var bench: LabBench
    public var repositoryPath: String
    public var repetitions: Int
    public var timeoutSeconds: Double
    public var skipBuild: Bool

    public var runtimeEventsPath: String
    public var runtimeWindowHours: Double
    public var minimumSamples: Int
    public var strictGates: Bool

    public var dictationVariant: DictationVariant
    public var dictationFinalizationOrder: DictationFinalizationOrder
    public var encoderComputeMode: EncoderComputeMode
    public var chunkSeconds: Double
    public var includeSilence: Bool
    public var simulateAutoEnter: Bool

    public var corpusRoot: String
    public var corpusIDs: String
    public var corpusOutputDirectory: String
    public var corpusCandidateMap: String
    public var corpusMinimumRecall: Double
    public var corpusMinimumContentRecall: Double

    public var speakerMode: SpeakerExperimentMode
    public var speakerCorpus: SpeakerCorpus
    public var speakerSeries: String
    public var consolidationThresholds: String
    public var matchThresholds: String
    public var speakerCollar: Double
    public var allowPartialCorpus: Bool
    public var speakerManifestPath: String
    public var speakerInputRoot: String
    public var speakerStateDirectory: String
    public var speakerResearchPhase: SpeakerResearchPhase
    public var speakerTopK: Int

    public var qaMode: QABenchMode

    public init(
        name: String = "Transcripted experiment",
        bench: LabBench = .runtimeSnapshot,
        repositoryPath: String,
        repetitions: Int = 3,
        timeoutSeconds: Double = 3_600,
        skipBuild: Bool = false,
        runtimeEventsPath: String = "",
        runtimeWindowHours: Double = 168,
        minimumSamples: Int = 10,
        strictGates: Bool = true,
        dictationVariant: DictationVariant = .production,
        dictationFinalizationOrder: DictationFinalizationOrder = .saveBeforeAutoEnter,
        encoderComputeMode: EncoderComputeMode = .default,
        chunkSeconds: Double = 30,
        includeSilence: Bool = true,
        simulateAutoEnter: Bool = true,
        corpusRoot: String = "",
        corpusIDs: String = "",
        corpusOutputDirectory: String = "",
        corpusCandidateMap: String = "",
        corpusMinimumRecall: Double = 0.45,
        corpusMinimumContentRecall: Double = 0.35,
        speakerMode: SpeakerExperimentMode = .thresholdSweep,
        speakerCorpus: SpeakerCorpus = .ami,
        speakerSeries: String = "",
        consolidationThresholds: String = "none 0.82 0.85 0.88 0.91",
        matchThresholds: String = "0.50 0.55 0.60 0.65 0.70",
        speakerCollar: Double = 0.25,
        allowPartialCorpus: Bool = false,
        speakerManifestPath: String = "",
        speakerInputRoot: String = "",
        speakerStateDirectory: String = "",
        speakerResearchPhase: SpeakerResearchPhase = .all,
        speakerTopK: Int = 8,
        qaMode: QABenchMode = .quick
    ) {
        self.name = name
        self.bench = bench
        self.repositoryPath = repositoryPath
        self.repetitions = repetitions
        self.timeoutSeconds = timeoutSeconds
        self.skipBuild = skipBuild
        self.runtimeEventsPath = runtimeEventsPath
        self.runtimeWindowHours = runtimeWindowHours
        self.minimumSamples = minimumSamples
        self.strictGates = strictGates
        self.dictationVariant = dictationVariant
        self.dictationFinalizationOrder = dictationFinalizationOrder
        self.encoderComputeMode = encoderComputeMode
        self.chunkSeconds = chunkSeconds
        self.includeSilence = includeSilence
        self.simulateAutoEnter = simulateAutoEnter
        self.corpusRoot = corpusRoot
        self.corpusIDs = corpusIDs
        self.corpusOutputDirectory = corpusOutputDirectory
        self.corpusCandidateMap = corpusCandidateMap
        self.corpusMinimumRecall = corpusMinimumRecall
        self.corpusMinimumContentRecall = corpusMinimumContentRecall
        self.speakerMode = speakerMode
        self.speakerCorpus = speakerCorpus
        self.speakerSeries = speakerSeries
        self.consolidationThresholds = consolidationThresholds
        self.matchThresholds = matchThresholds
        self.speakerCollar = speakerCollar
        self.allowPartialCorpus = allowPartialCorpus
        self.speakerManifestPath = speakerManifestPath
        self.speakerInputRoot = speakerInputRoot
        self.speakerStateDirectory = speakerStateDirectory
        self.speakerResearchPhase = speakerResearchPhase
        self.speakerTopK = speakerTopK
        self.qaMode = qaMode
    }

    public static func defaults(repositoryPath: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> LabRunConfiguration {
        let appSupport = homeDirectory
            .appendingPathComponent("Library/Application Support/Transcripted", isDirectory: true)
        let corpusRoot = homeDirectory.appendingPathComponent("Downloads/meeting-corpus", isDirectory: true)
        return LabRunConfiguration(
            repositoryPath: repositoryPath,
            runtimeEventsPath: appSupport.appendingPathComponent("logs/events.jsonl").path,
            corpusRoot: corpusRoot.path,
            corpusOutputDirectory: corpusRoot.appendingPathComponent("transcripted-output", isDirectory: true).path
        )
    }
}

public enum LabRunStatus: String, Codable, Sendable {
    case passed
    case warning
    case failed
    case incomplete
    case cancelled

    public var title: String { rawValue.capitalized }
}

public enum LabMetricDirection: String, Codable, Sendable {
    case lowerIsBetter
    case higherIsBetter
    case target
    case informational
}

public struct LabMetric: Codable, Equatable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let value: Double
    public let unit: String
    public let sampleCount: Int?
    public let target: Double?
    public let direction: LabMetricDirection

    public init(
        key: String,
        label: String,
        value: Double,
        unit: String,
        sampleCount: Int? = nil,
        target: Double? = nil,
        direction: LabMetricDirection = .informational
    ) {
        self.key = key
        self.label = label
        self.value = value
        self.unit = unit
        self.sampleCount = sampleCount
        self.target = target
        self.direction = direction
    }
}

public struct LabScoreDimension: Codable, Equatable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let score: Int
    public let weight: Double
    public let explanation: String

    public init(key: String, label: String, score: Int, weight: Double, explanation: String) {
        self.key = key
        self.label = label
        self.score = max(0, min(100, score))
        self.weight = weight
        self.explanation = explanation
    }
}

public struct LabScorecard: Codable, Equatable, Sendable {
    public let overallScore: Int?
    public let dimensions: [LabScoreDimension]
    public let hardGateFailures: [String]
    public let warnings: [String]

    public init(
        overallScore: Int?,
        dimensions: [LabScoreDimension] = [],
        hardGateFailures: [String] = [],
        warnings: [String] = []
    ) {
        self.overallScore = overallScore.map { max(0, min(100, $0)) }
        self.dimensions = dimensions
        self.hardGateFailures = hardGateFailures
        self.warnings = warnings
    }

    public static func weighted(
        dimensions: [LabScoreDimension],
        hardGateFailures: [String] = [],
        warnings: [String] = []
    ) -> LabScorecard {
        let usable = dimensions.filter { $0.weight > 0 }
        guard !usable.isEmpty else {
            return LabScorecard(overallScore: nil, dimensions: dimensions, hardGateFailures: hardGateFailures, warnings: warnings)
        }
        let totalWeight = usable.reduce(0) { $0 + $1.weight }
        let weighted = usable.reduce(0.0) { $0 + Double($1.score) * $1.weight }
        return LabScorecard(
            overallScore: Int((weighted / totalWeight).rounded()),
            dimensions: dimensions,
            hardGateFailures: hardGateFailures,
            warnings: warnings
        )
    }
}

public struct LabArtifact: Codable, Equatable, Identifiable, Sendable {
    public var id: String { path }
    public let label: String
    public let path: String

    public init(label: String, path: String) {
        self.label = label
        self.path = path
    }
}

public struct LabCommand: Codable, Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String
    public let summary: String

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: String,
        summary: String
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.summary = summary
    }

    public var displayCommand: String {
        ([executable] + arguments).map(LabShell.quote).joined(separator: " ")
    }
}

public struct LabProcessResult: Codable, Equatable, Sendable {
    public let exitCode: Int32
    public let timedOut: Bool
    public let durationSeconds: Double
    public let stdoutTail: String
    public let stderrTail: String

    public init(exitCode: Int32, timedOut: Bool, durationSeconds: Double, stdoutTail: String, stderrTail: String) {
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.durationSeconds = durationSeconds
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
    }
}

public struct LabAnalysisResult: Sendable {
    public let summary: String
    public let metrics: [LabMetric]
    public let scorecard: LabScorecard
    public let artifacts: [LabArtifact]

    public init(summary: String, metrics: [LabMetric], scorecard: LabScorecard, artifacts: [LabArtifact] = []) {
        self.summary = summary
        self.metrics = metrics
        self.scorecard = scorecard
        self.artifacts = artifacts
    }
}

public struct LabRunReport: Codable, Equatable, Identifiable, Sendable {
    public static let schemaVersion = 1

    public let schema: Int
    public let id: UUID
    public let startedAt: Date
    public let finishedAt: Date
    public let status: LabRunStatus
    public let configuration: LabRunConfiguration
    public let summary: String
    public let scorecard: LabScorecard
    public let metrics: [LabMetric]
    public let command: LabCommand?
    public let process: LabProcessResult?
    public let artifacts: [LabArtifact]
    public let sourceRevision: String?

    public init(
        id: UUID,
        startedAt: Date,
        finishedAt: Date,
        status: LabRunStatus,
        configuration: LabRunConfiguration,
        summary: String,
        scorecard: LabScorecard,
        metrics: [LabMetric],
        command: LabCommand?,
        process: LabProcessResult?,
        artifacts: [LabArtifact],
        sourceRevision: String?
    ) {
        self.schema = Self.schemaVersion
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.configuration = configuration
        self.summary = summary
        self.scorecard = scorecard
        self.metrics = metrics
        self.command = command
        self.process = process
        self.artifacts = artifacts
        self.sourceRevision = sourceRevision
    }

    public var durationSeconds: Double { finishedAt.timeIntervalSince(startedAt) }
}

public struct LabMetricDelta: Codable, Equatable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let baseline: Double
    public let candidate: Double
    public let delta: Double
    public let percentChange: Double?
    public let unit: String
}

public struct LabRunComparison: Codable, Equatable, Sendable {
    public let baselineID: UUID
    public let candidateID: UUID
    public let scoreDelta: Int?
    public let metricDeltas: [LabMetricDelta]
    public let newHardGateFailures: [String]
    public let resolvedHardGateFailures: [String]
}

public enum LabRunnerError: LocalizedError, Equatable {
    case invalidRepository(String)
    case missingInput(String)
    case invalidConfiguration(String)
    case processLaunch(String)
    case reportNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRepository(let path): return "Not a Transcripted repository: \(path)"
        case .missingInput(let detail): return "Missing input: \(detail)"
        case .invalidConfiguration(let detail): return "Invalid configuration: \(detail)"
        case .processLaunch(let detail): return "Could not launch experiment: \(detail)"
        case .reportNotFound(let detail): return "Lab report not found: \(detail)"
        }
    }
}
