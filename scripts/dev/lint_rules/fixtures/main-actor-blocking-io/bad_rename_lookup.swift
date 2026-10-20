// lint-fixture-path: Sources/UI/Settings/ExampleSettingsView+HomeActions.swift
// Shape of 5649d7cd7^: the rename runs detached, but the audio lookup after it
// runs back on the main actor.
import Foundation

@MainActor
final class ExampleHomeActions {
    func rename(sourceURL: URL, rawTitle: String) {
        let renameTask = Task.detached(priority: .userInitiated) { () throws -> HomeMeetingRenameResult in
            try HomeMeetingRename.rename(transcriptAt: sourceURL, to: rawTitle)
        }
        Task { @MainActor in
            let result = try await renameTask.value
            let audio = MeetingAudioArchiveResolver.attachment(forTranscript: result.transcriptURL)
            show(result, audio)
        }
    }
}
