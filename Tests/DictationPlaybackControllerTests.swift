// DictationPlaybackControllerTests.swift
// The Dictations page plays one take at a time and folds back when done.

import Foundation

@MainActor
private final class FakeDictationPlayer: DictationAudioPlayback {
    let url: URL
    var duration: TimeInterval
    var currentTime: TimeInterval = 0
    var onFinish: (() -> Void)?
    var playResult = true
    private(set) var events: [String] = []

    init(url: URL, duration: TimeInterval) {
        self.url = url
        self.duration = duration
    }

    func play() -> Bool {
        events.append("play")
        return playResult
    }

    func pause() { events.append("pause") }
    func stop() { events.append("stop") }

    func finish() {
        currentTime = duration
        onFinish?()
    }
}

@MainActor
private final class FakeDictationPlayerFactory {
    var made: [FakeDictationPlayer] = []
    var failingURLs: Set<URL> = []
    var nextPlayResult = true

    func make(_ url: URL) throws -> DictationAudioPlayback {
        if failingURLs.contains(url) { throw CocoaError(.fileReadCorruptFile) }
        let player = FakeDictationPlayer(url: url, duration: 20)
        player.playResult = nextPlayResult
        made.append(player)
        return player
    }
}

@MainActor
func testDictationPlaybackController() {
    let first = URL(fileURLWithPath: "/fake/audio/first.m4a")
    let second = URL(fileURLWithPath: "/fake/audio/second.m4a")

    runSuite("Playing a take opens it; pause keeps it open; play resumes") {
        let factory = FakeDictationPlayerFactory()
        let controller = DictationPlaybackController(makePlayer: { try factory.make($0) })

        assertTrue(controller.togglePlayback(entryID: "a") { first }, "a playable take starts")
        assertTrue(controller.isPlaying("a"), "it's playing")
        assertEqual(controller.session?.duration, 20, "the session knows the take's length")

        assertTrue(controller.togglePlayback(entryID: "a") { nil }, "toggling the open take never needs the file")
        assertTrue(controller.isActive("a"), "a paused take stays open")
        assertFalse(controller.isPlaying("a"), "but isn't playing")
        assertEqual(factory.made.count, 1, "pausing doesn't build a new player")

        controller.togglePlayback(entryID: "a") { nil }
        assertTrue(controller.isPlaying("a"), "play resumes the same take")
        assertEqual(factory.made.first?.events, ["play", "pause", "play"], "one player: play, pause, play")
    }

    runSuite("Starting another take stops the first: one plays at a time") {
        let factory = FakeDictationPlayerFactory()
        let controller = DictationPlaybackController(makePlayer: { try factory.make($0) })

        controller.togglePlayback(entryID: "a") { first }
        controller.togglePlayback(entryID: "b") { second }
        assertFalse(controller.isActive("a"), "the first take folds back")
        assertTrue(controller.isPlaying("b"), "the second take plays")
        assertEqual(factory.made.first?.events, ["play", "stop"], "the first player was stopped")

        factory.made.first?.finish()
        assertTrue(controller.isPlaying("b"), "a late finish from the old player is ignored")
    }

    runSuite("Reaching the end folds the take back to its resting bar") {
        let factory = FakeDictationPlayerFactory()
        let controller = DictationPlaybackController(makePlayer: { try factory.make($0) })

        controller.togglePlayback(entryID: "a") { first }
        factory.made.first?.finish()
        assertNil(controller.session, "nothing is open after the end")
        assertFalse(controller.isActive("a"), "the card folds back")
        assertEqual(controller.currentTime(for: "a"), 0, "a closed take reads zero")
    }

    runSuite("Seeking moves the playhead within the take, clamped to its length") {
        let factory = FakeDictationPlayerFactory()
        let controller = DictationPlaybackController(makePlayer: { try factory.make($0) })

        controller.togglePlayback(entryID: "a") { first }
        controller.seek(entryID: "a", toFraction: 0.25)
        assertEqual(controller.currentTime(for: "a"), 5, "a quarter of 20 s is 5 s")
        assertEqual(controller.progress(for: "a"), 0.25, "progress matches")
        controller.seek(entryID: "a", toFraction: 1.7)
        assertEqual(controller.currentTime(for: "a"), 20, "past the end clamps to the end")
        controller.seek(entryID: "a", toFraction: -1)
        assertEqual(controller.currentTime(for: "a"), 0, "before the start clamps to the start")
        controller.seek(entryID: "a", by: 2)
        assertEqual(controller.currentTime(for: "a"), 2, "VoiceOver steps move by seconds")
        controller.seek(entryID: "b", toFraction: 0.5)
        assertEqual(controller.currentTime(for: "a"), 2, "seeking a closed take does nothing")
    }

    runSuite("A take that can't play leaves nothing playing") {
        let factory = FakeDictationPlayerFactory()
        factory.failingURLs = [second]
        let controller = DictationPlaybackController(makePlayer: { try factory.make($0) })

        assertFalse(controller.togglePlayback(entryID: "a") { nil }, "no file means no playback")
        assertNil(controller.session, "nothing opens without a file")

        controller.togglePlayback(entryID: "a") { first }
        assertFalse(controller.togglePlayback(entryID: "b") { second }, "an unreadable file fails")
        assertNil(controller.session, "and the old take was already stopped")

        factory.nextPlayResult = false
        assertFalse(controller.togglePlayback(entryID: "c") { first }, "a player that won't start fails")
        assertNil(controller.session, "nothing is left open")
    }

    runSuite("Stopping by entry only stops that take; leaving the page stops everything") {
        let factory = FakeDictationPlayerFactory()
        let controller = DictationPlaybackController(makePlayer: { try factory.make($0) })

        controller.togglePlayback(entryID: "a") { first }
        controller.stop(entryID: "b")
        assertTrue(controller.isPlaying("a"), "deleting another entry doesn't stop this one")
        controller.stop(entryID: "a")
        assertNil(controller.session, "deleting the playing entry stops it")

        controller.togglePlayback(entryID: "a") { first }
        controller.stop()
        assertNil(controller.session, "leaving the page stops playback")
        assertEqual(factory.made.last?.events, ["play", "stop"], "the player was stopped")
    }
}
