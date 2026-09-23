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

    /// Returns whether the mail app took the draft. The fallback answers
    /// later: it is a normal window, not an app-modal loop, so a recording's
    /// Stop hotkey and menu keep working while it is up.
    @discardableResult
    static func open(
        _ url: URL?,
        openURL: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        presentFallback: @MainActor (@escaping @MainActor (FallbackAction) -> Void) -> Void = { presentNativeFallback(completion: $0) },
        copyAddress: @escaping @MainActor (String) -> Void = { address in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
        }
    ) -> Bool {
        if let url, openURL(url) {
            return true
        }

        presentFallback { action in
            if action == .copyAddress {
                copyAddress(FeedbackIssueBuilder.supportEmailAddress)
            }
        }
        return false
    }

    /// The fallback on screen, kept alive until a button closes it. A second
    /// failure while it is up brings it forward instead of stacking another,
    /// and its answer goes to the newest caller.
    private static var activeFallback: NonModalAlert?
    private static var activeFallbackCompletion: (@MainActor (FallbackAction) -> Void)?

    private static func presentNativeFallback(completion: @escaping @MainActor (FallbackAction) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        activeFallbackCompletion = completion
        if let activeFallback, activeFallback.isShowing {
            activeFallback.bringToFront()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t open your email app"
        alert.informativeText = "You can email \(FeedbackIssueBuilder.supportEmailAddress) from your browser or set up a default email app, then try again. Nothing has been sent."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Address")

        let presented = NonModalAlert(alert: alert) { buttonIndex in
            let answer = activeFallbackCompletion
            activeFallbackCompletion = nil
            answer?(buttonIndex == 1 ? .copyAddress : .dismiss)
            // This runs inside the panel's own button action. Dropping the
            // last reference now would free the panel and button while AppKit
            // is still unwinding the click, so hold it until a later turn. A
            // new fallback shown before then stays in place.
            let retired = activeFallback
            Task { @MainActor in
                if activeFallback === retired {
                    activeFallback = nil
                }
                withExtendedLifetime(retired) {}
            }
        }
        activeFallback = presented
        presented.show()
    }
}

/// Shows an `NSAlert`'s window without `runModal()`. An app-modal loop keeps
/// menu-bar commands such as Stop from running while it waits (see
/// 6ca91395), so this alert just routes its buttons back to a callback.
@MainActor
private final class NonModalAlert: NSObject {
    private let alert: NSAlert
    private let onButton: @MainActor (Int) -> Void

    init(alert: NSAlert, onButton: @escaping @MainActor (Int) -> Void) {
        self.alert = alert
        self.onButton = onButton
        super.init()
        // Build the panel first so nothing AppKit does while laying it out
        // can point the buttons back at NSAlert's own modal-stop handler,
        // which would leave a window no button can close.
        alert.layout()
        for (index, button) in alert.buttons.enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(buttonPressed(_:))
        }
    }

    func show() {
        let window = alert.window
        // Alert panels hide when the app deactivates. Keep this one up while
        // the user switches to a browser to write the email.
        window.hidesOnDeactivate = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        isShowing = true
    }

    /// False once a button closed it, while it waits to be released.
    private(set) var isShowing = false

    func bringToFront() {
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard isShowing else { return }
        isShowing = false
        alert.window.orderOut(nil)
        onButton(sender.tag)
    }
}
