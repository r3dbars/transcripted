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
    static let defaultPushToTalkBinding = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Function))
    static let defaultHandsFreeBinding = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_RightOption))
    static let defaultMeetingBinding = PhysicalDictationTriggerBinding(
        keyCode: UInt32(kVK_ANSI_M),
        modifiers: PhysicalDictationTriggerModifiers.option
    )
    static let defaultPasteLastDictationBinding = PhysicalDictationTriggerBinding(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: PhysicalDictationTriggerModifiers.option | PhysicalDictationTriggerModifiers.shift
    )
    static let defaultBinding = defaultPushToTalkBinding

    private static let keyCodeKey = "dictationTrigger-keyCode"
    private static let modifiersKey = "dictationTrigger-modifiers"
    private static let pushToTalkKeyCodeKey = "dictationPushToTalkTrigger-keyCode"
    private static let pushToTalkModifiersKey = "dictationPushToTalkTrigger-modifiers"
    private static let handsFreeKeyCodeKey = "dictationHandsFreeTrigger-keyCode"
    private static let handsFreeModifiersKey = "dictationHandsFreeTrigger-modifiers"
    private static let meetingKeyCodeKey = "meetingTrigger-keyCode"
    private static let meetingModifiersKey = "meetingTrigger-modifiers"
    private static let pasteLastDictationKeyCodeKey = "pasteLastDictationTrigger-keyCode"
    private static let pasteLastDictationModifiersKey = "pasteLastDictationTrigger-modifiers"
    private static let functionKeyUsageDomain = "com.apple.HIToolbox" as CFString
    private static let functionKeyUsageKey = "AppleFnUsageType" as CFString

    static func binding(userDefaults: UserDefaults = .standard) -> PhysicalDictationTriggerBinding {
        pushToTalkBinding(userDefaults: userDefaults)
    }

    static func pushToTalkBinding(userDefaults: UserDefaults = .standard) -> PhysicalDictationTriggerBinding {
        safeBinding(
            storedBinding(
                keyCodeKey: pushToTalkKeyCodeKey,
                modifiersKey: pushToTalkModifiersKey,
                userDefaults: userDefaults
            ) ?? migratedPushToTalkBinding(userDefaults: userDefaults),
            fallback: defaultPushToTalkBinding
        )
    }

    static func handsFreeBinding(userDefaults: UserDefaults = .standard) -> PhysicalDictationTriggerBinding {
        safeBinding(
            storedBinding(
                keyCodeKey: handsFreeKeyCodeKey,
                modifiersKey: handsFreeModifiersKey,
                userDefaults: userDefaults
            ) ?? migratedHandsFreeBinding(userDefaults: userDefaults),
            fallback: defaultHandsFreeBinding
        )
    }

    static func meetingBinding(userDefaults: UserDefaults = .standard) -> PhysicalDictationTriggerBinding {
        safeBinding(
            storedBinding(
                keyCodeKey: meetingKeyCodeKey,
                modifiersKey: meetingModifiersKey,
                userDefaults: userDefaults
            ) ?? migratedMeetingBinding(userDefaults: userDefaults),
            fallback: defaultMeetingBinding
        )
    }

    static func pasteLastDictationBinding(userDefaults: UserDefaults = .standard) -> PhysicalDictationTriggerBinding {
        safeBinding(
            storedBinding(
                keyCodeKey: pasteLastDictationKeyCodeKey,
                modifiersKey: pasteLastDictationModifiersKey,
                userDefaults: userDefaults
            ) ?? defaultPasteLastDictationBinding,
            fallback: defaultPasteLastDictationBinding
        )
    }

    static func save(_ binding: PhysicalDictationTriggerBinding, userDefaults: UserDefaults = .standard) {
        savePushToTalk(binding, userDefaults: userDefaults)
    }

    static func savePushToTalk(_ binding: PhysicalDictationTriggerBinding, userDefaults: UserDefaults = .standard) {
        saveBinding(
            binding,
            keyCodeKey: pushToTalkKeyCodeKey,
            modifiersKey: pushToTalkModifiersKey,
            userDefaults: userDefaults
        )
    }

    static func saveHandsFree(_ binding: PhysicalDictationTriggerBinding, userDefaults: UserDefaults = .standard) {
        saveBinding(
            binding,
            keyCodeKey: handsFreeKeyCodeKey,
            modifiersKey: handsFreeModifiersKey,
            userDefaults: userDefaults
        )
    }

    static func saveMeeting(_ binding: PhysicalDictationTriggerBinding, userDefaults: UserDefaults = .standard) {
        saveBinding(
            binding,
            keyCodeKey: meetingKeyCodeKey,
            modifiersKey: meetingModifiersKey,
            userDefaults: userDefaults
        )
    }

    static func savePasteLastDictation(_ binding: PhysicalDictationTriggerBinding, userDefaults: UserDefaults = .standard) {
        saveBinding(
            binding,
            keyCodeKey: pasteLastDictationKeyCodeKey,
            modifiersKey: pasteLastDictationModifiersKey,
            userDefaults: userDefaults
        )
    }

    private static func saveBinding(
        _ binding: PhysicalDictationTriggerBinding,
        keyCodeKey: String,
        modifiersKey: String,
        userDefaults: UserDefaults
    ) {
        userDefaults.set(Int(binding.keyCode), forKey: keyCodeKey)
        userDefaults.set(Int(binding.modifiers), forKey: modifiersKey)
        NotificationCenter.default.post(name: .hotkeysDidChange, object: nil)
    }

    static func resetToDefaults(userDefaults: UserDefaults = .standard) {
        savePushToTalk(defaultPushToTalkBinding, userDefaults: userDefaults)
        saveHandsFree(defaultHandsFreeBinding, userDefaults: userDefaults)
        saveMeeting(defaultMeetingBinding, userDefaults: userDefaults)
        savePasteLastDictation(defaultPasteLastDictationBinding, userDefaults: userDefaults)
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
              binding.modifiers == 0,
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

    /// Why a binding must never be installed in the event tap, or nil when it
    /// is safe.
    ///
    /// The tap swallows every key event that matches a binding, so a chord
    /// macOS itself relies on (⌘V, ⌘C, ⌘Q…) or a bare typing key hijacks
    /// ordinary input system-wide: a stored ⌘V paste-last shortcut turns
    /// every paste on the Mac into Transcripted's own popup. Modifier keys
    /// (Fn, Right ⌥…) and function keys are always allowed; anything else
    /// needs at least one of ⌘, ⌥, ⌃, or Fn beyond Shift.
    static func rejectionReason(for binding: PhysicalDictationTriggerBinding) -> String? {
        if isModifierKey(binding.keyCode) || isFunctionKey(binding.keyCode) {
            return nil
        }
        let chordModifiers = binding.modifiers
            & PhysicalDictationTriggerModifiers.all
            & ~(PhysicalDictationTriggerModifiers.shift | PhysicalDictationTriggerModifiers.capsLock)
        if navigationKeyCodes.contains(binding.keyCode) {
            // macOS sets the Fn flag on arrow and navigation keys by itself, so
            // Fn cannot count as the user's modifier here, and ⌘/⌥ alone are
            // line/word movement in every text field.
            let explicit = chordModifiers & ~PhysicalDictationTriggerModifiers.function
            let hasControl = explicit & PhysicalDictationTriggerModifiers.control != 0
            let commandOption = PhysicalDictationTriggerModifiers.command | PhysicalDictationTriggerModifiers.option
            let hasCommandOption = explicit & commandOption == commandOption
            if !hasControl && !hasCommandOption {
                return "Arrow and navigation keys need ⌃, or ⌘ with ⌥, so text editing isn't captured."
            }
            return nil
        }
        if chordModifiers == 0 {
            return "Add ⌘, ⌥, ⌃, or Fn so normal typing isn't captured."
        }
        if chordModifiers == PhysicalDictationTriggerModifiers.command,
           reservedCommandKeyCodes.contains(binding.keyCode) {
            return "\(displayString(for: binding)) is a macOS shortcut. Choose a different combination."
        }
        return nil
    }

    /// ⌘ (optionally with ⇧) plus one of these keys is system-wide editing,
    /// window, or app control that must keep reaching the frontmost app.
    private static let reservedCommandKeyCodes: Set<UInt32> = [
        UInt32(kVK_ANSI_A),
        UInt32(kVK_ANSI_C),
        UInt32(kVK_ANSI_V),
        UInt32(kVK_ANSI_X),
        UInt32(kVK_ANSI_Z),
        UInt32(kVK_ANSI_Q),
        UInt32(kVK_ANSI_W),
        UInt32(kVK_ANSI_H),
        UInt32(kVK_ANSI_M),
        UInt32(kVK_Tab),
        UInt32(kVK_Space),
        UInt32(kVK_ANSI_Comma),
    ]

    /// Keys macOS reports with an implicit Fn flag and that every text field
    /// uses for movement, so a bare or ⌘/⌥ chord on them must not be swallowed.
    private static let navigationKeyCodes: Set<UInt32> = [
        UInt32(kVK_LeftArrow),
        UInt32(kVK_RightArrow),
        UInt32(kVK_UpArrow),
        UInt32(kVK_DownArrow),
        UInt32(kVK_Home),
        UInt32(kVK_End),
        UInt32(kVK_PageUp),
        UInt32(kVK_PageDown),
        UInt32(kVK_ForwardDelete),
    ]

    /// A stored chord the event tap must never swallow falls back to the
    /// action's default at read time, so Settings, the menu bar, and the tap
    /// all agree on what actually fires. The recorder refuses such chords at
    /// save time; this guards whatever is already on disk from older builds.
    private static func safeBinding(
        _ binding: PhysicalDictationTriggerBinding,
        fallback: PhysicalDictationTriggerBinding
    ) -> PhysicalDictationTriggerBinding {
        rejectionReason(for: binding) == nil ? binding : fallback
    }

    private static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        switch Int(keyCode) {
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
             kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20:
            return true
        default:
            return false
        }
    }

    private static func storedBinding(
        keyCodeKey: String,
        modifiersKey: String,
        userDefaults: UserDefaults
    ) -> PhysicalDictationTriggerBinding? {
        guard userDefaults.object(forKey: keyCodeKey) != nil else { return nil }

        return PhysicalDictationTriggerBinding(
            keyCode: UInt32(userDefaults.integer(forKey: keyCodeKey)),
            modifiers: UInt32(userDefaults.integer(forKey: modifiersKey)) & PhysicalDictationTriggerModifiers.all
        )
    }

    private static func migratedPushToTalkBinding(userDefaults: UserDefaults) -> PhysicalDictationTriggerBinding {
        guard HotkeyPreferences.dictationShortcutMode(userDefaults: userDefaults) == .pushToTalk else {
            return defaultPushToTalkBinding
        }

        if userDefaults.object(forKey: keyCodeKey) != nil {
            return legacyDictationBinding(userDefaults: userDefaults)
        }

        return HotkeyPreferences.rightOptionDictationEnabled(userDefaults: userDefaults)
            ? defaultPushToTalkBinding
            : legacyCarbonDictationBinding(userDefaults: userDefaults)
    }

    private static func migratedHandsFreeBinding(userDefaults: UserDefaults) -> PhysicalDictationTriggerBinding {
        guard HotkeyPreferences.dictationShortcutMode(userDefaults: userDefaults) == .handsFree else {
            return defaultHandsFreeBinding
        }

        if userDefaults.object(forKey: keyCodeKey) != nil {
            return legacyDictationBinding(userDefaults: userDefaults)
        }

        return HotkeyPreferences.rightOptionDictationEnabled(userDefaults: userDefaults)
            ? defaultHandsFreeBinding
            : legacyCarbonDictationBinding(userDefaults: userDefaults)
    }

    private static func migratedMeetingBinding(userDefaults: UserDefaults) -> PhysicalDictationTriggerBinding {
        guard HotkeyPreferences.hasSavedMeetingBinding(userDefaults: userDefaults) else {
            return defaultMeetingBinding
        }

        let oldBinding = HotkeyPreferences.meetingBinding(userDefaults: userDefaults)
        return PhysicalDictationTriggerBinding(
            keyCode: oldBinding.keyCode,
            modifiers: modifiers(fromCarbon: oldBinding.modifiers)
        )
    }

    private static func legacyDictationBinding(userDefaults: UserDefaults) -> PhysicalDictationTriggerBinding {
        guard userDefaults.object(forKey: keyCodeKey) != nil else {
            return HotkeyPreferences.rightOptionDictationEnabled(userDefaults: userDefaults)
                ? defaultPushToTalkBinding
                : legacyCarbonDictationBinding(userDefaults: userDefaults)
        }

        return PhysicalDictationTriggerBinding(
            keyCode: UInt32(userDefaults.integer(forKey: keyCodeKey)),
            modifiers: UInt32(userDefaults.integer(forKey: modifiersKey)) & PhysicalDictationTriggerModifiers.all
        )
    }

    private static func legacyCarbonDictationBinding(userDefaults: UserDefaults) -> PhysicalDictationTriggerBinding {
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
