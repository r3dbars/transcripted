# Real-Zoom validation — how to close the domain gap

Every number in the embedding bake-off is from **AMI** (4 people, one room, far-field mics, *synthetically*
codec-degraded). Real Transcripted audio is **captured Zoom/Meet/Teams system audio** — different distribution
(separate streams, real codec + noise-suppression + auto-gain). The codec-robustness story should transfer,
but it's **assumed, not measured**. This is the one experiment that needs real data only you can provide.

## What to provide

1. **A recording** of a real call you'd transcribe — ideally the *same system-audio capture* Transcripted
   makes — with **2+ known speakers** and a few minutes each. Save as a `.wav` (any rate/channels; it's
   resampled to 16 kHz mono internally). A couple of recordings across conditions (good wifi, someone on a
   phone bridge) is even better.
2. **Ground-truth labels** — who spoke when. Easiest path: make a CSV and convert it:

   ```csv
   start,end,speaker
   0.0,4.2,alice
   4.2,9.8,bob
   9.8,15.0,alice
   ```
   ```bash
   python3 scripts/csv2rttm.py labels.csv mycall > mycall.rttm
   ```
   (You can label by scrubbing the recording, or export a Zoom transcript and adjust. Exact word-level timing
   isn't needed — speaker turns are enough.)

## Run it

```bash
# builds: diarize -> WeSpeaker baseline + each candidate model -> scorecard, all vs your labels
scripts/run_zoom_eval.sh mycall.wav mycall.rttm mycall "campplus eres2net ecapa"
```

Prints, for WeSpeaker (current) and each candidate, on **your real audio**:
`coverage` (speakers correctly separated), `DER` (error, lower better), `cross-call AUC` (separability).

## What success looks like

The recommendation **holds** if, on your real recording, CAM++ (and/or ERes2Net/ECAPA) shows **lower DER and
higher coverage than WeSpeaker**, the way it does on AMI. If real Zoom audio behaves *differently* (e.g. the
gap shrinks because separate streams are easier, or a new failure appears), this is where we'd catch it before
shipping. Either way it converts the AMI result into a real-world one.

> All artifacts land under `data/eval/zoom_<name>*` (gitignored). Measurement only — no app code touched.
