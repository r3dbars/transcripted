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

    runSuite("DictationReadinessWaitPolicy — recovery flag wins over stale ready flag") {
        let action = DictationReadinessWaitPolicy.action(
            isRecovering: true,
            inputFormatReady: true
        )

        assertEqual(action, .waitForRecovery, "active recovery should block recording even if a stale ready flag leaks through")
    }

    runSuite("DictationReadinessWaitPolicy — refreshes after failed recovery leaves input unready") {
        let action = DictationReadinessWaitPolicy.action(
            isRecovering: false,
            inputFormatReady: false,
            readinessRefreshes: 0,
            recoveryStartAttempts: 0
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

    runSuite("DictationReadinessWaitPolicy — stuck recovery timeout becomes refreshable") {
        var recovery = ParakeetRecoveryState()
        let generation = recovery.beginConfigChange()

        let stuckAction = DictationReadinessWaitPolicy.action(
            isRecovering: recovery.isRecovering,
            inputFormatReady: recovery.inputFormatReady
        )
        assertEqual(stuckAction, .waitForRecovery, "active recovery should match the Sentry stuck-recovery shape")

        assertTrue(recovery.timeoutRecovery(generation: generation), "timeout should apply to the active recovery")

        let postTimeoutAction = DictationReadinessWaitPolicy.action(
            isRecovering: recovery.isRecovering,
            inputFormatReady: recovery.inputFormatReady
        )
        assertEqual(postTimeoutAction, .refreshInputReadiness, "timeout should unblock dictation into a refresh path")
    }

    runSuite("DictationReadinessWaitPolicy — stale unready input gets one recovery start") {
        let action = DictationReadinessWaitPolicy.action(
            isRecovering: false,
            inputFormatReady: false,
            readinessRefreshes: 4,
            recoveryStartAttempts: 0
        )

        assertEqual(action, .startRecoveryRecording, "repeated stale readiness refreshes should force one guarded recovery start")
    }

    runSuite("DictationReadinessWaitPolicy — recovery start is bounded") {
        let action = DictationReadinessWaitPolicy.action(
            isRecovering: false,
            inputFormatReady: false,
            readinessRefreshes: 8,
            recoveryStartAttempts: 1
        )

        assertEqual(action, .refreshInputReadiness, "after one recovery start attempt the loop should go back to readiness refreshes")
    }
}
