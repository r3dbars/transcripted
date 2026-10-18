// ClipboardPasteTarget.swift
// The pasteboard seam the paster writes through, the layout-aware Cmd+V it
// posts, and the app a dictation should paste into. Split out of
// ClipboardRestoringTextPaster.swift.

import AppKit
import ApplicationServices
import Carbon
import Foundation

@MainActor
protocol ClipboardPasteboard: AnyObject {
    var changeCount: Int { get }
    var pasteboardItems: [NSPasteboardItem]? { get }

    @discardableResult
    func clearContents() -> Int

    @discardableResult
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool

    func string(forType dataType: NSPasteboard.PasteboardType) -> String?

    @discardableResult
    func writePasteboardItems(_ items: [NSPasteboardItem]) -> Bool
}

extension NSPasteboard: ClipboardPasteboard {
    @discardableResult
    func writePasteboardItems(_ items: [NSPasteboardItem]) -> Bool {
        writeObjects(items)
    }
}

func postClipboardPasteShortcut() -> Bool {
    let pasteKeyCode = currentPasteShortcutKeyCode()
    guard let vDown = CGEvent(keyboardEventSource: nil, virtualKey: pasteKeyCode, keyDown: true),
          let vUp = CGEvent(keyboardEventSource: nil, virtualKey: pasteKeyCode, keyDown: false) else {
        return false
    }

    vDown.flags = .maskCommand
    vDown.post(tap: .cghidEventTap)

    vUp.flags = .maskCommand
    vUp.post(tap: .cghidEventTap)

    return true
}

private func currentPasteShortcutKeyCode() -> CGKeyCode {
    guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
        return CGKeyCode(kVK_ANSI_V)
    }
    return pasteShortcutKeyCode(in: inputSource) ?? CGKeyCode(kVK_ANSI_V)
}

/// The keycode that types "v" in this layout. The paste is posted with Command held, so look
/// in the layout's Command table first: "Dvorak - QWERTY Cmd" swaps to QWERTY under Command,
/// and its unmodified "v" key would arrive as Cmd+. instead. Layouts without a Latin "v"
/// under Command fall back to the unmodified table.
func pasteShortcutKeyCode(in inputSource: TISInputSource) -> CGKeyCode? {
    guard let layoutProperty = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
        return nil
    }

    let layoutData = unsafeBitCast(layoutProperty, to: CFData.self)
    guard let layoutBytes = CFDataGetBytePtr(layoutData) else { return nil }
    let keyboardLayout = UnsafeRawPointer(layoutBytes).assumingMemoryBound(to: UCKeyboardLayout.self)
    let commandKeyState = UInt32((cmdKey >> 8) & 0xFF)
    return keyCode(producing: "v", in: keyboardLayout, modifierKeyState: commandKeyState)
        ?? keyCode(producing: "v", in: keyboardLayout, modifierKeyState: 0)
}

private func keyCode(
    producing target: String,
    in keyboardLayout: UnsafePointer<UCKeyboardLayout>,
    modifierKeyState: UInt32
) -> CGKeyCode? {
    for keyCode in UInt16(0)..<UInt16(128) {
        var deadKeyState: UInt32 = 0
        var actualLength = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDown),
            modifierKeyState,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &actualLength,
            &characters
        )
        guard status == noErr, actualLength > 0 else { continue }
        let produced = String(utf16CodeUnits: characters, count: actualLength).lowercased()
        if produced == target {
            return CGKeyCode(keyCode)
        }
    }

    return nil
}

enum ClipboardTargetActivationPolicy {
    /// Pure wait decision used by `waitForTargetActivation`: keep waiting only while the
    /// target is not yet frontmost AND the elapsed time has not reached the timeout.
    static func shouldWait(targetIsFrontmost: Bool, elapsed: TimeInterval, timeout: TimeInterval) -> Bool {
        guard !targetIsFrontmost else { return false }
        return elapsed < timeout
    }
}

struct DictationPasteTarget: Equatable {
    let processIdentifier: pid_t?
    let bundleIdentifier: String?

    static func capture(sourceApp: NSRunningApplication?) -> DictationPasteTarget? {
        guard let sourceApp else { return nil }
        return DictationPasteTarget(
            processIdentifier: sourceApp.processIdentifier,
            bundleIdentifier: sourceApp.bundleIdentifier
        )
    }

    static func preferredDestination(
        frontmostProcessIdentifier: pid_t?,
        frontmostBundleIdentifier: String?,
        transcriptedBundleIdentifier: String?,
        fallback: DictationPasteTarget?
    ) -> DictationPasteTarget? {
        guard let frontmostProcessIdentifier,
              let frontmostBundleIdentifier,
              frontmostBundleIdentifier != transcriptedBundleIdentifier else {
            return fallback
        }
        return DictationPasteTarget(
            processIdentifier: frontmostProcessIdentifier,
            bundleIdentifier: frontmostBundleIdentifier
        )
    }

    func matchesCurrentFrontmostApp() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        return matches(
            processIdentifier: frontmostApp.processIdentifier,
            bundleIdentifier: frontmostApp.bundleIdentifier
        )
    }

    func matches(processIdentifier currentProcessIdentifier: pid_t?, bundleIdentifier currentBundleIdentifier: String?) -> Bool {
        if let processIdentifier, let currentProcessIdentifier {
            return processIdentifier == currentProcessIdentifier
        }
        if let bundleIdentifier, let currentBundleIdentifier {
            return bundleIdentifier == currentBundleIdentifier
        }
        return false
    }
}
