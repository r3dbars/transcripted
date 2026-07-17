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
        message(for: caseValue(for: status))
    }

    static func caseValue(for status: SystemAudioStatus) -> Case {
        switch status {
        case .unknown:
            return .unknown
        case .healthy:
            return .healthy
        case .reconnecting:
            return .reconnecting
        case .silent:
            return .silent
        case .failed:
            return .failed
        }
    }
}
