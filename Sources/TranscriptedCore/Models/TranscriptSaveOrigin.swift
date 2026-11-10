import Foundation

/// The operation that published a saved status. A speaker-name edit can save an
/// older transcript while another pipeline job is still running.
public enum TranscriptSaveOrigin: Equatable, Sendable {
    case pipeline
    case speakerReview
}
