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
    }
}

private func fastCoverageContractReadRepoTextFile(_ relativePath: String) -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}
