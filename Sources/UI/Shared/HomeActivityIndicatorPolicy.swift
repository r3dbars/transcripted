import Foundation

/// What the status line of a Home activity row shows beside its text. Only active
/// work spins; a saved or failed row shows a still status icon, so a finished
/// transcription never looks busy.
enum HomeActivityIndicator: Equatable {
    case spinner
    case statusIcon(isSuccess: Bool)

    static func make(isWorking: Bool, isSuccess: Bool) -> HomeActivityIndicator {
        isWorking ? .spinner : .statusIcon(isSuccess: isSuccess)
    }
}
