import AppKit

/// Presents the pre-start "can't hear the other side" question as a plain
/// two-button alert. The decision logic lives in `MeetingSystemAudioAccessFlow`.
@MainActor
enum MeetingSystemAudioAccessAlert {
    static func ask(_ copy: MeetingSystemAudioAccessPromptCopy) async -> MeetingSystemAudioAccessChoice {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = copy.title
        alert.informativeText = copy.message
        alert.addButton(withTitle: copy.turnOnTitle)
        alert.addButton(withTitle: copy.micOnlyTitle)
        alert.buttons.first?.keyEquivalent = "\r"
        // No Escape shortcut: mic only after a denial is remembered, so it
        // has to be a real click, not a stray key press.

        return alert.runModal() == .alertFirstButtonReturn ? .turnOn : .recordMicOnly
    }
}
