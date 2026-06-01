# Autoeval: dictation stop-to-final-text speed

## Verdict

Kept one narrow win: save the Markdown dictation artifact before the optional Auto Enter delay.

This does not make Parakeet transcription faster. It makes saved Markdown ready about 170-210ms sooner for very short, short, and medium dictations when Auto Enter is enabled. Long dictation had noisy inference samples, but the save-after-text gap still dropped from about 211ms to about 1ms.

## Metric

- Primary measured values: stop-to-text, stop-to-saved, stop-to-delivery.
- Guardrails: stable transcript hash/word count, no no-speech regression, saved Markdown still written, no real clipboard/paste mutation during benchmark.

The benchmark uses synthetic local audio fixtures and injects samples into the app-owned `ParakeetEngine.transcribe()` dictation path. It intentionally avoids real paste events so the run does not touch the user clipboard or focused app.

## Commands and sources

- Repo/path: `/Users/redbars/.codex/worktrees/dictation-stop-full-autoeval`
- Stop path read: `Sources/UI/Overlay/DictationSessionController.swift`, `Sources/Speech/STTRouter.swift`, `Sources/Speech/ParakeetEngine.swift`, `Sources/Dictation/`
- Existing timing read: `transcription_complete`, `dictation_export_saved`, `dictation_delivery_completed`, `dictation_no_speech`, `scripts/ops/performance-budget.rb`
- Build: `bash build-deps.sh --force`, `bash build.sh --no-open --full`
- Baseline: `bash scripts/ops/dictation-stop-autoeval.sh --label baseline --variant native --iterations 3 --skip-build --finalization-order saveAfterAutoEnter`
- Save-before knob: `bash scripts/ops/dictation-stop-autoeval.sh --label save-before-auto-enter --variant native --iterations 3 --skip-build --finalization-order saveBeforeAutoEnter`
- Pre-resample knob: `bash scripts/ops/dictation-stop-autoeval.sh --label pre-resampled --variant pre_resampled --iterations 3 --skip-build`
- Chunking knob: `bash scripts/ops/dictation-stop-autoeval.sh --label chunked-30s --variant chunked --iterations 3 --skip-build --chunk-seconds 30`
- No-speech guardrail: `bash scripts/ops/dictation-stop-autoeval.sh --label no-speech-guardrail --variant native --iterations 1 --skip-build --include-silence`
- Auto Enter control: `bash scripts/ops/dictation-stop-autoeval.sh --label no-auto-enter-control --variant native --iterations 3 --skip-build --no-auto-enter`
- Raw JSONL source during run: `.autoeval/dictation-stop/results/*.jsonl` (raw values copied below; scratch dir is ignored)
- Fake app event logs during run: `.autoeval/dictation-stop/home-*/Library/Application Support/Transcripted/logs/events.jsonl`

## Baseline averages

Baseline is current behavior: paste, wait for Auto Enter, then save.

| case | audio_s | avg text_s | avg saved_s | avg delivery_s | saved-text gap | hash | words |
|---|---:|---:|---:|---:|---:|---|---:|
| very_short | 3.901 | 0.054 | 0.264 | 0.264 | 0.210 | 704c86dde71b597a | 10 |
| short | 10.877 | 0.073 | 0.285 | 0.285 | 0.212 | a3d0a8ebd83a0e74 | 32 |
| medium | 36.523 | 0.230 | 0.441 | 0.441 | 0.211 | 9057a70955b9864f | 114 |
| long | 111.802 | 0.692 | 0.903 | 0.903 | 0.211 | 377df7bb87e3d01e | 326 |

## Knob results

| # | Knob | Status | Raw result | Decision |
|---|---|---|---|---|
| 1 | Save before Auto Enter | kept | saved-text gap went from ~210-212ms to ~0-1ms. Short avg saved 0.285s -> 0.093s. Medium avg saved 0.441s -> 0.272s. | Keep. Improves saved artifact readiness without changing transcript hash. |
| 2 | Pre-resample before stop-time measurement | rejected | Same hashes, but avg text was not better: short 0.090s, medium 0.265s, long 0.735s. Preprocess cost was only 0-2ms. | Reject. Resampling is too small to matter. |
| 3 | 30s chunked transcription | rejected | Medium/long changed hash and word count: medium 114 -> 117 words, long 326 -> 323 words. Speed was not a clear win. | Reject. Correctness drift. |
| 4 | Short/no-speech tuning | ruled out | very_short transcribed successfully. 5s silence returned no text and no saved Markdown in 0.032s. | Do not change. Current gate is not slowing requested speech cases. |
| 5 | Model warm reuse | ruled out | Cold model init was 12-17s per benchmark app launch, but the stop benchmark runs with the model already loaded, matching normal started-recording behavior. | Not a stop-path knob. Startup/warmup is separate. |
| 6 | UI/logging before transcribe | ruled out | Code path before transcribe has stopRecording/model-ready check/overlay state/diagnostics. No-auto-enter control had saved/delivery ~= text time. | No measurable pre-transcribe win found in this scoped harness. |

## Raw results

### Baseline: save after Auto Enter

| case | iter | audio_s | text_s | saved_s | delivery_s | words | hash |
|---|---:|---:|---:|---:|---:|---:|---|
| very_short | 1 | 3.901 | 0.049 | 0.259 | 0.259 | 10 | 704c86dde71b597a |
| very_short | 2 | 3.901 | 0.048 | 0.259 | 0.259 | 10 | 704c86dde71b597a |
| very_short | 3 | 3.901 | 0.065 | 0.274 | 0.274 | 10 | 704c86dde71b597a |
| short | 1 | 10.877 | 0.072 | 0.281 | 0.281 | 32 | a3d0a8ebd83a0e74 |
| short | 2 | 10.877 | 0.074 | 0.288 | 0.288 | 32 | a3d0a8ebd83a0e74 |
| short | 3 | 10.877 | 0.073 | 0.285 | 0.285 | 32 | a3d0a8ebd83a0e74 |
| medium | 1 | 36.523 | 0.222 | 0.435 | 0.435 | 114 | 9057a70955b9864f |
| medium | 2 | 36.523 | 0.231 | 0.442 | 0.442 | 114 | 9057a70955b9864f |
| medium | 3 | 36.523 | 0.237 | 0.447 | 0.447 | 114 | 9057a70955b9864f |
| long | 1 | 111.802 | 0.735 | 0.948 | 0.948 | 326 | 377df7bb87e3d01e |
| long | 2 | 111.802 | 0.658 | 0.868 | 0.868 | 326 | 377df7bb87e3d01e |
| long | 3 | 111.802 | 0.683 | 0.892 | 0.892 | 326 | 377df7bb87e3d01e |

### Kept knob: save before Auto Enter

| case | iter | audio_s | text_s | saved_s | delivery_s | words | hash |
|---|---:|---:|---:|---:|---:|---:|---|
| very_short | 1 | 3.901 | 0.072 | 0.072 | 0.282 | 10 | 704c86dde71b597a |
| very_short | 2 | 3.901 | 0.062 | 0.063 | 0.273 | 10 | 704c86dde71b597a |
| very_short | 3 | 3.901 | 0.047 | 0.047 | 0.256 | 10 | 704c86dde71b597a |
| short | 1 | 10.877 | 0.107 | 0.107 | 0.319 | 32 | a3d0a8ebd83a0e74 |
| short | 2 | 10.877 | 0.099 | 0.100 | 0.312 | 32 | a3d0a8ebd83a0e74 |
| short | 3 | 10.877 | 0.071 | 0.071 | 0.283 | 32 | a3d0a8ebd83a0e74 |
| medium | 1 | 36.523 | 0.257 | 0.257 | 0.469 | 114 | 9057a70955b9864f |
| medium | 2 | 36.523 | 0.348 | 0.348 | 0.559 | 114 | 9057a70955b9864f |
| medium | 3 | 36.523 | 0.210 | 0.210 | 0.423 | 114 | 9057a70955b9864f |
| long | 1 | 111.802 | 0.785 | 0.787 | 0.999 | 326 | 377df7bb87e3d01e |
| long | 2 | 111.802 | 1.827 | 1.828 | 2.040 | 326 | 377df7bb87e3d01e |
| long | 3 | 111.802 | 0.768 | 0.769 | 0.981 | 326 | 377df7bb87e3d01e |

### Rejected probes

| attempt | case | avg text_s | avg saved_s | avg delivery_s | correctness |
|---|---|---:|---:|---:|---|
| pre_resampled | very_short | 0.062 | 0.062 | 0.273 | same hash, 10 words |
| pre_resampled | short | 0.090 | 0.090 | 0.300 | same hash, 32 words |
| pre_resampled | medium | 0.265 | 0.266 | 0.475 | same hash, 114 words |
| pre_resampled | long | 0.735 | 0.736 | 0.943 | same hash, 326 words |
| chunked_30s | very_short | 0.045 | 0.045 | 0.254 | same hash, 10 words |
| chunked_30s | short | 0.068 | 0.068 | 0.275 | same hash, 32 words |
| chunked_30s | medium | 0.245 | 0.245 | 0.456 | changed hash, 117 words |
| chunked_30s | long | 0.703 | 0.704 | 0.914 | changed hash, 323 words |
| no_auto_enter_control | very_short | 0.051 | 0.051 | 0.051 | same hash, 10 words |
| no_auto_enter_control | short | 0.074 | 0.075 | 0.075 | same hash, 32 words |
| no_auto_enter_control | medium | 0.228 | 0.229 | 0.229 | same hash, 114 words |
| no_auto_enter_control | long | 0.692 | 0.693 | 0.693 | same hash, 326 words |

## Kept changes

- `Sources/Dictation/DictationStopFinalizationPolicy.swift`: tiny policy for finalization order.
- `Sources/UI/Overlay/DictationSessionController.swift`: save before optional Auto Enter.
- `Sources/Speech/ParakeetEngine.swift`: benchmark-only sample injection hook.
- `Sources/Dictation/DictationStopBenchmarkRunner.swift`: env-gated benchmark runner.
- `Sources/TranscriptedApp.swift`: exits into benchmark runner when env is set.
- `scripts/ops/dictation-stop-autoeval.sh`: repeatable fixture generation, benchmark execution, and summary.
- `.gitignore`: ignores local `.autoeval/` scratch output.

## Rejected attempts

- Pre-resampling: no meaningful speed win; resampling cost was 0-2ms.
- Chunking: changed medium/long transcript hashes and word counts.
- Short/no-speech tuning: no-speech behavior was already fast and correct in the guardrail case.

## Risks

- This is a controlled synthetic-audio benchmark. It does not include real CoreAudio stop latency or real clipboard paste latency.
- The benchmark avoids raw transcript text in JSONL and records only hashes/counts.
- Long dictation inference showed noisy samples, so the kept change should be understood as a finalization-order win, not an ASR throughput win.

## Tests run

- `bash build-deps.sh --force`
- `bash build.sh --no-open --full`
- `bash scripts/ops/dictation-stop-autoeval.sh ...` for baseline, kept knob, rejected probes, no-speech guardrail, and no-auto-enter control
- `bash build.sh --no-open`
- `bash run-tests.sh` (2926 passed, 0 failed)
