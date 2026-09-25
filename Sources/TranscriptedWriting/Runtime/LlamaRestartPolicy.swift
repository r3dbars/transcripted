import Foundation

/// Bounded backoff keeps a broken helper from spinning without permanently
/// disabling autocomplete. A proven run resets the delay.
struct LlamaRestartPolicy {
    private(set) var failures = 0

    mutating func delay(wasHealthy: Bool, uptime: TimeInterval) -> TimeInterval {
        if wasHealthy, uptime >= 120 { failures = 0 }
        let delay = min(60.0, pow(2.0, Double(failures)) * 2.0)
        failures += 1
        return delay
    }
}
