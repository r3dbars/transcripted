# Dayflow-style Timeline: full integration plan

Status: planning — approved for implementation handoff
Owner: Justin (r3dbars)
Branch: `claude/dayflow-transcripted-integration-5h019m`
Written: 2026-07-03

## What we are building

Transcripted gains a Dayflow-style screen-activity timeline as its **new home screen**. The app
continuously captures lightweight screenshots, analyzes them with a local-first LLM pipeline into
activity cards, and renders a vertical day timeline where those cards sit **alongside Transcripted's
meetings and dictations** — one merged view of the day: what you did, what you said, what was decided.

Reference implementation: [Dayflow](https://github.com/JerryZLiu/Dayflow) (MIT, macOS 14+, SwiftUI).
We are rebuilding its capture pipeline, analysis pipeline, and primary views natively inside
Transcripted's architecture — not vendoring its code wholesale — but implementers MAY port individual
routines where that is faster. Any ported code requires the attribution step in Phase 0.

What Transcripted adds that Dayflow doesn't have: meeting/dictation cards inline on the timeline
(with transcripts, decisions, action items), agent-readable daily timeline Markdown in the capture
library, and MCP/CLI access to the merged day.

### Non-goals (v1)

- No cloud-hosted "Pro" backend, sign-in, referral, or paywall/feature-gating mechanics from Dayflow.
- No ChatGPT/Claude-CLI analysis provider in v1 (Phase 9 stretch; complex process/session plumbing).
- No journal/day-goals/confetti surface in v1 (Phase 9 stretch).
- No change to dictation paste-back, meeting capture, or `Sources/TranscriptedCore/` boundaries.
- Screenshots and screen-derived text NEVER leave the device unless the user explicitly configures a
  cloud provider (Gemini) — and even then, nothing screen-derived ever goes to Sentry/PostHog.

## Ground rules (read before writing any code)

1. **Build system**: app sources are auto-discovered by
   `scripts/entrypoints/lib/swiftc-app-args.sh` (`find Sources -name '*.swift'` excluding
   `Sources/TranscriptedCore/`). New dirs `Sources/Timeline/` and `Sources/UI/Timeline/` need **no
   build-script edits**. Do NOT put timeline code in `Sources/TranscriptedCore/` — Core is a strict
   library boundary for meeting transcription only.
2. **SQLite, not GRDB**: `-lsqlite3` is already linked (`swiftc-app-args.sh`). Follow the raw
   `import SQLite3` pattern of `Sources/TranscriptedCore/Stats/StatsDatabase.swift` /
   `Speaker/SpeakerDatabase.swift`. Do not add GRDB or any new SPM dependency — the bespoke build
   makes new deps expensive and nothing here needs one.
3. **Storage split**: DB + screenshots are app-owned state under
   `~/Library/Application Support/Transcripted/` (0700 dirs / 0600 files via the existing
   `createPrivateDirectory` helpers). Only human/agent-readable Markdown summaries go to the
   relocatable capture library. Update `docs/storage-paths.md` in the same PR as any new path.
4. **Privacy contract**: allowlists in `Sources/Observability/AnalyticsEventPolicy.swift`
   (data-driven from `Resources/analytics-events.psv`) and `SentryEventPolicy.swift` (Swift dict).
   New analytics events carry ONLY bucketed counts/durations/booleans — never titles, summaries,
   OCR text, app names, URLs, or paths. `Tests/AnalyticsEventPolicyTests.swift` enforces banned
   fragments; run `python3 scripts/ops/normalize-analytics-taxonomy.py` after editing the psv, and
   keep `docs/privacy-first-observability.md` in sync (the test asserts doc/psv parity).
5. **Threading**: capture + analysis run off-main (dispatch queue / actor). All UI state is
   `@MainActor`. No CoreAudio involvement here, so the real-time-callback rules don't apply, but
   keep screenshot encode + DB writes off the main thread always.
6. **Preferences pattern**: one `*Preferences` enum per concern in `Sources/Support/`, wrapping
   `UserDefaults.standard` with a key constant + `NotificationCenter` change notification (see
   `DockVisibilityPreferences` as the template).
7. **Fast tests**: new root `Tests/*Tests.swift` files MUST be registered in
   `Tests/FastTests.manifest` as `<File.swift>:<entryFunction>`; they are free functions using
   `runSuite`/`assertEqual`, not XCTest. `scripts/dev/check-build-source-lists.py` fails on drift.
8. **Verification per phase**: minimum `bash build.sh --no-open` + `bash run-tests.sh`. Phases
   touching E2E sources also run `python3 scripts/dev/check-build-source-lists.py` +
   `bash run-e2e-smoke.sh`. Add a `Sources/Timeline/**` rule to `.agents/test-matrix.yml` in Phase 0.
9. **Docs in lockstep**: `docs/repo-layout.md`, `Sources/CLAUDE.md`, root `CLAUDE.md` subsystem
   table, and new local `CLAUDE.md` files for `Sources/Timeline/` and `Sources/UI/Timeline/` are
   updated in the phase that creates each thing, not "later".
10. **Visual evidence**: UI phases include sanitized screenshots under `.agent-review/visuals/`
    per the PR template.

## Architecture overview

```
Sources/Timeline/                     (new subsystem — engine, no UI)
  ScreenCaptureEngine.swift           SCScreenshotManager loop, pause/resume state machine
  ActiveDisplayTracker.swift          which display gets captured
  InputIdleSnapshot.swift             CGEventSource idle seconds
  ForegroundAppSampler.swift          NSWorkspace frontmost app + window title per shot
  TimelineDatabase.swift              raw SQLite3 store (state/timeline.sqlite)
  TimelineRetentionManager.swift      size-capped oldest-first purge
  AnalysisScheduler.swift             60s tick, batch creation, idle shortcut
  BatchPlanner.swift                  pure batching rules (unit-tested)
  ObservationBuilder.swift            Vision OCR + app metadata → observations
  CardGenerator.swift                 observations → activity cards (45-min lookback, atomic replace)
  TimelineLLMProvider.swift           provider protocol + shared plumbing
  Providers/LocalFoundationProvider.swift    default: on-device (FoundationModels / Gemma MLX path)
  Providers/OllamaProvider.swift             localhost OpenAI-compatible (Ollama/LM Studio)
  Providers/GeminiProvider.swift             opt-in cloud, key in Keychain
  TimelineCategoryStore.swift         categories in UserDefaults JSON
  TimelineCaptureJoiner.swift         meetings/dictations → timeline entries
  TimelineMarkdownWriter.swift        daily timeline .md into capture library
  TimelineDayBoundary.swift           4 AM logical-day math (unit-tested)

Sources/UI/Timeline/                  (new UI surface, rendered inside the existing settings window)
  TimelineHomeView.swift              day canvas (the new home page)
  TimelineCanvasCard.swift            card block on the canvas
  TimelineDetailPanel.swift           right-hand card detail
  TimelineLiveStatusCard.swift        "generating…" / paused / resume card at now
  TimelineDayNavigation.swift         date pills + calendar popover
  ScreenshotSlideshowView.swift       full-screen screenshot playback + scrubber
  TimelineWeekGridView.swift          week mode (Phase 7)
  TimelineDashboardView.swift         weekly analytics (Phase 7)
  TimelineChatView.swift              chat over the day (Phase 8)
  CategoryPickerView.swift            category swap overlay
  TimelineTokens.swift                surface design tokens (pattern: MenuTokens.swift)

Sources/Support/                      (additions)
  TimelinePreferences.swift           master toggle, provider choice, storage cap, blocklist
  TranscriptedPermissionKind.swift    + .screenRecording case
```

Data flow: `ScreenCaptureEngine` (10s) → `timeline.sqlite screenshots` → `AnalysisScheduler` (60s)
→ `BatchPlanner` → `ObservationBuilder` (local OCR+metadata) → `CardGenerator` via provider →
`timeline_cards` → UI + `TimelineMarkdownWriter` → capture library → MCP/CLI.

## Data model (`state/timeline.sqlite`, WAL mode)

```sql
CREATE TABLE screenshots (
  id INTEGER PRIMARY KEY,
  captured_at INTEGER NOT NULL,          -- unix seconds
  file_path TEXT NOT NULL,               -- relative to screenshots root
  file_size INTEGER NOT NULL,
  idle_seconds_at_capture REAL NOT NULL,
  app_bundle_id TEXT,                    -- ForegroundAppSampler
  app_name TEXT,
  window_title TEXT,
  display_id INTEGER,
  is_deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_screenshots_captured ON screenshots(captured_at);

CREATE TABLE analysis_batches (
  id INTEGER PRIMARY KEY,
  batch_start_ts INTEGER NOT NULL,
  batch_end_ts INTEGER NOT NULL,
  status TEXT NOT NULL,                  -- pending|processing|analyzed|failed|failed_empty|skipped_short
  failure_reason TEXT,
  provider TEXT,
  created_at INTEGER NOT NULL
);
CREATE TABLE batch_screenshots (batch_id INTEGER, screenshot_id INTEGER,
  PRIMARY KEY(batch_id, screenshot_id));

CREATE TABLE observations (
  id INTEGER PRIMARY KEY,
  batch_id INTEGER NOT NULL,
  start_ts INTEGER NOT NULL,
  end_ts INTEGER NOT NULL,
  observation TEXT NOT NULL,             -- local text; never leaves device unless cloud provider chosen
  llm_model TEXT
);

CREATE TABLE timeline_cards (
  id INTEGER PRIMARY KEY,
  batch_id INTEGER,
  day TEXT NOT NULL,                     -- 'YYYY-MM-DD' keyed to 4 AM boundary
  start_ts INTEGER NOT NULL,
  end_ts INTEGER NOT NULL,
  kind TEXT NOT NULL DEFAULT 'activity', -- activity|meeting|dictation|idle
  capture_id TEXT,                       -- links kind=meeting/dictation to capture-library artifact
  title TEXT NOT NULL,
  summary TEXT NOT NULL,
  detailed_summary TEXT,
  category TEXT NOT NULL,
  subcategory TEXT,
  app_sites_json TEXT,                   -- {"primary": "...", "secondary": "..."}
  distractions_json TEXT,                -- [{startTime,endTime,title,summary}]
  is_deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_cards_day ON timeline_cards(day);

CREATE TABLE llm_calls (
  id INTEGER PRIMARY KEY, batch_id INTEGER, provider TEXT, model TEXT,
  operation TEXT, status TEXT, latency_ms INTEGER, created_at INTEGER,
  request_body TEXT, response_body TEXT   -- truncate both at 64 KB
);

CREATE TABLE chat_conversations (id INTEGER PRIMARY KEY, day TEXT, title TEXT, created_at INTEGER);
CREATE TABLE chat_messages (id INTEGER PRIMARY KEY, conversation_id INTEGER, role TEXT,
  content TEXT, tool_calls_json TEXT, created_at INTEGER);
```

Screenshots on disk: `~/Library/Application Support/Transcripted/recordings/screenshots/YYYY-MM-DD/<epoch-ms>.jpg`
(0700/0600). Meeting/dictation cards are projections — source of truth stays the capture-library
Markdown; `capture_id` joins back to it.

## Dayflow parity constants (use these exact values)

| Constant | Value |
|---|---|
| Screenshot cadence | 10 s |
| Screenshot format | JPEG q0.85, scaled to 1080 px height, aspect-fit, even dimensions, cursor shown |
| Batch target duration | 15 min (900 s) |
| Batch gap split | > 120 s gap starts a new batch |
| Minimum batch | < 300 s → `skipped_short` |
| Scheduler tick | 60 s; lookback 24 h |
| Card regen lookback | 45 min (2700 s), atomic `replaceTimelineCardsInRange` |
| Card duration rules | min 10 min (fold into neighbor), max 60 min (split at focus shift), no gaps/overlaps, merge-biased |
| Idle rules | fully-idle batch skips LLM → single Idle card, merged with adjacent idle card if gap small; category Idle only if idle > 50% of window |
| Logical day boundary | 4:00 AM |
| Local-provider frame sampling | ~15 evenly spaced frames, ≤720 px, base64 JPEG |
| Timeline canvas | vertical, 4 AM → 4 AM, ~60 px/hour, card height ∝ duration, min 10 px, 2 px gap |
| Card entrance | ~30 ms staggered fade/slide; hover scale 1.01 |
| Resume delays | 5 s after wake, 0.5 s after unlock/screensaver end |
| Retention purge | hourly; oldest-first when over user cap; soft-delete flag before file removal; ≤500 files/pass |
| Default categories | Work `#B984FF`, Personal `#6AADFF`, Distraction `#FF5950`, Idle `#A0AEC0` + Transcripted adds Meetings (pick a teal from TimelineTokens) |

Card generation prompt rules to carry over verbatim in spirit: write "as if you ARE the person
jotting notes about their day"; "DEFAULT TO MERGING — two 15-minute cards about the same work
stream should almost never exist"; new card only when core intent changed for 10+ minutes;
distraction = brief (<5 min) unrelated interruption inside a card, and "googling an error message
while debugging isn't a distraction"; category prompt returns exactly one allowed label, verbatim,
with case-insensitive normalization + fallback to first category on mismatch.

---

## Phase 0 — Scaffolding, permission, prefs, attribution

1. Create `Sources/Timeline/` + `Sources/UI/Timeline/` with local `CLAUDE.md` files (scope, file
   list, threading notes). Add both to the subsystem tables in root `CLAUDE.md`, `Sources/CLAUDE.md`,
   and `docs/repo-layout.md`.
2. `Sources/Support/TimelinePreferences.swift`: keys `timelineEnabled` (default **false** until
   onboarding opt-in), `timelineProvider` (`localFoundation|ollama|gemini`, default
   `localFoundation`), `timelineOllamaEndpoint` (default `http://localhost:1234`),
   `timelineStorageCapBytes` (default 5 GB), `timelineBlockedBundleIDs` (JSON array),
   `timelineOnboardingCompleted`. Notification per key change, per house pattern.
3. Permission: add `.screenRecording` to `Sources/Support/TranscriptedPermissionKind.swift`
   (icon, title, summary, action copy; NOT `isRequiredOnFirstLaunch`) and status/prompt/deep-link
   support in `TranscriptedPermissionAccess.swift`. Note: this is the FULL Screen Recording TCC
   tier, distinct from the existing `systemAudioRecording` tier. Update
   `NSScreenCaptureUsageDescription` in `Info.plist` to cover screen pixels for the timeline, not
   just system audio. macOS periodically re-prompts for screen-recording apps — the engine must
   treat revocation as a pause state, not a crash (Phase 1).
4. Attribution: add `THIRD_PARTY_NOTICES.md` (or extend if one exists) with Dayflow's MIT copyright
   + license text, noting the timeline subsystem is derived from Dayflow. Required if any code is
   ported; do it unconditionally — it's honest and costs nothing.
5. `.agents/test-matrix.yml`: add rule — touched `Sources/Timeline/**` or `Sources/UI/Timeline/**`
   → `bash build.sh --no-open` + `bash run-tests.sh` (+ e2e smoke once Phase 6 wires artifacts).
6. `docs/storage-paths.md`: document `state/timeline.sqlite`, `recordings/screenshots/`, and the
   future `captures/timeline/` Markdown dir.

Acceptance: `bash build.sh --no-open` green with empty scaffolding types;
`python3 scripts/dev/check-build-source-lists.py` green; `scripts/dev/agent-preflight.sh` output
reflects the new matrix rule.

## Phase 1 — Screen capture engine

Files: `ScreenCaptureEngine.swift`, `ActiveDisplayTracker.swift`, `InputIdleSnapshot.swift`,
`ForegroundAppSampler.swift`.

1. `ScreenCaptureEngine` (final class, own serial `DispatchQueue`): `DispatchSourceTimer` at 10 s.
   Each tick: `SCShareableContent` → pick display (requested → active → first), build
   `SCContentFilter` excluding windows of `timelineBlockedBundleIDs` apps, capture via
   `SCScreenshotManager.captureImage(contentFilter:configuration:)` with `scalesToFit`, cursor on,
   1080 px target height (even-rounded). Encode JPEG q0.85 off-main, write file, insert
   `screenshots` row with `InputIdleSnapshot.currentIdleSeconds()` (CGEventSource) and the
   `ForegroundAppSampler` snapshot (frontmost app bundle id/name + window title via CGWindowList —
   accessibility permission already granted for dictation, but degrade to app-only if title
   unavailable).
2. State machine `idle → starting → capturing → paused(reason)` with reasons: sleep, screen lock,
   screensaver, permission revoked, user pause. Subscribe to
   `NSWorkspace.willSleepNotification`/`didWakeNotification`,
   `com.apple.screenIsLocked`/`Unlocked` (distributed), screensaver notifications. Resume delays
   5 s / 0.5 s per parity table. Coordinate with `Sources/Reliability/` wake-recovery patterns —
   reuse its observers if exposed, otherwise mirror them; do not double-subscribe.
3. Permission revocation (macOS re-approval nag): a failed capture with a TCC error transitions to
   `paused(.permissionRevoked)` and posts a needs-attention state the UI surfaces (Phase 5). Never
   tight-loop retries; probe once per minute.
4. Ownership: `TranscriptedAppState` owns a lazy `TimelineEngineController` (new, `@MainActor`
   facade in `Sources/Timeline/`) that starts the engine iff `timelineEnabled` &&
   onboarding done && permission granted.
5. Local observability: `EventReporter` info events `timeline.capture_started/paused/resumed`,
   error `timeline.capture_failed` (reason tag only). No analytics yet.

Tests (fast, `Tests/TimelineCaptureTests.swift` + manifest entry): state-machine transitions,
resume-delay policy, blocklist filter set construction, even-dimension scaling math. Pure logic
only — no SCK in fast tests.

Acceptance: build + fast tests green; manual: run app with flag on, confirm JPEGs + rows appear at
10 s cadence, pause on lock, resume after unlock, CPU < 5% average on Apple Silicon.

## Phase 2 — Database, retention, storage cap

Files: `TimelineDatabase.swift`, `TimelineRetentionManager.swift`.

1. `TimelineDatabase`: raw SQLite3 following `StatsDatabase.swift` (serial queue, WAL,
   `PRAGMA busy_timeout`, schema-version table + forward-only migrations). All statements
   prepared/finalized; no string-interpolated SQL.
2. `TimelineRetentionManager`: hourly timer. When `recordings/screenshots/` total exceeds
   `timelineStorageCapBytes`: soft-delete oldest `screenshots` rows (batch ≤500), delete files,
   then hard-delete rows; also purge orphaned files with no row. Never touch screenshots belonging
   to batches currently `processing`. Daily `VACUUM`-lite: WAL checkpoint; DB backup optional (skip
   Dayflow's backup scheme in v1 — our DB is rebuildable from nothing).
3. Storage settings surface (minimal, extends `Sources/UI/Settings/` storage page): usage readout +
   cap slider + "Delete all screen recordings" destructive action (deletes files + DB rows,
   keeps cards).

Tests (`Tests/TimelineDatabaseTests.swift`): migrations idempotent, insert/query round-trip,
retention picks oldest-first and respects the processing guard, cap math. Use a temp-dir DB.

Acceptance: build + fast tests green; fill disk past cap in a manual run and watch purge behave.

## Phase 3 — Analysis pipeline (batches → observations → cards)

Files: `AnalysisScheduler.swift`, `BatchPlanner.swift`, `ObservationBuilder.swift`,
`CardGenerator.swift`, `TimelineDayBoundary.swift`, `TimelineCategoryStore.swift`.

1. `BatchPlanner` (pure, injectable clock): groups unbatched screenshots per parity table
   (120 s gap split, 15 min target, defer trailing short batch, `skipped_short` < 300 s).
2. Idle shortcut: batch where every screenshot has `idle_seconds_at_capture` ≥ threshold (60 s)
   → create/merge Idle card directly, mark `analyzed`, skip LLM.
3. `ObservationBuilder` (actor): for a batch, sample ~15 evenly spaced screenshots; per frame run
   Vision `VNRecognizeTextRequest` (fast level) + attach the stored app/window metadata; condense
   per-frame text to a bounded description (top N lines, dedup consecutive); merge into 2–5
   segments `{startTs, endTs, observation}` covering ≥80% of the window. This gives every provider
   — including the pure-local default — grounded text without needing a VLM.
4. `CardGenerator` (actor): pull observations + existing cards in the 45-min lookback window,
   build the card prompt (rules above, categories from `TimelineCategoryStore.descriptorsForLLM()`),
   call provider, validate/normalize JSON (`ActivityCardData` mirror of Dayflow's schema), clamp
   times, enforce no-gap/no-overlap, then atomically `replaceTimelineCardsInRange(start,end,day)`
   in one transaction. Meeting/dictation cards (kind != activity) are NEVER replaced by regen —
   range replacement filters `kind = 'activity' OR kind = 'idle'`.
5. `AnalysisScheduler` (actor): 60 s tick; single-flight; statuses per parity table; two-tier
   provider fallback (configured provider → `LocalFoundationProvider`); failure classification
   (rate-limit detect: HTTP 429/403 or "quota"/"rate limit"/"too many requests"); per-day throttled
   failure surfacing; `reprocessDay(day)` + `reprocessBatch(id)` (delete cards+observations, reset
   to pending).
6. Providers:
   - `TimelineLLMProvider` protocol: `func generateObservations(...)` (optional — default uses
     `ObservationBuilder` output as-is) + `func generateCards(observations:context:) async throws -> [ActivityCardData]`.
   - `LocalFoundationProvider` (default, zero-config): Apple FoundationModels on macOS 26 with the
     Gemma-MLX path as fallback — reuse the exact stack/pattern of
     `Sources/Meeting/LocalMeetingSummarizer.swift` (it already routes FoundationModels/Gemma MLX).
     Text-only: consumes `ObservationBuilder` segments, never images.
   - `OllamaProvider`: OpenAI-compatible localhost endpoint; can optionally send the ≤720 px
     sampled frames for VLM-grade observations (engine presets: ollama/lmstudio/custom).
   - `GeminiProvider`: opt-in; user API key stored in **Keychain** (add a small
     `TimelineKeychain` helper; do not put keys in UserDefaults); sends sampled frames (not video
     in v1 — frame batch keeps us out of the Files-API upload dance); model fallback chain;
     explicit red-lettered consent copy in settings before enabling.
   - Log every call to `llm_calls` (truncate bodies 64 KB).
7. `TimelineCategoryStore`: UserDefaults JSON (`timelineCategories`), fields
   `id/name/colorHex/details/order/isSystem/isIdle`, defaults per parity table + system category
   "Meetings" (isSystem, used by joiner). Ensure-defaults on read; case-insensitive normalization
   helper for LLM output.
8. `TimelineDayBoundary`: `day(for: Date) -> String` with 4 AM boundary + DST-safe math.

Tests (`Tests/TimelineAnalysisTests.swift`): batch planning table-driven cases (gaps, short,
trailing), idle shortcut + merge, day-boundary math incl. DST transitions, card JSON validation +
category normalization + fallback, range-replacement respects kind filter, rate-limit classifier.
Provider calls unit-tested behind a mock provider.

Observability: psv events `timeline_batch_completed|timeline_batch_failed` (props: provider-type
enum, duration bucket, observation-count bucket); Sentry policy entry
`timeline.analysis_failed` (error only, reason tag). Update sanitizer + docs per ground rule 4.

Acceptance: build + fast tests + `bash run-tests.sh` green; manual: an hour of real capture
produces sane merged cards with the local provider, no gaps on the day.

## Phase 4 — Timeline home UI (the new home screen)

Files: `Sources/UI/Timeline/` per architecture map; edits to
`Sources/UI/Settings/TranscriptedSettingsPage.swift`, `TranscriptedSettingsView.swift`,
`TranscriptedSettingsSidebar.swift`, `TranscriptedSettingsNavigationModel.swift`,
`Sources/UI/MenuBar/MenuBarPrimaryActionsView.swift`.

1. Navigation: add `TranscriptedSettingsPage.timeline` (title "Timeline", SF Symbol
   `calendar.day.timeline.left`, ⌘1) and make it the **default landing page**: sidebar order
   Timeline, Home, Dictations, Speakers, Agent (Home ⌘2, shift others). All existing
   "open home" entry points (`showSettingsWindow(page: .home, ...)`, menubar "Home" row) now route
   to `.timeline`; keep the old Home page reachable as "Captures". Update automation ids
   (`transcripted.settings.sidebar.timeline`) and the launch-smoke assertions in `build.sh`
   (lines ~316-336 assert menubar automation ids — verify they still pass).
2. `TimelineHomeView` (day canvas):
   - Vertical scroll canvas 4 AM → 4 AM, hour labels in a left gutter, ~60 px/hour,
     y = minutesSince4AM × pxPerMinute; card height ∝ duration, min 10 px, 2 px spacing.
   - Cards filled with category color (`TimelineCanvasCard`); meeting cards get the Meetings color
     + a mic glyph; dictation clusters get a keyboard glyph.
   - Display-only overlap trimming resolver (pure function, unit-tested).
   - Staggered ~30 ms entrance animation, hover scale 1.01 (respect
     `AccessibilityDisplayPolicy` reduce-motion), tap selects → detail panel.
   - Today: `TimelineLiveStatusCard` pinned at "now" — capturing = animated "Generating your next
     card…" shimmer; paused = bordered resume card (tap resumes); permission-revoked = warning card
     deep-linking to System Settings.
   - Auto-scroll to "now" on open for today; `TimelineDayNavigation` = prev/next day pills +
     calendar popover + "Today" button; day-rollover timer re-keys the canvas at 4 AM.
3. `TimelineDetailPanel` (right side, fixed width ~340 px inside the 980×760 window):
   title, `h:mm a – h:mm a` badge, category badge (dot + name) with swap button →
   `CategoryPickerView` overlay (rename/recolor/add categories inline, persists via
   `TimelineCategoryStore`, edits card row); summary section + optional detailed summary
   (selectable markdown); distraction chips; app/site line. For meeting cards: decisions/action
   items pulled from frontmatter summary keys (`local_summary_*` > `auto_summary_*`) + "Open
   transcript" (reveals .md) + play button reusing `MeetingAudioPlayback`. Failed batch in range →
   orange retry pill → `reprocessBatch`.
4. `ScreenshotSlideshowView`: full-screen modal playing the card's screenshots like video —
   spacebar play/pause, speed cycle (1×/2×/4×), drag scrubber with an 8-frame filmstrip
   (`CGImageSourceCreateThumbnailAtIndex`), Cmd-W/esc closes. Thumbnail strip in the detail panel
   (200 px tall, play overlay) opens it.
5. Design: `TimelineTokens.swift` — reuse Transcripted's dynamic light/dark color approach
   (`MenuTokens` pattern) and system fonts (SF Pro; do NOT vendor Dayflow's Figtree). Match
   Dayflow's layout anatomy, not its brand.
6. Menubar: add "Timeline" primary row (`transcripted.menubar.primary.timeline`) + a
   pause/resume-recording row reflecting engine state; status-item icon gains a subtle recording
   dot when capturing (respect existing icon behavior for dictation/meeting states — dictation
   states win).

Tests: canvas geometry mapper (time→y, duration→height, min-height, overlap trim) as pure fast
tests (`Tests/TimelineCanvasLayoutTests.swift`). Visual evidence to `.agent-review/visuals/`
(light + dark, empty day, dense day, live card).

Acceptance: build + fast tests green; launch smoke in `build.sh` passes with new menubar row;
manual: full day renders, selection/detail/slideshow/category-swap all work, reduce-motion
respected.

## Phase 5 — Meetings & dictations on the timeline (the merge)

Files: `TimelineCaptureJoiner.swift`; touches `Sources/UI/Shared/RecentCaptureScanners.swift`
consumers only (read-only reuse).

1. `TimelineCaptureJoiner`: on capture-library change (`HomeCaptureRefreshObserver` pattern) and on
   day load, scan `meetings/*.md` + `dictations/Dictations_*.md` via the existing scanners +
   `TranscriptFrontmatter` (`date`, `time`, `duration` keys) and upsert `timeline_cards` rows with
   `kind = meeting|dictation`, `capture_id`, title, summary (from `local_summary_*`/`auto_summary_*`),
   category Meetings. Dictations cluster into one card per contiguous burst (gap > 15 min splits).
   Deletion/rename in the library removes/updates the projection (join on `capture_id`, refresh
   staleness by comparing file mtime).
2. Card regen exclusion (already enforced in Phase 3): activity cards flow around meeting cards;
   the card prompt context includes meeting cards as fixed context ("a meeting occupied
   10:00–10:45") so the LLM doesn't duplicate them.
3. Needs-attention: capture rows with pending speaker review surface the existing pill affordances
   from `HomeView` on the timeline card.

Tests (`Tests/TimelineCaptureJoinerTests.swift`): frontmatter → card projection, dictation burst
clustering, rename/delete reconciliation, regen exclusion end-to-end against a temp DB.

Acceptance: build + fast tests green; manual: record a meeting, watch it appear on today's
timeline with summary + decisions in the detail panel.

## Phase 6 — Agent-readable outputs: Markdown, MCP, CLI

Files: `TimelineMarkdownWriter.swift`; `Tools/TranscriptedCaptureKit`, `Tools/TranscriptedMCP`,
`Tools/TranscriptedQA` additions; `docs/capture-format.md` update.

1. `TimelineMarkdownWriter`: after each successful card regen affecting day D, rewrite
   `<capture-library>/timeline/YYYY-MM-DD.md` atomically. Format (documented in
   `docs/capture-format.md`, new `capture_type: timeline` frontmatter with `format_version: 1`,
   `date`, `card_count`, `active_minutes`, `categories:` indented list):
   body = `# Timeline - <date>`, then per card
   `1. **9:00 AM – 10:30 AM — Title**` / `_Category_` / `Summary:` (+ `Details:`) bullets —
   Dayflow's clipboard-export shape, so exports match what Dayflow users expect. Meeting cards
   link `[transcript](../meetings/<stem>.md)`.
2. `Tools/TranscriptedCaptureKit`: add `TimelineMarkdownParser` (lockstep mirror of the writer,
   same rule as `CaptureMarkdownParser`).
3. `Tools/TranscriptedMCP`: new tools `get_timeline(date|range)` and fold timeline into `digest`
   (merged day: activities + meetings + decisions + action items). Index `timeline/*.md`.
4. `Tools/TranscriptedQA`: validate timeline artifacts (frontmatter keys, chronology, no overlap).
5. E2E smoke: add writer/parser sources to the explicit `SWIFT_SOURCES` array in
   `scripts/entrypoints/run-e2e-smoke.sh` + a round-trip check (write day file from fixture cards
   → parse → MCP index sees it).
6. Copy-to-clipboard export button on `TimelineHomeView` (day) reusing the writer's formatter.

Verification (per matrix): `python3 scripts/dev/check-build-source-lists.py` +
`bash run-e2e-smoke.sh` + `swift test --package-path Tools/TranscriptedMCP` +
`swift test --package-path Tools/TranscriptedCLI` (if CLI touched) + build + fast tests.

Acceptance: e2e smoke green including new round-trip; MCP `digest` for a fixture day interleaves
activities and meetings.

## Phase 7 — Week view + dashboard

Files: `TimelineWeekGridView.swift`, `TimelineDashboardView.swift`, builders in
`Sources/Timeline/` (`WeeklyStatsBuilder.swift` — pure, off-view).

1. Day/week mode toggle in the timeline header (Dayflow `timelineMode` pattern).
2. Week grid: 7 columns × 4AM–4AM rows, same color mapping, hover preview, click → day.
3. Dashboard section (below or tab): weekly overview stats, **category donut**
   (start with donut + focus heatmap; Sankey/treemap/interaction-graph are v2 stretch — log as
   follow-ups, don't block), top apps/sites list from `app_sites_json`, longest-focus + meeting-load
   chips (meeting minutes from joined cards — a stat Dayflow can't do).
4. `WeeklyStatsBuilder` computes everything from SQL in one pass; unit-test the aggregation.

Acceptance: build + fast tests green; visual evidence for week grid + dashboard light/dark.

## Phase 8 — Chat over your day

Files: `TimelineChatView.swift`, `Sources/Timeline/ChatService.swift`,
`ChatToolExecutor.swift`, `ChatPromptBuilder.swift`.

1. Chat panel on the timeline page (Dayflow anatomy: composer, message list, markdown renderer,
   thinking → tools → answer status states).
2. Tooling: `fetch_timeline(range)`, `fetch_observations(range)`, `fetch_meeting(capture_id)`
   (reads transcript Markdown), and a read-only SQL tool over `timeline.sqlite`
   (SELECT-only, statement-vetted). Provider = the configured timeline provider; the local
   FoundationModels path is the default and must work offline.
3. History persisted to `chat_conversations`/`chat_messages`; conversation list panel.
4. Privacy: chat context is assembled locally; with a cloud provider configured, show a one-time
   inline notice that questions send timeline text to that provider.

Tests: tool executor (SQL guardrails: rejects non-SELECT), prompt builder windowing.

Acceptance: build + fast tests green; manual: "what did I work on this morning and what did we
decide in the standup?" answers from cards + meeting summary fully locally.

## Phase 9 — Onboarding, settings, polish, stretch

1. Onboarding: timeline opt-in step appended to existing permissions onboarding
   (`Sources/UI/Settings/PermissionsOnboardingView.swift` + `PermissionsOnboardingPreferences`):
   explain what's captured, Screen Recording TCC grant flow with live status
   (`ScreenRecordingPermissionView` equivalent), provider choice (default local — one-click),
   category color setup (reuse `CategoryPickerView`), sample card creation on completion. Timeline
   stays fully off until this completes.
2. Settings: Timeline section in General/consolidated pages — provider picker + endpoint/key
   fields, prompt-override text areas (per-provider, house pattern of prefs enums), app blocklist
   editor (running-apps picker), storage cap, master off switch (kills engine, keeps data),
   "Delete all timeline data" destructive action.
3. Analytics (psv adds, all bucketed): `timeline_onboarding_completed`, `timeline_viewed`,
   `timeline_mode_changed`, `timeline_card_opened`, `timeline_provider_selected` (enum),
   `timeline_chat_question_asked` (count bucket only). Sentry adds: `timeline.capture_failed`,
   `timeline.analysis_failed`, `timeline.db_error`. Update `docs/privacy-first-observability.md` +
   run the taxonomy normalizer + keep `AnalyticsEventPolicyTests` green.
4. Stretch (separate follow-up PRs, not v1): ChatGPT/Claude-CLI provider, journal/day-goals
   surface, daily standup generator, timelapse MP4 rendering, Sankey/treemap dashboards,
   timeline review/ratings.

## Phase 10 — Hardening + release

1. Performance budget: capture + analysis idle overhead measured via
   `scripts/ops/performance-budget.rb` against `events.jsonl`; add timeline packets to the
   reliability recorder if wake-recovery interacts with the engine.
2. Full matrix run: `bash build-deps.sh --force` (if Core touched — it should NOT be),
   `bash build.sh --no-open`, `bash run-tests.sh`, `bash run-integration-smoke.sh`,
   `bash run-e2e-smoke.sh`, package `swift test`s for touched Tools.
3. Docs: README feature section, `docs/repo-layout.md`, storage/capture-format docs final pass,
   `WHATS_NEW`/release notes.
4. Beta: `SKIP_NOTARIZATION=1 bash build-beta.sh '' <user>` smoke, then normal release flow
   (appcast + cask per `docs/release-packaging.md` — a release is not done when the DMG exists).

## Sequencing & sizing

Phases 0–2 are independent-ish plumbing (≈ small PRs each). Phase 3 is the largest single chunk;
land it behind the disabled-by-default flag. Phase 4 makes it visible; 5 makes it Transcripted's;
6 makes it agent-native. 7–9 are additive. Every phase = its own PR against this branch's stack,
each passing its matrix checks, timeline feature dark until Phase 9 onboarding ships.

## Risks & honest caveats

- **Screen Recording TCC re-approval nags** (macOS periodic re-confirmation) will hit every user;
  the paused-with-banner state (Phase 1.3) is the mitigation, but expect support noise.
- **Local-only card quality**: OCR+metadata+FoundationModels will be worse than Gemini-on-video.
  The observation builder's app/window metadata is the equalizer — invest there before reaching
  for cloud. If quality disappoints, the Ollama VLM path is the pressure valve, still local.
- **Disk**: 1080p JPEG every 10 s ≈ 1.5–3 GB/day before purge. Default 5 GB cap ≈ ~2 days of
  raw screenshots; cards/markdown persist forever (tiny). Make the cap slider obvious.
- **Two capture stacks in one app**: meeting capture (SCK audio) + screenshot capture (SCK
  pixels) + local LLMs can stack CPU during a meeting. Phase 3 scheduler should defer analysis
  while a meeting is recording (`MeetingSessionController.isRecording` check) — cheap and avoids
  the worst case.
- **Home-screen swap** changes muscle memory for existing users; keeping old Home as "Captures"
  one click away (⌘2) is the compromise. Revisit after dogfooding.
