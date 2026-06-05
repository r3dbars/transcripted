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
    case missingBundledRunner
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

    static func m1Optimized(physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> LocalGemmaSummaryConfiguration {
        let gib = UInt64(1024 * 1024 * 1024)
        let memoryGB = physicalMemoryBytes / gib

        if memoryGB <= 16 {
            return LocalGemmaSummaryConfiguration(
                modelID: "mlx-community/gemma-4-12B-it-4bit",
                runtimePackage: "mlx-vlm",
                profileName: "m1-low-memory",
                minimumPhysicalMemoryBytes: 12 * gib,
                chunkCharacterLimit: 14_000,
                chunkMaxTokens: 420,
                directMaxTokens: 900,
                mergeMaxTokens: 1_300,
                maxKVSize: 8_192,
                processTimeoutSeconds: 900
            )
        }

        return LocalGemmaSummaryConfiguration(
            modelID: "mlx-community/gemma-4-12B-it-4bit",
            runtimePackage: "mlx-vlm",
            profileName: "apple-silicon-balanced",
            minimumPhysicalMemoryBytes: 12 * gib,
            chunkCharacterLimit: 18_000,
            chunkMaxTokens: 520,
            directMaxTokens: 1_000,
            mergeMaxTokens: 1_500,
            maxKVSize: 8_192,
            processTimeoutSeconds: 900
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

struct LocalGemmaSummaryRuntime: @unchecked Sendable {
    let configuration: LocalGemmaSummaryConfiguration
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var bundle: Bundle = .main
    var fileManager: FileManager = .default

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
        process.executableURL = uvURL
        let batchLabel = prompts.map { $0.label }.joined(separator: ", ")
        process.arguments = [
            "run",
            "--with",
            configuration.runtimePackage,
            "python",
            runnerURL.path,
            "--jobs-file", jobsURL.path,
            "--model", configuration.modelID,
            "--max-kv-size", "\(configuration.maxKVSize)"
        ]

        var processEnvironment = environment
        processEnvironment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        processEnvironment["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        processEnvironment["TOKENIZERS_PARALLELISM"] = "false"
        processEnvironment["PYTHONUNBUFFERED"] = "1"
        processEnvironment["UV_NO_PROGRESS"] = "1"
        processEnvironment["NO_COLOR"] = "1"
        process.environment = processEnvironment

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
        bundle.url(
            forResource: "gemma4_mlx_prompt_runner",
            withExtension: "py",
            subdirectory: "LocalSummarizer"
        )
    }

    private func uvExecutableURL() -> URL? {
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

        return try await Task.detached(priority: .utility) {
            let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
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

                let chunkOutputs = try runtime.generateBatch(
                    chunkPrompts,
                    workDirectory: workDirectory
                )
                var chunkNotes: [String] = []
                for (index, note) in chunkOutputs.enumerated() {
                    chunkNotes.append("# Chunk \(index + 1)\n\n\(note)")
                }

                summaryBody = try runtime.generate(
                    prompt: mergePrompt(title: title, notes: chunkNotes.joined(separator: "\n\n---\n\n")),
                    label: "merge",
                    maxTokens: configuration.mergeMaxTokens,
                    workDirectory: workDirectory
                )
            }

            let normalizedBody = LocalMeetingSummaryNormalizer.normalized(summaryBody)
            let sections = LocalMeetingSummaryNormalizer.sections(in: normalizedBody)
            let updatedMarkdown = LocalMeetingSummaryMarkdownUpdater.markdown(
                byApplying: sections,
                to: markdown,
                configuration: configuration,
                generatedAt: date,
                chunkCount: chunks.count
            )
            try updatedMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
            fileManager.restrictFileToOwnerOnly(at: transcriptURL)

            return LocalMeetingSummaryResult(
                transcriptURL: transcriptURL,
                chunkCount: chunks.count,
                profileName: configuration.profileName
            )
        }.value
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

        Return markdown with exactly these sections:
        # Title
        # Summary
        # Decisions
        # Action Items
        # Open Questions
        # Risks or Follow-ups
        # Accuracy Notes

        Rules:
        - Base every point only on the transcript.
        - Title must be specific, plain, and 3 to 8 words.
        - Keep it concise and useful.
        - Include timestamps when available.
        - If a section has nothing supported, write "None found."

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
        - Include timestamps when available.
        - Keep speaker labels only when useful.
        - If a heading has nothing supported, write "None found."

        Chunk transcript:
        \(chunk)
        """
    }

    private func mergePrompt(title: String, notes: String) -> String {
        """
        You are Transcripted's local meeting summarizer. Merge these chunk notes for "\(title)" into one accurate meeting summary.

        Do not invent decisions, tasks, dates, names, or facts. Remove duplicates.

        Return markdown with exactly these sections:
        # Title
        # Summary
        # Decisions
        # Action Items
        # Open Questions
        # Risks or Follow-ups
        # Accuracy Notes

        Rules:
        - Base every point only on the chunk notes.
        - Title must be specific, plain, and 3 to 8 words.
        - Keep each section concise.
        - Include timestamps when available.
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
        section("# Title", in: raw)?
            .components(separatedBy: .newlines)
            .first
            .map(cleanSectionText)
            .flatMap { $0.isEmpty || $0 == "None found." ? nil : String($0.prefix(96)) }
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
        let document = TranscriptFrontmatter.document(in: markdown)
        let body = document?.body ?? markdown
        let frontmatterLines = updatedFrontmatterLines(
            existing: document?.lines ?? [],
            sections: sections,
            configuration: configuration,
            generatedAt: generatedAt,
            chunkCount: chunkCount
        )
        let updatedBody = removingLocalSummaryBlock(from: body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let renderedBody = [updatedBody, renderedLocalSummarySection(sections)]
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
            yamlLine("local_summary_model", configuration.modelID),
            yamlLine("local_summary_runtime", configuration.runtimePackage),
            yamlLine("local_summary_profile", configuration.profileName),
            "local_summary_chunk_count: \"\(chunkCount)\"",
            yamlLine("local_summary", frontmatterSummaryValue(sections.summary)),
            yamlLine("local_summary_decisions", frontmatterSummaryValue(sections.decisions)),
            yamlLine("local_summary_action_items", frontmatterSummaryValue(sections.actionItems)),
            yamlLine("local_summary_open_questions", frontmatterSummaryValue(sections.openQuestions)),
            yamlLine("local_summary_risks_or_followups", frontmatterSummaryValue(sections.risksOrFollowUps)),
            yamlLine("local_summary_accuracy_notes", frontmatterSummaryValue(sections.accuracyNotes))
        ]
    }

    private static func renderedLocalSummarySection(_ sections: LocalMeetingSummarySections) -> String {
        """
        \(startMarker)
        ## Local Gemma Summary

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
            return trimmed == "## Local Summary" || trimmed == "## Local Gemma Summary"
        }) else {
            return body
        }

        var endIndex = lines.endIndex
        for index in lines.index(after: startIndex)..<lines.endIndex {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("## "),
               trimmed != "## Local Summary",
               trimmed != "## Local Gemma Summary" {
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
