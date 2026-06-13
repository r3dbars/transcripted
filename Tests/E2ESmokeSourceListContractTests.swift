import Foundation

func testE2ESmokeSourceListContract() {
    runSuite("E2E smoke source list contract - missing-source guard stays present") {
        let e2e = e2eSourceListReadRepoTextFile("scripts/entrypoints/run-e2e-smoke.sh")

        assertTrue(
            e2e.contains("E2E smoke source missing:"),
            "run-e2e-smoke.sh should guard each listed source path and fail with 'E2E smoke source missing:'"
        )

        let slow = e2eSourceListReadRepoTextFile("scripts/entrypoints/run-slow-pasteback-smoke.sh")
        assertTrue(
            slow.contains("E2E smoke source missing:"),
            "run-slow-pasteback-smoke.sh should mirror the same 'E2E smoke source missing:' existence guard"
        )
    }

    runSuite("E2E smoke source list contract - run-e2e-smoke.sh SWIFT_SOURCES all exist") {
        let scriptPath = "scripts/entrypoints/run-e2e-smoke.sh"
        let sources = e2eSourceListExtractSwiftSources(scriptPath)
        assertTrue(!sources.isEmpty, "should extract at least one source path from \(scriptPath)")

        for source in sources where source.hasPrefix("Sources/") || source.hasPrefix("Tools/") {
            assertTrue(
                e2eSourceListFileExists(source),
                "\(scriptPath) lists a missing source on disk: \(source)"
            )
        }
    }

    runSuite("E2E smoke source list contract - run-slow-pasteback-smoke.sh SWIFT_SOURCES all exist") {
        let scriptPath = "scripts/entrypoints/run-slow-pasteback-smoke.sh"
        let sources = e2eSourceListExtractSwiftSources(scriptPath)
        assertTrue(!sources.isEmpty, "should extract at least one source path from \(scriptPath)")

        for source in sources where source.hasPrefix("Sources/") || source.hasPrefix("Tools/") {
            assertTrue(
                e2eSourceListFileExists(source),
                "\(scriptPath) lists a missing source on disk: \(source)"
            )
        }
    }
}

private func e2eSourceListReadRepoTextFile(_ relativePath: String) -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func e2eSourceListFileExists(_ relativePath: String) -> Bool {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(relativePath)
    return FileManager.default.fileExists(atPath: url.path)
}

// Extract the quoted paths inside the SWIFT_SOURCES=( ... ) array of a smoke script.
private func e2eSourceListExtractSwiftSources(_ relativePath: String) -> [String] {
    let contents = e2eSourceListReadRepoTextFile(relativePath)
    let lines = contents.components(separatedBy: .newlines)

    var inArray = false
    var sources: [String] = []
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !inArray {
            if trimmed.hasPrefix("SWIFT_SOURCES=(") {
                inArray = true
            }
            continue
        }
        if trimmed.hasPrefix(")") {
            break
        }
        if let path = e2eSourceListFirstQuoted(trimmed) {
            sources.append(path)
        }
    }
    return sources
}

private func e2eSourceListFirstQuoted(_ line: String) -> String? {
    guard let start = line.firstIndex(of: "\"") else { return nil }
    let afterStart = line.index(after: start)
    guard let end = line[afterStart...].firstIndex(of: "\"") else { return nil }
    return String(line[afterStart..<end])
}
