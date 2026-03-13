// HotkeyPreferences.swift
// Data model, persistence, display, and validation for customizable keyboard shortcuts.
// Stateless enum — follows DraftUtils/StyleUtils pattern for testability.

import Carbon
import AppKit

struct HotkeyBinding: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32  // Carbon modifier mask
}

enum HotkeyPreferences {

    // MARK: - Defaults

    static let defaultDraft = HotkeyBinding(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey))
    static let defaultDictation = HotkeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))

    // MARK: - UserDefaults Keys

    private static let draftKeyCodeKey    = "hotkey-draft-keyCode"
    private static let draftModifiersKey  = "hotkey-draft-modifiers"
    private static let dictationKeyCodeKey   = "hotkey-dictation-keyCode"
    private static let dictationModifiersKey = "hotkey-dictation-modifiers"

    // MARK: - Read

    static func draftBinding() -> HotkeyBinding {
        let ud = UserDefaults.standard
        guard ud.object(forKey: draftKeyCodeKey) != nil else { return defaultDraft }
        return HotkeyBinding(
            keyCode: UInt32(ud.integer(forKey: draftKeyCodeKey)),
            modifiers: UInt32(ud.integer(forKey: draftModifiersKey))
        )
    }

    static func dictationBinding() -> HotkeyBinding {
        let ud = UserDefaults.standard
        guard ud.object(forKey: dictationKeyCodeKey) != nil else { return defaultDictation }
        return HotkeyBinding(
            keyCode: UInt32(ud.integer(forKey: dictationKeyCodeKey)),
            modifiers: UInt32(ud.integer(forKey: dictationModifiersKey))
        )
    }

    // MARK: - Write

    static func save(draft binding: HotkeyBinding) {
        let ud = UserDefaults.standard
        ud.set(Int(binding.keyCode), forKey: draftKeyCodeKey)
        ud.set(Int(binding.modifiers), forKey: draftModifiersKey)
        NotificationCenter.default.post(name: .hotkeysDidChange, object: nil)
    }

    static func save(dictation binding: HotkeyBinding) {
        let ud = UserDefaults.standard
        ud.set(Int(binding.keyCode), forKey: dictationKeyCodeKey)
        ud.set(Int(binding.modifiers), forKey: dictationModifiersKey)
        NotificationCenter.default.post(name: .hotkeysDidChange, object: nil)
    }

    static func resetToDefaults() {
        let ud = UserDefaults.standard
        ud.removeObject(forKey: draftKeyCodeKey)
        ud.removeObject(forKey: draftModifiersKey)
        ud.removeObject(forKey: dictationKeyCodeKey)
        ud.removeObject(forKey: dictationModifiersKey)
        NotificationCenter.default.post(name: .hotkeysDidChange, object: nil)
    }

    // MARK: - Display

    static func displayString(for binding: HotkeyBinding) -> String {
        var parts: [String] = []
        let mods = binding.modifiers
        if mods & UInt32(controlKey) != 0 { parts.append("⌃") }
        if mods & UInt32(optionKey) != 0  { parts.append("⌥") }
        if mods & UInt32(shiftKey) != 0   { parts.append("⇧") }
        if mods & UInt32(cmdKey) != 0     { parts.append("⌘") }
        parts.append(keyName(for: binding.keyCode))
        return parts.joined()
    }

    private static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        // Letters
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        // Numbers
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        // Special keys
        case kVK_Space:         return "Space"
        case kVK_Return:        return "Return"
        case kVK_Delete:        return "Delete"
        case kVK_ForwardDelete: return "Fwd Delete"
        case kVK_LeftArrow:     return "←"
        case kVK_RightArrow:    return "→"
        case kVK_UpArrow:       return "↑"
        case kVK_DownArrow:     return "↓"
        // Function keys
        case kVK_F1:  return "F1"
        case kVK_F2:  return "F2"
        case kVK_F3:  return "F3"
        case kVK_F4:  return "F4"
        case kVK_F5:  return "F5"
        case kVK_F6:  return "F6"
        case kVK_F7:  return "F7"
        case kVK_F8:  return "F8"
        case kVK_F9:  return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        // Punctuation
        case kVK_ANSI_Minus:        return "-"
        case kVK_ANSI_Equal:        return "="
        case kVK_ANSI_LeftBracket:  return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash:    return "\\"
        case kVK_ANSI_Semicolon:    return ";"
        case kVK_ANSI_Quote:        return "'"
        case kVK_ANSI_Comma:        return ","
        case kVK_ANSI_Period:       return "."
        case kVK_ANSI_Slash:        return "/"
        case kVK_ANSI_Grave:        return "`"
        default: return "Key\(keyCode)"
        }
    }

    // MARK: - Validation

    /// Rejects: bare letters (no modifier), modifier-only combos, Escape, Tab
    static func isValid(_ binding: HotkeyBinding) -> Bool {
        let code = Int(binding.keyCode)
        // Reject Escape and Tab outright
        if code == kVK_Escape || code == kVK_Tab { return false }
        // Must have at least one modifier (Cmd, Option, or Control — Shift alone doesn't count)
        let meaningfulModifiers = binding.modifiers & UInt32(cmdKey | optionKey | controlKey)
        if meaningfulModifiers == 0 { return false }
        return true
    }

    // MARK: - Modifier Conversion

    /// Converts NSEvent.ModifierFlags to Carbon modifier mask for RegisterEventHotKey
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        return carbon
    }
}

// MARK: - Notification

extension Notification.Name {
    static let hotkeysDidChange = Notification.Name("hotkeysDidChange")
}
