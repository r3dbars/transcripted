import Foundation
import TranscriptedCore

/// `SystemAudioStatus` bridge for `MeetingSystemAudioStatusCopy`.
///
/// Kept out of the Foundation-pure base file so the fast-test runner can
/// compile the copy mapping without linking the `Audio` module that defines
/// `SystemAudioStatus`. This overload only forwards each `SystemAudioStatus`
/// case to the matching Foundation-pure `Case`, so behavior stays identical.
extension MeetingSystemAudioStatusCopy {
    static func message(for status: SystemAudioStatus) -> String {
        switch status {
        case .unknown:
            return message(for: Case.unknown)
        case .healthy:
            return message(for: Case.healthy)
        case .reconnecting:
            return message(for: Case.reconnecting)
        case .silent:
            return message(for: Case.silent)
        case .failed:
            return message(for: Case.failed)
        }
    }
}
