import Foundation

/// A shared Whisper engine's publication belongs to one concrete model.
enum WhisperModelStatePolicy {
    static func state(
        for requested: TranscriptionModelChoice,
        owner: TranscriptionModelChoice?,
        storedState: ParakeetModelState,
        emittedState: ParakeetModelState? = nil
    ) -> ParakeetModelState {
        guard requested.isWhisper, requested == owner else { return .notLoaded }
        return emittedState ?? storedState
    }
}
