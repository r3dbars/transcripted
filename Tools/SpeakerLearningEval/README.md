# Speaker Learning Eval

Local-only cold-start scoreboard for Transcripted speaker learning.

The first harness uses Zoom transcript speaker labels as ground truth. It does
not tune thresholds, run audio models, upload data, print transcript text, or
persist transcript text.

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

Run the harness tests:

```bash
python3 -m unittest Tools/SpeakerLearningEval/tests/test_speaker_learning_eval.py
```
