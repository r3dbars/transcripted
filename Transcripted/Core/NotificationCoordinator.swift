import Foundation
import UserNotifications
import AppKit

// MARK: - Notification Categories, Permissions & Delegate

@available(macOS 26.0, *)
extension AppDelegate {

    /// Register notification categories and request permission (call once during setupApp)
    func registerNotificationCategories() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // "Stop" action for auto-detect recording notifications
        let stopAction = UNNotificationAction(
            identifier: "STOP_RECORDING",
            title: "Stop",
            options: .destructive
        )
        let autoDetectCategory = UNNotificationCategory(
            identifier: "AUTO_DETECT_RECORDING",
            actions: [stopAction],
            intentIdentifiers: []
        )

        // "Show in Finder" action for transcript saved notifications
        let showAction = UNNotificationAction(
            identifier: TranscriptSaver.showInFinderActionId,
            title: "Show in Finder",
            options: .foreground
        )
        let savedCategory = UNNotificationCategory(
            identifier: TranscriptSaver.notificationCategoryId,
            actions: [showAction],
            intentIdentifiers: []
        )

        center.setNotificationCategories([autoDetectCategory, savedCategory])

        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                AppLogger.app.info("Notification permission granted")
            } else if let error = error {
                AppLogger.app.debug("Notification permission error", ["error": error.localizedDescription])
            } else {
                AppLogger.app.info("Notification permission denied by user")
            }
        }
    }

    /// Notify user that auto-detect started a recording.
    /// Guards on authorization status to avoid UNErrorDomain error 1.
    func sendAutoDetectStartNotification(appName: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                AppLogger.app.debug("Skipping auto-detect start notification — not authorized")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Recording Started"
            content.body = "Transcripted detected \(appName) and started recording."
            content.categoryIdentifier = "AUTO_DETECT_RECORDING"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "auto-detect-start",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    /// Notify user that auto-detect stopped a recording.
    /// Guards on authorization status to avoid UNErrorDomain error 1.
    func sendAutoDetectStopNotification(duration: TimeInterval) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                AppLogger.app.debug("Skipping auto-detect stop notification — not authorized")
                return
            }

            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            let durationStr = String(format: "%d:%02d", minutes, seconds)

            let content = UNMutableNotificationContent()
            content.title = "Recording Saved"
            content.body = "\(durationStr) meeting transcribed."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "auto-detect-stop",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func handleNotificationResponse(
        _ response: UNNotificationResponse,
        completionHandler: @escaping () -> Void
    ) {
        let actionId = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo

        Task { @MainActor in
            switch actionId {
            case "STOP_RECORDING":
                self.audio?.stop()
            case TranscriptSaver.showInFinderActionId:
                if let path = userInfo["fileURL"] as? String {
                    let url = URL(fileURLWithPath: path)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            default:
                break
            }
        }

        completionHandler()
    }
}
