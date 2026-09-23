# Hill-climb lab

The hill-climb lab tunes Transcripted's settings against scored tests and
recommends a change only when it is a real, safe win for users. It sits on
top of the existing benches (`Tools/TranscriptedLab`, `scripts/ops/dictation-stop-autoeval.sh`,
`Tools/SpeakerEvalHarness`, `transcripted-cli import-audio`) and adds the
parts they were missing: a registry of every knob, fixed test sets with a
locked holdout, paired statistics, a search loop, and an append-only ledger.

Code: `scripts/hillclimb/` (Python stdlib only). Config: `config/hillclimb/`.

```text
knobs.json ──► climber proposes one knob change
                   │
                   ▼
objectives.json ─► bench runs incumbent and candidate on the DEV split
                   │   (timing benches interleave A/B runs)
                   ▼
               verdict: CI-backed win above min_effect,
                        no guardrail regression, no new hard-gate failure
                   │
         accept ◄──┴──► reject          every trial + verdict → ledger
                   │
                   ▼
               best config vs shipped defaults, once, on the HOLDOUT split
                   │
                   ▼
               recommendation.json (knob, from → to, source file:line, evidence)
```

## Objectives

| Objective | What it means for a user | Primary metric | Hard gates |
|---|---|---|---|
| `dictation-stop-latency` | Text shows up faster after you let go of the key | median `stop_to_text_s` per phrase | missing text, text from silence, unstable output |
| `meeting-turnaround` | Notes are ready sooner after Stop | median `turnaround_rtf` (seconds per second of audio) | no transcript, empty transcript |
| `speaker-naming-across-calls` | The app recognizes the same person on the next call without asking again | `auto_coverage` | any new false automatic name, cross-person merge, contaminated profile |

Each objective also has guardrails, metrics that may not get worse beyond a
stated tolerance (word error rate, word recall, prompts per recurring
speaker). See `config/hillclimb/objectives.json`.

## How a verdict works

A candidate is accepted over the incumbent only if all of these hold
(`decide` in `scripts/hillclimb/hc_engine.py`):

1. Both trials ran on the same build, host and OS. Numbers from different
   builds are never compared.
2. No hard gate fires more often than it did for the incumbent. Hard gates
   are never averaged away.
3. The candidate measured every item the incumbent measured.
4. Primary metric: paired per-item improvement, 95% bootstrap CI lower bound
   above zero, and the mean clears the objective's `min_effect`.
5. Guardrails: the CI lower bound never shows a regression bigger than the
   guardrail's `max_regression` (a non-inferiority test).

A result that looks like a win but is too noisy to call is marked
`inconclusive`. On timing benches the climber re-measures it once with double
the repetitions. It is never accepted as is.

### Things that keep us honest

- **Locked holdout.** Every suite splits its items into dev and holdout by a
  hash of `(salt, item id)`. Adding items never moves existing ones. The
  climber only ever looks at dev. The final winner is checked once on the
  holdout against the shipped defaults.
- **Holdout budget.** Holdout checks are counted per objective and suite
  version in `holdout-peeks.jsonl`. After `holdout_peek_budget` checks the
  lab refuses more until the suite grows (which changes its fingerprint).
  This stops "try until the holdout agrees".
- **A/A calibration.** `hillclimb.py calibrate OBJECTIVE` runs the defaults
  against themselves. A healthy bench must not call that a win, and its noise
  band must sit below `min_effect`. Run it on the Mac before the first climb
  of each objective.
- **Interleaving.** Timing benches re-measure the incumbent next to every
  candidate, alternating order each repetition, so thermal drift and
  background load hit both sides.
- **One knob per move.** Coordinate ascent: every accepted move has a
  one-line explanation in the ledger.

## Knobs

`config/hillclimb/knobs.json` lists every tunable setting with its shipped
default, legal range, source line, what it could break, and how a bench
applies it:

- `live`: a bench can set it today (env var, CLI flag, or knob file).
- `bench-only`: tunable in a bench's replica of the app logic (for example
  the speaker naming policy inside `SpeakerEvalHarness autoeval`). A winner
  means changing the app constant at `source`.
- `needs-seam`: hardcoded with no override yet. Listed so the map is
  complete; the climber skips it.

List them: `python3 scripts/hillclimb/hillclimb.py knobs [--area speaker]`.

## Commands

```bash
python3 scripts/hillclimb/hillclimb.py validate                  # registry + suites sanity
python3 scripts/hillclimb/hillclimb.py split dictation-phrases-v1   # see the dev/holdout split
python3 scripts/hillclimb/hillclimb.py calibrate dictation-stop-latency
python3 scripts/hillclimb/hillclimb.py climb dictation-stop-latency --budget 30 --confirm
python3 scripts/hillclimb/hillclimb.py confirm --campaign <dir>
python3 scripts/hillclimb/hillclimb.py leaderboard
python3 scripts/hillclimb/hillclimb.py --self-test
```

Try the whole loop on any machine with the synthetic demo registry:

```bash
python3 scripts/hillclimb/hillclimb.py --config-dir scripts/hillclimb/fixtures/demo \
    --state-dir /tmp/hc-demo climb demo-latency --budget 40 --confirm
```

State lives in `~/Library/Application Support/Transcripted Lab/HillClimb/`
on a Mac (`build/hillclimb/` elsewhere, or `TRANSCRIPTED_HILLCLIMB_STATE_DIR`).
Each campaign folder holds `campaign.json`, `trials.jsonl`,
`decisions.jsonl`, `climb-result.json`, and after a holdout check
`confirmation.json` plus `recommendation.json` when it passed.

## Plugging in another bench

Any tool can become a bench by speaking the request/result protocol in
`scripts/hillclimb/hc_benches.py`: read the request JSON (knobs, items,
split), write a result JSON with per-item metrics and gate counts, and
report the exact binary under test as `environment.app_revision`. Then add a
`command` entry to `config/hillclimb/benches.json` and an objective.

This is how the speaker detection bake-off (cross-call recognition score) and
the speech model speed shootout (WER, latency, real-time factor) plug in:
each emits per-item rows for the config it was asked to run, and the climber
does the rest. Per-item rows matter: the paired statistics need them, and an
aggregate-only number cannot be checked for noise.

Related tools (both draft PRs as of 2026-09-23, first Mac runs after 1.1.62):

- **Speech model shootout** (PR #1788): `bash scripts/stt-shootout/run.sh
  --engines a,b --minutes N --json-out PATH` writes WER, latency, speed and
  memory per model. A thin adapter that maps a `speech.model` knob to
  `--engines` and emits per-clip rows turns it into a bench.
- **Clean virtual Mac** (PR #1790, `docs/clean-vm-testing.md`): exec,
  screenshots, clicks and typing over VNC on a fresh macOS. Good for
  first-run and permission flows. No AirPods, no device switching, no
  sleep/wake, and no trustworthy speed numbers, so never climb timing
  objectives on it.

## Not covered yet

- Press-to-recording latency on the live app. The bench path measures the
  stop path only; see `docs/lab-control-channel.md` for driving the real app.
- Most meeting pipeline constants are `needs-seam` until the app reads
  overrides (`LabKnobOverrides`).
- Hardware conditions (AirPods, USB mics, sleep/wake) need a hardware lane;
  CI and benches prove correctness, not device latency.
