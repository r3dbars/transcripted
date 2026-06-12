import Foundation

func testMeetingPillRestPolicy() {
    runSuite("MeetingPillRestPolicy — countdown only runs for an unattended bare pill") {
        assertTrue(
            MeetingPillRestPolicy.canRest(
                isRecording: true,
                isTranscriptVisible: false,
                keepControlsVisible: false,
                isHovered: false
            ),
            "an idle recording pill should rest down to the capsule"
        )
        assertFalse(
            MeetingPillRestPolicy.canRest(
                isRecording: false,
                isTranscriptVisible: false,
                keepControlsVisible: false,
                isHovered: false
            ),
            "no recording means nothing to rest"
        )
        assertFalse(
            MeetingPillRestPolicy.canRest(
                isRecording: true,
                isTranscriptVisible: true,
                keepControlsVisible: false,
                isHovered: false
            ),
            "an open transcript means the user is watching — never rest under them"
        )
        assertFalse(
            MeetingPillRestPolicy.canRest(
                isRecording: true,
                isTranscriptVisible: false,
                keepControlsVisible: true,
                isHovered: false
            ),
            "the pin is the explicit opt-out of auto-resting"
        )
        assertFalse(
            MeetingPillRestPolicy.canRest(
                isRecording: true,
                isTranscriptVisible: false,
                keepControlsVisible: false,
                isHovered: true
            ),
            "a hovered pill is being attended to"
        )
    }

    runSuite("MeetingPillRestPolicy — hover blooms a resting pill without clearing the rest state") {
        assertTrue(
            MeetingPillRestPolicy.isCondensedRendered(
                isResting: true,
                isRecording: true,
                isTranscriptVisible: false,
                isHovered: false
            ),
            "a resting unattended pill renders as the capsule"
        )
        assertFalse(
            MeetingPillRestPolicy.isCondensedRendered(
                isResting: true,
                isRecording: true,
                isTranscriptVisible: false,
                isHovered: true
            ),
            "hovering a resting pill blooms the full strip"
        )
        assertFalse(
            MeetingPillRestPolicy.isCondensedRendered(
                isResting: false,
                isRecording: true,
                isTranscriptVisible: false,
                isHovered: false
            ),
            "a pill that never rested renders full"
        )
        assertFalse(
            MeetingPillRestPolicy.isCondensedRendered(
                isResting: true,
                isRecording: true,
                isTranscriptVisible: true,
                isHovered: false
            ),
            "an open transcript always renders the full strip"
        )
        assertFalse(
            MeetingPillRestPolicy.isCondensedRendered(
                isResting: true,
                isRecording: false,
                isTranscriptVisible: false,
                isHovered: false
            ),
            "non-recording states never render the capsule"
        )
    }

    runSuite("MeetingPillRestPolicy — rest delay leaves time to reach the controls") {
        assertTrue(
            MeetingPillRestPolicy.restDelaySeconds >= 4,
            "resting too aggressively makes the pill feel like it is fleeing the cursor"
        )
    }
}
