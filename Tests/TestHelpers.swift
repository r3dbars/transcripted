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

func runSuite(_ name: String, _ block: () -> Void) {
    print("Running \(name)...")
    block()
}

func runSuite(_ name: String, _ block: () async -> Void) async {
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

func readParakeetEngineSource(file: String = #file, line: Int = #line) -> String {
    readSourceFixture(
        "Sources/Speech/ParakeetEngine.swift",
        description: "ParakeetEngine.swift",
        file: file,
        line: line
    )
}

func readParakeetDeviceRecoverySource(file: String = #file, line: Int = #line) -> String {
    readSourceFixture(
        "Sources/Speech/ParakeetDeviceRecovery.swift",
        description: "ParakeetDeviceRecovery.swift",
        file: file,
        line: line
    )
}

func assertPostAwaitOwnershipGuard(
    in body: String,
    ownerCapture: String,
    suspension: String,
    guardStatement: String,
    mutation: String,
    helper: String,
    file: String = #file,
    line: Int = #line
) {
    guard let capture = body.range(of: ownerCapture),
          let awaitPoint = body.range(of: suspension, range: capture.upperBound..<body.endIndex),
          let ownershipGuard = body.range(of: guardStatement, range: awaitPoint.upperBound..<body.endIndex),
          let sharedMutation = body.range(of: mutation, range: ownershipGuard.upperBound..<body.endIndex) else {
        assertTrue(false, "\(helper) should guard delayed completion before shared-state mutation", file: file, line: line)
        return
    }
    assertTrue(
        capture.lowerBound < awaitPoint.lowerBound
            && awaitPoint.lowerBound < ownershipGuard.lowerBound
            && ownershipGuard.lowerBound < sharedMutation.lowerBound,
        "\(helper) should capture owner, await work, revalidate owner, then mutate shared state",
        file: file,
        line: line
    )
}

private func readSourceFixture(
    _ relativePath: String,
    description: String,
    file: String,
    line: Int
) -> String {
    let url = repoFixtureURL(relativePath)
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        totalTests += 1
        failedTests += 1
        let loc = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        print("  FAIL [\(loc)] could not read \(description): \(error)")
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
