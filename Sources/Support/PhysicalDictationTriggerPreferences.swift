import AppKit
import Carbon
import CoreGraphics
import Foundation

struct PhysicalDictationTriggerBinding: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32 = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

enum PhysicalDictationTriggerModifiers {
    static let command: UInt32 = 1 << 0
    static let shift: UInt32 = 1 << 1
    static let option: UInt32 = 1 << 2
    static let control: UInt32 = 1 << 3
    static let function: UInt32 = 1 << 4
    static let capsLock: UInt32 = 1 << 5

    static let all: UInt32 = command | shift | option | control | function | capsLock
}

enum FunctionKeySystemAction: Equatable {
    case notConfigured
    case doNothing
    case changeInputSource
    case showEmojiAndSymbols
    case startDictation
    case unknown(Int)

    var title: String {
        switch self {
        case .notConfigured:
            return "the macOS default"
        case .doNothing:
            return "Do Nothing"
        case .changeInputSource:
            return "Change Input Source"
        case .showEmojiAndSymbols:
            return "Emoji & Symbols"
        case .startDictation:
            return "Start Dictation"
        case .unknown:
            return "another system action"
        }
    }

    var conflictsWithBareFunctionKey: Bool {
        switch self {
        case .doNothing, .notConfigured:
            return false
        case .changeInputSource, .showEmojiAndSymbols, .startDictation, .unknown:
            return true
        }
    }
}

enum PhysicalDictationTriggerPreferences {
    static let defaultBinding = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_RightOption))

    private static let keyCodeKey = "dictationTrigger-keyCode"
    private static let modifiersKey = "dictationTrigger-modifiers"
    private static let functionKeyUsageDomain = "com.apple.HIToolbox" as CFString
    private static let functionKeyUsageKey = "AppleFnUsageType" as CFString

    static func binding(userDefaults: UserDefaults = .standard) -> PhysicalDictationTriggerBinding {
        guard userDefaults.object(forKey: keyCodeKey) != nil else {
            return migratedBinding(userDefaults: userDefaults)
        }

        return PhysicalDictationTriggerBinding(
            keyCode: UInt32(userDefaults.integer(forKey: keyCodeKey)),
            modifiers: UInt32(userDefaults.integer(forKey: modifiersKey)) & PhysicalDictationTriggerModifiers.all
        )
    }

    static func save(_ binding: PhysicalDictationTriggerBinding, userDefaults: UserDefaults = .standard) {
        userDefaults.set(Int(binding.keyCode), forKey: keyCodeKey)
        userDefaults.set(Int(binding.modifiers), forKey: modifiersKey)
        NotificationCenter.default.post(name: .hotkeysDidChange, object: nil)
    }

    static func resetToDefault(userDefaults: UserDefaults = .standard) {
        save(defaultBinding, userDefaults: userDefaults)
    }

    static func functionKeySystemAction() -> FunctionKeySystemAction {
        let value = CFPreferencesCopyAppValue(functionKeyUsageKey, functionKeyUsageDomain)
        if let number = value as? NSNumber {
            return functionKeySystemAction(rawValue: number.intValue)
        }
        if let string = value as? String, let rawValue = Int(string) {
            return functionKeySystemAction(rawValue: rawValue)
        }
        return .notConfigured
    }

    static func functionKeySystemAction(rawValue: Int?) -> FunctionKeySystemAction {
        guard let rawValue else { return .notConfigured }
        switch rawValue {
        case 0:
            return .doNothing
        case 1:
            return .changeInputSource
        case 2:
            return .showEmojiAndSymbols
        case 3:
            return .startDictation
        default:
            return .unknown(rawValue)
        }
    }

    static func functionKeyConflictWarning(
        for binding: PhysicalDictationTriggerBinding = PhysicalDictationTriggerPreferences.binding(),
        systemAction: FunctionKeySystemAction = PhysicalDictationTriggerPreferences.functionKeySystemAction()
    ) -> String? {
        guard binding.keyCode == UInt32(kVK_Function),
              systemAction.conflictsWithBareFunctionKey else {
            return nil
        }

        return "Fn is also set to \(systemAction.title) in macOS. Set Keyboard > Press Fn/Globe key to Do Nothing."
    }

    static func displayString(for binding: PhysicalDictationTriggerBinding) -> String {
        var parts = modifierDisplayParts(for: binding.modifiers)
        parts.append(keyName(for: binding.keyCode))
        return parts.joined()
    }

    static func bindingForKeyDown(keyCode: UInt32, modifierFlags: NSEvent.ModifierFlags) -> PhysicalDictationTriggerBinding {
        PhysicalDictationTriggerBinding(
            keyCode: keyCode,
            modifiers: modifiers(from: modifierFlags)
        )
    }

    static func bindingForFlagsChanged(keyCode: UInt32, modifierFlags: NSEvent.ModifierFlags) -> PhysicalDictationTriggerBinding? {
        guard isModifierKey(keyCode) else { return nil }

        let currentModifiers = modifiers(from: modifierFlags)
        if keyCode == UInt32(kVK_CapsLock) {
            return PhysicalDictationTriggerBinding(
                keyCode: keyCode,
                modifiers: currentModifiers & ~PhysicalDictationTriggerModifiers.capsLock
            )
        }

        guard let primaryModifier = primaryModifierMask(for: keyCode),
              currentModifiers & primaryModifier != 0 else {
            return nil
        }

        return PhysicalDictationTriggerBinding(
            keyCode: keyCode,
            modifiers: currentModifiers & ~primaryModifier
        )
    }

    static func matchesKeyDown(
        _ binding: PhysicalDictationTriggerBinding,
        keyCode: UInt32,
        modifiers: UInt32
    ) -> Bool {
        guard !isModifierKey(binding.keyCode) else { return false }
        return binding.keyCode == keyCode
            && binding.modifiers == (modifiers & PhysicalDictationTriggerModifiers.all)
    }

    static func matchesFlagsChangedPress(
        _ binding: PhysicalDictationTriggerBinding,
        keyCode: UInt32,
        modifiers: UInt32
    ) -> Bool {
        guard isModifierKey(binding.keyCode) else { return false }

        let currentModifiers = modifiers & PhysicalDictationTriggerModifiers.all
        if binding.keyCode == UInt32(kVK_CapsLock) {
            return binding.keyCode == keyCode
                && (currentModifiers & ~PhysicalDictationTriggerModifiers.capsLock) == binding.modifiers
        }

        return modifierChordEventBelongs(to: binding, keyCode: keyCode)
            && isModifierBindingActive(binding, modifiers: currentModifiers)
    }

    static func matchesFlagsChangedRelease(
        _ binding: PhysicalDictationTriggerBinding,
        keyCode: UInt32,
        modifiers: UInt32
    ) -> Bool {
        guard isModifierKey(binding.keyCode),
              binding.keyCode != UInt32(kVK_CapsLock),
              modifierChordEventBelongs(to: binding, keyCode: keyCode) else { return false }

        return !isModifierBindingActive(binding, modifiers: modifiers & PhysicalDictationTriggerModifiers.all)
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= PhysicalDictationTriggerModifiers.command }
        if flags.contains(.shift) { result |= PhysicalDictationTriggerModifiers.shift }
        if flags.contains(.option) { result |= PhysicalDictationTriggerModifiers.option }
        if flags.contains(.control) { result |= PhysicalDictationTriggerModifiers.control }
        if flags.contains(.function) { result |= PhysicalDictationTriggerModifiers.function }
        if flags.contains(.capsLock) { result |= PhysicalDictationTriggerModifiers.capsLock }
        return result
    }

    static func modifiers(from flags: CGEventFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.maskCommand) { result |= PhysicalDictationTriggerModifiers.command }
        if flags.contains(.maskShift) { result |= PhysicalDictationTriggerModifiers.shift }
        if flags.contains(.maskAlternate) { result |= PhysicalDictationTriggerModifiers.option }
        if flags.contains(.maskControl) { result |= PhysicalDictationTriggerModifiers.control }
        if flags.contains(.maskSecondaryFn) { result |= PhysicalDictationTriggerModifiers.function }
        if flags.contains(.maskAlphaShift) { result |= PhysicalDictationTriggerModifiers.capsLock }
        return result
    }

    static func modifiers(fromCarbon carbon: UInt32) -> UInt32 {
        var result: UInt32 = 0
        if carbon & UInt32(cmdKey) != 0 { result |= PhysicalDictationTriggerModifiers.command }
        if carbon & UInt32(shiftKey) != 0 { result |= PhysicalDictationTriggerModifiers.shift }
        if carbon & UInt32(optionKey) != 0 { result |= PhysicalDictationTriggerModifiers.option }
        if carbon & UInt32(controlKey) != 0 { result |= PhysicalDictationTriggerModifiers.control }
        if carbon & UInt32(kEventKeyModifierFnMask) != 0 { result |= PhysicalDictationTriggerModifiers.function }
        return result
    }

    static func isModifierKey(_ keyCode: UInt32) -> Bool {
        switch Int(keyCode) {
        case kVK_Command,
             kVK_RightCommand,
             kVK_Shift,
             kVK_RightShift,
             kVK_Option,
             kVK_RightOption,
             kVK_Control,
             kVK_RightControl,
             kVK_Function,
             kVK_CapsLock:
            return true
        default:
            return false
        }
    }

    static func isTypingKey(_ keyCode: UInt32) -> Bool {
        switch Int(keyCode) {
        case kVK_ANSI_A,
             kVK_ANSI_B,
             kVK_ANSI_C,
             kVK_ANSI_D,
             kVK_ANSI_E,
             kVK_ANSI_F,
             kVK_ANSI_G,
             kVK_ANSI_H,
             kVK_ANSI_I,
             kVK_ANSI_J,
             kVK_ANSI_K,
             kVK_ANSI_L,
             kVK_ANSI_M,
             kVK_ANSI_N,
             kVK_ANSI_O,
             kVK_ANSI_P,
             kVK_ANSI_Q,
             kVK_ANSI_R,
             kVK_ANSI_S,
             kVK_ANSI_T,
             kVK_ANSI_U,
             kVK_ANSI_V,
             kVK_ANSI_W,
             kVK_ANSI_X,
             kVK_ANSI_Y,
             kVK_ANSI_Z,
             kVK_ANSI_0,
             kVK_ANSI_1,
             kVK_ANSI_2,
             kVK_ANSI_3,
             kVK_ANSI_4,
             kVK_ANSI_5,
             kVK_ANSI_6,
             kVK_ANSI_7,
             kVK_ANSI_8,
             kVK_ANSI_9,
             kVK_ANSI_Minus,
             kVK_ANSI_Equal,
             kVK_ANSI_LeftBracket,
             kVK_ANSI_RightBracket,
             kVK_ANSI_Backslash,
             kVK_ANSI_Semicolon,
             kVK_ANSI_Quote,
             kVK_ANSI_Comma,
             kVK_ANSI_Period,
             kVK_ANSI_Slash,
             kVK_ANSI_Grave,
             kVK_Space:
            return true
        default:
            return false
        }
    }

    static func primaryModifierMask(for keyCode: UInt32) -> UInt32? {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand:
            return PhysicalDictationTriggerModifiers.command
        case kVK_Shift, kVK_RightShift:
            return PhysicalDictationTriggerModifiers.shift
        case kVK_Option, kVK_RightOption:
            return PhysicalDictationTriggerModifiers.option
        case kVK_Control, kVK_RightControl:
            return PhysicalDictationTriggerModifiers.control
        case kVK_Function:
            return PhysicalDictationTriggerModifiers.function
        case kVK_CapsLock:
            return PhysicalDictationTriggerModifiers.capsLock
        default:
            return nil
        }
    }

    private static func isModifierBindingActive(
        _ binding: PhysicalDictationTriggerBinding,
        modifiers: UInt32
    ) -> Bool {
        guard let primaryModifier = primaryModifierMask(for: binding.keyCode),
              modifiers & primaryModifier != 0 else {
            return false
        }

        return (modifiers & ~primaryModifier) == binding.modifiers
    }

    private static func modifierChordEventBelongs(
        to binding: PhysicalDictationTriggerBinding,
        keyCode: UInt32
    ) -> Bool {
        if binding.keyCode == keyCode { return true }
        guard let eventModifier = primaryModifierMask(for: keyCode) else { return false }
        return binding.modifiers & eventModifier != 0
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Command: return "Left ⌘"
        case kVK_RightCommand: return "Right ⌘"
        case kVK_Shift: return "Left ⇧"
        case kVK_RightShift: return "Right ⇧"
        case kVK_Option: return "Left ⌥"
        case kVK_RightOption: return "Right ⌥"
        case kVK_Control: return "Left ⌃"
        case kVK_RightControl: return "Right ⌃"
        case kVK_Function: return "Fn"
        case kVK_CapsLock: return "Caps Lock"
        case kVK_ANSI_KeypadEnter: return "Keypad Enter"
        case kVK_ANSI_Keypad0: return "Keypad 0"
        case kVK_ANSI_Keypad1: return "Keypad 1"
        case kVK_ANSI_Keypad2: return "Keypad 2"
        case kVK_ANSI_Keypad3: return "Keypad 3"
        case kVK_ANSI_Keypad4: return "Keypad 4"
        case kVK_ANSI_Keypad5: return "Keypad 5"
        case kVK_ANSI_Keypad6: return "Keypad 6"
        case kVK_ANSI_Keypad7: return "Keypad 7"
        case kVK_ANSI_Keypad8: return "Keypad 8"
        case kVK_ANSI_Keypad9: return "Keypad 9"
        case kVK_ANSI_KeypadDecimal: return "Keypad ."
        case kVK_ANSI_KeypadPlus: return "Keypad +"
        case kVK_ANSI_KeypadMinus: return "Keypad -"
        case kVK_ANSI_KeypadMultiply: return "Keypad *"
        case kVK_ANSI_KeypadDivide: return "Keypad /"
        case kVK_ANSI_KeypadEquals: return "Keypad ="
        case kVK_ANSI_KeypadClear: return "Keypad Clear"
        default:
            return HotkeyPreferences.keyName(for: keyCode)
        }
    }

    private static func migratedBinding(userDefaults: UserDefaults) -> PhysicalDictationTriggerBinding {
        if HotkeyPreferences.rightOptionDictationEnabled(userDefaults: userDefaults) {
            return defaultBinding
        }

        let oldBinding = HotkeyPreferences.dictationBinding(userDefaults: userDefaults)
        return PhysicalDictationTriggerBinding(
            keyCode: oldBinding.keyCode,
            modifiers: modifiers(fromCarbon: oldBinding.modifiers)
        )
    }

    private static func modifierDisplayParts(for modifiers: UInt32) -> [String] {
        var parts: [String] = []
        if modifiers & PhysicalDictationTriggerModifiers.control != 0 { parts.append("⌃") }
        if modifiers & PhysicalDictationTriggerModifiers.option != 0 { parts.append("⌥") }
        if modifiers & PhysicalDictationTriggerModifiers.shift != 0 { parts.append("⇧") }
        if modifiers & PhysicalDictationTriggerModifiers.command != 0 { parts.append("⌘") }
        if modifiers & PhysicalDictationTriggerModifiers.function != 0 { parts.append("Fn ") }
        if modifiers & PhysicalDictationTriggerModifiers.capsLock != 0 { parts.append("Caps ") }
        return parts
    }
}
