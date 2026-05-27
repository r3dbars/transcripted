// ContextCaptureEnginePolicyTests.swift
// Tests for the externally-observable policy that ContextCaptureEngine relies on:
// the hotkey-action debounce constant, the hotkeys-changed notification name,
// the default binding set that feeds bindingProvider, and the conflict-warning
// text that flows into the engine's hotkeyError pipeline.
//
// NOTE: ContextCaptureEngine itself is @MainActor and wired to AppKit, Carbon,
// NSWorkspace, DictationSessionController, FloatingOverlayController,
// EventReporter, and DiagnosticsTrail. Its internal seams
// (shouldAcceptHotkeyAction, routeDictationToggle, PhysicalShortcutDetector,
// PhysicalShortcutBinding, PhysicalShortcutAction) are file-private. These
// tests cover the shared constants and preference seams the engine consumes,
// not the engine class itself.

import AppKit
import Carbon
import Foundation

func testContextCaptureEnginePolicy() {

    // MARK: - Hotkey action debounce constant
    // The engine's shouldAcceptHotkeyAction() compares
    // ProcessInfo.systemUptime against this interval to reject rapid repeat
    // hotkey presses. Pin the contract so a future tweak does not silently
    // open a window where Carbon can double-fire start/stop transitions.

    runSuite("TranscriptedConstants.hotkeyActionDebounceInterval — strictly positive") {
        assertTrue(
            TranscriptedConstants.hotkeyActionDebounceInterval > 0,
            "non-positive debounce would let every Carbon callback pass through and race session state"
        )
    }

    runSuite("TranscriptedConstants.hotkeyActionDebounceInterval — under a typical double-tap window") {
        // Real users routinely toggle start/stop within ~0.4-0.5s. Going much
        // above that would block legitimate fast toggles.
        assertTrue(
            TranscriptedConstants.hotkeyActionDebounceInterval < 0.4,
            "debounce window should stay short enough to allow intentional fast start/stop toggles"
        )
    }

    runSuite("TranscriptedConstants.hotkeyActionDebounceInterval — matches engine's documented 200ms guard") {
        assertEqual(
            TranscriptedConstants.hotkeyActionDebounceInterval,
            0.2,
            "engine's hotkey repeat guard relies on a 200ms debounce window — bump this only with intent"
        )
    }

    runSuite("ContextCaptureEngine hotkey debounce — tracks independent actions separately") {
        let source = readContextCaptureEngineSource()

        assertTrue(
            source.contains("_lastAcceptedHotkeyTimesByAction"),
            "hotkey debounce should store last accepted times per action instead of one global timestamp"
        )
        assertTrue(
            source.contains("shouldAcceptHotkeyAction(\"dictation_hands_free\")"),
            "hands-free dictation should have its own debounce key"
        )
        assertTrue(
            source.contains("shouldAcceptHotkeyAction(\"dictation_push_to_talk\")"),
            "push-to-talk dictation should have its own debounce key"
        )
        assertTrue(
            source.contains("shouldAcceptHotkeyAction(\"meeting_physical_trigger\")"),
            "meeting physical trigger should have its own debounce key"
        )
    }

    // MARK: - Notification.Name.hotkeysDidChange
    // The engine subscribes to this notification to re-register hotkeys when
    // HotkeyRecorderView writes new bindings. Renaming the notification would
    // silently break preference live-updates.

    runSuite("Notification.Name.hotkeysDidChange — stable raw value") {
        assertEqual(
            Notification.Name.hotkeysDidChange.rawValue,
            "hotkeysDidChange",
            "engine's preference observer is bound to this exact notification name"
        )
    }

    // MARK: - Binding provider default set
    // The engine's bindingProvider always emits the meeting binding and,
    // when dictation shortcuts are enabled, prepends push-to-talk and
    // hands-free. Pin the three defaults a fresh install hands the provider.

    runSuite("PhysicalDictationTriggerPreferences fresh install — engine bindingProvider sees Fn / Right Option / Option-M") {
        let (defaults, suiteName) = makeContextCaptureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pushToTalk = PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults)
        let handsFree = PhysicalDictationTriggerPreferences.handsFreeBinding(userDefaults: defaults)
        let meeting = PhysicalDictationTriggerPreferences.meetingBinding(userDefaults: defaults)

        assertEqual(pushToTalk.keyCode, UInt32(kVK_Function), "push-to-talk default keyCode should be Fn")
        assertEqual(pushToTalk.modifiers, 0, "push-to-talk default should have no modifiers")
        assertEqual(handsFree.keyCode, UInt32(kVK_RightOption), "hands-free default keyCode should be Right Option")
        assertEqual(handsFree.modifiers, 0, "hands-free default should have no modifiers")
        assertEqual(meeting.keyCode, UInt32(kVK_ANSI_M), "meeting default keyCode should be M")
        assertEqual(meeting.modifiers, PhysicalDictationTriggerModifiers.option, "meeting default modifier should be Option")
    }

    runSuite("PhysicalDictationTriggerPreferences fresh install — meeting binding is independent of dictation shortcuts toggle") {
        // The engine's bindingProvider always includes the meeting binding,
        // even when dictation shortcuts are off. The meeting default must
        // therefore survive in the absence of any saved dictation preference.
        let (defaults, suiteName) = makeContextCaptureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "hotkey-dictation-shortcuts-enabled")

        assertFalse(
            HotkeyPreferences.dictationShortcutsEnabled(userDefaults: defaults),
            "explicitly-disabled dictation shortcuts should report as off"
        )

        let meeting = PhysicalDictationTriggerPreferences.meetingBinding(userDefaults: defaults)
        assertEqual(
            meeting,
            PhysicalDictationTriggerPreferences.defaultMeetingBinding,
            "meeting binding should stay available even when dictation shortcuts are disabled"
        )
    }

    // MARK: - dictationShortcutsEnabled default
    // The engine's bindingProvider checks this preference inside the closure
    // it hands the PhysicalShortcutDetector. A fresh install must default to
    // enabled so dictation shortcuts work out of the box.

    runSuite("HotkeyPreferences.dictationShortcutsEnabled — defaults to enabled for fresh installs") {
        let (defaults, suiteName) = makeContextCaptureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertTrue(
            HotkeyPreferences.dictationShortcutsEnabled(userDefaults: defaults),
            "fresh installs should report dictation shortcuts as enabled so the engine wires the dictation triggers"
        )
    }

    runSuite("HotkeyPreferences.dictationShortcutsEnabled — explicit opt-in survives reads") {
        let (defaults, suiteName) = makeContextCaptureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "hotkey-dictation-shortcuts-enabled")
        assertTrue(
            HotkeyPreferences.dictationShortcutsEnabled(userDefaults: defaults),
            "explicit-on preference should round-trip"
        )

        defaults.set(false, forKey: "hotkey-dictation-shortcuts-enabled")
        assertFalse(
            HotkeyPreferences.dictationShortcutsEnabled(userDefaults: defaults),
            "explicit-off preference should round-trip — engine drops dictation bindings in this case"
        )
    }

    // MARK: - hotkeyError pipeline inputs
    // ContextCaptureEngine.updateHotkeyError() joins carbonHotkeyError,
    // physicalTriggerError, and (when dictation shortcuts are enabled) the
    // function-key conflict warning. Pin the conflict-warning text since it
    // surfaces verbatim in the MenuBarPanel banner.

    runSuite("PhysicalDictationTriggerPreferences.functionKeyConflictWarning — silent when binding isn't bare Fn") {
        let rightOption = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_RightOption))

        assertNil(
            PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
                for: rightOption,
                systemAction: .startDictation
            ),
            "non-Fn bindings should never trigger the bare-Fn warning that flows into hotkeyError"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences.functionKeyConflictWarning — warns when bare Fn conflicts") {
        let fn = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Function))

        let warning = PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
            for: fn,
            systemAction: .startDictation
        )

        assertNotNil(warning, "bare Fn paired with a conflicting macOS Fn action should surface a hotkeyError")
        if let warning {
            assertTrue(
                warning.contains("Fn"),
                "warning text should mention Fn so users know which key to reconfigure"
            )
            assertTrue(
                warning.contains("Do Nothing"),
                "warning text should tell users to set Fn to Do Nothing in System Settings"
            )
        }
    }

    runSuite("PhysicalDictationTriggerPreferences.functionKeyConflictWarning — silent when macOS Fn is Do Nothing") {
        let fn = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Function))

        assertNil(
            PhysicalDictationTriggerPreferences.functionKeyConflictWarning(for: fn, systemAction: .doNothing),
            "bare Fn should not warn when macOS already routes Fn to nothing"
        )
        assertNil(
            PhysicalDictationTriggerPreferences.functionKeyConflictWarning(for: fn, systemAction: .notConfigured),
            "bare Fn should not warn when AppleFnUsageType is missing"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences.functionKeyConflictWarning — Fn with modifiers is not a bare-Fn conflict") {
        let fnSpace = PhysicalDictationTriggerBinding(
            keyCode: UInt32(kVK_Space),
            modifiers: PhysicalDictationTriggerModifiers.function
        )

        assertNil(
            PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
                for: fnSpace,
                systemAction: .startDictation
            ),
            "Fn+key chords don't fight the bare-Fn macOS action"
        )
    }

    // MARK: - Display strings the engine publishes
    // The engine publishes dictationShortcutDisplay (push-to-talk / hands-free)
    // and meetingShortcutDisplay through @Published strings consumed by
    // MenuBarPanel pills and the overlay. Pin the shape so a display tweak
    // does not silently regress the menubar UI.

    runSuite("PhysicalDictationTriggerPreferences.displayString — meeting default formats as Option-M chord") {
        assertEqual(
            PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.defaultMeetingBinding),
            "⌥M",
            "meeting default should render as ⌥M for the engine's meetingShortcutDisplay"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences.displayString — dictation defaults render as Fn and Right Option") {
        assertEqual(
            PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.defaultPushToTalkBinding),
            "Fn",
            "push-to-talk default should render as Fn for dictationShortcutDisplay"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.defaultHandsFreeBinding),
            "Right ⌥",
            "hands-free default should render as Right ⌥ for dictationShortcutDisplay"
        )
    }

    // MARK: - PhysicalShortcutDetector matcher dispatch
    // The detector picks a binding via matchesKeyDown / matchesFlagsChangedPress
    // / matchesFlagsChangedRelease. Cover the exact dispatch the engine relies
    // on when a press arrives: typing keys go through keyDown, modifier keys
    // go through flagsChanged.

    runSuite("PhysicalDictationTriggerPreferences.matchesKeyDown — meeting Option-M binding accepts ⌥M keyDown") {
        let meeting = PhysicalDictationTriggerPreferences.defaultMeetingBinding

        assertTrue(
            PhysicalDictationTriggerPreferences.matchesKeyDown(
                meeting,
                keyCode: UInt32(kVK_ANSI_M),
                modifiers: PhysicalDictationTriggerModifiers.option
            ),
            "engine's keyDown matcher should accept the configured meeting chord"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences.matchesKeyDown — meeting binding rejects bare M without Option") {
        let meeting = PhysicalDictationTriggerPreferences.defaultMeetingBinding

        assertFalse(
            PhysicalDictationTriggerPreferences.matchesKeyDown(meeting, keyCode: UInt32(kVK_ANSI_M), modifiers: 0),
            "bare M should not fire the meeting hotkey while a user is typing"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences.matchesKeyDown — modifier-only bindings are not keyDown matches") {
        let rightOption = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_RightOption))

        assertFalse(
            PhysicalDictationTriggerPreferences.matchesKeyDown(
                rightOption,
                keyCode: UInt32(kVK_RightOption),
                modifiers: PhysicalDictationTriggerModifiers.option
            ),
            "modifier-key bindings must go through the flagsChanged path so the detector picks them up correctly"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences.matchesFlagsChangedPress — Right Option binding fires on Right Option press") {
        let rightOption = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_RightOption))

        assertTrue(
            PhysicalDictationTriggerPreferences.matchesFlagsChangedPress(
                rightOption,
                keyCode: UInt32(kVK_RightOption),
                modifiers: PhysicalDictationTriggerModifiers.option
            ),
            "hands-free Right Option should be picked up by the detector's flagsChanged matcher"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences.matchesFlagsChangedRelease — Right Option binding releases when Option flag clears") {
        let rightOption = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_RightOption))

        assertTrue(
            PhysicalDictationTriggerPreferences.matchesFlagsChangedRelease(
                rightOption,
                keyCode: UInt32(kVK_RightOption),
                modifiers: 0
            ),
            "Right Option release must produce a release event for push-to-talk paste-back routing"
        )
        assertFalse(
            PhysicalDictationTriggerPreferences.matchesFlagsChangedRelease(
                rightOption,
                keyCode: UInt32(kVK_RightOption),
                modifiers: PhysicalDictationTriggerModifiers.option
            ),
            "Option flag still set should not be treated as a release"
        )
    }

    // MARK: - isModifierKey / isTypingKey routing classifications
    // The detector branches on these to decide whether a press belongs to
    // chord-detection or to typing-key flow. Pin a few classification cases
    // that affect engine routing.

    runSuite("PhysicalDictationTriggerPreferences.isModifierKey — covers the modifier keys the engine treats specially") {
        assertTrue(PhysicalDictationTriggerPreferences.isModifierKey(UInt32(kVK_Function)), "Fn is a modifier")
        assertTrue(PhysicalDictationTriggerPreferences.isModifierKey(UInt32(kVK_RightOption)), "Right Option is a modifier")
        assertTrue(PhysicalDictationTriggerPreferences.isModifierKey(UInt32(kVK_Option)), "Left Option is a modifier")
        assertTrue(PhysicalDictationTriggerPreferences.isModifierKey(UInt32(kVK_CapsLock)), "Caps Lock is a modifier")
        assertFalse(PhysicalDictationTriggerPreferences.isModifierKey(UInt32(kVK_ANSI_M)), "M is not a modifier")
        assertFalse(PhysicalDictationTriggerPreferences.isModifierKey(UInt32(kVK_Space)), "Space is not a modifier")
    }

    runSuite("PhysicalDictationTriggerPreferences.primaryModifierMask — modifier keys map to their flag bit") {
        assertEqual(
            PhysicalDictationTriggerPreferences.primaryModifierMask(for: UInt32(kVK_RightOption)),
            PhysicalDictationTriggerModifiers.option,
            "Right Option maps to the option flag for chord detection"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.primaryModifierMask(for: UInt32(kVK_Function)),
            PhysicalDictationTriggerModifiers.function,
            "Fn maps to the function flag"
        )
        assertNil(
            PhysicalDictationTriggerPreferences.primaryModifierMask(for: UInt32(kVK_ANSI_M)),
            "typing keys have no primary modifier mask"
        )
    }
}

private func makeContextCaptureDefaults() -> (UserDefaults, String) {
    let suiteName = "ContextCaptureEnginePolicyTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

private func readContextCaptureEngineSource() -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("Sources/Capture/ContextCaptureEngine.swift")
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}
