# Transcripted Lab architecture

Transcripted Lab is the regression and experiment surface for Transcripted. It lives as a standalone package under `Tools/TranscriptedLab` and does not ship inside the customer app.

## Contract

```text
Experiment configuration
        │
        ▼
TranscriptedLabKit command adapter
        │
        ├── runtime events analyzer
        ├── production dictation benchmark
        ├── corpus compare QA lane
        ├── speaker eval / auto-research
        └── repository QA bench
        │
        ▼
Versioned aggregate report
        │
        ├── hard gates
        ├── dimension scores
        ├── p50 / p95 / p99 metrics
        ├── local artifact pointers
        └── baseline → candidate deltas
```

The SwiftUI app and `transcripted-lab` CLI both call this contract. A result from the GUI and the equivalent CLI command must mean the same thing.

## Current score dimensions

- Runtime Snapshot: transcription speed, dictation start, dictation stop, reliability.
- Dictation Bench: stop/decode speed, delivery speed, text integrity.
- Speaker Threshold Sweep: false-merge safety, cross-meeting re-ID, fragmentation, DER.
- Transcription Corpus and QA: repository PASS/WARN/FAIL evidence.
- Speaker Auto-Research: keeps its native multi-gate holdout report; no flattened score yet.

## Isolation

Each Lab run gets its own artifact directory under Transcripted Lab Application Support. Existing benchmark scripts already isolate app homes and capture libraries where required. Corpus assets remain in their current gitignored locations so the Lab does not duplicate large audio collections.

## Next build slices

1. Add a first-token streaming event and a live partial-transcript latency lane when the production STT path has a stable event contract.
2. Add a dedicated labeled dictation corpus with WER/CER, names/numbers/punctuation buckets, and noise/device-route slices.
3. Normalize speaker auto-research holdout JSON into the app while preserving every safety gate and condition bucket.
4. Add campaign recipes so one click can sweep a bounded matrix and promote only candidates that beat the frozen baseline without a hard-gate regression.
5. Add a real-hardware lane for built-in mic, AirPods/HFP, USB microphones, sleep/wake, and route changes. CI remains correctness proof, not hardware latency proof.
