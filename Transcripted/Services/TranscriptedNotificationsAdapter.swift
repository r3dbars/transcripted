// TranscriptedNotificationsAdapter.swift
// Embedder-side concrete conformer for TranscriptedCore's `TranscriptNotifier` protocol.
//
// Core is UI-framework-agnostic and only calls through the protocol. This adapter wraps
// `UNUserNotificationCenter` and sets the `TRANSCRIPT_SAVED` category identifier on
// delivered notifications so the "Show in Finder" action button (registered by
// `NotificationCoordinator.registerNotificationCategories()`) is attached. Before
// extraction, `TranscriptSaver` called `UNUserNotificationCenter` directly and set
// the category inline; after extraction Core became a library and that responsibility
// moved here.
//
// Also stashes the saved transcript path in `userInfo["fileURL"]` so that
// `AppDelegate.handleNotificationResponse` can resolve the path back into a URL and
// call `NSWorkspace.shared.activateFileViewerSelecting` when the user taps
// "Show in Finder".

import Foundation
import UserNotifications
import TranscriptedCore

@available(macOS 26.0, *)
@MainActor
final class TranscriptedNotificationsAdapter: TranscriptNotifier {

    private let transcriptSavedCategoryId = "TRANSCRIPT_SAVED"

    // MARK: - TranscriptNotifier

    func notifyTranscriptSaved(fileURL: URL) {
        let savedPath = fileURL.path
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                AppLogger.app.debug("Skipping transcript-saved notification — not authorized")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Transcript Saved"
            content.body = fileURL.lastPathComponent
            content.sound = .default
            content.categoryIdentifier = self.transcriptSavedCategoryId
            content.userInfo = ["fileURL": savedPath]

            let request = UNNotificationRequest(
                identifier: "transcript-saved-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    AppLogger.app.debug("Failed to post transcript-saved notification", ["error": error.localizedDescription])
                }
            }
        }
    }

    func notifyTranscriptionFailed(errorMessage: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                AppLogger.app.debug("Skipping transcription-failed notification — not authorized")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Transcription Failed"
            content.body = errorMessage
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "transcription-failed-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    AppLogger.app.debug("Failed to post transcription-failed notification", ["error": error.localizedDescription])
                }
            }
        }
    }

    func requestNotificationPermission() {
        // Permission is requested once during `AppDelegate.registerNotificationCategories()`
        // which runs at the start of `setupApp()`. This is a no-op to satisfy the protocol
        // without double-prompting the user.
    }
}
