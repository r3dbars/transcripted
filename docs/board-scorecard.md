# Board Scorecard

Give an AI agent (Claude Code, Codex, or any capable assistant) one task list and
one scoring contract so it can test every surface of Transcripted and report a
per-board accuracy score instead of a flat pass/fail pile.

A **board** is one testable surface: a screen (Home, Speakers, Settings · General),
a quality lane (Transcription, Diarization, Summary), or a recording surface
(Meeting capture). They are enumerated in `.agents/board-scorecard.yml`.

## Why this exists

The QA bench (`docs/qa-test-bench.md`) already proves "504/504 checks pass." That
is great for regressions but it can't answer "how good is the Speakers board?" or
"did summary quality regress?" The scorecard adds that: each board gets a 0-100
score so you can watch quality move over time, board by board.

## How a board is scored

Each board scores on up to three dimensions, blended by weight:

| Dimension | What it answers | Evidence source |
| --- | --- | --- |
| `ui` | Does the surface render and respond? | `transcripted-qa ui-smoke --format json` (Accessibility-driven) |
| `functional` | Does the flow produce valid artifacts? | `transcripted-qa validate-all --format json` |
| `accuracy` | How close to ground truth? | a `score-<board>.json` from a scorer |

Rules that keep it honest:

- A dimension with **no evidence is INCOMPLETE, never green or red.** "We didn't
  test it" never becomes a pass.
- Board score is the weighted mean over the dimensions that actually have
  evidence; weights renormalize over those present.
- The overall verdict is the **worst auto board** — one RED board cannot hide
  behind green ones.
- `hardware` and `human` boards are not auto-scored; they are listed and routed
  to the manual packet (`manual-scenarios.md`), not counted as green.

Status tiers (tunable in the registry `defaults.thresholds`): score ≥ 85 → GREEN,
≥ 65 → YELLOW, else RED, no evidence → INCOMPLETE.

## Running it

The whole thing has to run on a **Mac with permissions granted** — the macOS app
can't build or run in a Linux/cloud session. Preflight permissions first:

```bash
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 \
  swift run --package-path Tools/TranscriptedQA transcripted-qa permission-state --mode computer-use
```

Then the bench mode wires evidence + scoring together:

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode scorecard
```

That runs `validate-all` (functional), `ui-smoke` when `build/Transcripted.app`
exists (UI), any accuracy scorers you opted into (below), and writes:

```text
/tmp/transcripted-qa-bench/<run-id>/board-scorecard.md
/tmp/transcripted-qa-bench/<run-id>/raw/board-scorecard.json
```

Or drive the aggregator directly once you have the JSON:

```bash
python3 scripts/ops/score-boards.py \
  --registry .agents/board-scorecard.yml \
  --ui-json raw/scorecard-ui-smoke.json \
  --functional-json raw/validate-all.json \
  --accuracy-dir raw \
  --json-out raw/board-scorecard.json \
  --markdown-out board-scorecard.md
```

## Accuracy scorers

Each writes a uniform `score-<board>.json` (`{board, score, present, detail, ...}`)
that the aggregator picks up from `--accuracy-dir`. They are opt-in in the bench
via env vars because they need real candidate output produced by driving the app —
the synthetic fixtures under `scripts/ops/fixtures/board-scorecard/` are for tests
and demos only, never fed as if they were product output.

### Transcription

Word recall/precision against Zoom ground truth already lives in
`scripts/ops/compare-meeting-corpus.py`. Convert its mean recall into
`score-transcription.json` and point the bench at it with
`TRANSCRIPTED_QA_TRANSCRIPTION_SCORE`.

### Diarization — `score-diarization.py`

Frame-based DER (missed + false-alarm + confusion over reference speech) after a
greedy hyp-label → ref-speaker mapping. Input is a segments JSON with `reference`
and `hypothesis` turns on a shared timeline. `score = 100 * (1 - DER)`.

```bash
python3 scripts/ops/score-diarization.py --segments segments.json --out raw/score-diarization.json
```

### Dictation correction — `score-dictation.py`

Token WER between the app's processed dictation and a hand-written expected
output, over the fixture cases. The candidate (app output keyed by case id) is
produced by driving dictation on the Mac. No candidate → INCOMPLETE.

```bash
python3 scripts/ops/score-dictation.py \
  --fixture scripts/ops/fixtures/board-scorecard/dictation-corrections.json \
  --candidate raw/dictation-candidate.json --out raw/score-dictation.json
```

### Meeting detection — `score-detection.py`

Precision/recall/F1 of the prompt detector against labelled app-state cases. The
candidate (detector's decision per case) comes from replaying the fixture cases
through the detector. `score = 100 * F1`.

### Summary — `score-summary-judge.py`

Summary quality is subjective, so the agent itself is the judge, scoring against a
frozen rubric (coverage, faithfulness, action items, conciseness). Build a local
judge prompt packet:

```bash
python3 scripts/ops/score-summary-judge.py --mode prompt \
  --transcript transcript.md --summary summary.md --meeting-id m1 --out raw/judge-prompt.txt
```

The agent reads the packet, returns rubric JSON, and you fold it into a score:

```bash
python3 scripts/ops/score-summary-judge.py --mode score \
  --judge-result raw/judge-result.json --out raw/score-summary.json
```

## The agent loop

1. Run the permission-state preflight; if blocked, report INCOMPLETE with the
   exact reason — a TCC blocker is never product proof.
2. Build the app, run `--mode scorecard`, generate any candidate outputs the
   accuracy boards need by driving the app.
3. Read `board-scorecard.md`. For RED/YELLOW auto boards, investigate and propose
   a fix. For INCOMPLETE auto boards, wire the missing evidence.
4. For `hardware`/`human` boards, follow the manual packet — do not fake a score.

## Tuning the registry

`check_globs` are best-effort matches against the `check`/`target` fields of the
validator JSON. After the first real Mac run, tighten them against the actual
`ui-smoke` / `validate-all` check names so each board pulls exactly the evidence
it owns. Weights and thresholds live in the registry too.

## Privacy

The scorecard reads only check names, statuses, and numeric scores. It never
copies transcript text, speaker names, emails, tokens, or absolute paths into the
report. Keep judge prompt packets local — they embed transcript content and must
not be uploaded.

## Tests

```bash
python3 scripts/ops/test-score-boards.py
```

Covers the scoring math, each scorer CLI, and the aggregator end-to-end. Pure
logic — no app, no Mac, no network.
