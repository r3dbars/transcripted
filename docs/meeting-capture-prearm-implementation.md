# Calendar pre-arm + one-tap recording — implementation notes

Companion to `docs/MEETING_CAPTURE_PROMPTING.md` (the design spec). This file
records how the spec maps onto the **current** `Sources/` codebase, what this
PR adds, and what is deliberately deferred. The spec's appendix references an
older `Transcripted/…` file layout (`MeetingDetector.swift`,
`PillStateManager.swift`); the live tree has already moved past that, so read
this for the real integration points.

## What already existed before this PR

The gentle calendar-pre-arm design is **largely already implemented** in the
current tree — the spec described migrating from an older codebase that no
longer exists:

- **EventKit calendar layer** — `Sources/Meeting/MeetingPromptDetector.swift`
  reads upcoming events (12h horizon), detects a conferencing link
  (Zoom / Meet / Teams / Webex / FaceTime) over `event.url` / `location` /
  `notes`, and offers a prompt inside the pre-arm window
  (`MeetingPromptWindowPolicy.shouldOfferCalendarPrompt`: from
  `calendarReminderLeadTime = 60s` before start to
  `calendarReminderPostStartGrace = 5min` after). Declined / all-day / link-less
  events never qualify.
- **The "armed" surface** — there is no `PillState` enum. The
  `MeetingOverlayController.OverlayState.prompt` state **is** the armed card: it
  renders the candidate with a one-tap **Record** button.
- **The tap** — `onPromptRecord → MeetingSessionController.startRecording(trigger: .detectedPrompt)`
  is the only record path. No file is ever written without it.
- **Permission + onboarding** — `.calendar` is a first-class
  `TranscriptedPermissionKind`; onboarding already has a Calendar step with an
  "Allow calendar access" button.
- **Legacy ad-hoc fallback** — running-process + mic-activity detection
  (`MicActivityMonitor`, `AutoCallDetectionPreferences`, default on) runs
  alongside the calendar path.

## What this PR adds

The genuine gaps versus the spec:

1. **Explicit opt-in / kill switch** — `Sources/Support/CalendarPreArmPreferences.swift`
   (default ON). `MeetingPromptDetector` now gates the calendar-candidate path on
   `calendarAccessGranted() && isCalendarPreArmEnabled()`. Turning it off stops
   all calendar prompts while leaving the ad-hoc fallback running — it degrades,
   it doesn't die.
2. **Generic-title privacy** — `Sources/Support/MeetingTitlePrivacyPreferences.swift`
   (default: show real titles) + `Sources/Meeting/MeetingArmedPromptCopy.swift`.
   The armed card shows the resolved title (real, or a generic "Meeting") and
   defaults to generic when a screen-share is detected (spec §4.2 B5). Today the
   prompt's `detail` line leaked the real event title even while screen-sharing.
3. **Armed copy + single T-0 chime** — `MeetingArmedPromptCopyPolicy` produces the
   `Starts in N min` pre-arm subtext and the single `Starting now — tap to record`
   nudge; the overlay plays one soft chime when a calendar prompt is presented at
   start time. Calendar prompts no longer show the 30s auto-dismiss countdown
   number.
4. **Settings + onboarding wiring** — two new General-page toggles ("Pre-arm from
   calendar", "Show real meeting titles"); onboarding's "Meeting reminders"
   toggle now persists to `CalendarPreArmPreferences`.

## The load-bearing invariant (held)

**No recording file is ever written without an explicit Record tap.** Pre-arm
only anticipates and prompts. `MeetingPromptDetector` exposes a *request*
(`onPromptRequest`) and a *separate* accept signal (`markAccepted`) that it never
calls itself; the record path lives solely in
`MeetingOverlayController.onPromptRecord`. The chime accompanies the card — it is
not an auto-start. Covered by the
"pre-arm only requests a prompt; it never auto-records" test.

## Pre-roll buffer — forward-only fallback shipped (buffer deferred)

The spec's optional 20s in-RAM pre-roll buffer (§3.5) is the heaviest, highest-
risk piece: it holds audio in RAM **before** any tap, so it needs an explicit
never-persists / continuously-overwritten guarantee and review sign-off (§4.4).
This PR ships the **safe forward-only-from-tap** fallback the spec calls out:
recording starts at the tap, which can now happen at/just-before the meeting
start instead of after first speech. The RAM-only pre-roll is a deliberate
follow-up; it must not ship half-done.

## Known approximations / follow-ups

- **T-0 chime timing & armed lifetime.** The armed card still auto-dismisses on
  the existing ~30s prompt timeout rather than persisting ~3min past start; the
  20s poll + pending cooldown re-present it. Precise T-0 timing and the longer
  armed lifetime are follow-ups.
- **Automatic screen-share detection.** `MeetingArmedPromptCopyPolicy` already
  takes an `isScreenShareLikely` flag (tested), but no cheap, reliable detector
  is wired yet, so it is passed `false`; the "Show real meeting titles" toggle is
  the live control. See the `TODO(prearm)` in `MeetingOverlayController`.
- **Chime asset.** The start nudge reuses the existing `dictationStart` cue (soft,
  respects the UI-sound preference). A dedicated "meeting armed" sound is a
  follow-up.
- **Auto-record (8s countdown) tier.** Out of scope here; remains the spec's
  opt-in, default-off tier.

## Manual proof required (not provable in CI)

- Real Calendar permission grant flow (TCC).
- A real Zoom/Meet/Teams/Webex calendar event firing the pre-arm prompt at
  start − lead.
- The tap → record at T-0 and the single soft chime.
- The General-page toggles and onboarding "Meeting reminders" persistence.
