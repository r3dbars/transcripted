import Foundation

/// Local event monitors see every app window. Recording belongs only to the
/// window that opened the recorder, including its modifier press/release pair.
enum ShortcutRecordingEventPolicy {
    enum Action: Equatable {
        case record
        case passAndClearPending
        case stopAndPass
    }

    static func action(owner: ObjectIdentifier?, eventWindow: ObjectIdentifier?, ownerVisible: Bool) -> Action {
        guard let owner, ownerVisible else { return .stopAndPass }
        return eventWindow == owner ? .record : .passAndClearPending
    }
}
