import Foundation

func testMeetingPillRestPolicy() {
    runSuite("MeetingPillRestPolicy — countdown only runs for an unattended bare pill") {
        assertTrue(
            MeetingPillRestPolicy.canRest(
                isRecording: true,
                keepControlsVisible: false,
                isHovered: false,
                hasSystemAudioWarning: false
            ),
            "an idle recording pill should rest down to the capsule"
        )
        assertFalse(
            MeetingPillRestPolicy.canRest(
                isRecording: false,
                keepControlsVisible: false,
                isHovered: false,
                hasSystemAudioWarning: false
            ),
            "no recording means nothing to rest"
        )
        assertFalse(
            MeetingPillRestPolicy.canRest(
                isRecording: true,
                keepControlsVisible: true,
                isHovered: false,
                hasSystemAudioWarning: false
            ),
            "the pin is the explicit opt-out of auto-resting"
        )
        assertFalse(
            MeetingPillRestPolicy.canRest(
                isRecording: true,
                keepControlsVisible: false,
                isHovered: true,
                hasSystemAudioWarning: false
            ),
            "a hovered pill is being attended to"
        )
        assertTrue(
            MeetingPillRestPolicy.canRest(
                isRecording: true,
                keepControlsVisible: false,
                isHovered: false,
                hasSystemAudioWarning: true
            ),
            "a diagnostic system-audio latch must not hold the normal recorder open"
        )
    }

    runSuite("MeetingPillRestPolicy — capsule rendering follows the resting state, not hover") {
        assertTrue(
            MeetingPillRestPolicy.isCondensedRendered(
                isResting: true,
                isRecording: true,
                hasSystemAudioWarning: false
            ),
            "a resting pill renders as the capsule"
        )
        assertFalse(
            MeetingPillRestPolicy.isCondensedRendered(
                isResting: false,
                isRecording: true,
                hasSystemAudioWarning: false
            ),
            "an awake pill renders full — hover wakes by clearing the resting state, not by overriding rendering"
        )
        assertFalse(
            MeetingPillRestPolicy.isCondensedRendered(
                isResting: true,
                isRecording: false,
                hasSystemAudioWarning: false
            ),
            "non-recording states never render the capsule"
        )
        assertTrue(
            MeetingPillRestPolicy.isCondensedRendered(
                isResting: true,
                isRecording: true,
                hasSystemAudioWarning: true
            ),
            "a diagnostic system-audio latch must not replace the compact timer"
        )
    }

    runSuite("MeetingPillRestPolicy — rest delay leaves time to reach the controls") {
        assertTrue(
            MeetingPillRestPolicy.restDelaySeconds >= 4,
            "resting too aggressively makes the pill feel like it is fleeing the cursor"
        )
    }
}
