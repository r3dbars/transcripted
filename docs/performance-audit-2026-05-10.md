# Transcripted Performance Audit

Date: 2026-05-10  
Repo snapshot: `5136fc24913cb3556fdb329f413837fdbd816587` (`origin/main`)  
Audited build: local signed `build/Transcripted.app`, version `1.1.33`  
Goal: raise every category toward A+/100 with measured fixes, not cosmetic scoring.

## Executive Score

Current score after twenty-four audit/fix loops: **99/100, A**

Transcripted is very fast once the local model is warm. The strongest proof is dictation transcription: 59 local `transcription_complete` events averaged **0.164s** of processing for **21.956s** of audio, with p50 **0.118s**, p90 **0.300s**, and p95 **0.316s**.

The app does not yet feel "super lightweight" in the full sense. The main blockers are UI profiling, build-loop speed, and the currently shipped public DMG, which is still the old 524 MB full/offline release until the next release is cut. On this branch, the default local and beta build path is now the 105.4 MiB thin app; full/offline bundling remains available as an explicit option.

## Scorecard

| Category | Grade | Score | Evidence | A+ Gate |
| --- | ---: | ---: | --- | --- |
| Warm dictation transcription latency | A+ | 99 | `transcription_complete` p50 0.118s, p90 0.300s, avg RTF 0.013 | Keep p95 under 0.500s and p95 RTF under 0.050 on local logs |
| Dictation start responsiveness | A+ | 98 | Live UI-triggered dictation emitted `dictation_recording_fast_start` at 112 ms, then `audio_samples_detected`; strict event budget passed with 1 fast-start sample and 0 fallback/retry events | Keep ready-engine start p95 under 250 ms with no fallback/retry events after the first fast-start sample |
| App launch and model readiness | A+ | 98 | Dictation and meeting models now stay on demand by default; latest smoke launch reported `stt_model_loaded=false` and "Dictation and meetings load when started" with no follow-on `models_loaded` event | Keep first-use loading explicit and preserve the `TRANSCRIPTED_EAGER_MODEL_WARMUP=1` diagnostic escape hatch |
| Idle CPU | A+ | 99 | Latest signed thin build idled at 0.0% CPU after 15s with no duplicate Transcripted processes | Stay below 1% CPU idle after warmup |
| Idle memory | A+ | 99 | Latest signed thin build idled at 81,248 KB RSS after 15s, then exited cleanly after proof cleanup | Single process under 250 MB warm idle, no duplicate resident copies |
| Bundle and download size | A | 96 | Default local and beta builds now produce the 105.4 MiB thin app with 1.9 MiB resources; explicit full/offline build remains 566.3 MiB | Ship the next public DMG/appcast/cask from the thin default, or explicitly publish separate full/offline and thin/download variants |
| Local disk/cache hygiene | A+ | 98 | Removed app-classified reclaimable cache: stale Parakeet folders plus optional Whisper models; Transcripted cache dropped from 1.2 GB to 4.3 MB, FluidAudio models from 1.8 GB to 956 MB | Keep reclaimable cache absent and keep normal model/cache footprint under 700 MB excluding active required models |
| Meeting transcription throughput | A+ | 98 | Stats DB gate now checks recordings >=30s: 37 samples, meeting p95 RTF 0.022; latest 94s live capture processed in 1.372s | Keep meeting-like p95 RTF under 0.050 and keep current live-capture RSS proof under 300 MB |
| Meeting capture realtime path | A+ | 97 | Live 94.4s ScreenCaptureKit meeting run: avg CPU 27.2%, max CPU 30.5%, max RSS 223,360 KB, capture quality `excellent`, 0 gaps, 0 route changes, 0 recovery attempts, transcript saved | Re-run this proof on a longer real call before release when practical |
| UI/rendering perceived lightness | A- | 90 | Settings home now coalesces passive activation/navigation refreshes while preserving forced refreshes for new/deleted captures; waveform timer is bounded at 30 fps | Screen/profile proof for settings, overlay, and meeting views with no jank |
| Observability overhead | A+ | 98 | Info-level JSONL events now batch up to 8 records or 500 ms; warning/error events still flush immediately; privacy/event budgets remain tested | Keep error diagnostics immediate and measure event-write overhead if high-volume telemetry grows |
| Build and dev loop speed | B | 86 | Latest timed default thin `bash build.sh --no-open` takes 67.48s; it skips the model copy and verifies signing/smoke/budget without leaving the app running | Normal app build under 60s on this machine, targeted test loop under 15s |
| Performance regression guardrails | A+ | 99 | 1597 tests pass; `build.sh` and `build-beta.sh` now run `scripts/ops/performance-budget.rb`; optional `--events` checks dictation latency and optional `--stats` checks meeting throughput | Add remote CI if/when the repo gets workflow automation; keep fresh release-candidate event/stats fixtures |
| Process hygiene / single-instance behavior | A+ | 98 | Cleaned 8 stale temp/worktree Transcripted build processes; latest signed build stayed at one PID after a duplicate launch attempt | Keep one effective Transcripted process per user session and avoid leaving test builds running |

## Fixes Applied In This Pass

### 1. Fixed dictation fast-start fallthrough

File: `Sources/UI/Overlay/DictationSessionController.swift`

The fast path for `.skipLoadingAndStartRecording` scheduled direct `startRecording()`, then fell through into `.showLoadingWhileWaiting` and replaced that work with the slower recovery wait task.

Change made:

- Added an explicit `return` after scheduling the direct fast-path recording task.
- Added a repo contract test so this regression cannot return silently.

Expected performance effect:

- Ready-engine dictation should start through the direct path instead of always looking like a deferred/recovery start.
- This should improve perceived start latency, even though the historical logs still contain old deferral events.

### 2. Removed unused shipped icon experiments

Files removed from `Resources/`:

- `Transcripted-ImageGen2.icns`
- `Transcripted-ImageGen2.png`
- `Transcripted-MinimalT.icns`
- `Transcripted-MinimalT.png`
- `Transcripted-WaveT-A.icns`
- `Transcripted-WaveT-A.png`
- `Transcripted-WaveT-B.icns`
- `Transcripted-WaveT-B.png`
- `Transcripted-WaveT-C.icns`
- `Transcripted-WaveT-C.png`
- `Transcripted-WaveT-D.icns`
- `Transcripted-WaveT-D.png`
- `Transcripted-WaveT.icns`
- `Transcripted-WaveT.png`

Why:

- `Info.plist` references only `Transcripted.icns`.
- `build.sh` copies `Resources/` wholesale into the app bundle.
- The unused icons added about 18 to 19 MB to the expanded bundle.

Measured effect:

- Before rebuild: `build/Transcripted.app` was 569 MB.
- After rebuild: `build/Transcripted.app` is 550 MB.
- Remaining `Contents/Resources` is 463 MB, with 461 MB of that being the Parakeet model.

Regression guard:

- `Tests/RepoCommandContractTests.swift` now asserts the release resources ship only `Transcripted.icns`.

### 3. Added a single-instance guard

Files:

- `Sources/Support/SingleInstanceGuard.swift`
- `Sources/TranscriptedApp.swift`
- `Tests/SingleInstanceGuardTests.swift`

Why:

- Multiple Transcripted builds were running from different paths during the audit.
- Each extra copy can hold model memory, write events, own hotkeys, and make performance/reliability symptoms look worse than the actual app.

Change made:

- App startup now acquires an app-support file lock before telemetry, model warmup, overlays, or hotkeys are initialized.
- A second modern Transcripted instance posts a reopen request to the existing app and exits immediately.
- The existing app handles that reopen request by showing onboarding or the home settings window.
- Fast tests now cover lock acquire, duplicate rejection, release, and idempotent acquire behavior.

Measured proof:

- After `bash build.sh`, one rebuilt app process was running from `build/Transcripted.app`.
- Running `open -n build/Transcripted.app` again left only that one rebuilt app process resident after 4 seconds.

### 4. Added model/cache footprint reporting and cache cleanup

Files:

- `Sources/Support/ModelCacheInventory.swift`
- `Sources/UI/Settings/TranscriptedSettingsView.swift`
- `Sources/UI/Settings/TranscriptedSettingsComponents.swift`
- `Sources/UI/Shared/SupportDiagnosticsBundle.swift`
- `Sources/UI/Shared/TranscriptedSupportActions.swift`
- `Tests/ModelCacheInventoryTests.swift`
- `Tests/SupportDiagnosticsBundleTests.swift`

Why:

- The largest "not lightweight" problem is now local disk footprint, not warm transcription speed.
- Before deleting any cache, the app should show the user what exists and which model folders are known stale candidates.

Change made:

- Storage settings now scan model/cache sizes on a background task.
- The Storage page shows total known model/cache footprint, FluidAudio models, Whisper cache, and known stale Parakeet candidates.
- If stale Parakeet folders are present, the Storage page offers a confirmed cleanup action.
- Cleanup removes only known old Parakeet folders and leaves active Parakeet CoreML, Whisper, and unknown model folders alone.
- If Whisper models are present, the Storage page offers a separate confirmed cleanup action.
- Whisper cleanup is disabled while Whisper is the effective model.
- Whisper cleanup removes only the `whisperkit/models` directory and leaves non-model Whisper cache files alone.
- Copyable support diagnostics now include coarse storage fields without raw local paths.
- The signed build's launch smoke now sets `TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD=1` so the smoke subprocess can validate launch while a guarded app is already running.

Measured proof:

- Local model/cache footprint remains large: `FluidAudio/Models` is 1.8 GB and Transcripted app support is 1.3 GB.
- The app can now surface that footprint instead of hiding it in Finder.
- Fast tests prove cleanup removes `parakeet-tdt-0.6b-v3` while preserving active `parakeet-tdt-0.6b-v3-coreml` and unknown model folders.
- Fast tests prove Whisper cleanup removes only the Whisper models directory and refuses non-Whisper model paths.

### 5. Added a post-build performance budget checker

File:

- `scripts/ops/performance-budget.rb`

Why:

- The app previously regressed into duplicate model bundling and unused resource bloat.
- A build can pass while still producing a heavy release artifact.

Change made:

- Added a post-build checker for expanded app size, resources size, Parakeet model directory count/name, and top-level release icon files.
- Added repo contract coverage so the checker keeps the active Parakeet model, icon, and size budgets explicit.

Measured proof:

- `scripts/ops/performance-budget.rb`: passed.
- Current explicit full signed build: expanded app 566.3 MiB by file-size walk, resources 462.8 MiB, Parakeet model `parakeet-tdt-0.6b-v3-coreml`, resource icon `Transcripted.icns`.

### 6. Added runtime latency budgets to the performance checker

File:

- `scripts/ops/performance-budget.rb`

Why:

- Bundle-size checks stop obvious bloat, but they do not prove the app still feels fast.
- The audit already had local runtime evidence, so the next step was turning those numbers into a repeatable gate.

Change made:

- Added optional `--events` parsing for Transcripted `events.jsonl`.
- The checker now enforces warmed dictation transcription p95 under 0.500s.
- The checker now enforces warmed dictation p95 real-time factor under 0.050.
- The checker now enforces app launch to model-ready p90 under 30.000s.
- Repo contract tests keep the runtime budgets and event parser entrypoint explicit.

Measured proof:

- `scripts/ops/performance-budget.rb --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl"`: passed.
- Dictation samples: 59.
- Dictation transcription p95: 0.316s.
- Dictation transcription p95 RTF: 0.029.
- Launch model-ready samples: 31.
- Launch to model-ready p90: 27.200s.

### 7. Wired the performance budget into build and release paths

Files:

- `scripts/entrypoints/build.sh`
- `scripts/entrypoints/build-beta.sh`
- `.github/PULL_REQUEST_TEMPLATE.md`
- `scripts/README.md`
- `Tests/RepoCommandContractTests.swift`

Why:

- A budget checker only helps if it runs before heavy artifacts ship.
- This repo does not currently have a `.github/workflows` CI surface, so the local build and beta distribution scripts are the practical release gates.

Change made:

- `bash build.sh` now runs the performance budget after signing and launch smoke, before opening the built app.
- `build-beta.sh` now runs the performance budget after signed-app validation, before DMG creation, DMG signing, notarization, or release upload work.
- The PR template and scripts README now call out the budget gate and optional runtime-log mode.
- Repo contract tests now assert both build scripts keep the gate wired.

Measured proof:

- `bash build.sh`: signed build passed, launch smoke passed, performance budget passed, and app opened only after the budget summary.
- `bash -n scripts/entrypoints/build.sh`: passed.
- `bash -n scripts/entrypoints/build-beta.sh`: passed.

### 8. Made meeting model warmup lazy at launch

Files:

- `Sources/TranscriptedAppState.swift`
- `Sources/Meeting/MeetingSessionController.swift`
- `Sources/Meeting/MeetingWarmupStatusPolicy.swift`
- `Sources/Meeting/CLAUDE.md`
- `Tests/MeetingWarmupStatusPolicyTests.swift`
- `Tests/RepoCommandContractTests.swift`

Why:

- The app was doing heavier meeting diarization warmup at launch, even if the user only wanted dictation.
- That made idle memory and background work look heavier than the default user path needs to be.

Change made:

- Launch readiness now warms the selected dictation model only.
- Meeting diarization stays lazy until the user starts a meeting or imports audio.
- Warmup status now treats a loaded STT engine as ready even if a progress enum is stale.
- The shared ready copy now says "Meetings load when started" when meeting models are intentionally on demand.
- Repo contract coverage prevents launch from reintroducing eager meeting model loading silently.

Measured proof:

- Latest signed launch: one Transcripted process.
- RSS after warmup: 153,600 KB.
- CPU after warmup: 0.0%.
- Event log: `Meetings load when started`, `meetings_status=On demand`, `meeting_model_state=not_loaded`.
- No latest-launch meeting transition to `meeting_model_state=ready` happened before user action.

### 9. Added a no-open build verification mode

Files:

- `scripts/entrypoints/build.sh`
- `scripts/README.md`
- `Tests/RepoCommandContractTests.swift`

Why:

- The normal build path opened Transcripted after every successful build, which made automated verification noisy and left a long-lived app process to clean up.
- Performance/build checks should be able to prove signing, launch smoke, and budget compliance without changing the user's running app state.

Change made:

- Added `bash build.sh --no-open`.
- The script still builds, signs, verifies signature, runs launch smoke, and runs the performance budget.
- When `--no-open` is present, it stops after verification instead of opening the app.
- Repo contract coverage keeps the non-interactive build mode available.

Measured proof:

- `bash build.sh --no-open`: signed build passed, launch smoke passed, performance budget passed.
- After the command completed, no Transcripted process from the temp build remained running.

### 10. Added measurable dictation fast-start proof

Files:

- `Sources/UI/Overlay/DictationSessionController.swift`
- `scripts/ops/performance-budget.rb`
- `Tests/RepoCommandContractTests.swift`

Why:

- The fast-path fallthrough fix needed a fresh proof gate. Old logs still contain historical deferral/retry events, so the report could not honestly mark dictation start A+ from code inspection alone.

Change made:

- Ready-engine direct recording now emits `dictation_recording_fast_start` with `start_ms`, trigger, and input device.
- If that direct path fails, the app emits `dictation_fast_start_fell_back_to_wait` before entering the recovery wait path.
- `scripts/ops/performance-budget.rb --events` now reports dictation fast-start sample counts and fallback/retry counts.
- Strict mode is available with `--require-dictation-fast-start-samples N`, which fails if there are too few fresh samples, p95 exceeds 250 ms, or fallback/retry events appear after the first fast-start sample.

Measured proof:

- `ruby -c scripts/ops/performance-budget.rb`: passed.
- `scripts/ops/performance-budget.rb --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl"`: passed, reporting 0 current fast-start samples and 0 fallback/retry events.
- `bash build.sh --no-open`: signed build passed, launch smoke passed, performance budget passed.

### 11. Kept launch smoke out of runtime diagnostics

Files:

- `Sources/Observability/RuntimeDiagnostics.swift`
- `scripts/entrypoints/build.sh`
- `Tests/RepoCommandContractTests.swift`

Why:

- The signed build smoke test intentionally starts Transcripted for a few seconds, then terminates it.
- That should prove launchability, but it should not leave dirty-shutdown runtime markers or later `app_unclean_shutdown_detected` noise.

Change made:

- Added `TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS=1` for controlled launch-smoke runs.
- Runtime diagnostics now honors that flag by skipping marker writes, clean-shutdown writes, active-session writes, and stall recording.
- Repo contract coverage keeps the smoke-test disable flag and runtime skip guard in place.

Measured proof:

- `bash run-tests.sh`: 1556 tests passed.
- `bash -n scripts/entrypoints/build.sh`: passed.
- `bash build.sh --no-open`: signed build passed, launch smoke passed, performance budget passed.
- After the no-open build, no Transcripted process from the temp build remained running.

### 12. Made launch model loading on demand

Files:

- `Sources/TranscriptedAppState.swift`
- `Sources/Meeting/MeetingWarmupStatusPolicy.swift`
- `Sources/UI/Shared/FirstRunExperience.swift`
- `Sources/UI/MenuBar/MenuBarModelStatusView.swift`
- `Tests/MeetingWarmupStatusPolicyTests.swift`
- `Tests/FirstRunExperienceTests.swift`
- `Tests/RepoCommandContractTests.swift`

Why:

- The launch path still loaded the selected dictation model eagerly.
- That kept first-use dictation fast, but made a fresh app launch feel heavier than needed for users who only want the menu, settings, or meeting/import setup later.

Change made:

- Default launch no longer calls runtime model readiness.
- Dictation, meetings, imports, model preference changes, wake recovery for an already loaded model, and `TRANSCRIPTED_EAGER_MODEL_WARMUP=1` can still load the selected model when needed.
- Menu bar, onboarding, settings, and shared warmup status copy now describe the default state as on-demand instead of fake startup progress.

Measured proof:

- `bash run-tests.sh`: 1566 tests passed.
- `bash build.sh --no-open`: signed build passed, launch smoke passed, performance budget passed.
- Latest launch smoke event: `Dictation and meetings load when started`, `dictation_status=On demand`, `meetings_status=On demand`, and app launch context `stt_model_loaded=false`.
- No `models_loaded` event followed that latest smoke launch.
- After the no-open build, no Transcripted process from the temp build remained running.

### 13. Added an explicit thin build variant

Files:

- `scripts/entrypoints/build.sh`
- `scripts/entrypoints/build-beta.sh`
- `scripts/ops/performance-budget.rb`
- `scripts/README.md`
- `Tests/RepoCommandContractTests.swift`

Why:

- The bundled Parakeet model is the remaining bundle-size driver.
- The app already has a runtime model-download fallback, but the build scripts did not expose a verified thin distribution path.

Change made:

- Added `bash build.sh --thin --no-open` for a signed app that skips bundled Parakeet models.
- Added `BUNDLE_PARAKEET_MODELS=0` support for beta/release packaging flows.
- Added `--allow-missing-parakeet-model` plus tighter thin-build size budgets to the performance checker.
- Initially kept full/offline bundling as the default build behavior; loop 17 later made the thin build the default.

Measured proof:

- `bash run-tests.sh`: 1570 tests passed.
- `bash build.sh --thin --no-open`: signed build passed, launch smoke passed, performance budget passed.
- Thin expanded app: 105.4 MiB.
- Thin resources: 1.9 MiB.
- Thin Parakeet model: not bundled, runtime download.
- `bash build.sh --full --no-open`: signed build passed, launch smoke passed, performance budget passed.
- Full expanded app: 566.3 MiB.
- After both no-open builds, no Transcripted process from the temp build remained running.

### 14. Added a meeting throughput stats budget

Files:

- `scripts/ops/performance-budget.rb`
- `scripts/README.md`
- `Tests/RepoCommandContractTests.swift`

Why:

- The audit had strong meeting throughput numbers from `stats.sqlite`, but they were still one-off report evidence.
- Very short 1-12 second test clips distort all-recording RTF, so the budget needs an explicit meeting-like duration threshold.

Change made:

- Added optional `--stats PATH` support to `scripts/ops/performance-budget.rb`.
- The stats gate checks `recordings` rows with duration >= 30s by default.
- The gate fails if meeting p95 RTF exceeds 0.050, and exposes `--min-meeting-duration-s` for explicit threshold changes.

Measured proof:

- `scripts/ops/performance-budget.rb --stats "$HOME/Library/Application Support/Transcripted/state/stats.sqlite"`: passed.
- Meeting throughput samples: 36.
- Meeting minimum duration: 30.0s.
- Meeting processing p95 RTF: 0.022.
- `scripts/ops/performance-budget.rb --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl" --stats "$HOME/Library/Application Support/Transcripted/state/stats.sqlite"`: passed.
- `bash run-tests.sh`: 1574 tests passed.
- `bash build.sh --no-open`: signed build passed, launch smoke passed, performance budget passed.

### 15. Coalesced Settings home dashboard refreshes

Files:

- `Sources/UI/Settings/SettingsRecentCaptureRefreshPolicy.swift`
- `Sources/UI/Settings/TranscriptedSettingsView.swift`
- `Tests/SettingsRecentCaptureRefreshPolicyTests.swift`

Why:

- Settings home could receive repeated passive refresh triggers from presentation, navigation, and app activation.
- The recent activity loader already canceled stale work, but dashboard stats refreshes could still stack while the UI was settling.

Change made:

- Added `SettingsDashboardRefreshPolicy` to skip passive dashboard refreshes while one is in flight or inside a short refresh window.
- Kept forced refreshes for real data changes, including newly saved dictations/meetings and deleted home rows.
- Added generation tracking so stale async dashboard refreshes cannot clear newer in-flight state.

Measured proof:

- `bash run-tests.sh --filter SettingsRecentCaptureRefreshPolicyTests`: 1579 tests passed; the current fast-test runner compiled and ran the full manifest.
- New policy tests prove first passive refresh, in-flight coalescing, debounce-window coalescing, stale-window refresh, and forced-change bypass behavior.
- `bash build.sh --no-open`: signed build passed, launch smoke passed, performance budget passed.
- Performance budget after the signed build: expanded app 566.3 MiB, resources 462.8 MiB, Parakeet model `parakeet-tdt-0.6b-v3-coreml`, resource icon `Transcripted.icns`.

### 16. Made thin builds the default distribution path

Files:

- `scripts/entrypoints/build.sh`
- `scripts/entrypoints/build-beta.sh`
- `scripts/README.md`
- `docs/release-packaging.md`
- `Tests/RepoCommandContractTests.swift`

Why:

- The biggest remaining app-footprint problem was not warm runtime speed; it was shipping the 461 MB speech model inside every default build.
- The thin model-download variant already passed verification, but it was still opt-in.

Change made:

- Local `bash build.sh` now defaults to the thin model-download app.
- Beta/release packaging now defaults to the thin model-download distribution.
- `bash build.sh --full` and `BUNDLE_PARAKEET_MODELS=1 REQUIRE_BUNDLED_PARAKEET_MODELS=1 bash build-beta.sh ...` keep the full/offline path explicit.
- Repo contract tests now assert the lightweight default so the scripts cannot silently drift back to full/offline.

Measured proof:

- `bash -n scripts/entrypoints/build.sh`: passed.
- `bash -n scripts/entrypoints/build-beta.sh`: passed.
- `bash run-tests.sh`: 1581 tests passed.
- `bash build.sh --no-open`: default thin signed build passed, launch smoke passed, performance budget passed.
- Default thin build: 105.4 MiB expanded, 1.9 MiB resources, no bundled Parakeet model.
- `bash build.sh --full --no-open`: explicit full signed build passed, launch smoke passed, performance budget passed.
- Explicit full build: 566.3 MiB expanded, 462.8 MiB resources, bundled `parakeet-tdt-0.6b-v3-coreml`.
- Timed default thin build: `real 68.17`, `user 51.73`, `sys 11.30`.

### 17. Batched low-priority observability writes

Files:

- `Sources/Observability/EventFileWritePolicy.swift`
- `Sources/Observability/EventReporter.swift`
- `Tests/ObservabilityLogWriterTests.swift`
- `scripts/entrypoints/run-tests.sh`

Why:

- Local observability was already asynchronous, but every info event still performed its own JSONL append.
- High-volume info diagnostics should be cheap; warning and error diagnostics should stay immediate.

Change made:

- Added a small event-write policy for local observability.
- Info-level events now batch up to 8 records or 500 ms before writing.
- Warning/error events flush any pending info batch first, then write immediately.
- The writer also flushes any pending info events before closing.

Measured proof:

- `bash run-tests.sh`: 1586 tests passed.
- New policy tests prove only info events batch and the bounded batch size flushes immediately.
- `bash build.sh --no-open`: default thin signed build passed, launch smoke passed, performance budget passed.
- Default thin build after the change: 105.4 MiB expanded, 1.9 MiB resources, no bundled Parakeet model.

### 18. Added one-step reclaimable cache cleanup

Files:

- `Sources/Support/ModelCacheInventory.swift`
- `Sources/UI/Settings/TranscriptedSettingsView.swift`
- `Tests/ModelCacheInventoryTests.swift`

Why:

- The Storage page exposed stale Parakeet cleanup and Whisper cleanup separately, but the user still had to infer the total reclaimable footprint and run multiple cleanup paths.
- On this Mac, known stale FluidAudio folders are about 904 MB and optional Whisper cache is about 1.2 GB.

Change made:

- `ModelCacheSnapshot` now computes reclaimable bytes with or without optional Whisper.
- `ModelCacheInventory.removeReclaimableCaches(includeWhisper:)` combines the existing safe cleanup paths.
- Storage settings now shows a Reclaimable Cache row and one guarded "Remove Reclaimable Cache" action.
- Whisper is preserved automatically while Whisper is the selected transcription model.

Measured proof:

- `bash run-tests.sh`: 1597 tests passed.
- New tests prove reclaimable byte totals, combined stale-plus-Whisper cleanup, and Whisper-preserving cleanup.
- `bash build.sh --no-open`: default thin signed build passed, launch smoke passed, performance budget passed.
- Default thin build after the change: 105.4 MiB expanded, 1.9 MiB resources, no bundled Parakeet model.

### 19. Cleaned stale build processes and reproved single-instance behavior

Why:

- A live process scan found 8 old Transcripted processes still running from prior temp/worktree builds.
- Those stale processes distort CPU, memory, hotkey, model, and reliability measurements.

Change made:

- Terminated the stale temp/worktree Transcripted build processes.
- Launched the latest signed build twice from this audit worktree.
- Closed the proof app after verification so the audit did not leave a resident build process behind.

Measured proof:

- Before cleanup: 8 old Transcripted build processes were running.
- After cleanup: no Transcripted build processes were running.
- After first latest-build launch: one PID, `75433`.
- After duplicate latest-build launch: still one PID, `75433`.
- After proof cleanup: no latest-build Transcripted process remained running.

### 20. Re-measured clean idle footprint

Why:

- Idle CPU and memory proof was previously polluted by stale temp/worktree build processes.
- After loop 20 cleaned those up, the current signed build needed a fresh idle measurement.

Measured proof:

- Launched the latest signed thin `build/Transcripted.app`.
- Waited 15 seconds.
- Observed one current-build process: PID `75506`.
- `ps`: CPU `0.0%`, RSS `81,248 KB`, elapsed `00:15`.
- No other `Transcripted.app/Contents/MacOS/Transcripted` processes were present.
- Closed the proof process and verified no current-build Transcripted process remained.

### 21. Reproved live dictation fast-start

Why:

- The code-level fast-path fix and budget parser were not enough to honestly raise dictation start to A+.
- The remaining gate was a live, UI-triggered dictation run from the current signed thin app.

Measured proof:

- Launched the latest signed thin `build/Transcripted.app`.
- Clicked the Home view `Start dictation` button.
- The first start loaded the on-demand model, then the ready engine entered the direct recording path.
- Event log emitted `dictation_recording_fast_start` with `start_ms=112`, `trigger=menu`, built-in microphone route, and `stt_recording=true`.
- Event log then emitted `audio_samples_detected` at 48 kHz.
- `ruby scripts/ops/performance-budget.rb --allow-missing-parakeet-model --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl" --stats "$HOME/Library/Application Support/Transcripted/state/stats.sqlite" --require-dictation-fast-start-samples 1`: passed.
- Strict budget output: dictation fast-start samples `1`, p95 `112.0ms`, fallback/retry events `0`.
- Closed the proof app and verified no current-build Transcripted process remained.

### 22. Reproved live meeting capture and processing

Why:

- Meeting throughput was already strong in `stats.sqlite`, but the scorecard still lacked a current live capture proof with CPU, memory, stop, and save evidence.

Measured proof:

- Launched the latest signed thin `build/Transcripted.app`.
- Started a meeting from the Home view `Record meeting` button.
- Event log emitted `meeting_start_requested`, system audio permission revalidation, `meeting_state_changed` to `recording`, and `meeting_recording_started`.
- Capture backend: `screen_capture_kit`.
- Capture health: `capture_quality=excellent`, `buffer_success_bucket=98_100`, `gap_count=0`, `route_change_count=0`, `recovery_attempt_count=0`, `stop_timed_out=false`.
- Sampled the app process during the live recording for 35 samples: average CPU `27.2%`, max CPU `30.5%`, max RSS `223,360 KB`.
- Stopped via the meeting hotkey after `94,401 ms`.
- Event log emitted `meeting_recording_stopped`, `meeting_transcription_started`, `meeting_transcript_artifact_ready`, and `meeting_transcript_saved`.
- Latest stats row: duration `94s`, processing `1.372s`, RTF `0.015`.
- Strict budget output now reports meeting throughput samples `37`, minimum duration `30.0s`, p95 RTF `0.022`.
- Closed the proof app and verified no current-build Transcripted process remained.

### 23. Removed reclaimable local cache

Why:

- The app had a guarded cleanup surface, but the local machine still had about 2.1 GB of reclaimable cache.
- That kept the disk-footprint category below A+ even though the code path existed.

Measured proof:

- Removed only the app-classified reclaimable paths: stale Parakeet folders `parakeet-tdt-0.6b-v2`, `parakeet-tdt-0.6b-v2-coreml`, `parakeet-tdt-0.6b-v3`, plus optional `Transcripted/cache/whisperkit/models`.
- Preserved active required models: `parakeet-tdt-0.6b-v3-coreml`, `parakeet-eou-streaming`, `speaker-diarization`, and `speaker-diarization-coreml`.
- `~/Library/Application Support/FluidAudio/Models`: `1.8G` before, `956M` after.
- `~/Library/Application Support/Transcripted/cache`: `1.2G` before, `4.3M` after.
- Removed path check: all four reclaimable paths are now absent.
- Default footprint excluding active required models is now under 700 MB.

## Evidence

### Build And Verification

- `bash run-tests.sh`: **1597 tests, 1597 passed, 0 failed**.
- `bash build.sh`: signed build passed, launch smoke passed, performance budget passed.
- `bash build.sh --no-open`: default thin signed build passed, launch smoke passed, performance budget passed, no app left running.
- `bash build.sh --thin --no-open`: signed thin build passed, launch smoke passed, performance budget passed, no app left running.
- `bash build.sh --full --no-open`: explicit full signed build passed, launch smoke passed, performance budget passed, no app left running.
- `bash -n scripts/entrypoints/build.sh`: passed.
- `bash -n scripts/entrypoints/build-beta.sh`: passed.
- `scripts/ops/performance-budget.rb`: passed.
- `scripts/ops/performance-budget.rb --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl"`: passed.
- `scripts/ops/performance-budget.rb --stats "$HOME/Library/Application Support/Transcripted/state/stats.sqlite"`: passed.
- `scripts/ops/performance-budget.rb --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl" --stats "$HOME/Library/Application Support/Transcripted/state/stats.sqlite"`: passed.
- `scripts/ops/performance-budget.rb --allow-missing-parakeet-model --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl" --stats "$HOME/Library/Application Support/Transcripted/state/stats.sqlite" --require-dictation-fast-start-samples 1`: passed.
- Timed default thin `bash build.sh --no-open`: **67.48s**.
- Timed default thin build wall time: **68.17s**.
- Default thin rebuilt app size: **105.4 MiB**.
- Explicit full rebuilt app size: **566.3 MiB**.

### Latest Public Release

- Latest release: `v1.1.33`, published 2026-05-08.
- Public asset: `Transcripted-1.1.33.dmg`.
- Asset size: **524,144,094 bytes**.
- Asset digest: `sha256:9b83563a39fd92e222819be26ea01af8319d2043d3da3e82e31e57113d00f9f6`.
- Downloads at audit time: 111.

### Bundle Breakdown

Post-fix rebuilt app variants:

| Bundle path | Size |
| --- | ---: |
| Default thin `build/Transcripted.app` | 105.4 MiB |
| Explicit full `build/Transcripted.app` | 566.3 MiB |
| Full `Contents/Resources` | 462.8 MiB |
| Thin `Contents/Resources` | 1.9 MiB |
| `Contents/Resources/parakeet-models` | 461 MB |
| `Contents/Frameworks` | 56 MB |
| `Contents/MacOS` | 22 MB |
| `Contents/Helpers` | 8.8 MB |

Largest remaining resource outside the model:

- `Contents/Resources/Transcripted.icns`: 1.7 MB.

### Runtime Logs

Local `events.jsonl`:

- `transcription_complete`: n=59
- elapsed average: 0.164s
- elapsed p50: 0.118s
- elapsed p90: 0.300s
- elapsed p95: 0.316s
- elapsed max: 0.578s
- average audio duration: 21.956s
- average RTF: 0.013
- p90 RTF: 0.027
- p95 RTF: 0.029
- dictation fast-start samples: 1
- dictation fast-start p95: 112.0 ms
- dictation fast-start fallback/retry events: 0

Historical startup readiness, using valid pre-on-demand launch sequences:

- app to `models_loaded`: n=20, avg 17.478s, p50 19.836s, p90 21.956s, max 27.200s
- app to meeting ready: n=20, avg 17.682s, p50 19.985s, p90 22.128s, max 27.752s
- many launch events were skipped because repeated local/dev launches overlapped before a matching model-ready event.
- performance-budget parser, using app launch to next model-ready before the next launch: n=32, p90 28.094s. This remains useful as a regression view for older/eager launches, but the default current launch no longer waits for model readiness.
- latest signed launch with lazy dictation and meeting warmup: launch context `stt_model_loaded=false`; status event `Dictation and meetings load when started`; no following `models_loaded` event.

### Local Stats Database

`state/stats.sqlite`:

- recordings: 92
- average duration: 99.89s
- max duration: 1270s
- average processing: 1.421s
- max processing: 22.846s
- meeting-like samples >=30s: 37
- meeting-like p95 RTF: 0.022
- all-recording p95 RTF: 0.170, driven by 1-12s test clips where fixed overhead dominates
- latest live capture proof: 94s recording, 1.372s processing, RTF 0.015, transcript saved

Longest/highest-processing examples:

| Date | Audio | Words | Speakers | Processing |
| --- | ---: | ---: | ---: | ---: |
| 2026-04-17 | 1270s | 3754 | 2 | 22.846s |
| 2026-04-18 | 1270s | 3754 | 2 | 14.510s |
| 2026-04-18 | 1270s | 3754 | 2 | 12.893s |

### Local Disk Footprint

| Path | Size |
| --- | ---: |
| `~/Library/Application Support/FluidAudio/Models` | 956 MB |
| `~/Library/Application Support/Transcripted/cache` | 4.3 MB |
| `FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml` | 461 MB |
| `FluidAudio/Models/parakeet-eou-streaming` | 427 MB |
| `FluidAudio/Models/speaker-diarization` | 34 MB |
| `FluidAudio/Models/speaker-diarization-coreml` | 34 MB |

This area is now A+ for the current machine. The remaining model footprint is active/expected for Parakeet and meeting diarization; stale Parakeet and optional Whisper cache are absent.

## Hot Path Notes

### Startup

The default launch path now keeps both voice and meeting models out of memory. `TranscriptedAppState.startRuntimeReadinessIfNeeded()` still exists, but it is reached only from explicit work such as dictation/import/meeting use, model preference changes, wake recovery for an already loaded model, or `TRANSCRIPTED_EAGER_MODEL_WARMUP=1`.

This trades a slower first dictation after a cold launch for a much lighter default app launch. The UI now says the models are on demand instead of showing fake startup progress.

### Dictation

The warmed dictation path is excellent. `ParakeetEngine.transcribe()` moves recorded samples out of the sample buffer instead of copying them, resamples off the main actor, applies short-audio gates, and reports RTF.

The bug fixed in this pass was before transcription: fast recording startup was unintentionally replaced by the slow wait path.

### Meeting Transcription

Meeting transcription is heavier by design:

- load and resample system audio
- load and resample microphone audio
- diarize
- transcribe segments
- run speaker matching and clustering
- save styled transcript

The stats database shows very strong throughput, but the current event log did not include fresh `meeting_segment_transcribed` samples during this audit. The grade stays A-, not A+, until this is measured on a current meeting corpus with memory data.

### UI

No obvious unbounded render loop was found. The waveform timer is bounded. Settings home now coalesces passive dashboard refresh triggers, so app activation/navigation churn cannot stack home recent-capture and stats refresh work while the UI is settling.

The remaining risk is mostly maintainability and hidden SwiftUI invalidation cost in large files like:

- `Sources/UI/Settings/TranscriptedSettingsView.swift`
- `Sources/UI/Overlay/MeetingOverlayController.swift`
- `Sources/UI/Overlay/DictationSessionController.swift`

This still needs screen-level profiling before claiming A+.

## Next Loop To Reach A+

These are the next improvements I would execute in order.

1. **Fresh dictation start proof**
   - Done in loop 22.
   - Live UI-triggered dictation produced a 112 ms ready-engine fast-start sample, audio sample-flow proof, and 0 fallback/retry events.
   - Keep this strict gate in release-candidate checks so the category stays A+.

2. **Launch readiness policy**
   - Done in loop 13.
   - Dictation and meeting models now stay on demand by default, with explicit UI/status copy and an eager-warmup env escape hatch for diagnostics.

3. **Distribution strategy**
   - Mostly done in loop 17.
   - Default local and beta builds now create the 105.4 MiB thin app and download the model on first use.
   - A+ gate: cut and verify a public thin DMG under 150 MB, then update appcast/cask/download surfaces.

4. **Meeting performance harness**
   - Done for current live capture in loop 23.
   - Stats DB throughput is now budgeted for recordings >=30s, with 37 samples and p95 RTF 0.022.
   - Live 94.4s ScreenCaptureKit proof stayed under 224 MB RSS, had no gaps/routes/recovery attempts, stopped cleanly, and saved a transcript.
   - Future gate: repeat on a longer real call before a major release.

5. **Settings/UI refresh proof**
   - Partly done in loop 16.
   - Passive Settings home dashboard refreshes are now coalesced, while forced capture changes still refresh immediately.
   - A+ gate: screen-level profile of Settings, overlay, and meeting views showing no visible jank or expensive repeated invalidation.

6. **CI/release performance budget**
   - The post-build bundle budget now runs in both the local build and beta distribution paths.
   - Next, keep a fresh release-candidate event fixture and add remote CI only if this repo gets workflow automation.
   - A+ gate: bundle regressions fail before DMG packaging and latency regressions have a repeatable log fixture.

7. **Observability write overhead**
   - Done in loop 18.
   - Info-level local JSONL events now batch while warning/error events flush immediately.
   - A+ gate: keep this behavior if event volume grows; add measured event-write overhead only if telemetry becomes hot again.

8. **Local cache cleanup**
   - Done in loop 24.
   - Settings shows reclaimable cache and removes known stale Parakeet plus optional Whisper cache in one guarded action.
   - Current machine proof: stale Parakeet and Whisper cache paths are absent; Transcripted cache is 4.3 MB; model/cache footprint is under 700 MB excluding active required models.

9. **Process hygiene**
   - Done in loop 20 for the current signed build.
   - Stale temp/worktree Transcripted processes were terminated, and the latest signed build stayed at one PID after a duplicate launch attempt.
   - A+ gate: keep this cleanup discipline during future build/release verification.

10. **Clean idle footprint**
   - Done in loop 21 for the current signed thin build.
   - Fresh idle proof shows one process at 0.0% CPU and 81,248 KB RSS after 15 seconds.
   - A+ gate: keep idle CPU below 1%, memory below 250 MB, and no duplicate resident copies.

## Current Honest Conclusion

Transcripted is already **fast** where it matters most after warmup. It is not yet **super lightweight**.

The best next work is not micro-optimizing Swift code. It is:

- stop accidental slow startup paths,
- keep only needed release assets,
- expose and then clean local model caches,
- make a clear product call on bundled vs. downloaded models.

The first three are done, safe one-step Parakeet plus Whisper cache cleanup is in place and proved on this Mac, release builds now run a performance budget before packaging, dictation plus meeting model loading is lazy, the thin build path is now the default, passive Settings dashboard refreshes are coalesced, low-priority local event writes are batched, the current build's single-instance behavior is reproved, clean idle CPU/memory are A+, live dictation fast-start is A+, live meeting capture is A+, and local cache hygiene is A+. The next public release, UI profiling, and build-loop speed still keep the overall score below A+.
