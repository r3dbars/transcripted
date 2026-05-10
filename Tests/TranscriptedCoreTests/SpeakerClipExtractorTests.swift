import AVFoundation
import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class SpeakerClipExtractorTests: XCTestCase {
    private var tempDirectory: URL!
    private var database: SpeakerDatabase!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerClipExtractorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        database = SpeakerDatabase(path: tempDirectory.appendingPathComponent("speakers.sqlite").path)
    }

    override func tearDownWithError() throws {
        database = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testExtractClipsUsesLightweightProfileSnapshotMetadata() throws {
        let profile = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        )
        database.setDisplayName(id: profile.id, name: "Morgan", source: NameSource.userManual)
        _ = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.26, count: 256),
            existingId: profile.id
        )

        let audioURL = tempDirectory.appendingPathComponent("source.wav")
        try writeMonoWAV(to: audioURL, duration: 2.0)

        let clips = try SpeakerClipExtractor.extractClips(
            sourceAudioURL: audioURL,
            utterances: [
                TranscriptionUtterance(
                    start: 0.0,
                    end: 1.0,
                    channel: 0,
                    speakerId: 0,
                    persistentSpeakerId: profile.id,
                    matchSimilarity: 0.92,
                    transcript: "hello from the clip"
                )
            ],
            channel: .mic,
            speakerDB: database,
            clipsDirectory: tempDirectory.appendingPathComponent("clips", isDirectory: true)
        )

        let clip = try XCTUnwrap(clips.first)
        XCTAssertEqual(clip.persistentSpeakerId, profile.id)
        XCTAssertEqual(clip.currentName, "Morgan")
        XCTAssertEqual(clip.callCount, 2)
        XCTAssertEqual(clip.sampleText, "hello from the clip")
    }

    private func writeMonoWAV(to url: URL, duration: TimeInterval, sampleRate: Double = 16_000) throws {
        let frameCount = Int(duration * sampleRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return XCTFail("Failed to create test audio format")
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return XCTFail("Failed to create test audio buffer")
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        if let channelData = buffer.floatChannelData?[0] {
            for index in 0..<frameCount {
                channelData[index] = 0.25
            }
        }

        try file.write(from: buffer)
    }
}
