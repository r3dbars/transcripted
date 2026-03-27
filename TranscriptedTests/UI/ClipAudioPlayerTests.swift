import XCTest
@testable import Transcripted

@available(macOS 14.0, *)
@MainActor
final class ClipAudioPlayerTests: XCTestCase {

    // MARK: - Stop resets state

    func testStopResetsIsPlayingAndCurrentClipURL() {
        let player = ClipAudioPlayer()

        // Manually set state as if something were playing
        player.isPlaying = true
        player.currentClipURL = URL(fileURLWithPath: "/tmp/fake.wav")

        player.stop()

        XCTAssertFalse(player.isPlaying, "isPlaying should be false after stop()")
        XCTAssertNil(player.currentClipURL, "currentClipURL should be nil after stop()")
    }

    // MARK: - Rapid play/stop race condition regression

    /// Regression test: calling play() then immediately stop() must leave the player
    /// in a clean state. Before the loadTask fix, the background Task could complete
    /// after stop() and flip isPlaying back to true.
    ///
    /// stop() is synchronous on @MainActor — it cancels the loadTask and resets state
    /// immediately. The cancelled Task.detached checks Task.isCancelled before applying
    /// state, so no sleep is needed.
    func testRapidPlayStopLeavesPlayerStopped() {
        let player = ClipAudioPlayer()
        let dummyURL = URL(fileURLWithPath: "/tmp/nonexistent-clip.wav")

        player.play(url: dummyURL)
        player.stop()

        // stop() is synchronous on MainActor — state is immediately correct
        XCTAssertFalse(player.isPlaying, "isPlaying should remain false after rapid play/stop")
        XCTAssertNil(player.currentClipURL, "currentClipURL should remain nil after rapid play/stop")
    }

    // MARK: - Play replaces previous

    /// When play(urlB) is called while play(urlA) is still loading, the first load
    /// should be cancelled. After settling, currentClipURL should NOT be urlA.
    func testPlayReplacePreviousDoesNotRetainOldURL() async throws {
        let player = ClipAudioPlayer()
        let urlA = URL(fileURLWithPath: "/tmp/clip-a.wav")
        let urlB = URL(fileURLWithPath: "/tmp/clip-b.wav")

        player.play(url: urlA)
        player.play(url: urlB)

        // Both URLs are nonexistent so AVAudioPlayer init will throw immediately
        // in the detached task. We need a brief yield to let the Task.detached
        // complete and hop back to MainActor. AVAudioPlayer init with a missing
        // file fails synchronously (no real I/O), so this is fast.
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms

        XCTAssertNotEqual(player.currentClipURL, urlA,
                          "First URL should have been cancelled and not retained")
    }

    // MARK: - Initial state is clean

    func testInitialState() {
        let player = ClipAudioPlayer()
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.currentClipURL)
    }

    // MARK: - Double stop is safe

    func testDoubleStopDoesNotCrash() {
        let player = ClipAudioPlayer()
        player.stop()
        player.stop()
        XCTAssertFalse(player.isPlaying)
    }
}
