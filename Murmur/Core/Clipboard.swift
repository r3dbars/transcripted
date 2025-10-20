import Foundation
import AppKit
import UserNotifications

class Clipboard {
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        print("✓ Copied: \"\(text.prefix(50))\(text.count > 50 ? "..." : "")\"")
        showNotification(text: text)
    }

    private static func showNotification(text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Murmur"
        content.body = "Transcription copied: \(String(text.prefix(100)))"

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("⚠️ Notification failed: \(error.localizedDescription)")
            }
        }
    }
}
