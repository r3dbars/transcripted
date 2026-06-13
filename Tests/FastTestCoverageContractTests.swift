import Foundation

func testFastTestCoverageContract() {
    runSuite("Fast test coverage contract - runner emits LLVM coverage artifacts") {
        let contents = fastCoverageContractReadRepoTextFile("scripts/entrypoints/run-tests.sh")

        assertTrue(
            contents.contains("--coverage") && contents.contains("FAST_TEST_COVERAGE"),
            "fast tests should expose a CLI flag and env flag for coverage runs"
        )
        assertTrue(
            contents.contains("COVERAGE_DIR=\"$BUILD_DIR/coverage/fast-tests\""),
            "fast-test coverage artifacts should stay under build/coverage/fast-tests"
        )
        assertTrue(
            contents.contains("-profile-generate") && contents.contains("-profile-coverage-mapping"),
            "coverage runs should compile the same swiftc test suite with LLVM coverage instrumentation"
        )
        assertTrue(
            contents.contains("LLVM_PROFILE_FILE=\"$COVERAGE_DIR/default-%p.profraw\""),
            "coverage runs should isolate raw profile output by process"
        )
        assertTrue(
            contents.contains("llvm-profdata") && contents.contains("llvm-cov"),
            "coverage runs should merge profile data and emit llvm-cov reports"
        )
        assertTrue(
            contents.contains("summary.txt") && contents.contains("report.lcov"),
            "coverage runs should write a text summary and a machine-readable-ish LCOV report"
        )

        assertTrue(
            contents.contains("--filter") && contents.contains("--list"),
            "fast tests should expose a single-suite --filter selector and a --list of known entries"
        )

        let appSources = fastCoverageContractAppSourcePaths(contents)
        assertFalse(
            appSources.isEmpty,
            "fast-test runner should still list app sources in the APP_SOURCES block"
        )

        for path in appSources {
            assertTrue(
                fastCoverageContractRepoFileExists(path),
                "APP_SOURCES references a file that no longer exists on disk: \(path)"
            )
        }

        var seen = Set<String>()
        var duplicate: String? = nil
        for path in appSources where duplicate == nil {
            if seen.contains(path) {
                duplicate = path
            }
            seen.insert(path)
        }
        assertNil(
            duplicate,
            "APP_SOURCES should not list the same Sources/*.swift path twice"
        )
    }
}

// Pull every quoted Sources/*.swift path out of the APP_SOURCES=( ... ) block so
// the test fails when a renamed/deleted source is left stale in the runner.
private func fastCoverageContractAppSourcePaths(_ scriptContents: String) -> [String] {
    guard let blockStart = scriptContents.range(of: "APP_SOURCES=(") else {
        return []
    }
    let afterStart = scriptContents[blockStart.upperBound...]
    guard let blockEnd = afterStart.range(of: ")") else {
        return []
    }
    let block = String(afterStart[..<blockEnd.lowerBound])

    var paths: [String] = []
    for rawLine in block.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("\"") else { continue }
        let withoutLeadingQuote = line.dropFirst()
        guard let closingQuote = withoutLeadingQuote.firstIndex(of: "\"") else { continue }
        let path = String(withoutLeadingQuote[..<closingQuote])
        guard path.hasPrefix("Sources/") && path.hasSuffix(".swift") else { continue }
        paths.append(path)
    }
    return paths
}

private func fastCoverageContractRepoFileExists(_ relativePath: String) -> Bool {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(relativePath)
    return FileManager.default.fileExists(atPath: url.path)
}

private func fastCoverageContractReadRepoTextFile(_ relativePath: String) -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}
