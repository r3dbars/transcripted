import Foundation

enum ImportedAudioQueuePersistenceFailureCopy {
    static let retryEntryMessage =
        "Imported audio was saved after Transcripted couldn't add it to the transcription queue. Finish the transcript from Home."

    static func displayMessage(preservedForRelaunch: Bool) -> String {
        if preservedForRelaunch {
            return "Transcripted couldn't safely queue that import. The copied audio was saved for retry in Home."
        }
        return "Transcripted couldn't safely queue that import or save a retry entry. Import the original file again."
    }
}

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
