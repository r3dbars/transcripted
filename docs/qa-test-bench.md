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

For real local Gemma/MLX proof on the synthetic fixture, run:

```bash
bash scripts/ops/run-local-summary-fixture.sh --real-gemma
```

That path uses `uv run --with mlx-vlm==0.6.1` and the bundled
`Resources/LocalSummarizer/gemma4_mlx_prompt_runner.py`. It may download the
MLX runtime/model on first run. Missing `uv`, missing Python 3.10+ for `uv`,
insufficient RAM, runtime install failure, or model execution failure is a real
host blocker, not a green fixture.

## Pasteback Synthetic Run

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode pasteback-synthetic
```

This runs only the fake slow Cmd+V target smoke. It writes a markdown subreport
beside the QA report and JSON under `raw/`. It proves the target-buffer result
for synthetic slow readers, retry pasteback, cancellation cleanup, and Auto
Enter readiness without using real dictation audio or the real clipboard.

## UI Run

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode ui
```

This builds the app, then runs:

```bash
swift run --package-path Tools/TranscriptedQA transcripted-qa ui-smoke --app build/Transcripted.app
```

The smoke launches the built app with an isolated home directory, opens the real
menu bar popover through Accessibility, opens Home/Settings, navigates to
General, and validates stable `transcripted.*` controls are visible and enabled.
It writes local JSON evidence under the QA run's `raw/` folder.

This requires Accessibility permission for the terminal or Codex runner. If
macOS blocks AX observation/control, the result is `INCOMPLETE` with exit code
`3`. Do not treat that as product proof.

## Imported Audio Native Run

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode imported-audio-native
```

This builds the app, then runs:

```bash
swift run --package-path Tools/TranscriptedQA transcripted-qa imported-audio-native-smoke --app build/Transcripted.app
```

The smoke launches the built app with an isolated home and capture library,
opens the real Settings General import action, waits for the native `NSOpenPanel`,
selects a spoken AIFF fixture through the picker, and waits for a saved imported
meeting Markdown plus retained audio. It writes local JSON evidence and keeps
the isolated capture library for inspection.

This requires Accessibility plus keyboard event permission for the runner. If
macOS blocks the picker automation, or if local speech/diarization models cannot
finish the import on this Mac, the result is `INCOMPLETE` with exit code `3`.
That is a real proof blocker, not a product pass.

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
- `swift run --package-path Tools/TranscriptedQA transcripted-qa imported-audio-smoke`
- native imported-audio picker proof remains opt-in via
  `--mode imported-audio-native`
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

The imported-audio smoke generates a synthetic WAV, a canonical imported
meeting Markdown file, retained single-file audio, and then validates the
`system_audio`-only parser/validator contract. It is repo-owned deterministic
artifact proof. It does not click the native file picker and does not prove real
ML transcription quality for user media.

Live artifact validation is non-blocking by default because a development Mac
may not have saved meetings yet. To make it strict:

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode deep --strict-artifacts
```

In non-strict `deep`, `full`, and `live` modes, local artifact warnings are
shown in the report as warnings-only local state, but they do not hold the
bench exit code. Command/tool failures that do not produce a structured
validation report still fail. Use `--strict-artifacts` when local saved-artifact
drift should block the gate.

## Full Run

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode full
```

Use this as the broad pre-merge gate for risky or release-impacting work. It
runs `deep`, then adds:

- deterministic release-health fixture checks
- a local Gemma meeting-summary dry-run plan when eligible local transcripts are present

To make the Gemma rows execute instead of planning only:

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode full --gemma-execute
```

`--gemma-execute` also makes quick/deep/full run the real synthetic Gemma
fixture. In full mode, the local transcript autoeval only runs when eligible
local transcripts are present; otherwise the synthetic fixture remains the real
runtime proof.

The report includes a compact operator verdict:

- Working
- Regressed
- Needs human
- Release GO/HOLD

`HOLD` is still expected when the automated full gate passes but manual proof is
outstanding. Real meeting apps, TCC prompts, Bluetooth hardware, sleep/wake,
local Gemma beta workflow, and pasteback feel still need the generated manual
packet when those risks matter.

## Live Run

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode live
```

This runs `full`, then adds the real mic + system-audio capture smoke:

```bash
bash run-live-capture-smoke.sh --skip-build
```

Before that smoke, live mode runs:

```bash
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift run --package-path Tools/TranscriptedQA transcripted-qa permission-state --mode live-capture --format json
```

It requires local microphone permission, System Audio Recording proof, and the
Codex/computer-use host permissions needed for screenshots and clicks. If macOS
blocks the harness, report `INCOMPLETE: harness permission blocked` with the
exact permission reason. Do not treat a TCC blocker as product proof.

## Audio Synthetic Run

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode audio-synthetic
```

This runs `bash run-daily-audio-reliability.sh --synthetic`. It can prove the
deterministic route fixture matrix and the simulated artifact/failure contract.
It cannot prove real Zoom, Meet, browser WebRTC, Bluetooth/AirPods, TCC, or
user-perceived volume behavior. Issue #500 stays manual-required until the
dated matrix in `docs/qa-issue-500-meeting-audio.md` is run.

## Speaker-Naming Simulator

Use this to reason about how many speakers the post-meeting "Review meeting
speakers" sheet asks you to name, without needing audio or ML models:

```bash
scripts/ops/speaker-naming-simulator.py            # scenario suite (table)
scripts/ops/speaker-naming-simulator.py --sweep    # consolidation-threshold tradeoff
scripts/ops/speaker-naming-simulator.py --json     # machine-readable suite output
```

It generates synthetic offline-diarization output — true speakers over-segmented
into several clusters, the way VBx splits one remote voice — and runs a faithful
pure-Python model of `EmbeddingClusterer` post-processing (small-cluster
absorption + same-voice consolidation). The suite reports review-row counts
before/after consolidation, expected labels, channel role, and false-merge
flags, so it catches the user-facing failure: duplicate speaker rows in the
post-meeting review sheet. The fixtures cover cold unknown voices, repeated
named speakers, tentative known speakers, remote groups, local default-off
`You` behavior, opt-in local room split, and near-threshold similar voices. The
script exits non-zero if any scenario misses its expected review count, expected
labels, expected cluster count, or false-merge guard.

The `--sweep` view shows where an over-segmented one-on-one collapses correctly
versus where genuinely similar distinct voices start to wrongly merge, which is
how to pick the consolidation threshold.

The thresholds in the script mirror
`Sources/TranscriptedCore/Speaker/EmbeddingClusterer.swift`; keep them in sync
when that file changes. This is a model, not the real Swift path — use it to
tune and reason, then validate behavior changes with `swift test` and the
`EmbeddingClustererTests` coverage.

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

## Release Gate Report

Use this when you want one pre-merge or release-candidate report instead of
separate build, telemetry, release-surface, and log checks:

```bash
python3 scripts/ops/release-gate-report.py
```

The default command runs the quick QA bench, Sentry and PostHog health probes,
live appcast/download/release-health checks, and a local aggregate log sweep.
It writes:

```text
/tmp/transcripted-release-gate/<run-id>/release-gate-report.md
/tmp/transcripted-release-gate/<run-id>/release-gate-report.json
```

For a deeper release-candidate pass:

```bash
python3 scripts/ops/release-gate-report.py --qa-mode deep --strict-artifacts
```

Missing Sentry or PostHog credentials are `YELLOW` / unknown. They are not
treated as green proof. Actual release-surface drift or required release-health
failures are `RED`.

The report starts with one skimmable proof-lane summary:

- deterministic proof: build, fast tests, smoke checks, artifact fixtures, and packaged smoke when requested
- mocked/proxy proof: synthetic pasteback, route, Bluetooth/AirPods, and Gemma dry-run checks, never hardware proof
- telemetry proof: Sentry and PostHog aggregate probes
- release-surface proof: appcast, download, GitHub, cask, and Sentry release metadata
- local log proof: only timestamped warnings at or after the gate starts affect the color; stale or un-timestamped local residue is noted without holding the gate
- manual/hardware UNKNOWN: live audio/TCC, real meeting apps, Bluetooth/AirPods hardware, sleep/wake, pasteback feel, speaker review feel, and install/update proof

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

This does not drive the app UI or native file picker automatically. It scores
the Transcripted Markdown once that Markdown exists. For deterministic imported
artifact shape proof, use `imported-audio-smoke` from the deep bench.

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

- Codex UI automation permission-state and state-change proof
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

## Codex UI Automation Permissions

Run this before any Codex computer-use, screenshot, or click-flow proof:

```bash
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift run --package-path Tools/TranscriptedQA transcripted-qa permission-state --mode computer-use
```

Pass bar:

- Accessibility, Event Posting, Input Monitoring, Screen Recording, and Automation are ready for the app that runs Codex or the terminal host
- Transcripted app bundle identity matches the expected bundle id
- every automated click proves a visible state change after the event

If the command warns, stop the UI lane and report `INCOMPLETE: harness
permission blocked`. Actual TCC grant, deny, revoke, fresh-user prompt behavior,
real mic/system-audio capture, and "does this feel stuck?" judgment stay manual.

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
