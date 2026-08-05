import Foundation

func testSharedMeetingMicClaim() {
    runSuite("SharedMeetingMicClaimPolicy.isSharingActive — current claim reports sharing active") {
        assertTrue(
            SharedMeetingMicClaimPolicy.isSharingActive(.current),
            "a claim whose meeting session reports itself alive must read as actively sharing"
        )
    }

    runSuite("SharedMeetingMicClaimPolicy.isSharingActive — stale claim reports sharing inactive") {
        assertFalse(
            SharedMeetingMicClaimPolicy.isSharingActive(.stale),
            "a claim orphaned by a dead meeting session must read identically to no claim at all"
        )
    }

    runSuite("SharedMeetingMicClaimPolicy.isSharingActive — absent claim reports sharing inactive") {
        assertFalse(
            SharedMeetingMicClaimPolicy.isSharingActive(.absent),
            "no claim on file must read as not sharing"
        )
    }

    runSuite("SharedMeetingMicClaimStatus — three distinct, stable cases") {
        assertTrue(
            SharedMeetingMicClaimStatus.absent != .current && SharedMeetingMicClaimStatus.current != .stale
                && SharedMeetingMicClaimStatus.absent != .stale,
            "absent/current/stale must remain three independently distinguishable cases"
        )
    }

    runSuite("SharedMeetingMicClaimPolicy.isClaimSessionAlive — same identity, active session reads alive") {
        let identity = UUID()
        assertTrue(
            SharedMeetingMicClaimPolicy.isClaimSessionAlive(
                mintedIdentity: identity,
                currentIdentity: identity,
                isCaptureSessionActive: true
            ),
            "a claim minted for the currently active session must read alive"
        )
    }

    runSuite("SharedMeetingMicClaimPolicy.isClaimSessionAlive — active session but a DIFFERENT identity reads stale") {
        // Exactly the race Codex flagged on PR #1642: an unexpected stop
        // schedules an async resume for meeting A, a brand-new meeting B
        // starts (fresh identity) before that resume runs, and B's capture
        // pipeline is genuinely active. Meeting A's orphaned claim must NOT
        // read as alive just because *some* recording happens to be active
        // again — otherwise recovery stays suppressed and B's mic relay
        // feeds A's already-finished recorder.
        let mintedForMeetingA = UUID()
        let currentlyRecordingMeetingB = UUID()
        assertFalse(
            SharedMeetingMicClaimPolicy.isClaimSessionAlive(
                mintedIdentity: mintedForMeetingA,
                currentIdentity: currentlyRecordingMeetingB,
                isCaptureSessionActive: true
            ),
            "a claim from a superseded recording must resolve stale even though a different recording is active"
        )
    }

    runSuite("SharedMeetingMicClaimPolicy.isClaimSessionAlive — same identity but inactive session reads stale") {
        let identity = UUID()
        assertFalse(
            SharedMeetingMicClaimPolicy.isClaimSessionAlive(
                mintedIdentity: identity,
                currentIdentity: identity,
                isCaptureSessionActive: false
            ),
            "identity matching alone is not enough — the session must also report itself active"
        )
    }

    runSuite("SharedMeetingMicClaimPolicy.isClaimSessionAlive — no current recording (nil identity) reads stale") {
        assertFalse(
            SharedMeetingMicClaimPolicy.isClaimSessionAlive(
                mintedIdentity: UUID(),
                currentIdentity: nil,
                isCaptureSessionActive: false
            ),
            "between recordings there is no current identity to match, so any claim reads stale"
        )
    }

    runSuite("wake guard composition — current claim skips teardown, stale/absent do not") {
        assertEqual(
            ParakeetSystemWakePolicy.decision(
                sharedMeetingMicRecording: SharedMeetingMicClaimPolicy.isSharingActive(.current)
            ),
            .skipSharedMeetingMic,
            "a live claim must still make wake defer to meeting-owned recovery"
        )
        assertEqual(
            ParakeetSystemWakePolicy.decision(
                sharedMeetingMicRecording: SharedMeetingMicClaimPolicy.isSharingActive(.stale)
            ),
            .tearDownAudioGraph,
            "a stale claim must not suppress dictation's own wake recovery forever"
        )
        assertEqual(
            ParakeetSystemWakePolicy.decision(
                sharedMeetingMicRecording: SharedMeetingMicClaimPolicy.isSharingActive(.absent)
            ),
            .tearDownAudioGraph,
            "no claim must behave exactly like the pre-handshake unshared case"
        )
    }
}
