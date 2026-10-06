// DictationTranscribeAgainRunner.swift
// Runs Transcribe again for one saved dictation at a time, app-wide.

import Foundation

/// Tracks the one dictation being transcribed again. Shared (like
/// `CaptureUndoManager.shared`) so the in-progress state survives leaving the
/// Dictations page and coming back while the model runs.
@MainActor
final class DictationTranscribeAgainRunner: ObservableObject {
    static let shared = DictationTranscribeAgainRunner()

    @Published private(set) var runningEntryID: String?

    /// Starts Transcribe again for `entry` unless one is already running.
    /// `transcribe` gets 16 kHz mono samples decoded from the kept file;
    /// `onFailure` gets a plain-words message. Returns false when it didn't
    /// start.
    @discardableResult
    func start(
        entry: SavedDictationEntry,
        audioURL: URL,
        cleanupEnabled: Bool = DictationCleanupPreferences.isEnabled(),
        transcribe: @escaping ([Float]) async throws -> String,
        onFailure: @escaping (String) -> Void
    ) -> Bool {
        guard runningEntryID == nil else { return false }
        runningEntryID = entry.id
        Task { @MainActor in
            defer { runningEntryID = nil }
            do {
                _ = try await DictationRetranscription.run(
                    entry: entry,
                    audioURL: audioURL,
                    cleanupEnabled: cleanupEnabled,
                    transcribe: transcribe
                )
            } catch let failure as DictationRetranscription.Failure {
                onFailure(failure.message)
            } catch DictationEntryTextRewrite.RewriteError.entryNotFound {
                onFailure("This dictation changed or was deleted while it was being transcribed again, so nothing was saved.")
            } catch {
                onFailure("Transcripted couldn't transcribe this dictation again. The original text was kept.")
            }
        }
        return true
    }
}
