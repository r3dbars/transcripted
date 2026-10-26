// lint-fixture-path: Sources/UI/Settings/ExampleSettingsView+Pages.swift
// The fixed shapes (5f7a490b8, 5649d7cd7): file work inside Task.detached,
// including a wrapped `Task.detached(\n priority:\n) {` call, a background
// queue, a continuation and a nonisolated helper.
import SwiftUI

struct ExampleSettingsView: View {
    var body: some View { Text("x") }
}

extension ExampleSettingsView {
    private func deleteDictationWithUndo(_ entry: SavedDictationEntry) {
        Task { @MainActor in
            do {
                let undoPayload = try await Task.detached(priority: .userInitiated) {
                    try DictationTranscriptStore.deleteEntryReversibly(entry)
                }.value
                stage(undoPayload)
            } catch {
                presentFailure(error)
            }
        }
    }

    private func rename(sourceURL: URL, rawTitle: String) {
        let renameTask = Task.detached(
            priority: .userInitiated
        ) { () throws -> (HomeMeetingRenameResult, MeetingAudioAttachment?) in
            let result = try HomeMeetingRename.rename(transcriptAt: sourceURL, to: rawTitle)
            return (result, MeetingAudioArchiveResolver.attachment(forTranscript: result.transcriptURL))
        }
        Task { @MainActor in
            let (result, audio) = try await renameTask.value
            show(result, audio)
        }
    }

    private func cleanUp(_ url: URL) {
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func load(_ url: URL) async -> Data? {
        await withCheckedContinuation { continuation in
            continuation.resume(returning: try? Data(contentsOf: url))
        }
    }

    nonisolated private static func resolve(_ url: URL) -> URL? {
        // OwnFileResolver.resolveExistingFile(candidateURLs: [url]) in a comment is fine.
        OwnFileResolver.resolveExistingFile(candidateURLs: [url])
    }
}

// A non-UI type with no main-actor isolation may call the helpers directly.
enum ExampleArchiveWorker {
    static func run(_ entry: SavedDictationEntry) throws {
        _ = try DictationTranscriptStore.deleteEntryReversibly(entry)
        let message = "Data(contentsOf: url) inside a string is fine"
        _ = message
    }
}
