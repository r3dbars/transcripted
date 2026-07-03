// ContextCaptureEnginePolicyTests.swift
// Tests for the externally-observable policy that ContextCaptureEngine relies on:
// the hotkey-action debounce constant, the hotkeys-changed notification name,
// the default binding set that feeds the detector's cached binding snapshot,
// and the conflict-warning text that flows into the engine's hotkeyError
// pipeline.
//
// NOTE: ContextCaptureEngine itself is @MainActor and wired to AppKit,
// NSWorkspace, DictationSessionController, FloatingOverlayController,
// EventReporter, and DiagnosticsTrail. Its remaining internal seams
// (shouldAcceptHotkeyAction, routeDictationToggle, PhysicalShortcutDetector)
// are file-private. These tests cover the shared constants and preference seams
// the engine consumes, plus the pure chord-resolution precedence the engine now
// delegates to PhysicalShortcutMatcher (PhysicalShortcutAction /
// PhysicalShortcutBinding live alongside it), not the engine class itself.

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
        assertTrue(
            source.contains("shouldAcceptHotkeyAction(\"paste_last_dictation_physical_trigger\")"),
            "paste-last-dictation trigger should have its own debounce key"
        )
    }

    runSuite("ContextCaptureEngine hotkey unregister — preserves paste callback owner") {
        let source = readContextCaptureEngineSource()

        assertTrue(
            source.contains("var onPasteLastDictation: (() -> Void)?"),
            "paste-last-dictation callback should stay on the engine like the meeting toggle callback"
        )
        assertFalse(
            source.contains("onPasteLastDictation = nil"),
            "hotkey unregister/re-register recovery should not clear the app-owned paste callback"
        )
    }

    // MARK: - Notification.Name.hotkeysDidChange
    // The engine subscribes to this notification to re-register hotkeys when
    // HotkeyRecorderView writes new bindings. Renaming the notification would
    // silently break preference live-updates — and, since the detector caches
    // its binding snapshot, would also leave the CGEventTap matching stale
    // shortcuts.

    runSuite("Notification.Name.hotkeysDidChange — stable raw value") {
        assertEqual(
            Notification.Name.hotkeysDidChange.rawValue,
            "hotkeysDidChange",
            "engine's preference observer is bound to this exact notification name"
        )
    }

    // MARK: - Cached binding snapshot
    // The CGEventTap callback runs for every system-wide
    // keyDown/keyUp/flagsChanged. It must read a cached binding snapshot —
    // rebuilt on .hotkeysDidChange — instead of hitting UserDefaults (4 binding
    // lookups plus migration fallbacks) per keystroke, which added latency to
    // all typing on the machine and raised the tapDisabledByTimeout risk.

    runSuite("ContextCaptureEngine binding snapshot — tap callback reads cached bindings, not per-event UserDefaults") {
        let source = readContextCaptureEngineSource()

        assertTrue(
            source.contains("physicalShortcutDetector.updateShortcutBindings(Self.currentShortcutBindings())"),
            "engine should rebuild the detector's cached binding snapshot when it (re)configures the detector"
        )
        assertFalse(
            source.contains("bindingProvider"),
            "per-event binding provider closure must stay removed — the tap callback reads the cached snapshot instead of resolving preferences per keystroke"
        )
    }

    runSuite("ContextCaptureEngine event tap — serviced on dedicated run loop instead of main") {
        let source = readContextCaptureEngineSource()

        assertTrue(
            source.contains("TranscriptedPhysicalShortcutTap"),
            "physical shortcut event tap should run on its own named thread"
        )
        assertTrue(
            source.contains("CFRunLoopAddSource(runLoop, source, .commonModes)"),
            "event tap source should be installed on the dedicated thread run loop"
        )
        assertFalse(
            source.contains("CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)"),
            "system-wide keyboard events must not be serviced on the app's main run loop"
        )
    }

    runSuite("ContextCaptureEngine tap-disabled recovery — reconciles missed push-to-talk release") {
        let source = readContextCaptureEngineSource()

        assertTrue(
            source.contains("reconcileStateAfterTapWasDisabled()"),
            "tap-disabled events should reconcile detector state before re-enabling the tap"
        )
        assertTrue(
            source.contains("CGEventSource.keyState(.combinedSessionState"),
            "reconciliation should check the physical key state for a missed keyUp"
        )
        assertTrue(
            source.contains("onShortcut?(.dictationPushToTalk, .release)"),
            "a released push-to-talk key should synthesize the missing release callback"
        )
    }

    runSuite("ContextCaptureEngine Accessibility retry — re-registers after permission is granted") {
        let source = readContextCaptureEngineSource()

        assertTrue(
            source.contains("accessibilityRetryTask"),
            "engine should keep a lightweight retry task while Accessibility is missing"
        )
        assertTrue(
            source.contains("TranscriptedPermissionAccess.isGranted(.accessibility)"),
            "retry task should poll the real Accessibility grant state"
        )
        assertTrue(
            source.contains("self.reRegisterHotkeys()"),
            "granting Accessibility should re-attempt physical trigger registration without waiting for wake or relaunch"
        )
    }

    runSuite("TranscriptedAppState wake recovery — uses registration error, not advisory warning") {
        let appStateSource = readRepoSource("Sources/TranscriptedAppState.swift")
        let contextSource = readContextCaptureEngineSource()

        assertTrue(
            contextSource.contains("var hotkeyRegistrationError: String?"),
            "ContextCaptureEngine should expose the real registration failure separately from advisory banner text"
        )
        assertTrue(
            appStateSource.contains("self?.contextCapture.hotkeyRegistrationError"),
            "wake recovery should ignore Fn-conflict advisory warnings when deciding whether registration succeeded"
        )
        assertFalse(
            appStateSource.contains("self?.contextCapture.hotkeyError"),
            "wake recovery must not treat advisory hotkeyError banner text as registration failure"
        )
    }

    runSuite("DictationSessionController finishing hotkey — shows visible feedback instead of silent swallow") {
        let source = readRepoSource("Sources/UI/Overlay/DictationSessionController.swift")

        assertTrue(
            source.contains("if overlayController.state == .drafting"),
            "ignored stop/start intent during the drafting/transcribing window should be surfaced to the user"
        )
        assertTrue(
            source.contains("overlayController.showError(\"Still finishing the last dictation. Try again in a moment.\")"),
            "finishing-window hotkey press should reuse the existing visible finishing message"
        )
    }

    // MARK: - Binding snapshot default set
    // The engine's binding snapshot always includes the meeting binding and,
    // when dictation shortcuts are enabled, prepends push-to-talk and
    // hands-free. Pin the defaults a fresh install hands the snapshot.

    runSuite("PhysicalDictationTriggerPreferences fresh install — engine binding snapshot sees Fn / Right Option / Option-M / Option-Shift-V") {
        let (defaults, suiteName) = makeContextCaptureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pushToTalk = PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults)
        let handsFree = PhysicalDictationTriggerPreferences.handsFreeBinding(userDefaults: defaults)
        let meeting = PhysicalDictationTriggerPreferences.meetingBinding(userDefaults: defaults)
        let pasteLastDictation = PhysicalDictationTriggerPreferences.pasteLastDictationBinding(userDefaults: defaults)

        assertEqual(pushToTalk.keyCode, UInt32(kVK_Function), "push-to-talk default keyCode should be Fn")
        assertEqual(pushToTalk.modifiers, 0, "push-to-talk default should have no modifiers")
        assertEqual(handsFree.keyCode, UInt32(kVK_RightOption), "hands-free default keyCode should be Right Option")
        assertEqual(handsFree.modifiers, 0, "hands-free default should have no modifiers")
        assertEqual(meeting.keyCode, UInt32(kVK_ANSI_M), "meeting default keyCode should be M")
        assertEqual(meeting.modifiers, PhysicalDictationTriggerModifiers.option, "meeting default modifier should be Option")
        assertEqual(pasteLastDictation.keyCode, UInt32(kVK_ANSI_V), "paste-last-dictation default keyCode should be V")
        assertEqual(
            pasteLastDictation.modifiers,
            PhysicalDictationTriggerModifiers.option | PhysicalDictationTriggerModifiers.shift,
            "paste-last-dictation default modifiers should be Option Shift"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences fresh install — meeting and paste bindings are independent of dictation shortcuts toggle") {
        // The engine's binding snapshot always includes the meeting and paste bindings,
        // even when dictation shortcuts are off. The meeting default must
        // therefore survive in the absence of any saved dictation preference,
        // and paste-last-dictation stays available as a recovery action.
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
        assertEqual(
            PhysicalDictationTriggerPreferences.pasteLastDictationBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultPasteLastDictationBinding,
            "paste-last-dictation binding should stay available even when dictation shortcuts are disabled"
        )
    }

    // MARK: - dictationShortcutsEnabled default
    // The engine checks this preference when it rebuilds the detector's cached
    // binding snapshot. A fresh install must default to enabled so dictation
    // shortcuts work out of the box.

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
    // ContextCaptureEngine.updateHotkeyError() joins physicalTriggerError and
    // (when dictation shortcuts are enabled) the function-key conflict warning.
    // Pin the conflict-warning text since it
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

    runSuite("PhysicalDictationTriggerPreferences.displayString — paste-last-dictation default formats as Option-Shift-V chord") {
        assertEqual(
            PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.defaultPasteLastDictationBinding),
            "⌥⇧V",
            "paste-last-dictation default should render as ⌥⇧V in shortcut editors"
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

    runSuite("PhysicalDictationTriggerPreferences.matchesKeyDown — paste-last-dictation Option-Shift-V binding accepts ⌥⇧V keyDown") {
        let pasteLastDictation = PhysicalDictationTriggerPreferences.defaultPasteLastDictationBinding

        assertTrue(
            PhysicalDictationTriggerPreferences.matchesKeyDown(
                pasteLastDictation,
                keyCode: UInt32(kVK_ANSI_V),
                modifiers: PhysicalDictationTriggerModifiers.option | PhysicalDictationTriggerModifiers.shift
            ),
            "engine's keyDown matcher should accept the configured paste-last-dictation chord"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences.matchesKeyDown — paste-last-dictation binding rejects bare V") {
        let pasteLastDictation = PhysicalDictationTriggerPreferences.defaultPasteLastDictationBinding

        assertFalse(
            PhysicalDictationTriggerPreferences.matchesKeyDown(pasteLastDictation, keyCode: UInt32(kVK_ANSI_V), modifiers: 0),
            "bare V should not fire paste-last-dictation while a user is typing"
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

    // MARK: - PhysicalShortcutMatcher chord-resolution precedence
    // The detector resolves which configured binding a key event belongs to via
    // PhysicalShortcutMatcher. These exercise the real extracted matcher so its
    // exact-then-fallback precedence, per-action release scoping, and
    // shared-modifier chord detection stay faithful to the engine's behavior.

    runSuite("PhysicalShortcutMatcher.matchingFlagsChangedPressShortcut — exact keyCode binding wins over fallback") {
        // Two modifier-only bindings that both accept an Option flagsChanged
        // event: hands-free is on Left Option, push-to-talk on Right Option.
        // When the Right Option key fires, the exact-keyCode match must win even
        // though the Left Option binding would also satisfy the press matcher.
        let bindings = [
            PhysicalShortcutBinding(
                action: .dictationHandsFree,
                binding: PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Option))
            ),
            PhysicalShortcutBinding(
                action: .dictationPushToTalk,
                binding: PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_RightOption))
            )
        ]

        let match = PhysicalShortcutMatcher.matchingFlagsChangedPressShortcut(
            bindings,
            keyCode: UInt32(kVK_RightOption),
            modifiers: PhysicalDictationTriggerModifiers.option
        )

        assertEqual(
            match?.action,
            .dictationPushToTalk,
            "exact-keyCode flagsChanged binding must win over an equally-eligible fallback binding"
        )
    }

    runSuite("PhysicalShortcutMatcher.matchingFlagsChangedPressShortcut — falls back to a chord binding when the event uses a generic modifier keyCode") {
        // A Right Command + Shift chord. A generic Shift keyCode event with both
        // modifiers held belongs to the chord, but its keyCode (kVK_Shift) does
        // not equal the binding keyCode (kVK_RightCommand), so the exact pass
        // misses and the fallback pass must resolve it.
        let bindings = [
            PhysicalShortcutBinding(
                action: .dictationHandsFree,
                binding: PhysicalDictationTriggerBinding(
                    keyCode: UInt32(kVK_RightCommand),
                    modifiers: PhysicalDictationTriggerModifiers.shift
                )
            )
        ]

        let match = PhysicalShortcutMatcher.matchingFlagsChangedPressShortcut(
            bindings,
            keyCode: UInt32(kVK_Shift),
            modifiers: PhysicalDictationTriggerModifiers.command | PhysicalDictationTriggerModifiers.shift
        )

        assertEqual(
            match?.action,
            .dictationHandsFree,
            "a generic-modifier event that belongs to a chord should resolve via the fallback pass"
        )
    }

    runSuite("PhysicalShortcutMatcher.matchesRelease — only the binding for the requested action is consulted") {
        let bindings = [
            PhysicalShortcutBinding(
                action: .dictationHandsFree,
                binding: PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_RightOption))
            ),
            PhysicalShortcutBinding(
                action: .dictationPushToTalk,
                binding: PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Function))
            )
        ]

        // Right Option releasing (Option flag cleared) is a release for the
        // hands-free binding...
        assertTrue(
            PhysicalShortcutMatcher.matchesRelease(
                for: .dictationHandsFree,
                in: bindings,
                keyCode: UInt32(kVK_RightOption),
                modifiers: 0
            ),
            "release should match the hands-free binding when its Right Option flag clears"
        )

        // ...but the same key event must not count as a release for push-to-talk,
        // whose binding is the Fn key.
        assertFalse(
            PhysicalShortcutMatcher.matchesRelease(
                for: .dictationPushToTalk,
                in: bindings,
                keyCode: UInt32(kVK_RightOption),
                modifiers: 0
            ),
            "a Right Option release must not be treated as a release for the Fn-bound push-to-talk action"
        )
    }

    runSuite("PhysicalShortcutMatcher.matchesRelease — missing action binding never releases") {
        let bindings = [
            PhysicalShortcutBinding(
                action: .dictationHandsFree,
                binding: PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_RightOption))
            )
        ]

        assertFalse(
            PhysicalShortcutMatcher.matchesRelease(
                for: .meeting,
                in: bindings,
                keyCode: UInt32(kVK_RightOption),
                modifiers: 0
            ),
            "no configured binding for the action means there is nothing to release"
        )
    }

    runSuite("PhysicalShortcutMatcher.hasChordUsingModifier — detects a modifier shared by another action's chord") {
        // Hands-free is bare Right Option (Option flag). Meeting is an Option-M
        // chord, a keyed binding whose modifiers include Option. Pressing Right
        // Option therefore collides with the meeting chord and must be flagged
        // so the detector defers the bare-modifier shortcut.
        let bindings = [
            PhysicalShortcutBinding(
                action: .dictationHandsFree,
                binding: PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_RightOption))
            ),
            PhysicalShortcutBinding(
                action: .meeting,
                binding: PhysicalDictationTriggerBinding(
                    keyCode: UInt32(kVK_ANSI_M),
                    modifiers: PhysicalDictationTriggerModifiers.option
                )
            )
        ]

        assertTrue(
            PhysicalShortcutMatcher.hasChordUsingModifier(
                UInt32(kVK_RightOption),
                in: bindings,
                excluding: .dictationHandsFree
            ),
            "Right Option must be detected as feeding the meeting Option-M chord so the modifier press is deferred"
        )
    }

    runSuite("PhysicalShortcutMatcher.hasChordUsingModifier — ignores the excluded action and other modifier-only bindings") {
        // Excluding meeting removes the only chord that uses Option; the
        // remaining hands-free binding is itself a modifier-only key, which the
        // matcher must skip, so no shared chord is reported.
        let bindings = [
            PhysicalShortcutBinding(
                action: .dictationHandsFree,
                binding: PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_RightOption))
            ),
            PhysicalShortcutBinding(
                action: .meeting,
                binding: PhysicalDictationTriggerBinding(
                    keyCode: UInt32(kVK_ANSI_M),
                    modifiers: PhysicalDictationTriggerModifiers.option
                )
            )
        ]

        assertFalse(
            PhysicalShortcutMatcher.hasChordUsingModifier(
                UInt32(kVK_RightOption),
                in: bindings,
                excluding: .meeting
            ),
            "excluding the only Option chord leaves only a modifier-only binding, which is not a chord conflict"
        )
    }

    runSuite("PhysicalShortcutMatcher.hasChordUsingModifier — non-modifier keyCode has no primary mask") {
        let bindings = [
            PhysicalShortcutBinding(
                action: .meeting,
                binding: PhysicalDictationTriggerBinding(
                    keyCode: UInt32(kVK_ANSI_M),
                    modifiers: PhysicalDictationTriggerModifiers.option
                )
            )
        ]

        assertFalse(
            PhysicalShortcutMatcher.hasChordUsingModifier(
                UInt32(kVK_ANSI_M),
                in: bindings,
                excluding: .dictationHandsFree
            ),
            "a typing keyCode has no primary modifier mask, so it can't share a modifier with another chord"
        )
    }

    runSuite("PhysicalShortcutMatcher.matchingKeyDownShortcut — picks the binding whose chord the keyDown satisfies") {
        let bindings = [
            PhysicalShortcutBinding(
                action: .meeting,
                binding: PhysicalDictationTriggerBinding(
                    keyCode: UInt32(kVK_ANSI_M),
                    modifiers: PhysicalDictationTriggerModifiers.option
                )
            ),
            PhysicalShortcutBinding(
                action: .pasteLastDictation,
                binding: PhysicalDictationTriggerBinding(
                    keyCode: UInt32(kVK_ANSI_V),
                    modifiers: PhysicalDictationTriggerModifiers.option | PhysicalDictationTriggerModifiers.shift
                )
            )
        ]

        let match = PhysicalShortcutMatcher.matchingKeyDownShortcut(
            bindings,
            keyCode: UInt32(kVK_ANSI_V),
            modifiers: PhysicalDictationTriggerModifiers.option | PhysicalDictationTriggerModifiers.shift
        )

        assertEqual(
            match?.action,
            .pasteLastDictation,
            "keyDown matcher should resolve the Option-Shift-V chord to paste-last-dictation"
        )
        assertNil(
            PhysicalShortcutMatcher.matchingKeyDownShortcut(
                bindings,
                keyCode: UInt32(kVK_ANSI_V),
                modifiers: 0
            ),
            "bare V with no modifiers should match no keyDown binding"
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
    readRepoSource("Sources/Capture/ContextCaptureEngine.swift")
}

private func readRepoSource(_ path: String) -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(path)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}
