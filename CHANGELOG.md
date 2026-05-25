# Changelog

All notable user-facing changes to Transcripted are documented here. The format
loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project uses semantic-ish versioning (`MAJOR.MINOR.PATCH`).

Release downloads and signed DMGs live on the
[GitHub Releases](https://github.com/r3dbars/transcripted/releases) page. The
appcast for in-app Sparkle updates is at
[`docs/appcast.xml`](docs/appcast.xml).

Entries marked **[CRITICAL]** are flagged as `sparkle:criticalUpdate` and are
force-installed by Sparkle so existing users recover from a regression.

## [1.1.43] - 2026-05-22

### Added
- Retranscribe saved meetings with speaker identification, including a gate for retranscription and updated playback mix generation.
- Full meeting audio playback choice with preservation of the mic/source selection.
- Active meeting quit confirmation to prevent accidental loss of in-progress recordings.
- Onboarding funnel and "shown" telemetry events.

### Changed
- Consolidated settings into a compact General settings page and removed the redundant shortcuts section.
- Imported audio now uses the source file date for recording timestamps.
- Clarified speaker review inbox and naming review copy; clarified failed meeting retry state.
- Long meeting stop timeout now scales with meeting length; long meetings remain visible after stop failures.
- Deferred speaker review queue improvements, including consolidated breakdown rows and retryable queue behavior.

### Fixed
- CoreML inference lifetime crash.
- Meeting audio playback echo.
- Bluetooth output dictation readiness issue.
- Saved-before-quit meetings being misclassified as failures.
- Long meeting failed-state refresh, home stats duplicate sheet, and home stats details action.
- Calendar permission refresh after the system prompt; settings now refresh after permission grants.
- Repeated quit termination replies and duplicate update timeout telemetry.
- Meeting system audio status after async start and meeting mic tap teardown.
- Split UTF-8 speaker name finalization and split previews.
- Agent setup details toggle and menu ready warning layout.
- No-speech meetings no longer reported as Sentry failures.
- Feedback sound silenced; support feedback cue removed.
- Pruning of old failed meeting audio.

## [1.1.42] - 2026-05-19

### Added
- Dictation filler cleanup setting that strips fillers and disfluencies from transcripts.
- Transcripted QA bench with a corpus comparison mode (including private meeting corpus support).
- Build version included in analytics metadata; Sentry release registration guardrails and rerun-safe metadata.
- Audio diagnostic flags for the long-standing audio reliability investigation (issue 500).

### Changed
- Tightened dictation cleanup heuristics and protected path-like text from being mangled.
- Hardened Parakeet device rewarm recovery and detection of transient meeting audio ducking.
- Clarified meeting speaker save failure messaging.

### Fixed
- Calendar permission entitlement.

## [1.1.41] - 2026-05-18

### Added
- Improved error guidance when imported audio fails.
- Live capture smoke gate and expanded release readiness contract tests (release blockers now caught earlier).

### Changed
- Release plumbing: hardened launch smoke isolation and cleanup.

## [1.1.40] - 2026-05-18

### Fixed
- Stale home speaker review badges; the speaker queue now refreshes after a meeting is saved.

## [1.1.39] - 2026-05-18

### Added
- Onboarding completion tracking and analytics for the completion flow.
- Audio import action restored on Home and also surfaced in General settings.

### Changed
- Polished settings hover states.
- README download links now point at the guided download page.
- Clarified the speakers cleanup tab.

### Fixed
- Stale runtime shutdown diagnostics.
- Preserved dictation audio is now cleared on interruption.
- Preserved meeting transcript trigger telemetry across edge cases.

## [1.1.38] - 2026-05-16

### Added
- Timer in the minimized meeting overlay (fits long durations).
- Speakers tab added to home activity tabs.
- Meeting audio scrubber controls and home meeting audio recovery controls.
- Inline flagging and recovery for failed meetings on Home.

### Changed
- Settings toggles converted to switch rows with polished interaction states and restored accessibility detail.
- Folded meetings settings into Home.
- Moved dictation sounds into General settings.
- Reworked home artifact inbox: simpler rows, subdued "load more" button, refined actions, removed action tiles, attention banner limited to active work.
- Softer severity styling and matched row design for the speaker review surface.
- Long minimized meeting timer layout fits long values; failed meeting retry signal simplified and polished.
- Meeting saves now count as a first-value event.
- Failed meeting titles preserved on error update; failed retry audio safely preserved (including during speaker review).
- Split speaker finalization failure telemetry for clearer attribution.

### Fixed
- Hardened dictation retry and recovery paths.
- Failed meeting review expansion and inline recovery clarity.
- Speaker name finalization after the row restyle.
- Meeting audio scrub interactions.
- Clearing of meeting diagnostics after a missing-mic stop.
- Physical-key no-speech copy clarified.

## [1.1.37] - 2026-05-14

### Changed
- Hardened meeting audio preservation and improved the meeting save completion flow.
- Hardened audio startup and meeting failure diagnostics; tightened reliability review fixes.

## [1.1.36] - 2026-05-14

### Added
- Transcripted launch demo assets and refreshed launch GIFs.
- Calendar event titles used for meeting names (including manual meeting starts).

### Changed
- Stabilized and simplified home capture tabs and folder tabs; removed the home tab seam.
- Kept onboarding dictation shortcuts fully off when chosen.
- Preserved the meeting outcome trigger attribution telemetry.
- Avoid cancelling active dictation inference when starting a new transcription.

### Fixed
- Settings header rendering when sidebar collapses.
- Report Issue sheet layout.
- Meeting mic tap teardown order; meeting audio stop race.
- Queued meeting save state.
- Built-in mic Bluetooth recovery.
- Various findings from a "bug hunt" sweep.

## [1.1.35] - 2026-05-13

### Added
- JSON output for CLI `read` commands.
- Settings window is now resizable.
- Meeting-first onboarding path.
- Meeting volume drop diagnostics.
- Reliability scoring and Sentry diagnostic tagging.
- CLI can now follow external/app-selected capture libraries.

### Changed
- Menubar and overlay UI papercuts polished.
- Hotkey debounce and dictation timeout switched to monotonic uptime, avoiding wall-clock drift issues.
- Hardened queued meeting model recovery and startup recovery diagnostics.
- Pinned HuggingFace downloads to `huggingface.co` only; removed unused beta token from the app binary and the Anthropic proxy route from the beta worker archive.
- Cleaned up failed dictation mic starts and added timeout context to stall diagnostics.
- Guarded meeting warmup and meeting transcription model readiness.

### Fixed
- Cached model readiness state.
- Blocked Bluetooth audio recovery.

## [1.1.34] - 2026-05-11

### Added
- Whisper cache cleanup control and stale model cleanup control; model cache footprint is now surfaced.
- Setting to disable dictation shortcut.
- Reclaimable cache cleanup option.
- Thin app build option (default for new performance builds).

### Changed
- Launch model loading is now on-demand and meeting model warmup is deferred until needed (faster app launch).
- Dictation start cancellation is now explicit; single-instance performance guard added.
- Hidden cancel hints when dictation is disabled.
- Quieter "thin" update for existing users; first model download setup copy clarified.
- Hardened model prefetch startup states.
- Coalesced settings refresh work; batched info observability writes.
- Tighter support diagnostics redaction and scrubbing of key values; locked runtime diagnostics context keys.

### Fixed
- Dictation ready-start retry race.
- Cleared inactive runtime session heartbeats; heartbeat shutdown attribution kept safe.
- Whisper cache root cleanup hardening.

## [1.1.33] - 2026-05-08

### Added
- Deferred speaker review flow with a polished speaker naming sheet.
- Runtime session duration telemetry; Sentry runtime crash context.
- MCP `--help` output and expanded PostHog health probe coverage.

### Changed
- Reduced idle audio recovery noise and quieted noisy health events.
- Quieter `transcripted-mcp` self-test logs.
- Update-ready copy clarified.
- Restored matched speaker profiles when the mic collapses.
- Shared transcript frontmatter parsing across surfaces.
- Simplified speaker review name checks; removed unused beta proxy URL.
- CLI now follows app-selected retrieval paths and validates CLI manifest capture paths.

### Fixed
- Malformed frontmatter durations rejected gracefully.

## [1.1.32] - 2026-05-06

### Added
- Speaker name autocomplete in the naming UI.
- Meeting audio diagnostics.
- "You" selection support in speaker review (preserves row-level "You" naming).

### Changed
- Clarified physical-key no-speech copy.

### Fixed
- Reapply hidden Dock visibility preference (Dock visibility drift).
- MCP custom capture directory indexing.
- Activation drift during recording and Dock activation drift repair.
- Agent onboarding copy actions.
- CLI speaker search preview.

## [1.1.31] - 2026-05-04

### Added
- Meeting audio storage retention with automatic backfill compression of existing meeting audio.

### Changed
- Hardened meeting audio storage cleanup and meeting audio conversion validation.
- Cleaned up stale meeting audio temp files.

## [1.1.30] - 2026-05-03

### Added
- Reliability packets attached to support diagnostics.
- Audio reliability state matrix and daily audio reliability check.

### Changed
- Skip the dictation startup loading state when the mic is already ready; smoothed dictation microphone startup copy.
- Defer shortcut app lookup on Home; stabilized home stats identity and sped up menu and recent meeting refreshes (including recent meeting previews).
- Stale dictation readiness refreshes now time out.
- Prefer built-in mic for meeting capture by default.
- Removed legacy MCP helper fallback.

### Fixed
- Dictation start after wake from sleep.

## [1.1.29] - 2026-05-02

### Added
- Settings support page with a refined support feedback flow; feedback now routed to a support email.
- Support diagnostics with runtime shutdown tracking and dictation audio route telemetry.
- CLI `meeting read` command.
- Contextual home feedback flow.

### Changed
- Major Home redesign: unified tabs and activity, attached mode tabs to the hero, seamless folder tabs spanning full width, tighter vertical spacing, simplified copy, refined hero spotlight, polished hero design, home activity synced with hero mode.
- Tightened meetings view and preview; hardened home meeting preview performance.
- Simplified feedback menu item and support settings UI.
- Hardened dictation input readiness recovery.
- Deduplicated retrieval speaker names; simplified speaker naming cleanup.
- Publish SCK capture errors on main thread.

### Fixed
- Stale dictation mic start recovery.
- Idle Parakeet device rewarm reporting.
- Meeting stop timeout diagnostics snapshot.
- Cleanup helper actor isolation.

## [1.1.28] - 2026-04-30

### Added
- Show recent meetings near meeting actions on Home.
- Meeting health teardown regression tests (relevant for stop reliability).

### Changed
- Simplified home activity rows.
- Preserve meeting cancel stop timeouts so cancel can no longer hang.
- Live-status callouts in release notes clarified.

### Fixed
- Recent capture cancellation races.
- Raw relative capture path validation; relative storage paths now rejected (also a security hardening).

## [1.1.27] - 2026-04-29

### Added
- Human review hub for agent PRs (developer-facing).
- Embedded PR visual artifacts and agent PR review packets (developer/agent-facing).

### Changed
- Clarified home capture actions.
- Review packet outputs no longer truncated and limited to PR changes only.

### Fixed
- Recent activity menu hang.
- Meeting health snapshot timing.

## [1.1.26] - 2026-04-29

### Added
- Transcripted now has a permanent Dock presence (Dock icon always visible; clicking opens Settings Home).
- Dock visibility setting to opt out of the permanent Dock icon.
- Redesigned Settings Home as a Wispr Flow-style activity dashboard: welcome header, single hero CTA, tabbed day-grouped timeline of recent dictations and meetings, lifetime stats rail (words, dictations, meetings, hours, streak), with per-row copy/flag/menu actions including Reveal in Finder, Show audio in Finder, and Delete (single-entry delete without nuking the day file).
- "Typing time saved" stat surfaced on Home.
- Meeting audio route diagnostics; tracking of failed dictation starts.
- Load more on settings home; settings home stats polished.

### Changed
- Automatic updates are now restart-ready.
- Hardened audio device recovery and local log appends; serialized meeting audio graph teardown.
- Improved CLI meeting search matching.
- Clearer corrections examples and clarified corrections settings UI; "dictate" copy used in corrections preview.
- Polished meeting failure home card copy.
- Hidden settings window title; polished settings home UI and activity.
- Optimized settings capture refresh; kept settings home snappy.
- Hardened Sparkle appcast feed configuration (security hardening).
- Hardened dictation entry IDs against collisions.
- Sentry context scrubbing hardened.

### Fixed
- Fail fast when system capture is missing rather than silently hanging.

## [1.1.25] - 2026-04-27

### Added
- Recording sessions now appear in the macOS force-quit dialog so a hung session can be reliably killed.

### Changed
- Voice Processing IO (VPIO) is now off by default for meeting mic capture, with real-time software AGC handling levels instead; tuned VPIO for the meeting-recording cases where it is still used.
- Audio stop teardown moved off the main thread to keep the UI responsive when ending a recording.
- Stale dictation recovery work is now cancelled when the user cancels, preventing late ghost retries.
- Dictation visualizer/metering fix so the live waveform reflects the correct mic.

### Fixed
- Meeting widget freeze tied to the previous VPIO ducking behavior.
- Race that could reuse a cancelled wake-recovery attempt.
- Used the live retained audio archive path so meeting playback resolves to the right file.
- Preserved usable system audio when the mic capture segment is very short.
- Avoided bundling duplicate Parakeet models, shrinking the app footprint.

## [1.1.24] - 2026-04-24

### Added
- Voice Processing IO (VPIO) enabled on meeting mic capture to fix Safari/Firefox meeting audio sounding quiet.

## [1.1.23] - 2026-04-24 [CRITICAL]

### Fixed
- Disabled the Sentry "app hang" reporter, which was firing noisy false-positive hang reports and contributing to instability. Force-installed via Sparkle.

## [1.1.22] - 2026-04-24 [CRITICAL]

### Fixed
- Fixed the updater getting stuck on "Checking for updates..." indefinitely. Force-installed via Sparkle so existing installs can recover.

## [1.1.21] - 2026-04-24

### Fixed
- Recover from stuck dictation audio by resetting the capture pipeline instead of silently hanging.
- Refresh dictation readiness state after a recovery so the next press works without restarting the app.

## [1.1.20] - 2026-04-24

### Changed
- Beta diagnostics opt-out is now preserved across updates.
- Settings panel refreshes are faster and avoid redundant recomputation.

### Fixed
- Storage tool legacy reads now work against older on-disk layouts.
- Hardened the release QA reliability paths so first-run setup is more predictable.

## [1.1.19] - 2026-04-24

Release plumbing only; no user-facing changes.

## [1.1.18] - 2026-04-22

### Added
- Meeting prompt now offers a "remind me later" option so it stops nagging in the same session.

### Fixed
- Empty dictation audio is now retried automatically instead of producing a silent failure.
- Hardened wake-from-sleep and meeting recording recovery so sessions resume cleanly after the Mac wakes.

## [1.1.17] - 2026-04-22

### Added
- Redesigned first-run onboarding flow with a clearer permissions walkthrough and analytics on each step.
- "Quiet" update reminders so Sparkle stops interrupting active work.

### Changed
- Clearer feedback when dictation captures no speech (instead of an opaque empty result).
- Custom capture library paths are now preserved across updates.
- Tightened analytics, observability, and storage-root sanitization (stronger privacy hygiene with no user-visible behavior change).

### Fixed
- AirPods dictation mic start hardened against initialization failures.
- Speaker name suggestion combobox returning wrong matches.
- Removed a redundant Whisper finishExternalTranscription call that could double-fire on error paths.

## [1.1.16] - 2026-04-21

### Added
- One-click Claude Desktop MCP install from settings.

### Changed
- App settings command now routes to the settings window instead of a partial menu surface.
- AirPods users get the built-in mic preferred for dictation, with a warning when the macOS Fn key shortcut conflicts with system bindings.
- Split Fn dictation shortcuts by capture mode and restored Right Option hands-free as the default.
- Shorter, simpler local agent prompt and clearer agent-connection choices.
- DMG MCP setup prompt clarified.
- Avoided redundant dictation device resets that caused brief mic glitches.

## [1.1.15] - 2026-04-21

### Added
- Menu bar visibility toggles to hide/show specific menu bar items.
- Physical dictation trigger keys (assignable hardware shortcut).
- Dictation shortcut modes (multiple capture/trigger options).
- Coarse audio start diagnostics surfaced to help users debug mic failures.

### Changed
- Home action tiles stabilized into a compact two-column grid with menu toggles aligned to primary actions.
- Improved people/duplicate review controls in settings.
- Microphone permission recovery flow improved; mic recovery hardened against transient failures.

### Fixed
- Parakeet startRecording failure now resets state cleanly so the next attempt can succeed.

## [1.1.14] - 2026-04-21

### Added
- Minimized meeting overlay widget for low-distraction recording.
- Per-speaker "You" selection coverage so your own voice is identified consistently across meetings.

### Changed
- Polished the speaker review workflow.
- Improved recent-context previews.
- Simplified settings menu copy.
- App responsiveness improvements on hot paths.
- README rewritten around agent context.

### Fixed
- Avoided stale meeting start timeout reuse that could fail the next meeting.
- Hardened Parakeet startRecording failure recovery.
- Hardened audio start recovery and observability path scrubbing.

## [1.1.13] - 2026-04-20

### Added
- Whisper transcription engine as an alternative to Parakeet, selectable in advanced transcription model settings.
- Custom dictionary terms so jargon and names transcribe correctly.
- Meeting audio playback controls; meeting recording audio is now retained.
- Launch at login setting.
- Dictation auto-enter, limited to a selected list of apps.
- Concierge-style agent setup flow with automatic agent connection routing and bundled Transcripted agent starter skills.
- "Copy for agent" action in settings and a portable meeting agent bundle.

### Changed
- Recent meetings moved out of the menu bar to a dedicated surface.
- Clarified agent environment routing and added agent response voice guidance.
- Capped feedback issue URL length so long reports do not break the link.
- Cleaned up imported audio when transcription is rejected.
- Preserved final capture health on meeting stop.
- Hardened Sentry local overrides, meeting prompt host matching, and observability secret sanitizers.

### Fixed
- Core sendability warnings (latent concurrency bugs).
- Sandbox-boundary check in the failed transcription path (`hasPrefix` was matching unintended siblings).
- Detected indexed transcripts that were missing their markdown counterpart and reconciled them.
- Removed dead draft-overlay state that could surface stale UI.

## [1.1.12] - 2026-04-18

### Added
- Home screen transcription activity feedback so users can see a transcription is in progress.
- A Wilhelm-scream easter egg on feedback submission.

### Changed
- Overhauled the meeting overlay waveform visualizer, then refined and combined mic + system streams into a single dictation-style waveform; tightened the meeting overlay pill.
- Calmed meeting recording controls: tuned action colors, clarified tooltips, and moved cancel to an explicit button with a confirmation step.
- Compacted the menu bar popover.

### Fixed
- Quiet meeting model warmup failures (silent startup failures on the offline path).
- Dictation mic release after a session ended.

## [1.1.11] - 2026-04-18

### Added
- Recent meetings and recent dictations views.
- Imported audio transcription flow (transcribe files you already have).
- Sparkle update status surfaced in the UI.
- Latest-dictation paste helper.
- Homebrew cask install path (`brew install --cask transcripted`).

### Changed
- Menu bar popover redesigned into a compact quick-action menu with flattened styling and condensed actions.
- Settings and menu surfaces redesigned.
- DMG installer layout polished and arrow now points at the Applications folder.
- Calmed Teams meeting prompts so they fire less aggressively.

### Fixed
- Startup hangs caused by storage and audio setup blocking the main thread.
- Mic-only speaker name finalization (the "you" speaker on solo dictations sometimes did not stick).
- Hardened secret redaction coverage in logs.

## [1.1.10] - 2026-04-17

### Fixed
- Dictation no longer truncates longer sessions; the audio buffer cap was raised from 120 seconds to 30 minutes.
- Hardened Accessibility API force-casts so unexpected Core Foundation types fall through to nil paths instead of crashing the app.
- Tightened meeting capture start gating to avoid spurious captures.

## [1.0.9] - 2026-04-17

### Added
- Dictation auto-paste now works inside terminal apps.

## [1.0.8] - 2026-04-17

### Added
- Identify multiple local speakers on the mic channel: meetings with several people physically in the room can now split the local mic into individual speakers via a new "People in the Room" settings toggle (default off), including a "Keep as You" batch action in the speaker-naming sheet.
- Onboarding now names the active transcription model (Parakeet TDT V3) and surfaces its download source; a persistent menu-bar status badge shows model readiness and links into settings.
- "Send Feedback" now files reports directly to GitHub Issues.

### Changed
- Compacted the meeting recording pill: the title is hidden during recording and the panel shrinks to a tight 260pt status indicator.
- Meeting transcript failures are now classified for clearer diagnostics.
- Friendlier copy for TLS / secure-connection errors during model download, replacing the default macOS SSL message.
- Permission recovery actions and copy layering clarified.
- CLI recent meeting previews improved.
- Deferred audio capture and audio engine initialization until capture actually starts, for a lighter cold launch.
- Removed sidecar language from the README and simplified the README copy.

### Fixed
- Reliable mic switching for AirPods and rapid device changes: dictation now waits on engine readiness instead of racing it, with a longer Bluetooth-friendly retry budget, coordinated recovery between the engine and session controller, and proper handling of AirPods 24 kHz HFP mode.
- Scrubbed feedback logs so file paths, emails, bearer tokens, and API keys cannot leak when filing a GitHub issue.
- Rejected secure text fields (passwords, PINs) as auto-paste targets.
- Aligned the pipeline-busy classifier with the actual transcription error message so retries trigger correctly.
- Preserved meeting trigger telemetry attribution.
- Hardened analytics secret sanitization and Sentry bearer token redaction.
- Hardened file logger startup behavior.
- Fixed agent fallback path resolution.

## [1.0.7] - 2026-04-14

### Added
- On macOS 26, switched system audio capture to ScreenCaptureKit audio-only, which triggers the lighter "System Audio Recording Only" permission tier with an inline Allow dialog (no app restart required) instead of full Screen Recording.
- Dictation overlay now offers a direct "Open Mic Settings" path when microphone access is denied.

### Changed
- Split first-run permission gating so onboarding asks for each permission at the right moment.
- Simplified the macOS 26 permission flow and cleaned up the permission prompt flow.
- Improved onboarding readability.
- Tightened retrieval tool output handling.
- Hardened observability secret redaction.

### Fixed
- Fixed the system audio permission flow after upgrading macOS.
- Removed an unused Apple Speech permission request.

## [1.0.6] - 2026-04-13

### Fixed
- Cleared a stuck "saving transcript" state that could leave meetings appearing to hang after recording.
- Fixed meeting reminder defer behavior so dismissed/deferred prompts behave as expected.

## [1.0.5] - 2026-04-13

### Added
- First-run onboarding now appears in a dedicated welcome window.

### Changed
- Improved the first-run onboarding flow end-to-end.
- Polished the Transcripted installer packaging.
- Aligned meeting permission copy with current behavior.
- Deferred launch-time audio prewarm so cold start is lighter.
- Removed per-meeting transcript sidecar files (transcripts are now consolidated).
- Hardened capture reliability for edge cases.
- Hardened Parakeet initialization diagnostics for clearer failure messages.
- Hardened beta token packaging.

## [1.0.4] - 2026-04-12

First release on the public Sparkle appcast.

### Added
- Privacy-first observability stack with onboarding crash-reporting consent (Sentry, with privacy-safe boundaries and DSN configured).
- Sparkle auto-updater scaffolding so future releases can ship in-app updates.
- Native meeting-detected prompt that asks whether to start recording.
- Auto-recovery for dictation across microphone changes, including AirPods and post-sleep/wake device switches.
- App readiness coordinator that queues meeting transcriptions behind active recordings.
- Markdown-first storage layout for transcripts and related artifacts.
- Local PostHog override support for self-hosted analytics endpoints.
- Short-audio guard that skips Parakeet transcription on clips too short to be meaningful, with regression tests.
- No-speech dictation analytics tracking.

### Changed
- Simplified first-run and menu UX, and trimmed the agent connection flow.
- Refined dictation overlay: tightened the pill, refined the stop button, improved Done button contrast.
- Swapped and lowered the dictation "delivered" cue sound for less startle.
- Improved the speaker identity review flow and protected corrected speaker profiles from being overwritten.
- Deferred saved metadata until speaker naming finalizes, and hardened speaker-naming artifact updates.
- Improved meeting warmup telemetry.
- Clarified meeting failure overlay copy and privacy consent copy.
- Hardened SQLite sidecar permissions and Sentry privacy boundaries.
- Removed beta telemetry shipping and the unused beta DMG updater.

### Fixed
- AirPods dictation input recovery and the wake-from-sleep audio graph recovery.
- Detected and resynced audio format mismatches after sleep/wake; fixed an audio format mismatch crash on device switch.
- Hardened meeting recorder lifecycle and meeting audio recovery.
- Parakeet model directories not being bundled correctly.
- Offline diarizer config to match FluidAudio 0.7.9.
- CLI retrieval mode and dictation parsing.
- Analytics override path lookup.
- Streaming SHA-256 verification to prevent an out-of-memory bypass during model download integrity checks.

## Pre-1.0.4

Versions `v0.1.0` through `v1.0.3` predate the public Sparkle appcast and
correspond to the pre-takeover Draft codebase. The standalone Transcripted
history before the Draft takeover is preserved on the
`legacy/transcripted-standalone` branch and the `pre-draft-takeover-2026-04-06`
tag. See `CLAUDE.md` for the historical-zone map.
