import Foundation

func testMeetingCaptureSounds() {
    runSuite("Meeting cues keep Tink and Pop at their existing volume") {
        assertEqual(AppSoundPlayer.soundURL(for: .meetingRecordingStart)?.path,
                    "/System/Library/Sounds/Tink.aiff", "start keeps Tink")
        assertEqual(AppSoundPlayer.soundURL(for: .meetingRecordingStop)?.path,
                    "/System/Library/Sounds/Pop.aiff", "stop keeps Pop")
        assertEqual(AppSoundPlayer.Cue.meetingRecordingStart.playbackVolume, 1, "start volume")
        assertEqual(AppSoundPlayer.Cue.meetingRecordingStop.playbackVolume, 1, "stop volume")
        assertFalse(AppSoundPlayer.Cue.meetingRecordingStart.followsSystemInterfaceSounds,
                    "no new interface-sounds preference gate")
    }

    runSuite("Meeting cue loading is lazy and playback stays on the output queue") {
        let queue = DispatchQueue(label: "test.meeting-cue-output")
        let outputKey = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: outputKey, value: true)
        var loaded: [String] = []
        var played: [String] = []
        var allWorkOnOutputQueue = true
        let player = AppSoundPlayer(queue: queue, now: { 0 }) { url in
            loaded.append(url.lastPathComponent)
            allWorkOnOutputQueue = allWorkOnOutputQueue && DispatchQueue.getSpecific(key: outputKey) == true
            return MeetingCueFakePlayer(onPrepare: {
                allWorkOnOutputQueue = allWorkOnOutputQueue && DispatchQueue.getSpecific(key: outputKey) == true
            }, onPlay: {
                allWorkOnOutputQueue = allWorkOnOutputQueue && DispatchQueue.getSpecific(key: outputKey) == true
                played.append(url.lastPathComponent)
            })
        }
        player.preload()
        queue.sync {}
        assertFalse(loaded.contains("Tink.aiff"), "launch does not load meeting start sound")
        assertFalse(loaded.contains("Pop.aiff"), "launch does not load meeting stop sound")

        player.play(.meetingRecordingStart, respectingPreferences: false)
        player.play(.meetingRecordingStop, respectingPreferences: false)
        queue.sync {}
        assertEqual(played, ["Tink.aiff", "Pop.aiff"], "start/stop order is preserved")
        assertTrue(allWorkOnOutputQueue, "loading, preparation and playback never execute on the caller")
    }

    runSuite("A stalled meeting sound does not hold its caller") {
        let queue = DispatchQueue(label: "test.meeting-cue-stalled-output")
        let preparationEntered = DispatchSemaphore(value: 0)
        let releasePreparation = DispatchSemaphore(value: 0)
        let callerReturned = DispatchSemaphore(value: 0)
        let player = AppSoundPlayer(queue: queue, now: { 0 }) { url in
            MeetingCueFakePlayer(onPrepare: {
                if url.lastPathComponent == "Tink.aiff" {
                    preparationEntered.signal()
                    releasePreparation.wait()
                }
            })
        }
        DispatchQueue.global().async {
            player.play(.meetingRecordingStart, respectingPreferences: false)
            callerReturned.signal()
        }
        // These are deadlock guards, not latency budgets. The fake remains
        // held until after we observe that the caller returned independently.
        let entered = preparationEntered.wait(timeout: .now() + 10)
        let returned = callerReturned.wait(timeout: .now() + 10)
        releasePreparation.signal()
        queue.sync {}
        assertEqual(entered, .success, "fake preparation was reached")
        assertEqual(returned, .success, "caller returns while native preparation is held")
    }

    runSuite("A meeting cue that becomes stale during preparation is dropped") {
        let queue = DispatchQueue(label: "test.meeting-cue-stale-output")
        let clock = MeetingCueTestClock()
        var played: [String] = []
        let player = AppSoundPlayer(queue: queue, now: { clock.now }) { url in
            MeetingCueFakePlayer(onPrepare: {
                if url.lastPathComponent == "Tink.aiff" { clock.advance() }
            }, onPlay: { played.append(url.lastPathComponent) })
        }
        player.play(.meetingRecordingStart, respectingPreferences: false)
        queue.sync {}
        assertEqual(played, [], "late start cue cannot announce a recording after slow setup")
        player.play(.meetingRecordingStop, respectingPreferences: false)
        queue.sync {}
        assertEqual(played, ["Pop.aiff"], "fresh stop cue still plays")
    }

    runSuite("Stale queued meeting cues never open another sound player") {
        let queue = DispatchQueue(label: "test.meeting-cue-queued")
        let clock = MeetingCueTestClock()
        var loaded: [String] = []
        let player = AppSoundPlayer(queue: queue, now: { clock.now }) { url in
            loaded.append(url.lastPathComponent)
            return MeetingCueFakePlayer()
        }
        queue.suspend()
        player.play(.meetingRecordingStart, respectingPreferences: false)
        clock.advance()
        queue.resume()
        queue.sync {}
        assertEqual(loaded, [], "an obsolete cue does no native loading or preparation")
    }

    runSuite("Meeting cue compatibility does not change the app sound preference") {
        let key = "enableUISounds"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UISoundPreferences.setEnabled(false)
        let queue = DispatchQueue(label: "test.meeting-cue-preferences")
        var played: [String] = []
        let player = AppSoundPlayer(queue: queue, now: { 0 }) { url in
            MeetingCueFakePlayer(onPlay: { played.append(url.lastPathComponent) })
        }
        player.play(.dictationStart)
        player.play(.meetingRecordingStart, respectingPreferences: false)
        player.play(.meetingRecordingStop, respectingPreferences: false)
        queue.sync {}
        assertEqual(played, ["Tink.aiff", "Pop.aiff"], "legacy meeting cues remain unconditional; dictation stays muted")
        assertFalse(UISoundPreferences.isEnabled(), "preference stays disabled")
    }
}

private final class MeetingCueFakePlayer: AppCueAudioPlayer {
    var volume: Float = 0
    var currentTime: TimeInterval = 0
    var isPlaying = false
    private let onPrepare: () -> Void
    private let onPlay: () -> Void

    init(onPrepare: @escaping () -> Void = {}, onPlay: @escaping () -> Void = {}) {
        self.onPrepare = onPrepare
        self.onPlay = onPlay
    }

    func prepareToPlay() -> Bool { onPrepare(); return true }
    func play() -> Bool { onPlay(); isPlaying = true; return true }
    func stop() { isPlaying = false }
}

private final class MeetingCueTestClock {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    func advance() { lock.lock(); defer { lock.unlock() }; time += 2 }
}
