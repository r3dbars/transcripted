// SecureKeyboardEntryWarningPolicyTests.swift
// Promises for the Secure Keyboard Entry warning: F8-style dictation keys go
// silent while another app holds secure input, so the menu bar must tell the
// user once per owner and clear when it releases. Right Option still works,
// so a modifier binding must stay quiet. IOKit/Carbon are faked; this does
// not prove a live CGEventTap under Secure Keyboard Entry.

import Foundation

func testSecureKeyboardEntryWarningPolicy() {
    let obsidian = SecureEventInputSnapshot(
        isEnabled: true,
        ownerProcessID: 4242,
        ownerDisplayName: "Obsidian"
    )
    let terminal = SecureEventInputSnapshot(
        isEnabled: true,
        ownerProcessID: 5252,
        ownerDisplayName: "Terminal"
    )
    let unknownOwner = SecureEventInputSnapshot(
        isEnabled: true,
        ownerProcessID: nil,
        ownerDisplayName: nil
    )

    func decide(
        previous: SecureEventInputWatchState = .idle,
        snapshot: SecureEventInputSnapshot,
        modifier: Bool = false,
        shortcutsEnabled: Bool = true,
        key: String = "F8",
        selfPID: Int32 = 1,
        now: TimeInterval = 100,
        logInterval: TimeInterval = 2
    ) -> (SecureEventInputWatchState, SecureKeyboardEntryDecision) {
        SecureKeyboardEntryWarningPolicy.evaluate(
            previous: previous,
            snapshot: snapshot,
            dictationUsesModifierKey: modifier,
            dictationShortcutsEnabled: shortcutsEnabled,
            dictationKeyDisplay: key,
            selfProcessID: selfPID,
            now: now,
            logInterval: logInterval
        )
    }

    func shownText(_ decision: SecureKeyboardEntryDecision) -> String? {
        if case .show(let text) = decision.notice { return text }
        return nil
    }

    // MARK: - Off → on with an owner

    runSuite("Secure Keyboard Entry turning on with an owner shows one notice naming that app and the dictation key") {
        let (next, decision) = decide(snapshot: obsidian)
        let text = shownText(decision)
        assertNotNil(text, "off → on must produce a notice")
        assertTrue(
            text?.contains("Obsidian") == true,
            "the notice must name the app holding Secure Keyboard Entry"
        )
        assertTrue(
            text?.contains("Secure Keyboard Entry") == true,
            "the notice must say Secure Keyboard Entry so the user can search for it"
        )
        assertTrue(
            text?.contains("F8") == true,
            "the notice must name the bound dictation key"
        )
        assertTrue(
            text?.contains("Right Option") == true,
            "the notice must mention that Right Option still works"
        )
        assertEqual(next.visibleNotice, text, "the watch must keep the notice until secure input turns off")
        assertEqual(decision.log?.isEnabled, true, "turning on must log locally")
        assertEqual(decision.log?.ownerDisplayName, "Obsidian", "the log must carry the owner app")
        assertEqual(decision.log?.ownerProcessID, 4242, "the log must carry the owner pid")
    }

    runSuite("Secure Keyboard Entry with no resolved owner still warns, as Another app") {
        let (_, decision) = decide(snapshot: unknownOwner)
        let text = shownText(decision)
        assertTrue(
            text?.contains(SecureKeyboardEntryWarningPolicy.unknownOwnerDisplayName) == true,
            "a missing owner name must still produce a usable notice"
        )
        assertEqual(decision.log?.isEnabled, true, "an unknown owner turning on must still log")
        assertNil(decision.log?.ownerProcessID, "an unknown owner log has no pid")
    }

    // MARK: - Same owner: only one notice

    runSuite("The same owner holding Secure Keyboard Entry does not get a second notice") {
        let (shown, first) = decide(snapshot: obsidian, now: 100)
        guard case .show = first.notice else {
            assertTrue(false, "setup: first observation must show")
            return
        }
        let (againState, again) = decide(previous: shown, snapshot: obsidian, now: 102.5)
        assertEqual(again.notice, .unchanged, "polling the same owner must not show again")
        assertNil(again.log, "polling the same owner must not log again")
        assertEqual(againState.visibleNotice, shown.visibleNotice, "the first notice stays up")
    }

    runSuite("A later poll of the same owner after the log interval still does not show again") {
        let (shown, _) = decide(snapshot: obsidian, now: 10)
        let (_, again) = decide(previous: shown, snapshot: obsidian, now: 30)
        assertEqual(again.notice, .unchanged, "time passing is not a new owner")
        assertNil(again.log, "the log is rate-limited to owner or on/off changes")
    }

    // MARK: - Owner change

    runSuite("A new owner while Secure Keyboard Entry stays on replaces the notice once") {
        let (shown, _) = decide(snapshot: obsidian, now: 100)
        let (next, decision) = decide(previous: shown, snapshot: terminal, now: 103)
        let text = shownText(decision)
        assertTrue(text?.contains("Terminal") == true, "the new notice must name the new owner")
        assertTrue(text?.contains("Obsidian") != true, "the old owner must leave the notice")
        assertEqual(next.visibleNotice, text, "the watch shows the new owner's notice")
        assertEqual(decision.log?.isEnabled, true, "an owner change logs as still on")
        assertEqual(decision.log?.ownerDisplayName, "Terminal", "the log follows the new owner")
        assertEqual(decision.log?.ownerProcessID, 5252, "the log follows the new pid")
    }

    // MARK: - On → off

    runSuite("Secure Keyboard Entry turning off clears the notice and logs off") {
        let (shown, _) = decide(snapshot: obsidian, now: 100)
        let (next, decision) = decide(previous: shown, snapshot: .inactive, now: 104)
        assertEqual(decision.notice, .clear, "release must take the notice down")
        assertNil(next.visibleNotice, "nothing stays on screen after release")
        assertEqual(decision.log?.isEnabled, false, "turning off must log locally")
        assertEqual(decision.log?.ownerDisplayName, "Obsidian", "the off log still names who released")
        assertEqual(decision.log?.ownerProcessID, 4242, "the off log still carries the pid")
    }

    runSuite("Already-off observations stay quiet") {
        let (_, decision) = decide(snapshot: .inactive)
        assertEqual(decision.notice, .unchanged, "off → off must not clear a notice that is not up")
        assertNil(decision.log, "off → off must not log")
    }

    runSuite("Off then on again with the same owner is a new notice") {
        let (shown, _) = decide(snapshot: obsidian, now: 100)
        let (cleared, _) = decide(previous: shown, snapshot: .inactive, now: 110)
        let (_, again) = decide(previous: cleared, snapshot: obsidian, now: 120)
        assertNotNil(shownText(again), "a fresh hold after release must warn again")
        assertEqual(again.log?.isEnabled, true, "a fresh hold logs on")
    }

    // MARK: - Modifier bindings stay quiet

    runSuite("A modifier dictation key never shows a Secure Keyboard Entry notice") {
        let (_, decision) = decide(snapshot: obsidian, modifier: true)
        assertEqual(decision.notice, .unchanged, "Right Option still works, so there is nothing to warn about")
        assertNil(decision.log, "modifier bindings do not log Secure Keyboard Entry")
        assertFalse(
            SecureKeyboardEntryWarningPolicy.shouldPoll(
                dictationUsesModifierKey: true,
                dictationShortcutsEnabled: true
            ),
            "modifier bindings must not poll"
        )
    }

    runSuite("Switching dictation to a modifier key clears a visible notice without a false off log") {
        let (shown, _) = decide(snapshot: obsidian, now: 100)
        let (next, decision) = decide(
            previous: shown,
            snapshot: obsidian,
            modifier: true,
            now: 105
        )
        assertEqual(decision.notice, .clear, "Right Option no longer needs the warning")
        assertNil(next.visibleNotice, "the notice comes down with the binding change")
        assertNil(decision.log, "the other app is still holding secure input; do not log off")
    }

    runSuite("Dictation shortcuts turned off clear the notice") {
        let (shown, _) = decide(snapshot: obsidian, now: 100)
        let (next, decision) = decide(
            previous: shown,
            snapshot: obsidian,
            shortcutsEnabled: false,
            now: 105
        )
        assertEqual(decision.notice, .clear, "no dictation key means no warning")
        assertNil(next.visibleNotice, "the notice comes down when shortcuts are off")
    }

    runSuite("Our own process holding Secure Keyboard Entry is not treated as another app") {
        let selfHeld = SecureEventInputSnapshot(
            isEnabled: true,
            ownerProcessID: 77,
            ownerDisplayName: "Transcripted"
        )
        let (_, decision) = decide(snapshot: selfHeld, selfPID: 77)
        assertEqual(decision.notice, .unchanged, "do not warn that we are blocking ourselves")
        assertNil(decision.log, "self-held secure input is not a foreign owner")
    }

    // MARK: - Polling window

    runSuite("Non-modifier dictation keys poll every 2–3 seconds") {
        assertTrue(
            SecureKeyboardEntryWarningPolicy.shouldPoll(
                dictationUsesModifierKey: false,
                dictationShortcutsEnabled: true
            ),
            "F8-style bindings must poll because the tap cannot see the F8 press"
        )
        let ns = SecureKeyboardEntryWarningPolicy.pollIntervalNanoseconds
        assertTrue(ns >= 2_000_000_000, "poll at least every 2 s")
        assertTrue(ns <= 3_000_000_000, "poll no slower than every 3 s")
    }

    runSuite("Disabled dictation shortcuts do not poll") {
        assertFalse(
            SecureKeyboardEntryWarningPolicy.shouldPoll(
                dictationUsesModifierKey: false,
                dictationShortcutsEnabled: false
            ),
            "no dictation key means no poll"
        )
    }

    // MARK: - PID → name fallback

    runSuite("The running-app display name wins over proc_name") {
        assertEqual(
            SecureKeyboardEntryWarningPolicy.resolveOwnerDisplayName(
                processID: 9,
                runningApplicationName: "Obsidian",
                processName: "ObsidianHelper"
            ),
            "Obsidian",
            "NSRunningApplication's name is what the user sees"
        )
    }

    runSuite("An empty running-app name falls back to proc_name") {
        assertEqual(
            SecureKeyboardEntryWarningPolicy.resolveOwnerDisplayName(
                processID: 9,
                runningApplicationName: "  ",
                processName: "obsidian"
            ),
            "obsidian",
            "proc_name is the fallback when Launch Services has no display name"
        )
        assertEqual(
            SecureKeyboardEntryWarningPolicy.resolveOwnerDisplayName(
                processID: 9,
                runningApplicationName: nil,
                processName: "obsidian"
            ),
            "obsidian",
            "a missing running-app name also falls back to proc_name"
        )
    }

    runSuite("When both name lookups fail the owner stays unknown") {
        assertNil(
            SecureKeyboardEntryWarningPolicy.resolveOwnerDisplayName(
                processID: 9,
                runningApplicationName: nil,
                processName: nil
            ),
            "no invented name when both lookups miss"
        )
        assertNil(
            SecureKeyboardEntryWarningPolicy.resolveOwnerDisplayName(
                processID: 9,
                runningApplicationName: "",
                processName: "  "
            ),
            "whitespace is not a name"
        )
    }

    // MARK: - IOConsoleUsers parser

    runSuite("The on-console IOConsoleUsers session supplies kCGSSessionSecureInputPID") {
        let users: [[String: Any]] = [
            [
                SecureEventInputRegistryKeys.onConsole: false,
                SecureEventInputRegistryKeys.secureInputPID: 111,
            ],
            [
                SecureEventInputRegistryKeys.onConsole: true,
                SecureEventInputRegistryKeys.secureInputPID: 4242,
            ],
        ]
        assertEqual(
            SecureKeyboardEntryWarningPolicy.ownerProcessID(fromConsoleUsers: users),
            4242,
            "the current console session's secure-input pid is the owner"
        )
    }

    runSuite("A console user without an on-console flag still counts") {
        let users: [[String: Any]] = [
            [SecureEventInputRegistryKeys.secureInputPID: 88 as Int32],
        ]
        assertEqual(
            SecureKeyboardEntryWarningPolicy.ownerProcessID(fromConsoleUsers: users),
            88,
            "ioreg dumps sometimes omit kCGSSessionOnConsoleKey"
        )
    }

    runSuite("PID 0 and empty console-user lists are not an owner") {
        assertNil(
            SecureKeyboardEntryWarningPolicy.ownerProcessID(fromConsoleUsers: []),
            "no users means no owner"
        )
        let zero: [[String: Any]] = [
            [
                SecureEventInputRegistryKeys.onConsole: true,
                SecureEventInputRegistryKeys.secureInputPID: 0,
            ],
        ]
        assertNil(
            SecureKeyboardEntryWarningPolicy.ownerProcessID(fromConsoleUsers: zero),
            "pid 0 is not a process holding secure input"
        )
        let offConsole: [[String: Any]] = [
            [
                SecureEventInputRegistryKeys.onConsole: false,
                SecureEventInputRegistryKeys.secureInputPID: 99,
            ],
        ]
        assertNil(
            SecureKeyboardEntryWarningPolicy.ownerProcessID(fromConsoleUsers: offConsole),
            "another session's pid is not the current console owner"
        )
    }

    // MARK: - Local log only

    runSuite("secure_input_state_changed stays on the device: no PostHog, no Sentry") {
        let plan = ObservabilityEventCapturePlan.make(
            level: .warning,
            engine: "capture",
            event: "secure_input_state_changed",
            message: "Secure Keyboard Entry on",
            context: [
                "enabled": "on",
                "pid": "4242",
                "owner": "Obsidian",
            ],
            engineState: nil,
            infoDictionary: nil,
            timestamp: "2026-10-19T00:00:00Z",
            appVersion: "test",
            osVersion: "test"
        )
        assertNil(plan.forwarded, "this event must not be in AnalyticsEventForwardingPolicy")
        assertNil(plan.sentryPolicy, "a warning must not become a Sentry event")
        assertFalse(plan.forwardsToSentry, "nothing leaves for crash reporting")
        assertEqual(plan.localEntry.event, "secure_input_state_changed", "the local log keeps the event name")
        assertEqual(plan.localEntry.context?["enabled"], "on", "enabled survives local sanitizer")
        assertEqual(plan.localEntry.context?["pid"], "4242", "pid survives local sanitizer")
        assertEqual(
            plan.localEntry.context?["owner"],
            "Obsidian",
            "owner is not a dropped key fragment, so the app name stays in the local log"
        )
    }

    runSuite("Notice copy names the bound key, not a hardcoded F8") {
        let text = SecureKeyboardEntryWarningPolicy.noticeText(
            ownerDisplayName: "Obsidian",
            dictationKeyDisplay: "F7"
        )
        assertTrue(text.contains("F7"), "a saved F7 binding must appear in the notice")
        assertFalse(text.contains("F8"), "do not claim F8 when another key is bound")
    }
}
