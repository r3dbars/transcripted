// TestHelpers.swift
// Minimal assertion helpers for test suite (no XCTest dependency)

import Foundation

var totalTests = 0
var passedTests = 0
var failedTests = 0

struct ObservabilitySanitizerCorpus: Decodable {
    let cases: [ObservabilitySanitizerCorpusCase]
}

struct ObservabilitySanitizerCorpusCase: Decodable {
    let id: String
    let input: String
    let mustNotContain: [String]
    let mustContain: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case input
        case mustNotContain = "must_not_contain"
        case mustContain = "must_contain"
    }
}

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: String = #file, line: Int = #line) {
    totalTests += 1
    if actual == expected {
        passedTests += 1
    } else {
        failedTests += 1
        let loc = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        print("  FAIL [\(loc)] \(message.isEmpty ? "" : message + " — ")expected \(expected), got \(actual)")
    }
}

func assertTrue(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    totalTests += 1
    if condition {
        passedTests += 1
    } else {
        failedTests += 1
        let loc = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        print("  FAIL [\(loc)] \(message.isEmpty ? "expected true" : message)")
    }
}

func assertFalse(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    assertTrue(!condition, message.isEmpty ? "expected false" : message, file: file, line: line)
}

func assertNil<T>(_ value: T?, _ message: String = "", file: String = #file, line: Int = #line) {
    totalTests += 1
    if value == nil {
        passedTests += 1
    } else {
        failedTests += 1
        let loc = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        print("  FAIL [\(loc)] \(message.isEmpty ? "expected nil" : message), got \(String(describing: value))")
    }
}

func assertNotNil<T>(_ value: T?, _ message: String = "", file: String = #file, line: Int = #line) {
    totalTests += 1
    if value != nil {
        passedTests += 1
    } else {
        failedTests += 1
        let loc = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        print("  FAIL [\(loc)] \(message.isEmpty ? "expected non-nil" : message)")
    }
}

/// Suites benched in Tests/quarantine.txt, one per line as
/// `YYYY-MM-DD | <runSuite name> | <why, and who fixes it>`. A benched suite is
/// skipped and reported instead of turning unrelated PRs red while it gets
/// fixed. `scripts/dev/check-test-shape.py` validates the file and warns about
/// entries older than two weeks. See Tests/README.md ("Flaky tests").
let quarantinedSuites: [String: String] = {
    guard let text = try? String(contentsOf: repoFixtureURL("Tests/quarantine.txt"), encoding: .utf8) else {
        return [:]
    }
    var suites: [String: String] = [:]
    for rawLine in text.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.split(separator: "|", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 3 { suites[parts[1]] = parts[2] }
    }
    return suites
}()

var quarantinedSuiteCount = 0

private func skipQuarantinedSuite(_ name: String) -> Bool {
    guard let reason = quarantinedSuites[name] else { return false }
    quarantinedSuiteCount += 1
    print("Skipping \(name) (quarantined: \(reason))")
    return true
}

func runSuite(_ name: String, _ block: () -> Void) {
    if skipQuarantinedSuite(name) { return }
    print("Running \(name)...")
    block()
}

func runSuite(_ name: String, _ block: () async -> Void) async {
    if skipQuarantinedSuite(name) { return }
    print("Running \(name)...")
    await block()
}

actor ParakeetAsyncInterleavingGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func opened() -> Bool {
        isOpen
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}

func repoFixtureURL(_ relativePath: String) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(relativePath)
}

/// ParakeetEngine is one @MainActor class split by area into a core file plus
/// extension files. Its source contracts read the core and these extensions
/// together. Each file ends with its closing brace at column zero, so a slice
/// ending at "\n}\n" stops at the end of the file it started in.
let parakeetEngineSourceFiles = [
    "ParakeetEngine.swift",
    "ParakeetInputReadiness.swift",
    "ParakeetInputRoute.swift",
    "ParakeetAudioTap.swift",
    "ParakeetRecordingStart.swift",
    "ParakeetRecordingTeardown.swift",
    "ParakeetDictationTranscription.swift",
    "ParakeetASRInference.swift",
]

func readParakeetEngineSource(file: String = #file, line: Int = #line) -> String {
    parakeetEngineSourceFiles.map { name in
        readSourceFixture(
            "Sources/Speech/\(name)",
            description: name,
            file: file,
            line: line
        )
    }.joined(separator: "\n")
}

/// MeetingSessionController is one @MainActor class split into a core file
/// plus `MeetingSessionController+Area.swift` extension files. `part: "Stop"`
/// reads only `MeetingSessionController+Stop.swift`, so an ordering pin stays
/// inside the one file both of its anchors live in. With no part, it reads the
/// core file and every extension joined, for presence checks and call counts.
func readMeetingSessionControllerSource(part: String? = nil, file: String = #file, line: Int = #line) -> String {
    joinedSplitTypeText(directory: "Sources/Meeting", type: "MeetingSessionController", part: part, file: file, line: line)
}

private func joinedSplitTypeText(directory: String, type: String, part: String?, file: String, line: Int) -> String {
    let names: [String]
    if let part {
        names = ["\(type)+\(part).swift"]
    } else {
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: repoFixtureURL(directory).path)) ?? []
        names = ["\(type).swift"] + listing.filter { $0.hasPrefix("\(type)+") && $0.hasSuffix(".swift") }.sorted()
    }
    return names.map { name in
        readSourceFixture("\(directory)/\(name)", description: name, file: file, line: line)
    }.joined(separator: "\n")
}

func readSourceFixture(
    _ relativePath: String,
    description: String? = nil,
    file: String = #file,
    line: Int = #line
) -> String {
    let url = repoFixtureURL(relativePath)
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        totalTests += 1
        failedTests += 1
        let loc = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        print("  FAIL [\(loc)] could not read \(description ?? relativePath): \(error)")
        return ""
    }
}

func loadJSONFixture<T: Decodable>(_ relativePath: String, as type: T.Type = T.self, file: String = #file, line: Int = #line) -> T {
    let url = repoFixtureURL(relativePath)

    do {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        failedTests += 1
        totalTests += 1
        let loc = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        print("  FAIL [\(loc)] could not load fixture \(relativePath): \(error)")
        fatalError("Missing required fixture \(relativePath)")
    }
}
