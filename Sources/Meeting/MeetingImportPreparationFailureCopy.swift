import Foundation

/// Maps an imported-audio preparation failure into the shared failure-kind
/// taxonomy and user-facing copy. Extracted from `MeetingSessionController`
/// so this classification stays unit-testable without instantiating the
/// controller.
enum MeetingImportPreparationFailureCopy {
    static func kind(for error: Error) -> String {
        if let preparationError = error as? MeetingImportedAudioPreparationError {
            return preparationError.diagnosticKind
        }

        return MeetingFailureKind.classify(message: error.localizedDescription).rawValue
    }

    static func message(for error: Error) -> String {
        if let preparationError = error as? MeetingImportedAudioPreparationError,
           let description = preparationError.errorDescription {
            return description
        }

        return "Transcripted couldn't prepare that audio file. Try choosing it again, or convert it to WAV or M4A first."
    }
}
