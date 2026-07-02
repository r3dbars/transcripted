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

    runSuite("MeetingPromptHeuristics.runtimePresentation — ignores future last-active timestamps") {
        let now = Date(timeIntervalSince1970: 1_000)
        let prompt = MeetingPromptHeuristics.runtimePresentation(
            providerName: "Zoom",
            isFrontmost: false,
            lastActiveAt: now.addingTimeInterval(10),
            now: now
        )

        assertNil(prompt, "clock-skewed future activity should not create a prompt")
    }

    runSuite("MeetingPromptProvider.supportsRuntimeOnlyPrompt — app-open-only prompts require strong evidence") {
        assertFalse(
            MeetingPromptProvider.teams.supportsRuntimeOnlyPrompt,
            "Teams should not prompt just because the app is open"
        )
        assertFalse(
            MeetingPromptProvider.zoom.supportsRuntimeOnlyPrompt,
            "Zoom should not prompt just because the app is open or frontmost"
        )
        assertTrue(
            MeetingPromptProvider.webex.supportsRuntimeOnlyPrompt,
            "Webex should keep the native runtime-only prompt path"
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

    runSuite("MeetingPromptHeuristics.snoozeInterval — explicit operator interval wins") {
        let runtime = MeetingPromptHeuristics.snoozeInterval(
            for: .runtimeApp,
            explicit: 5 * 60,
            defaultInterval: 30 * 60
        )
        let calendar = MeetingPromptHeuristics.snoozeInterval(
            for: .calendarEvent,
            explicit: 10 * 60,
            defaultInterval: 30 * 60
        )

        assertEqual(runtime, 5 * 60, "runtime prompts should honor an explicit reminder interval")
        assertEqual(calendar, 10 * 60, "calendar prompts should honor an explicit reminder interval")
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

    runSuite("MeetingPromptHeuristics.backoffKind — keeps runtime resume and Teams dismissal buckets distinct") {
        assertEqual(
            MeetingPromptHeuristics.backoffKind(for: .zoom, source: .calendarEvent),
            .calendarDefault,
            "normal calendar dismissals should use the calendar default bucket"
        )
        assertEqual(
            MeetingPromptHeuristics.backoffKind(for: .teams, source: .calendarEvent),
            .calendarTeamsExtended,
            "Teams calendar dismissals should use the extended bucket"
        )
        assertEqual(
            MeetingPromptHeuristics.backoffKind(for: .zoom, source: .runtimeApp, hasResumeDate: true),
            .runtimeUntilNextCalendar,
            "runtime prompts with a known next calendar window should be grouped separately"
        )
        assertEqual(
            MeetingPromptHeuristics.backoffKind(for: .teams, source: .runtimeApp),
            .runtimeTeamsExtended,
            "Teams runtime dismissals should stay sticky"
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
                startsIn: MeetingPromptHeuristics.calendarReminderLeadTime + 1,
                endsIn: 30 * 60
            ),
            "calendar prompts should not fire earlier than one minute before the meeting"
        )
        assertTrue(
            MeetingPromptWindowPolicy.shouldOfferCalendarPrompt(
                startsIn: MeetingPromptHeuristics.calendarReminderLeadTime,
                endsIn: 30 * 60
            ),
            "calendar prompts should fire at one minute before the meeting"
        )
    }

    runSuite("MeetingPromptWindowPolicy.shouldOfferCalendarPrompt — keeps a short grace period after start") {
        assertTrue(
            MeetingPromptWindowPolicy.shouldOfferCalendarPrompt(
                startsIn: -MeetingPromptHeuristics.calendarReminderPostStartGrace,
                endsIn: 25 * 60
            ),
            "calendar prompts should still be eligible during the short after-start grace period"
        )
        assertFalse(
            MeetingPromptWindowPolicy.shouldOfferCalendarPrompt(
                startsIn: -(MeetingPromptHeuristics.calendarReminderPostStartGrace + 1),
                endsIn: 25 * 60
            ),
            "calendar prompts should expire after the post-start grace period"
        )
    }

    runSuite("MeetingPromptWindowPolicy.shouldOfferCalendarPrompt — rejects ended calendar events") {
        assertFalse(
            MeetingPromptWindowPolicy.shouldOfferCalendarPrompt(
                startsIn: -3 * 60,
                endsIn: -30
            ),
            "calendar prompts should not fire after a Zoom calendar event has already ended"
        )
        assertFalse(
            MeetingPromptWindowPolicy.shouldOfferCalendarPrompt(
                startsIn: -3 * 60,
                endsIn: 0
            ),
            "calendar prompts should stop at the event end boundary"
        )
        assertTrue(
            MeetingPromptWindowPolicy.shouldOfferCalendarPrompt(
                startsIn: -3 * 60,
                endsIn: 20 * 60
            ),
            "in-progress calendar-backed meetings should still be eligible during the post-start grace period"
        )
    }

    runSuite("MeetingPromptProvider.isBrowserBundleID — matches browser families by prefix, including helpers") {
        assertTrue(
            MeetingPromptProvider.isBrowserBundleID("com.google.Chrome"),
            "the main Chrome bundle should be recognized"
        )
        assertTrue(
            MeetingPromptProvider.isBrowserBundleID("com.google.Chrome.helper"),
            "Chrome's helper process (the one that actually holds the mic in a call) must be recognized"
        )
        assertTrue(
            MeetingPromptProvider.isBrowserBundleID("com.apple.WebKit.GPU"),
            "Safari/WKWebView audio runs in a WebKit service process and must be recognized"
        )
        assertTrue(
            MeetingPromptProvider.isBrowserBundleID("com.apple.Safari"),
            "the main Safari bundle should be recognized"
        )
        assertFalse(
            MeetingPromptProvider.isBrowserBundleID("com.apple.QuickTimePlayerX"),
            "non-browser apps should not be treated as a browser call"
        )
        assertFalse(
            MeetingPromptProvider.isBrowserBundleID("com.google.ChromeEvil"),
            "a bundle id that only shares a prefix segment should not match the family"
        )
    }

    runSuite("MeetingPromptProvider.micInputProvider — attributes mic-holding processes to a provider") {
        assertEqual(
            MeetingPromptProvider.micInputProvider(forBundleID: "us.zoom.xos"),
            .zoom,
            "the native Zoom bundle holding the mic should attribute to Zoom"
        )
        assertEqual(
            MeetingPromptProvider.micInputProvider(forBundleID: "us.zoom.xos.helper"),
            .zoom,
            "a native conferencing helper process should still attribute to its parent app"
        )
        assertEqual(
            MeetingPromptProvider.micInputProvider(forBundleID: "com.microsoft.teams2"),
            .teams,
            "the native Teams bundle holding the mic should attribute to Teams"
        )
        assertEqual(
            MeetingPromptProvider.micInputProvider(forBundleID: "com.google.Chrome.helper"),
            .googleMeet,
            "a browser holding the mic maps to the representative browser-call provider — this closes the Meet gap"
        )
        assertEqual(
            MeetingPromptProvider.micInputProvider(forBundleID: "com.apple.WebKit.GPU"),
            .googleMeet,
            "a Safari/WebKit service holding the mic maps to the browser-call provider"
        )
        assertNil(
            MeetingPromptProvider.micInputProvider(forBundleID: "com.apple.QuickTimePlayerX"),
            "an unrecognized mic user (QuickTime, Voice Memos, …) should produce no provider and no prompt"
        )
        assertNil(
            MeetingPromptProvider.micInputProvider(forBundleID: "com.justinbetker.draft"),
            "our own bundle is not a conferencing app or browser, so attribution alone yields nil"
        )
    }

    runSuite("MeetingPromptHeuristics.micInputPresentation — mic-in-use outranks a frontmost browser") {
        let presentation = MeetingPromptHeuristics.micInputPresentation(title: "Zoom call detected")
        assertEqual(presentation.title, "Zoom call detected", "mic-input title should pass through unchanged")
        assertEqual(presentation.score, 5, "mic-in-use should score above the frontmost-browser runtime score of 4")
        assertTrue(
            presentation.score > MeetingPromptHeuristics.runtimePresentation(
                providerName: "Zoom",
                isFrontmost: true,
                lastActiveAt: nil,
                now: Date(timeIntervalSince1970: 1_000)
            )!.score,
            "a mic-in-use candidate should outrank a frontmost-app candidate"
        )
    }

    runSuite("MeetingPromptProvider.cameraCallProvider — attributes a camera-on signal via the frontmost call app") {
        assertEqual(
            MeetingPromptProvider.cameraCallProvider(forFrontmostBundleID: "com.google.Chrome"),
            .googleMeet,
            "a frontmost browser with the camera on maps to the generic browser call"
        )
        assertEqual(
            MeetingPromptProvider.cameraCallProvider(forFrontmostBundleID: "us.zoom.xos"),
            .zoom,
            "a frontmost native conferencing app maps to its own provider"
        )
        assertNil(
            MeetingPromptProvider.cameraCallProvider(forFrontmostBundleID: "com.apple.PhotoBooth"),
            "the camera on while Photo Booth is frontmost is a selfie, not a call — no provider, no prompt"
        )
        assertNil(
            MeetingPromptProvider.cameraCallProvider(forFrontmostBundleID: nil),
            "the camera on with no frontmost app cannot be attributed, so it stays quiet"
        )
    }

    runSuite("MeetingPromptReason.isAdHocCallSignal — mic, camera, and speaker are ad-hoc signals; calendar/runtime are not") {
        assertTrue(MeetingPromptReason.micInput.isAdHocCallSignal, "mic input is an ad-hoc call signal")
        assertTrue(MeetingPromptReason.cameraInput.isAdHocCallSignal, "camera input is an ad-hoc call signal")
        assertTrue(MeetingPromptReason.audioOutput.isAdHocCallSignal, "native-app audio output is an ad-hoc call signal")
        assertFalse(MeetingPromptReason.runtimeOnly.isAdHocCallSignal, "runtime-app is not an ad-hoc mic/camera signal")
        assertFalse(MeetingPromptReason.calendarNearby.isAdHocCallSignal, "calendar is not an ad-hoc mic/camera signal")
    }

    runSuite("MeetingPromptProvider.audioOutputProvider — output attributes to native conferencing apps only") {
        assertEqual(
            MeetingPromptProvider.audioOutputProvider(forBundleID: "us.zoom.xos"),
            .zoom,
            "Zoom playing audio output maps to the Zoom provider"
        )
        assertEqual(
            MeetingPromptProvider.audioOutputProvider(forBundleID: "us.zoom.xos.helper"),
            .zoom,
            "conferencing helper processes attribute to the parent app by family prefix"
        )
        assertEqual(
            MeetingPromptProvider.audioOutputProvider(forBundleID: "com.microsoft.teams2"),
            .teams,
            "Teams playing audio output maps to the Teams provider"
        )
        assertNil(
            MeetingPromptProvider.audioOutputProvider(forBundleID: "com.google.Chrome.helper"),
            "browser output is dominated by non-call playback and must never count as a call signal"
        )
        assertNil(
            MeetingPromptProvider.audioOutputProvider(forBundleID: "com.spotify.client"),
            "media apps playing audio must never count as a call signal"
        )
    }

    runSuite("MeetingPromptHeuristics.shouldReofferAfterExpiry — unattended prompts re-offer a bounded number of times") {
        assertTrue(
            MeetingPromptHeuristics.shouldReofferAfterExpiry(expiryCount: 1),
            "the first unattended expiry should schedule a short re-offer, not a dismissal"
        )
        assertTrue(
            MeetingPromptHeuristics.shouldReofferAfterExpiry(expiryCount: MeetingPromptHeuristics.maxPromptExpiryReoffers),
            "expiries up to the cap should still re-offer"
        )
        assertFalse(
            MeetingPromptHeuristics.shouldReofferAfterExpiry(expiryCount: MeetingPromptHeuristics.maxPromptExpiryReoffers + 1),
            "past the cap an ignored call must fall back to the normal dismissal backoff"
        )
        assertTrue(
            MeetingPromptHeuristics.promptExpiryReofferInterval < MeetingPromptHeuristics.defaultRuntimeDismissFallbackInterval,
            "the re-offer interval must be meaningfully shorter than a dismissal, or the expiry path is pointless"
        )
    }

    runSuite("MeetingPromptHeuristics.promptTimeoutSeconds — live call prompts outlast calendar reminders") {
        assertEqual(
            MeetingPromptHeuristics.promptTimeoutSeconds(for: .micInput, calendarDefault: 30),
            MeetingPromptHeuristics.adHocCallPromptTimeoutSeconds,
            "an ad-hoc mic call prompt should use the longer live-call lifetime"
        )
        assertEqual(
            MeetingPromptHeuristics.promptTimeoutSeconds(for: .audioOutput, calendarDefault: 30),
            MeetingPromptHeuristics.adHocCallPromptTimeoutSeconds,
            "an output-led call prompt should use the longer live-call lifetime"
        )
        assertEqual(
            MeetingPromptHeuristics.promptTimeoutSeconds(for: .calendarNearby, calendarDefault: 30),
            30,
            "calendar reminders keep the shorter default because their moment ages out"
        )
        assertTrue(
            MeetingPromptHeuristics.adHocCallPromptTimeoutSeconds > 30,
            "the live-call prompt lifetime should actually be longer than the calendar default"
        )
    }

    runSuite("MissedCallNudgePolicy.shouldNudge — nudges long unrecorded calls, respects every gate") {
        let now = Date(timeIntervalSince1970: 100_000)
        let longCall = MissedCallNudgePolicy.minimumCallDuration + 60

        assertTrue(
            MissedCallNudgePolicy.shouldNudge(
                duration: longCall, sawMeetingRecording: false, userDeclined: false, lastNudgeAt: nil, now: now
            ),
            "a long unrecorded call with no decline should nudge"
        )
        assertFalse(
            MissedCallNudgePolicy.shouldNudge(
                duration: longCall, sawMeetingRecording: true, userDeclined: false, lastNudgeAt: nil, now: now
            ),
            "a call that was recorded needs no nudge"
        )
        assertFalse(
            MissedCallNudgePolicy.shouldNudge(
                duration: longCall, sawMeetingRecording: false, userDeclined: true, lastNudgeAt: nil, now: now
            ),
            "an explicit 'not now' on the prompt means the nudge must stay quiet"
        )
        assertFalse(
            MissedCallNudgePolicy.shouldNudge(
                duration: MissedCallNudgePolicy.minimumCallDuration - 1,
                sawMeetingRecording: false, userDeclined: false, lastNudgeAt: nil, now: now
            ),
            "short calls are not worth interrupting for"
        )
        assertFalse(
            MissedCallNudgePolicy.shouldNudge(
                duration: longCall, sawMeetingRecording: false, userDeclined: false,
                lastNudgeAt: now.addingTimeInterval(-MissedCallNudgePolicy.nudgeCooldown + 60), now: now
            ),
            "back-to-back calls must not stack nudges inside the cooldown"
        )
        assertTrue(
            MissedCallNudgePolicy.shouldNudge(
                duration: longCall, sawMeetingRecording: false, userDeclined: false,
                lastNudgeAt: now.addingTimeInterval(-MissedCallNudgePolicy.nudgeCooldown - 60), now: now
            ),
            "once the cooldown passes a fresh missed call can nudge again"
        )
    }

    runSuite("MissedCallNudgePolicy.durationBucket — analytics stay coarse") {
        assertEqual(MissedCallNudgePolicy.durationBucket(for: 12 * 60), "10_to_20m", "12 minutes lands in the shortest bucket")
        assertEqual(MissedCallNudgePolicy.durationBucket(for: 25 * 60), "20_to_40m", "25 minutes lands in the middle bucket")
        assertEqual(MissedCallNudgePolicy.durationBucket(for: 70 * 60), "40m_plus", "long calls collapse into the open-ended bucket")
    }

    runSuite("MeetingPromptCallTelemetry — funnel buckets and signal kinds stay coarse and deterministic") {
        assertEqual(MeetingPromptCallTelemetry.durationBucket(for: 3 * 60), "1_to_5m", "short calls get the smallest bucket")
        assertEqual(MeetingPromptCallTelemetry.durationBucket(for: 7 * 60), "5_to_10m", "mid-short calls bucket correctly")
        assertEqual(MeetingPromptCallTelemetry.durationBucket(for: 15 * 60), "10_to_20m", "standard meetings bucket correctly")
        assertEqual(MeetingPromptCallTelemetry.durationBucket(for: 30 * 60), "20_to_40m", "half-hour meetings bucket correctly")
        assertEqual(MeetingPromptCallTelemetry.durationBucket(for: 90 * 60), "40m_plus", "long meetings collapse into the open bucket")

        assertEqual(
            MeetingPromptCallTelemetry.signalKinds(micSeen: true, speakerSeen: true, cameraSeen: true),
            "camera+mic+speaker",
            "signal kinds join sorted so dashboards get stable enum values"
        )
        assertEqual(
            MeetingPromptCallTelemetry.signalKinds(micSeen: false, speakerSeen: true, cameraSeen: false),
            "speaker",
            "a listen-only call reports the speaker signal alone"
        )
        assertEqual(
            MeetingPromptCallTelemetry.signalKinds(micSeen: false, speakerSeen: false, cameraSeen: false),
            "none",
            "an empty signal set stays an explicit enum value"
        )
    }

    runSuite("MeetingPromptCallTelemetry.promptOutcome — recorded beats declined beats ignored beats no_prompt") {
        assertEqual(
            MeetingPromptCallTelemetry.promptOutcome(promptShown: true, wasRecorded: true, userDeclined: true),
            .recorded,
            "a recording is the terminal success no matter what happened before"
        )
        assertEqual(
            MeetingPromptCallTelemetry.promptOutcome(promptShown: true, wasRecorded: false, userDeclined: true),
            .declined,
            "an explicit 'not now' is a decision, not a miss"
        )
        assertEqual(
            MeetingPromptCallTelemetry.promptOutcome(promptShown: true, wasRecorded: false, userDeclined: false),
            .ignored,
            "a prompt that fired but got no interaction is the 'never saw it' bucket"
        )
        assertEqual(
            MeetingPromptCallTelemetry.promptOutcome(promptShown: false, wasRecorded: false, userDeclined: false),
            .noPrompt,
            "a call we detected but never prompted for is a product gap, not a user choice"
        )
    }

    runSuite("MeetingPromptCallTelemetry.dismissStreakBucket — 'keeps hitting not now' stays a coarse bucket") {
        assertEqual(MeetingPromptCallTelemetry.dismissStreakBucket(1), "1", "a first dismissal is its own bucket")
        assertEqual(MeetingPromptCallTelemetry.dismissStreakBucket(2), "2", "a second dismissal is its own bucket")
        assertEqual(MeetingPromptCallTelemetry.dismissStreakBucket(5), "3_plus", "streaks collapse past three")
    }
}
