// DictationFastStartLaunchTests.swift
// Where the fast path's mic open starts, and which handle it leaves behind
// for a key release to read.

import Foundation

@MainActor
func testDictationFastStartLaunch() async {
    runSuite("An open that finishes in this turn leaves no start handle") {
        // The borrowed-meeting-mic shape: the open never suspends and its
        // success tail already cleared the handle.
        var events: [String] = []
        let handle = DictationFastStartLaunch.start(opensInThisTurn: true) {
            events.append("mic open")
        }
        assertEqual(events, ["mic open"], "the open ran before launch returned")
        assertNil(handle, "a finished open must not be kept as an in-flight start")
        assertEqual(
            DictationRecordingStartLifecyclePolicy.stopDecision(
                isLoadingOverlay: false,
                isListeningOverlay: true,
                hasStartupTask: false,
                hasRecordingStartTask: handle != nil,
                sttIsRecording: false
            ),
            .stopRecording,
            "a release after a finished start stops the take, it doesn't cancel a pending start"
        )
    }

    await runSuite("An open that suspends starts now and keeps its handle until it lands") {
        let gate = OpenGate()
        var events: [String] = []
        let handle = DictationFastStartLaunch.start(opensInThisTurn: true) {
            events.append("mic open requested")
            await gate.wait()
            events.append("mic open finished")
        }
        assertEqual(events, ["mic open requested"], "the open's first step ran in this turn")
        assertNotNil(handle)
        assertEqual(
            DictationRecordingStartLifecyclePolicy.stopDecision(
                isLoadingOverlay: false,
                isListeningOverlay: false,
                hasStartupTask: false,
                hasRecordingStartTask: handle != nil,
                sttIsRecording: false
            ),
            .cancelPendingStart,
            "a release while the mic opens cancels the pending start"
        )
        gate.open()
        await handle?.value
        assertEqual(events, ["mic open requested", "mic open finished"])
    }

    await runSuite("Gated off, the open waits for a later turn and keeps its handle") {
        var events: [String] = []
        let handle = DictationFastStartLaunch.start(opensInThisTurn: false) {
            events.append("mic open")
        }
        assertEqual(events, [], "the meeting-mic, first-start and cold-model opens stay deferred")
        assertNotNil(handle)
        await handle?.value
        assertEqual(events, ["mic open"])
    }
}

@MainActor
private final class OpenGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
