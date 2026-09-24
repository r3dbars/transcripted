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
               verdict: significant win above min_effect (sign-flip p < 0.05),
                        guardrails proven no worse, no new hard-gate failure
                   │
         accept ◄──┴──► reject          every trial + verdict → ledger
                   │
                   ▼
               best config vs shipped defaults, once, on the HOLDOUT split (p < 0.01)
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

1. Every repetition of both trials ran on the same build, host and OS.
   Numbers from different builds are never compared, and a rebuild halfway
   through a trial voids it.
2. No hard gate fires more often than it did for the incumbent. Hard gates
   are never averaged away.
3. The candidate measured every item the incumbent measured.
4. Primary metric: a one-sided paired sign-flip permutation test on the
   per-unit improvements gives p < 0.05 on dev (p < 0.01 on the holdout),
   and the mean clears the objective's `min_effect`. The test is exact up to
   16 units. With n units the smallest possible p is 1/2^n, so a tiny suite
   can't produce a win at all.
5. Guardrails are non-inferiority tests: the same test must reject "worse
   than `max_regression`" at the same p. A guardrail measured on fewer than
   half as many units as the primary, or one that lost items, rejects. A
   guardrail with no data is never skipped.

A result that looks like a win but is too noisy to call is marked
`inconclusive`. On timing benches the climber runs one more batch of
repetitions, pools it with the first, and judges the pooled data at half the
p threshold (it's a second look at a near miss). It is never accepted as is.

### Units, not items

Items that share people or a meeting aren't independent. A suite item can
carry `"cluster"`, and the lab averages each cluster into one unit before
testing, and keeps a cluster on one side of the holdout line. The lab refuses
to climb or confirm unless the suite has at least **10 dev units and 8
holdout units** (`MIN_UNITS` in `hc_engine.py`). `hillclimb.py split SUITE`
shows both counts. `validate` lists objectives that are blocked this way
without failing.

### How often noise gets through

`hillclimb.py simulate-null OBJECTIVE --sd S` answers this for an objective's
real suite sizes. `S` is the per-unit noise of the primary improvement, which
`calibrate` measures on the Mac. With 10% noise and a 5% `min_effect`:

| Suite | False move per candidate (dev) | False confirm per holdout check |
|---|---|---|
| 10 dev / 8 holdout units (the minimum) | about 4% | under 1% |
| dictation phrases (41 dev / 23 holdout) | about 0.1% | under 1% |

A false dev move only wastes trials. What ships is a holdout confirm, and
with the default 3 checks per holdout that stays around 2-3% at worst.

### Things that keep us honest

- **Locked holdout.** Every suite splits its items into dev and holdout by a
  hash of `(salt, cluster or item id)`. Adding items never moves existing
  ones. The climber only ever looks at dev. The final winner is checked once
  on the holdout against the shipped defaults.
- **Holdout budget.** Holdout checks are counted per objective by which
  holdout items they saw, in `holdout-peeks.jsonl`. A holdout that shares
  more than half its items with an earlier one counts as the same holdout, so
  adding a few items doesn't reset the budget. After `holdout_peek_budget`
  checks the lab refuses more. `--force-holdout` overrides it and the check
  is recorded as forced.
- **Sealed holdout rows.** `trials.jsonl` keeps only aggregates for holdout
  trials (`"per_item": "sealed"`), and bench work folders for holdout runs go
  under `work/holdout-sealed/`. An agent running a climb must not read that
  folder.
- **A/A calibration.** `hillclimb.py calibrate OBJECTIVE` runs the defaults
  against themselves. A healthy bench must not call that a win, and its noise
  band must sit below `min_effect`. Run it on the Mac before the first climb
  of each objective.
- **Interleaving.** Timing benches re-measure the incumbent next to every
  candidate, alternating order each repetition, so thermal drift and
  background load hit both sides.
- **One knob per move.** Coordinate ascent: every accepted move has a
  one-line explanation in the ledger.
- **Checks the bench can't do.** An objective can list
  `post_confirm_checks`. They're copied into `recommendation.json` under
  `required_before_shipping`. The speaker objective requires
  `scripts/run_speaker_autoresearch.py` (the per-bucket no-regression
  contract).
- **Clean timeouts.** Every bench runs in its own process group, and a
  timeout kills the whole group, so an app or CLI run can't keep going into
  the next trial.

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
python3 scripts/hillclimb/hillclimb.py climb dictation-stop-latency --resume <dir>   # after a crash or Ctrl-C
python3 scripts/hillclimb/hillclimb.py confirm --campaign <dir>
python3 scripts/hillclimb/hillclimb.py simulate-null dictation-stop-latency --sd 0.1
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
`decisions.jsonl`, `climb-result.json` (rewritten after every decision, with
`status` running or finished), and after a holdout check `confirmation.json`
plus `recommendation.json` when it passed.

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

- **Speaker naming is blocked on suite size.** Its 48 items are 16 audio
  qualities of the same people, so they collapse to 4 dev units and 2
  holdout units (family × identity split). The harness has to emit
  per-person or per-meeting rows before this objective can climb.

- Press-to-recording latency on the live app is not an objective yet. The
  pieces exist: `scripts/hillclimb/lab_control.py` drives the real app
  (start/stop dictation and meetings, import audio) through a file-drop
  channel. The channel only exists in a local lab build (`bash build.sh
  --no-open --lab`), never in beta or release builds, and even there it's off
  unless the app was launched with `TRANSCRIPTED_LAB_CONTROL_DIR`. See
  `docs/lab-control-channel.md`.
- Most meeting pipeline constants are `needs-seam` until the app reads
  overrides (`LabKnobOverrides`).
- Hardware conditions (AirPods, USB mics, sleep/wake) need a hardware lane;
  CI and benches prove correctness, not device latency.
