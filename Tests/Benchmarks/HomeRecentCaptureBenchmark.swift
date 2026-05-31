import Foundation

@main
struct HomeRecentCaptureBenchmark {
    static func main() async throws {
        let configuration = try BenchmarkConfiguration(arguments: CommandLine.arguments)
        let fileManager = FileManager.default
        let runRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("build/home-recent-capture-benchmark", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let captureRoot = runRoot.appendingPathComponent("captures", isDirectory: true)
        let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
        let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)
        let previousCaptureLocation = UserDefaults.standard.object(
            forKey: TranscriptedStoragePreferences.captureLibraryLocationKey
        )

        try fileManager.createDirectory(at: meetingsRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dictationsRoot, withIntermediateDirectories: true)
        defer {
            if let previousCaptureLocation {
                UserDefaults.standard.set(previousCaptureLocation, forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
            } else {
                UserDefaults.standard.removeObject(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
            }
            try? fileManager.removeItem(at: runRoot)
        }

        UserDefaults.standard.set(captureRoot.path, forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)

        let fixture = try FixtureBuilder(
            captures: configuration.captures,
            meetingsRoot: meetingsRoot,
            dictationsRoot: dictationsRoot
        ).build()

        var loadDurations: [Double] = []
        for _ in 0..<configuration.repetitions {
            let start = DispatchTime.now()
            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: configuration.visibleLimit + 1,
                meetingLimit: configuration.visibleLimit + 1,
                includeDictationCounts: true
            )
            let elapsed = milliseconds(since: start)
            try validate(snapshot: snapshot, fixture: fixture, visibleLimit: configuration.visibleLimit + 1)
            loadDurations.append(elapsed)
        }

        let cancellationStart = DispatchTime.now()
        let task = Task {
            await RecentCaptureLoader.load(
                dictationLimit: configuration.visibleLimit + 1,
                meetingLimit: configuration.visibleLimit + 1,
                includeDictationCounts: true
            )
        }
        task.cancel()
        _ = await task.value
        let cancellationDuration = milliseconds(since: cancellationStart)

        print(
            BenchmarkResult(
                captures: configuration.captures,
                meetings: fixture.meetingCount,
                dictations: fixture.dictationCount,
                repetitions: configuration.repetitions,
                loadDurations: loadDurations,
                cancellationDuration: cancellationDuration
            ).markdownRow
        )
    }

    private static func validate(
        snapshot: RecentCaptureSnapshot,
        fixture: FixtureSummary,
        visibleLimit: Int
    ) throws {
        guard snapshot.meetings.count == min(visibleLimit, fixture.meetingCount) else {
            throw BenchmarkError.validation("expected \(min(visibleLimit, fixture.meetingCount)) meetings, got \(snapshot.meetings.count)")
        }
        guard snapshot.dictations.count == min(visibleLimit, fixture.dictationCount) else {
            throw BenchmarkError.validation("expected \(min(visibleLimit, fixture.dictationCount)) dictations, got \(snapshot.dictations.count)")
        }
        guard snapshot.dictationCounts.total == fixture.dictationCount else {
            throw BenchmarkError.validation("expected \(fixture.dictationCount) counted dictations, got \(snapshot.dictationCounts.total)")
        }
        guard snapshot.dictationCounts.totalWords == fixture.totalDictationWords else {
            throw BenchmarkError.validation("expected \(fixture.totalDictationWords) counted words, got \(snapshot.dictationCounts.totalWords)")
        }
        guard isNewestFirst(snapshot.meetings.map(\.date)) else {
            throw BenchmarkError.validation("meetings were not sorted newest-first")
        }
        guard isNewestFirst(snapshot.dictations.map(\.createdAt)) else {
            throw BenchmarkError.validation("dictations were not sorted newest-first")
        }
    }

    private static func isNewestFirst(_ dates: [Date]) -> Bool {
        zip(dates, dates.dropFirst()).allSatisfy { $0 >= $1 }
    }

    private static func milliseconds(since start: DispatchTime) -> Double {
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Double(elapsed) / 1_000_000
    }
}

private struct BenchmarkConfiguration {
    let captures: Int
    let repetitions: Int
    let visibleLimit: Int

    init(arguments: [String]) throws {
        captures = try Self.intValue(for: "--captures", in: arguments) ?? 1_000
        repetitions = try Self.intValue(for: "--repetitions", in: arguments) ?? 3
        visibleLimit = try Self.intValue(for: "--visible-limit", in: arguments) ?? 10
        guard captures > 0, repetitions > 0, visibleLimit > 0 else {
            throw BenchmarkError.configuration("captures, repetitions, and visible-limit must be positive")
        }
    }

    private static func intValue(for flag: String, in arguments: [String]) throws -> Int? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex), let value = Int(arguments[valueIndex]) else {
            throw BenchmarkError.configuration("missing integer value for \(flag)")
        }
        return value
    }
}

private struct FixtureBuilder {
    let captures: Int
    let meetingsRoot: URL
    let dictationsRoot: URL

    private var meetingCount: Int { captures / 2 }
    private var dictationCount: Int { captures - meetingCount }
    private let calendar = Calendar(identifier: .gregorian)
    private let baseDate = Date(timeIntervalSince1970: 1_779_470_400) // 2026-05-18T14:00:00Z

    func build() throws -> FixtureSummary {
        var totalWords = 0
        for index in 0..<meetingCount {
            try writeMeeting(index: index)
        }
        for index in 0..<dictationCount {
            totalWords += try writeDictation(index: index)
        }
        return FixtureSummary(
            meetingCount: meetingCount,
            dictationCount: dictationCount,
            totalDictationWords: totalWords
        )
    }

    private func writeMeeting(index: Int) throws {
        let date = date(offsetMinutes: -index)
        let filename = String(format: "Meeting_%05d.md", index)
        let url = meetingsRoot.appendingPathComponent(filename, isDirectory: false)
        let markdown = """
        ---
        title: "Synthetic Meeting \(index)"
        capture_type: meeting
        date: "\(dayString(from: date))"
        time: "\(timeString(from: date))"
        duration: "10:00"
        total_word_count: 8
        mic_utterances: 1
        system_utterances: 1
        ---

        # Synthetic Meeting \(index)

        ## Transcript

        **00:01** [Mic/You]
        Synthetic meeting line \(index).

        **00:04** [System/Alex]
        Another synthetic line \(index).
        """
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.creationDate: date, .modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    private func writeDictation(index: Int) throws -> Int {
        let date = date(offsetDays: -index)
        let filename = "Dictations_\(dayString(from: date)).md"
        let url = dictationsRoot.appendingPathComponent(filename, isDirectory: false)
        let wordCount = 6
        let markdown = """
        ---
        title: "Dictations for \(dayString(from: date))"
        date: \(dayString(from: date))
        capture_type: dictation_day
        ---

        # Dictations for \(dayString(from: date))

        ## \(sectionTimeString(from: date)) - Synthetic dictation \(index)

        Entry ID: `dictation-\(index)`
        Captured: \(isoString(from: date))
        Source app: Benchmark
        Delivery: copied
        Words: \(wordCount)
        Characters: 42

        synthetic dictation body number \(index)
        """
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.creationDate: date, .modificationDate: date],
            ofItemAtPath: url.path
        )
        return wordCount
    }

    private func date(offsetMinutes: Int) -> Date {
        calendar.date(byAdding: .minute, value: offsetMinutes, to: baseDate) ?? baseDate
    }

    private func date(offsetDays: Int) -> Date {
        calendar.date(byAdding: .day, value: offsetDays, to: baseDate) ?? baseDate
    }

    private func dayString(from date: Date) -> String {
        format(date, pattern: "yyyy-MM-dd")
    }

    private func timeString(from date: Date) -> String {
        format(date, pattern: "HH:mm:ss")
    }

    private func sectionTimeString(from date: Date) -> String {
        format(date, pattern: "h:mm a")
    }

    private func isoString(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

private struct FixtureSummary {
    let meetingCount: Int
    let dictationCount: Int
    let totalDictationWords: Int
}

private struct BenchmarkResult {
    let captures: Int
    let meetings: Int
    let dictations: Int
    let repetitions: Int
    let loadDurations: [Double]
    let cancellationDuration: Double

    var markdownRow: String {
        let raw = loadDurations.map { String(format: "%.1f", $0) }.joined(separator: ", ")
        let average = loadDurations.reduce(0, +) / Double(loadDurations.count)
        let best = loadDurations.min() ?? 0
        return "| \(captures) | \(meetings) | \(dictations) | \(repetitions) | \(raw) | \(String(format: "%.1f", average)) | \(String(format: "%.1f", best)) | \(String(format: "%.1f", cancellationDuration)) |"
    }
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case configuration(String)
    case validation(String)

    var description: String {
        switch self {
        case .configuration(let message), .validation(let message):
            return message
        }
    }
}
