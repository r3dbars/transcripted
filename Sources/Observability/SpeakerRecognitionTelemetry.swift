import Foundation

/// Bucketing for speaker-recognition accuracy analytics.
///
/// Only these coarse enum buckets leave the device — never raw similarity
/// values, margins, profile ids, or names. The buckets are aligned with the
/// matcher's decision thresholds (match floors around 0.55–0.85, auto-accept
/// at 0.92, margin guard at 0.12) so fleet-wide correction rates per bucket
/// can be read directly against the gates they should retune.
enum SpeakerRecognitionTelemetry {

    static func similarityBucket(_ similarity: Double?) -> String {
        guard let similarity else { return "none" }
        switch similarity {
        case ..<0.6:
            return "lt_0_60"
        case ..<0.7:
            return "0_60_69"
        case ..<0.8:
            return "0_70_79"
        case ..<0.92:
            return "0_80_91"
        default:
            return "0_92_plus"
        }
    }

    /// Margin between best match and runner-up. A negative runner-up is the
    /// matcher's "nothing else cleared the floor" sentinel — an unambiguous win.
    static func marginBucket(similarity: Double?, secondSimilarity: Double?) -> String {
        guard let similarity else { return "none" }
        guard let second = secondSimilarity, second >= 0 else { return "no_runner_up" }
        switch similarity - second {
        case ..<0.05:
            return "lt_0_05"
        case ..<0.12:
            return "0_05_11"
        case ..<0.25:
            return "0_12_24"
        default:
            return "0_25_plus"
        }
    }
}
