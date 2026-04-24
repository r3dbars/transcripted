// DictationReadinessWaitPolicyTests.swift

import Foundation

func testDictationReadinessWaitPolicy() {
    runSuite("DictationReadinessWaitPolicy — waits while recovery is active") {
        let action = DictationReadinessWaitPolicy.action(
            isRecovering: true,
            inputFormatReady: false
        )

        assertEqual(action, .waitForRecovery, "active recovery should not start or refresh")
    }

    runSuite("DictationReadinessWaitPolicy — refreshes after failed recovery leaves input unready") {
        let action = DictationReadinessWaitPolicy.action(
            isRecovering: false,
            inputFormatReady: false
        )

        assertEqual(action, .refreshInputReadiness, "failed recovery should trigger another readiness refresh")
    }

    runSuite("DictationReadinessWaitPolicy — starts recording when input is ready") {
        let action = DictationReadinessWaitPolicy.action(
            isRecovering: false,
            inputFormatReady: true
        )

        assertEqual(action, .startRecording, "ready input should start recording")
    }
}
