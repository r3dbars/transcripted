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

func repoFixtureURL(_ relativePath: String) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(relativePath)
}

/// TranscriptedSettingsView.swift's pages are split across sibling
/// `TranscriptedSettingsView+*.swift` extension files. Contract tests that
/// check for wiring somewhere on the Settings surface should not care which
/// physical file a given page's code lives in, so this concatenates the main
/// file with all of its sibling extension files.
func settingsSurfaceContents() -> String {
    let mainURL = repoFixtureURL("Sources/UI/Settings/TranscriptedSettingsView.swift")
    let mainContents = (try? String(contentsOf: mainURL, encoding: .utf8)) ?? ""
    let dirURL = repoFixtureURL("Sources/UI/Settings")
    guard let entries = try? FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) else {
        return mainContents
    }
    let extensionContents = entries
        .filter { $0.lastPathComponent.hasPrefix("TranscriptedSettingsView+") && $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
    return ([mainContents] + extensionContents).joined(separator: "\n")
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
