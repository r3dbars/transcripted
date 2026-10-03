import Combine
import Foundation

/// The whole percent Home's working row shows for a progress value, or nil
/// when it shows none. The row and the render key both use this, so the
/// shell re-renders exactly when the visible number changes.
enum HomeActivityPercent {
    static func displayed(_ progress: Double?) -> Int? {
        guard let progress, progress > 0 else { return nil }
        return Int(progress * 100)
    }
}

/// Everything the Settings shell shows from the meeting session, reduced to
/// what changes the window. `coarse` holds the plain values that only move
/// on real events (state, saved title, failed meetings, ...). The recording
/// duration is never part of it: the elapsed label is its own leaf view.
struct SettingsMeetingRenderKey<Coarse: Equatable>: Equatable {
    let coarse: Coarse
    /// Home's displayed percent, only while Home is the selected page.
    let activityPercent: Int?
    /// Pages show relative times ("Now 3:41 PM"), so a minute boundary
    /// counts as a change while the session is publishing.
    let wallMinute: Int

    static func make(
        coarse: Coarse,
        activityProgress: Double?,
        showsActivityPercent: Bool,
        now: Date
    ) -> SettingsMeetingRenderKey {
        SettingsMeetingRenderKey(
            coarse: coarse,
            activityPercent: showsActivityPercent ? HomeActivityPercent.displayed(activityProgress) : nil,
            wallMinute: Int((now.timeIntervalSinceReferenceDate / 60).rounded(.down))
        )
    }
}

/// Stands between a chatty `ObservableObject` (the meeting session publishes
/// on every duration tick and progress step) and a view that only needs a
/// few of its values. Each burst of changes is evaluated once, on the next
/// main-actor turn (`@Published` fires before the value lands), and the
/// gate publishes only when the key differs from the last one.
@MainActor
final class SettingsMeetingRenderGate<Key: Equatable>: ObservableObject {
    typealias Scheduler = (@escaping @MainActor () -> Void) -> Void

    private(set) var key: Key
    private let makeKey: @MainActor () -> Key
    private let schedule: Scheduler
    private var isEvaluationPending = false
    private var subscription: AnyCancellable?

    init<Changes: Publisher>(
        changes: Changes,
        makeKey: @escaping @MainActor () -> Key,
        schedule: @escaping Scheduler = SettingsMeetingRenderGate.nextMainActorTurn
    ) where Changes.Failure == Never {
        self.makeKey = makeKey
        self.schedule = schedule
        self.key = makeKey()
        subscription = changes.sink { [weak self] _ in
            self?.changeDidArrive()
        }
    }

    /// Run `work` after the current main-actor turn. Not `RunLoop.main`,
    /// which stalls while a menu is tracking.
    nonisolated static func nextMainActorTurn(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in work() }
    }

    func changeDidArrive() {
        guard !isEvaluationPending else { return }
        isEvaluationPending = true
        schedule { [weak self] in
            self?.evaluate()
        }
    }

    private func evaluate() {
        isEvaluationPending = false
        let next = makeKey()
        guard next != key else { return }
        key = next
        objectWillChange.send()
    }
}
