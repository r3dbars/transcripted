import Foundation
import AVFoundation
import AppKit

// MARK: - Debug Helpers (DEBUG builds only)

#if DEBUG
@available(macOS 26.0, *)
extension AppDelegate {

    @objc func resetOnboarding() {
        OnboardingState.resetOnboarding()
        AppLogger.app.info("Onboarding reset — restart app to see onboarding")
    }

    @objc func testNamingTray() {
        guard let tm = taskManager else { return }
        let speakerDB = tm.transcription.speakerDB

        // Seed DB with test profiles so merge suggestions appear
        let mkbhdEmbedding = (0..<256).map { _ in Float.random(in: -1...1) }
        let travisEmbedding = (0..<256).map { _ in Float.random(in: -1...1) }
        let mkbhdProfile = speakerDB.addOrUpdateSpeaker(embedding: mkbhdEmbedding)
        speakerDB.setDisplayName(id: mkbhdProfile.id, name: "MKBHD", source: NameSource.userManual)
        // Bump call count by adding a few more times
        for _ in 0..<6 {
            _ = speakerDB.addOrUpdateSpeaker(embedding: mkbhdEmbedding, existingId: mkbhdProfile.id)
        }
        let travisProfile = speakerDB.addOrUpdateSpeaker(embedding: travisEmbedding)
        speakerDB.setDisplayName(id: travisProfile.id, name: "Travis", source: NameSource.userManual)
        for _ in 0..<2 {
            _ = speakerDB.addOrUpdateSpeaker(embedding: travisEmbedding, existingId: travisProfile.id)
        }

        // Create tiny silence WAV files for clip playback
        let clip1 = createSilentWAV(name: "test_speaker_0")
        let clip2 = createSilentWAV(name: "test_speaker_1")

        // Create test naming entries — one unknown, one needing confirmation
        // Insert into DB so merge targets exist
        let unknownProfile = speakerDB.addOrUpdateSpeaker(embedding: (0..<256).map { _ in Float.random(in: -1...1) })
        let knownProfile = speakerDB.addOrUpdateSpeaker(embedding: (0..<256).map { _ in Float.random(in: -1...1) })

        let entries = [
            SpeakerNamingEntry(
                id: unknownProfile.id,
                sortformerSpeakerId: "0",
                clipURL: clip1,
                sampleText: "I think the new MacBook Pro is incredible this year, the M4 chip is a huge leap forward",
                currentName: nil,
                matchSimilarity: nil,
                needsNaming: true,
                needsConfirmation: false,
                qwenResult: .notAttempted
            ),
            SpeakerNamingEntry(
                id: knownProfile.id,
                sortformerSpeakerId: "1",
                clipURL: clip2,
                sampleText: "Yeah the battery life improvements are really what sold me on upgrading",
                currentName: "Travis",
                matchSimilarity: 0.72,
                needsNaming: false,
                needsConfirmation: true,
                qwenResult: .notAttempted
            )
        ]

        // Create a dummy transcript URL (doesn't need to exist for testing)
        let dummyTranscript = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_transcript.md")
        let dummyMic = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_mic.wav")
        let dummySystem = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_system.wav")

        tm.speakerNamingRequest = SpeakerNamingRequest(
            speakers: entries,
            transcriptURL: dummyTranscript,
            systemAudioURL: dummySystem,
            micAudioURL: dummyMic,
            onComplete: { [weak tm] updates in
                tm?.handleNamingComplete(
                    updates: updates,
                    transcriptURL: dummyTranscript,
                    micURL: dummyMic,
                    systemURL: dummySystem,
                    clips: entries
                )
            }
        )

        AppLogger.app.info("Debug: Test naming tray triggered", ["speakers": "\(entries.count)"])
    }

    /// Create a tiny silent WAV file for debug clip playback
    func createSilentWAV(name: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).wav")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000) else {
            return url
        }
        buffer.frameLength = 24000  // 0.5 seconds of silence
        if let file = try? AVAudioFile(forWriting: url, settings: format.settings) {
            try? file.write(from: buffer)
        }
        return url
    }
}
#endif
