import Foundation

// Every meeting transcription entry point builds its request through
// MeetingTranscriptionRequestBuilder, which takes People-in-the-room from an
// injected preference. These suites flip that preference and check what each
// entry point would hand to the pipeline or the failed queue.

func testMeetingTranscriptionEntryPoint() {
    let micURL = URL(fileURLWithPath: "/synthetic/meeting_mic.wav")
    let systemURL = URL(fileURLWithPath: "/synthetic/meeting_system.wav")
    let transcriptURL = URL(fileURLWithPath: "/synthetic/meeting.md")
    let recordingDate = Date(timeIntervalSince1970: 1_800_000_000)

    runSuite("Saved-audio retranscribe takes People-in-the-room from the preference") {
        for enabled in [true, false] {
            let builder = MeetingTranscriptionRequestBuilder(localSpeakerPreference: { enabled })
            let request = builder.savedAudioRetranscription(
                micURL: micURL,
                systemURL: systemURL,
                meetingTitle: "Synthetic",
                replacementTranscriptURL: transcriptURL,
                recordingDate: recordingDate
            )
            assertEqual(request.options.splitLocalSpeakers, enabled, "retranscribe follows the setting (\(enabled))")
            assertEqual(request.micURL, micURL)
            assertEqual(request.systemURL, systemURL)
            assertEqual(request.replacementTranscriptURL, transcriptURL)
        }
    }

    runSuite("A live recording queued at Stop takes People-in-the-room from the preference") {
        for enabled in [true, false] {
            let builder = MeetingTranscriptionRequestBuilder(localSpeakerPreference: { enabled })
            let request = builder.recordedMeeting(
                micURL: micURL,
                systemURL: systemURL,
                meetingTitle: nil,
                recordingDate: recordingDate
            )
            assertEqual(request.options.splitLocalSpeakers, enabled, "live queue follows the setting (\(enabled))")
        }
    }

    runSuite("A queued job's failed-queue row keeps the People-in-the-room choice from enqueue") {
        for enabled in [true, false] {
            var preference = enabled
            let builder = MeetingTranscriptionRequestBuilder(localSpeakerPreference: { preference })
            let queued = builder.recordedMeeting(
                micURL: micURL,
                systemURL: systemURL,
                meetingTitle: "Synthetic",
                recordingDate: recordingDate
            )
            // The user flips the setting while the job waits; the row must
            // still run the way the meeting was queued.
            preference.toggle()
            let row = builder.failedQueueRow(
                forQueued: queued,
                errorMessage: "Transcription cancelled",
                languageSelection: .automatic,
                micOnlyByChoice: true
            )
            assertEqual(row.splitLocalSpeakers, enabled, "row keeps the enqueue snapshot (\(enabled))")
            assertEqual(row.micURL, micURL)
            assertEqual(row.systemURL, systemURL)
            assertEqual(row.recordingDate, recordingDate)
            assertTrue(row.micOnlyByChoice, "mic-only choice rides along with the row")
        }
    }

    runSuite("Imported audio's failed-queue row never splits the mic, whatever the preference") {
        let builder = MeetingTranscriptionRequestBuilder(localSpeakerPreference: { true })
        let row = builder.failedQueueRow(
            forImportedAudio: systemURL,
            suggestedTitle: "Imported",
            recordingDate: recordingDate,
            errorMessage: "Imported audio saved before cancellation.",
            languageSelection: .automatic
        )
        assertFalse(row.splitLocalSpeakers, "imports are one system-channel file")
        assertEqual(row.micURL, nil)
        assertEqual(row.systemURL, systemURL)
    }

    runSuite("A failed-queue row's People-in-the-room choice survives a save and reload") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-entrypoint-row-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for enabled in [true, false] {
            let builder = MeetingTranscriptionRequestBuilder(localSpeakerPreference: { enabled })
            let row = builder.failedQueueRow(
                forQueued: builder.recordedMeeting(
                    micURL: micURL,
                    systemURL: systemURL,
                    meetingTitle: "Synthetic",
                    recordingDate: recordingDate
                ),
                errorMessage: "Models not ready",
                languageSelection: .automatic,
                micOnlyByChoice: false
            )
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let stored = FailedTranscription(
                    recordingDate: row.recordingDate,
                    micAudioURL: row.micURL ?? systemURL,
                    systemAudioURL: row.systemURL,
                    errorMessage: row.errorMessage,
                    meetingTitle: row.meetingTitle,
                    splitLocalSpeakers: row.splitLocalSpeakers,
                    languageSelection: row.languageSelection,
                    micOnlyByChoice: row.micOnlyByChoice
                )
                let file = directory.appendingPathComponent("failed.json")
                try JSONEncoder().encode([stored]).write(to: file)
                let reloaded = try JSONDecoder().decode([FailedTranscription].self, from: Data(contentsOf: file))
                assertEqual(reloaded.first?.splitLocalSpeakers, enabled, "reloaded row keeps the choice (\(enabled))")
            } catch {
                assertTrue(false, "failed-queue row should round-trip: \(error)")
            }
        }
    }
}
