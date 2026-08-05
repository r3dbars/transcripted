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
