import Combine
import Foundation

@MainActor
func testDictationAudioLevels() {
    // The router owns the dictation level as a `let`, like this host. A level
    // tick must not fire the owner's objectWillChange, or the Settings/Home
    // window (which observes the router) re-renders 20 times a second for the
    // whole take, even while closed.
    @MainActor
    final class RouterLikeOwner: ObservableObject {
        let audioLevels = DictationAudioLevels()
        @Published var isRecording = false
    }

    runSuite("Dictation level ticks don't fire the owning router's objectWillChange") {
        let owner = RouterLikeOwner()
        var ownerChanges = 0
        let cancellable = owner.objectWillChange.sink { _ in ownerChanges += 1 }

        for level in [Float(0.1), 0.4, 0.4, 0] {
            owner.audioLevels.update(level)
        }
        assertEqual(ownerChanges, 0, "level ticks should stay off the router's objectWillChange")

        owner.isRecording = true
        assertEqual(ownerChanges, 1, "real router state changes still notify observers")
        cancellable.cancel()
    }

    runSuite("The island meter gets every dictation level, in order, repeats included") {
        let levels = DictationAudioLevels()
        var seen: [Float] = []
        let sub = levels.$level.sink { seen.append($0) }

        for level in [Float(0.1), 0.4, 0.4, 0] {
            levels.update(level)
        }

        // Initial value on subscribe, then each update; the waveform draws
        // every tick, so nothing may be deduplicated or throttled.
        assertEqual(seen, [0, 0.1, 0.4, 0.4, 0])
        assertEqual(levels.level, 0)
        sub.cancel()
    }
}
