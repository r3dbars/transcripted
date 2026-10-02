# Voiceprint bake-off

> **Finished, scripts removed.** ReDimNet2 b4 won and ships. The bake-off's scoring, audit and dataset scripts were deleted from `scripts/voiceprint/` in the October 2026 cleanup; only the converter that `scripts/models/redimnet2/install.sh` needs is left. To rerun the bake-off, restore them with `git checkout 85bbcc09 -- scripts/voiceprint`.

Which voice fingerprint model should Transcripted use to recognize the same person across meetings?

Nemotron 3 now separates speakers (PR #1887), so the voiceprint model only decides "who is who". Today that model is WeSpeaker ResNet34-LM, the pyannote community-1 embedding that FluidAudio runs. This bake-off tests every voiceprint model we could legally ship, on human-labeled speech. It also measures what users feel: how many meetings until someone is named automatically, and wrong names, which must stay at zero.

This file is the contract every agent works from. Paths below are relative to the repo root; `VP` means `data/eval/voiceprint/`. `data/` is gitignored, and in this worktree it symlinks to the speaker-lab worktree's data.

## Stages

1. **Datasets:** human-labeled speech where the same person shows up in different sessions, plus call-audio degradations.
2. **Model screen:** embed every set with every eligible model. Score verification (EER, and hits at near-zero false accepts) and a naming simulation. Also score speed and size.
3. **Ship the winner:** convert it to Core ML, add it to the app as a `SpeakerSegmentEmbedder`, run the real pipeline end to end against today's model, review, and write up the results.

## Layout (all under VP, gitignored)

```
VP/venv/                      shared Python 3.12 venv (torch, sherpa-onnx, onnxruntime, coremltools, speechbrain, transformers)
VP/raw/<dataset>/             downloads, untouched
VP/sets/<set>/segments.jsonl  one row per clean clip (schema below)
VP/sets/<set>/README.md       source, license, how it was built, counts
VP/sets/<set>/READY           written last, when segments.jsonl and every clean clip exist
VP/clips/<set>/clean/<seg_id>.wav     16 kHz mono PCM16, one speaker only
VP/clips/<set>/<cond>/<seg_id>.wav    degraded copies (conditions below)
VP/clips/<set>/<cond>/READY
VP/models/<model_id>/model.json       one per model, written by the agent that set it up (schema below)
VP/models/<model_id>/...              weights
VP/models/licenses.json               written only by the license agent
VP/emb/<model_id>/<set>__<cond>.npz   keys: seg_id (str array), emb (float32 [N, D], raw, not normalized)
VP/emb/<model_id>/<set>__<cond>.json  {model_id, dim, clips, seconds_audio, seconds_compute, device, threads, finished_at}
VP/results/                           scorer outputs
VP/logs/                              logs
```

### segments.jsonl (one JSON object per line)

| field | meaning |
|---|---|
| `seg_id` | unique across all sets: `<set>:<speaker>:<session>:<n>`, with characters other than `[A-Za-z0-9_.:-]` replaced by `_` |
| `set` | set name |
| `speaker` | global, human-labeled speaker id, prefixed with the set (`vox1o:id10270`) |
| `session` | recording/session id (`vox1o:5r0dWxy17C8`, `ami:ES2002a`, `libri:1272-128104`) |
| `bucket` | 2, 4, or 8: the clip is cut to exactly this many seconds from one continuous single-speaker stretch |
| `dur` | clip seconds (= bucket) |
| `clip` | path relative to VP (`clips/<set>/clean/<seg_id>.wav`) |
| `src` | `{file, start, end}` in the original download |
| `gender` | optional |

**Rules for every set:**
- One talker per clip. There must be no overlap with another labeled speaker anywhere in the clip, and at least 0.3 s away from one.
- Not silent: clip RMS ≥ -45 dBFS.
- Per (speaker, session), up to 3 clips per bucket, from different places in the session. Aim for at least 2 sessions per speaker. A speaker with only one session is useful only as a stranger (impostor) and must be marked `"stranger_only": true`.
- At most about 3,000 clean clips per set. Prefer more speakers over more clips per speaker.

### Conditions (one shared script, `scripts/voiceprint/degrade.py`)

| cond | what |
|---|---|
| `clean` | as cut |
| `opus12` | Opus at 12 kbps, 16 kHz, like a weak Zoom/Meet link |
| `phone` | 8 kHz, 300–3400 Hz band, G.711 μ-law, back to 16 kHz |
| `noisy` | room reverb (RT60 0.3–0.7 s) plus music or babble at 5–15 dB SNR. Music and babble come from the YODAS bank (`data/eval/yodas3/bank/en`), never from an eval set |

Each condition is deterministic per `seg_id` (seeded) and keeps the clip length.

### model.json

```json
{"model_id": "wespeaker-resnet34-lm", "family": "wespeaker", "runtime": "sherpa",
 "files": ["wespeaker_en_voxceleb_resnet34_LM.onnx"], "dim": 256,
 "source_url": "...", "train_data": "VoxCeleb2 dev", "params_m": 6.6,
 "baseline": true, "status": "ready", "notes": "..."}
```

`runtime` names a module `scripts/voiceprint/runtimes/<runtime>.py` exposing:

```python
class Embedder:
    def __init__(self, model_dir: Path, meta: dict, threads: int = 3): ...
    def embed(self, wav: np.ndarray) -> np.ndarray:  # float32 mono 16 kHz in, 1-D float32 out
```

`status`: `ready` only after the agent has embedded 20 sample clips and checked that same-speaker cosine is clearly above different-speaker cosine.

## Who owns what

Agents never edit another agent's files. Agents never `git commit`; the coordinator commits. Every agent writes its scripts under `scripts/voiceprint/` using the file names it was given.

- `scripts/voiceprint/embed_daemon.py`, `slot` handling, and all commits: coordinator
- `scripts/voiceprint/sets/build_<set>.py`: that set's agent
- `scripts/voiceprint/degrade.py`: degradation agent
- `scripts/voiceprint/runtimes/<runtime>.py` + `VP/models/<id>/`: that runtime's agent
- `scripts/voiceprint/score_verify.py`: verification scorer
- `scripts/voiceprint/naming_sim.py`: naming simulator
- `VP/models/licenses.json`: license agent

## Safety rules (hard)

- Never read or write `~/Library/Application Support/Transcripted`, the real speaker database, the capture library, or app preferences.
- Don't kill processes by pattern (`pkill`, `killall`). Kill only the PIDs you started.
- Keep downloads under `VP/raw` or `VP/models`. Datasets are for local evaluation only and are never committed or uploaded.
- Heavy compute: at most 3 threads per process (`OMP_NUM_THREADS=3`), and at most 2 heavy processes per agent. Bulk embedding is the coordinator's `embed_daemon.py`, not the model agents.
- Don't edit Swift sources in Stages 1–2.
- **Installing packages:** the venv is shared, so installs must never overlap. Take the lock with `mkdir VP/logs/pip.lock`: it succeeds only if nobody else holds it, and if it fails, wait and retry. Then run `"/Users/redbars/Library/Application Support/Tilde Lab/Tools/uv" pip install --python VP/venv/bin/python <pkg>`, then `rmdir VP/logs/pip.lock`. Never downgrade torch or numpy. If a model needs conflicting versions, make its own venv under `VP/venvs/<name>`.
- **Long commands:** run them in the background and wait for them to finish; don't chain `sleep`s.
