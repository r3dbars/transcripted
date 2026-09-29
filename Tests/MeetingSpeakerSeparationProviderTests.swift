import Foundation

/// Promise: each meeting's speaker separation is picked for the diarization
/// backend that is running when the meeting is transcribed, not the one the app
/// asked for at launch. When Nemotron fails to load and pyannote stands in, the
/// meeting gets pyannote's settings.
func testMeetingSpeakerSeparationProvider() async {
    final class BackendBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: DiarizationBackend
        init(_ value: DiarizationBackend) { self.value = value }
        var backend: DiarizationBackend {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    await runSuite("MeetingSpeakerSeparationProvider uses the backend that is running at each meeting") {
        let active = BackendBox(.nemotron)
        let provider = MeetingSpeakerSeparationProvider.make(
            activeBackend: { active.backend }
        ) { backend, _ in
            backend
        }

        let beforeFallback = await provider(nil)
        assertEqual(beforeFallback, .nemotron, "while Nemotron runs, meetings get Nemotron's settings")

        // Nemotron failed to load after the provider was built; pyannote diarizes now.
        active.backend = .pyannote
        let afterFallback = await provider(nil)
        assertEqual(afterFallback, .pyannote, "a pyannote meeting must not get Nemotron-tuned separation")
    }

    await runSuite("MeetingSpeakerSeparationProvider passes the meeting's recording date through") {
        let recordingDate = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = MeetingSpeakerSeparationProvider.make(
            activeBackend: { .nemotron }
        ) { _, date in
            date
        }

        let passed = await provider(recordingDate)
        assertEqual(passed ?? nil, recordingDate, "the calendar lookup needs the meeting's own start")
        let importedPassed = await provider(nil)
        assertNil(importedPassed ?? nil, "an import has no recording date to look up")
    }
}
