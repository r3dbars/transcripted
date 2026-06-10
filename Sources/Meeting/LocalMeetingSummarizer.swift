import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

struct LocalMeetingSummaryResult: Equatable, Sendable {
    let transcriptURL: URL
    let chunkCount: Int
    let profileName: String
}

struct LocalMeetingSummarySections: Equatable, Sendable {
    let title: String?
    let participants: String
    let summary: String
    let decisions: String
    let actionItems: String
    let openQuestions: String
    let risksOrFollowUps: String
    let accuracyNotes: String

    func withParticipants(_ participants: String) -> LocalMeetingSummarySections {
        LocalMeetingSummarySections(
            title: title,
            participants: participants,
            summary: summary,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions,
            risksOrFollowUps: risksOrFollowUps,
            accuracyNotes: accuracyNotes
        )
    }
}

enum LocalMeetingSummaryError: LocalizedError, Equatable {
    case emptyTranscript
    case insufficientMemory(availableGB: Int, requiredGB: Int)
    case runtimeUnavailable
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
                directMaxTokens: 360,
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

enum LocalMeetingSummaryParticipantExtractor {
    static func participants(from transcript: String) -> String {
        var names: [String] = []
        var seen = Set<String>()

        for rawLine in transcript.components(separatedBy: .newlines) {
            guard let label = speakerLabel(from: rawLine),
                  let name = normalizedParticipantName(label) else {
                continue
            }
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            names.append(name)
        }

        guard !names.isEmpty else { return "None found." }
        return names.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func speakerLabel(from rawLine: String) -> String? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        if line.hasPrefix("**") {
            let timestampStart = line.index(line.startIndex, offsetBy: 2)
            guard let timestampEnd = line[timestampStart...].range(of: "**")?.lowerBound else {
                return nil
            }
            let timestamp = String(line[timestampStart..<timestampEnd])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !looksLikeTimestamp(timestamp) {
                return speakerLabel(from: timestamp)
            }
            let remainderStart = line.index(timestampEnd, offsetBy: 2)
            return firstBracketValue(in: String(line[remainderStart...]))
        }

        if line.hasPrefix("["),
           let firstEnd = line.firstIndex(of: "]") {
            let firstValue = String(line[line.index(after: line.startIndex)..<firstEnd])
            let remainder = String(line[line.index(after: firstEnd)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if looksLikeTimestamp(firstValue) {
                return firstBracketValue(in: remainder)
            }

            if startsWithTimestamp(remainder) {
                return firstValue
            }

            if firstValue.contains("/") {
                return firstValue
            }
        }

        return nil
    }

    private static func firstBracketValue(in raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("["),
              let end = text.firstIndex(of: "]") else {
            return nil
        }
        return String(text[text.index(after: text.startIndex)..<end])
    }

    private static func normalizedParticipantName(_ raw: String) -> String? {
        let unwrapped = raw
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let channelStripped = unwrapped.split(separator: "/", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? unwrapped
        let name = channelStripped
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard !name.isEmpty,
              !looksLikeTimestamp(name),
              !isPlaceholderParticipantName(name) else {
            return nil
        }
        return String(name.prefix(96))
    }

    private static func isPlaceholderParticipantName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        if normalized == "remote" || normalized == "unknown" || normalized == "unknown speaker" {
            return true
        }
        if normalized == "speaker" {
            return true
        }
        if normalized.hasPrefix("speaker ") {
            let suffix = normalized.dropFirst("speaker ".count)
            return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber }
        }
        return false
    }

    private static func startsWithTimestamp(_ value: String) -> Bool {
        let first = value.split(separator: " ", maxSplits: 1).first.map(String.init) ?? value
        return looksLikeTimestamp(first)
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
                prompt: directPrompt(title: title, transcript: chunks[0]),
                label: "direct",
                maxTokens: configuration.directMaxTokens,
                workDirectory: workDirectory
            )
        } else {
            let chunkPrompts = chunks.enumerated().map { index, chunk in
                LocalGemmaSummaryPrompt(
                    label: "chunk-\(index + 1)",
                    prompt: chunkPrompt(
                        title: title,
                        chunk: chunk,
                        index: index + 1,
                        total: chunks.count
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
                prompt: mergePrompt(title: title, notes: chunkNotes.joined(separator: "\n\n---\n\n")),
                label: "merge",
                maxTokens: configuration.mergeMaxTokens,
                workDirectory: workDirectory
            )
        }

        try Task.checkCancellation()
        let normalizedBody = LocalMeetingSummaryNormalizer.normalized(summaryBody)
        let participants = LocalMeetingSummaryParticipantExtractor.participants(from: transcript)
        let sections = LocalMeetingSummaryNormalizer.sections(in: normalizedBody)
            .withParticipants(participants)
        let latestMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        let latestTranscript = LocalMeetingTranscriptExtractor.transcriptText(from: latestMarkdown)
        guard latestTranscript == transcript else {
            throw LocalMeetingSummaryError.transcriptChanged
        }
        let updatedMarkdown = LocalMeetingSummaryMarkdownUpdater.markdown(
            byApplying: sections,
            to: latestMarkdown,
            configuration: configuration,
            generatedAt: date,
            chunkCount: chunks.count,
            sourceTranscriptFilename: transcriptURL.lastPathComponent
        )

        try Task.checkCancellation()
        try updatedMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
        fileManager.restrictFileToOwnerOnly(at: transcriptURL)

        return LocalMeetingSummaryResult(
            transcriptURL: transcriptURL,
            chunkCount: chunks.count,
            profileName: configuration.profileName
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

    private func directPrompt(title: String, transcript: String) -> String {
        """
        You are Transcripted's local meeting summarizer. You are running fully on-device with Gemma 4 12B.

        Summarize "\(title)" accurately. Do not invent decisions, tasks, dates, names, or facts. If something is unclear, write unclear.

        Return markdown in exactly this shape:
        # Title
        <plain 3-8 word title, no markdown marker>

        # Summary
        - <2-4 bullets on what mattered, outcomes, and important context>

        # Decisions
        - <only explicit choices or commitments>

        # Action Items
        - <Owner if named: concrete unfinished follow-up>

        # Open Questions
        - <unresolved questions>

        # Risks or Follow-ups
        - <risks, blockers, or things to watch>

        # Accuracy Notes
        - <only source-quality caveats that affect trust>

        Rules:
        - Always include every section heading exactly as listed, even when the section says "None found."
        - Base every point only on the transcript.
        - Do not make the meeting title itself a markdown heading. Always put it under # Title.
        - Title must be specific, plain, and 3 to 8 words.
        - Keep the whole output short. Prefer fewer, sharper bullets over broad coverage.
        - Summary must explain the actual substance of the meeting, not describe the transcript. Never write "the transcript consists of", "the transcript contains", "the speaker discusses", or similar meta-summary filler.
        - If the source is a test, demo, repeated status loop, or setup check, summarize it as a test recording or setup check. Do not summarize it as repetitive transcript text.
        - Use compact one-line bullets. Do not use sub-bullets, long explanations, or repeated qualifiers.
        - Include timestamps when available.
        - Preserve concrete names, product names, decisions, dates, and numbers when they matter.
        - Decisions include explicit choices, selections, agreed settings, approvals, or commitments from the transcript.
        - Decision bullets should name the outcome first, then short context.
        - Action Items are only future follow-up work after the meeting, not instructions already completed during the transcript.
        - Action item bullets should start with the owner when the transcript names one. If no owner is named, start with "Unassigned:".
        - Treat commitments as action items when a participant agrees to do, send, decide, test, review, or follow up on something after the meeting.
        - Do not list one-off navigation, roleplay, game, or setup instructions as Action Items unless the transcript leaves them as unfinished follow-up work.
        - Put brainstorms, proposals, or maybes in Open Questions or Risks unless the transcript clearly says they were decided.
        - Accuracy Notes should be "None found." unless repetition, cut-off text, unclear audio, or speaker confusion changes how much the reader should trust the summary.
        - If a section has nothing supported, write exactly "None found."

        Transcript:
        \(transcript)
        """
    }

    private func chunkPrompt(title: String, chunk: String, index: Int, total: Int) -> String {
        """
        You are Transcripted's local meeting-note extractor. This is chunk \(index) of \(total) from "\(title)".

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
        - Chunk Summary should capture the actual substance, not describe the transcript or the speaker.
        - If the source is a test, demo, repeated status loop, or setup check, summarize it as a test recording or setup check. Do not summarize it as repetitive transcript text.
        - Use compact one-line bullets. Do not use sub-bullets or long explanations.
        - Include timestamps and speakers when available, especially for action items and decisions.
        - Preserve concrete names, product names, decisions, dates, and numbers when they matter.
        - Decisions include explicit choices, selections, agreed settings, approvals, or commitments from this chunk.
        - Decision bullets should name the outcome first, then short context.
        - Action Items are only future follow-up work after the meeting, not in-call setup steps or instructions already completed during the transcript.
        - Action item bullets should start with the owner when the chunk names one. If no owner is named, start with "Unassigned:".
        - Treat commitments as action items when a participant agrees to do, send, decide, test, review, or follow up on something after the meeting.
        - Do not list one-off navigation, roleplay, game, or setup instructions as Action Items unless the chunk leaves them as unfinished follow-up work.
        - Keep brainstorms, proposals, or maybes out of Decisions unless the chunk clearly says they were decided.
        - If a heading has nothing supported, write exactly "None found."

        Chunk transcript:
        \(chunk)
        """
    }

    private func mergePrompt(title: String, notes: String) -> String {
        """
        You are Transcripted's local meeting summarizer. Merge these chunk notes for "\(title)" into one accurate meeting summary.

        Do not invent decisions, tasks, dates, names, or facts.

        Return markdown in exactly this shape:
        # Title
        <plain 3-8 word title, no markdown marker>

        # Summary
        - <2-4 bullets on what mattered, outcomes, and important context>

        # Decisions
        - <only explicit choices or commitments>

        # Action Items
        - <Owner if named: concrete unfinished follow-up>

        # Open Questions
        - <unresolved questions>

        # Risks or Follow-ups
        - <risks, blockers, or things to watch>

        # Accuracy Notes
        - <only source-quality caveats that affect trust>

        Rules:
        - Always include every section heading exactly as listed, even when the section says "None found."
        - Base every point only on the chunk notes.
        - Do not make the meeting title itself a markdown heading. Always put it under # Title.
        - Title must be specific, plain, and 3 to 8 words.
        - Keep the whole output short. Prefer fewer, sharper bullets over broad coverage.
        - Summary must explain the actual substance of the meeting, not describe the notes. Never write "the transcript consists of", "the transcript contains", "the speaker discusses", or similar meta-summary filler.
        - If the source is a test, demo, repeated status loop, or setup check, summarize it as a test recording or setup check. Do not summarize it as repetitive transcript text.
        - Use compact one-line bullets. Do not use sub-bullets, long explanations, or repeated qualifiers.
        - Include timestamps when available.
        - Preserve concrete names, product names, decisions, dates, and numbers when they matter.
        - Preserve explicit action items, decisions, open questions, and follow-ups from the chunk notes.
        - Decisions include explicit choices, selections, agreed settings, approvals, or commitments from the chunk notes.
        - Decision bullets should name the outcome first, then short context.
        - Action Items are only future follow-up work after the meeting, not in-call setup steps or instructions already completed during the transcript.
        - Action item bullets should start with the owner when the notes name one. If no owner is named, start with "Unassigned:".
        - Treat commitments as action items when a participant agrees to do, send, decide, test, review, or follow up on something after the meeting.
        - Do not list one-off navigation, roleplay, game, or setup instructions as Action Items unless the notes leave them as unfinished follow-up work.
        - Remove duplicates only when the same owner, same task or decision, and same topic are repeated.
        - Never promote brainstorms, proposals, or unresolved questions into Decisions.
        - Accuracy Notes should be "None found." unless repetition, cut-off text, unclear audio, or speaker confusion changes how much the reader should trust the summary.
        - If a section has nothing supported, write exactly "None found."

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
            participants: section("# Participants", in: text) ?? "None found.",
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
            .map(cleanTitleText)
            .flatMap { isStructuralGeneratedTitle($0) ? nil : String($0.prefix(96)) }
        return explicitTitle ?? firstGeneratedTitleHeading(in: raw)
    }

    static func section(_ heading: String, in raw: String) -> String? {
        let lines = raw.components(separatedBy: .newlines)
        let targetTitle = normalizedHeadingTitle(heading)
        guard let startIndex = lines.firstIndex(where: {
            normalizedHeadingTitle($0) == targetTitle
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
        let targetTitle = normalizedHeadingTitle(heading)
        return text.components(separatedBy: .newlines).contains { line in
            normalizedHeadingTitle(line) == targetTitle
        }
    }

    private static func normalizedHeadingTitle(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let title = trimmed.drop { $0 == "#" }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func firstGeneratedTitleHeading(in raw: String) -> String? {
        raw.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("# "), !requiredSections.contains(trimmed) else {
                return nil
            }
            let title = cleanTitleText(String(trimmed.dropFirst(2)))
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

    private static func cleanTitleText(_ raw: String) -> String {
        var title = cleanSectionText(raw)
        while title.hasPrefix("#") {
            title = String(title.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title
    }
}

enum LocalMeetingSummaryMarkdownUpdater {
    static let startMarker = "<!-- transcripted:local-summary:start v=1 -->"
    static let endMarker = "<!-- transcripted:local-summary:end -->"

    private static let managedFrontmatterKeys: Set<String> = [
        "local_summary_version",
        "local_summary_source_transcript",
        "local_summary_title",
        "local_summary_generated_at",
        "local_summary_model",
        "local_summary_runtime",
        "local_summary_profile",
        "local_summary_chunk_count",
        "local_summary_participants",
        "local_summary",
        "local_summary_next_steps",
        "local_summary_commitments",
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
        chunkCount: Int,
        sourceTranscriptFilename: String? = nil
    ) -> String {
        let document = TranscriptFrontmatter.document(in: markdown)
        let body = document?.body ?? markdown
        let frontmatterLines = updatedFrontmatterLines(
            existing: document?.lines ?? [],
            sections: sections,
            configuration: configuration,
            generatedAt: generatedAt,
            chunkCount: chunkCount,
            sourceTranscriptFilename: sourceTranscriptFilename
        )
        let updatedBody = removingLocalSummaryBlock(from: body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let renderedBody = [updatedBody, renderedLocalSummarySection(sections, sourceTranscriptFilename: sourceTranscriptFilename)]
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
        configuration: LocalGemmaSummaryConfiguration,
        generatedAt: Date,
        chunkCount: Int,
        sourceTranscriptFilename: String?
    ) -> [String] {
        let retained = existing.filter { line in
            guard let key = frontmatterKey(in: line) else { return true }
            return !managedFrontmatterKeys.contains(key)
        }
        let generatedAtString = ISO8601DateFormatter().string(from: generatedAt)
        let sourceLines = sourceTranscriptFilename
            .flatMap { filename -> String? in
                let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : yamlLine("local_summary_source_transcript", trimmed)
            }
            .map { [$0] } ?? []
        return retained + sourceLines + [
            "local_summary_version: \"1\"",
            yamlLine("local_summary_title", sections.title ?? ""),
            "local_summary_generated_at: \"\(generatedAtString)\"",
            yamlLine("local_summary_model", configuration.modelID),
            yamlLine("local_summary_runtime", configuration.runtimePackage),
            yamlLine("local_summary_profile", configuration.profileName),
            "local_summary_chunk_count: \"\(chunkCount)\"",
            yamlLine("local_summary_participants", frontmatterSummaryValue(sections.participants)),
            yamlLine("local_summary", frontmatterSummaryValue(sections.summary)),
            yamlLine("local_summary_next_steps", frontmatterSummaryValue(nextStepsText(sections))),
            yamlLine("local_summary_commitments", frontmatterSummaryValue(sections.actionItems)),
            yamlLine("local_summary_decisions", frontmatterSummaryValue(sections.decisions)),
            yamlLine("local_summary_action_items", frontmatterSummaryValue(sections.actionItems)),
            yamlLine("local_summary_open_questions", frontmatterSummaryValue(sections.openQuestions)),
            yamlLine("local_summary_risks_or_followups", frontmatterSummaryValue(sections.risksOrFollowUps)),
            yamlLine("local_summary_accuracy_notes", frontmatterSummaryValue(sections.accuracyNotes))
        ]
    }

    private static func renderedLocalSummarySection(
        _ sections: LocalMeetingSummarySections,
        sourceTranscriptFilename: String?
    ) -> String {
        let sourceLine = sourceTranscriptFilename
            .flatMap { filename -> String? in
                let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : "Source transcript: `\(trimmed)`"
            }
        let headerLines = ["## Local Gemma Summary", sourceLine]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return """
        \(startMarker)
        \(headerLines)

        ### Summary
        \(sections.summary)

        ### Next Steps
        \(nextStepsText(sections))

        ### Decisions
        \(sections.decisions)

        ### Open Questions
        \(sections.openQuestions)

        ### Participants
        \(sections.participants)

        ### Action Items
        \(sections.actionItems)

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
        guard let startRange = body.range(of: startMarker) else {
            return body
        }
        guard let endRange = body.range(
                of: endMarker,
                range: startRange.upperBound..<body.endIndex
              ) else {
            var updated = body
            updated.removeSubrange(startRange.lowerBound..<updated.endIndex)
            return updated
        }

        var updated = body
        updated.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        return updated
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

    private static func nextStepsText(_ sections: LocalMeetingSummarySections) -> String {
        let values = [sections.actionItems, sections.risksOrFollowUps]
            .filter(isMeaningfulSummaryText)
        guard !values.isEmpty else { return "None found." }
        return values.joined(separator: "\n")
    }

    private static func isMeaningfulSummaryText(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.localizedCaseInsensitiveCompare("none found.") != .orderedSame
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
