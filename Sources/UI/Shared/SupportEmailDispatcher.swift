import AppKit
import Foundation

/// Shared mail handoff for menu-bar support and capture-specific feedback.
/// A failed handoff leaves the caller's draft intact and never changes the
/// clipboard unless the user explicitly chooses Copy Address.
@MainActor
enum SupportEmailDispatcher {
    enum FallbackAction {
        case dismiss
        case copyAddress
    }

    @discardableResult
    static func open(
        _ url: URL?,
        openURL: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        presentFallback: @MainActor () -> FallbackAction = { presentNativeFallback() },
        copyAddress: @MainActor (String) -> Void = { address in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
        }
    ) -> Bool {
        if let url, openURL(url) {
            return true
        }

        if presentFallback() == .copyAddress {
            copyAddress(FeedbackIssueBuilder.supportEmailAddress)
        }
        return false
    }

    private static func presentNativeFallback() -> FallbackAction {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t open your email app"
        alert.informativeText = "You can email \(FeedbackIssueBuilder.supportEmailAddress) from your browser or set up a default email app, then try again. Nothing has been sent."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Address")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn ? .copyAddress : .dismiss
    }
}
