import XCTest
@testable import TranscriptedCore

final class SystemAudioSilenceWatchTests: XCTestCase {
    func testNothingHappensWhileNoOtherAppPlays() {
        var watch = SystemAudioSilenceWatch.armed(.start, at: 0)
        for second in 0..<120 {
            let now = TimeInterval(second)
            XCTAssertTrue(watch.noteBuffer(hasSignal: false, at: now))
            XCTAssertEqual(watch.evaluate(otherAudioPlaying: false, at: now), .none)
        }
        XCTAssertFalse(watch.exhausted)
        XCTAssertEqual(watch.reconnectsLeft, SystemAudioSilenceWatch.maxReconnects)
    }

    func testRealSignalEndsTheWatch() {
        var watch = SystemAudioSilenceWatch.armed(.rebuild, at: 0)
        XCTAssertTrue(watch.noteBuffer(hasSignal: false, at: 1))
        XCTAssertFalse(watch.noteBuffer(hasSignal: true, at: 2))
    }

    func testRebuildKeepsTheBudgetSoReconnectsStayBounded() {
        var watch = SystemAudioSilenceWatch.armed(.start, at: 0)
        _ = watch.noteBuffer(hasSignal: false, at: 0)
        XCTAssertEqual(watch.evaluate(otherAudioPlaying: true, at: SystemAudioSilenceWatch.silenceSeconds), .reconnect)
        watch.restartSilence()
        _ = watch.noteBuffer(hasSignal: false, at: 10)
        XCTAssertEqual(watch.evaluate(otherAudioPlaying: true, at: 10 + SystemAudioSilenceWatch.silenceSeconds), .none)
        XCTAssertTrue(watch.exhausted)
        XCTAssertEqual(watch.reconnectsLeft, 0)
    }

    func testReportsOnceAfterSustainedUnheardPlayback() {
        var watch = SystemAudioSilenceWatch.armed(.outputChange, at: 0)
        var actions: [SystemAudioSilenceWatch.Action] = []
        for second in 0..<200 {
            let now = TimeInterval(second)
            _ = watch.noteBuffer(hasSignal: false, at: now)
            let action = watch.evaluate(otherAudioPlaying: true, at: now)
            if action != .none { actions.append(action) }
            if action == .reconnect { watch.restartSilence() }
        }
        XCTAssertEqual(actions, [.reconnect, .reportUnheard])
        XCTAssertTrue(watch.reportedUnheard)
        XCTAssertFalse(watch.wantsPlaybackCheck(at: 500), "No more process scans once reported")
    }

    func testPlaybackStoppingResetsTheUnheardClock() {
        var watch = SystemAudioSilenceWatch.armed(.start, at: 0)
        _ = watch.noteBuffer(hasSignal: false, at: 0)
        XCTAssertEqual(watch.evaluate(otherAudioPlaying: true, at: 5), .reconnect)
        _ = watch.noteBuffer(hasSignal: false, at: 6)
        XCTAssertEqual(watch.evaluate(otherAudioPlaying: true, at: 11), .none)
        XCTAssertEqual(watch.unheardSince, 11)
        XCTAssertEqual(watch.evaluate(otherAudioPlaying: false, at: 12), .none)
        XCTAssertNil(watch.unheardSince)
        XCTAssertEqual(watch.evaluate(otherAudioPlaying: true, at: 13), .none)
        XCTAssertEqual(
            watch.evaluate(otherAudioPlaying: true, at: 13 + SystemAudioSilenceWatch.unheardReportSeconds),
            .reportUnheard
        )
    }

    func testChecksPlaybackAtMostOncePerInterval() {
        var watch = SystemAudioSilenceWatch.armed(.start, at: 0)
        _ = watch.noteBuffer(hasSignal: false, at: 0)
        XCTAssertEqual(watch.evaluate(otherAudioPlaying: false, at: 5), .none)
        XCTAssertFalse(watch.wantsPlaybackCheck(at: 5.5))
        XCTAssertEqual(watch.evaluate(otherAudioPlaying: true, at: 5.5), .none, "Too soon after the last scan")
        XCTAssertEqual(watch.evaluate(otherAudioPlaying: true, at: 6), .reconnect)
    }

    func testWakeWatchKeepsItsFasterBoundedWindow() {
        var watch = SystemAudioSilenceWatch.armed(.wake, at: 0)
        XCTAssertEqual(watch.until, SystemAudioSilenceWatch.wakeWindowSeconds)
        XCTAssertEqual(watch.reconnectsLeft, SystemAudioSilenceWatch.maxWakeReconnects)
        _ = watch.noteBuffer(hasSignal: false, at: 0)
        XCTAssertEqual(watch.evaluate(otherAudioPlaying: true, at: SystemAudioSilenceWatch.wakeSilenceSeconds), .reconnect)
        XCTAssertFalse(watch.isExpired(at: SystemAudioSilenceWatch.wakeWindowSeconds - 1))
        XCTAssertTrue(watch.isExpired(at: SystemAudioSilenceWatch.wakeWindowSeconds))
        XCTAssertFalse(SystemAudioSilenceWatch.armed(.start, at: 0).isExpired(at: 10_000), "Start watch runs until signal")
    }

    func testAReportedWakeWatchOutlivesItsWindowUntilSignal() {
        // Review follow-up: once the user was told, the watch must stay to
        // see a quiet call come back, or the warning outlives the call.
        var watch = SystemAudioSilenceWatch.armed(.wake, at: 0)
        let silence = SystemAudioSilenceWatch.wakeSilenceSeconds
        _ = watch.noteBuffer(hasSignal: false, at: 0)
        XCTAssertEqual(watch.evaluate(otherAudioPlaying: true, at: silence), .reconnect)
        _ = watch.noteBuffer(hasSignal: false, at: silence)
        XCTAssertEqual(watch.evaluate(otherAudioPlaying: true, at: silence * 2), .none)
        XCTAssertEqual(
            watch.evaluate(otherAudioPlaying: true, at: silence * 2 + SystemAudioSilenceWatch.unheardReportSeconds),
            .reportUnheard
        )
        XCTAssertFalse(watch.isExpired(at: SystemAudioSilenceWatch.wakeWindowSeconds + 1_000))
        XCTAssertFalse(watch.noteBuffer(hasSignal: true, at: SystemAudioSilenceWatch.wakeWindowSeconds + 1_000))
    }
}
