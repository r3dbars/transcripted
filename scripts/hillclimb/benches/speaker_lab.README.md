# speaker-lab bench

Hill-climb bench adapter for the speaker lab (`scripts/run_speaker_lab.sh --single`). It lets
the climber tune the whole meeting speaker pipeline (diarizer backend, voice fingerprint model,
Nemotron preset, cross-call match floor, same-voice merge, duplicate-profile merge, and the
fingerprint update policy) for one outcome: a person you've already had a call with lands on
their own profile next time, so you don't have to name them again.

- Adapter: `scripts/hillclimb/benches/speaker_lab.py` (`--request REQUEST.json`, `--self-test`)
- Tests: `scripts/hillclimb/benches/test_speaker_lab.py` (fake driver + the real driver with a
  fake harness; runs on Linux)
- Suite: `config/hillclimb/suites/speaker-lab-ami.json` (24 AMI series, 16 dev / 8 holdout)

The adapter's docstring covers the per-item unit, the metrics, determinism, and what has to
exist on the Mac. This file holds the registry entries for the hill-climb lab (#1791), as
JSON ready to paste. They live here, not in `config/hillclimb/*.json`, because those files
belong to that branch.

## How one trial runs

1. Knobs become driver flags (the table below). Unset knobs aren't passed, so the driver's
   production defaults apply.
2. Every requested series that's fully downloaded goes into ONE driver call:
   `run_speaker_lab.sh --single --skip-build --corpus ami --series "<sorted series>" ...`.
   Every driver env twin (`MATCH`, `SERIES`, `VARIANTS`, ...) and harness env override
   (`TRANSCRIPTED_NEMOTRON_PRESET`, `TRANSCRIPTED_SPEAKER_EMBEDDER`,
   `TRANSCRIPTED_DIARIZATION_BACKEND`, `TRANSCRIPTED_LAB_KNOBS_FILE`) is scrubbed first, so a
   stray shell export can't change a trial. `--embedding-parity` is never passed: it's a
   one-off diagnostic (can Nemotron voiceprints share `speakers.sqlite`?), not something to
   climb, so run it by hand with the driver.
3. `scores.json` must echo every knob that was set (variant plus effective replay knobs), or
   every item errors.
4. Per-series metrics come from `recognition-events.json` (per-appearance outcomes) and the
   per-meeting DER rows in `scores.json`.

| knob id | driver flag | notes |
|---|---|---|
| `diarization.backend` | `--backend pyannote\|nemotron` | |
| `diarization.nemotron.preset` | `--preset <name>` | nemotron only. `fast128` (the default) is not passed, so it shares the unset-preset dump cache. Ignored under pyannote |
| `speaker.embedder` | `--embedder native\|eres2net` | `wespeaker` maps to `native` |
| `speaker.match.mode` | `--match adaptive` or `--match <floor>` | `fixed` needs `speaker.match.fixed_floor` |
| `speaker.match.fixed_floor` | (with mode `fixed`) | ignored under `adaptive` |
| `speaker.cluster.same_voice_consolidation.wespeaker` / `.eres2net` | `--same-voice <float>` | only the one that matches the embedder is used |
| `speaker.profile.duplicate_merge_similarity_replay` | `--dedup <float>` | |
| `speaker.writeback.path_fixes` | `--write-path-fixes on\|off` | sanity lever, not in the objective's search list |
| `speaker.writeback.confident_blend_alpha` | `--blend-confident` | |
| `speaker.writeback.cautious_blend_alpha` | `--blend-cautious` | |
| `speaker.writeback.confident_similarity` | `--writeback-confident-sim` | |
| `speaker.writeback.cautious_similarity` | `--writeback-cautious-sim` | |
| `speaker.writeback.margin` | `--writeback-margin` | |

Knobs that had no effect in a config (a preset under pyannote, a fixed floor under adaptive,
the other embedder's same-voice value) are listed in `environment.ignored_knobs`, so a flat
response on them is explained.

## Paste into #1791

### `config/hillclimb/benches.json`: add to `benches`

```json
{"id": "speaker-lab", "kind": "command", "timeout_seconds": 21600,
 "command": ["python3", "{repo}/scripts/hillclimb/benches/speaker_lab.py", "--request", "{request}"]}
```

`timeout_seconds` covers a cold trial: the first trial of a variant dumps all 48 dev meetings.
Warm trials (dumps cached) are replay + scoring and take seconds to a couple of minutes.

### `config/hillclimb/knobs.json`: new knobs, add to `knobs`

```json
[
  {
    "id": "diarization.backend",
    "area": "diarization",
    "title": "Speaker diarization model",
    "type": "enum",
    "default": "pyannote",
    "choices": ["pyannote", "nemotron"],
    "status": "live",
    "apply": [
      {"via": "env", "name": "TRANSCRIPTED_DIARIZATION_BACKEND"},
      {"via": "bench-flag", "name": "--backend"}
    ],
    "affects": ["speaker-lab-recognition"],
    "source": "Sources/Support/DiarizationBackendPreferences.swift:26",
    "risk": "Nemotron is experimental and off by default; first use downloads its CoreML model. A different diarizer changes every turn boundary, so DER and speaker counts can move in either direction.",
    "notes": "The app reads TRANSCRIPTED_DIARIZATION_BACKEND (env wins over the hidden diarization-backend-preference default). The speaker-lab bench scrubs that env var and passes --backend to run_speaker_lab.sh instead. The first trial of each backend x embedder x preset variant dumps every meeting (slow); later trials reuse the per-variant dump cache. Shipping nemotron means flipping DiarizationBackendPreferences.defaultChoice."
  },
  {
    "id": "diarization.nemotron.preset",
    "area": "diarization",
    "title": "Nemotron diarization preset",
    "type": "enum",
    "default": "fast128",
    "choices": ["fast128", "fast32", "fast32-int8", "offline"],
    "status": "live",
    "apply": [
      {"via": "env", "name": "TRANSCRIPTED_NEMOTRON_PRESET"},
      {"via": "bench-flag", "name": "--preset"}
    ],
    "affects": ["speaker-lab-recognition"],
    "source": "Sources/TranscriptedCore/Services/NemotronDiarizationRunner.swift:33",
    "risk": "offline runs on CPU+GPU (fails the ANE compiler), so it is much slower and hotter; smaller chunks (fast32) trade DER for latency.",
    "notes": "Only applies when diarization.backend = nemotron (the adapter reports it in environment.ignored_knobs otherwise). Core silently falls back to fast128 on an unknown name (NemotronDiarizationRunner.resolvePresetName); the harness dump refuses one, so choices are limited to presets the tests pin (DiarizationBackendTests.swift) plus offline. The adapter does not pass fast128: the driver names variants after the preset string, so passing it would fork the dump cache and re-diarize everything."
  },
  {
    "id": "speaker.match.mode",
    "area": "speaker",
    "title": "Cross-call match floor: the app's adaptive floor or one fixed value",
    "type": "enum",
    "default": "adaptive",
    "choices": ["adaptive", "fixed"],
    "status": "bench-only",
    "apply": [{"via": "bench-flag", "name": "--match"}],
    "affects": ["speaker-lab-recognition"],
    "source": "Sources/TranscriptedCore/Speaker/SpeakerEmbeddingThresholds.swift:61",
    "risk": "A fixed floor ignores how many turns a voiceprint came from, so short speakers get matched on thin evidence.",
    "notes": "adaptive = SpeakerEmbeddingThresholds.adaptiveMatch(forSegmentCount:), what ships. fixed uses speaker.match.fixed_floor. A fixed winner means replacing the adaptive tiers (speaker.match.adaptive_*, needs-seam) in source."
  },
  {
    "id": "speaker.match.fixed_floor",
    "area": "speaker",
    "title": "Cross-call match floor when speaker.match.mode = fixed",
    "type": "float",
    "default": 0.6,
    "min": 0.4,
    "max": 0.8,
    "step": 0.05,
    "status": "bench-only",
    "apply": [{"via": "bench-flag", "name": "--match"}],
    "affects": ["speaker-lab-recognition"],
    "source": "Tools/SpeakerEvalHarness/Sources/speaker-eval-harness/Replay.swift:143",
    "risk": "Too low glues strangers to saved people (wrong names); too high asks about everyone again.",
    "notes": "Ignored under speaker.match.mode = adaptive (listed in environment.ignored_knobs). Cosine scales differ by embedder: the lab's own sweep uses 0.55-0.70 for WeSpeaker and 0.45-0.60 for ERes2Net. 0.6 is the harness's pre-lab default."
  },
  {
    "id": "speaker.profile.duplicate_merge_similarity_replay",
    "area": "speaker",
    "title": "Duplicate-profile merge similarity (speaker lab replay)",
    "type": "float",
    "default": 0.6,
    "min": 0.5,
    "max": 0.9,
    "step": 0.05,
    "status": "bench-only",
    "apply": [{"via": "bench-flag", "name": "--dedup"}],
    "affects": ["speaker-lab-recognition"],
    "source": "Sources/TranscriptedCore/Speaker/SpeakerProfileMerger.swift:376",
    "risk": "Too low permanently fuses two different people's saved profiles; too high leaves duplicates for the user to clean up.",
    "notes": "Bench-only twin of speaker.profile.duplicate_merge_similarity (needs-seam, so the climber skips it; flipping that knob's status would make the speaker-autoeval and meeting-import objectives search a knob their benches reject). Same source constant: a winner edits mergeDuplicates' 0.6 default."
  },
  {
    "id": "speaker.writeback.path_fixes",
    "area": "speaker",
    "title": "Gated voiceprint write-back + cross-cluster spin-off",
    "type": "bool",
    "default": true,
    "status": "bench-only",
    "apply": [{"via": "bench-flag", "name": "--write-path-fixes"}],
    "affects": ["speaker-lab-recognition"],
    "source": "Sources/TranscriptedCore/Speaker/SpeakerWritePathPolicy.swift:37",
    "risk": "false replays the legacy write path (every match blends at full rate), which is known to drift voiceprints.",
    "notes": "true is what ships. Kept as a sanity lever for before/after checks, not in speaker-lab-recognition's search list."
  }
]
```

### `config/hillclimb/knobs.json`: edits to existing knobs

Add `"speaker-lab-recognition"` to `affects` and append the `apply` entry shown. Nothing
else changes, and none of these touch another bench (a `bench-flag` entry sets no env var).

```json
{
  "speaker.embedder": {"affects_add": "speaker-lab-recognition", "apply_add": {"via": "bench-flag", "name": "--embedder"}},
  "speaker.cluster.same_voice_consolidation.wespeaker": {"affects_add": "speaker-lab-recognition", "apply_add": {"via": "bench-flag", "name": "--same-voice"}},
  "speaker.cluster.same_voice_consolidation.eres2net": {"affects_add": "speaker-lab-recognition", "apply_add": {"via": "bench-flag", "name": "--same-voice"}},
  "speaker.writeback.confident_blend_alpha": {"affects_add": "speaker-lab-recognition", "apply_add": {"via": "bench-flag", "name": "--blend-confident"}},
  "speaker.writeback.cautious_blend_alpha": {"affects_add": "speaker-lab-recognition", "apply_add": {"via": "bench-flag", "name": "--blend-cautious"}},
  "speaker.writeback.confident_similarity": {"affects_add": "speaker-lab-recognition", "apply_add": {"via": "bench-flag", "name": "--writeback-confident-sim"}},
  "speaker.writeback.cautious_similarity": {"affects_add": "speaker-lab-recognition", "apply_add": {"via": "bench-flag", "name": "--writeback-cautious-sim"}},
  "speaker.writeback.margin": {"affects_add": "speaker-lab-recognition", "apply_add": {"via": "bench-flag", "name": "--writeback-margin"}}
}
```

Their defaults already match the lab's production defaults (0.88 / 0.65 same-voice, blend
0.15 / 0.05, write-back similarity 0.80 / 0.72, margin 0.12), so the baseline is what ships.
The `speaker.embedder` env apply (`TRANSCRIPTED_SPEAKER_EMBEDDER`) is harmless here: the
adapter scrubs it and passes `--embedder`.

### `config/hillclimb/objectives.json`: add to `objectives`

```json
{
  "id": "speaker-lab-recognition",
  "title": "Speakers (lab): returning people land on their own profile, any diarizer + fingerprint",
  "bench": "speaker-lab",
  "suite": "speaker-lab-ami",
  "primary": {
    "id": "recognition_rate",
    "direction": "higher",
    "compare": "difference",
    "aggregate": "mean",
    "min_effect": 0.03
  },
  "guardrails": [
    {
      "id": "pipeline_der",
      "direction": "lower",
      "compare": "difference",
      "aggregate": "mean",
      "max_regression": 0.01
    },
    {
      "id": "speaker_count_abs_error",
      "direction": "lower",
      "compare": "difference",
      "aggregate": "mean",
      "max_regression": 0.25
    }
  ],
  "hard_gates": [
    "wrong_person",
    "new_person_false_match"
  ],
  "knobs": [
    "diarization.backend",
    "diarization.nemotron.preset",
    "speaker.embedder",
    "speaker.match.mode",
    "speaker.match.fixed_floor",
    "speaker.cluster.same_voice_consolidation.wespeaker",
    "speaker.cluster.same_voice_consolidation.eres2net",
    "speaker.profile.duplicate_merge_similarity_replay",
    "speaker.writeback.confident_blend_alpha",
    "speaker.writeback.cautious_blend_alpha",
    "speaker.writeback.confident_similarity",
    "speaker.writeback.cautious_similarity",
    "speaker.writeback.margin"
  ],
  "repetitions": 1,
  "interleave": false,
  "holdout_peek_budget": 3,
  "bench_options": {
    "harness_binary": "Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness",
    "data_dir": "data",
    "collar": 0.25,
    "min_appearance_sec": 5,
    "wrong_penalty": 2,
    "lab_timeout_seconds": 20000
  },
  "notes": "Runs the full meeting speaker pipeline (diarizer -> embeddings -> clusterer -> speaker DB) on AMI series through scripts/run_speaker_lab.sh --single, one call per trial over the whole split. Replay is deterministic given cached dumps, so one repetition. The first trial of each backend x embedder x preset variant dumps every meeting (slow, and CoreML inference is not guaranteed bit-identical, so never clear dumps mid-climb); pre-warm with bash scripts/run_speaker_lab.sh --variants ... first. Hard gates: any extra returning person put on someone else's profile, or any extra first-time speaker glued to a known profile, vetoes a candidate. ERes2Net needs its Model.mlmodelc staged (bench_options.eres2net_model); without it eres2net trials come back as item errors, which the item_error gate rejects."
}
```

Why these numbers: the dev split has about 12 series x 4 people x up to 3 returning
appearances, so one appearance moves a series' `recognition_rate` by about 0.08 and the mean
by about 0.007. `min_effect` 0.03 is roughly four more people recognized. The DER guardrail
(one point) keeps a recognition win from coming out of worse turn boundaries, and the
speaker-count guardrail keeps it from coming out of merging people.

## Gaps

- Items in one request share a speaker DB, so a series' numbers depend on the other series in
  the request. The climber always sends a whole split, so pairs are fair, but dev and holdout
  numbers aren't comparable in absolute terms.
- `falseMergeProfiles` (a profile that ended up holding two people) is only computed for the
  whole run in `scores.json`, not per series, so it isn't a gate yet. `wrong_person` catches
  most of what it would.
- Stale dumps: `dump-ok` checks backend/embedder/preset, not the harness build. After a
  diarizer or embedding change, clear `data/eval/ami/dumps/` yourself.
- Only AMI. ICSI recurs speakers too (`CORPUS=icsi`), but its meetings aren't grouped into
  series, so it'd need an item shape based on meeting lists.
- Not run on the Mac yet: the tests use a fake driver and a fake harness. The first real
  trial should be checked against a plain `run_speaker_lab.sh --single` of the same settings.
