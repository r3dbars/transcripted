# Codebase Architecture Health — 2026-06-14

Principal-engineer deep audit of Transcripted (`main`). Read-only pass: LOC sweep,
structural reads of the heaviest files, git churn analysis, build/test-system review.
Goal is velocity, not style: what structural stuff makes the next 6 months of feature
work slow, risky, or bug-prone, and what's worth fixing.

## Executive summary

Overall health grade: **B**

Transcripted is in genuinely good shape for a native app of this size and ambition.
The hard parts — the raw-swiftc build, the CoreAudio real-time discipline, the
prebuilt-deps archive, the test runner — are deliberately engineered and well
guarded. There is almost no rot: **zero TODO/FIXME/HACK markers across ~83k LOC**,
near-zero Draft-era dead code, no reverse dependencies from the Core library into the
app shell, and a clean DI seam (`MeetingSTTAdapter`) that is exactly what the docs
promise. The build system that looks scary on paper is actually mostly self-correcting.

What pulls the grade down to a B is one concentrated, worsening problem: **a handful of
god objects that are simultaneously the largest, most-coupled, and most-frequently-edited
files in the repo.** The top four files by LOC are also the top four by commit count
since January. That correlation is the whole story — these files are change-magnets,
they create merge contention, and they're where the next feature's bug will hide. The
worst offender, `TranscriptedSettingsView.swift`, is 4503 lines and has been touched in
**187 commits since Jan** — more than 1 in 5 working days. Plus a low-grade structural
risk: the whole thing builds in **Swift 5 language mode with no strict-concurrency
checking**, so 19 `@unchecked Sendable` escape hatches are trust-me-bro, not
compiler-verified — and a Swift 6 migration is a someday-tax that gets heavier the
longer the audio threading grows.

This is **not** a debt cliff. It's a "decompose the four hot files before they
calcify, then keep shipping" situation. There is no architectural dead-end forcing a
rewrite; the seams are sound, the bones are good.

## God objects (ranked)

The decisive signal: **LOC rank ≈ git-churn rank.** Big and hot is the worst quadrant.
Churn numbers are commits touching the file since 2026-01-01.

| Rank | File | LOC | Commits | Responsibilities crammed in | Risk |
|------|------|-----|---------|------------------------------|------|
| 1 | `Sources/UI/Settings/TranscriptedSettingsView.swift` | 4503 | **187** | One `TranscriptedSettingsView` struct holding **246 private funcs/vars** and **156 `home`-prefixed members**. Renders the settings sidebar AND reimplements the entire Home surface inline (`homePage`, `homeMeetingsListSection`, `homeFailedMeetingsCard`) plus every Home action: delete/rename/retranscribe/summary/feedback/failed-meeting management. | **Critical.** Hottest file in the repo, split-brain with HomeView. Every settings/home tweak risks an unrelated section. Merge-conflict epicenter. |
| 2 | `Sources/Meeting/MeetingSessionController.swift` | 3104 | 137 | A `@MainActor` state machine with ~35 mutable private vars, including a sprawl of `liveCodex*` flags (7+ booleans coordinating one feature). Owns: permission gating, model warmup, capture start/stop, imported-audio handoff, app-level transcription queueing, local-speaker split, failed-meeting actions, mic-boost prompt, audio-inactivity, transcript restyling, live-codex sidecar coordination. | **High.** The brain of the meeting feature. Boolean-flag coordination of the live sidecar is the kind of state soup that breeds heisenbugs. |
| 3 | `Sources/Speech/ParakeetEngine.swift` | 3088 | 114 | One class spanning 7 MARK sections: model init, input readiness, recording, EOU streaming (live display), transcription, pure-sample transcription (meeting path), cleanup. Holds the CoreAudio input tap. | **High.** Mixes RT-audio lifecycle with two distinct transcription paths (dictation streaming + meeting pure-sample). Touching one path risks the other. |
| 4 | `Sources/UI/Settings/HomeView.swift` | 2559 | 96 | `HomeViewModel` + ~13 `Home*` value/view types + 26 view structs. The *other half* of Home, paralleling the home logic that also lives in #1. | **High.** Split-brain with #1: home logic spread across two 2.5k–4.5k-line files that move together (187 + 96 commits). |
| 5 | `Sources/UI/Overlay/MeetingOverlayController.swift` | 2525 | 41 | Panel + root view + pill body + design tokens + controller + state + subscriptions + rest/wake + context menu + view-push, all in one file (16 MARK sections, multiple top-level types). | **Medium.** Large but cohesive (it's one feature surface). Lower churn than 1–4. |
| 6 | `Sources/TranscriptedCore/Pipeline/TranscriptionTaskManager.swift` | 1524 | 55 | Task queue + lifecycle + orphaned-recording recovery + completion/cleanup. | **Medium.** Large but decomposed by clear responsibility across the 3-file pipeline (`TaskManager` + `Pipeline` 1027 + `Runner` 884). Reasonable. |
| 7 | `Sources/TranscriptedCore/Speaker/RetroactiveSpeakerUpdater.swift` | 1999 | 33 | Retroactive transcript rewriting on speaker rename/merge. | **Low-med.** Big but bounded domain, lower churn, has direct SPM test coverage. |

The pattern: **everything in rows 1–4 is in the big-and-hot quadrant.** Rows 5–7 are big
but cooler or better-bounded. Fix 1–4 and the velocity tax mostly evaporates.

## Build / test system assessment

Verdict: **the raw-swiftc build is worth its constraints and should NOT be migrated.**
It's the single most over-feared thing in the repo. The actual footguns are narrower
than the lore suggests.

### What's actually fine (debunking the lore)

- **Adding a new app source file is zero-friction.** The app build
  (`scripts/entrypoints/lib/swiftc-app-args.sh:68-72`) globs
  `find Sources -name '*.swift' -not -path 'Sources/TranscriptedCore/*'`. New files are
  auto-discovered. The "you must manually register sources" fear does NOT apply to the
  main build.
- **The fast-test runner is well-guarded, not brittle.** `run-tests.sh` explicitly
  diffs `Tests/FastTests.manifest` against `find Tests` and **fails with a precise
  message** if they drift (`scripts/entrypoints/run-tests.sh:108-131`). It catches
  manifest typos *before* swiftc with a targeted error
  (`...:201-213`), and prints a "check the manifest before chasing swiftc output"
  banner on compile failure (`...:446-449`). 126 manifest entries currently match 126
  root test files exactly. This is good scaffolding. The failure mode is a clear error,
  not a silent skip.
- **Build correctness guards are strong.** Deps-staleness detection by mtime
  (`build.sh:85-128`), a launch UI smoke that boots the signed app and asserts menubar
  structure (`build.sh:160-323`), a performance budget gate (`:522-527`), and a shared
  `swiftc-app-args.sh` so dev and beta builds **cannot diverge** on
  frameworks/linker/sources — the header comment notes they HAD diverged once and this
  fixed it. That's mature.

### The real, narrow footguns

1. **`run-e2e-smoke.sh` has a hand-curated 34-entry `SWIFT_SOURCES` list**
   (`scripts/entrypoints/run-e2e-smoke.sh:33-68`). This is the one place the "add your
   file manually" gotcha is real: if a listed source grows a new dependency, you must
   add it by hand or get a cryptic swiftc error. Documented, but still a per-change
   trap when touching the e2e-covered storage/sanitizer paths.
2. **A new *root* test file must be registered in the manifest.** Friction is real but
   the runner tells you exactly what to do. One-line fix when it bites.
3. **Whole-module `-O` build is all-or-nothing.** `build.sh:468-476` compiles every app
   source in one `swiftc` invocation with WMO. No incremental object caching for the app
   target — every app build is a full rebuild. As `Sources/UI` (29.5k LOC) grows, app
   build time grows monotonically. Not a correctness issue, a wall-clock tax. The
   god-object files make this worse (one giant file = one giant type-check unit).

### Test architecture

The strategy is **"extract pure policy → unit-test the policy → leave a thin shell."**
It works beautifully for the small policy types (`MeetingRecordingStartGate`,
`MeetingFailureKind`, `STTRouterPolicy`, etc.) — 126 fast tests + 45 Core SPM tests,
mostly fast and deterministic. But the shells aren't thin: the god objects are
3000–4500 lines, so a lot of *orchestration* behavior lives in untested code. God-object
references in tests are mostly to *extracted helper types*
(`MeetingSessionController.FailedMeetingItem`), not the controller's wiring logic.

Coverage gaps (the strategy doc already flags these, and the numbers confirm):

- **SwiftUI rendering: essentially zero.** Only 4 of 126 root tests touch a View type,
  and those are contract checks, not render tests. The 7k+ LOC of Settings/Home view
  code is verified only by the launch smoke's structural assertions.
- **Real-audio path: 2 integration + 2 e2e tests**, gated behind `run-live-capture-smoke`
  which needs hardware/TCC. The RT-callback and device-recovery logic — the riskiest
  code in the app — is largely manual-QA-verified.

## Boundary, threading, concurrency findings

### Core library boundary — mostly clean, one aspirational claim

- **The DI seam is exactly right.** `MeetingSTTAdapter.swift` is a 63-line protocol
  adapter from the app's `STTRouter` to `TranscriptedCore.SpeechToTextEngine`. Textbook.
- **No reverse dependency.** Core never imports app modules. The one layering nit:
  `Sources/TranscriptedCore/Audio/Audio.swift:4` imports **AppKit** — but only for
  `NSWorkspace` sleep/wake notifications (`:694`, `:704`). Narrow and macOS-justified;
  it just means Core isn't truly platform-portable. Acceptable.
- **The "consumed only through `Sources/Meeting/`" claim is aspirational, not enforced.**
  `Sources/UI/` (11 files), `Sources/Speech/ParakeetEngine.swift`, and
  `Sources/Dictation/` all `import TranscriptedCore` directly and use its public types
  (SpeakerProfile, scanners, RecentMeetingItem, etc.) without going through the Meeting
  bridge. This is reaching *public model* types, not internals, so it's a soft leak, not
  a rot — but the doc overstates the discipline. Real risk: a Core public-API change now
  ripples into UI directly, defeating the point of the bridge.
- **Format-mirror duplication with no cross-validation test.** Core's
  `TranscriptFormatter`/`TranscriptFrontmatter` and `Tools/TranscriptedCaptureKit`'s
  `CaptureMarkdownParser` independently implement the same Markdown contract. Each has
  its own tests; **nothing asserts they agree.** The only guard is a CLAUDE.md note
  saying "update both in the same change." That's discipline-only — a real drift risk
  for the CLI/MCP tools the moment someone changes the saved format and forgets.

### Threading — discipline is genuinely held

The CoreAudio real-time rules are respected where it counts. The raw IOProc in
`SystemAudioProcessTap.swift:104-139` is exemplary: no-copy `AVAudioPCMBuffer` wrapper,
`CACurrentMediaTime()` (allocation-free) for the watchdog, no logging in the hot path,
and an explicit comment (`:99-103`) documenting that the only locks are short stat-counter
increments and "anything heavier must be deferred." The engine taps
(`ParakeetEngine.swift:1464`, `Audio.swift:1261`, `AudioFileManager.swift:305`) follow the
same `[weak self]` no-blocking-work pattern. This is the part of the codebase I'd trust
most.

### Concurrency — Swift 5 mode, hand-audited Sendable

The structural risk. **The whole app builds in Swift 5 language mode**: `Package.swift` is
`swift-tools-version: 5.9` with `swiftSettings` containing only `-F`/`-I` framework paths
— **no `.enableUpcomingFeature("StrictConcurrency")`, no Swift 6 mode** — and the
raw-swiftc build sets no strict-concurrency flag either. So the **19 `@unchecked Sendable`**
declarations (incl. `Audio`, `SpeakerDatabase`, `SCKAudioCapture`, `FileLogger`,
`AppLogger`, several in `LocalMeetingSummarizer`) are programmer promises the compiler is
**not** checking. Each is plausibly correct today (most wrap an internal lock/queue), but:

- There is no compiler net catching a *new* data race introduced next to one of these.
- A Swift 6 migration is inevitable and gets more expensive every month the audio +
  meeting-session concurrency surface grows. Doing it after #1–#4 are decomposed will be
  far cheaper than doing it now against 3000-line `@MainActor` god objects.

No global mutable state of concern: the `static var` sweep is almost entirely computed
URL/string getters; the one mutable static (`MeetingSessionController.runtimeDiagnosticsRecorder`)
is a test seam. `nonisolated(unsafe)` appears only 5 times. Good.

## Debt inventory (ranked)

1. **God-object concentration (1–4 above).** Biggest + hottest + most-coupled files.
   The velocity tax. *Everything else is a footnote next to this.*
2. **Settings/Home split-brain.** Home logic lives in BOTH
   `TranscriptedSettingsView.swift` (156 home-prefixed members, reimplements home
   inline — does NOT embed `HomeView`) and `HomeView.swift`. Two huge files that move
   together. Duplicated surface, doubled change cost.
3. **Swift 5 mode + 19 unchecked-Sendable.** No compiler net for data races; deferred
   Swift 6 migration debt that compounds.
4. **Format-mirror drift risk.** Core formatter vs CaptureKit parser, no agreement test.
   Will silently break CLI/MCP tools on a format change.
5. **e2e-smoke curated source list.** 34 hand-listed files; the one real "add it
   manually" footgun.
6. **App build is full-rebuild WMO.** Wall-clock tax that grows with UI LOC; amplified
   by god-object type-check units.
7. **Soft Core boundary leak.** UI/Speech/Dictation import Core directly; the
   "Meeting-only" claim isn't enforced.
8. **Thin UI + real-audio test coverage.** Documented; the riskiest code is manual-QA.

Notably absent from this list: dead code, Draft-era rot, circular deps, reverse
dependencies. The repo is clean on all of those. (`OverlayDraftingView`, `CorrectionDraftRow`,
and `libDraftDeps.a` are legacy *names*, not legacy *code* — the archive `-O` is the
prebuilt deps + Core objects, just historically named.)

## The #1 highest-ROI refactor

**Decompose `TranscriptedSettingsView.swift` + collapse the Settings/Home split-brain.**

Why this one: it is the single hottest file in the entire repo (187 commits since Jan),
it's 4503 lines, and it *duplicates* the responsibility of the 4th-hottest file
(`HomeView.swift`, 96 commits). Fixing it kills the worst merge-contention point AND the
worst split-brain in one move. Every settings or home feature for the next 6 months
routes through this file today; cutting it down is leverage on essentially all near-term
UI work.

Concrete shape:
- Extract each settings page (`homePage`, `dictationsPage`, etc.) into its own `View`
  file with a focused view-model. The `private var <thing>Page: some View` members are
  already the natural seams.
- Pull the ~156 `home*` members and Home action handlers (delete/rename/retranscribe/
  summary/feedback/failed-meeting) out of the settings struct and unify them with the
  existing `HomeViewModel` in `HomeView.swift` — one Home owner, not two.
- Leave `TranscriptedSettingsView` as a thin shell: sidebar + page routing.

Effort: **L** (3000+ lines of UI to carve, but mechanical — extract-and-route, low
algorithmic risk; the launch UI smoke + 6 existing test files give a safety net).
Velocity payoff: **very high.** Removes the #1 and #4 change-magnets, eliminates the
split-brain, and makes the most-edited area of the app safe to touch in parallel. Also
shrinks the worst WMO type-check unit, helping build time.

## Ranked remediation moves

1. **Decompose `TranscriptedSettingsView` + unify Home.** `[effort: L]` `[risk: med]`
   `[payoff: very high]` — The #1 refactor above. Do this first. Med risk only because
   it's a lot of UI surface; mitigated by the launch smoke and existing tests.

2. **Split `MeetingSessionController` along its seams.** `[effort: L]` `[risk: med]`
   `[payoff: high]` — Extract the live-codex sidecar coordination (the 7+ `liveCodex*`
   booleans) into its own `@MainActor` coordinator, and the app-level transcription
   queue into a dedicated queue object. Leaves a smaller session state machine. Kills
   the 2nd change-magnet and the worst boolean-flag soup.

3. **Add a Core-formatter ⇄ CaptureKit-parser agreement test.** `[effort: S]`
   `[risk: low]` `[payoff: med-high]` — One golden-fixture round-trip test: format a
   transcript with Core, parse it with CaptureKit, assert equality. Cheap insurance that
   turns a silent CLI/MCP-breaking drift into a red build. Highest ROI-per-hour on the
   list.

4. **Carve dual transcription paths out of `ParakeetEngine`.** `[effort: M]`
   `[risk: med]` `[payoff: high]` — Separate the streaming-dictation path from the
   pure-sample meeting path so a change to one can't break the other. Keep the RT tap
   lifecycle in a focused core; the discipline there is good, don't disturb it.

5. **Plan (don't yet execute) the Swift 6 migration; gate it on #1–#4.** `[effort: L]`
   `[risk: high if done now]` `[payoff: high, deferred]` — Turn on
   `StrictConcurrency` warnings in CI as a *non-blocking* signal now to measure the
   surface, then migrate after the god objects shrink. Doing it against 3000-line
   `@MainActor` files first would be brutal; sequencing it after #1–#4 makes it
   tractable. Each `@unchecked Sendable` becomes a verified or fixed claim.

6. **Make the Core boundary real or drop the claim.** `[effort: M]` `[risk: low]`
   `[payoff: med]` — Either route UI's Core access through Meeting-owned view-model
   types, or update the docs to say "Core public types are app-wide, Meeting owns the
   *pipeline* seam." Today the doc oversells the enforcement; pick one and make it true.

7. **Auto-generate the e2e-smoke source list (or shrink its surface).** `[effort: S]`
   `[risk: low]` `[payoff: low-med]` — Replace the hand-curated 34-entry list with a
   dependency-driven include where feasible, removing the one real "add it manually"
   footgun.

8. **Add a few SwiftUI snapshot/contract tests for the new extracted Home views.**
   `[effort: M]` `[risk: low]` `[payoff: med]` — Best done *after* #1, when the views are
   small enough to test. Closes the biggest coverage gap on the most-edited surface.

## Ship vs pay down — the call

**Keep shipping — but make moves #1–#3 the price of admission for the next big UI bet.**

There's no debt cliff and no architectural dead-end forcing a pause. The build, the
boundaries, the threading discipline, and the absence of rot all say "this team can keep
moving." The risk is narrow and named: four god objects that are getting bigger and
hotter every week. They won't cause a crisis next month, but every feature shipped
*into* them without decomposing makes the eventual carve harder and the Swift 6 migration
worse.

Recommended sequencing: ship #3 (the format-agreement test, an afternoon) immediately as
free insurance. Then, before or alongside the next significant Settings/Home feature, do
#1 — don't add the 188th commit to a 4503-line file. Tackle #2 when the next meeting
feature lands. Treat #5 (Swift 6) as a tracked, deferred item gated on #1–#4. That keeps
feature velocity high while bending the god-object curve down instead of up.
