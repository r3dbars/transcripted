import ArgumentParser
import Foundation
import SQLite3

struct StressTest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stress-test",
        abstract: "Generate large test datasets and validate performance + correctness."
    )

    @Option(name: .long, help: "Number of transcripts to generate")
    var transcripts: Int = 50

    @Option(name: .long, help: "Speakers per transcript")
    var speakersPerTranscript: Int = 5

    @Option(name: .long, help: "Utterances per transcript")
    var utterancesPerTranscript: Int = 100

    @OptionGroup var formatOpts: FormatOptions

    func run() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcripted-stress-\(ProcessInfo.processInfo.processIdentifier)")
        let fm = FileManager.default

        if fm.fileExists(atPath: tmpDir.path) {
            try fm.removeItem(at: tmpDir)
        }
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        defer {
            try? fm.removeItem(at: tmpDir)
        }

        let memBefore = currentMemoryUsageMB()
        let overallStart = Date()

        // -------------------------------------------------------
        // Step 1: Generate large transcript set
        // -------------------------------------------------------
        print("=== Step 1: Generate \(transcripts) transcripts (\(utterancesPerTranscript) utterances, \(speakersPerTranscript) speakers each) ===")
        let genStart = Date()

        var transcriptNames: [String] = []
        for i in 0..<transcripts {
            let hour = i / 60
            let minute = i % 60
            let name = String(format: "Call_2026-03-26_%02d-%02d-00", hour, minute)
            transcriptNames.append(name)
        }

        let generator = TestDataGenerator(outputDir: tmpDir)

        for (idx, name) in transcriptNames.enumerated() {
            let duration = 300 + (idx * 10)
            try generator.generateTranscript(
                name: name,
                utteranceCount: utterancesPerTranscript,
                speakerCount: speakersPerTranscript
            )
            try generator.generateSidecar(
                name: name,
                utteranceCount: utterancesPerTranscript,
                speakerCount: speakersPerTranscript,
                durationSeconds: duration
            )
        }

        let genTime = Date().timeIntervalSince(genStart)
        print("  Generated \(transcripts) transcripts + sidecars in \(String(format: "%.2f", genTime))s")

        // -------------------------------------------------------
        // Step 2: Generate speakers.sqlite with 50+ speakers
        // -------------------------------------------------------
        print("\n=== Step 2: Generate speaker database ===")
        let speakerCount = max(50, speakersPerTranscript * 2)
        try generator.generateSpeakerDB(speakerCount: speakerCount)
        print("  Generated speakers.sqlite with \(speakerCount) speakers")

        // -------------------------------------------------------
        // Step 3: Generate stats.sqlite
        // -------------------------------------------------------
        print("\n=== Step 3: Generate stats database ===")
        try generator.generateStatsDB(recordingCount: transcripts)
        print("  Generated stats.sqlite with \(transcripts) recordings")

        // -------------------------------------------------------
        // Step 4: Generate index referencing all transcripts
        // -------------------------------------------------------
        print("\n=== Step 4: Generate index ===")
        try generator.generateIndex(transcriptNames: transcriptNames)
        print("  Generated transcripted.json with \(transcripts) entries")

        // -------------------------------------------------------
        // Step 5: Generate large log file (1000+ entries)
        // -------------------------------------------------------
        print("\n=== Step 5: Generate large log file ===")
        let logEntryCount = 1500
        try generator.generateLogFile(entryCount: logEntryCount, errorRate: 0.02)
        print("  Generated app.jsonl with \(logEntryCount) entries")

        // -------------------------------------------------------
        // Step 6: Run all validators and time each category
        // -------------------------------------------------------
        print("\n=== Step 6: Timed validation passes ===")

        var allResults: [ValidationResult] = []
        var timings: [(category: String, duration: Double, checkCount: Int)] = []

        // Transcript validation
        let t1 = Date()
        let transcriptResults = TranscriptValidator(directory: tmpDir).validate()
        let d1 = Date().timeIntervalSince(t1)
        allResults += transcriptResults
        timings.append(("TranscriptValidator", d1, transcriptResults.count))

        // JSON Sidecar validation
        let t2 = Date()
        let sidecarResults = JSONSidecarValidator(directory: tmpDir).validate()
        let d2 = Date().timeIntervalSince(t2)
        allResults += sidecarResults
        timings.append(("JSONSidecarValidator", d2, sidecarResults.count))

        // Speaker DB validation
        let t3 = Date()
        let speakerResults = SpeakerDBValidator(
            dbPath: tmpDir.appendingPathComponent("speakers.sqlite").path
        ).validate()
        let d3 = Date().timeIntervalSince(t3)
        allResults += speakerResults
        timings.append(("SpeakerDBValidator", d3, speakerResults.count))

        // Stats DB validation
        let t4 = Date()
        let statsResults = StatsDBValidator(
            dbPath: tmpDir.appendingPathComponent("stats.sqlite").path
        ).validate()
        let d4 = Date().timeIntervalSince(t4)
        allResults += statsResults
        timings.append(("StatsDBValidator", d4, statsResults.count))

        // Log validation
        let t5 = Date()
        let logResults = LogValidator(
            logPath: tmpDir.appendingPathComponent("Logs/app.jsonl").path
        ).validate()
        let d5 = Date().timeIntervalSince(t5)
        allResults += logResults
        timings.append(("LogValidator", d5, logResults.count))

        // Index validation
        let t6 = Date()
        let indexResults = IndexValidator(directory: tmpDir).validate()
        let d6 = Date().timeIntervalSince(t6)
        allResults += indexResults
        timings.append(("IndexValidator", d6, indexResults.count))

        // Print timing report
        for (category, duration, checks) in timings {
            let perCheck = checks > 0 ? duration / Double(checks) * 1000 : 0
            print("  \(category.padding(toLength: 24, withPad: " ", startingAt: 0)) \(String(format: "%6.3f", duration))s  \(checks) checks  \(String(format: "%.2f", perCheck))ms/check")
        }

        // -------------------------------------------------------
        // Step 7: Stress-specific checks
        // -------------------------------------------------------
        print("\n=== Step 7: Stress-specific checks ===")

        var stressResults: [ValidationResult] = []

        // Check 1: All transcript filenames are unique
        let mdFiles = (try? fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" && $0.lastPathComponent.hasPrefix("Call_") }) ?? []
        let mdNames = mdFiles.map { $0.lastPathComponent }
        let uniqueMdNames = Set(mdNames)
        if mdNames.count == uniqueMdNames.count {
            stressResults.append(.pass("stress/unique-filenames", target: "\(mdNames.count) transcripts"))
            print("  PASS  All \(mdNames.count) transcript filenames are unique")
        } else {
            let dupeCount = mdNames.count - uniqueMdNames.count
            stressResults.append(.fail("stress/unique-filenames", target: "\(mdNames.count) transcripts",
                detail: "\(dupeCount) duplicate filenames"))
            print("  FAIL  \(dupeCount) duplicate filenames found")
        }

        // Check 2: No duplicate speaker IDs in index
        let indexPath = tmpDir.appendingPathComponent("transcripted.json")
        if let indexData = try? Data(contentsOf: indexPath),
           let indexJSON = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
           let knownSpeakers = indexJSON["known_speakers"] as? [[String: Any]] {
            let speakerIds = knownSpeakers.compactMap { $0["persistent_id"] as? String }
            let uniqueSpeakerIds = Set(speakerIds)
            if speakerIds.count == uniqueSpeakerIds.count {
                stressResults.append(.pass("stress/no-duplicate-speaker-ids", target: "\(speakerIds.count) speakers"))
                print("  PASS  No duplicate speaker IDs in index (\(speakerIds.count) speakers)")
            } else {
                let dupeCount = speakerIds.count - uniqueSpeakerIds.count
                stressResults.append(.fail("stress/no-duplicate-speaker-ids", target: "index",
                    detail: "\(dupeCount) duplicate speaker IDs"))
                print("  FAIL  \(dupeCount) duplicate speaker IDs in index")
            }
        } else {
            stressResults.append(.fail("stress/no-duplicate-speaker-ids", target: "index",
                detail: "Could not parse transcripted.json"))
            print("  FAIL  Could not parse index for speaker ID check")
        }

        // Check 3: Log entry count check with large log
        let logPath = tmpDir.appendingPathComponent("Logs/app.jsonl")
        if let logContent = try? String(contentsOf: logPath, encoding: .utf8) {
            let lineCount = logContent.components(separatedBy: "\n").filter { !$0.isEmpty }.count
            if lineCount == logEntryCount {
                stressResults.append(.pass("stress/log-entry-count", target: "\(lineCount) entries"))
                print("  PASS  Log has expected \(lineCount) entries")
            } else {
                stressResults.append(.fail("stress/log-entry-count", target: "app.jsonl",
                    detail: "Expected \(logEntryCount) entries, got \(lineCount)"))
                print("  FAIL  Expected \(logEntryCount) log entries, got \(lineCount)")
            }
        } else {
            stressResults.append(.fail("stress/log-entry-count", target: "app.jsonl",
                detail: "Could not read log file"))
            print("  FAIL  Could not read log file")
        }

        // Check 4: Memory usage delta
        let memAfter = currentMemoryUsageMB()
        let memDelta = memAfter - memBefore
        let memStatus = memDelta < 500 ? "PASS" : "WARN"
        if memDelta < 500 {
            stressResults.append(.pass("stress/memory-usage", target: "\(String(format: "%.1f", memDelta))MB delta"))
        } else {
            stressResults.append(.warn("stress/memory-usage", target: "\(String(format: "%.1f", memDelta))MB delta",
                detail: "Memory increased by \(String(format: "%.1f", memDelta))MB — may indicate a leak"))
        }
        print("  \(memStatus)  Memory delta: \(String(format: "%.1f", memDelta))MB (before: \(String(format: "%.1f", memBefore))MB, after: \(String(format: "%.1f", memAfter))MB)")

        allResults += stressResults

        // -------------------------------------------------------
        // Step 8: Summary
        // -------------------------------------------------------
        let totalTime = Date().timeIntervalSince(overallStart)
        let passed = allResults.filter { $0.status == .pass }.count
        let failed = allResults.filter { $0.status == .fail }.count
        let warned = allResults.filter { $0.status == .warn }.count

        print("\n=== Summary ===")
        print("Total checks:  \(allResults.count)")
        print("Passed:        \(passed)")
        print("Failed:        \(failed)")
        print("Warnings:      \(warned)")
        print("Total time:    \(String(format: "%.2f", totalTime))s")
        print("")

        for (category, duration, checks) in timings {
            print("  \(category.padding(toLength: 24, withPad: " ", startingAt: 0)) \(String(format: "%6.3f", duration))s  (\(checks) checks)")
        }

        if failed > 0 {
            print("\nFailed checks:")
            for result in allResults where result.status == .fail {
                print("  FAIL  \(result.check)  \(result.target)  \(result.detail ?? "")")
            }
            throw ExitCode(1)
        }
    }

    // MARK: - Memory Measurement

    /// Get current process memory usage in MB using mach_task_info.
    private func currentMemoryUsageMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), ptr, &count)
            }
        }
        if result == KERN_SUCCESS {
            return Double(info.resident_size) / (1024 * 1024)
        }
        return 0
    }
}
