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

    runSuite("DictationReadinessWaitPolicy — forces recovery after repeated unready refreshes") {
        let action = DictationReadinessWaitPolicy.action(
            isRecovering: false,
            inputFormatReady: false,
            readinessRefreshes: 6,
            forcedRecoveryAttempts: 0,
            forcedRecoveryRefreshThreshold: 6,
            maxForcedRecoveryAttempts: 2,
            recoveryStartAttempts: 1
        )

        assertEqual(action, .forceInputRecovery, "repeated unready refreshes should force a hard input recovery after the bounded recovery start path")
    }

    runSuite("DictationReadinessWaitPolicy — forced recovery budget falls back to refresh") {
        let action = DictationReadinessWaitPolicy.action(
            isRecovering: false,
            inputFormatReady: false,
            readinessRefreshes: 6,
            forcedRecoveryAttempts: 2,
            forcedRecoveryRefreshThreshold: 6,
            maxForcedRecoveryAttempts: 2,
            recoveryStartAttempts: 1
        )

        assertEqual(action, .refreshInputReadiness, "forced recovery should stay bounded inside a single dictation wait")
    }

    runSuite("DictationReadinessWaitPolicy — active recovery wins over forced recovery threshold") {
        let action = DictationReadinessWaitPolicy.action(
            isRecovering: true,
            inputFormatReady: false,
            readinessRefreshes: 6,
            forcedRecoveryAttempts: 0,
            forcedRecoveryRefreshThreshold: 6,
            maxForcedRecoveryAttempts: 2,
            recoveryStartAttempts: 1
        )

        assertEqual(action, .waitForRecovery, "active device recovery should not be interrupted by the forced recovery threshold")
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

    runSuite("DictationReadinessWaitPolicy — timed-out readiness refresh gets one recovery start") {
        let action = DictationReadinessWaitPolicy.action(
            isRecovering: false,
            inputFormatReady: false,
            readinessRefreshes: 1,
            recoveryStartAttempts: 0,
            readinessRefreshTimedOut: true
        )

        assertEqual(action, .startRecoveryRecording, "one stale readiness refresh should unblock the guarded recovery start")
    }

    runSuite("DictationReadinessWaitPolicy — recovery start is bounded") {
        let action = DictationReadinessWaitPolicy.action(
            isRecovering: false,
            inputFormatReady: false,
            readinessRefreshes: 4,
            recoveryStartAttempts: 1
        )

        assertEqual(action, .refreshInputReadiness, "after one recovery start attempt the loop should go back to readiness refreshes")
    }

    runSuite("DictationReadinessWaitPolicy — timed-out refresh recovery start is bounded") {
        let action = DictationReadinessWaitPolicy.action(
            isRecovering: false,
            inputFormatReady: false,
            readinessRefreshes: 1,
            recoveryStartAttempts: 1,
            readinessRefreshTimedOut: true
        )

        assertEqual(action, .refreshInputReadiness, "a timed-out refresh should not loop recovery starts forever")
    }

    runSuite("DictationReadinessRefreshTimeoutPolicy — active refresh stays live before timeout") {
        let timedOut = DictationReadinessRefreshTimeoutPolicy.timedOut(
            startedAt: 10.0,
            now: 10.89,
            timeout: 0.9
        )

        assertFalse(timedOut, "refresh should not time out before the timeout window")
    }

    runSuite("DictationReadinessRefreshTimeoutPolicy — stale refresh times out at timeout") {
        let timedOut = DictationReadinessRefreshTimeoutPolicy.timedOut(
            startedAt: 10.0,
            now: 10.9,
            timeout: 0.9
        )

        assertTrue(timedOut, "refresh should time out once it reaches the timeout window")
    }

    runSuite("DictationReadinessRefreshTimeoutPolicy — missing start never times out") {
        let timedOut = DictationReadinessRefreshTimeoutPolicy.timedOut(
            startedAt: nil,
            now: 10.9,
            timeout: 0.9
        )

        assertFalse(timedOut, "no active refresh should not be treated as timed out")
    }
}
