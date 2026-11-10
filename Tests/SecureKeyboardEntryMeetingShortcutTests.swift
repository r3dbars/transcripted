import Foundation

/// Literal binding assembly, pure policy and explicitly injected monitor only.
/// No preferences, engine, live secure-input source, process namer or event tap.
@MainActor
func testSecureKeyboardEntryMeetingShortcut() {
    // Public Carbon key values expressed as literals, without native calls:
    // Right Option=61, M=46, F8=100; app modifier bits option=4, Fn=16.
    let modifierDictation = PhysicalShortcutBinding(
        action: .dictationPushToTalk, binding: .init(keyCode: 61)
    )
    let meeting = PhysicalDictationTriggerBinding(keyCode: 46, modifiers: 4)

    func decide(
        previous: SecureEventInputWatchState = .idle,
        snapshot: SecureEventInputSnapshot = .init(
            isEnabled: true, ownerProcessID: 400, ownerDisplayName: "Synthetic owner"
        ),
        modifier: Bool = true,
        enabled: Bool = true,
        dictationDisplay: String = "Right ⌥",
        meetingDisplay: String? = "⌥M",
        now: TimeInterval = 100
    ) -> (SecureEventInputWatchState, SecureKeyboardEntryDecision) {
        SecureKeyboardEntryWarningPolicy.evaluate(
            previous: previous, snapshot: snapshot,
            dictationUsesModifierKey: modifier, dictationShortcutsEnabled: enabled,
            dictationKeyDisplay: dictationDisplay, meetingKeyDisplay: meetingDisplay,
            selfProcessID: 77, now: now, logInterval: 10
        )
    }

    func text(_ decision: SecureKeyboardEntryDecision) -> String? {
        if case .show(let value) = decision.notice { return value }
        return nil
    }

    runSuite("Registered meeting key warns while the default modifier dictation remains usable") {
        let registered = PhysicalShortcutMatcher.configuredBindings(dictation: modifierDictation, meeting: meeting)
        let display = SecureKeyboardEntryWarningPolicy.meetingKeyDisplay(in: registered)
        assertEqual(display, "⌥M")
        let (state, effect) = decide(meetingDisplay: display)
        assertNotNil(state.visibleNotice)
        assertTrue(text(effect)?.contains("⌥M") == true)
        assertTrue(text(effect)?.localizedCaseInsensitiveContains("meeting") == true)
        assertFalse(text(effect)?.localizedCaseInsensitiveContains("dictation") == true)
        assertEqual(effect.log?.isEnabled, true)
        assertTrue(SecureKeyboardEntryWarningPolicy.shouldPoll(
            dictationUsesModifierKey: true, dictationShortcutsEnabled: true, meetingShortcutBlocked: true
        ))
        assertTrue(SecureKeyboardEntryWarningPolicy.shouldStartPoll(
            isWatching: true, dictationUsesModifierKey: true,
            dictationShortcutsEnabled: true, meetingShortcutBlocked: true
        ))
    }

    runSuite("Disabling dictation still registers and warns for the nonmodifier meeting key") {
        let registered = PhysicalShortcutMatcher.configuredBindings(dictation: nil, meeting: meeting)
        assertEqual(registered.count, 1)
        assertEqual(registered.first?.action, .meeting)
        assertEqual(registered.first?.binding, meeting)
        let display = SecureKeyboardEntryWarningPolicy.meetingKeyDisplay(in: registered)
        let (_, effect) = decide(enabled: false, meetingDisplay: display)
        assertTrue(text(effect)?.contains("⌥M") == true)
        assertFalse(text(effect)?.localizedCaseInsensitiveContains("dictation") == true)
        assertTrue(SecureKeyboardEntryWarningPolicy.shouldPoll(
            dictationUsesModifierKey: false, dictationShortcutsEnabled: false, meetingShortcutBlocked: true
        ))
    }

    runSuite("Both affected keys are named while old dictation-only copy stays exact") {
        let (_, both) = decide(modifier: false, dictationDisplay: "F8")
        assertTrue(text(both)?.contains("F8") == true)
        assertTrue(text(both)?.contains("⌥M") == true)
        assertTrue(text(both)?.localizedCaseInsensitiveContains("dictation") == true)
        assertTrue(text(both)?.localizedCaseInsensitiveContains("meeting") == true)
        assertEqual(SecureKeyboardEntryWarningPolicy.noticeText(
            ownerDisplayName: "Synthetic owner", dictationKeyDisplay: "F8"
        ), "Shortcuts are blocked until Synthetic owner releases Secure Keyboard Entry. F8 dictation won't work.")
        assertEqual(SecureKeyboardEntryWarningPolicy.noticeText(
            ownerDisplayName: nil, dictationKeyDisplay: "  "
        ), "Shortcuts are blocked until Another app releases Secure Keyboard Entry. Dictation won't work.")
        let (_, legacy) = decide(modifier: false, dictationDisplay: "F8", meetingDisplay: nil)
        assertEqual(text(legacy), "Shortcuts are blocked until Synthetic owner releases Secure Keyboard Entry. F8 dictation won't work.")
    }

    runSuite("Actual registration excludes a colliding meeting and selection ignores modifier meetings") {
        let f8 = PhysicalShortcutBinding(action: .dictationHandsFree, binding: .init(keyCode: 100))
        let fnF8 = PhysicalDictationTriggerBinding(keyCode: 100, modifiers: 16)
        let colliding = PhysicalShortcutMatcher.configuredBindings(dictation: f8, meeting: fnF8)
        assertEqual(colliding.count, 1)
        assertEqual(colliding.first?.action, .dictationHandsFree)
        assertEqual(colliding.first?.binding, f8.binding)
        assertNil(SecureKeyboardEntryWarningPolicy.meetingKeyDisplay(in: colliding))
        let restored = PhysicalShortcutMatcher.configuredBindings(dictation: nil, meeting: fnF8)
        assertEqual(restored.first?.action, .meeting)
        assertEqual(restored.first?.binding, fnF8)
        assertNotNil(SecureKeyboardEntryWarningPolicy.meetingKeyDisplay(in: restored))
        let modifierMeeting = PhysicalShortcutMatcher.configuredBindings(
            dictation: nil, meeting: .init(keyCode: 61)
        )
        assertEqual(modifierMeeting.count, 1, "modifier meetings remain valid registrations")
        assertNil(SecureKeyboardEntryWarningPolicy.meetingKeyDisplay(in: modifierMeeting))
        assertNil(SecureKeyboardEntryWarningPolicy.meetingKeyDisplay(in: []))
        assertFalse(SecureKeyboardEntryWarningPolicy.shouldPoll(
            dictationUsesModifierKey: true, dictationShortcutsEnabled: true
        ), "old no-meeting default remains a dictation-only control")
    }

    runSuite("Rebinding an affected meeting rebuilds the notice without logging the same hold twice") {
        let (first, _) = decide()
        let (rebound, changed) = decide(previous: first, meetingDisplay: "⌃F9", now: 101)
        assertTrue(text(changed)?.contains("⌃F9") == true)
        assertFalse(text(changed)?.contains("⌥M") == true)
        assertNil(changed.log)
        let (_, repeated) = decide(previous: rebound, meetingDisplay: "⌃F9", now: 102)
        assertEqual(repeated.notice, .unchanged)
        assertNil(repeated.log)
        let (_, both) = decide(previous: rebound, modifier: false, dictationDisplay: "F8", meetingDisplay: "⌃F9", now: 103)
        assertTrue(text(both)?.contains("F8") == true)
        assertTrue(text(both)?.contains("⌃F9") == true)
        assertNil(both.log)
    }

    runSuite("Meeting warnings preserve self-owner rejection release owner changes and log throttling") {
        let selfHeld = SecureEventInputSnapshot(isEnabled: true, ownerProcessID: 77, ownerDisplayName: "Synthetic self")
        let (_, own) = decide(snapshot: selfHeld)
        assertEqual(own.notice, .unchanged)
        assertNil(own.log)
        let (held, _) = decide()
        let (released, off) = decide(previous: held, snapshot: .inactive, now: 101)
        assertEqual(off.notice, .clear)
        assertNil(released.visibleNotice)
        assertEqual(off.log?.isEnabled, false)
        let other = SecureEventInputSnapshot(isEnabled: true, ownerProcessID: 401, ownerDisplayName: "Other synthetic owner")
        let (_, changed) = decide(previous: held, snapshot: other, now: 101)
        assertTrue(text(changed)?.contains("Other synthetic owner") == true)
        assertEqual(changed.log?.ownerProcessID, 401)
        // Removing affected bindings does not claim the foreign hold ended.
        // Re-adding within the injected log interval should warn, not re-log.
        let (quiet, _) = decide(previous: held, enabled: false, meetingDisplay: nil, now: 101)
        let (_, again) = decide(previous: quiet, now: 102)
        assertNotNil(text(again))
        assertNil(again.log)
    }

    runSuite("No affected bindings clear quietly and a stopped watch cannot restart for meetings") {
        let (held, _) = decide()
        let (quiet, cleared) = decide(previous: held, meetingDisplay: nil)
        assertEqual(cleared.notice, .clear)
        assertNil(cleared.log)
        assertNil(quiet.visibleNotice)
        assertFalse(SecureKeyboardEntryWarningPolicy.shouldStartPoll(
            isWatching: false, dictationUsesModifierKey: true,
            dictationShortcutsEnabled: false, meetingShortcutBlocked: true
        ))
        assertFalse(SecureKeyboardEntryWarningPolicy.shouldAcceptWatchCallback(isWatching: false))
        assertFalse(SecureKeyboardEntryWarningPolicy.shouldPoll(
            dictationUsesModifierKey: true, dictationShortcutsEnabled: false, meetingShortcutBlocked: false
        ))
    }

    runSuite("Injected monitor probes for meetings caches owner refreshes and resets without live adapters") {
        let source = MeetingSecureInputSource()
        let namer = MeetingSecureInputNamer()
        let monitor = SecureKeyboardEntryMonitor(source: source, namer: namer, selfProcessID: 77)
        var notices: [String?] = []
        var logs: [SecureKeyboardEntryLogEvent] = []
        monitor.onNoticeChange = { notices.append($0) }
        monitor.onLog = { logs.append($0) }
        monitor.check(dictationUsesModifierKey: true, dictationShortcutsEnabled: false,
                      dictationKeyDisplay: "Right ⌥", meetingKeyDisplay: "⌥M", now: 100)
        assertTrue(monitor.visibleNotice?.contains("⌥M") == true)
        assertEqual(source.ownerReads, 1)
        assertEqual(namer.applicationReads, 1)
        assertEqual(logs.count, 1)
        monitor.check(dictationUsesModifierKey: true, dictationShortcutsEnabled: false,
                      dictationKeyDisplay: "Right ⌥", meetingKeyDisplay: "⌃F9", now: 101)
        assertEqual(source.ownerReads, 1, "rebinding does not redo cached owner lookup")
        assertEqual(namer.applicationReads, 1)
        assertEqual(logs.count, 1)
        assertTrue(monitor.visibleNotice?.contains("⌃F9") == true)
        source.pid = 401
        monitor.check(dictationUsesModifierKey: true, dictationShortcutsEnabled: false,
                      dictationKeyDisplay: "Right ⌥", meetingKeyDisplay: "⌃F9", now: 102, refreshOwner: true)
        assertEqual(source.ownerReads, 2)
        assertEqual(logs.last?.ownerProcessID, 401)
        monitor.reset()
        assertNil(monitor.visibleNotice)
        assertEqual(notices.last, .some(nil))
        let priorReads = source.enabledReads
        monitor.check(dictationUsesModifierKey: true, dictationShortcutsEnabled: false,
                      dictationKeyDisplay: "Right ⌥", meetingKeyDisplay: nil, now: 103)
        assertEqual(source.enabledReads, priorReads, "no affected bindings must not query the native-source seam")
        assertEqual(logs.count, 2, "reset and quiet checks must not invent a release log")
    }
}

private final class MeetingSecureInputSource: SecureEventInputReading {
    var pid: Int32? = 400
    var enabledReads = 0
    var ownerReads = 0
    func isEnabled() -> Bool { enabledReads += 1; return true }
    func ownerProcessID() -> Int32? { ownerReads += 1; return pid }
}

private final class MeetingSecureInputNamer: SecureEventInputProcessNaming {
    var applicationReads = 0
    func runningApplicationDisplayName(forProcessID pid: Int32) -> String? {
        applicationReads += 1
        return "Synthetic owner \(pid)"
    }
    func processName(forProcessID pid: Int32) -> String? { nil }
}
