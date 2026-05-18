import AVFoundation
import Foundation

func testParakeetPrewarmPolicy() {
    runSuite("ParakeetPrewarmPolicy.decision — authorized microphone can prewarm") {
        let decision = ParakeetPrewarmPolicy.decision(for: .authorized)

        assertEqual(decision, .proceed, "authorized microphone access should allow prewarm")
    }

    runSuite("ParakeetPrewarmPolicy.decision — pending permission skips prewarm without an error") {
        let decision = ParakeetPrewarmPolicy.decision(for: .notDetermined)

        assertEqual(
            decision,
            .skip(
                level: .info,
                event: "prewarm_permission_pending",
                message: "Skipping speech engine prewarm until microphone permission is decided",
                context: ["mic_status": "not_determined"]
            ),
            "pending permission should defer prewarm until the user answers the prompt"
        )
    }

    runSuite("ParakeetPrewarmPolicy.decision — denied permission skips prewarm with a warning") {
        let decision = ParakeetPrewarmPolicy.decision(for: .denied)

        assertEqual(
            decision,
            .skip(
                level: .warning,
                event: "prewarm_permission_unavailable",
                message: "Skipping speech engine prewarm because microphone permission is unavailable",
                context: ["mic_status": "denied"]
            ),
            "missing microphone access should stop prewarm from surfacing as a startup failure"
        )
    }

    runSuite("ParakeetPrewarmPolicy.decision — restricted permission reports the concrete status") {
        let decision = ParakeetPrewarmPolicy.decision(for: .restricted)

        assertEqual(
            decision,
            .skip(
                level: .warning,
                event: "prewarm_permission_unavailable",
                message: "Skipping speech engine prewarm because microphone permission is unavailable",
                context: ["mic_status": "restricted"]
            ),
            "restricted microphone access should be warning-level but privacy-safe"
        )
    }
}
