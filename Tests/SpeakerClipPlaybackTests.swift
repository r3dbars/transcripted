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
        let player = FakeRetainedAudioPlayer(recordingDuration: 2)
        let playback = SpeakerClipPlayback(retainedAudioPlayer: player)
        defer { playback.stop() }
        let sample = SpeakerRetainedAudioSample(url: url, startTime: 0.2, duration: 0.4)
        let followingTurnStart = 0.8
        playback.play(sample)
        assertEqual(playback.activeURL, nil, "a retained range must not identify as a global profile clip")
        assertEqual(player.loadedURL, url)
        assertTrue(abs((player.endTime ?? 0) - 0.6) < 0.001, "the range must end where the sample's turn ends")
        assertEqual(player.pendingSeekTimes, [0.2], "playback must seek to the turn's start")
        assertFalse(player.isPlaying, "audio must not start before the seek lands")

        player.finishSeek(0, finished: true)
        assertTrue(player.isPlaying, "a landed seek should start the range")
        assertTrue(playback.isPlaying(sample))
        player.advance(by: 0.3)
        assertTrue(playback.isPlaying(sample), "the range should keep playing before its end")
        player.advance(by: 0.3)
        assertTrue(player.furthestPosition < followingTurnStart, "playback must not reach the following speaker's turn")
        assertEqual(playback.activeRetainedSample, nil, "the configured range end should finish playback")
        assertEqual(player.loadedURL, nil, "range completion should release the long recording")
    }

    await runSuite("SpeakerClipPlayback keeps same-file voices distinct and ignores stale seeks") {
        let player = FakeRetainedAudioPlayer(recordingDuration: 2)
        let playback = SpeakerClipPlayback(retainedAudioPlayer: player)
        defer { playback.stop() }
        let first = SpeakerRetainedAudioSample(url: url, startTime: 0.2, duration: 0.4)
        let second = SpeakerRetainedAudioSample(url: url, startTime: 0.8, duration: 0.4)
        playback.play(first)
        playback.play(second)
        assertFalse(playback.isPlaying(first), "different voices in one file must not both highlight")
        assertTrue(playback.isPlaying(second))
        assertEqual(player.pendingSeekTimes, [0.2, 0.8])

        player.finishSeek(0, finished: false)
        player.endLoad(0)
        assertTrue(playback.isPlaying(second), "a superseded seek or end must not stop the replacement sample")
        player.finishSeek(0, finished: true)
        player.advance(by: 0.1)
        assertTrue(player.position >= 0.82, "the replacement sample should play from its own start")

        playback.play(second)
        assertEqual(playback.activeRetainedSample, nil, "clicking the playing sample should stop it")
        assertEqual(player.loadedURL, nil)
        assertFalse(player.isPlaying)

        playback.play(second)
        playback.play(second)
        player.finishSeek(0, finished: true)
        player.endLoad(player.loadCount - 1)
        assertEqual(playback.activeRetainedSample, nil, "late callbacks must not restart a stopped sample")
        assertFalse(player.isPlaying)
    }

    await runSuite("SpeakerClipPlayback clears a sample beyond the retained recording end") {
        let player = FakeRetainedAudioPlayer(recordingDuration: 2)
        let playback = SpeakerClipPlayback(retainedAudioPlayer: player)
        defer { playback.stop() }
        playback.play(SpeakerRetainedAudioSample(url: url, startTime: 3, duration: 1))
        player.finishSeek(0, finished: true)
        player.advance(by: 0.01)
        assertEqual(playback.activeRetainedSample, nil, "a truncated recording must not leave a sample stuck playing")
        assertEqual(player.loadedURL, nil)

        playback.play(SpeakerRetainedAudioSample(url: url, startTime: 3, duration: 1))
        player.finishSeek(0, finished: false)
        assertEqual(playback.activeRetainedSample, nil, "a seek the recording cannot reach must clear the sample")
        assertEqual(player.loadedURL, nil)
    }

    await runSuite("SpeakerClipPlayback sets the range end on the real AVPlayer item") {
        let avPlayer = AVPlayer()
        avPlayer.isMuted = true
        let playback = SpeakerClipPlayback(retainedAudioPlayer: AVPlayerRetainedAudioPlayer(player: avPlayer))
        defer { playback.stop() }
        playback.play(SpeakerRetainedAudioSample(url: url, startTime: 0.2, duration: 0.4))
        assertTrue(abs((avPlayer.currentItem?.forwardPlaybackEndTime.seconds ?? 0) - 0.6) < 0.001)
        playback.stop()
        assertEqual(avPlayer.currentItem, nil, "stopping should release the long recording")
        assertEqual(avPlayer.rate, 0)
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

        var playedHash: String?
        playback.playLoadedWavData = { data in
            playedHash = SpeakerClipSidecarQuote.sha256Hex(data)
            return true
        }
        playback.play(url)
        let loaded = playback.lastLoadedPlay
        assertTrue(loaded != nil, "play must keep the Data it loaded")
        assertEqual(loaded?.quote, quote, "the shown quote must come from the Data play loaded")
        assertEqual(
            playback.activeValidatedQuote,
            loaded?.quote,
            "the shown quote must be the one computed from that loaded Data"
        )
        assertEqual(
            playback.activeWavSHA256,
            loaded?.sha256,
            "the playing audio identity must be the hash of that same Data"
        )
        assertEqual(
            playedHash,
            loaded?.sha256,
            "the play seam must receive the same Data the quote was validated against"
        )
        assertTrue(playback.isPlaying(url), "the clip that loaded those bytes must be the one playing")

        do {
            try Data(repeating: 9, count: (loaded?.wavData.count ?? 0) + 8).write(to: url)
            try writeMatchingSpeakerClipSidecar(nextTo: url, sampleText: "Quote for a later wav.")
        } catch {
            assertTrue(false, "could not replace the clip after play loaded it: \(error)")
            return
        }

        assertEqual(
            playback.activeValidatedQuote,
            loaded?.quote,
            "replacing the file must not change the quote that belongs to the playing Data"
        )
        assertEqual(
            playback.activeWavSHA256,
            loaded?.sha256,
            "the playing audio must still be the Data that was loaded with that quote"
        )
        assertEqual(
            playback.lastLoadedPlay?.wavData,
            loaded?.wavData,
            "the held play Data must not be a reread after replace"
        )
        assertTrue(playback.isPlaying(url), "playback must keep holding the loaded clip")
        let disk = (try? Data(contentsOf: url)) ?? Data()
        assertEqual(
            SpeakerClipSidecarQuote.validatedText(nextTo: url, wavData: disk),
            "Quote for a later wav.",
            "a live reread after replace would see the new pair"
        )
        assertTrue(
            SpeakerClipSidecarQuote.validatedText(nextTo: url, wavData: loaded?.wavData ?? Data()) == nil,
            "the loaded bytes must not match the replacement sidecar"
        )
    }

    await runSuite("SpeakerClipPlayback clears failed retained-audio startup") {
        let brokenURL = url.deletingPathExtension().appendingPathExtension("m4a")
        try? Data([0, 1, 2]).write(to: brokenURL)
        defer { try? FileManager.default.removeItem(at: brokenURL) }
        let player = AVPlayer()
        player.isMuted = true
        let playback = SpeakerClipPlayback(retainedAudioPlayer: AVPlayerRetainedAudioPlayer(player: player))
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

/// Stands in for AVPlayer on a virtual clock: seeks wait until the test lands
/// them, time moves only on `advance`, and every load's end callback stays
/// callable so a test can deliver it late.
@MainActor
private final class FakeRetainedAudioPlayer: SpeakerRetainedAudioPlayer {
    private struct Seek {
        let time: Double
        let completion: @MainActor (Bool) -> Void
    }

    let recordingDuration: Double
    private(set) var loadedURL: URL?
    private(set) var endTime: Double?
    private(set) var position = 0.0
    private(set) var furthestPosition = 0.0
    private(set) var isPlaying = false
    private var endCallbacks: [@MainActor () -> Void] = []
    private var pendingSeeks: [Seek] = []

    var pendingSeekTimes: [Double] { pendingSeeks.map(\.time) }
    var loadCount: Int { endCallbacks.count }

    init(recordingDuration: Double) {
        self.recordingDuration = recordingDuration
    }

    func load(_ url: URL, endTime: Double, onEnd: @escaping @MainActor () -> Void) {
        loadedURL = url
        self.endTime = endTime
        position = 0
        endCallbacks.append(onEnd)
    }

    func seek(to time: Double, completion: @escaping @MainActor (Bool) -> Void) {
        pendingSeeks.append(Seek(time: time, completion: completion))
    }

    /// Like `AVPlayer.play()`, sets the rate even with nothing loaded, so a
    /// late restart shows up as `isPlaying`.
    func play() {
        isPlaying = true
    }

    func unload() {
        loadedURL = nil
        endTime = nil
        isPlaying = false
    }

    /// Deliver the pending seek at `index` (in request order).
    func finishSeek(_ index: Int, finished: Bool) {
        let seek = pendingSeeks.remove(at: index)
        if finished, loadedURL != nil {
            position = min(seek.time, recordingDuration)
        }
        seek.completion(finished)
    }

    /// Fire the end callback of the load at `index`, as a late notification would.
    func endLoad(_ index: Int) {
        endCallbacks[index]()
    }

    /// Move the playhead; reaching the range end or the end of the recording
    /// stops and fires the current load's end callback.
    func advance(by seconds: Double) {
        guard isPlaying, loadedURL != nil, let endTime else { return }
        let stopAt = min(endTime, recordingDuration)
        position = min(position + seconds, max(position, stopAt))
        furthestPosition = max(furthestPosition, position)
        guard position >= stopAt else { return }
        isPlaying = false
        endCallbacks[endCallbacks.count - 1]()
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
