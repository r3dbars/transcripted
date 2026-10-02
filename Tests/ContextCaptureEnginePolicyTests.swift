// ContextCaptureEnginePolicyTests.swift
// Promises the capture engine keeps, checked through the pure seams it
// delegates to: the per-action hotkey repeat guard, the binding snapshot the
// event tap matches against, tap-disabled recovery, the Accessibility retry
// gate, the hotkey banner, and the default bindings, display strings and
// chord matching the detector relies on.
//
// ContextCaptureEngine itself is @MainActor and wired to AppKit, NSWorkspace,
// CGEventTap and DictationSessionController, so this runner doesn't build it.
// What still needs the real app (the tap's dedicated run-loop thread, the
// Accessibility polling loop, lock-held delayed press delivery) is covered by
// `bash check.sh hardware` and the manual checks in Sources/Capture/CLAUDE.md.

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

    runSuite("Hotkey repeat guard — a second press of the same toggle inside the window is dropped") {
        var debouncer = HotkeyActionDebouncer(interval: 0.2)
        assertTrue(debouncer.shouldAccept(.dictationHandsFree, now: 100), "first hands-free press goes through")
        assertFalse(debouncer.shouldAccept(.dictationHandsFree, now: 100.1), "a Carbon double-fire 100ms later is dropped")
        assertTrue(debouncer.shouldAccept(.dictationHandsFree, now: 100.3), "a press after the window goes through")
        assertFalse(debouncer.shouldAccept(.dictationHandsFree, now: 100.4), "the window restarts from the last accepted press")
    }

    runSuite("Hotkey repeat guard — each toggle action has its own window") {
        var debouncer = HotkeyActionDebouncer(interval: 0.2)
        assertTrue(debouncer.shouldAccept(.dictationHandsFree, now: 50), "hands-free press goes through")
        assertTrue(debouncer.shouldAccept(.meeting, now: 50.05), "a meeting press right after a dictation press still goes through")
        assertTrue(debouncer.shouldAccept(.pasteLastDictation, now: 50.1), "paste-last-dictation has its own window too")
        assertFalse(debouncer.shouldAccept(.meeting, now: 50.1), "a repeat meeting press is still dropped")
    }

    runSuite("Hotkey repeat guard — push-to-talk presses are never dropped") {
        // Its release is paired to the physical key hold. A swallowed press
        // would leave a release with nothing to stop.
        var debouncer = HotkeyActionDebouncer(interval: 0.2)
        assertNil(PhysicalShortcutAction.dictationPushToTalk.hotkeyDebounceID, "push-to-talk has no repeat bucket")
        assertTrue(debouncer.shouldAccept(.dictationPushToTalk, now: 10), "first push-to-talk press goes through")
        assertTrue(debouncer.shouldAccept(.dictationPushToTalk, now: 10.01), "a quick second hold still goes through")
        assertTrue(debouncer.shouldAccept(.dictationHandsFree, now: 10.02), "push-to-talk presses don't use up the hands-free window")
    }

    runSuite("Hotkey repeat guard — default window is the shared debounce constant") {
        var debouncer = HotkeyActionDebouncer()
        let interval = TranscriptedConstants.hotkeyActionDebounceInterval
        assertEqual(debouncer.interval, interval, "the engine's guard uses TranscriptedConstants.hotkeyActionDebounceInterval")
        assertTrue(debouncer.shouldAccept(.meeting, now: 1000), "first press goes through")
        assertFalse(debouncer.shouldAccept(.meeting, now: 1000 + interval / 2), "a repeat inside the shared window is dropped")
        assertTrue(debouncer.shouldAccept(.meeting, now: 1000 + interval), "a press at the window edge goes through")
    }

    runSuite("Hotkey repeat guard — telemetry ids stay stable") {
        assertEqual(PhysicalShortcutAction.dictationHandsFree.hotkeyDebounceID, "dictation_hands_free", "hands-free bucket id")
        assertEqual(PhysicalShortcutAction.meeting.hotkeyDebounceID, "meeting_physical_trigger", "meeting bucket id")
        assertEqual(
            PhysicalShortcutAction.pasteLastDictation.hotkeyDebounceID,
            "paste_last_dictation_physical_trigger",
            "paste-last-dictation bucket id"
        )
    }

    runSuite("Tap re-enable — a push-to-talk key let go while the tap was off gets its release") {
        let fn = UInt32(kVK_Function)
        let m = UInt32(kVK_ANSI_M)
        let result = PhysicalShortcutMatcher.reconcileAfterTapDisabled(
            activePushToTalkKeyCode: fn,
            consumedKeyCodes: [fn, m],
            isPhysicallyDown: { _ in false }
        )
        assertTrue(result.synthesizesPushToTalkRelease, "the missed keyUp must become a push-to-talk release so the take stops and pastes")
        assertNil(result.activePushToTalkKeyCode, "push-to-talk is no longer active")
        assertEqual(result.consumedKeyCodes, [], "keys that are no longer down are forgotten so their next press isn't swallowed")
    }

    runSuite("Tap re-enable — a push-to-talk key still held keeps recording") {
        let fn = UInt32(kVK_Function)
        let m = UInt32(kVK_ANSI_M)
        let result = PhysicalShortcutMatcher.reconcileAfterTapDisabled(
            activePushToTalkKeyCode: fn,
            consumedKeyCodes: [fn, m],
            isPhysicallyDown: { $0 == fn }
        )
        assertFalse(result.synthesizesPushToTalkRelease, "a held key must not be released early")
        assertEqual(result.activePushToTalkKeyCode, fn, "push-to-talk stays active")
        assertEqual(result.consumedKeyCodes, [fn], "the held key stays consumed; the released one is dropped")
    }

    runSuite("Tap re-enable — nothing active means no release") {
        let result = PhysicalShortcutMatcher.reconcileAfterTapDisabled(
            activePushToTalkKeyCode: nil,
            consumedKeyCodes: [],
            isPhysicallyDown: { _ in false }
        )
        assertFalse(result.synthesizesPushToTalkRelease, "no push-to-talk hold means nothing to release")
        assertNil(result.activePushToTalkKeyCode, "stays idle")
    }

    runSuite("Physical key state — a modifier key counts as down while its modifier family is held") {
        let rightOption = UInt32(kVK_RightOption)
        assertTrue(
            PhysicalShortcutMatcher.isPhysicalKeyDown(
                rightOption,
                modifierFlags: PhysicalDictationTriggerModifiers.option,
                keyState: { _ in false }
            ),
            "recovery reads the Option flag for an Option binding"
        )
        assertFalse(
            PhysicalShortcutMatcher.isPhysicalKeyDown(rightOption, modifierFlags: 0, keyState: { _ in true }),
            "no Option flag means the Option binding was let go"
        )
        let m = UInt32(kVK_ANSI_M)
        assertTrue(
            PhysicalShortcutMatcher.isPhysicalKeyDown(m, modifierFlags: 0, keyState: { $0 == m }),
            "a typing key reads its own key state"
        )
        assertFalse(
            PhysicalShortcutMatcher.isPhysicalKeyDown(m, modifierFlags: PhysicalDictationTriggerModifiers.option, keyState: { _ in false }),
            "modifier flags don't make a typing key look held"
        )
    }

    runSuite("Delayed modifier press — checks the bound key, not the whole modifier family") {
        let rightOption = UInt32(kVK_RightOption)
        let leftOption = UInt32(kVK_Option)
        let press = DelayedModifierShortcutPress(generation: 3, keyCode: rightOption, action: .dictationPushToTalk)
        assertFalse(
            PhysicalShortcutMatcher.shouldActivateDelayedModifierPress(
                current: press,
                expected: press,
                keyState: { $0 == leftOption }
            ),
            "Left Option held must not start a Right Option push-to-talk"
        )
        assertTrue(
            PhysicalShortcutMatcher.shouldActivateDelayedModifierPress(
                current: press,
                expected: press,
                keyState: { $0 == rightOption }
            ),
            "the bound Right Option still held starts push-to-talk"
        )
        assertFalse(
            PhysicalShortcutMatcher.shouldActivateDelayedModifierPress(
                current: nil,
                expected: press,
                keyState: { _ in true }
            ),
            "a press that was already cancelled never activates"
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

    runSuite("Binding snapshot — dictation shortcuts on: push-to-talk, hands-free, meeting, paste") {
        let (defaults, suiteName) = makeContextCaptureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let bindings = PhysicalShortcutMatcher.configuredBindings(userDefaults: defaults)
        assertEqual(
            bindings.map(\.action),
            [.dictationPushToTalk, .dictationHandsFree, .meeting, .pasteLastDictation],
            "dictation shortcuts come first so they win shared-key ties"
        )
        assertEqual(bindings.map(\.binding), [
            PhysicalDictationTriggerPreferences.defaultPushToTalkBinding,
            PhysicalDictationTriggerPreferences.defaultHandsFreeBinding,
            PhysicalDictationTriggerPreferences.defaultMeetingBinding,
            PhysicalDictationTriggerPreferences.defaultPasteLastDictationBinding,
        ], "a fresh install snapshots the default bindings")
    }

    runSuite("Binding snapshot — dictation shortcuts off still keeps meeting and paste") {
        let (defaults, suiteName) = makeContextCaptureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "hotkey-dictation-shortcuts-enabled")

        let bindings = PhysicalShortcutMatcher.configuredBindings(userDefaults: defaults)
        assertEqual(
            bindings.map(\.action),
            [.meeting, .pasteLastDictation],
            "turning dictation shortcuts off must not take the meeting or paste shortcuts with it"
        )
    }

    runSuite("Binding snapshot — reflects saved bindings when rebuilt") {
        let (defaults, suiteName) = makeContextCaptureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let before = PhysicalShortcutMatcher.configuredBindings(userDefaults: defaults)
        defaults.set(false, forKey: "hotkey-dictation-shortcuts-enabled")
        let after = PhysicalShortcutMatcher.configuredBindings(userDefaults: defaults)
        assertEqual(before.count, 4, "first snapshot has all four shortcuts")
        assertEqual(after.count, 2, "a rebuild after a preference change picks up the new state")
    }

    runSuite("Accessibility retry — only a missing grant waits for the grant") {
        let missingGrant = PhysicalShortcutTriggerStatus.tapCreateFailureMessage(accessibilityGranted: false)
        let otherFailure = PhysicalShortcutTriggerStatus.tapCreateFailureMessage(accessibilityGranted: true)

        assertEqual(missingGrant, "Shortcut trigger needs Accessibility permission", "the menu bar matches on this text to offer the Accessibility pane")
        assertTrue(
            PhysicalShortcutTriggerStatus.retriesAfterAccessibilityGrant(registrationError: missingGrant),
            "a missing grant keeps polling so granting it re-registers without wake or relaunch"
        )
        assertFalse(
            PhysicalShortcutTriggerStatus.retriesAfterAccessibilityGrant(registrationError: otherFailure),
            "a tap failure with Accessibility granted isn't fixed by waiting for the grant"
        )
        assertFalse(
            PhysicalShortcutTriggerStatus.retriesAfterAccessibilityGrant(registrationError: nil),
            "a working tap doesn't poll"
        )
    }

    runSuite("Hotkey banner — a Fn conflict is advisory, never a registration failure") {
        let warning = "Fn conflict"
        assertEqual(
            PhysicalShortcutTriggerStatus.bannerMessage(
                registrationError: nil,
                dictationShortcutsEnabled: true,
                functionKeyConflictWarning: warning
            ),
            warning,
            "with the tap working, the Fn conflict shows in the banner"
        )
        // Wake recovery reads the registration error (nil here), not this
        // banner, so it doesn't retry registration over an advisory warning.
        assertEqual(
            PhysicalShortcutTriggerStatus.bannerMessage(
                registrationError: "Shortcut trigger failed to start",
                dictationShortcutsEnabled: true,
                functionKeyConflictWarning: warning
            ),
            "Shortcut trigger failed to start",
            "a registration failure wins: one message at a time so the header isn't clipped"
        )
        assertNil(
            PhysicalShortcutTriggerStatus.bannerMessage(
                registrationError: nil,
                dictationShortcutsEnabled: false,
                functionKeyConflictWarning: warning
            ),
            "the Fn conflict doesn't matter while dictation shortcuts are off"
        )
    }

    runSuite("Ignored stop during finishing — says it's still finishing instead of a silent swallow") {
        func route(finishing: Bool) -> DictationStopRoute {
            DictationStopRoute.route(
                stopDecision: .ignoreInactive, trigger: .physicalKey,
                isFinishingPreviousTake: finishing, isRecording: false, hasRecoverableRecording: false
            )
        }
        assertEqual(
            route(finishing: true),
            .ignore(showStillFinishing: true),
            "a stop press while the last take is drafting or transcribing gets the visible finishing message"
        )
        assertEqual(
            route(finishing: false),
            .ignore(showStillFinishing: false),
            "with nothing finishing, an ignored stop stays quiet"
        )
        assertEqual(
            DictationStopRoute.stillFinishingMessage,
            "Still finishing the last dictation. Try again in a moment.",
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
    // ContextCaptureEngine.updateHotkeyError() shows physicalTriggerError, or
    // else (when dictation shortcuts are enabled) the function-key conflict warning.
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
    }

    runSuite("PhysicalDictationTriggerPreferences.functionKeyConflictWarning — warns on a fresh Mac where Fn was never set") {
        let fn = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Function))

        // macOS only writes AppleFnUsageType once someone changes it, and its
        // default is never Do Nothing, so a missing value still conflicts.
        let warning = PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
            for: fn,
            systemAction: .notConfigured
        )
        assertTrue(warning != nil, "bare Fn should warn when AppleFnUsageType is missing")
        assertTrue(
            warning?.contains("Do Nothing") == true,
            "the missing-setting warning should still say which option to pick"
        )
        assertFalse(
            warning?.contains("macOS default in macOS") == true,
            "the missing-setting warning should read naturally"
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

    // MARK: - Modifier-key routing classifications
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
