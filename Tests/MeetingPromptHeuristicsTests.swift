// MeetingPromptHeuristicsTests.swift
// Tests for native-app meeting reminder heuristics and snooze policy.

import Foundation

func testMeetingPromptHeuristics() {
    runSuite("MeetingPromptHeuristics.runtimePresentation — frontmost apps get the stronger reminder") {
        let now = Date(timeIntervalSince1970: 1_000)
        let prompt = MeetingPromptHeuristics.runtimePresentation(
            providerName: "Zoom",
            isFrontmost: true,
            lastActiveAt: nil,
            now: now
        )

        assertEqual(prompt?.title, "Zoom is active", "frontmost reminder title should be direct")
        assertEqual(prompt?.score, 4, "frontmost apps should outrank stale native reminders")
    }

    runSuite("MeetingPromptHeuristics.runtimePresentation — recent app launches still get a reminder") {
        let now = Date(timeIntervalSince1970: 1_000)
        let prompt = MeetingPromptHeuristics.runtimePresentation(
            providerName: "Teams",
            isFrontmost: false,
            lastActiveAt: now.addingTimeInterval(-30),
            now: now
        )

        assertEqual(prompt?.title, "Teams just opened", "recent launches should get the softer reminder")
        assertEqual(prompt?.score, 3, "recent launches should score below a frontmost active app")
    }

    runSuite("MeetingPromptHeuristics.runtimePresentation — stale native activity expires") {
        let now = Date(timeIntervalSince1970: 1_000)
        let prompt = MeetingPromptHeuristics.runtimePresentation(
            providerName: "FaceTime",
            isFrontmost: false,
            lastActiveAt: now.addingTimeInterval(-(MeetingPromptHeuristics.runtimeActivityFreshness + 1)),
            now: now
        )

        assertNil(prompt, "stale app activity should not keep prompting forever")
    }

    runSuite("MeetingPromptProvider.supportsRuntimeOnlyPrompt — Teams must rely on stronger evidence") {
        assertFalse(
            MeetingPromptProvider.teams.supportsRuntimeOnlyPrompt,
            "Teams should not prompt just because the app is open"
        )
        assertTrue(
            MeetingPromptProvider.zoom.supportsRuntimeOnlyPrompt,
            "Zoom should keep the existing runtime-only prompt path"
        )
    }

    runSuite("MeetingPromptProvider.provider(forMeetingHost:) accepts exact provider hosts and subdomains") {
        assertEqual(
            MeetingPromptProvider.provider(forMeetingHost: "zoom.us"),
            .zoom,
            "Zoom's root host should be recognized"
        )
        assertEqual(
            MeetingPromptProvider.provider(forMeetingHost: "us02web.zoom.us"),
            .zoom,
            "Zoom subdomains should be recognized"
        )
        assertEqual(
            MeetingPromptProvider.provider(forMeetingHost: "meet.google.com"),
            .googleMeet,
            "Google Meet's canonical host should be recognized"
        )
        assertEqual(
            MeetingPromptProvider.provider(forMeetingHost: "company.webex.com."),
            .webex,
            "Provider subdomains with a trailing dot should be recognized"
        )
    }

    runSuite("MeetingPromptProvider.provider(forMeetingHost:) rejects lookalike domains") {
        assertNil(
            MeetingPromptProvider.provider(forMeetingHost: "zoom.us.evil.example"),
            "Zoom lookalike hosts should not trigger a meeting prompt"
        )
        assertNil(
            MeetingPromptProvider.provider(forMeetingHost: "evilzoom.us"),
            "Hosts that only contain a provider suffix should not match"
        )
        assertNil(
            MeetingPromptProvider.provider(forMeetingHost: "teams.microsoft.com.example.net"),
            "Teams lookalike hosts should not trigger a meeting prompt"
        )
        assertNil(
            MeetingPromptProvider.provider(forMeetingHost: "webex.com.attacker.test"),
            "Webex lookalike hosts should not trigger a meeting prompt"
        )
    }

    runSuite("MeetingPromptHeuristics.snoozeInterval — runtime reminders use a short follow-up interval") {
        let interval = MeetingPromptHeuristics.snoozeInterval(
            for: .runtimeApp,
            explicit: nil,
            defaultInterval: 30 * 60
        )

        assertEqual(
            interval,
            MeetingPromptHeuristics.runtimeReminderSnoozeInterval,
            "runtime reminders should reappear sooner than calendar prompts"
        )
    }

    runSuite("MeetingPromptHeuristics.snoozeInterval — calendar prompts keep the longer default") {
        let interval = MeetingPromptHeuristics.snoozeInterval(
            for: .calendarEvent,
            explicit: nil,
            defaultInterval: 30 * 60
        )

        assertEqual(interval, 30 * 60, "calendar prompts should preserve the longer snooze")
    }

    runSuite("MeetingPromptHeuristics.remindSoonBackoffKind — short reminders stay distinct from dismissal") {
        assertEqual(
            MeetingPromptHeuristics.remindSoonInterval,
            2 * 60,
            "remind-soon prompts should come back quickly"
        )
        assertEqual(
            MeetingPromptHeuristics.remindSoonBackoffKind(for: .calendarEvent),
            .calendarShortReminder,
            "calendar remind-soon should not look like a full dismissal"
        )
        assertEqual(
            MeetingPromptHeuristics.remindSoonBackoffKind(for: .runtimeApp),
            .runtimeShortReminder,
            "runtime remind-soon should not look like a full dismissal"
        )
    }

    runSuite("MeetingPromptHeuristics.dismissMinimumInterval — Teams get a stickier dismissal") {
        let defaultInterval: TimeInterval = 30 * 60
        assertEqual(
            MeetingPromptHeuristics.dismissMinimumInterval(for: .zoom, default: defaultInterval),
            defaultInterval,
            "Zoom should keep the default dismissal interval"
        )
        assertEqual(
            MeetingPromptHeuristics.dismissMinimumInterval(for: .teams, default: defaultInterval),
            MeetingPromptHeuristics.teamsDismissMinimumInterval,
            "Teams should stay quiet longer after a dismissal"
        )
        assertEqual(
            MeetingPromptHeuristics.dismissMinimumInterval(
                for: .zoom,
                default: MeetingPromptHeuristics.defaultRuntimeDismissFallbackInterval
            ),
            MeetingPromptHeuristics.defaultRuntimeDismissFallbackInterval,
            "Zoom should keep the standard runtime fallback"
        )
        assertEqual(
            MeetingPromptHeuristics.dismissMinimumInterval(
                for: .teams,
                default: MeetingPromptHeuristics.defaultRuntimeDismissFallbackInterval
            ),
            MeetingPromptHeuristics.teamsDismissMinimumInterval,
            "Teams should fall back to the longer dismissal interval"
        )
    }

    runSuite("MeetingPromptHeuristics.reason — calendar prompts distinguish runtime-backed prompts") {
        assertEqual(
            MeetingPromptHeuristics.reason(for: .calendarEvent, hasRuntimeContext: false),
            .calendarNearby,
            "calendar-only prompts should record the nearby-calendar reason"
        )
        assertEqual(
            MeetingPromptHeuristics.reason(for: .calendarEvent, hasRuntimeContext: true),
            .calendarPlusRuntimeMatch,
            "calendar prompts with app evidence should record the combined reason"
        )
        assertEqual(
            MeetingPromptHeuristics.reason(for: .runtimeApp, hasRuntimeContext: false),
            .runtimeOnly,
            "runtime prompts should keep the runtime-only reason"
        )
    }

    runSuite("MeetingPromptWindowPolicy.shouldOfferCalendarPrompt — only prompts in the one-minute lead window") {
        assertFalse(
            MeetingPromptWindowPolicy.shouldOfferCalendarPrompt(
                startsIn: MeetingPromptHeuristics.calendarReminderLeadTime + 1
            ),
            "calendar prompts should not fire earlier than one minute before the meeting"
        )
        assertTrue(
            MeetingPromptWindowPolicy.shouldOfferCalendarPrompt(
                startsIn: MeetingPromptHeuristics.calendarReminderLeadTime
            ),
            "calendar prompts should fire at one minute before the meeting"
        )
    }

    runSuite("MeetingPromptWindowPolicy.shouldOfferCalendarPrompt — keeps a short grace period after start") {
        assertTrue(
            MeetingPromptWindowPolicy.shouldOfferCalendarPrompt(
                startsIn: -MeetingPromptHeuristics.calendarReminderPostStartGrace
            ),
            "calendar prompts should still be eligible during the short after-start grace period"
        )
        assertFalse(
            MeetingPromptWindowPolicy.shouldOfferCalendarPrompt(
                startsIn: -(MeetingPromptHeuristics.calendarReminderPostStartGrace + 1)
            ),
            "calendar prompts should expire after the post-start grace period"
        )
    }
}
