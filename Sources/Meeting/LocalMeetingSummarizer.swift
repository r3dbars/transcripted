import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

struct LocalMeetingSummaryResult: Equatable, Sendable {
    let transcriptURL: URL
    let chunkCount: Int
    let profileName: String
    let provider: LocalMeetingSummaryProvider
}

struct LocalMeetingSummarySections: Equatable, Sendable {
    let title: String?
    let summary: String
    let decisions: String
    let actionItems: String
    let openQuestions: String
    let risksOrFollowUps: String
    let accuracyNotes: String
}

enum LocalMeetingSummaryError: LocalizedError, Equatable {
    case emptyTranscript
    case insufficientMemory(availableGB: Int, requiredGB: Int)
    case runtimeUnavailable
    case appleFoundationUnavailable(reason: String)
    case missingBundledRunner
    case transcriptChanged
    case processTimedOut(label: String)
    case processFailed(label: String, exitCode: Int32, detail: String)
    case outputMissing(label: String)

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "This meeting does not have enough transcript text to summarize."
        case .insufficientMemory(let availableGB, let requiredGB):
            return "Gemma 4 12B needs about \(requiredGB)GB of memory. This Mac reports \(availableGB)GB, so Transcripted skipped the local summary to avoid heavy swapping."
        case .runtimeUnavailable:
            return "Transcripted could not find the local MLX runner. Install uv, or set TRANSCRIPTED_UV_PATH to a uv executable."
        case .appleFoundationUnavailable(let reason):
            return reason
        case .missingBundledRunner:
            return "Transcripted could not find the bundled Gemma summary runner."
        case .transcriptChanged:
            return "This meeting changed while the local summary was running. Run the summary again to avoid overwriting newer edits."
        case .processTimedOut:
            return "The local Gemma summary took too long and was stopped."
        case .processFailed(_, _, let detail):
            return detail.isEmpty ? "The local Gemma summary failed." : detail
        case .outputMissing:
            return "The local Gemma runner finished without writing a summary."
        }
    }
}

struct LocalMeetingSummaryRunMetadata: Equatable, Sendable {
    let provider: LocalMeetingSummaryProvider
    let modelID: String
    let runtimePackage: String
    let profileName: String
    let heading: String

    static func gemma(configuration: LocalGemmaSummaryConfiguration) -> LocalMeetingSummaryRunMetadata {
        LocalMeetingSummaryRunMetadata(
            provider: .gemmaMLX,
            modelID: configuration.modelID,
            runtimePackage: configuration.runtimePackage,
            profileName: configuration.profileName,
            heading: "Local Gemma Summary"
        )
    }
}

struct LocalGemmaSummaryConfiguration: Equatable, Sendable {
    let modelID: String
    let runtimePackage: String
    let profileName: String
    let minimumPhysicalMemoryBytes: UInt64
    let chunkCharacterLimit: Int
    let chunkMaxTokens: Int
    let directMaxTokens: Int
    let mergeMaxTokens: Int
    let maxKVSize: Int
    let processTimeoutSeconds: TimeInterval
    let processNiceValue: Int
    let cpuThreadLimit: Int
    let interJobCooldownSeconds: TimeInterval

    static func m1Optimized(physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> LocalGemmaSummaryConfiguration {
        let gib = UInt64(1024 * 1024 * 1024)
        let memoryGB = physicalMemoryBytes / gib

        if memoryGB <= 16 {
            return LocalGemmaSummaryConfiguration(
                modelID: LocalMeetingSummarySetupStatus.defaultModelID,
                runtimePackage: LocalMeetingSummarySetupStatus.defaultRuntimePackage,
                profileName: "m1-low-memory",
                minimumPhysicalMemoryBytes: 12 * gib,
                chunkCharacterLimit: 9_000,
                chunkMaxTokens: 300,
                directMaxTokens: 900,
                mergeMaxTokens: 2_400,
                maxKVSize: 6_144,
                processTimeoutSeconds: 900,
                processNiceValue: 15,
                cpuThreadLimit: 2,
                interJobCooldownSeconds: 4
            )
        }

        return LocalGemmaSummaryConfiguration(
            modelID: LocalMeetingSummarySetupStatus.defaultModelID,
            runtimePackage: LocalMeetingSummarySetupStatus.defaultRuntimePackage,
            profileName: "apple-silicon-balanced",
            minimumPhysicalMemoryBytes: 12 * gib,
            chunkCharacterLimit: 18_000,
            chunkMaxTokens: 520,
            directMaxTokens: 1_000,
            mergeMaxTokens: 2_400,
            maxKVSize: 8_192,
            processTimeoutSeconds: 900,
            processNiceValue: 10,
            cpuThreadLimit: 4,
            interJobCooldownSeconds: 2
        )
    }

    func validateHardware(physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) throws {
        guard physicalMemoryBytes >= minimumPhysicalMemoryBytes else {
            let gib = UInt64(1024 * 1024 * 1024)
            let availableGB = Int((physicalMemoryBytes + gib - 1) / gib)
            let requiredGB = Int((minimumPhysicalMemoryBytes + gib - 1) / gib)
            throw LocalMeetingSummaryError.insufficientMemory(
                availableGB: availableGB,
                requiredGB: requiredGB
            )
        }
    }
}

struct LocalMeetingSummarySetupStatus: Equatable, Sendable {
    static let defaultModelID = "mlx-community/gemma-4-12B-it-4bit"
    static let defaultRuntimePackage = "mlx-vlm==0.6.1"

    let modelID: String
    let runtimePackage: String
    let profileName: String
    let physicalMemoryGB: Int
    let minimumMemoryGB: Int
    let hasEnoughMemory: Bool
    let uvPath: String?

    var hasRuntime: Bool { uvPath != nil }
    var isReady: Bool { hasEnoughMemory && hasRuntime }

    static func current(
        configuration: LocalGemmaSummaryConfiguration? = nil,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> LocalMeetingSummarySetupStatus {
        let resolvedConfiguration = configuration ?? .m1Optimized(physicalMemoryBytes: physicalMemoryBytes)
        return LocalMeetingSummarySetupStatus(
            modelID: resolvedConfiguration.modelID,
            runtimePackage: resolvedConfiguration.runtimePackage,
            profileName: resolvedConfiguration.profileName,
            physicalMemoryGB: gigabytesRoundedUp(physicalMemoryBytes),
            minimumMemoryGB: gigabytesRoundedUp(resolvedConfiguration.minimumPhysicalMemoryBytes),
            hasEnoughMemory: physicalMemoryBytes >= resolvedConfiguration.minimumPhysicalMemoryBytes,
            uvPath: uvExecutableURL(environment: environment, fileManager: fileManager)?.path
        )
    }

    static func uvExecutableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let candidates = [
            environment["TRANSCRIPTED_UV_PATH"],
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
            environment["HOME"].map { "\($0)/.local/bin/uv" }
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }

        for path in candidates where !path.isEmpty {
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    private static func gigabytesRoundedUp(_ bytes: UInt64) -> Int {
        let gib = UInt64(1024 * 1024 * 1024)
        return Int((bytes + gib - 1) / gib)
    }
}

struct AppleFoundationSummarySetupStatus: Equatable, Sendable {
    let isFrameworkAvailable: Bool
    let isModelAvailable: Bool
    let contextSize: Int
    let unavailableReason: String?

    var isReady: Bool {
        isFrameworkAvailable && isModelAvailable
    }

    var profileName: String {
        guard isFrameworkAvailable else { return "apple-foundation-unavailable" }
        guard contextSize > 0 else { return "apple-foundation-unknown-context" }
        return "apple-foundation-context-\(contextSize)"
    }

    static func current() -> AppleFoundationSummarySetupStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return AppleFoundationSummarySetupStatus(
                    isFrameworkAvailable: true,
                    isModelAvailable: true,
                    contextSize: model.contextSize,
                    unavailableReason: nil
                )
            case .unavailable(.appleIntelligenceNotEnabled):
                return unavailable("Turn on Apple Intelligence in System Settings to use Apple on-device summaries.", contextSize: model.contextSize)
            case .unavailable(.deviceNotEligible):
                return unavailable("This Mac is not eligible for Apple Intelligence on-device summaries.", contextSize: model.contextSize)
            case .unavailable(.modelNotReady):
                return unavailable("Apple's on-device model is still downloading or preparing. Try again when this Mac is idle.", contextSize: model.contextSize)
            case .unavailable:
                return unavailable("Apple's on-device model is unavailable on this Mac right now.", contextSize: model.contextSize)
            @unknown default:
                return unavailable("Apple's on-device model reported an unknown availability state.", contextSize: model.contextSize)
            }
        }
        #endif

        return AppleFoundationSummarySetupStatus(
            isFrameworkAvailable: false,
            isModelAvailable: false,
            contextSize: 0,
            unavailableReason: "Apple Foundation Models are not available in this build."
        )
    }

    private static func unavailable(_ reason: String, contextSize: Int) -> AppleFoundationSummarySetupStatus {
        AppleFoundationSummarySetupStatus(
            isFrameworkAvailable: true,
            isModelAvailable: false,
            contextSize: contextSize,
            unavailableReason: reason
        )
    }
}

struct LocalGemmaSummaryPrompt: Sendable {
    let label: String
    let prompt: String
    let maxTokens: Int
}

enum LocalMeetingSummaryStore {
    static func summaryURL(for transcriptURL: URL) -> URL {
        let base = transcriptURL.deletingPathExtension()
        return base
            .deletingLastPathComponent()
            .appendingPathComponent("\(base.lastPathComponent).summary")
            .appendingPathExtension("md")
    }

    static func summaryExists(for transcriptURL: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: summaryURL(for: transcriptURL).path)
    }

    @discardableResult
    static func removeGeneratedSummary(
        for transcriptURL: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let url = summaryURL(for: transcriptURL)
        guard fileManager.fileExists(atPath: url.path),
              let values = try TranscriptFrontmatter.readValues(from: url),
              values["capture_type"] == "meeting_summary",
              values["source_transcript"] == transcriptURL.lastPathComponent else {
            return false
        }
        try fileManager.removeItem(at: url)
        return true
    }
}

enum LocalMeetingTranscriptExtractor {
    static func transcriptText(from markdown: String) -> String {
        let body = TranscriptFrontmatter.body(in: markdown) ?? markdown
        let lines = body.components(separatedBy: .newlines)
        let headingIndexes = lines.indices.filter { index in
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "## Full Transcript" || trimmed == "## Transcript"
        }

        guard let transcriptIndex = headingIndexes.first else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let startIndex = lines.index(after: transcriptIndex)
        var endIndex = lines.endIndex
        for index in startIndex..<lines.endIndex {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("## ") || trimmed == "---" || trimmed.hasPrefix("*Generated by ") {
                endIndex = index
                break
            }
        }

        return lines[startIndex..<endIndex]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum LocalMeetingSummaryChunker {
    static func turns(from transcript: String) -> [String] {
        splitIntoTurns(transcript)
    }

    static func chunks(from transcript: String, targetCharacterLimit: Int) -> [String] {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return [] }
        guard targetCharacterLimit > 0, trimmedTranscript.count > targetCharacterLimit else {
            return [trimmedTranscript]
        }

        let turns = splitIntoTurns(trimmedTranscript)
        var result: [String] = []
        var current: [String] = []
        var currentCount = 0

        for turn in turns {
            let turnCount = turn.count + 2
            if !current.isEmpty, currentCount + turnCount > targetCharacterLimit {
                result.append(current.joined(separator: "\n\n"))
                current = [turn]
                currentCount = turnCount
            } else {
                current.append(turn)
                currentCount += turnCount
            }
        }

        if !current.isEmpty {
            result.append(current.joined(separator: "\n\n"))
        }

        return result
    }

    private static func splitIntoTurns(_ transcript: String) -> [String] {
        var turns: [String] = []
        var current: [String] = []

        func flush() {
            let text = current
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                turns.append(text)
            }
            current = []
        }

        for rawLine in transcript.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if isTurnBoundary(line), !current.isEmpty {
                flush()
            }
            current.append(line)
        }

        flush()
        return turns.isEmpty ? [transcript] : turns
    }

    private static func isTurnBoundary(_ line: String) -> Bool {
        if line.hasPrefix("**"), line.dropFirst(2).contains("**") {
            let remainder = line.dropFirst(2)
            let time = remainder.prefix { $0 != "*" }
            if looksLikeTimestamp(String(time)) { return true }
        }

        if line.hasPrefix("[") {
            if let end = line.firstIndex(of: "]") {
                let firstBracket = String(line[line.index(after: line.startIndex)..<end])
                if looksLikeTimestamp(firstBracket) { return true }
            }

            let zoomPattern = #"^\[[^\]]+\]\s+\d{1,2}:\d{2}:\d{2}"#
            if line.range(of: zoomPattern, options: .regularExpression) != nil {
                return true
            }
        }

        return false
    }

    private static func looksLikeTimestamp(_ value: String) -> Bool {
        let parts = value.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}

struct LocalGemmaSummaryRuntime: @unchecked Sendable {
    let configuration: LocalGemmaSummaryConfiguration
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var bundle: Bundle = .main
    var fileManager: FileManager = .default
    var runnerURLOverride: URL?
    var generateBatchOverride: (@Sendable ([LocalGemmaSummaryPrompt], URL) throws -> [String])?

    func generate(prompt: String, label: String, maxTokens: Int, workDirectory: URL) throws -> String {
        let outputs = try generateBatch(
            [LocalGemmaSummaryPrompt(label: label, prompt: prompt, maxTokens: maxTokens)],
            workDirectory: workDirectory
        )
        guard let output = outputs.first else {
            throw LocalMeetingSummaryError.outputMissing(label: label)
        }
        return output
    }

    func generateBatch(_ prompts: [LocalGemmaSummaryPrompt], workDirectory: URL) throws -> [String] {
        guard !prompts.isEmpty else { return [] }
        try Task.checkCancellation()
        if let generateBatchOverride {
            let outputs = try generateBatchOverride(prompts, workDirectory)
            try Task.checkCancellation()
            return outputs
        }
        guard let runnerURL = runnerURL() else {
            throw LocalMeetingSummaryError.missingBundledRunner
        }
        guard let uvURL = uvExecutableURL() else {
            throw LocalMeetingSummaryError.runtimeUnavailable
        }

        let jobs = try prompts.enumerated().map { index, prompt in
            let safeLabel = "\(index + 1)-\(fileSafeLabel(prompt.label))"
            let promptURL = workDirectory.appendingPathComponent("\(safeLabel)-prompt.txt")
            let outputURL = workDirectory.appendingPathComponent("\(safeLabel)-output.md")
            let metricsURL = workDirectory.appendingPathComponent("\(safeLabel)-metrics.json")
            try prompt.prompt.write(to: promptURL, atomically: true, encoding: .utf8)
            fileManager.restrictFileToOwnerOnly(at: promptURL)
            return (
                label: prompt.label,
                outputURL: outputURL,
                record: [
                    "label": prompt.label,
                    "prompt_file": promptURL.path,
                    "output_file": outputURL.path,
                    "metrics_file": metricsURL.path,
                    "max_tokens": prompt.maxTokens
                ] as [String: Any]
            )
        }

        let jobsURL = workDirectory.appendingPathComponent("jobs.json")
        let jobsData = try JSONSerialization.data(
            withJSONObject: jobs.map { $0.record },
            options: [.prettyPrinted]
        )
        try jobsData.write(to: jobsURL, options: [.atomic])
        fileManager.restrictFileToOwnerOnly(at: jobsURL)

        let process = Process()
        let batchLabel = prompts.map { $0.label }.joined(separator: ", ")
        let uvArguments = [
            "run",
            "--with",
            configuration.runtimePackage,
            "python",
            runnerURL.path,
            "--jobs-file", jobsURL.path,
            "--model", configuration.modelID,
            "--max-kv-size", "\(configuration.maxKVSize)",
            "--cooldown-seconds", "\(configuration.interJobCooldownSeconds)"
        ]
        if configuration.processNiceValue > 0 {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
            process.arguments = [
                "-n", "\(min(configuration.processNiceValue, 20))",
                uvURL.path
            ] + uvArguments
        } else {
            process.executableURL = uvURL
            process.arguments = uvArguments
        }

        let threadLimit = "\(max(1, configuration.cpuThreadLimit))"
        process.environment = sanitizedProcessEnvironment(threadLimit: threadLimit)

        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw LocalMeetingSummaryError.processFailed(
                label: batchLabel,
                exitCode: -1,
                detail: error.localizedDescription
            )
        }

        let startedAt = Date()
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            if Date().timeIntervalSince(startedAt) > configuration.processTimeoutSeconds {
                process.terminate()
                throw LocalMeetingSummaryError.processTimedOut(label: batchLabel)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw LocalMeetingSummaryError.processFailed(
                label: batchLabel,
                exitCode: process.terminationStatus,
                detail: Self.sanitizedRuntimeDetail(stderrText)
            )
        }

        return try jobs.map { job in
            guard fileManager.fileExists(atPath: job.outputURL.path),
                  let output = try? String(contentsOf: job.outputURL, encoding: .utf8),
                  !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalMeetingSummaryError.outputMissing(label: job.label)
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func runnerURL() -> URL? {
        if let runnerURLOverride {
            return runnerURLOverride
        }
        return bundle.url(
            forResource: "gemma4_mlx_prompt_runner",
            withExtension: "py",
            subdirectory: "LocalSummarizer"
        )
    }

    private func uvExecutableURL() -> URL? {
        LocalMeetingSummarySetupStatus.uvExecutableURL(
            environment: environment,
            fileManager: fileManager
        )
    }

    func sanitizedProcessEnvironment(threadLimit: String) -> [String: String] {
        let allowedParentKeys = [
            "PATH",
            "HOME",
            "TMPDIR",
            "TEMP",
            "TMP",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "XDG_CACHE_HOME",
            "HF_HOME",
            "HF_HUB_CACHE",
            "TRANSFORMERS_CACHE",
            "UV_CACHE_DIR",
        ]
        var sanitized: [String: String] = [:]
        for key in allowedParentKeys {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                sanitized[key] = value
            }
        }
        sanitized["HF_HUB_DISABLE_TELEMETRY"] = "1"
        sanitized["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        sanitized["TOKENIZERS_PARALLELISM"] = "false"
        sanitized["PYTHONUNBUFFERED"] = "1"
        sanitized["UV_NO_PROGRESS"] = "1"
        sanitized["NO_COLOR"] = "1"
        sanitized["OMP_NUM_THREADS"] = threadLimit
        sanitized["OPENBLAS_NUM_THREADS"] = threadLimit
        sanitized["VECLIB_MAXIMUM_THREADS"] = threadLimit
        sanitized["NUMEXPR_NUM_THREADS"] = threadLimit
        return sanitized
    }

    private func fileSafeLabel(_ label: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = label.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let safe = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return safe.isEmpty ? "prompt" : String(safe.prefix(48))
    }

    private static func sanitizedRuntimeDetail(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lines = trimmed.components(separatedBy: .newlines)
            .filter { !$0.contains("-prompt.txt") && !$0.contains("prompt_file") && !$0.contains("jobs.json") }
            .suffix(8)
        return lines.joined(separator: "\n")
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct AppleFoundationMeetingSummaryContent {
    @Guide(description: "A specific plain meeting title, 3 to 8 words.")
    var title: String

    @Guide(description: "Only transcript-supported summary bullets.", .maximumCount(6))
    var summary: [String]

    @Guide(description: "Only explicit decisions from the transcript.", .maximumCount(8))
    var decisions: [String]

    @Guide(description: "Only unfinished future follow-up work after the meeting.", .maximumCount(8))
    var actionItems: [String]

    @Guide(description: "Only unresolved questions from the transcript.", .maximumCount(8))
    var openQuestions: [String]

    @Guide(description: "Risks, blockers, or follow-ups supported by the transcript.", .maximumCount(8))
    var risksOrFollowUps: [String]

    @Guide(description: "Uncertainty and accuracy notes.", .maximumCount(4))
    var accuracyNotes: [String]

    var markdown: String {
        """
        # Title
        \(clean(title, fallback: "Meeting Summary"))

        # Summary
        \(render(summary))

        # Decisions
        \(render(decisions))

        # Action Items
        \(render(actionItems))

        # Open Questions
        \(render(openQuestions))

        # Risks or Follow-ups
        \(render(risksOrFollowUps))

        # Accuracy Notes
        \(render(accuracyNotes))
        """
    }

    private func render(_ values: [String]) -> String {
        let cleaned = values
            .map { clean($0, fallback: "") }
            .filter { !$0.isEmpty && $0.localizedCaseInsensitiveCompare("none found") != .orderedSame }
        guard !cleaned.isEmpty else { return "None found." }
        return cleaned.map { "- \($0)" }.joined(separator: "\n")
    }

    private func clean(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
#endif

struct AppleFoundationSummaryRuntime: Sendable {
    let setupStatus: AppleFoundationSummarySetupStatus
    let reservedResponseTokens: Int
    let chunkMaxTokens: Int
    let directMaxTokens: Int
    let mergeMaxTokens: Int

    init(
        setupStatus: AppleFoundationSummarySetupStatus = .current(),
        reservedResponseTokens: Int = 700,
        chunkMaxTokens: Int = 420,
        directMaxTokens: Int = 900,
        mergeMaxTokens: Int = 1_000
    ) {
        self.setupStatus = setupStatus
        self.reservedResponseTokens = reservedResponseTokens
        self.chunkMaxTokens = chunkMaxTokens
        self.directMaxTokens = directMaxTokens
        self.mergeMaxTokens = mergeMaxTokens
    }

    var metadata: LocalMeetingSummaryRunMetadata {
        LocalMeetingSummaryRunMetadata(
            provider: .appleFoundation,
            modelID: "com.apple.foundationmodels.system.default",
            runtimePackage: "FoundationModels.framework",
            profileName: setupStatus.profileName,
            heading: "Local Apple Summary"
        )
    }

    func generate(prompt: String, maxTokens: Int) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.isAvailable else {
                throw LocalMeetingSummaryError.appleFoundationUnavailable(
                    reason: AppleFoundationSummarySetupStatus.current().unavailableReason
                        ?? "Apple's on-device model is unavailable on this Mac right now."
                )
            }

            let session = LanguageModelSession(
                model: model,
                instructions: """
                You summarize Transcripted meeting transcripts accurately.
                Use only the supplied transcript or chunk notes.
                Do not invent decisions, action items, questions, people, dates, or facts.
                If a field has no direct support, leave it empty.
                """
            )
            let response = try await session.respond(
                to: prompt,
                generating: AppleFoundationMeetingSummaryContent.self,
                options: GenerationOptions(
                    temperature: 0.0,
                    maximumResponseTokens: maxTokens
                )
            )
            return response.content.markdown
        }
        #endif

        throw LocalMeetingSummaryError.appleFoundationUnavailable(
            reason: "Apple Foundation Models are not available in this build."
        )
    }

    func chunks(for transcript: String, title: String) async throws -> [String] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.isAvailable else {
                throw LocalMeetingSummaryError.appleFoundationUnavailable(
                    reason: AppleFoundationSummarySetupStatus.current().unavailableReason
                        ?? "Apple's on-device model is unavailable on this Mac right now."
                )
            }

            let turns = LocalMeetingSummaryChunker.turns(from: transcript)
            let safePromptBudget = max(900, model.contextSize - reservedResponseTokens - 250)
            var chunks: [String] = []
            var current: [String] = []

            for turn in turns {
                try Task.checkCancellation()
                let candidate = (current + [turn]).joined(separator: "\n\n")
                let prompt = LocalMeetingSummaryPrompts.chunk(
                    title: title,
                    chunk: candidate,
                    index: max(1, chunks.count + 1),
                    total: 999,
                    runtimeName: "Apple on-device Foundation Models"
                )
                let tokenCount: Int
                if #available(macOS 26.4, *) {
                    tokenCount = (try? await model.tokenCount(for: prompt)) ?? Int(Double(candidate.count) / 3.6)
                } else {
                    tokenCount = Int(Double(candidate.count) / 3.6)
                }
                if !current.isEmpty, tokenCount > safePromptBudget {
                    chunks.append(current.joined(separator: "\n\n"))
                    current = [turn]
                } else {
                    current.append(turn)
                }
            }

            if !current.isEmpty {
                chunks.append(current.joined(separator: "\n\n"))
            }
            return chunks.isEmpty ? [transcript] : chunks
        }
        #endif

        throw LocalMeetingSummaryError.appleFoundationUnavailable(
            reason: "Apple Foundation Models are not available in this build."
        )
    }
}

struct LocalMeetingSummarizer: @unchecked Sendable {
    let configuration: LocalGemmaSummaryConfiguration
    var runtime: LocalGemmaSummaryRuntime
    var fileManager: FileManager = .default

    init(
        configuration: LocalGemmaSummaryConfiguration = .m1Optimized(),
        runtime: LocalGemmaSummaryRuntime? = nil
    ) {
        self.configuration = configuration
        self.runtime = runtime ?? LocalGemmaSummaryRuntime(configuration: configuration)
    }

    func summarize(transcriptURL: URL, title: String, date: Date = Date()) async throws -> LocalMeetingSummaryResult {
        try configuration.validateHardware()
        try Task.checkCancellation()

        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        try Task.checkCancellation()

        let transcript = LocalMeetingTranscriptExtractor.transcriptText(from: markdown)
        guard transcript.split(whereSeparator: \.isWhitespace).count >= 40 else {
            throw LocalMeetingSummaryError.emptyTranscript
        }

        let chunks = LocalMeetingSummaryChunker.chunks(
            from: transcript,
            targetCharacterLimit: configuration.chunkCharacterLimit
        )
        let workDirectory = try makeWorkDirectory()
        defer { try? fileManager.removeItem(at: workDirectory) }

        let summaryBody: String
        if chunks.count == 1 {
            try Task.checkCancellation()
            summaryBody = try runtime.generate(
                prompt: LocalMeetingSummaryPrompts.direct(
                    title: title,
                    transcript: chunks[0],
                    runtimeName: "Gemma 4 12B"
                ),
                label: "direct",
                maxTokens: configuration.directMaxTokens,
                workDirectory: workDirectory
            )
        } else {
            let chunkPrompts = chunks.enumerated().map { index, chunk in
                LocalGemmaSummaryPrompt(
                    label: "chunk-\(index + 1)",
                    prompt: LocalMeetingSummaryPrompts.chunk(
                        title: title,
                        chunk: chunk,
                        index: index + 1,
                        total: chunks.count,
                        runtimeName: "Gemma 4 12B"
                    ),
                    maxTokens: configuration.chunkMaxTokens
                )
            }

            try Task.checkCancellation()
            let chunkOutputs = try runtime.generateBatch(
                chunkPrompts,
                workDirectory: workDirectory
            )
            var chunkNotes: [String] = []
            for (index, note) in chunkOutputs.enumerated() {
                try Task.checkCancellation()
                chunkNotes.append("# Chunk \(index + 1)\n\n\(note)")
            }

            try Task.checkCancellation()
            summaryBody = try runtime.generate(
                prompt: LocalMeetingSummaryPrompts.merge(
                    title: title,
                    notes: chunkNotes.joined(separator: "\n\n---\n\n"),
                    runtimeName: "Gemma 4 12B"
                ),
                label: "merge",
                maxTokens: configuration.mergeMaxTokens,
                workDirectory: workDirectory
            )
        }

        try Task.checkCancellation()
        let normalizedBody = LocalMeetingSummaryNormalizer.normalized(summaryBody)
        let sections = LocalMeetingSummaryNormalizer.sections(in: normalizedBody)
        let latestMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        let latestTranscript = LocalMeetingTranscriptExtractor.transcriptText(from: latestMarkdown)
        guard latestTranscript == transcript else {
            throw LocalMeetingSummaryError.transcriptChanged
        }
        let updatedMarkdown = LocalMeetingSummaryMarkdownUpdater.markdown(
            byApplying: sections,
            to: latestMarkdown,
            metadata: .gemma(configuration: configuration),
            generatedAt: date,
            chunkCount: chunks.count
        )

        try Task.checkCancellation()
        try updatedMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
        fileManager.restrictFileToOwnerOnly(at: transcriptURL)

        return LocalMeetingSummaryResult(
            transcriptURL: transcriptURL,
            chunkCount: chunks.count,
            profileName: configuration.profileName,
            provider: .gemmaMLX
        )
    }

    func prepareModelForFirstSummary() async throws -> String {
        try configuration.validateHardware()
        try Task.checkCancellation()

        let workDirectory = try makeWorkDirectory()
        defer { try? fileManager.removeItem(at: workDirectory) }

        _ = try runtime.generate(
            prompt: """
            You are Transcripted's local meeting summarizer. Reply with exactly:
            Ready.
            """,
            label: "setup",
            maxTokens: 8,
            workDirectory: workDirectory
        )

        return configuration.profileName
    }

    private func makeWorkDirectory() throws -> URL {
        let root = FileManager.default.transcriptedTemporaryDir
            .appendingPathComponent("local-summaries", isDirectory: true)
        fileManager.ensurePrivateDirectory(at: root, context: "Transcripted local summaries")
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createPrivateDirectory(at: directory)
        return directory
    }

}

struct AppleFoundationMeetingSummarizer: @unchecked Sendable {
    var runtime = AppleFoundationSummaryRuntime()
    var fileManager: FileManager = .default

    func summarize(transcriptURL: URL, title: String, date: Date = Date()) async throws -> LocalMeetingSummaryResult {
        try Task.checkCancellation()
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        let transcript = LocalMeetingTranscriptExtractor.transcriptText(from: markdown)
        guard transcript.split(whereSeparator: \.isWhitespace).count >= 40 else {
            throw LocalMeetingSummaryError.emptyTranscript
        }

        let chunks = try await runtime.chunks(for: transcript, title: title)
        let summaryBody: String
        if chunks.count == 1 {
            summaryBody = try await runtime.generate(
                prompt: LocalMeetingSummaryPrompts.direct(
                    title: title,
                    transcript: chunks[0],
                    runtimeName: "Apple on-device Foundation Models"
                ),
                maxTokens: runtime.directMaxTokens
            )
        } else {
            var chunkNotes: [String] = []
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                let output = try await runtime.generate(
                    prompt: LocalMeetingSummaryPrompts.chunk(
                        title: title,
                        chunk: chunk,
                        index: index + 1,
                        total: chunks.count,
                        runtimeName: "Apple on-device Foundation Models"
                    ),
                    maxTokens: runtime.chunkMaxTokens
                )
                chunkNotes.append("# Chunk \(index + 1)\n\n\(output)")
            }
            summaryBody = try await runtime.generate(
                prompt: LocalMeetingSummaryPrompts.merge(
                    title: title,
                    notes: chunkNotes.joined(separator: "\n\n---\n\n"),
                    runtimeName: "Apple on-device Foundation Models"
                ),
                maxTokens: runtime.mergeMaxTokens
            )
        }

        try Task.checkCancellation()
        let normalizedBody = LocalMeetingSummaryNormalizer.normalized(summaryBody)
        let sections = LocalMeetingSummaryNormalizer.sections(in: normalizedBody)
        let latestMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        let latestTranscript = LocalMeetingTranscriptExtractor.transcriptText(from: latestMarkdown)
        guard latestTranscript == transcript else {
            throw LocalMeetingSummaryError.transcriptChanged
        }
        let updatedMarkdown = LocalMeetingSummaryMarkdownUpdater.markdown(
            byApplying: sections,
            to: latestMarkdown,
            metadata: runtime.metadata,
            generatedAt: date,
            chunkCount: chunks.count
        )
        try updatedMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
        fileManager.restrictFileToOwnerOnly(at: transcriptURL)

        return LocalMeetingSummaryResult(
            transcriptURL: transcriptURL,
            chunkCount: chunks.count,
            profileName: runtime.metadata.profileName,
            provider: .appleFoundation
        )
    }

    func prepareModelForFirstSummary() async throws -> String {
        _ = try await runtime.generate(
            prompt: """
            You are Transcripted's Apple on-device meeting summarizer. Reply with title Ready and one summary bullet saying Ready.
            """,
            maxTokens: 80
        )
        return runtime.metadata.profileName
    }
}

enum LocalMeetingSummaryPrompts {
    static func direct(title: String, transcript: String, runtimeName: String) -> String {
        """
        You are Transcripted's local meeting summarizer. You are running fully on-device with \(runtimeName).

        Summarize "\(title)" accurately. Do not invent decisions, tasks, dates, names, or facts. If something is unclear, write unclear.

        Return markdown with exactly these sections:
        # Title
        # Summary
        # Decisions
        # Action Items
        # Open Questions
        # Risks or Follow-ups
        # Accuracy Notes

        Rules:
        - Always include every section heading exactly as listed, even when the section says "None found."
        - Base every point only on the transcript.
        - Title must be specific, plain, and 3 to 8 words.
        - Keep it concise and useful.
        - Use compact one-line bullets. Do not use sub-bullets, long explanations, or repeated qualifiers.
        - Include timestamps when available.
        - Decisions include explicit choices, selections, agreed settings, approvals, or commitments from the transcript.
        - Action Items are only future follow-up work after the meeting, not instructions already completed during the transcript.
        - Do not list one-off navigation, roleplay, game, or setup instructions as Action Items unless the transcript leaves them as unfinished follow-up work.
        - Put brainstorms, proposals, or maybes in Open Questions or Risks unless the transcript clearly says they were decided.
        - If a section has nothing supported, write "None found."

        Transcript:
        \(transcript)
        """
    }

    static func chunk(title: String, chunk: String, index: Int, total: Int, runtimeName: String) -> String {
        """
        You are Transcripted's local meeting-note extractor. You are running fully on-device with \(runtimeName). This is chunk \(index) of \(total) from "\(title)".

        Extract only facts supported by this chunk. Do not invent.

        Return markdown with these exact headings:
        ## Chunk Summary
        ## Decisions
        ## Action Items
        ## Open Questions
        ## Risks or Follow-ups

        Rules:
        - Always include every section heading exactly as listed, even when the section says "None found."
        - Preserve every explicit decision, action item, open question, and follow-up from this chunk.
        - Use compact one-line bullets. Do not use sub-bullets or long explanations.
        - Include timestamps and speakers when available, especially for action items and decisions.
        - Decisions include explicit choices, selections, agreed settings, approvals, or commitments from this chunk.
        - Action Items are only future follow-up work after the meeting, not in-call setup steps or instructions already completed during the transcript.
        - Do not list one-off navigation, roleplay, game, or setup instructions as Action Items unless the chunk leaves them as unfinished follow-up work.
        - Keep brainstorms, proposals, or maybes out of Decisions unless the chunk clearly says they were decided.
        - If a heading has nothing supported, write "None found."

        Chunk transcript:
        \(chunk)
        """
    }

    static func merge(title: String, notes: String, runtimeName: String) -> String {
        """
        You are Transcripted's local meeting summarizer. You are running fully on-device with \(runtimeName). Merge these chunk notes for "\(title)" into one accurate meeting summary.

        Do not invent decisions, tasks, dates, names, or facts.

        Return markdown with exactly these sections:
        # Title
        # Summary
        # Decisions
        # Action Items
        # Open Questions
        # Risks or Follow-ups
        # Accuracy Notes

        Rules:
        - Always include every section heading exactly as listed, even when the section says "None found."
        - Base every point only on the chunk notes.
        - Title must be specific, plain, and 3 to 8 words.
        - Keep each section concise.
        - Use compact one-line bullets. Do not use sub-bullets, long explanations, or repeated qualifiers.
        - Include timestamps when available.
        - Preserve explicit action items, decisions, open questions, and follow-ups from the chunk notes.
        - Decisions include explicit choices, selections, agreed settings, approvals, or commitments from the chunk notes.
        - Action Items are only future follow-up work after the meeting, not in-call setup steps or instructions already completed during the transcript.
        - Do not list one-off navigation, roleplay, game, or setup instructions as Action Items unless the notes leave them as unfinished follow-up work.
        - Remove duplicates only when the same owner, same task or decision, and same topic are repeated.
        - Never promote brainstorms, proposals, or unresolved questions into Decisions.
        - If a section has nothing supported, write "None found."

        Chunk notes:
        \(notes)
        """
    }
}

enum LocalMeetingSummaryNormalizer {
    private static let requiredSections = [
        "# Title",
        "# Summary",
        "# Decisions",
        "# Action Items",
        "# Open Questions",
        "# Risks or Follow-ups",
        "# Accuracy Notes"
    ]

    static func normalized(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = "# Summary\nNone found."
        }

        for section in requiredSections where !containsHeading(section, in: text) {
            text += "\n\n\(section)\nNone found."
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sections(in raw: String) -> LocalMeetingSummarySections {
        let text = normalized(raw)
        return LocalMeetingSummarySections(
            title: summaryTitle(in: text),
            summary: section("# Summary", in: text) ?? "None found.",
            decisions: section("# Decisions", in: text) ?? "None found.",
            actionItems: section("# Action Items", in: text) ?? "None found.",
            openQuestions: section("# Open Questions", in: text) ?? "None found.",
            risksOrFollowUps: section("# Risks or Follow-ups", in: text) ?? "None found.",
            accuracyNotes: section("# Accuracy Notes", in: text) ?? "None found."
        )
    }

    static func summaryTitle(in raw: String) -> String? {
        let explicitTitle = section("# Title", in: raw)?
            .components(separatedBy: .newlines)
            .first
            .map(cleanSectionText)
            .flatMap { isStructuralGeneratedTitle($0) ? nil : String($0.prefix(96)) }
        return explicitTitle ?? firstGeneratedTitleHeading(in: raw)
    }

    static func section(_ heading: String, in raw: String) -> String? {
        let lines = raw.components(separatedBy: .newlines)
        guard let startIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == heading
        }) else {
            return nil
        }

        var endIndex = lines.endIndex
        for index in lines.index(after: startIndex)..<lines.endIndex {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") {
                endIndex = index
                break
            }
        }

        return cleanSectionText(
            lines[lines.index(after: startIndex)..<endIndex]
                .joined(separator: "\n")
        )
    }

    private static func containsHeading(_ heading: String, in text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines) == heading
        }
    }

    private static func firstGeneratedTitleHeading(in raw: String) -> String? {
        raw.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("# "), !requiredSections.contains(trimmed) else {
                return nil
            }
            let title = cleanSectionText(String(trimmed.dropFirst(2)))
            return isStructuralGeneratedTitle(title) ? nil : String(title.prefix(96))
        }.first
    }

    private static func isStructuralGeneratedTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        if normalized.isEmpty || normalized == "none found." {
            return true
        }
        if normalized == "title" || normalized == "summary" {
            return true
        }
        if normalized.hasPrefix("chunk ") {
            let suffix = normalized.dropFirst("chunk ".count)
            return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber }
        }
        return false
    }

    private static func cleanSectionText(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "None found." : text
    }
}

enum LocalMeetingSummaryMarkdownUpdater {
    static let startMarker = "<!-- transcripted:local-summary:start v=1 -->"
    static let endMarker = "<!-- transcripted:local-summary:end -->"

    private static let managedFrontmatterKeys: Set<String> = [
        "local_summary_version",
        "local_summary_title",
        "local_summary_generated_at",
        "local_summary_provider",
        "local_summary_model",
        "local_summary_runtime",
        "local_summary_profile",
        "local_summary_chunk_count",
        "local_summary",
        "local_summary_decisions",
        "local_summary_action_items",
        "local_summary_open_questions",
        "local_summary_risks_or_followups",
        "local_summary_accuracy_notes"
    ]

    static func markdown(
        byApplying sections: LocalMeetingSummarySections,
        to markdown: String,
        configuration: LocalGemmaSummaryConfiguration,
        generatedAt: Date,
        chunkCount: Int
    ) -> String {
        self.markdown(
            byApplying: sections,
            to: markdown,
            metadata: .gemma(configuration: configuration),
            generatedAt: generatedAt,
            chunkCount: chunkCount
        )
    }

    static func markdown(
        byApplying sections: LocalMeetingSummarySections,
        to markdown: String,
        metadata: LocalMeetingSummaryRunMetadata,
        generatedAt: Date,
        chunkCount: Int
    ) -> String {
        let document = TranscriptFrontmatter.document(in: markdown)
        let body = document?.body ?? markdown
        let frontmatterLines = updatedFrontmatterLines(
            existing: document?.lines ?? [],
            sections: sections,
            metadata: metadata,
            generatedAt: generatedAt,
            chunkCount: chunkCount
        )
        let updatedBody = removingLocalSummaryBlock(from: body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let renderedBody = [updatedBody, renderedLocalSummarySection(sections, metadata: metadata)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        return """
        ---
        \(frontmatterLines.joined(separator: "\n"))
        ---

        \(renderedBody)
        """
    }

    private static func updatedFrontmatterLines(
        existing: [String],
        sections: LocalMeetingSummarySections,
        metadata: LocalMeetingSummaryRunMetadata,
        generatedAt: Date,
        chunkCount: Int
    ) -> [String] {
        let retained = existing.filter { line in
            guard let key = frontmatterKey(in: line) else { return true }
            return !managedFrontmatterKeys.contains(key)
        }
        let generatedAtString = ISO8601DateFormatter().string(from: generatedAt)
        return retained + [
            "local_summary_version: \"1\"",
            yamlLine("local_summary_title", sections.title ?? ""),
            "local_summary_generated_at: \"\(generatedAtString)\"",
            yamlLine("local_summary_provider", metadata.provider.rawValue),
            yamlLine("local_summary_model", metadata.modelID),
            yamlLine("local_summary_runtime", metadata.runtimePackage),
            yamlLine("local_summary_profile", metadata.profileName),
            "local_summary_chunk_count: \"\(chunkCount)\"",
            yamlLine("local_summary", frontmatterSummaryValue(sections.summary)),
            yamlLine("local_summary_decisions", frontmatterSummaryValue(sections.decisions)),
            yamlLine("local_summary_action_items", frontmatterSummaryValue(sections.actionItems)),
            yamlLine("local_summary_open_questions", frontmatterSummaryValue(sections.openQuestions)),
            yamlLine("local_summary_risks_or_followups", frontmatterSummaryValue(sections.risksOrFollowUps)),
            yamlLine("local_summary_accuracy_notes", frontmatterSummaryValue(sections.accuracyNotes))
        ]
    }

    private static func renderedLocalSummarySection(
        _ sections: LocalMeetingSummarySections,
        metadata: LocalMeetingSummaryRunMetadata
    ) -> String {
        """
        \(startMarker)
        ## \(metadata.heading)

        ### Summary
        \(sections.summary)

        ### Decisions
        \(sections.decisions)

        ### Action Items
        \(sections.actionItems)

        ### Open Questions
        \(sections.openQuestions)

        ### Risks or Follow-ups
        \(sections.risksOrFollowUps)

        ### Accuracy Notes
        \(sections.accuracyNotes)
        \(endMarker)
        """
    }

    static func localSummaryBlock(in body: String) -> String? {
        guard let startRange = body.range(of: startMarker),
              let endRange = body.range(
                of: endMarker,
                range: startRange.upperBound..<body.endIndex
              ) else {
            return nil
        }
        return String(body[startRange.lowerBound..<endRange.upperBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removingLocalSummaryBlock(from body: String) -> String {
        guard let startRange = body.range(of: startMarker),
              let endRange = body.range(
                of: endMarker,
                range: startRange.upperBound..<body.endIndex
              ) else {
            return bodyWithoutLegacyLocalSummarySection(body)
        }

        var updated = body
        updated.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        return updated
    }

    private static func bodyWithoutLegacyLocalSummarySection(_ body: String) -> String {
        var lines = body.components(separatedBy: .newlines)
        guard let startIndex = lines.firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "## Local Summary"
                || trimmed == "## Local Gemma Summary"
                || trimmed == "## Local Apple Summary"
        }) else {
            return body
        }

        var endIndex = lines.endIndex
        for index in lines.index(after: startIndex)..<lines.endIndex {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("## "),
               trimmed != "## Local Summary",
               trimmed != "## Local Gemma Summary",
               trimmed != "## Local Apple Summary" {
                endIndex = index
                break
            }
        }

        lines.removeSubrange(startIndex..<endIndex)
        return lines.joined(separator: "\n")
    }

    static func removingLocalSummaryMarkers(from body: String) -> String {
        body.replacingOccurrences(of: startMarker, with: "")
            .replacingOccurrences(of: endMarker, with: "")
    }

    private static func frontmatterKey(in line: String) -> String? {
        guard line.first?.isWhitespace != true else { return nil }
        return line.split(separator: ":", maxSplits: 1).first.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func yamlLine(_ key: String, _ value: String) -> String {
        "\(key): \"\(yamlValue(value))\""
    }

    private static func yamlValue(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func frontmatterSummaryValue(_ raw: String) -> String {
        let flattened = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        return String(flattened.prefix(1_200))
    }
}
