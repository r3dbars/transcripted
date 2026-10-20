import AVFoundation
import CryptoKit
import Foundation

@MainActor
func testSpeakerClipPlayback() async {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpeakerPlayback-\(UUID().uuidString).wav")
    let sidecarURL = url.deletingPathExtension().appendingPathExtension("json")
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: sidecarURL)
    }
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
        let followingTurnStart = 0.8
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
        assertTrue(latestTime < followingTurnStart, "playback must not reach the following speaker's turn")
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

    await runSuite("SpeakerClipPlayback quotes the wav bytes it loaded, not a later replace") {
        let playback = SpeakerClipPlayback()
        defer { playback.stop() }
        let quote = "Words from these bytes."
        do {
            try writeMatchingSpeakerClipSidecar(nextTo: url, sampleText: quote)
        } catch {
            assertTrue(false, "could not write matching sidecar: \(error)")
            return
        }
        let loaded = (try? Data(contentsOf: url)) ?? Data()
        assertTrue(!loaded.isEmpty, "the playback fixture must have wav bytes")
        assertEqual(
            SpeakerClipSidecarQuote.validatedText(nextTo: url, wavData: loaded),
            quote
        )

        let quoteForLoadedBytes = SpeakerClipSidecarQuote.validatedText(nextTo: url, wavData: loaded)
        playback.play(url)
        do {
            try Data(repeating: 9, count: loaded.count + 8).write(to: url)
            try writeMatchingSpeakerClipSidecar(nextTo: url, sampleText: "Quote for a later wav.")
        } catch {
            assertTrue(false, "could not replace the clip after play: \(error)")
            return
        }
        let replaced = (try? Data(contentsOf: url)) ?? Data()
        assertEqual(
            quoteForLoadedBytes,
            quote,
            "the quote must be validated against the bytes play would load, even if sound cannot start"
        )
        assertEqual(
            SpeakerClipSidecarQuote.validatedText(nextTo: url, wavData: replaced),
            "Quote for a later wav.",
            "a live reread after replace would see the new pair"
        )
        assertEqual(
            SpeakerClipSidecarQuote.validatedText(nextTo: url, wavData: loaded),
            nil,
            "the old bytes must not match the replacement sidecar"
        )
    }

    await runSuite("SpeakerClipPlayback holds the loaded quote against the same play Data") {
        let playback = SpeakerClipPlayback()
        defer { playback.stop() }
        let quote = "Words from these bytes."
        do {
            try writeMatchingSpeakerClipSidecar(nextTo: url, sampleText: quote)
        } catch {
            assertTrue(false, "could not write matching sidecar: \(error)")
            return
        }

        playback.play(url)
        let heldQuote = playback.activeValidatedQuote
        let heldHash = playback.activeWavSHA256
        assertEqual(heldQuote, quote, "the shown quote must come from the Data play loaded")
        assertTrue(playback.isPlaying(url), "the clip that loaded those bytes must be the one playing")
        assertTrue(
            heldHash != nil && !(heldHash ?? "").isEmpty,
            "play must record the hash of the same Data it handed to NSSound"
        )

        do {
            let loadedCount = (try? Data(contentsOf: url))?.count ?? 0
            try Data(repeating: 9, count: max(loadedCount, 8) + 8).write(to: url)
            try writeMatchingSpeakerClipSidecar(nextTo: url, sampleText: "Quote for a later wav.")
        } catch {
            assertTrue(false, "could not replace the clip after play loaded it: \(error)")
            return
        }

        assertEqual(
            playback.activeValidatedQuote,
            heldQuote,
            "replacing the file must not change the quote that belongs to the playing Data"
        )
        assertEqual(
            playback.activeWavSHA256,
            heldHash,
            "the playing audio must still be the Data that was loaded with that quote"
        )
        assertTrue(playback.isPlaying(url), "playback must keep holding the loaded clip")
        let disk = (try? Data(contentsOf: url)) ?? Data()
        assertEqual(
            SpeakerClipSidecarQuote.validatedText(nextTo: url, wavData: disk),
            "Quote for a later wav.",
            "a live reread after replace would see the new pair"
        )
        assertTrue(
            SpeakerClipSidecarQuote.validatedText(nextTo: url, wavData: disk) != heldQuote,
            "the shown quote must not be a reread of the replaced sidecar"
        )
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

private func writeMatchingSpeakerClipSidecar(nextTo clipURL: URL, sampleText: String) throws {
    let wav = try Data(contentsOf: clipURL)
    let digest = SHA256.hash(data: wav).map { String(format: "%02x", $0) }.joined()
    let json: [String: Any] = [
        "channel": "system",
        "diarizerSpeakerId": "1",
        "segments": [["start": 0.2, "end": 0.6, "text": sampleText]],
        "sampleText": sampleText,
        "formatVersion": 1,
        "wavByteCount": wav.count,
        "wavSHA256": digest
    ]
    let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    try data.write(to: clipURL.deletingPathExtension().appendingPathExtension("json"))
}
