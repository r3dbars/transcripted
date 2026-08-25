# Transcripted Lab

Transcripted Lab is a local macOS experiment workbench for Transcripted. It does not reimplement the app. It launches the repository's real speaker, transcription, dictation, and QA lanes, then stores one normalized report contract for every run.

The package contains:

- `TranscriptedLab` — native SwiftUI app for configuring experiments and comparing runs.
- `transcripted-lab` — headless CLI backed by the same runner, analyzers, scorecards, and report store.
- `TranscriptedLabKit` — reusable experiment configuration, process orchestration, metric parsing, scoring, and report persistence.

## Build and open the app

From the Transcripted repository root:

```bash
Tools/TranscriptedLab/script/build_and_run.sh
```

The script builds both products, creates `Tools/TranscriptedLab/dist/Transcripted Lab.app`, ad-hoc signs it, and opens it.

Verify without opening:

```bash
Tools/TranscriptedLab/script/build_and_run.sh --verify
```

## CLI

```bash
swift run --package-path Tools/TranscriptedLab transcripted-lab help
swift run --package-path Tools/TranscriptedLab transcripted-lab doctor
```

A few useful runs:

```bash
# Score the last seven days of production latency events.
swift run --package-path Tools/TranscriptedLab transcripted-lab snapshot \
  --window-hours 168 \
  --minimum-samples 10

# Exercise the real production dictation stop path five times per fixture.
swift run --package-path Tools/TranscriptedLab transcripted-lab run dictation-stop \
  --variant production \
  --repetitions 5 \
  --include-silence

# Sweep same-voice consolidation and cross-meeting match thresholds.
swift run --package-path Tools/TranscriptedLab transcripted-lab run speaker-identity \
  --speaker-mode threshold-sweep \
  --speaker-corpus ami \
  --consolidation "none 0.82 0.85 0.88 0.91" \
  --match "0.50 0.55 0.60 0.65 0.70"

# Run the existing quick QA lane.
swift run --package-path Tools/TranscriptedLab transcripted-lab run qa \
  --qa-mode quick
```

List, inspect, and compare saved runs:

```bash
swift run --package-path Tools/TranscriptedLab transcripted-lab list
swift run --package-path Tools/TranscriptedLab transcripted-lab show RUN_ID
swift run --package-path Tools/TranscriptedLab transcripted-lab compare BASELINE_ID CANDIDATE_ID
```

Every command also supports `--json` for automation.

## The benches

### Runtime Snapshot

Reads `~/Library/Application Support/Transcripted/logs/events.jsonl` by default and reports:

- transcription elapsed time and real-time factor at p50/p95/p99
- dictation fast start
- request-to-recording
- start-to-first-audio-sample
- stop-to-paste and stop-to-done
- fallback, retry, and deferred-start events

The targets mirror Transcripted's existing performance budget instead of creating new definitions of fast.

### Dictation Bench

Wraps `scripts/ops/dictation-stop-autoeval.sh` and the app's `DictationStopBenchmarkRunner`. It exposes:

- production, native, pre-resampled, and chunked paths
- repetitions
- encoder compute units
- finalization order
- Auto Enter delay
- chunk size
- silence guardrail

Hard gates catch missing saved text, speech/silence inversion, and output-hash drift across identical repetitions. This lane measures speed and consistency, not word error rate.

### Transcription Bench

Wraps the repository's `corpus-compare` QA mode. It validates a local truth corpus and compares Transcripted Markdown against the expected transcript using the repository's existing recall gates.

Use Runtime Snapshot beside it for production speed. A future lane can add first-token streaming latency once Transcripted ships a stable event for it.

### Speaker Bench

Two modes:

- **Threshold Sweep** runs `scripts/run_speaker_eval.sh` against AMI, ICSI, VoxConverse, or the bounded VoxCeleb sample. It scores DER, identity fragmentation, false merges, and cross-meeting re-identification.
- **ASK / SUGGEST / AUTO Research** runs the frozen, resumable speaker auto-research loop with train/dev/locked-holdout promotion gates.

False cross-person merges are hard failures. The threshold-sweep leaderboard is safety-first: zero false merges beats a more aggressive candidate with higher apparent recall.

The auto-research lane keeps its native final report rather than flattening false automatic names, open-set errors, and contamination gates into a fake single number.

### QA Bench

Wraps `scripts/ops/transcripted-qa-bench.sh` and normalizes its PASS/WARN/FAIL/SKIP output. Quick, deep, full, UI, packaged, artifact, synthetic audio, pasteback, and live modes are available.

## Storage and privacy

Lab reports live under:

```text
~/Library/Application Support/Transcripted Lab/Runs/
```

Run artifacts live under:

```text
~/Library/Application Support/Transcripted Lab/Artifacts/
```

Speaker corpora and their existing reports remain in Transcripted's gitignored `data/` paths. Transcripted Lab stores aggregate metrics, hashes, command output tails, and artifact paths. It does not copy raw audio or transcript bodies into the Lab report.

## Score rules

One average never gets to hide a serious failure. A run is failed before its number matters when it has conditions such as:

- a cross-person speaker merge
- missing final dictation text
- silence producing text
- identical audio producing unstable output hashes
- a blocking QA failure
- an experiment timeout or non-zero process exit

That is the whole point of the Lab: make regressions loud, reproducible, and hard to rationalize away.
