# Autoeval: Dictation Stop To Final Text

## Verdict

Kept one small win: save the dictation Markdown immediately after paste, before
the optional auto-enter delay.

This does not change STT speed. It removes a fixed wait from the saved-artifact
path for users with auto-enter enabled. Baseline logs show that wait is about
217 ms.

## Metric

- Primary: time from `dictation_stop_requested` to final text ready, pasted, and
  saved.
- Text ready source: `transcription_complete` timestamp.
- Saved source: `dictation_export_saved` timestamp.
- Delivery source: `dictation_delivery_completed` timestamp.
- Guardrails: final text unchanged, paste still first, saved Markdown still
  written, auto-enter still only runs after a real paste, no no-speech changes,
  no privacy payload changes.

## Actual Path Read

`Sources/UI/Overlay/DictationSessionController.swift` owns stop orchestration:

1. record `dictation_stop_requested`
2. `await appState.sttRouter.stopRecording()`
3. wait for model readiness if needed
4. set overlay to drafting
5. `await appState.sttRouter.transcribe()`
6. clean filler text if enabled
7. paste with `ClipboardRestoringTextPaster`
8. save through `DictationTranscriptStore`
9. optional auto-enter through `DictationAutoSender`
10. record `dictation_delivery_completed`

`Sources/Speech/STTRouter.swift` routes dictation transcription to
`ParakeetEngine.transcribe()` for the default model.

`Sources/Speech/ParakeetEngine.swift` drains native samples, resamples to 16 kHz,
applies the short-audio gate, runs `AsrManager.transcribe`, applies custom
dictionary replacements, and records `transcription_complete` with `elapsed_s`,
`audio_duration_s`, and `rtf`.

## Commands And Log Sources

- `git status --short`
- repo guidance: `AGENT_START.md`, `README.md`, `AGENTS.md`,
  `docs/repo-layout.md`, `docs/agent-onboarding.md`, `CLAUDE.md`,
  `Sources/CLAUDE.md`, `Sources/UI/CLAUDE.md`, `Sources/Speech/CLAUDE.md`,
  `Sources/Dictation/CLAUDE.md`, `Sources/Support/CLAUDE.md`, `Tests/README.md`
- source search: `rg "dictation_stop_requested|transcription_complete|dictation_delivery_completed|dictation_export_saved|elapsed_s|rtf"`
- baseline log: `~/Library/Application Support/Transcripted/logs/events.jsonl`
- parser: Ruby JSONL scan pairing `dictation_stop_requested` ->
  `transcription_complete` -> `dictation_export_saved` ->
  `dictation_delivery_completed`
- verification: `bash scripts/dev/agent-preflight.sh`,
  `bash build.sh --no-open`, `bash run-tests.sh`

## Baseline Raw Results

Representative app `1.1.44` rows from local event logs:

| Case | Stop timestamp | Audio s | Stop->text s | Stop->saved s | Stop->delivery s | Inference s | RTF | Auto-enter |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| very short 3-5s | 2026-05-31T18:29:01.256Z | 3.4 | 0.119 | 0.336 | 0.338 | 0.099 | 0.029 | sent_enter |
| short 10-15s | 2026-05-31T18:36:40.172Z | 11.4 | 0.129 | 0.345 | 0.347 | 0.114 | 0.010 | sent_enter |
| medium 30-45s | 2026-05-31T02:09:16.948Z | 30.6 | 0.239 | 0.451 | 0.453 | 0.228 | 0.007 | sent_enter |
| long 90-120s | 2026-05-29T20:05:20.980Z | 91.5 | 0.741 | 0.964 | 0.965 | 0.721 | 0.008 | sent_enter |
| long 90-120s | 2026-05-31T01:44:19.581Z | 118.2 | 0.638 | 0.641 | 0.642 | 0.617 | 0.005 | disabled |

Aggregate proof of the stall:

| Segment | Samples | Avg stop->text s | Avg stop->saved s | Avg saved-text gap s | P50 gap s | P95 gap s |
|---|---:|---:|---:|---:|---:|---:|
| app 1.1.44, auto-enter sent | 40 | 0.186 | 0.403 | 0.217 | 0.217 | 0.222 |
| app 1.1.44, auto-enter disabled | 4 | 0.444 | 0.540 | 0.096 | 0.005 | 0.375 |

The auto-enter path was saving after `dictationAutoEnterDelay` (`200 ms`), so
saved Markdown readiness lagged text readiness by the fixed auto-enter wait.

## Knobs Tested

| # | Knob | Change | Raw result | Decision |
|---|---|---|---|---|
| 1 | Move save before auto-enter wait | `paste -> save -> autoEnter` instead of `paste -> autoEnter -> save` | Removes the observed 0.217s average text-to-save gap for auto-enter sessions, while preserving paste first | Kept |
| 2 | Reduce STT inference work | Considered resampling, chunking, empty-retry, and short-audio paths | Baseline RTF was already 0.005-0.029 for the target rows | Rejected as higher risk |
| 3 | Move overlay/logging before transcription | Considered moving drafting UI/log work | Expected win is tiny compared with the fixed 200 ms auto-enter wait | Rejected |
| 4 | Change no-speech or short-audio behavior | Considered short-audio/no-speech gates | Would risk correctness and no-speech behavior | Rejected |

## Kept Change

- `Sources/UI/Overlay/DictationSessionController.swift`
  - `persistDictationTranscript(...)` now runs immediately after
    `pasteWithClipboardRestore(...)`.
  - `performAutoEnterIfNeeded(...)` still runs only after a pasted delivery.

## Tests Run

- `bash build.sh --no-open`
  - passed, including signature verification, launch smoke, and performance
    budget
- `bash run-tests.sh`
  - passed, `2929 tests, 2929 passed, 0 failed`

## Remaining Risks

- I did not replay fresh live dictation audio after the code change, because the
  installed production app was already running and the proof did not require
  disrupting foreground audio.
- `dictation_delivery_completed` still includes the optional auto-enter wait by
  design. The improved metric is stop-to-saved Markdown, not stop-to-auto-enter.
- A future pass should add first-class stop-to-text and stop-to-saved summaries
  to `scripts/ops/performance-budget.rb` so this does not need an ad hoc parser.
