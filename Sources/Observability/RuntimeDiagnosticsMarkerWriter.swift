import Foundation
import Synchronization

/// Writes the runtime-diagnostics marker off the main thread, in order, with
/// latest-wins coalescing: while one save runs, at most one newer snapshot
/// waits, and newer submits replace it.
///
/// Only the periodic heartbeat uses `submit`. `writeNow` is for the launch,
/// stage and clean-shutdown markers, so crash evidence is on disk before the
/// caller moves on, as on main. It runs on the same
/// serial queue behind anything already queued, so an older queued snapshot
/// can never land after it. Nothing on this queue touches the main thread or
/// the main actor, so calling `writeNow` from main can't deadlock.
final class RuntimeDiagnosticsMarkerWriter: Sendable {
    typealias Save = @Sendable (RuntimeDiagnosticsMarker, URL) -> Void

    private let queue = DispatchQueue(label: "app.runtime-diagnostics-marker", qos: .userInitiated)
    private let pending = Mutex<RuntimeDiagnosticsMarker?>(nil)
    private let url: URL
    private let save: Save

    init(url: URL, save: @escaping Save = { RuntimeDiagnosticsStore.save($0, to: $1) }) {
        self.url = url
        self.save = save
    }

    /// Queue a snapshot. Returns without waiting for disk.
    func submit(_ snapshot: RuntimeDiagnosticsMarker) {
        let slotWasEmpty = pending.withLock { slot -> Bool in
            let wasEmpty = slot == nil
            slot = snapshot
            return wasEmpty
        }
        guard slotWasEmpty else { return }
        queue.async { [self] in
            guard let latest = pending.withLock({ slot -> RuntimeDiagnosticsMarker? in
                let value = slot
                slot = nil
                return value
            }) else { return }
            save(latest, url)
        }
    }

    /// Write a snapshot before returning, after any queued write, and
    /// discard any snapshot still waiting (it's older than this one).
    func writeNow(_ snapshot: RuntimeDiagnosticsMarker) {
        queue.sync {
            pending.withLock { $0 = nil }
            save(snapshot, url)
        }
    }
}
