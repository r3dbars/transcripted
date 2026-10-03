import Combine
import Foundation

@MainActor
func testDictationAudioLevels() {
    // STTRouter owns the dictation meter as a `let`, like this host. Settings
    // observes the whole router, so a meter reading must not fire the router's
    // objectWillChange, or Settings re-renders 30 times a second while dictating.
    @MainActor
    final class RouterLikeOwner: ObservableObject {
        let audioLevels = DictationAudioLevels()
        @Published var isRecording = false
    }

    runSuite("A meter reading doesn't fire the owning router's objectWillChange") {
        let owner = RouterLikeOwner()
        var ownerChanges = 0
        let cancellable = owner.objectWillChange.sink { _ in ownerChanges += 1 }

        for step in 0..<60 {
            let level = Float(step % 10) / 10
            owner.audioLevels.update(DictationAudioLevel(level: level, peak: min(1, level + 0.1)))
        }
        assertEqual(ownerChanges, 0, "meter readings should stay off the router's objectWillChange")

        owner.isRecording = true
        assertEqual(ownerChanges, 1, "real router state changes still notify observers")
        cancellable.cancel()
    }

    runSuite("Every reading reaches the island in order, right away (no extra main hop)") {
        let levels = DictationAudioLevels()
        assertEqual(levels.current, .silent, "a fresh meter starts silent")

        let initial = levels.current
        var received: [DictationAudioLevel] = []
        let subscription = levels.readings.sink { received.append($0) }

        let r1 = DictationAudioLevel(level: 0.2, peak: 0.5)
        let r2 = DictationAudioLevel(level: 0.7, peak: 0.9)
        let r3 = DictationAudioLevel(level: 0.1)
        levels.update(r1)
        levels.update(r2)
        levels.update(r3)

        // Checked synchronously: no await, no run loop spin.
        assertEqual(received, [initial, r1, r2, r3], "subscriber should get the current reading, then each update in order")
        assertEqual(levels.current, r3, "current should be the last reading")

        levels.update(r3)
        levels.update(r3)
        assertEqual(received, [initial, r1, r2, r3, r3, r3], "repeated readings are delivered too")
        subscription.cancel()
    }

    runSuite("A late subscriber starts from the latest reading") {
        let levels = DictationAudioLevels()
        let latest = DictationAudioLevel(level: 0.3, peak: 0.6)
        levels.update(DictationAudioLevel(level: 0.9))
        levels.update(latest)

        var received: [DictationAudioLevel] = []
        let subscription = levels.readings.sink { received.append($0) }
        assertEqual(received, [latest], "a new subscriber should see the current reading first, not the history")
        subscription.cancel()
    }

    runSuite("A reading's peak is never below its level") {
        let defaulted = DictationAudioLevel(level: 0.4)
        assertEqual(defaulted.level, 0.4)
        assertEqual(defaulted.peak, 0.4, "peak defaults to the level")

        let kept = DictationAudioLevel(level: 0.3, peak: 0.8)
        assertEqual(kept.level, 0.3)
        assertEqual(kept.peak, 0.8, "a louder peak is kept")

        let raised = DictationAudioLevel(level: 0.6, peak: 0.2)
        assertEqual(raised.level, 0.6)
        assertEqual(raised.peak, 0.6, "a peak below the level is raised to the level")

        assertEqual(DictationAudioLevel.silent.level, 0)
        assertEqual(DictationAudioLevel.silent.peak, 0)
    }
}
