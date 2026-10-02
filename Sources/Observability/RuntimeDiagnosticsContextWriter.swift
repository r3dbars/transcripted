import Foundation

/// Preference reads can wait on cfprefsd. Keep runtime scope updates off the
/// main thread, in submission order, without delaying capture or the heartbeat.
final class RuntimeDiagnosticsContextWriter: Sendable {
    private let queue = DispatchQueue(label: "app.runtime-diagnostics-context", qos: .utility)
    private let apply: @Sendable ([String: String]) -> Void

    init(apply: @escaping @Sendable ([String: String]) -> Void) {
        self.apply = apply
    }

    func submit(_ context: [String: String]) {
        queue.async { [apply] in apply(context) }
    }
}
