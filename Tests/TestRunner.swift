// TestRunner.swift
// Entry point for the test suite

import Foundation

@main
struct TestRunner {
    static func main() {
        print("Transcripted Fast Test Suite\n")

        testCapturedContext()
        testRefusalDetection()
        testStyleUtils()
        testDiffSummary()
        testMeetingTranscriptStyler()
        testSpeakerNamingPolicy()
        testDictationTranscriptWriter()
        testDictationAgentOutput()
        testDictationSounds()

        print("\n\(totalTests) tests, \(passedTests) passed, \(failedTests) failed")
        if failedTests > 0 {
            print("FAILED")
            exit(1)
        } else {
            print("ALL TESTS PASSED")
        }
    }
}
