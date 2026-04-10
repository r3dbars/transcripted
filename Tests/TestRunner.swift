// TestRunner.swift
// Entry point for the test suite

import Foundation

@main
struct TestRunner {
    static func main() async {
        print("Draft Test Suite\n")

        testCapturedContext()
        testRefusalDetection()
        testStyleUtils()
        testDiffSummary()
        testMeetingTranscriptStyler()
        testDictationTranscriptWriter()
        testDictationSessionTimeout()
        testMicRecordingMergePlan()
        await testWakeRecoveryCoordinator()

        print("\n\(totalTests) tests, \(passedTests) passed, \(failedTests) failed")
        if failedTests > 0 {
            print("FAILED")
            exit(1)
        } else {
            print("ALL TESTS PASSED")
        }
    }
}
