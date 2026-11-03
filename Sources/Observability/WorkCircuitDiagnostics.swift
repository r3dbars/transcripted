import Foundation

/// Fixed vocabulary for refused/timed-out native work. `work_step` describes
/// the requested operation; it does not claim which earlier call got stuck.
/// Never forward an operation string or a native error description directly.
enum WorkCircuitDiagnostics {
    enum Source: String, CaseIterable {
        case systemInput = "system_input"
        case engineGraph = "engine_graph"
    }

    enum Step: String, CaseIterable {
        case selection, snapshot, readiness, prepare, start, stop, reset, unknown
    }

    static let keys: Set<String> = ["work_source", "work_step", "inflight_bucket"]
    private static let inflightBuckets: Set<String> = ["0", "1", "2_3", "4_plus", "unknown"]

    static func properties(source: Source, operation: String, inflight: Int? = nil) -> [String: String] {
        [
            "work_source": source.rawValue,
            "work_step": step(for: operation).rawValue,
            "inflight_bucket": bucket(inflight),
        ]
    }

    /// Known keys accept only their fixed enums, including in untyped Sentry
    /// dictionaries. All other keys retain their destination's own policy.
    static func allows(key: String, value: Any) -> Bool {
        guard keys.contains(key) else { return true }
        guard let string = value as? String else { return false }
        switch key {
        case "work_source": return Source(rawValue: string) != nil
        case "work_step": return Step(rawValue: string) != nil
        case "inflight_bucket": return inflightBuckets.contains(string)
        default: return false
        }
    }

    private static func step(for operation: String) -> Step {
        switch operation {
        case "start_recording_selection": return .selection
        case "start_recording_snapshot", "start_recording_settled_snapshot": return .snapshot
        case "prewarm_selection", "prewarm_snapshot", "prewarm_settled_snapshot",
             "pinned_dictation_warmup_decision": return .readiness
        case "pinned_dictation_prepare": return .prepare
        case "start_recording", "pinned_dictation_start": return .start
        case "pinned_dictation_stop": return .stop
        case "zombie_engine_reset": return .reset
        default: return .unknown
        }
    }

    private static func bucket(_ count: Int?) -> String {
        guard let count, count >= 0 else { return "unknown" }
        switch count {
        case 0: return "0"
        case 1: return "1"
        case 2...3: return "2_3"
        default: return "4_plus"
        }
    }
}
