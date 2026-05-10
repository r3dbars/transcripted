import AppKit
import Carbon

enum ShortcutRecorderKeyEventPolicy {
    static func shouldStopRecordingAndPassThrough(_ event: NSEvent) -> Bool {
        shouldStopRecordingAndPassThrough(keyCode: event.keyCode, modifierFlags: event.modifierFlags)
    }

    static func shouldStopRecordingAndPassThrough(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        guard keyCode == UInt16(kVK_Tab) else { return false }

        // Bare Tab is normal focus traversal. Modified Tab stays captured so
        // partial shortcut attempts do not leak into the focused control.
        return PhysicalDictationTriggerPreferences.modifiers(from: modifierFlags) == 0
    }
}
