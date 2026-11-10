import Foundation

/// Merge diagnostics accept only metrics, never speaker identities or names.
enum SpeakerMergeLogMetadata {
    static func explicit(newCallCount: Int) -> [String: String] {
        ["newCallCount": "\(newCallCount)"]
    }

    static func duplicate(similarity: Double) -> [String: String] {
        ["similarity": String(format: "%.3f", similarity)]
    }
}
