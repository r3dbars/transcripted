import Foundation

// 2026-08 meeting-state-collapse audit: MeetingSessionStateMachine is the
// pure, dependency-free rules layer over MeetingSessionState (aka
// MeetingSessionController.State). These tests exercise the legal-transition
// table and the two "what is the meeting doing right now" query functions
// directly, without needing to construct a real MeetingSessionController.

func testMeetingSessionStateMachine() {
    runSuite("MeetingSessionStateMachine.isLegalTransition — every state may transition to itself") {
        let allStates: [MeetingSessionState] = [
            .idle, .loadingModels, .ready, .startingRecording, .recording,
            .stoppingRecording, .transcribing, .error("boom"),
        ]
        for state in allStates {
            assertTrue(
                MeetingSessionStateMachine.isLegalTransition(from: state, to: state),
                "\(state) should be able to transition to itself (idempotent no-op)"
            )
        }
    }

    runSuite("MeetingSessionStateMachine.isLegalTransition — every state may transition to .error") {
        let allStates: [MeetingSessionState] = [
            .idle, .loadingModels, .ready, .startingRecording, .recording,
            .stoppingRecording, .transcribing,
        ]
        for state in allStates {
            assertTrue(
                MeetingSessionStateMachine.isLegalTransition(from: state, to: .error("boom")),
                "\(state) -> .error should always be legal — error reporting must never be blocked"
            )
        }
    }

    runSuite("MeetingSessionStateMachine.isLegalTransition — the recording lifecycle is a straight line") {
        assertTrue(
            MeetingSessionStateMachine.isLegalTransition(from: .ready, to: .startingRecording),
            "recording starts from ready"
        )
        assertTrue(
            MeetingSessionStateMachine.isLegalTransition(from: .startingRecording, to: .recording),
            "capture confirms recording"
        )
        assertTrue(
            MeetingSessionStateMachine.isLegalTransition(from: .recording, to: .stoppingRecording),
            "stop/cancel/termination begins teardown"
        )
        assertTrue(
            MeetingSessionStateMachine.isLegalTransition(from: .stoppingRecording, to: .transcribing),
            "stop completes with mic audio and enqueues transcription"
        )
        assertTrue(
            MeetingSessionStateMachine.isLegalTransition(from: .stoppingRecording, to: .ready),
            "cancel completes with no background work left"
        )
        assertTrue(
            MeetingSessionStateMachine.isLegalTransition(from: .transcribing, to: .ready),
            "the transcription queue drains with no failure"
        )
    }

    runSuite("MeetingSessionStateMachine.isLegalTransition — recording cannot be skipped into") {
        assertFalse(
            MeetingSessionStateMachine.isLegalTransition(from: .idle, to: .recording),
            "recording must go through startingRecording, not be entered directly from idle"
        )
        assertFalse(
            MeetingSessionStateMachine.isLegalTransition(from: .ready, to: .recording),
            "recording must go through startingRecording, not be entered directly from ready"
        )
        assertFalse(
            MeetingSessionStateMachine.isLegalTransition(from: .loadingModels, to: .startingRecording),
            "a recording cannot start while still loading models"
        )
    }

    runSuite("MeetingSessionStateMachine.isLegalTransition — a new recording can start while an earlier one is still transcribing") {
        assertTrue(
            MeetingSessionStateMachine.isLegalTransition(from: .transcribing, to: .startingRecording),
            "startRecording()'s own entry switch allows starting from .transcribing (an earlier meeting's background job doesn't block a new recording)"
        )
    }

    runSuite("MeetingSessionStateMachine.isLegalTransition — jobs can start transcribing before models were ever prepared") {
        assertTrue(
            MeetingSessionStateMachine.isLegalTransition(from: .idle, to: .transcribing),
            "a recovered/imported job queued at launch can start before prepareModels() has run once"
        )
    }

    runSuite("MeetingSessionStateMachine.isLegalTransition — an import cancellation can land back on idle") {
        assertTrue(
            MeetingSessionStateMachine.isLegalTransition(from: .idle, to: .ready),
            "a concurrent flow (e.g. a model-selection reset) can move state back to idle while an import cancellation is resolving"
        )
    }

    runSuite("MeetingSessionStateMachine.isCaptureSessionActive — true through the whole capture window") {
        assertTrue(MeetingSessionStateMachine.isCaptureSessionActive(.startingRecording))
        assertTrue(MeetingSessionStateMachine.isCaptureSessionActive(.recording))
        assertTrue(MeetingSessionStateMachine.isCaptureSessionActive(.stoppingRecording))
    }

    runSuite("MeetingSessionStateMachine.isCaptureSessionActive — false outside the capture window") {
        assertFalse(MeetingSessionStateMachine.isCaptureSessionActive(.idle))
        assertFalse(MeetingSessionStateMachine.isCaptureSessionActive(.loadingModels))
        assertFalse(MeetingSessionStateMachine.isCaptureSessionActive(.ready))
        assertFalse(MeetingSessionStateMachine.isCaptureSessionActive(.transcribing))
        assertFalse(MeetingSessionStateMachine.isCaptureSessionActive(.error("boom")))
    }

    runSuite("MeetingSessionStateMachine.isSteadyStateRecording — true only for .recording") {
        assertTrue(MeetingSessionStateMachine.isSteadyStateRecording(.recording))
        assertFalse(MeetingSessionStateMachine.isSteadyStateRecording(.startingRecording))
        assertFalse(MeetingSessionStateMachine.isSteadyStateRecording(.stoppingRecording))
        assertFalse(MeetingSessionStateMachine.isSteadyStateRecording(.idle))
        assertFalse(MeetingSessionStateMachine.isSteadyStateRecording(.ready))
        assertFalse(MeetingSessionStateMachine.isSteadyStateRecording(.transcribing))
        assertFalse(MeetingSessionStateMachine.isSteadyStateRecording(.error("boom")))
    }

    runSuite("MeetingSessionStateMachine.mayReportUnrelatedFailureAsError — blocked while capture is live") {
        assertFalse(
            MeetingSessionStateMachine.mayReportUnrelatedFailureAsError(while: .startingRecording),
            "an unrelated failure (import rejection, a different queued job's prepare failure) must not stomp the mic-engage window"
        )
        assertFalse(
            MeetingSessionStateMachine.mayReportUnrelatedFailureAsError(while: .recording),
            "an unrelated failure must not stomp an active recording — that would silently clear quit-confirm/dictation-block/mic-share/menubar gates for a capture still physically running"
        )
        assertFalse(
            MeetingSessionStateMachine.mayReportUnrelatedFailureAsError(while: .stoppingRecording),
            "an unrelated failure must not stomp a capture that is still tearing down"
        )
    }

    runSuite("MeetingSessionStateMachine.mayReportUnrelatedFailureAsError — allowed outside the capture window") {
        assertTrue(MeetingSessionStateMachine.mayReportUnrelatedFailureAsError(while: .idle))
        assertTrue(MeetingSessionStateMachine.mayReportUnrelatedFailureAsError(while: .loadingModels))
        assertTrue(MeetingSessionStateMachine.mayReportUnrelatedFailureAsError(while: .ready))
        assertTrue(MeetingSessionStateMachine.mayReportUnrelatedFailureAsError(while: .transcribing))
    }
}
