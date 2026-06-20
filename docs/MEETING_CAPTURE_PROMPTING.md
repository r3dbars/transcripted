# Meeting-Capture Prompting Overhaul

**Status:** Draft spec for review
**Owner:** Design lead (synthesis)
**Audience:** Justin + eng
**One-line goal:** Get more meetings recorded with near-zero user thought, without inheriting the silent-recorder liability that forces people to turn the feature off.

---

## 1. Problem & goal

Transcripted is only valuable when it has artifacts. More recorded meetings = more transcripts, summaries, and searchable history. Today most meetings are never captured, and the ones that are cost the user attention at the exact moment they have none (the first 10 seconds of a live call).

**The goal is a capture rate that approaches 100% of the meetings the user actually wants, while the per-meeting cognitive cost approaches zero.** Two numbers move in opposite directions if you design naively:

- Crank capture up with silent auto-record → you record non-consenting third parties, the user gets uncomfortable, behavior chills, and the feature gets disabled (or sued — see Otter below).
- Crank trust up with a per-meeting "do you want to record?" modal → friction kills capture; people blow past it mid-conversation.

The winning design threads both: **front-load the detection and staging to *before* the meeting (so the user never has to remember, find a hotkey, or decide what counts as a meeting), and keep the actual record-start a single explicit human tap (so no file is ever written by surprise).** Convenience comes from prediction; trust comes from the tap.

---

## 2. How the current system works, and where it loses meetings

### 2.1 Current detection

All detection lives in `Transcripted/Services/MeetingDetector.swift`:

- **Running-process detection (primary trigger).** A hardcoded bundle-ID→name map (`MeetingDetector.swift:72-80`): `us.zoom.xos` (Zoom), `com.microsoft.teams2` / `com.microsoft.teams` (Teams), Webex, FaceTime, Loom. It subscribes to `NSWorkspace.didLaunchApplicationNotification` / `didTerminateApplicationNotification` and scans `runningApplications` on startup. A matching app *running* is the necessary precondition for any auto-record.
- **Bidirectional audio-level detection (the "a meeting is happening" signal).** Once a meeting app is running, `Audio.startMonitoring()` (`Audio.swift:508`, lightweight mic + system metering, no file) plus a 1s timer poll. In `tick()` it reads mic and system-audio levels; both above `speechThreshold = 0.02` = "bidirectional". Sustained bidirectional for `requiredBidirectionalDuration = 5s` → `onMeetingStart`.
- **Everything is gated on `UserDefaults` `autoRecordMeetings`**, which defaults to **false** (`SettingsContainerView.swift:21`, `@AppStorage` default false; never registered otherwise).

### 2.2 Current prompt UX: there isn't one

There is effectively **no pre-recording prompt**. When auto-detect is ON, the flow is fully automatic with only a *post-facto* notification: after 5s of bidirectional audio, `audio.start()` runs and *then* `sendAutoDetectStartNotification(appName:)` fires a banner titled "Recording Started" whose only action button is "Stop" (`NotificationCoordinator.swift:54-74`, `:16-25`). The user is **told after the fact**, never **asked**. When auto-detect is OFF (the default) the user gets nothing — no suggestion, no banner. The floating pill (`PillStateManager.swift:46-50`) has exactly four states — `idle`, `recording`, `processing`, `saved` — and **no "meeting detected / tap to record" state**.

### 2.3 Where meetings leak (ranked by size)

1. **Off by default = most meetings never record.** `autoRecordMeetings` defaults false. Unless the user finds Settings → Meeting Detection and flips it, the detector tracks state but never records (`MeetingDetector.swift:163,217,246`). This is the single biggest leak: the feature is dormant for anyone who didn't opt in.
2. **Browser meetings are a total blind spot.** Google Meet, Zoom-web, Teams-web run in a browser whose bundle ID isn't in `meetingApps`, so detection never even arms. The settings copy admits it (`MeetingDetectionSection.swift:43`: "Browser meetings (Google Meet, Teams web) require manual start."). A large share of modern meetings is 0% covered.
3. **Prompts too late / first 5+ seconds always lost.** Auto-start needs 5s of sustained bidirectional audio *after* the app is in a call. The opening (greetings, the first decision) is never captured.
4. **Tell-not-ask, and only nudge is a dismissible banner.** No proactive "looks like you're in a Zoom call, record it?" anywhere. The pill has no suggest state.
5. **Notifications silently suppressed if permission not granted.** Both auto-detect banners bail unless `authorizationStatus == .authorized` (`NotificationCoordinator.swift:56,80`). A user who denied notifications gets no feedback that recording started/stopped — and the "Stop" opt-out is unreachable.
6. **Audio heuristic is fragile.** Auto-start needs *both* mic AND system audio above 0.02 simultaneously — a muted listener never crosses the bar and is never recorded. A 15s lull (`silenceGracePeriod`) ends recording mid-meeting, then it must re-arm with another 5s.
7. **One meeting app at a time.** `handleMeetingAppLaunched` returns early if `activeMeetingApp != nil` (`MeetingDetector.swift:148`). Back-to-back/overlapping tools confuse state.
8. **No retroactive recovery.** Once the opening is lost, there's no buffer — recording only starts forward from `audio.start()`.

### 2.4 What the prior art says (research-backed constraints)

These are not opinions; they shape what we're allowed to ship.

- **All-party consent is the only safe default.** Federal + ~38 states are one-party, but 12 states (CA, WA, IL, FL, PA, …) are all-party, and you cannot geolocate remote participants. CIPA / Wiretap statutory damages **stack per violation**. So behave as if all-party always applies.
- **The Otter class action (In re Otter.AI, N.D. Cal. 2025) is the cautionary tale.** OtterPilot auto-joined calendar meetings as a bot and captured non-host participants who never consented and couldn't opt out. The legal landmine is **the third party who never knew** — not the user who installed the app. "Make sure you have permission" boilerplate that shifts liability onto the user is exactly the mistake.
- **"Silent recording is impossible" should be an advertised invariant (Fathom).** If the product has no silent-to-disk path, you literally cannot ship the Otter failure mode by accident.
- **Self-documenting consent (Granola).** Capture the spoken "yes" / disclosure inside the recording at t=0; auto-post an in-meeting chat notice; supply 5-second context-matched verbal scripts (sales / client / internal) so disclosure feels natural.
- **Lean into the OS indicator.** The macOS orange (mic) / purple (system-audio) menu-bar dot is system-enforced and tamper-proof. "Invisible to the meeting" is never invisible to the Mac user — treat the dot as free, honest proof.
- **Design against surprise, not recording.** 58% of professionals are uncomfortable with surprise AI joins; 41% change behavior when they know recording is happening (Calendly 2024). Predictability + visible control preserves both trust *and* conversation quality. A prompt for a meeting you scheduled is *expected*; a banner that pops because a bot heard two voices is a *surprise*.
- **EU/GDPR:** consent is often the *wrong* instrument (employee consent rarely "freely given"); transparency-before-capture + retention limits + auto-delete is the portable design that satisfies both US all-party norms and EU duties.

---

## 3. Recommended design

**Calendar-driven pre-arm with a single gentle one-tap nudge, on a new fifth pill state `.armed`** — synthesized winner, with the strongest grafts from the runner-up "auto-arm" and "ambient" designs deliberately scoped in or explicitly deferred.

### 3.1 Stance on aggressiveness: gentle by default, with one aggressive option behind a switch

**Default: gentle. One tap per meeting. No countdown-to-auto-record in the default path.**

This is defended directly by the judge and the adversarial reviews:

- The judges scored the calendar pre-arm the winner precisely because it **front-loads detection to before the meeting** (killing the "remember / find hotkey / decide" cost) **while keeping record-start an explicit human tap** so **no file is ever written without a tap**. That single property is what lets us advertise "it never records you by surprise" — and what keeps us on the safe side of the Otter line.
- The aggressive "inaction = consent, auto-start at t=0" design (design #1) scored well on raw capture but every one of its key tradeoffs is a *blocking* risk: default-on auto-start *can* capture a non-consenting third party, "the notice came a beat late" is arguable in strict all-party states, and the audible chime it relies on is itself a feature people will ask to suppress — which is the silent path we refuse to ship. We keep its *good* ideas (pre-roll buffer, browser detection, muted-listener fix) and drop its auto-start-on-inaction core.
- The ambient "set-it-once, record everything silently" design (design #4) maximizes capture but is the highest-liability option: it leans entirely on an always-visible indicator to substitute for consent, and a denied-notifications / glanced-past user can be recorded with no contemporaneous human acknowledgement. We make this an *opt-in advanced mode*, not the default.

**Net stance:** ship the gentle calendar-pre-arm as the default-on primary path. Offer aggressiveness as an explicit, clearly-disclosed setting (see §3.7), defaulting to the gentle tier. The countdown-auto-record path (below) is **built but defaults OFF**; turning it on is a deliberate choice with full disclosure.

### 3.2 Detection triggers (layered, calendar-first)

**Tier 1 — Calendar pre-arm (NEW, primary).** Add EventKit (zero calendar code exists today; `grep EKEventStore` over Sources returns nothing). On launch and on a 15-min refresh, plus `EKEventStoreChanged` notifications, read events in the next 12h from the default calendars. An event qualifies for pre-arm if **any** of:

- a conferencing URL via regex over `event.url`, `location`, and `notes` for `zoom.us`, `teams.microsoft`/`teams.live`, `webex.com`, `meet.google.com`, or a tel/SIP dial-in;
- a known virtual-conference structured field; or
- 2+ attendees on a non-all-day time block.

Each qualifying event schedules a local timer firing at **start − lead** (default lead **60s**). We honor `EKEvent` status and the user's RSVP: **declined or cancelled events never arm**; edits reschedule via `EKEventStoreChanged`.

This fixes the two biggest leaks for free: **browser meetings become first-class** (we key off the calendar link, not the app process) and the **off-by-default dormancy** is replaced by a visibly-working path.

**Tier 2 — Conferencing/app detection (KEPT + widened, fallback for ad-hoc meetings).** The legacy running-process + bidirectional-audio detector (`MeetingDetector.swift`) stays as an **opt-in** fallback for meetings with no calendar event (someone grabs you on Zoom with no invite, Slack huddles). Two grafted improvements from the other designs, gated to the fallback path:

- **Close the browser blind spot cheaply:** a low-frequency window-title scan (the RecapAI / pasrom open-source pattern) matching `"Meet - "`, `"Zoom Meeting"`, `"Microsoft Teams | "` in Chrome/Safari/Arc/Edge. Prefer `CGWindowList` (already linked at `OnboardingState.swift:145`, **no AX permission**) over the AX API; fall back to AX only if title fidelity demands it, and request that permission once with a clear rationale.
- **Muted-listener fix:** arm on **either channel sustained** above `speechThreshold`, not the current `mic AND system` (`MeetingDetector.swift:208,231` already computes `||` for `hasAudio` on the stop side — bring the start side in line). This captures the mostly-listening attendee who never crosses the bidirectional bar today.

**Tier 3 — the staging step (NEW, applies to both tiers).** At pre-arm/lead time we call the existing `Audio.startMonitoring()` (`Audio.swift:508`) to pre-warm the engine and permission checks. **No file is written.** This is the same lightweight metering path `MeetingDetector` already uses, now driven by the clock instead of a process match.

### 3.3 The prompt UX (exact spec)

Add a **fifth `PillState` case `.armed`** to `PillStateManager.swift:46-50` (between `idle` and `recording`). Two touchpoints, both on the existing floating pill (`FloatingPanelView.swift`) — never a system notification, so it works even when notification permission is denied (fixes the silent-suppression gap at `NotificationCoordinator.swift:56,80`).

**Touchpoint 1 — PRE-ARM card (T−60s, silent).** Pill morphs from the `.idle` capsule into a slim `.armed` card, ~220×44, **no sound, no modal, does not steal focus** (panel keeps `canBecomeKey = false`).

- Left: a calendar-clock glyph with a soft pulsing ring (reuse `showOnboardingGlow` styling, `PillStateManager.swift:62`).
- Center, one line, truncated: the event title, e.g. **"Weekly 1:1 with Sarah"** (privacy fallback "Meeting" — see §4).
- Right: one pill-shaped primary button **"Record"** (`mic.fill`). A faint secondary **×** dismisses this meeting's prompt.
- Subtext, 11pt secondary: **"Starts in 1 min"**.

**Touchpoint 2 — START nudge (T−0, the single gentle nudge).** At the event's scheduled start the card plays **one** soft chime (reuse `PillSounds` "Pop" at 30% volume, `PillStateManager.swift:11-13,37`). Subtext flips to **"Starting now — tap to record"**. The Record button gets a one-time scale bounce. **That is the entire nudge: one chime, one line, one button.** No countdown, no auto-start in the default path — if the user does nothing, **nothing records** and the `.armed` card auto-dismisses ~3 min after scheduled start.

**Exact copy & buttons (default gentle path):**

| Element | Copy |
|---|---|
| Pre-arm title | `Weekly 1:1 with Sarah` (event title; fallback `Meeting`) |
| Pre-arm subtext | `Starts in 1 min` |
| Primary button | `Record` (icon `mic.fill`) |
| Secondary | `×` (dismiss this meeting; on recurring series → `Skip this one` / `Skip series`) |
| T−0 subtext | `Starting now — tap to record` |

**The 60s-countdown auto-record path (built, OFF by default).** Some users will want hands-free capture. For them we ship an **opt-in "Auto-record scheduled meetings"** tier (§3.7) that converts the gentle nudge into a short countdown. **Critical: the countdown is ~8 seconds, NOT 60.** A 60s timer guarantees you lose the meeting's opening (the existing #1 pain point) at the worst possible scale; 8s is long enough to react (well above the ~2s glance-and-act floor) and the pre-roll buffer (§3.5) fully covers the gap so nothing is actually lost. When this tier is on, the `.armed` card and pill show:

| Element | Copy (auto-record tier only) |
|---|---|
| Title | `Looks like a Zoom call` (app/meeting name interpolated) |
| Subtitle | `Recording starts in 8s unless you stop it` |
| Countdown ring | 42px info/**blue** ring (not red — red reads as "already recording"), depleting clockwise, live integer 8…7…6 |
| Button 1 | `Not now` (icon `ti-x`) — dismiss, no recording; suppress re-prompt for this meeting instance |
| Button 2 | `Snooze` (icon `ti-clock`) — re-arm in 90s if the call is still live |
| Button 3 | `Record now` (icon `ti-player-record`, filled, primary) — start immediately, back-fill pre-roll |
| Footer | `All-party notice. Everyone hears recording start. Esc = stop & discard.` |
| At t=0 (no action) | Recording starts **non-silently**: chime on the call + pill → recording + in-meeting chat notice where the API allows + pre-roll back-fill |

So the button set across the whole feature is: gentle path = **`Record` / ×**; auto-record tier = **`Not now` / `Snooze` / `Record now`** with t=0 auto-start. We deliberately do not offer a "Remind me in N minutes" beyond Snooze — it's the same affordance with a fixed 90s.

### 3.4 The tap, and what start means

Clicking **Record** calls the existing `audio.start()` entry (same path as `AuroraIdleView onRecord`, `FloatingPanelView.swift:267-272` → `RecordingCoordinator.toggleRecording`, `RecordingCoordinator.swift:9-16`). The pill transitions to the existing `.recording` state (gradient border + running timer + Stop). Because record starts at the tap, **not after 5s of bidirectional audio**, the meeting opening is captured.

At t=0 of the recording we surface consent in-band (see §4): post an in-meeting chat notice where the conferencing API allows (Granola/Fathom), and show a 5-second verbal-disclosure one-liner in the pill tooltip, matched to meeting type by attendee domains (internal vs external), e.g. *"Heads up — I'm recording this for notes."*

### 3.5 Pre-roll buffer (grafted, default-ON, RAM-only)

While `.armed`, hold a short rolling **in-memory** buffer (default **20s**, configurable 0–30s) from the already-running monitor tap (`Audio.startMonitoring`). On the Record tap we prepend it so greetings aren't lost. **The buffer is RAM-only, continuously overwritten, and never hits disk unless the user taps** — this preserves the no-silent-file invariant and is the load-bearing engineering risk (§4.4). If shipping the buffer is too costly or its invariant can't be guaranteed under review, the honest fallback is **forward-only-from-tap**, which still beats today because the tap can happen at T−0 instead of after first speech.

### 3.6 Recording indicator & instant stop/discard

**Indicator (three redundant, honest signals):**

1. The macOS system **orange mic / purple system-audio menu-bar dot** — never suppressed, treated as tamper-proof proof.
2. The pill in `.recording` state, pinned visible, showing app/meeting name + live elapsed timer + red dot. **The pill is the source of truth**, so a denied-notifications user always sees state.
3. The existing "Recording Started" notification (`NotificationCoordinator.swift:54-74`) fires as a *redundant* signal only.

**Stop / discard (instant, multiple routes):**

- **During `.armed`** (gentle path): the × on the card, or `Stop` on the armed pill — aborts before any file is written, **zero artifact**.
- **After recording starts:** the pill's `Stop` (keeps the recording, `RecordingCoordinator.toggleRecording`) **and a distinct `Discard`** affordance — a small "Delete this recording" link visible for the first ~10s that **stops AND deletes** the audio + pre-roll without transcribing. This is the panic button for "I didn't mean to start this in front of someone."
- **Global Esc**, hooked like the tray's existing local+global Esc monitors (`FloatingPanelView.swift:340-376`): Esc during arm = abort; Esc within the first ~10s of recording = stop & discard.
- **Cmd+Shift+R** toggles as today (`HotkeyManager.swift:10-28`).

`Discard` is reachable from the pill, never buried in a menu.

### 3.7 Aggressiveness as a setting (the tier model)

One setting, three tiers, **default = Gentle**:

1. **Off** — no pre-arm, no prompts. (Legacy audio/process auto-detect remains independently opt-in, as today.)
2. **Gentle (DEFAULT, what onboarding turns on)** — calendar pre-arm + one-tap nudge. No countdown, no auto-start. *No file without a tap.*
3. **Auto-record (opt-in, full disclosure)** — calendar pre-arm + 8s countdown + non-silent t=0 auto-start. This is the only tier that can write a file without a tap, and it only does so after an audible chime + visible indicator + in-meeting notice.

The legacy running-process/bidirectional-audio detector (`MeetingDetector.swift`) is the **ad-hoc fallback** under any tier ≥ Gentle, still independently toggleable.

---

## 4. Consent model & blocking mitigations (load-bearing)

This section is non-negotiable. The product invariant we advertise — **"Transcripted never writes a recording file without a human signal, and never records anyone silently"** — is what keeps us off the Otter docket. Every mitigation below is a ship-blocker.

### 4.1 Two-layer consent

**App-level (the Mac user).** One-time onboarding opt-in: Transcripted asks for EventKit read permission and states plainly: *"I'll watch your calendar and offer to record meetings with one tap. I never record without your tap."* This replaces the buried default-off `autoRecordMeetings` flag (`SettingsContainerView.swift:21`) with an explicit onboarding choice. (Keep the code default `false`; onboarding's primary CTA writes the tier.)

**Participant-level (everyone in the room).** All-party consent is the **universal default** because remote attendees can't be geolocated and statutory damages stack. We satisfy it three ways at record-start:

1. **Self-documenting verbal disclosure** — surface a context-matched one-liner the user reads aloud; it lands *inside* the recording at t=0 (Granola pattern), so consent survives in two-party states.
2. **Auto-posted chat notice** via the conferencing API where available (Granola/Fathom).
3. **Separate local consent log** — one row per recording: timestamp, meeting title, detected app, disclosure method surfaced. Local-only.

Jurisdiction handling is **portable, not geo-gated**: notify-before-capture + retention limit + auto-delete satisfies both US all-party norms and EU/GDPR transparency duties (where employee "consent" is rarely freely given and Art. 6(1)(f) legitimate interest + transparency matters more than a click).

### 4.2 BLOCKING legal mitigations (from the adversarial review)

- **B1 — No silent-to-disk path, ever.** In the default/Gentle tier, a file is written only on the human tap. In the opt-in Auto-record tier, t=0 start is **never silent**: audible chime + visible pill + OS dot + in-meeting chat notice all fire at t=0. If any of those four can't fire (e.g. chat-notice API unavailable), the recording **still must** emit the chime + dot + pill. Delete any code path that could record to disk with zero contemporaneous signal.
- **B2 — Do not push compliance onto the user.** No "ensure you have permission" boilerplate substituting for product behavior (the explicit Otter mistake). The product *performs* notice; it doesn't *outsource* it.
- **B3 — Non-host third parties must always have notice + a real opt-out/pause.** The in-meeting notice + the audible chime are the notice; Stop/Discard + Pause are the opt-out. This is the precise gap that sank Otter.
- **B4 — Retention + auto-delete are first-class.** Ship a visible retention setting and auto-delete (portable EU/US posture). AI-transcript accuracy is itself a compliance concern; keep a human-review path.
- **B5 — Calendar metadata is sensitive.** Event titles/attendees rendered on a floating pill and written to the consent log are PII. Local-only handling; a setting to show generic **"Meeting"** instead of the real title (default to generic in screen-share contexts).

### 4.3 BLOCKING false-positive mitigations

False positives must be **cheap by construction**: pre-arm writes nothing and auto-starts nothing in the Gentle tier, so a wrong guess costs at most one dismissible card and **zero recorded bytes**.

- **F1 — Link-but-not-a-meeting** (focus block, hold, "Zoom link in notes"): `.armed` card appears, user ignores or taps ×. No file.
- **F2 — Back-to-back / overlapping meetings** (today's detector returns early on `activeMeetingApp != nil`, `MeetingDetector.swift:148`): calendar pre-arm handles a queue — show the nearer-starting event, roll to the next at its start.
- **F3 — Cancelled / declined / moved:** honor `EKEvent` status + RSVP; declined/cancelled never arm; `EKEventStoreChanged` reschedules on edits.
- **F4 — Recurring junk:** per-meeting × offers **"Skip this one / Skip series"**. Track dismiss-vs-record per series; after 3 straight ignores, stop arming with a quiet, undoable "muted this recurring meeting" note.
- **F5 — Wrong-link meetings** (phone-only, in-person with a stray URL): still just a card; ignored at no cost.
- **F6 — Auto-record tier safety:** in the opt-in tier, the t=0 chime makes any wrong auto-start **immediately audible** (and disclosed), and Esc within 10s does stop-and-discard in one keystroke — a wrong auto-start can never silently accumulate. Repeated "Not now" on the same app within a session raises that app's arm threshold for the day.

**Honest core:** because the default path has no silent record, a false positive **can never become a privacy incident** — the worst outcome is a card you didn't want.

### 4.4 The one new invariant risk to watch

The 20s in-memory pre-roll buffer means **audio IS held in RAM before any tap**. Eng must guarantee it never persists and is continuously overwritten, or the "no recording without a tap" promise is undermined. This gets explicit review sign-off; if it can't be guaranteed, ship forward-only-from-tap (§3.5).

---

## 5. Implementation plan

Phased so the trust-preserving default ships first and the aggressive tier is gated behind a switch + telemetry.

### Phase 0 — Pill `.armed` state + plumbing (no calendar yet)
- Add `case armed` to `PillState` (`PillStateManager.swift:46-50`) with transitions `idle → armed → recording` and `armed → idle` (dismiss).
- Build the `.armed` card view in `FloatingPanelView.swift` (reuse `showOnboardingGlow` for the pulse). Wire its Record button to the existing `RecordingCoordinator.toggleRecording` path (`FloatingPanelView.swift:267-272`).
- Add the `Discard` affordance to the `.recording` view (first ~10s): stop + delete without transcribe.
- **Ship behind a feature flag, dark.** No behavior change for users yet.

### Phase 1 — Calendar pre-arm (EventKit)
- New `Services/CalendarPreArm.swift`: EventKit read, 12h horizon, 15-min refresh + `EKEventStoreChanged`, qualification regex (§3.2), per-event local timers at start−lead.
- Onboarding step requesting EventKit permission with the §4.1 copy; primary CTA writes tier = **Gentle**.
- At lead time: enter `.armed`, call `Audio.startMonitoring()` (`Audio.swift:508`). No file.
- Honor `EKEvent` status + RSVP (F3); queue overlapping events (F2); per-series skip/mute (F4).
- Consent log writer (local-only, §4.1); generic-title privacy setting (B5).

### Phase 2 — Pre-roll buffer (RAM-only)
- Extend the `Audio.startMonitoring` tap to write mic+system into a continuously-overwritten in-memory ring (default 20s). On Record tap, flush to the front of the file. **Explicit eng sign-off on the never-persists invariant (§4.4).** Fallback: forward-only-from-tap.

### Phase 3 — Ad-hoc fallback improvements (legacy detector)
- Window-title scan via `CGWindowList` (already linked, `OnboardingState.swift:145`) to close the browser blind spot (Tier 2).
- Bring the start-side audio gate in line with the stop-side `||` so muted listeners arm (`MeetingDetector.swift:208,231`).
- Keep this tier independently opt-in.

### Phase 4 — Auto-record tier (opt-in countdown, default OFF)
- Add the 8s countdown ring + `Not now` / `Snooze` / `Record now` to the `.armed` card (auto-record tier only).
- Non-silent t=0 auto-start: chime + pill + OS dot + in-meeting chat notice + pre-roll back-fill (B1).
- In-meeting chat-notice integration per conferencing API where available.

### Settings / opt-in
- `MeetingDetectionSection.swift`: replace the static browser-limitation copy (`:43`) with the tier picker (Off / Gentle / Auto-record), pre-roll length (0–30s), retention/auto-delete (B4), generic-title toggle (B5), and the ad-hoc-fallback toggle.
- Onboarding writes **Gentle** as the default.

### Safe rollout & kill switch
- **Default aggressiveness: Gentle.** Auto-record tier defaults **OFF**; turning it on is a deliberate, disclosed choice.
- **Feature flag / kill switch** gating the entire pre-arm path (a single `UserDefaults` / remote flag) so we can dark-launch and disable instantly if EventKit scanning, title-matching, or the pre-roll invariant misbehaves.
- **Telemetry to tune, before considering any default change:** prompt-shown → tapped → recorded → kept funnel; false-positive dismiss rate per source; pre-roll cost; countdown abort rate (if/when Auto-record tier sees use). Use this to settle the 8s-vs-8–12s number and whether Auto-record should ever graduate to default.
- Staged: internal → small cohort → GA, with the kill switch live the whole time.

---

## 6. Open questions for Justin

1. **Default aggressiveness.** Recommendation is **Gentle by default** (one tap, no auto-start). Agree, or do you want Auto-record (8s countdown, non-silent t=0 start) as the default to maximize capture? The judges and risk reviews favor Gentle; Auto-record is the only tier that can write a file without a tap.
2. **Does countdown-auto-record ship at all, and on/opt-in?** Recommendation: **build it, ship it OFF (opt-in)**, full disclosure. Alternative: don't build it yet (Gentle only) and revisit after telemetry. Your call on whether the capture upside justifies the liability surface even behind a switch.
3. **Pre-roll buffer.** Ship the 20s RAM-only pre-roll (max capture of the opening, but new invariant risk), or the safer forward-only-from-tap (lower value, zero RAM-audio risk)? Recommendation: pre-roll **if** eng signs off on the never-persists guarantee; otherwise forward-only.
4. **Calendar permission friction.** Pre-arm is dead without EventKit access. How hard do we push the calendar ask in onboarding, and how graceful is the no-calendar fallback (ad-hoc detector only)?
5. **Title privacy default.** Show real event titles on the pill (better UX) or default to generic "Meeting" (safer for screen-share)? Recommendation: real title normally, generic when a screen-share/system-audio capture is detected.
6. **Lead time.** 60s pre-arm lead and 20s pre-roll — keep, or tune? Meetings start early/late, so the chime can fire into an empty room or after the real start.
7. **Ad-hoc fallback scope.** Keep the legacy audio/process detector as an opt-in fallback (re-inherits browser-blind/5s-late gaps unless we also ship the Phase 3 title-scan)? Or invest fully in title-scan so ad-hoc meetings are first-class too?

---

## Appendix — file map (current system, for implementers)

- `Transcripted/Services/MeetingDetector.swift` — all current detection; `meetingApps` map (`:72-80`), thresholds `speechThreshold 0.02` (`:51`) / `requiredBidirectionalDuration 5s` (`:54`) / `silenceGracePeriod 15s` (`:57`), one-app-at-a-time early return (`:148`), gate on `autoRecordMeetings` (`:163,217,246`), `||` stop-side audio (`:208`).
- `Transcripted/TranscriptedApp.swift:138-153` — wires `onMeetingStart`/`onMeetingEnd`.
- `Transcripted/Core/NotificationCoordinator.swift:54-101` — post-start/stop banners; auth gate (`:56,80`); Stop action (`:16-25`).
- `Transcripted/UI/Settings/Sections/MeetingDetectionSection.swift:43` — settings copy incl. browser-limitation disclaimer (to be replaced by the tier picker).
- `Transcripted/UI/Settings/SettingsContainerView.swift:21` — `autoRecordMeetings` `@AppStorage` default `false`.
- `Transcripted/Core/RecordingCoordinator.swift:9-16` — `toggleRecording`, shared start/stop.
- `Transcripted/Core/HotkeyManager.swift:10-28` — Cmd+Shift+R.
- `Transcripted/Core/MenuBarManager.swift:52-55` — menu-bar Start Recording.
- `Transcripted/UI/FloatingPanel/FloatingPanelView.swift` — pill/tray; manual start (`:267-272`); Esc monitors (`:340-376`).
- `Transcripted/UI/FloatingPanel/PillStateManager.swift:46-50` — `PillState` (idle/recording/processing/saved — **add `.armed`**); `PillSounds` (`:9-41`); `showOnboardingGlow` (`:62`).
- `Transcripted/Core/Audio.swift:508` — `startMonitoring()`, the pre-warm/pre-roll tap.
- **EventKit:** none today (`grep EKEventStore` → zero). New `Services/CalendarPreArm.swift`.
