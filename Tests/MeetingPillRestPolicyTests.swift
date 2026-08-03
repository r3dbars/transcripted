import Foundation

func testMeetingPillRestPolicy() {
    runSuite("MeetingPillRestPolicy — countdown only runs for an unattended bare pill") {
        assertTrue(
            MeetingPillRestPolicy.canRest(
                isRecording: true,
                isTranscriptVisible: false,
                keepControlsVisible: false,
                isHovered: false,
                hasSystemAudioWarning: false
            ),
            "an idle recording pill should rest down to the capsule"
        )
        assertFalse(
            MeetingPillRestPolicy.canRest(
                isRecording: false,
                isTranscriptVisible: false,
                keepControlsVisible: false,
                isHovered: false,
                hasSystemAudioWarning: false
            ),
            "no recording means nothing to rest"
        )
        assertFalse(
            MeetingPillRestPolicy.canRest(
                isRecording: true,
                isTranscriptVisible: true,
                keepControlsVisible: false,
                isHovered: false,
                hasSystemAudioWarning: false
            ),
            "an open transcript means the user is watching — never rest under them"
        )
        assertFalse(
            MeetingPillRestPolicy.canRest(
                isRecording: true,
                isTranscriptVisible: false,
                keepControlsVisible: true,
                isHovered: false,
                hasSystemAudioWarning: false
            ),
            "the pin is the explicit opt-out of auto-resting"
        )
        assertFalse(
            MeetingPillRestPolicy.canRest(
                isRecording: true,
                isTranscriptVisible: false,
                keepControlsVisible: false,
                isHovered: true,
                hasSystemAudioWarning: false
            ),
            "a hovered pill is being attended to"
        )
        assertFalse(
            MeetingPillRestPolicy.canRest(
                isRecording: true,
                isTranscriptVisible: false,
                keepControlsVisible: false,
                isHovered: false,
                hasSystemAudioWarning: true
            ),
            "system-audio trouble must stay expanded as readable text"
        )
    }

    runSuite("MeetingPillRestPolicy — capsule rendering follows the resting state, not hover") {
        assertTrue(
            MeetingPillRestPolicy.isCondensedRendered(
                isResting: true,
                isRecording: true,
                isTranscriptVisible: false,
                hasSystemAudioWarning: false
            ),
            "a resting pill renders as the capsule"
        )
        assertFalse(
            MeetingPillRestPolicy.isCondensedRendered(
                isResting: false,
                isRecording: true,
                isTranscriptVisible: false,
                hasSystemAudioWarning: false
            ),
            "an awake pill renders full — hover wakes by clearing the resting state, not by overriding rendering"
        )
        assertFalse(
            MeetingPillRestPolicy.isCondensedRendered(
                isResting: true,
                isRecording: true,
                isTranscriptVisible: true,
                hasSystemAudioWarning: false
            ),
            "an open transcript always renders the full strip"
        )
        assertFalse(
            MeetingPillRestPolicy.isCondensedRendered(
                isResting: true,
                isRecording: false,
                isTranscriptVisible: false,
                hasSystemAudioWarning: false
            ),
            "non-recording states never render the capsule"
        )
        assertFalse(
            MeetingPillRestPolicy.isCondensedRendered(
                isResting: true,
                isRecording: true,
                isTranscriptVisible: false,
                hasSystemAudioWarning: true
            ),
            "a latched warning must bloom from rest and remain readable"
        )
    }

    runSuite("MeetingPillRestPolicy — rest delay leaves time to reach the controls") {
        assertTrue(
            MeetingPillRestPolicy.restDelaySeconds >= 4,
            "resting too aggressively makes the pill feel like it is fleeing the cursor"
        )
    }
}
