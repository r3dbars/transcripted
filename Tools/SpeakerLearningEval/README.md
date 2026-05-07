# Speaker Learning Eval

Local-only cold-start scoreboard for Transcripted speaker learning.

The baseline harness uses Zoom transcript speaker labels as ground truth. It
does not tune thresholds, upload data, print transcript text, or persist
transcript text.

Run the 3-meeting smoke eval:

```bash
python3 Tools/SpeakerLearningEval/speaker_learning_eval.py \
  --corpus /Users/redbars/Downloads/meeting-corpus \
  --limit 3 \
  --output .transcripted-speaker-eval/smoke-3.json
```

Run the full 25-meeting eval:

```bash
python3 Tools/SpeakerLearningEval/speaker_learning_eval.py \
  --corpus /Users/redbars/Downloads/meeting-corpus \
  --output .transcripted-speaker-eval/full-25.json
```

The JSON report tracks:

- unknown labels required
- correct automatic matches after a speaker has been labeled once
- false matches
- duplicate profiles per real speaker
- meetings to first recognition
- runtime
- top failure cases

Speaker labels are redacted by default. Use `--include-speaker-labels` only for
local debugging.

Run the audio-backed 3-meeting smoke eval:

```bash
python3 Tools/SpeakerLearningEval/speaker_learning_eval.py \
  --mode audio \
  --corpus /Users/redbars/Downloads/meeting-corpus \
  --limit 3 \
  --output .transcripted-speaker-eval/audio-smoke-3.json \
  --audio-cache .transcripted-speaker-eval/audio-cache
```

Run the full audio-backed eval:

```bash
python3 Tools/SpeakerLearningEval/speaker_learning_eval.py \
  --mode audio \
  --corpus /Users/redbars/Downloads/meeting-corpus \
  --output .transcripted-speaker-eval/audio-full-25.json \
  --audio-cache .transcripted-speaker-eval/audio-cache
```

Audio mode runs Transcripted's offline diarization CLI against both
`system_audio` and `microphone` tracks, captures per-segment embeddings in the
local cache, and scores profile matches against Zoom speaker labels. The cache
and reports stay under `.transcripted-speaker-eval/`, which is ignored by git.

Run the harness tests:

```bash
python3 -m unittest \
  Tools/SpeakerLearningEval/tests/test_speaker_learning_eval.py \
  Tools/SpeakerLearningEval/tests/test_autoresearch_loop.py
```

Run a Karpathy-style local autoresearch pass:

```bash
python3 Tools/SpeakerLearningEval/autoresearch_loop.py \
  --mode audio \
  --corpus /Users/redbars/Downloads/meeting-corpus \
  --limit 3 \
  --cycles 1
```

The loop writes `experiments.jsonl`, `best.json`, and short Markdown summaries
under `.transcripted-speaker-eval/autoresearch/`. The scoring gate is simple:
wrong names must stay at zero, then the loop ranks correct auto-names,
recurring speakers recognized, manual confirmations avoided, and duplicate
folder cleanup.
