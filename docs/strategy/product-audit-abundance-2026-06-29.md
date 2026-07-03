# Product audit — the abundance read (2026-06-29)

A fresh product pass over `main`, written to *add to* the existing strategy
work, not repeat it. Read these first; this doc assumes them and builds past:

- `docs/strategy/SYNTHESIS-2026-06-14.md` — the moat/pitch/refactor convergence
- `docs/strategy/growth-positioning-2026-06-14.md` — "memory for your AI agent"
- `docs/strategy/codebase-architecture-health-2026-06-14.md` — the god objects
- `docs/NEXT_WORK.md` — the "one bet" shortlist
- `docs/FIX_ROADMAP.md` — current trust/correctness/activation fixes

## The one read

**You finished building the memory. You have not yet built the assistant.**

In the two weeks since the June 14 synthesis, the "one bet" mostly *shipped*:
structured summary fields are indexed, `list_action_items` / `list_decisions` /
`digest` exist, and extraction now runs always-on at save time (git log:
`d0cc0b3`, `cd24347`, `95791ca`, `8a7a550`). That's the moat the strategy docs
said no cloud notetaker can copy on private data. It's real and it's done.

But the entire product is still **pull**. Every gram of value requires the user
to (1) remember the memory exists, (2) open an agent, (3) phrase a question, (4)
have wired up MCP first. The cross-meeting tools are a beautiful library card
catalog that only opens when someone walks in and asks. The abundance move is
not another tool the agent *can* call — it's value that arrives *without being
asked for*. You built the index; now make it reach out.

Three things are missing between "captured" and "useful," and none of them are a
Granola-style AI-notes product (the thing the growth doc correctly says not to
build):

1. **Nothing is proactive.** No notification ever says "you have an open
   commitment." (`grep`: only `Sources/TranscriptedCore/Protocols/TranscriptNotifier.swift`
   exists; no app-level `UNUserNotification` delivery anywhere.)
2. **Nothing closes the loop to action.** Action items die as Markdown lines.
   (`grep`: zero Reminders/Things/Linear/Todoist/EventKit-reminder integration
   in `Sources/`.)
3. **Nothing kills the cold start.** A new user's library is empty, so the
   magic moment ("ask your history") returns nothing for days — and it's gated
   behind MCP setup most users skip.

## The abundance bets

Ranked by "moat you already own but aren't spending." These are *new* surface,
not on any current roadmap doc.

### 1. Make it push, not just pull — the after-meeting brief

When a meeting saves, you already extract decisions / action items / open
questions (always-on now). Today that data sits in a file. Instead: fire one
native notification — *"3 action items captured. One you also committed to on
the May 13 call is still open."* That second sentence is the whole game. It's a
**cross-meeting** statement, which is structurally impossible for any cloud
notetaker to make about your private history, and it's exactly what the index
you just shipped enables for free.

This is **not** the Granola AI-notes trap the growth doc warns against. Granola
summarizes *one* meeting prettily. This surfaces *your own commitments across
all of them* — the chief-of-staff layer, not the note-taker layer. Same engine,
opposite framing: don't compete with the agent on summaries, hand the user the
one thing only your local history can know.

Effort M. Highest-leverage unspent asset in the product. **[impact: very high]**

### 2. Close the loop — get commitments out of Markdown

Capture without action is a filing cabinet. An action item the product
extracted should be one tap from leaving: "Add to Reminders / Things / draft the
follow-up email." Apple Reminders via EventKit is fully local, zero-cloud, and
on-brand — no trust cost. This is the difference between "I have a transcript"
and "this app runs my follow-ups," which is the difference between a tool you
respect and a tool you can't quit.

Effort M (Reminders first; pluggable targets later). **[impact: high]**

### 3. Kill the cold start — magic before setup

Two compounding problems: the library starts empty, and the aha is gated behind
MCP setup (the onboarding agent step is skippable, per the UX map). Fixes:

- **Ship a tiny demo capture library** (2–3 fake meetings) so the very first
  thing a user can do is ask "what did I commit to?" and get a quoted answer —
  *before* they've recorded anything. The hero GIF promise becomes touchable on
  minute one.
- **The first real meeting auto-surfaces its own recap in-app**, no agent
  required. The brief from bet #1 *is* the proof the agent loop pays off, and it
  lands even for the user who skipped the MCP step. The agent connection then
  upgrades a value they've already felt instead of being the gate to feeling it.

This directly attacks the activation gaps `FIX_ROADMAP.md` #3/#7 name, from the
value side rather than the onboarding-copy side. Effort M. **[impact: high]**

### 4. Voice as the query channel — the "ask my history" loop, out loud

You already have all three pieces and have never connected them: dictation
(voice in), the memory index (the answer source), and MCP (the retrieval).
Wire a hotkey that lets you *speak* a question — "what did I promise Sarah this
week?" — and get the answer back from your own history. This is the demo that
breaks Hacker News, because nobody has local voice-in → answer-from-your-life.
It's the natural "Her" moment for a local-first tool, and it's a recombination
of parts you've already shipped, not new ML. (Note: there's currently no
voice-out path at all — `grep`: no `AVSpeechSynthesizer`. Text-back answer is
the cheap v1; spoken answer is the wow.)

Effort M–L. **[impact: high, spiky — this is the launch artifact]**

### 5. Local-first does not have to mean single-player

Meetings are inherently multi-person, but the product is single-player: three
people in a call each running Transcripted get three worse, siloed transcripts.
The growth doc parks "multiplayer" inside a future paid E2EE-sync tier. That
undersells it. Even without cloud, two Macs on the same call could merge speaker
labels and share a dictionary locally — and the *act of inviting a teammate so
the transcript gets better* is a product-led growth loop the current GTM (all
HN/Reddit pushes) completely lacks. The transcript improving because your
colleague also installed it is the most natural viral mechanic available, and it
seeds the eventual Team tier instead of waiting on it.

Effort L. **[impact: high, strategic — this is your distribution flywheel]**

### 6. The artifact is a growth surface you're not using

Every saved recap is a thing a person might forward to the others on the call.
A clean, shareable recap export (tasteful footer, no spam) turns the product's
own output into word-of-mouth — distribution built into the artifact, not
bolted on as a launch push. Pairs with #5: the recap you share is the invite.

Effort S–M. **[impact: med, compounding]**

## Sharp smaller wins

- **In-app history search.** Search lives in the menubar; Home has no real
  search surface (UX map + `grep`). A user who skipped MCP still deserves to
  find their own words. This is also the non-agent on-ramp to the memory.
- **`recap` / `recent_context` quality.** `NEXT_WORK.md` #2 flagged these
  returning the first 15 lines of small talk; confirm the summary-aware fix
  landed end-to-end, because it's the first thing every agent calls and it sets
  the whole first impression of the moat.
- **Batch speaker merge.** Review is row-by-row (UX map). Cleaning up a meeting
  with 6 over-segmented clusters is six round-trips.
- **Format-agreement test (Core formatter ⇄ CaptureKit parser).** Still the
  cheapest insurance in the repo — an afternoon that turns a silent CLI/MCP
  break into a red build. The synthesis flagged it; it's still unwritten.
- **Production `print()` in the speech path.** ~20 `print()` calls in
  `ParakeetEngine` / `WhisperEngine` / `LocalMeetingSummarizer` should route
  through `EventReporter`. Small, and it's leaking into the console today.

## Engineering reality check — the tax is compounding

The June 14 audit named four god objects as *the* velocity risk and said
"decompose them before they calcify." Two weeks later they are **bigger**, not
smaller:

| File | Jun 14 LOC | Now | Δ |
|------|-----------:|----:|--:|
| `TranscriptedSettingsView.swift` | 4503 | ~4948 | +445 |
| `MeetingSessionController.swift` | 3104 | ~3358 | +254 |
| `HomeView.swift` | 2559 | ~3056 | +497 |

Nobody did the refactor; the curve is bending the wrong way. This matters *now*
because **bets #1, #3, and the in-app search win all land in exactly these
files** — the after-meeting brief and Home surface live in
`TranscriptedSettingsView` / `HomeView`, the meeting-save hook lives in
`MeetingSessionController`. The synthesis already saw this collision ("the hero
move is trapped in the worst god object"). It's now more true, not less. The
recommendation stands and hardens: **carve `TranscriptedSettingsView` +
`HomeView` apart before shipping the proactive layer into them**, or the 189th
commit to a 4948-line file writes the bug.

Everything else in the architecture doc still holds: clean bones, real threading
discipline, no rot, deferred-but-real Swift 6 debt. The one delta is that the
god-object warning has started cashing the check it wrote.

## Sequencing

1. **This week, free:** in-app search + format-agreement test + `print()`→
   `EventReporter`. No god-object risk, immediate quality.
2. **The bet:** carve `TranscriptedSettingsView`/`HomeView`, then ship the
   after-meeting brief (#1) and demo library / first-meeting recap (#3) into the
   newly clean Home. This is the proactive turn — memory becomes assistant.
3. **The loop:** action export to Reminders (#2). Now the product *does* things.
4. **The launch artifact:** voice-as-query (#4) + shareable recap (#6) — the HN
   demo and its built-in invite.
5. **The flywheel:** local multiplayer (#5) — the distribution mechanic the
   current all-outbound GTM is missing, and the seed of the Team tier.

## What not to do (unchanged, worth restating)

- Don't build a Granola-style polished-summary product. The after-meeting brief
  (#1) is *commitments across your history*, not prettier notes — keep that line
  bright.
- Don't add anything that uploads transcripts or audio. Reminders/EventKit and
  local multiplayer are chosen precisely because they stay on-device.
- Don't ship the proactive layer into a 4948-line view file. Carve first.
