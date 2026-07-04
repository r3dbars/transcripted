import Foundation

func testMeetingImportPreparationFailureCopy() {
    runSuite("MeetingImportPreparationFailureCopy.kind maps preparation errors to stable diagnostic kinds") {
        assertEqual(
            MeetingImportPreparationFailureCopy.kind(for: MeetingImportedAudioPreparationError.fileMissing),
            MeetingFailureKind.importFileMissing.rawValue,
            "a missing selected file should classify as import_file_missing"
        )
        assertEqual(
            MeetingImportPreparationFailureCopy.kind(for: MeetingImportedAudioPreparationError.cannotInspect),
            MeetingFailureKind.importFileUnreadable.rawValue,
            "an uninspectable file should classify as import_file_unreadable"
        )
        assertEqual(
            MeetingImportPreparationFailureCopy.kind(for: MeetingImportedAudioPreparationError.unreadable),
            MeetingFailureKind.importFileUnreadable.rawValue,
            "an unreadable file should classify as import_file_unreadable"
        )
        assertEqual(
            MeetingImportPreparationFailureCopy.kind(for: MeetingImportedAudioPreparationError.notRegularFile),
            MeetingFailureKind.importUnsupportedFile.rawValue,
            "a non-regular-file selection should classify as import_unsupported_file"
        )
        assertEqual(
            MeetingImportPreparationFailureCopy.kind(for: MeetingImportedAudioPreparationError.unsupportedAudioType),
            MeetingFailureKind.importUnsupportedFile.rawValue,
            "an unsupported audio type should classify as import_unsupported_file"
        )
        assertEqual(
            MeetingImportPreparationFailureCopy.kind(for: MeetingImportedAudioPreparationError.copyFailed),
            MeetingFailureKind.importCopyFailed.rawValue,
            "a copy failure should classify as import_copy_failed"
        )
    }

    runSuite("MeetingImportPreparationFailureCopy.kind falls back to MeetingFailureKind for unrelated errors") {
        struct OtherError: LocalizedError {
            var errorDescription: String? { "System audio is required. Turn on System Audio Recording and retry." }
        }

        assertEqual(
            MeetingImportPreparationFailureCopy.kind(for: OtherError()),
            MeetingFailureKind.systemAudioPermission.rawValue,
            "non-preparation errors should still classify through the shared MeetingFailureKind taxonomy"
        )
    }

    runSuite("MeetingImportPreparationFailureCopy.message surfaces preparation-specific copy") {
        assertEqual(
            MeetingImportPreparationFailureCopy.message(for: MeetingImportedAudioPreparationError.fileMissing),
            "The selected audio file could not be found. It may have been moved or deleted.",
            "file-missing copy should point at the moved-or-deleted explanation"
        )
        assertEqual(
            MeetingImportPreparationFailureCopy.message(for: MeetingImportedAudioPreparationError.unsupportedAudioType),
            "That file does not include a readable audio track. Choose a WAV, MP3, M4A, AAC, AIFF, MP4, or MOV file.",
            "unsupported audio copy should list accepted formats"
        )
    }

    runSuite("MeetingImportPreparationFailureCopy.message falls back to generic retry copy for unrelated errors") {
        struct OtherError: LocalizedError {
            var errorDescription: String? { nil }
        }

        assertEqual(
            MeetingImportPreparationFailureCopy.message(for: OtherError()),
            "Transcripted couldn't prepare that audio file. Try choosing it again, or convert it to WAV or M4A first.",
            "non-preparation errors without a description should get the generic retry message"
        )
    }
}
