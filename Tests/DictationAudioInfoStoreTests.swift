import Combine
import Foundation

@MainActor
func testDictationAudioInfoStore() {
    runSuite("Audio info publishes only changed card availability or duration") {
        let store = DictationAudioInfoStore()
        var published: [[String: DictationAudioInfoStore.Info]] = []
        let subscription = store.$infos.sink { published.append($0) }
        let miss = DictationAudioInfoStore.Info(isAvailable: false, duration: nil)
        let available = DictationAudioInfoStore.Info(isAvailable: true, duration: 2)
        let changedDuration = DictationAudioInfoStore.Info(isAvailable: true, duration: 3)
        assertEqual(published, [[:]], "a new subscriber receives the initial empty value")

        store.updateInfo(miss, for: "synthetic-first")
        assertEqual(published.count, 2, "the first result publishes even when it is a miss")
        assertEqual(published.last?["synthetic-first"], miss)
        store.updateInfo(miss, for: "synthetic-first")
        assertEqual(published.count, 2, "a repeated missing result does not publish")

        store.updateInfo(available, for: "synthetic-first")
        assertEqual(published.count, 3, "newly available audio publishes")
        assertEqual(published.last?["synthetic-first"], available)
        store.updateInfo(available, for: "synthetic-first")
        assertEqual(published.count, 3, "unchanged available facts are also silent")
        store.updateInfo(changedDuration, for: "synthetic-first")
        assertEqual(published.count, 4, "a changed duration publishes")
        assertEqual(published.last?["synthetic-first"], changedDuration)
        store.updateInfo(changedDuration, for: "synthetic-first")
        assertEqual(published.count, 4, "the same changed duration is silent")

        store.updateInfo(miss, for: "synthetic-first")
        assertEqual(published.count, 5, "losing a previously available file publishes")
        store.updateInfo(miss, for: "synthetic-first")
        assertEqual(published.count, 5, "repeat invalidation remains silent")
        store.updateInfo(miss, for: "synthetic-second")
        assertEqual(published.count, 6, "a different entry gets its own first result")
        assertEqual(published.last, ["synthetic-first": miss, "synthetic-second": miss])
        withExtendedLifetime(subscription) {}
    }
}
