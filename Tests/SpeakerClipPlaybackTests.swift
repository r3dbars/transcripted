import AVFoundation
import Foundation

@MainActor
func testSpeakerClipPlayback() async {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpeakerPlayback-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        try writeSilentSpeakerPlaybackFixture(to: url)
    } catch {
        assertTrue(false, "could not create silent playback fixture: \(error)")
        return
    }

    await runSuite("SpeakerClipPlayback streams only the requested retained-audio range") {
        let player = AVPlayer()
        player.isMuted = true
        let playback = SpeakerClipPlayback(retainedAudioPlayer: player)
        defer { playback.stop() }
        let sample = SpeakerRetainedAudioSample(url: url, startTime: 0.2, duration: 0.4)
        playback.play(sample)
        assertEqual(playback.activeURL, nil, "a retained range must not identify as a global profile clip")
        assertTrue(abs((player.currentItem?.forwardPlaybackEndTime.seconds ?? 0) - 0.6) < 0.001)

        var observedProgress = false
        var latestTime = 0.0
        let deadline = Date().addingTimeInterval(5)
        while playback.isPlaying(sample), Date() < deadline {
            let time = player.currentTime().seconds
            if time.isFinite {
                latestTime = max(latestTime, time)
                observedProgress = observedProgress || (player.rate > 0 && time > 0.22)
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assertTrue(observedProgress, "the real muted player should advance within the selected range")
        assertTrue(latestTime <= 0.62, "playback must not reach the following speaker's turn")
        assertEqual(playback.activeRetainedSample, nil, "the configured range end should finish playback")
        assertEqual(player.currentItem, nil, "range completion should release the long recording")
    }

    await runSuite("SpeakerClipPlayback keeps same-file voices distinct and ignores stale seeks") {
        let player = AVPlayer()
        player.isMuted = true
        let playback = SpeakerClipPlayback(retainedAudioPlayer: player)
        defer { playback.stop() }
        let first = SpeakerRetainedAudioSample(url: url, startTime: 0.2, duration: 0.4)
        let second = SpeakerRetainedAudioSample(url: url, startTime: 0.8, duration: 0.4)
        playback.play(first)
        playback.play(second)
        assertFalse(playback.isPlaying(first), "different voices in one file must not both highlight")
        assertTrue(playback.isPlaying(second))
        let deadline = Date().addingTimeInterval(5)
        while playback.isPlaying(second), Date() < deadline {
            if player.currentTime().seconds >= 0.82 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assertTrue(player.currentTime().seconds >= 0.82, "a superseded seek must not stop the replacement sample")
        playback.play(second)
        assertEqual(playback.activeRetainedSample, nil, "clicking the playing sample should stop it")
        assertEqual(player.currentItem, nil)
        try? await Task.sleep(nanoseconds: 30_000_000)
        assertEqual(playback.activeRetainedSample, nil, "late callbacks must not restart a stopped sample")
        assertEqual(player.rate, 0)
    }

    await runSuite("SpeakerClipPlayback clears a sample beyond the retained recording end") {
        let player = AVPlayer()
        player.isMuted = true
        let playback = SpeakerClipPlayback(retainedAudioPlayer: player)
        defer { playback.stop() }
        playback.play(SpeakerRetainedAudioSample(url: url, startTime: 3, duration: 1))
        let deadline = Date().addingTimeInterval(5)
        while playback.activeRetainedSample != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assertEqual(playback.activeRetainedSample, nil, "a truncated recording must not leave a sample stuck playing")
        assertEqual(player.currentItem, nil)
    }

    await runSuite("SpeakerClipPlayback clears failed retained-audio startup") {
        let brokenURL = url.deletingPathExtension().appendingPathExtension("m4a")
        try? Data([0, 1, 2]).write(to: brokenURL)
        defer { try? FileManager.default.removeItem(at: brokenURL) }
        let player = AVPlayer()
        player.isMuted = true
        let playback = SpeakerClipPlayback(retainedAudioPlayer: player)
        defer { playback.stop() }
        playback.play(SpeakerRetainedAudioSample(url: brokenURL, startTime: 0, duration: 1))
        let deadline = Date().addingTimeInterval(5)
        while playback.activeRetainedSample != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        assertEqual(playback.activeRetainedSample, nil, "a file that cannot load must not leave the row stuck playing")
        assertEqual(player.currentItem, nil)
    }
}

private func writeSilentSpeakerPlaybackFixture(to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
    buffer.frameLength = buffer.frameCapacity
    buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}
