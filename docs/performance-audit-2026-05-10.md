# Transcripted Performance Audit

Date: 2026-05-10  
Repo snapshot: `5136fc24913cb3556fdb329f413837fdbd816587` (`origin/main`)  
Audited build: local signed `build/Transcripted.app`, version `1.1.33`  
Goal: raise every category toward A+/100 with measured fixes, not cosmetic scoring.

## Executive Score

Current score after two audit/fix loops: **88/100, B+**

Transcripted is very fast once the local model is warm. The strongest proof is dictation transcription: 59 local `transcription_complete` events averaged **0.164s** of processing for **21.956s** of audio, with p50 **0.118s**, p90 **0.300s**, and p95 **0.316s**.

The app does not yet feel "super lightweight" in the full sense. The main blockers are startup model readiness, disk/cache footprint, duplicate app-process hygiene in dev/local runs, and the 524 MB public DMG / 550 MB expanded app bundle. Most of the remaining bundle weight is the bundled 461 MB Parakeet CoreML model, which is a product tradeoff: fast offline first run vs. small installer.

## Scorecard

| Category | Grade | Score | Evidence | A+ Gate |
| --- | ---: | ---: | --- | --- |
| Warm dictation transcription latency | A+ | 99 | `transcription_complete` p50 0.118s, p90 0.300s, avg RTF 0.013 | Keep p95 under 0.500s and p95 RTF under 0.050 on local logs |
| Dictation start responsiveness | A- | 91 | Found and fixed fast-path fallthrough that replaced direct recording with recovery wait; old logs still show 61 `audio_start_deferred` events | Fresh live dictation run shows no fast-path deferral/retry on a ready engine |
| App launch and model readiness | C+ | 74 | Valid launch sequences: app to `models_loaded` avg 17.478s, p50 19.836s, p90 21.956s, max 27.200s | Visible app interactive under 2s, ready state under 10s, or explicit lazy-load UX |
| Idle CPU | A | 96 | Observed Transcripted app processes at 0.0% CPU; MCP helper about 0.2% CPU | Stay below 1% CPU idle after warmup |
| Idle memory | B | 83 | Warm app processes ranged from about 210 MB RSS to about 583 MB RSS depending on model state | Single process under 250 MB warm idle, no duplicate resident copies |
| Bundle and download size | B | 82 | Release DMG is 524,144,094 bytes; rebuilt app is 550 MB expanded after icon cleanup | DMG under 150 MB, or documented intentional offline-model bundle with optional thin build |
| Local disk/cache hygiene | D+ | 68 | `FluidAudio/Models` is 1.8 GB; Transcripted app support is 1.3 GB; WhisperKit cache is 1.2 GB | In-app cleanup/reporting, stale model pruning, normal default footprint under 700 MB excluding active bundled model |
| Meeting transcription throughput | A- | 92 | Stats DB: 91 recordings, avg 99.96s audio, avg processing 1.422s; worst 1270s recording processed in 22.846s | Corpus p95 RTF under 0.050 with memory cap proof |
| Meeting capture realtime path | A- | 90 | Dedicated capture/recovery code, async model gate, AGC uses vDSP, capture status events present | Live long-meeting profile shows stable CPU/memory and no dropped capture state |
| UI/rendering perceived lightness | B | 85 | Large SwiftUI/control files, but no clear hot render loop found; waveform timer is bounded at 30 fps | Screen/profile proof for settings, overlay, and meeting views with no jank |
| Observability overhead | A- | 91 | Async event capture, allowlisted analytics, local reliability packets; high launch chatter remains | Batch low-priority local events and keep privacy/event budgets tested |
| Build and dev loop speed | C+ | 78 | Fresh deps build took 3:26 wall; app build took 2:04 clean and 1:32 incremental after this pass | Normal app build under 60s on this machine, targeted test loop under 15s |
| Performance regression guardrails | A- | 93 | 1505 tests pass; repo contract tests now guard model duplication, icon bloat, and dictation fast start | Automated perf-budget parser for bundle size, startup, dictation latency, and cache size |
| Process hygiene / single-instance behavior | A- | 92 | Added file-lock single-instance guard; duplicate launch of the rebuilt app settled back to one running process | Release/current builds keep one effective Transcripted process per user session |

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

## Evidence

### Build And Verification

- `bash run-tests.sh`: **1510 tests, 1510 passed, 0 failed**.
- `bash build.sh`: signed build passed, launch smoke passed.
- Incremental post-fix build wall time: **1:10.95**.
- Rebuilt app size: **550 MB**.

### Latest Public Release

- Latest release: `v1.1.33`, published 2026-05-08.
- Public asset: `Transcripted-1.1.33.dmg`.
- Asset size: **524,144,094 bytes**.
- Asset digest: `sha256:9b83563a39fd92e222819be26ea01af8319d2043d3da3e82e31e57113d00f9f6`.
- Downloads at audit time: 111.

### Bundle Breakdown

Post-fix rebuilt app:

| Bundle path | Size |
| --- | ---: |
| `build/Transcripted.app` | 550 MB |
| `Contents/Resources` | 463 MB |
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

Startup readiness, using valid launch sequences only:

- app to `models_loaded`: n=20, avg 17.478s, p50 19.836s, p90 21.956s, max 27.200s
- app to meeting ready: n=20, avg 17.682s, p50 19.985s, p90 22.128s, max 27.752s
- many launch events were skipped because repeated local/dev launches overlapped before a matching model-ready event.

### Local Stats Database

`state/stats.sqlite`:

- recordings: 91
- average duration: 99.96s
- max duration: 1270s
- average processing: 1.422s
- max processing: 22.846s

Longest/highest-processing examples:

| Date | Audio | Words | Speakers | Processing |
| --- | ---: | ---: | ---: | ---: |
| 2026-04-17 | 1270s | 3754 | 2 | 22.846s |
| 2026-04-18 | 1270s | 3754 | 2 | 14.510s |
| 2026-04-18 | 1270s | 3754 | 2 | 12.893s |

### Local Disk Footprint

| Path | Size |
| --- | ---: |
| `~/Library/Application Support/FluidAudio/Models` | 1.8 GB |
| `~/Library/Application Support/Transcripted` | 1.3 GB |
| `~/Library/Application Support/Transcripted/cache` | 1.2 GB |
| `FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml` | 461 MB |
| `FluidAudio/Models/parakeet-tdt-0.6b-v3` | 461 MB |
| `FluidAudio/Models/parakeet-tdt-0.6b-v2-coreml` | 443 MB |
| `FluidAudio/Models/parakeet-eou-streaming` | 427 MB |
| `Transcripted/cache/whisperkit/models` | 1.2 GB |

This is the clearest "not lightweight" area. The app needs a cleanup surface and stale-model pruning.

## Hot Path Notes

### Startup

`TranscriptedAppState.startRuntimeReadinessIfNeeded()` starts model readiness at launch:

- `sttRouter.initializeSelectedModel()`
- `meetingSession.prepareModels(showLoadingUI: false)`

This keeps first dictation and meetings ready, but it creates the 17 to 22 second readiness window. The UI may still appear before that, but the app is not truly ready until the model load completes.

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

No obvious unbounded render loop was found. The waveform timer is bounded. The risk is mostly maintainability and hidden SwiftUI invalidation cost in large files like:

- `Sources/UI/Settings/TranscriptedSettingsView.swift`
- `Sources/UI/Overlay/MeetingOverlayController.swift`
- `Sources/UI/Overlay/DictationSessionController.swift`

This needs screen-level profiling before claiming A+.

## Next Loop To Reach A+

These are the next improvements I would execute in order.

1. **Fresh dictation start proof**
   - Run a clean single-instance build.
   - Trigger a ready-engine dictation.
   - Confirm no `audio_start_deferred` or `dictation_recording_retry` appears for the fast path.
   - Raise dictation start responsiveness to A+/98 only if the log proves it.

2. **Cache cleanup and stale model pruning**
   - Add a diagnostics/cleanup view that reports model/cache size.
   - Offer removal of stale FluidAudio models not needed by the active app.
   - Keep Whisper cleanup explicit because users may have selected Whisper.
   - A+ gate: user can recover multiple GB without Finder spelunking.

3. **Launch readiness policy**
   - Decide whether first-use speed or tiny launch footprint wins.
   - Option A: keep eager warmup, but make readiness state explicit and optimize model load time.
   - Option B: lazy-load models on first dictation/meeting and make installer/app launch feel much lighter.
   - A+ gate: either ready under 10s or honestly lazy with clear UX.

4. **Distribution strategy**
   - The bundled model is the reason the app is 550 MB expanded.
   - To reach A+ on download size, ship a thin app and download the model on first run, or provide separate full/offline and thin installers.
   - A+ gate: default DMG under 150 MB, or a conscious offline-first exception.

5. **Meeting performance harness**
   - Build a local corpus runner for a few anonymized/fixture meetings.
   - Track RTF, peak RSS, and segment counts.
   - A+ gate: p95 RTF under 0.050, stable memory, no main-thread stalls.

6. **CI performance budget**
   - Add a script that fails on resource bloat, duplicate model bundles, too many shipped assets, and performance log regressions.
   - A+ gate: bundle and latency regressions fail before release.

## Current Honest Conclusion

Transcripted is already **fast** where it matters most after warmup. It is not yet **super lightweight**.

The best next work is not micro-optimizing Swift code. It is:

- stop accidental slow startup paths,
- keep only needed release assets,
- expose and clean local model caches,
- make a clear product call on bundled vs. downloaded models.

The first three are done in this pass. Cache cleanup, launch readiness, and distribution strategy still keep the overall score below A+.
