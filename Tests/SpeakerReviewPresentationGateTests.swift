import Foundation

func testSpeakerReviewPresentationGate() {
    runSuite("SpeakerReviewPresentationGate shows a review right away when nothing is recording") {
        var gate = SpeakerReviewPresentationGate()
        let id = UUID()
        assertEqual(gate.requestChanged(to: id), .present(id))
        assertFalse(gate.isHoldingReview, "a shown review is not held")
        assertEqual(gate.requestChanged(to: id), .none, "the same request should not present twice")
        assertEqual(gate.requestChanged(to: nil), .dismiss, "clearing the request should close the window")
    }

    runSuite("SpeakerReviewPresentationGate holds a review until the next recording stops") {
        var gate = SpeakerReviewPresentationGate()
        assertEqual(gate.meetingCaptureChanged(isActive: true), .none)
        let id = UUID()
        assertEqual(gate.requestChanged(to: id), .none, "a review must not land on top of a live call")
        assertTrue(gate.isHoldingReview, "the review should be waiting")
        assertEqual(gate.meetingCaptureChanged(isActive: false), .present(id), "stopping should show the held review")
        assertFalse(gate.isHoldingReview)
        assertEqual(gate.meetingCaptureChanged(isActive: false), .none, "a repeat stop should not present again")
    }

    runSuite("SpeakerReviewPresentationGate keeps an open window open when a new call starts") {
        var gate = SpeakerReviewPresentationGate()
        let first = UUID()
        assertEqual(gate.requestChanged(to: first), .present(first))
        assertEqual(gate.meetingCaptureChanged(isActive: true), .none, "starting a call must not yank a window the user may be typing in")
        let second = UUID()
        assertEqual(
            gate.requestChanged(to: second),
            .present(second),
            "with a window already up, the next review replaces it in place"
        )
    }

    runSuite("SpeakerReviewPresentationGate forgets a closed review") {
        var gate = SpeakerReviewPresentationGate()
        let id = UUID()
        assertEqual(gate.requestChanged(to: id), .present(id))
        gate.windowClosed(requestID: id)
        assertNil(gate.presentedRequestID)
        assertNil(gate.currentRequestID, "a closed review is finished")
        assertEqual(gate.meetingCaptureChanged(isActive: true), .none)
        assertEqual(gate.meetingCaptureChanged(isActive: false), .none, "a closed review must not come back after the next call")
        assertEqual(gate.requestChanged(to: nil), .none, "a late clear after close has nothing to dismiss")
    }

    runSuite("SpeakerReviewPresentationGate ignores a replaced window closing") {
        var gate = SpeakerReviewPresentationGate()
        let first = UUID()
        let second = UUID()
        _ = gate.requestChanged(to: first)
        _ = gate.requestChanged(to: second)
        gate.windowClosed(requestID: first)
        assertEqual(gate.presentedRequestID, second, "the old window closing must not forget its replacement")
        assertEqual(gate.currentRequestID, second)
    }

    runSuite("SpeakerReviewPresentationCopy names the meeting") {
        assertEqual(SpeakerReviewPresentationCopy.title(meetingTitle: "Weekly sync"), "Review speakers · Weekly sync")
        assertEqual(SpeakerReviewPresentationCopy.title(meetingTitle: " "), "Review meeting speakers")
        assertEqual(SpeakerReviewPresentationCopy.title(meetingTitle: nil), "Review meeting speakers")
        assertTrue(
            SpeakerReviewPresentationCopy.subtitle.contains("Speakers page"),
            "the subtitle should name the real page"
        )
        assertFalse(
            SpeakerReviewPresentationCopy.subtitle.contains("Settings > People"),
            "there is no People page"
        )
    }
}
