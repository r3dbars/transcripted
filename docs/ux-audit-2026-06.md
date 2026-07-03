# Transcripted UX audit — June 2026

A researcher's pass over the live app surfaces: first run, the menubar, the
dictation overlay, meeting capture, and Settings. Everything here is grounded in
the actual code as of this branch, with `file:line` pointers so each finding is
checkable.

The framing question was: **where will users hesitate, what's confusing, what
should disappear, and where will they quit?** That's how this is organized,
followed by a prioritized change list.

---

## TL;DR

The product is genuinely good and the writing is mostly excellent — calm,
concrete, privacy-forward. The problems aren't taste, they're *load*:

1. **Onboarding is 12–14 full-screen steps before the app opens.** That's the
   single biggest quit risk, and the team already knows it — there's
   abandonment telemetry wired into every step.
2. **The "first dictation" test can fail for reasons that look like the product
   is broken** (model still downloading, hotkey conflict, no speech), and
   there's no graceful "that didn't work, here's why" path.
3. **Silent outputs.** A meeting ends and the transcript drops into a folder
   with no toast, no "Open", no breadcrumb. The payoff moment is invisible.
4. **Paste silently falls back to the clipboard** when it can't type into the
   target app — and the user is never told their words are sitting on the
   clipboard, so it reads as "my dictation vanished."
5. **Settings has real jargon and at least two duplicated controls** that make a
   simple app feel like it has an advanced mode it doesn't need to expose.

Fixing 1–4 is where the activation and retention wins are. 5 is cleanup.

---

## Where users hesitate

**The permission rooms.** Both onboarding paths gate the "Continue" button on
granting permissions (`PermissionsOnboardingView.swift:88-90, 430-440`). The
flow itself is fine — it polls every second so checkmarks flip automatically
when you return from System Settings (`:575-587`) — but two specific labels
cause hesitation:

- **Accessibility** is explained only as *"So paste-back works in other apps."*
  (`:418`). People who associate "Accessibility" with screen readers will pause,
  and some will deny it because it sounds like it's not for them. This is the
  permission most likely to be refused, and refusing it breaks the core feature.
- **System Audio** is correctly reframed as *"For everyone else on the call."*
  (`:408`) — that one's a good model to copy.

**The "try it now" step.** The dictation path asks the user to physically tap
Right Option and dictate into a demo field (`:226-247`). Great idea — but it's
the first time the model may need to download, and if it's mid-download the test
just… waits. The user doesn't know if they did it wrong or the app is slow.

**Mic-processing picker.** Three options, one of which name-drops "Blue Yeti"
and another warns that "other apps' audio may get quieter"
(`MicrophoneProcessingPreferences.swift:67-71`). Anyone who opens this picker
hesitates because there's no "just pick the normal one" signal (there is a
default, but the labels don't say so loudly enough).

**Paste Last Dictation.** The menubar row says "Paste to [app]" but gives no
hint about what happens with no focused field or Accessibility off
(`MenuBarPrimaryActionsView.swift:89-97`). Users learn by hitting the error.

---

## What's confusing

**Duplicated settings.** Mic processing and the local-speaker split toggle each
appear in *both* General and Privacy
(`TranscriptedSettingsView.swift:2549-2588` and the Privacy duplicate near
`:2826-2844`). Same control, same help text, two homes. A user who flips it in
one place and later sees it in the other can't tell if they're different knobs.

**"Identify multiple people on this Mac"** (`:2571`). The label describes a
mechanism, not an outcome. Nothing tells the user that flipping this means a
*review sheet appears after the meeting* asking them to name voices. They find
out by being surprised.

**Two transcription verbs.** The dictation overlay shows "Transcribing…" and
then "Refining…" (`OverlayDraftingView.swift:151, 170`). To the user these are
indistinguishable states — "refining" reads like extra work happening to their
words that they didn't ask for.

**"Saved only."** When the 5-minute dictation cap hits, the overlay says "Saved
only" (`DictationSessionController.swift:1157`) with no where or why. Did it
fail? Where did it go? This is a confusing success.

**Jargon leaking into the UI.** "Markdown" (never explained — fine for the
target user, risky for the mainstream one), and in the Beta tab, "Codex" and
"Claude Cowork" appear with no context for anyone outside that ecosystem.

**No-speech advice only fits half the users.** The no-speech message branches on
trigger type: physical-key users get *"Hold the dictation key while you talk"*,
everyone else gets the generic *"Start over and speak a little longer"*
(`DictationNoSpeechPresentationPolicy.swift:5-9`). Hands-free is the default, so
most people get the less useful message.

---

## What should disappear

**~4 onboarding steps.** The flow has real teaching steps (permissions,
shortcut test) *and* pure pitch steps (Memory payoff `:320`, Agent demo `:337`)
that the user already bought — they downloaded the app. Memory + Agent demo +
Agent connect can collapse into one "you're set, here's the payoff" screen and a
later nudge. Target: get the meetings path under ~7 steps, dictation under ~9.

**One of the two duplicated Settings homes** for mic processing and
local-speaker split. Pick General *or* Privacy, not both.

**Dead onboarding code.** `FirstRunOnboardingStep` and its
`onboardingAction`/`FirstRunOnboardingActionState` helpers
(`FirstRunExperience.swift:60-241`) are an entire parallel onboarding model that
nothing but its own tests references — the live flow is
`PermissionsOnboardingView`'s own `OnboardingStepKind`. It's not user-facing,
but it's a trap for the next person editing onboarding copy. Delete it.

**The redundant shortcut echo.** The dictation shortcut is shown in the menubar
row, again as a trailing badge, and again as an overlay hint. One canonical
place is enough.

**The 1.5s success toast.** Paste-success holds for 1.5s
(`PasteLastDictationFeedback.swift`) — fast enough that a user who starts typing
immediately never sees the confirmation. 2.5s is safer.

---

## Where they're likely to quit

Ranked by how much it hurts:

1. **Mid-onboarding.** 12–14 steps is a lot of "Continue" for a free utility.
   The team instruments `onboarding_step_viewed` and a `WorkflowAbandoned`
   event per step (`PermissionsOnboardingView.swift:620-661`) — pull that data,
   the drop-off curve will point straight at the cut list above.
2. **The first dictation test failing.** Model-still-downloading, a hotkey
   conflict, or a quiet mic all produce a "nothing happened" experience right at
   the moment the user is deciding if this thing works. There's no "the hotkey
   didn't fire — check it in Settings" branch; they just get "No speech heard."
3. **Paste falling back to clipboard, silently.** When AX is off or focus
   changed, the text goes to the clipboard and the overlay shows a terse
   "copied instead"-style message with **no button to paste it**
   (`DictationSessionController.swift:1564-1583`). To the user, their words are
   gone. This is the highest-severity individual bug-feeling moment in the app.
4. **"Where did my meeting go?"** After a recording stops, the overlay says
   "Saved to Markdown" (`MeetingOverlayController.swift:825`) and that's it — no
   toast, no "Open", no Finder reveal. The user has to *know* to open Settings →
   Home or dig through a folder. The single best moment in the product is
   invisible.
5. **Inactivity auto-stop on a real call.** Five minutes under a quiet
   threshold triggers a 30-second countdown to auto-stop
   (`MeetingAudioInactivityDetector.swift:34`). Calls have long quiet stretches
   (someone screen-sharing, thinking, on mute). Auto-stopping a live recording
   that the user wanted is a trust-breaker, and there's no "stay recording for
   this call" snooze — only a global Settings toggle.

---

## Change list (prioritized)

### P0 — protects activation and trust, do first

| # | Change | Why | Where |
|---|--------|-----|-------|
| 1 | **Tell the user when paste fell back to the clipboard, and give a one-click "Paste" / make it obvious it's on the clipboard.** | Highest "it lost my text" moment. | `DictationSessionController.swift:1564-1583`, `OverlayDraftingView.swift:219-274` |
| 2 | **Add a save confirmation for meetings** — overlay "Saved · Open" plus reveal-in-Finder. | The payoff is currently invisible. | `MeetingOverlayController.swift:825` |
| 3 | **Cut onboarding to ~7 (meetings) / ~9 (dictation) steps.** Merge Memory + Agent demo + Connect into one payoff screen; defer agent-connect to a Home nudge. | Biggest quit point; they already have the abandonment data to prove it. | `PermissionsOnboardingView.swift:730-765` |
| 4 | **Rewrite the Accessibility permission reason** to an outcome with examples: *"So Transcripted can type your words into Mail, Slack, and other apps."* | It's the most-denied required permission and denial breaks the core loop. | `PermissionsOnboardingView.swift:418` |

### P1 — removes confusion and dead-ends

| # | Change | Why | Where |
|---|--------|-----|-------|
| 5 | **Handle a failed first-dictation test explicitly** — detect "model still downloading" and "no trigger fired" and say so, instead of "No speech heard." | The make-or-break first impression. | `PermissionsOnboardingView.swift:226-247`, `DictationNoSpeechPresentationPolicy.swift` |
| 6 | **De-duplicate mic-processing and local-speaker-split** into one Settings home each. | Two homes for one control reads as two settings. | `TranscriptedSettingsView.swift:2549-2588` + Privacy duplicate |
| 7 | **Relabel "Identify multiple people on this Mac"** to describe the outcome: *"After meetings, ask me to name the people near this Mac who spoke."* | Label describes mechanism, hides the surprise sheet. | `TranscriptedSettingsView.swift:2571` |
| 8 | **Add a "keep recording" snooze to the inactivity auto-stop** (and consider ending on the calendar event's end time instead). | Auto-stopping a wanted recording breaks trust. | `MeetingAudioInactivityDetector.swift:34` |
| 9 | **Make the no-speech message useful for hands-free users** (the default mode). | Most users get the least useful message. | `DictationNoSpeechPresentationPolicy.swift:5-9` |

### P2 — polish and cleanup

| # | Change | Why | Where |
|---|--------|-----|-------|
| 10 | **Delete the dead `FirstRunOnboardingStep` model.** | Trap for the next onboarding edit. | `FirstRunExperience.swift:60-241` |
| 11 | **Merge "Transcribing…" and "Refining…"** into one state, or hide "Refining." | Two verbs read as mystery extra work. | `OverlayDraftingView.swift:151,170` |
| 12 | **Replace "Saved only"** with "Auto-saved to today's notes" + a way to open it. | Confusing success. | `DictationSessionController.swift:1157` |
| 13 | **Soften the mic-processing picker** — mark the default clearly, move the Blue Yeti / voice-processing detail behind "Advanced." | Makes a simple app feel like it needs tuning. | `MicrophoneProcessingPreferences.swift:54-72` |
| 14 | **Slow the paste-success toast to ~2.5s** and surface a clear cancel/Escape hint during listening even when shortcuts are disabled. | Confirmation currently missable; cancel undiscoverable for some. | `PasteLastDictationFeedback.swift`, `OverlayHeaderView.swift:326-342` |
| 15 | **Add an empty-state nudge on Home** ("Record your first meeting" / "Try a dictation") instead of bare empty sections. | First-open Home is silent. | `HomeView.swift:1815-1862` |

---

## What's already good (don't break these)

- The privacy story is told plainly and early, and the "never sent" list in
  Settings is exactly right (`TranscriptedSettingsView.swift:2650`).
- The detected-meeting prompt is non-blocking with a clean "Not now" / "Remind
  me soon" (`MeetingOverlayController.swift:785-797`).
- The model-status badge in the menubar means users always know if dictation is
  ready (`MenuBarModelStatusView.swift`).
- The imported-audio error messages are specific and human
  (`MeetingImportedAudioPreparer.swift:11-50`) — that's the bar the rest of the
  app should hit.
- Onboarding permission polling auto-refreshes, so the System Settings
  round-trip doesn't dead-end (`PermissionsOnboardingView.swift:575-587`).

---

*Method: read the live UI surfaces (Overlay, MenuBar, Settings, onboarding,
meeting capture) plus README positioning. Findings are code-grounded; the
prioritization is a judgment call about activation and trust impact, not a
usability test. The fastest way to confirm the #1 onboarding finding is to pull
the existing `onboarding_step_viewed` / `WorkflowAbandoned` funnel.*
