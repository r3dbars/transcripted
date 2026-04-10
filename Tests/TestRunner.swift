// TestRunner.swift
// Entry point for the test suite

import Foundation

@main
struct TestRunner {
    static func main() {
        print("Draft Test Suite\n")

        testCapturedContext()
        testRefusalDetection()
        testStyleUtils()
        testDiffSummary()
        testMeetingTranscriptStyler()
        testDictationTranscriptWriter()
        testDictationSessionTimeout()

        print("\n\(totalTests) tests, \(passedTests) passed, \(failedTests) failed")
        if failedTests > 0 {
            print("FAILED")
            exit(1)
        } else {
            print("ALL TESTS PASSED")
        }
    }
}
