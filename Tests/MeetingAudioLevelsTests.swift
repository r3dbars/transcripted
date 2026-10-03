import Combine
import Foundation

@MainActor
func testMeetingAudioLevels() {
    // The session owns its meter levels as a `let`, like this host. A level
    // tick must not fire the owner's objectWillChange, or every window that
    // observes the whole session re-renders several times a second.
    @MainActor
    final class SessionLikeOwner: ObservableObject {
        let audioLevels = MeetingAudioLevels()
        @Published var displayStatus = 0
    }

    runSuite("Meter level ticks don't fire the owning session's objectWillChange") {
        let owner = SessionLikeOwner()
        var ownerChanges = 0
        let cancellable = owner.objectWillChange.sink { _ in ownerChanges += 1 }

        for level in [Float(0.1), 0.2, 0.3] {
            owner.audioLevels.updateMic(level)
            owner.audioLevels.updateSystem(level)
        }
        assertEqual(ownerChanges, 0, "level ticks should stay off the session's objectWillChange")

        owner.displayStatus = 1
        assertEqual(ownerChanges, 1, "real session state changes still notify observers")
        cancellable.cancel()
    }

    runSuite("The overlay gets every mic and system level, in order, one per update") {
        let levels = MeetingAudioLevels()
        var mic: [Float] = []
        var system: [Float] = []
        let micSub = levels.$micLevel.sink { mic.append($0) }
        let systemSub = levels.$systemLevel.sink { system.append($0) }

        levels.updateMic(0.4)
        levels.updateMic(0.4)
        levels.updateSystem(0.7)
        levels.updateMic(0)
        levels.updateSystem(0.2)

        // Initial value on subscribe, then each update, repeats included.
        assertEqual(mic, [0, 0.4, 0.4, 0])
        assertEqual(system, [0, 0.7, 0.2])
        assertEqual(levels.micLevel, 0)
        assertEqual(levels.systemLevel, 0.2)
        micSub.cancel()
        systemSub.cancel()
    }
}
