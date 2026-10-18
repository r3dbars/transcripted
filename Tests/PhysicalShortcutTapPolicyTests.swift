// PhysicalShortcutTapPolicyTests.swift
// Promises for the physical-shortcut tap once macOS starts delivering F-keys
// as media keys or with a different implicit Fn flag: the tap must listen
// for NSSystemDefined events and always pass them through; a configured
// dictation F-key arriving as a media key must be diagnosable; a press of
// the saved key with the wrong Cmd/Ctrl/Opt/Shift set must be diagnosable
// without logging any other typing; tap-disable and install must say what
// happened. The CGEventTap itself is not built here.

import Carbon
import CoreGraphics
import Foundation

func testPhysicalShortcutTapPolicy() {
    let function = PhysicalDictationTriggerModifiers.function
    let command = PhysicalDictationTriggerModifiers.command
    let option = PhysicalDictationTriggerModifiers.option
    let shift = PhysicalDictationTriggerModifiers.shift
    let control = PhysicalDictationTriggerModifiers.control
    let f8 = UInt32(kVK_F8)
    let savedF8 = PhysicalDictationTriggerBinding(keyCode: f8)
    let rightOption = PhysicalDictationTriggerPreferences.defaultPushToTalkBinding

    runSuite("Diagnostic event names are stable and telemetry-safe") {
        assertEqual(
            PhysicalShortcutDiagnosticEvent.mediaKey,
            "hotkey_fkey_arrived_as_media_key",
            "media-key diagnosis is hotkey_fkey_arrived_as_media_key"
        )
        assertEqual(
            PhysicalShortcutDiagnosticEvent.modifierMismatch,
            "hotkey_modifier_mismatch",
            "wrong-modifier diagnosis is hotkey_modifier_mismatch"
        )
        assertEqual(
            PhysicalShortcutDiagnosticEvent.tapDisabled,
            "physical_shortcut_tap_disabled",
            "tap-disable diagnosis is physical_shortcut_tap_disabled"
        )
        assertEqual(
            PhysicalShortcutDiagnosticEvent.installed,
            "physical_shortcut_trigger_installed",
            "install diagnosis is physical_shortcut_trigger_installed"
        )
        for name in [
            PhysicalShortcutDiagnosticEvent.mediaKey,
            PhysicalShortcutDiagnosticEvent.modifierMismatch,
            PhysicalShortcutDiagnosticEvent.tapDisabled,
            PhysicalShortcutDiagnosticEvent.installed,
        ] {
            let lowered = name.lowercased()
            for fragment in PayloadSanitizationCore.baseSensitiveKeyFragments {
                assertFalse(
                    lowered.contains(fragment),
                    "event \(name) contains sanitizer drop fragment \(fragment)"
                )
            }
        }
    }

    runSuite("The shortcut tap listens for NSSystemDefined media-key events") {
        let mask = PhysicalShortcutTapPolicy.eventsOfInterestMask()
        let systemDefinedBit = CGEventMask(1) << PhysicalShortcutTapPolicy.systemDefinedEventTypeRawValue
        assertEqual(
            PhysicalShortcutTapPolicy.systemDefinedEventTypeRawValue,
            14,
            "NSEvent.EventType.system / NX_SYSDEFINED is 14"
        )
        assertTrue(
            (mask & systemDefinedBit) != 0,
            "F8-as-play/pause never reaches the tap unless NSSystemDefined is in the mask"
        )
        assertTrue(
            (mask & (CGEventMask(1) << CGEventType.keyDown.rawValue)) != 0,
            "keyDown stays in the mask"
        )
        assertTrue(
            (mask & (CGEventMask(1) << CGEventType.keyUp.rawValue)) != 0,
            "keyUp stays in the mask"
        )
        assertTrue(
            (mask & (CGEventMask(1) << CGEventType.flagsChanged.rawValue)) != 0,
            "flagsChanged stays in the mask"
        )
    }

    runSuite("NSSystemDefined media-key events always pass through and are never swallowed") {
        assertTrue(
            PhysicalShortcutTapPolicy.mustPassThrough(
                eventTypeRawValue: PhysicalShortcutTapPolicy.systemDefinedEventTypeRawValue
            ),
            "a media key the tap sees must still reach macOS (play/pause, volume)"
        )
        assertFalse(
            PhysicalShortcutTapPolicy.mustPassThrough(eventTypeRawValue: CGEventType.keyDown.rawValue),
            "ordinary keyDown is not a pass-through-only media key"
        )
    }

    runSuite("A play/pause media key parses as NX type 16 on key down") {
        let down = PhysicalShortcutMediaKeyPolicy.parseAuxControl(
            subtype: PhysicalShortcutMediaKeyPolicy.auxControlButtonsSubtype,
            data1: auxControlData1(nxKeyType: 16, isKeyDown: true)
        )
        assertEqual(down?.nxKeyType, Optional(16), "F8-as-media-key is NX_KEYTYPE_PLAY = 16")
        assertEqual(down?.isKeyDown, Optional(true), "key-down state 0xA is a press")

        let up = PhysicalShortcutMediaKeyPolicy.parseAuxControl(
            subtype: PhysicalShortcutMediaKeyPolicy.auxControlButtonsSubtype,
            data1: auxControlData1(nxKeyType: 16, isKeyDown: false)
        )
        assertEqual(up?.isKeyDown, Optional(false), "key-up state 0xB is a release")

        assertTrue(
            PhysicalShortcutMediaKeyPolicy.parseAuxControl(
                subtype: 0,
                data1: auxControlData1(nxKeyType: 16, isKeyDown: true)
            ) == nil,
            "only AUX_CONTROL_BUTTONS (subtype 8) is a media key"
        )
    }

    runSuite("F8 in media-key mode is play/pause; other F-keys map to their hardware keys") {
        assertEqual(
            PhysicalShortcutMediaKeyPolicy.nxKeyType(forFunctionKey: f8),
            Optional(PhysicalShortcutMediaKeyPolicy.playPauseNXKeyType),
            "F8's media-key form is play/pause"
        )
        assertEqual(
            PhysicalShortcutMediaKeyPolicy.nxKeyType(forFunctionKey: UInt32(kVK_F10)),
            Optional(7),
            "F10's media-key form is mute"
        )
        assertEqual(
            PhysicalShortcutMediaKeyPolicy.nxKeyType(forFunctionKey: UInt32(kVK_F12)),
            Optional(0),
            "F12's media-key form is volume up"
        )
        assertTrue(
            PhysicalShortcutMediaKeyPolicy.nxKeyType(forFunctionKey: UInt32(kVK_F20)) == nil,
            "F13-F20 have no media-key form"
        )
        assertTrue(
            PhysicalShortcutMediaKeyPolicy.nxKeyType(forFunctionKey: UInt32(kVK_RightOption)) == nil,
            "Right Option is not a media key"
        )
    }

    runSuite("A configured dictation F-key arriving as its media key is diagnosable") {
        assertTrue(
            PhysicalShortcutMediaKeyPolicy.dictationFunctionKeyArrivedAsMediaKey(
                nxKeyType: PhysicalShortcutMediaKeyPolicy.playPauseNXKeyType,
                dictationBinding: savedF8
            ),
            "play/pause is the saved F8 dictation key arriving as a media key"
        )
        assertTrue(
            PhysicalShortcutMediaKeyPolicy.dictationFunctionKeyArrivedAsMediaKey(
                nxKeyType: 19,
                dictationBinding: PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_F9))
            ),
            "NX_KEYTYPE_FAST is F9's next-track alias"
        )
        assertFalse(
            PhysicalShortcutMediaKeyPolicy.dictationFunctionKeyArrivedAsMediaKey(
                nxKeyType: PhysicalShortcutMediaKeyPolicy.playPauseNXKeyType,
                dictationBinding: rightOption
            ),
            "play/pause is not Right Option"
        )
        assertFalse(
            PhysicalShortcutMediaKeyPolicy.dictationFunctionKeyArrivedAsMediaKey(
                nxKeyType: 7,
                dictationBinding: savedF8
            ),
            "mute is not the saved F8"
        )
        assertFalse(
            PhysicalShortcutMediaKeyPolicy.dictationFunctionKeyArrivedAsMediaKey(
                nxKeyType: PhysicalShortcutMediaKeyPolicy.playPauseNXKeyType,
                dictationBinding: nil
            ),
            "no dictation binding means this media key is not our F-key"
        )
        assertEqual(
            PhysicalShortcutMediaKeyPolicy.nxKeyKind(16),
            "play",
            "the log names the media-key kind, not a raw number"
        )
        let mediaContext = PhysicalShortcutMediaKeyPolicy.mediaKeyContext(nxKeyType: 16)
        assertEqual(mediaContext["nx_key_kind"], "play", "media-key log context is categorical")
        assertDiagnosticKeysSurviveSanitizer(mediaContext, label: "media-key log")
    }

    runSuite("A modifier mismatch logs only for the saved key, never for other typing") {
        assertTrue(
            PhysicalShortcutModifierMismatchPolicy.shouldLog(
                saved: savedF8,
                keyCode: f8,
                modifiers: command
            ),
            "Cmd+F8 on a saved F8 is a mismatch worth logging"
        )
        assertTrue(
            PhysicalShortcutModifierMismatchPolicy.shouldLog(
                saved: savedF8,
                keyCode: f8,
                modifiers: option | shift
            ),
            "Option+Shift+F8 on a saved F8 is a mismatch worth logging"
        )
        assertTrue(
            PhysicalShortcutModifierMismatchPolicy.shouldLog(
                saved: savedF8,
                keyCode: f8,
                modifiers: control
            ),
            "Control+F8 on a saved F8 is a mismatch worth logging"
        )
        assertFalse(
            PhysicalShortcutModifierMismatchPolicy.shouldLog(
                saved: savedF8,
                keyCode: f8,
                modifiers: 0
            ),
            "a matching F8 press is not a mismatch"
        )
        assertFalse(
            PhysicalShortcutModifierMismatchPolicy.shouldLog(
                saved: savedF8,
                keyCode: f8,
                modifiers: function
            ),
            "Fn on an F-key is not a mismatch"
        )
        assertFalse(
            PhysicalShortcutModifierMismatchPolicy.shouldLog(
                saved: savedF8,
                keyCode: UInt32(kVK_Space),
                modifiers: command
            ),
            "Cmd+Space must not log; only the saved key is in scope"
        )
        assertFalse(
            PhysicalShortcutModifierMismatchPolicy.shouldLog(
                saved: savedF8,
                keyCode: UInt32(kVK_ANSI_A),
                modifiers: 0
            ),
            "ordinary typing must not log"
        )

        let optionM = PhysicalDictationTriggerPreferences.defaultMeetingBinding
        assertFalse(
            PhysicalShortcutModifierMismatchPolicy.shouldLog(
                saved: optionM,
                keyCode: UInt32(kVK_ANSI_M),
                modifiers: 0
            ),
            "bare M while Option+M is saved is typing, not a logged mismatch"
        )
        assertTrue(
            PhysicalShortcutModifierMismatchPolicy.shouldLog(
                saved: optionM,
                keyCode: UInt32(kVK_ANSI_M),
                modifiers: command
            ),
            "Cmd+M on a saved Option+M is a mismatch on the saved key"
        )
        assertFalse(
            PhysicalShortcutModifierMismatchPolicy.shouldLog(
                saved: optionM,
                keyCode: UInt32(kVK_ANSI_M),
                modifiers: option
            ),
            "Option+M matches the meeting shortcut"
        )
    }

    runSuite("Tap-disable logs the reason and whether the tap was re-enabled") {
        assertEqual(
            PhysicalShortcutTapPolicy.tapDisabledReason(for: .tapDisabledByTimeout),
            "timeout",
            "macOS disabling the tap for being slow is reason timeout"
        )
        assertEqual(
            PhysicalShortcutTapPolicy.tapDisabledReason(for: .tapDisabledByUserInput),
            "user_input",
            "macOS disabling the tap for user input is reason user_input"
        )
        assertTrue(
            PhysicalShortcutTapPolicy.tapDisabledReason(for: .keyDown) == nil,
            "ordinary key events are not a tap-disable"
        )
        let reenabled = PhysicalShortcutTapPolicy.tapDisabledContext(reason: "timeout", reenabled: true)
        assertEqual(reenabled["reason"], "timeout", "reason stays categorical")
        assertEqual(reenabled["reenabled"], "true", "re-enable result is a boolean string")
        let leftOff = PhysicalShortcutTapPolicy.tapDisabledContext(reason: "user_input", reenabled: false)
        assertEqual(leftOff["reenabled"], "false", "a failed re-enable is visible")
        assertDiagnosticKeysSurviveSanitizer(reenabled, label: "tap-disabled log")
    }

    runSuite("Installing the tap logs which bindings were installed") {
        let both = [
            PhysicalShortcutBinding(action: .dictationPushToTalk, binding: savedF8),
            PhysicalShortcutBinding(
                action: .meeting,
                binding: PhysicalDictationTriggerPreferences.defaultMeetingBinding
            ),
        ]
        let bothContext = PhysicalShortcutTapPolicy.installedBindingsContext(both)
        assertEqual(
            bothContext["actions"],
            "dictation_push_to_talk,meeting",
            "the log names the installed actions, not key display names"
        )
        assertEqual(bothContext["dictation_is_fkey"], "true", "an F-key dictation binding is flagged")
        assertDiagnosticKeysSurviveSanitizer(bothContext, label: "install log")

        let handsFree = [
            PhysicalShortcutBinding(action: .dictationHandsFree, binding: rightOption),
            PhysicalShortcutBinding(
                action: .meeting,
                binding: PhysicalDictationTriggerPreferences.defaultMeetingBinding
            ),
        ]
        let handsFreeContext = PhysicalShortcutTapPolicy.installedBindingsContext(handsFree)
        assertEqual(
            handsFreeContext["actions"],
            "dictation_hands_free,meeting",
            "tap-to-toggle installs as hands-free"
        )
        assertEqual(handsFreeContext["dictation_is_fkey"], "false", "Right Option is not an F-key")

        let meetingOnly = [
            PhysicalShortcutBinding(
                action: .meeting,
                binding: PhysicalDictationTriggerPreferences.defaultMeetingBinding
            ),
        ]
        let meetingContext = PhysicalShortcutTapPolicy.installedBindingsContext(meetingOnly)
        assertEqual(meetingContext["actions"], "meeting", "dictation shortcuts off still installs meetings")
        assertEqual(meetingContext["dictation_is_fkey"], "false", "no dictation binding is not an F-key")
    }

    runSuite("Media-key and modifier-mismatch logs are rate-limited on an injected clock") {
        var limiter = PhysicalShortcutDiagnosticRateLimiter(interval: 5)
        assertTrue(limiter.shouldEmit("hotkey_fkey_arrived_as_media_key", now: 100), "first diagnostic goes through")
        assertFalse(
            limiter.shouldEmit("hotkey_fkey_arrived_as_media_key", now: 104.9),
            "a repeat inside 5s is dropped"
        )
        assertTrue(
            limiter.shouldEmit("hotkey_fkey_arrived_as_media_key", now: 105),
            "a diagnostic at the 5s edge goes through"
        )
        assertTrue(
            limiter.shouldEmit("hotkey_modifier_mismatch", now: 105.1),
            "a different diagnostic has its own window"
        )
        assertEqual(
            PhysicalShortcutTapPolicy.diagnosticLogInterval,
            5,
            "the tap uses a 5s window for media-key and mismatch logs"
        )
    }
}

private func auxControlData1(nxKeyType: Int, isKeyDown: Bool) -> Int {
    let state = isKeyDown ? PhysicalShortcutMediaKeyPolicy.keyDownState : PhysicalShortcutMediaKeyPolicy.keyUpState
    return (nxKeyType << 16) | (state << 8)
}

private func assertDiagnosticKeysSurviveSanitizer(_ context: [String: String], label: String) {
    let fragments = PayloadSanitizationCore.baseSensitiveKeyFragments
    for key in context.keys {
        let lowered = key.lowercased()
        for fragment in fragments {
            assertFalse(
                lowered.contains(fragment),
                "\(label) key \(key) contains sanitizer drop fragment \(fragment)"
            )
        }
    }
}
