# Transcripted QA Test Bench

Use this when you want a QA-tester pass on Transcripted instead of one narrow
unit-test run.

The bench is an orchestrator. It calls the repo's existing checks, captures
logs, and writes one local report under:

```text
/tmp/transcripted-qa-bench/<run-id>/qa-report.md
```

## Quick Run

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode quick
```

This runs:

- `bash scripts/dev/agent-preflight.sh`
- `bash build.sh --no-open`
- `bash run-tests.sh`
- `bash run-e2e-smoke.sh`
- `bash run-slow-pasteback-smoke.sh`
- `bash scripts/ops/run-local-summary-fixture.sh`

It proves the app builds, fast tests pass, and deterministic meeting/dictation
artifact discovery plus fake slow-target pasteback still work without microphone
or TCC prompts. The local summary fixture also proves the Gemma summary app path
can start, finish, and rewrite a saved synthetic meeting into the expected
Markdown shape without private meeting content or a model download.

## Pasteback Synthetic Run

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode pasteback-synthetic
```

This runs only the fake slow Cmd+V target smoke. It writes a markdown subreport
beside the QA report and JSON under `raw/`. It proves the target-buffer result
for synthetic slow readers without using real dictation audio or the real
clipboard.

## Deep Run

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode deep
```

This adds:

- `bash run-integration-smoke.sh`
- `swift test`
- `swift test --package-path Tools/TranscriptedQA`
- `swift run --package-path Tools/TranscriptedQA transcripted-qa round-trip`
- a small `TranscriptedQA` stress pass
- `TranscriptedQA` health and live artifact validation
- `bash run-daily-audio-reliability.sh --synthetic`

The synthetic audio step also reports an audio route automation proxy matrix so
the bench names what is automated for dictation, meeting mic/system audio,
WebRTC/Zoom contention, Bluetooth/AirPods settling, and privacy/security. It
also generates deterministic meeting-route fixtures for shared mic, missing
system audio, quiet mic recovery/failure, output ducking, route churn, stop
timeout, and stop/save artifact outcomes. This does not replace live or manual
route proof.
Mocked Bluetooth/AirPods route contracts are automated policy proof, not hardware proof.
Real connected AirPods/Bluetooth hardware remains manual proof.

Deep inherits the deterministic local summary fixture from quick. That fixture
is shape and hang-guard proof only; real Gemma summary quality still needs
manual or corpus review.

Live artifact validation is non-blocking by default because a development Mac
may not have saved meetings yet. To make it strict:

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode deep --strict-artifacts
```

## Live Run

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode live
```

This adds the real mic + system-audio capture smoke:

```bash
bash run-live-capture-smoke.sh --skip-build
```

It requires local microphone permission and System Audio Recording permission.
If macOS blocks it, report that as `INCOMPLETE` or `FAIL` with the permission
reason. Do not treat a TCC blocker as product proof.

## Audio Synthetic Run

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode audio-synthetic
```

This runs `bash run-daily-audio-reliability.sh --synthetic`. It can prove the
deterministic route fixture matrix and the simulated artifact/failure contract.
It cannot prove real Zoom, Meet, browser WebRTC, Bluetooth/AirPods, TCC, or
user-perceived volume behavior. Issue #500 stays manual-required until the
dated matrix in `docs/qa-issue-500-meeting-audio.md` is run.

## Corpus Run

Use this when you want the QA tester to inspect Justin's local meeting corpus
from Downloads:

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode corpus
```

By default this reads:

```text
~/Downloads/meeting-corpus
```

It validates an audio-ready representative subset, checks local audio/transcript
presence, parses Zoom caption turns without printing transcript text, and writes
local-only corpus evidence into the QA run folder. The default subset is
`meeting-0024,meeting-0025`.

To choose exact meetings:

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode corpus --corpus-ids meeting-0024,meeting-0025
```

This does not commit the corpus and does not upload audio or transcripts. It is
the corpus-readiness and ground-truth check. Use it before comparing new
Transcripted output against the corpus.

The corpus is private local test data, so it stays out of the required agent
test matrix. Use the corpus mode only on machines that have the corpus.

## Short Output

Every bench report starts with a plain short answer:

```text
PASS: tested 504/504 checks. Good to go.
```

When something is flagged, it stays short:

```text
INCOMPLETE: tested 502/504 checks. Not good yet: 2 flagged.
```

The next section is `Flags`, which lists only the failed, warned, or skipped
checks. The full logs stay linked later in the report.

## Corpus Compare Run

Use this after Transcripted has produced Markdown for one or more corpus
meetings:

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode corpus-compare --corpus-ids meeting-0024,meeting-0025
```

By default, the bench looks for Transcripted Markdown here:

```text
~/Downloads/meeting-corpus/transcripted-output
```

Expected file shapes are:

```text
transcripted-output/meeting-0024.md
transcripted-output/meeting-0024/transcript.md
transcripted-output/meeting-0024/*.md
```

You can point it somewhere else:

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode corpus-compare \
  --corpus-ids meeting-0024,meeting-0025 \
  --corpus-output-dir /path/to/transcripted-output
```

Or provide a private JSON map:

```json
{
  "meeting-0024": "/path/to/Transcripted meeting 24.md",
  "meeting-0025": "/path/to/Transcripted meeting 25.md"
}
```

Then run:

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode corpus-compare \
  --corpus-candidate-map /path/to/candidate-map.json
```

This mode compares Transcripted Markdown against Zoom ground truth with
redacted scores: word recall, content-word recall, speaker-label count, and
private speaker-name match counts. Reports do not print transcript text or
speaker names.

This does not yet drive the app UI or import audio automatically. It scores the
Transcripted Markdown once that Markdown exists.

## Exit Codes

- `0`: all blocking checks passed with no warnings or skipped steps
- `1`: at least one blocking check failed
- `3`: the report is incomplete because at least one step warned or was skipped

## Manual QA

Every run writes:

```text
/tmp/transcripted-qa-bench/<run-id>/manual-scenarios.md
```

Use it for the lanes that need a human:

- actual meeting-app volume behavior
- sleep/wake
- Bluetooth and device switching
- TextEdit, Notes, browser text area dictation
- speaker review and manual rename feel
- "does this UI feel stuck?" recovery checks

For the meeting-volume matrix, use:

```text
docs/qa-issue-500-meeting-audio.md
```

For the daily audio state-machine loop, use:

```text
docs/audio-reliability-daily-check.md
```

## Pass Bar

A strong QA pass should answer:

- Do meetings start, stop, transcribe, and save?
- Do dictations paste or copy and then save readable Markdown?
- Can the local meeting corpus be read as private ground truth?
- Does Transcripted output match the private Zoom truth closely enough?
- Do speaker labels stay understandable, with `You` for the local mic by default?
- Do manual speaker names survive into Markdown?
- Do failed meetings explain stage, retryability, retained artifacts, and user-visible state?
- Do support diagnostics and analytics stay privacy-safe?
- Did every failing check leave a local evidence path?

## Privacy

Keep raw logs local. Do not upload:

- transcript text
- audio files
- meeting titles
- speaker names
- emails
- tokens
- absolute paths
- raw private URLs
- device names
