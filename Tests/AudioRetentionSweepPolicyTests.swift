import Foundation

func testAudioRetentionSweepPolicy() {
    let launch = Date(timeIntervalSince1970: 1_793_000_000)

    runSuite("AudioRetentionSweepPolicy sweeps an open app again after the interval") {
        assertFalse(
            AudioRetentionSweepPolicy.isDue(
                lastSweep: launch, now: launch.addingTimeInterval(60 * 60),
                meeting: .thirtyDays, dictation: .sevenDays
            ),
            "an hour after launch maintenance is too soon"
        )
        assertTrue(
            AudioRetentionSweepPolicy.isDue(
                lastSweep: launch, now: launch.addingTimeInterval(AudioRetentionSweepPolicy.interval),
                meeting: .thirtyDays, dictation: .sevenDays
            ),
            "an app left open past the interval sweeps again instead of waiting for a relaunch"
        )
    }

    runSuite("AudioRetentionSweepPolicy sweeps when only one window is finite") {
        let later = launch.addingTimeInterval(AudioRetentionSweepPolicy.interval + 1)
        assertTrue(AudioRetentionSweepPolicy.isDue(lastSweep: launch, now: later, meeting: .never, dictation: .thirtyDays))
        assertTrue(AudioRetentionSweepPolicy.isDue(lastSweep: launch, now: later, meeting: .sevenDays, dictation: .forever))
        assertTrue(
            AudioRetentionSweepPolicy.isDue(lastSweep: launch, now: later, meeting: .never, dictation: .off),
            "Don't keep has a zero-day window and still sweeps"
        )
    }

    runSuite("AudioRetentionSweepPolicy does nothing when nothing can expire") {
        assertFalse(AudioRetentionSweepPolicy.isDue(lastSweep: nil, now: launch, meeting: .never, dictation: .forever))
    }

    runSuite("AudioRetentionSweepPolicy recovers from a missing or backwards clock") {
        assertTrue(AudioRetentionSweepPolicy.isDue(lastSweep: nil, now: launch, meeting: .thirtyDays, dictation: .forever))
        assertTrue(
            AudioRetentionSweepPolicy.isDue(
                lastSweep: launch, now: launch.addingTimeInterval(-60),
                meeting: .thirtyDays, dictation: .forever
            )
        )
    }
}
