import Foundation

/// User-facing diagnostic copy for system-audio capture status changes.
///
/// The copy mapping is keyed on a Foundation-pure `Case` so it can be
/// unit-tested in the fast-test runner without pulling the
/// AVFoundation/AppKit/CoreAudio-heavy `Audio` module that defines
/// `SystemAudioStatus`. The thin `SystemAudioStatus` overload lives in
/// `MeetingSystemAudioStatusCopy+SystemAudioStatus.swift` (app build only) and
/// forwards each case here, so the two paths stay byte-for-byte aligned.
enum MeetingSystemAudioStatusCopy {
    /// Foundation-pure mirror of `SystemAudioStatus`'s cases.
    enum Case {
        case unknown
        case healthy
        case reconnecting
        case silent
        case failed
    }

    static func message(for status: Case) -> String {
        switch status {
        case .unknown:
            return "System audio status reset"
        case .healthy:
            return "System audio capture is healthy"
        case .reconnecting:
            return "System audio capture is reconnecting"
        case .silent:
            return "System audio capture is silent"
        case .failed:
            return "System audio capture failed"
        }
    }
}
