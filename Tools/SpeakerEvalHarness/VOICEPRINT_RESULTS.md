# Voiceprint bake-off: results

_Generated 2026-09-29 00:18 by `scripts/voiceprint/build_report.py` from `data/eval/voiceprint/results`. Rerun it any time; numbers that haven't landed show as pending. The charts and raw tables live under `data/eval/voiceprint/results/report/` (gitignored with the rest of `data/`)._

## The short version

- We scored **23 voiceprint networks** (25 builds, 21 networks we could legally ship) on 11,399 clips (after the audit drops) of 334 real people in four human-labeled sets, plus a fifth set with model-made labels that we keep out of the ranking.
- Today's model (`app-wespeaker-coreml`) accepts 74.6% [72.3, 77.5] of same-person pairs on call audio at 1 false accept in 1,000.
- **Winner: `redimnet2-b6-vox2-lm`.** 84.6% [82.3, 86.6] on call audio, +10.0 [+8.0, +11.2]* points vs today's model. That's a clear win: the paired interval excludes zero.
- Runner-up: `redimnet-b6-vox2-lm` at 83.8% [81.5, 86.0]. The intervals overlap, so this metric alone can't separate them.
- Wrong silent names: **0 for all 23 models simulated.** That was the hard gate.
- Still pending: call-audio verification for 12 networks (3dspeaker-campplus-en-voxceleb, 3dspeaker-campplus-zh-cn-common, 3dspeaker-eres2net-base-200k-zh-cn-common, redimnet-M-vb2-vox2-cnc-ft_mix, redimnet-b2-vox2-lm...); naming with call audio for 15 models.

## What we tested and why

Nemotron now separates the speakers in a meeting (PR #1887). So the voiceprint model only has to answer one thing: is this the same person we heard before? Today that model is the WeSpeaker ResNet34-LM embedding inside FluidAudio. We wanted to know if anything we can legally ship does that better.

Four kinds of test, because one number lies:

1. **Pairwise verification.** Take two clips. Same person or not? We report *TAR at FAR 1e-3*: of all same-person pairs, the share we accept when the bar is set so only 1 in 1,000 different-person pairs sneaks through (higher is better). EER is where misses equal false accepts (lower is better). Clips are 2, 4 and 8 seconds. Same person always means a *different* session, never the same recording.
2. **Call audio.** The headline is *cross-condition*: enroll a person on clean audio, then test on a weak Opus 12 kbps link, a phone line (8 kHz, μ-law), or a reverberant room with music or babble at 5 to 15 dB SNR. That's what a meeting app hears.
3. **Naming simulation.** A Python mirror of the app's naming replays whole runs of meetings with each model, with the bars calibrated per model. It counts what a user feels: how many meetings until a regular is named automatically, how often we suggest the wrong name, and wrong *silent* names, which must be zero.
4. **Lineup, speed, and the real pipeline.** A lineup of everyone at once (334 people), how long one clip takes, and finally the winner run through the actual app pipeline against today's model.

The gate for shipping: the license has to allow it, and wrong silent names have to be zero. Accuracy only ranks what passes.

## Datasets

All audio is 16 kHz mono. We use local copies for evaluation only; nothing is committed or uploaded.

| set | what it is | people | sessions | clips (2 / 4 / 8 s) | dropped by audit | used for | conditions |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `vox1o` | VoxCeleb1 test: 40 celebrities, each in many different YouTube videos. Human-checked. Old-school interviews. | 40 | 676 | 2,869 (906 / 1,000 / 963) | 114 | ranking | clean, opus12, phone, noisy |
| `libri` | LibriSpeech: 146 readers, several chapters each. Read speech, clean, easy. | 146 (29 single-session) | 365 | 3,000 (1,002 / 1,016 / 982) | 9 | ranking | clean, opus12, phone, noisy |
| `ami` | AMI meetings: 96 people in 24 groups who meet four times. Closest public thing to the product. | 96 | 96 | 3,000 (1,000 / 1,000 / 1,000) | 344 | ranking | clean, opus12, phone, noisy |
| `icsi` | ICSI meetings: 52 researchers who meet week after week. Noisier headset mix, real weekly regulars. | 52 (14 single-session) | 74 | 3,000 (1,014 / 1,042 / 944) | 3 | ranking | clean, opus12, phone, noisy |
| `yodas` | YouTube speech (YODAS3). Labels made by two models agreeing, not by people. Reported on its own, never ranked. | 246 (236 single-session) | 265 | 2,080 (659 / 687 / 734) | 0 | reported separately | clean, opus12, phone, noisy |

The four ranked sets hold 334 people. Single-session people can only be strangers (impostors), never the person you're trying to recognize.

Call-audio copies, made by `scripts/voiceprint/degrade.py`, one deterministic copy per clip and condition:

- `opus12`: Opus at 12 kbps, like a weak Zoom or Meet link.
- `phone`: 8 kHz, 300 to 3400 Hz, G.711 μ-law.
- `noisy`: room reverb (RT60 0.3 to 0.7 s) plus music or babble at 5 to 15 dB SNR. The noise comes from a separate bank, never from an eval set.

Trials are sampled once per set and clip length (up to 30,000 of each kind) and reused for every model and condition, so every model faces the same pairs.

| set | clip length | people | clips | same-person pairs | different-person pairs (same session) | false accepts allowed at 1e-3 / 1e-4 |
| --- | --- | --- | --- | --- | --- | --- |
| `ami` | 2 s | 96 | 892 | 3093 of 3093 | 30000 (245) | 30 / 3 |
| `ami` | 4 s | 96 | 894 | 3098 of 3098 | 30000 (264) | 30 / 3 |
| `ami` | 8 s | 96 | 870 | 2938 of 2938 | 30000 (243) | 30 / 3 |
| `icsi` | 2 s | 52 | 1012 | 17623 of 17623 | 30000 (383) | 30 / 3 |
| `icsi` | 4 s | 52 | 1041 | 20334 of 20334 | 30000 (365) | 30 / 3 |
| `icsi` | 8 s | 51 | 944 | 18714 of 18714 | 30000 (313) | 30 / 3 |
| `libri` | 2 s | 146 | 999 | 2396 of 2396 | 30000 (0) | 30 / 3 |
| `libri` | 4 s | 146 | 1013 | 2478 of 2478 | 30000 (0) | 30 / 3 |
| `libri` | 8 s | 146 | 979 | 2294 of 2294 | 30000 (0) | 30 / 3 |
| `vox1o` | 2 s | 40 | 869 | 9000 of 9000 | 30000 (0) | 30 / 3 |
| `vox1o` | 4 s | 40 | 961 | 10816 of 10816 | 30000 (0) | 30 / 3 |
| `vox1o` | 8 s | 40 | 925 | 12975 of 12975 | 30000 (0) | 30 / 3 |
| `yodas` | 2 s | 230 | 659 | 238 of 238 | 30000 (0) | 30 / 3 |
| `yodas` | 4 s | 239 | 687 | 202 of 202 | 30000 (0) | 30 / 3 |
| `yodas` | 8 s | 239 | 734 | 274 of 274 | 30000 (0) | 30 / 3 |

**We audited the answer key before trusting any ranking.** Details in `results/audit/audit.md`.

- Clips dropped before scoring: vox1o 114, libri 9, ami 344, icsi 3. Reasons: re-uploaded videos in vox1o (same recording under two session ids), a chapter read by someone else in libri, mislabeled clips, and AMI clips with another person's laugh or cough inside.
- AMI: 332 of 3,000 clips have another participant's laugh or cough inside. Models misplace those about 4 to 6 times as often. They're dropped.
- For the six models the audit checked, the drops don't change their order on any set; they shift everyone together.

## Results

Headline metric: **true accepts at 1 in 1,000 false accepts on call audio**, pooled over the four human sets (mean over sets of the mean over clip lengths and conditions). Brackets are 95% bootstrap intervals over speakers. **Δ** is the paired difference to today's model on the cells both have, in percentage points; `*` means the interval excludes zero. Each model uses the better of raw cosine, centered cosine and AS-norm (the scorer picks it); that selection flatters every model a little and the Δ interval doesn't include it.

![Ranking of call-audio accuracy with 95% intervals](../../data/eval/voiceprint/results/report/ranking.png)

### Every model

`Ship?` is the license verdict (engineering triage, not legal advice). `clean` and `call` are the headline metric on clean and call audio. `lineup` is clean / call in the 334-person lineup. `auto from mtg 3+` is the share of a regular's appearances named silently from their third meeting on, with bars calibrated on clean audio only (the same footing for every model) / with call audio in the calibration. `wrong names` is wrong silent names in the simulation (must be 0). `ms/clip` is embed time for one clip; `~` means a rough timing from the embedding job on a busy machine, not a benchmark. `cells` is scored (set, clip length, condition) cells out of the most any model has. Rows marked _(Core ML)_ are the same network converted to Core ML, so the accuracy should match; parity is in the latency section.

| # | model | ship? | params (M) | clean | call [95% CI] | Δ vs baseline | EER call | lineup | auto from mtg 3+ | wrong names | ms/clip | cells |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `redimnet2-b6-vox2-lm` | yes, credit | 12.4 | 93.6 | 84.6 [82.3, 86.6] | +10.0 [+8.0, +11.2]* | 2.83 | 92% / 83% | 68% / 36% | 0 | ~160 | 60/60 |
| 2 | `redimnet-b6-vox2-lm` | yes, credit | 15.0 | 92.9 | 83.8 [81.5, 86.0] | +9.2 [+7.4, +10.7]* | 3.08 | 96% / 88% | 68% / pending | 0 | ~151 | 60/60 |
| 3 | `redimnet2-b4-vox2-lm` | yes, credit | 6.7 | 92.8 | 83.0 [80.1, 85.1] | +8.3 [+6.2, +9.6]* | 3.14 | 94% / 86% | 70% / 27% | 0 | ~79 | 60/60 |
| 4 | `wespeaker-resnet293-lm-coreml` _(Core ML)_ | yes, credit | 28.6 | 92.2 | 80.7 [78.5, 83.2] | +6.0 [+4.6, +7.4]* | 3.42 | 91% / 70% | 52% / pending | 0 | 20 | 60/60 |
| 5 | `wespeaker-resnet221-lm-coreml` _(Core ML)_ | yes, credit | 23.7 | 92.0 | 80.5 [78.1, 83.0] | +5.9 [+4.1, +7.3]* | 3.45 | 89% / 73% | 51% / 22% | 0 | 15 | 60/60 |
| 6 | `wespeaker-resnet34-lm` | yes, credit | 6.6 | 89.3 | 75.1 [72.6, 77.6] | +0.5 [-0.5, +0.9] | 4.26 | 84% / 65% | 66% / 26% | 0 | ~141 | 60/60 |
| 7 | `app-wespeaker-coreml` **(baseline)** | yes, credit | 6.6 | 88.7 | 74.6 [72.3, 77.5] | ref | 4.25 | 87% / 70% | 58% / 25% | 0 | 11 | 60/60 |
| 8 | `wespeaker-campplus-lm` | yes, credit | 7.2 | 87.4 | 74.6 [71.8, 77.7] | -0.1 [-1.8, +1.3] | 4.25 | 88% / 73% | 58% / 20% | 0 | ~101 | 60/60 |
| 9 | `3dspeaker-campplus-zh-en-common-advanced` | yes (medium risk) | 6.9 | 83.4 | 72.6 [69.3, 75.8] | -2.0 [-4.5, +0.2] | 4.24 | 82% / 70% | 63% / 19% | 0 | ~69 | 60/60 |
| 10 | `3dspeaker-eres2net-en-voxceleb` | yes, credit | 6.6 | 86.6 | 70.9 [68.5, 74.2] | -3.7 [-5.4, -1.7]* | 4.89 | 80% / 61% | 61% / 37% | 0 | ~153 | 60/60 |
| 11 | `titanet-large` | yes, credit (medium risk) | 25.3 | 84.7 | 67.7 [64.4, 71.5] | -6.9 [-9.4, -4.2]* | 5.50 | 77% / 64% | 37% / pending | 0 | ~203 | 60/60 |
| 12 | `redimnet2-b3-vb2-vox2-cnc2-lm` | no (reference only) | 4.5 | 93.9 | pending | – | pending | 93% / pending | 80% / pending | 0 | ~82 | 12/60 partial |
| 13 | `redimnet2-b6-vox2-lm-coreml` _(Core ML)_ | yes, credit | 12.4 | 93.6 | pending | – | pending | 92% / pending | 68% / pending | 0 | 23 | 12/60 partial |
| 14 | `redimnet2-b4-vox2-lm-coreml` _(Core ML)_ | yes, credit | 6.7 | 92.8 | pending | – | pending | 94% / pending | 70% / pending | 0 | 15 | 12/60 partial |
| 15 | `redimnet-M-vb2-vox2-cnc-ft_mix` | no (reference only) | 4.8 | 92.0 | pending | – | pending | 87% / pending | 60% / pending | 0 | ~95 | 12/60 partial |
| 16 | `redimnet2-b2-vox2-lm` | yes, credit | 3.7 | 90.2 | pending | – | pending | 87% / pending | 63% / pending | 0 | ~102 | 12/60 partial |
| 17 | `wespeaker-campplus` | yes, credit | 7.2 | 89.6 | pending | – | pending | 85% / pending | 59% / pending | 0 | ~172 | 12/60 partial |
| 18 | `wespeaker-resnet34` | yes, credit | 6.6 | 89.2 | pending | – | pending | 85% / pending | 69% / pending | 0 | ~184 | 12/60 partial |
| 19 | `redimnet-b2-vox2-lm` | yes, credit | 5.1 | 89.0 | pending | – | pending | 89% / pending | 60% / pending | 0 | ~62 | 12/60 partial |
| 20 | `3dspeaker-campplus-en-voxceleb` | yes, credit | 7.2 | 87.1 | pending | – | pending | 84% / pending | 52% / pending | 0 | ~204 | 12/60 partial |
| 21 | `titanet-small` | yes, credit (medium risk) | 10.0 | 80.4 | pending | – | pending | 76% / pending | 46% / pending | 0 | ~90 | 12/60 partial |
| 22 | `3dspeaker-eres2net-base-200k-zh-cn-common` | yes (medium risk) | 9.9 | 64.3 | pending | – | pending | pending | 49% / pending | 0 | ~331 | 9/60 partial |
| 23 | `speakernet` | yes, credit | 5.8 | 61.8 | pending | – | pending | 65% / pending | 32% / pending | 0 | ~51 | 12/60 partial |
| 24 | `3dspeaker-campplus-zh-cn-common` | yes (medium risk) | 6.9 | 47.4 | pending | – | pending | 52% / pending | 9.1% / pending | 0 | ~142 | 12/60 partial |
| 25 | `speechbrain-xvector-vox` | yes, credit | 4.2 | 44.5 | pending | – | pending | 34% / pending | 17% / pending | 0 | ~9.6 | 12/60 partial |

**Set up but not scored yet** (no embeddings scored): `3dspeaker-campplus-zh-en-common-advanced-coreml` (yes (medium risk)), `3dspeaker-eres2net-zh-cn-common` (yes (medium risk)), `3dspeaker-eres2netv2-zh-cn-common` (yes (medium risk)), `ecapa2` (no (reference only)), `redimnet2-b4-eval-full10-turnlen` (yes, credit, eval), `redimnet2-b4-eval-s124-fp16-turnlen` (yes, credit, eval), `redimnet2-b4-eval-s1248-fp16-turnlen` (yes, credit, eval), `redimnet2-b4-eval-s24-fp16` (yes, credit, eval), `redimnet2-b4-eval-s24-fp16-turnlen` (yes, credit, eval), `redimnet2-b4-eval-s248-fp16` (yes, credit, eval), `redimnet2-b4-eval-s248-fp32-turnlen` (yes, credit, eval), `redimnet2-b4-eval-s2510-fp32` (yes, credit, eval), `redimnet2-b4-eval-s310-fp32` (yes, credit, eval), `redimnet2-b6-vb2-vox2-cnc2-lm` (no (reference only)), `speechbrain-ecapa-vox` (yes, credit), `speechbrain-resnet-vox` (yes, credit), `titanet-large-coreml` (yes, credit (medium risk)), `unispeech-sat-base-plus-sv` (unclear), `wavlm-base-plus-sv` (unclear), `wespeaker-resnet152-lm` (yes, credit), `wespeaker-resnet221-lm` (yes, credit), `wespeaker-resnet293-lm` (yes, credit).

### By condition and clip length

TAR at FAR 1e-3 / EER, both in %. The clean>x columns enroll clean and test on the degraded copy; the last three are call audio by clip length.

| model | clean | clean>opus12 | clean>phone | clean>noisy | 2 s | 4 s | 8 s |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `redimnet2-b6-vox2-lm` | 93.6 / 1.15 | 87.8 / 1.89 | pending | 81.5 / 3.77 | 66.8 / 5.21 | 89.3 / 2.33 | 97.7 / 0.96 |
| `redimnet-b6-vox2-lm` | 92.9 / 1.37 | 87.6 / 2.04 | pending | 80.0 / 4.12 | 65.5 / 5.79 | 88.4 / 2.44 | 97.5 / 1.01 |
| `redimnet2-b4-vox2-lm` | 92.8 / 1.31 | 86.3 / 2.10 | pending | 79.6 / 4.18 | 64.0 / 5.80 | 87.7 / 2.65 | 97.2 / 0.97 |
| `wespeaker-resnet293-lm-coreml` _(Core ML)_ | 92.2 / 1.48 | 83.7 / 2.42 | pending | 77.7 / 4.43 | 61.1 / 6.11 | 85.1 / 2.94 | 95.8 / 1.22 |
| `wespeaker-resnet221-lm-coreml` _(Core ML)_ | 92.0 / 1.45 | 84.0 / 2.36 | pending | 77.1 / 4.55 | 60.4 / 6.14 | 85.3 / 2.94 | 95.8 / 1.28 |
| `wespeaker-resnet34-lm` | 89.3 / 1.78 | 79.6 / 2.91 | pending | 70.6 / 5.61 | 52.8 / 7.32 | 78.9 / 3.77 | 93.6 / 1.69 |
| `app-wespeaker-coreml` **(baseline)** | 88.7 / 1.77 | 79.0 / 2.94 | pending | 70.2 / 5.56 | 52.8 / 7.27 | 78.2 / 3.81 | 92.8 / 1.67 |
| `wespeaker-campplus-lm` | 87.4 / 1.96 | 78.4 / 2.92 | pending | 70.7 / 5.57 | 51.2 / 7.61 | 78.5 / 3.66 | 94.0 / 1.47 |
| `3dspeaker-campplus-zh-en-common-advanced` | 83.4 / 2.45 | 75.7 / 3.43 | pending | 69.5 / 5.06 | 51.0 / 7.10 | 76.0 / 3.89 | 90.8 / 1.75 |
| `3dspeaker-eres2net-en-voxceleb` | 86.6 / 2.05 | 77.6 / 3.05 | pending | 64.3 / 6.73 | 47.3 / 8.21 | 74.8 / 4.43 | 90.7 / 2.04 |
| `titanet-large` | 84.7 / 2.35 | 77.4 / 3.21 | pending | 58.0 / 7.79 | 46.3 / 8.61 | 71.1 / 5.09 | 85.7 / 2.81 |

![Clean vs call-audio accuracy for the top models](../../data/eval/voiceprint/results/report/clean_vs_call.png)

## Winner and runner-up

The rule: a shippable license, every cell scored, zero wrong silent names in the naming simulation. Then the highest call-audio accuracy. We don't crown anyone while a candidate that looks better on the cells it has is still being scored.

### Winner: `redimnet2-b6-vox2-lm`

- **Call audio:** 84.6% [82.3, 86.6] at 1 in 1,000 false accepts; EER 2.83%. Clean: 93.6% [91.7, 95.0].
- **Against today's model** (74.6% [72.3, 77.5]): +10.0 [+8.0, +11.2]* points, paired on 24 shared call-audio cells. That's clearly better.
- **Naming:** names 68% of a regular's appearances from meeting 3 on (clean bars), median first automatic name at meeting 3; wrong silent names 0; 64 wrong suggestions (1.4%). With call audio in the calibration: 36%.
- **Lineup (DIR at zero wrong names):** 92% clean, 83% on opus12 probes.
- **Size and speed:** 12.4M parameters; about 23 ms per clip (measured in latency.md).
- **Core ML build** (`redimnet2-b6-vox2-lm-coreml`): fp32, worst parity 1.0, 54.6 MB, runs on gpu.
- **License:** MIT weights (repo license, release assets); credit VoxCeleb. (eligible-attribution, low risk). Trained on: VoxCeleb2 dev (vox2), pretrain then large-margin finetune (lm).

### Runner-up: `redimnet-b6-vox2-lm`

- **Call audio:** 83.8% [81.5, 86.0] at 1 in 1,000 false accepts; EER 3.08%. Clean: 92.9% [91.6, 94.6].
- **Against today's model** (74.6% [72.3, 77.5]): +9.2 [+7.4, +10.7]* points, paired on 24 shared call-audio cells. That's clearly better.
- **Against the winner:** intervals overlap, no separation on this metric.
- **Naming:** names 68% of a regular's appearances from meeting 3 on (clean bars), median first automatic name at meeting 3; wrong silent names 0; 72 wrong suggestions (1.6%).
- **Lineup (DIR at zero wrong names):** 96% clean, 88% on opus12 probes.
- **Size and speed:** 15.0M parameters; about 151 ms per clip (rough embed-job timing on a busy machine).
- **License:** MIT (repo license covers release weights; none stated separately); credit VoxCeleb. (eligible-attribution, low risk). Trained on: VoxCeleb2 dev (vox2), pretrain then large-margin finetune (ft_lm).

## Naming simulation

This is what a user feels. For each model we replay realistic runs of meetings (AMI and ICSI as they happened, LibriSpeech and VoxCeleb as invented recurring groups), with the app's naming rules mirrored in Python: match against the profiles from before each meeting, name silently only when confirmations, similarity bar and margin all agree, otherwise suggest or ask. A simulated user always knows who is who and corrects mistakes. Bars are calibrated on half the speakers and scored on the other half, both ways.

Work per meeting: type a name 3, pick a known person 2, confirm a suggestion 1, fix a wrong suggestion 3, fix a wrong silent name 10.

| model | ship? | wrong silent names (all runs) | look-alike pairs over bar | strangers wrongly named | wrong suggestions | auto from mtg 3+ (clean bars) | first auto: median / p90 meeting | work per meeting | with call audio: auto from mtg 3+ / wrong / work |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `redimnet2-b3-vb2-vox2-cnc2-lm` | no (reference only) | 0 | 0 / 14,647 | 0 | 76 (2.3%) | 80% | 3 / never | 3.75 | pending |
| `redimnet2-b4-vox2-lm` | yes, credit | 0 | 0 / 43,941 | 0 | 68 (1.6%) | 70% | 3 / never | 3.94 | 27% / 0 / 4.80 |
| `wespeaker-resnet34` | yes, credit | 0 | 0 / 14,647 | 0 | 70 (1.8%) | 69% | 3 / never | 4.00 | pending |
| `redimnet-b6-vox2-lm` | yes, credit | 0 | 0 / 14,647 | 0 | 72 (1.6%) | 68% | 3 / never | 3.94 | pending |
| `redimnet2-b6-vox2-lm` | yes, credit | 0 | 0 / 42,421 | 0 | 64 (1.4%) | 68% | 3 / never | 3.94 | 36% / 0 / 4.43 |
| `wespeaker-resnet34-lm` | yes, credit | 0 | 0 / 43,941 | 0 | 74 (1.7%) | 66% | 3 / never | 4.06 | 26% / 0 / 4.84 |
| `redimnet2-b2-vox2-lm` | yes, credit | 0 | 0 / 14,647 | 0 | 118 (2.4%) | 63% | 3 / never | 4.03 | pending |
| `3dspeaker-campplus-zh-en-common-advanced` | yes (medium risk) | 0 | 0 / 43,941 | 0 | 88 (2.0%) | 63% | 3 / never | 4.14 | 19% / 0 / 5.03 |
| `3dspeaker-eres2net-en-voxceleb` | yes, credit | 0 | 0 / 43,941 | 0 | 122 (2.5%) | 61% | 3 / never | 4.11 | 37% / 0 / 4.68 |
| `redimnet-M-vb2-vox2-cnc-ft_mix` | no (reference only) | 0 | 0 / 14,647 | 0 | 98 (1.8%) | 60% | 3 / never | 4.04 | pending |
| `redimnet-b2-vox2-lm` | yes, credit | 0 | 0 / 14,647 | 0 | 104 (2.0%) | 60% | 3 / never | 4.08 | pending |
| `wespeaker-campplus` | yes, credit | 0 | 0 / 14,647 | 0 | 108 (2.0%) | 59% | 3 / never | 4.11 | pending |
| `wespeaker-campplus-lm` | yes, credit | 0 | 0 / 43,941 | 0 | 108 (2.1%) | 58% | 3 / never | 4.14 | 20% / 0 / 4.97 |
| `app-wespeaker-coreml` **(baseline)** | yes, credit | 0 | 0 / 43,941 | 0 | 116 (2.2%) | 58% | 3 / never | 4.14 | 25% / 0 / 4.91 |
| `wespeaker-resnet293-lm-coreml` _(Core ML)_ | yes, credit | 0 | 0 / 14,647 | 0 | 74 (1.3%) | 52% | 4 / never | 4.22 | pending |
| `3dspeaker-campplus-en-voxceleb` | yes, credit | 0 | 0 / 14,647 | 0 | 88 (1.6%) | 52% | 4 / never | 4.28 | pending |
| `wespeaker-resnet221-lm-coreml` _(Core ML)_ | yes, credit | 0 | 0 / 43,941 | 0 | 84 (1.4%) | 51% | 4 / never | 4.26 | 22% / 0 / 4.94 |
| `3dspeaker-eres2net-base-200k-zh-cn-common` | yes (medium risk) | 0 | 0 / 13,887 | 0 | 210 (4.6%) | 49% | 4 / never | 4.25 | pending |
| `titanet-small` | yes, credit (medium risk) | 0 | 0 / 14,647 | 0 | 234 (3.8%) | 46% | 5 / never | 4.39 | pending |
| `titanet-large` | yes, credit (medium risk) | 0 | 0 / 14,647 | 0 | 204 (2.9%) | 37% | never / never | 4.49 | pending |
| `speakernet` | yes, credit | 0 | 0 / 14,647 | 0 | 578 (8.1%) | 32% | never / never | 4.79 | pending |
| `speechbrain-xvector-vox` | yes, credit | 0 | 0 / 14,647 | 0 | 600 (8.5%) | 17% | never / never | 5.30 | pending |
| `3dspeaker-campplus-zh-cn-common` | yes (medium risk) | 0 | 0 / 14,647 | 0 | 582 (6.6%) | 9.1% | never / never | 5.19 | pending |

For scale, today's model with the app's shipped bars (0.70 / 0.80 / 0.92, no calibration) names 47% of regulars' appearances from meeting 3 on clean audio and 35% on call audio, with 0 wrong silent names. Our calibration (zero wrong names plus a safety margin, same recipe for every model) gives the same model 58% with clean-only bars, and 43% clean / 25% call once call audio is in the calibration. Absolute rates move a lot with how strict the bars are, so read the table as models against each other, not against the live app.

Notes on reading it:

- **Clean-only bars** are calibrated on clean audio for every model, so they compare fairly. **With call audio** bars are calibrated on every condition a model has, like the app, which makes them stricter; compare those columns only between models that have the same coverage.
- No confidence intervals here: the simulation is point estimates over many seeded runs (48 per model in the last check), not a bootstrap.
- A model shows a look-alike pair when two different held-out people clear the lineup bar against each other. It over-counts on purpose.

## Lineup (334 people)

Everyone at once: all labeled people share one database and each probe has to pick the right name, or none for a stranger. The number in the model table is **DIR at zero wrong names**: the share of known people shown with the right name at the lowest bar where nobody, known or stranger, gets a wrong name. Higher is better; the table shows clean / opus12 probes, one bar per model.

Generated 2026-09-28 21:42 by `scripts/voiceprint/score_lineup.py`. All 334 people of vox1o, libri, ami and icsi (after the audit drop lists) share one database. Per seed, about 233 are enrolled (their earliest session, all clips) and about 101 are strangers who are never enrolled: every `stranger_only` person plus 20% of each set's multi-session people. Probes are every later session of an enrolled person and every session of a stranger. Numbers are means over 5 seeds (which people are strangers, which clips make the 1- and 3-clip probes).

How to read it. A name is shown when the top match's cosine clears the model's bar. **DIR** = known person, right name shown. **misID** = known person, wrong name shown. **stranger FA** = stranger given someone's name. **DIR @ 0 wrong** = DIR at the lowest bar where nobody (known or stranger) gets a wrong name. **One bar per model** (per talk time): set on clean + opus12 + noisy probes pooled, because the app can't tell a clean room from a weak call; the columns then show each condition at that one bar. `0.1% FA bar` = the bar letting through at most 0.1% of stranger probes; with 1,129 stranger probes per seed over 3 conditions that allows 1 stranger false alarm(s) in the pooled set.

People: 334 human-labeled (43 `stranger_only`), plus 236 yodas `stranger_only` people for the extra-distractor check. Drops applied: vox1o 114, libri 9, ami 344, icsi 3, yodas 0.

**Call audio, models with full coverage (opus12 probes)**

Ranked by the headline: **DIR at zero wrong names on opus12 probes**, clean enrollment (1 session), all clips, pooled lineup, one bar per model. `score` = the scoring that wins the headline for that model (raw cosine or centered cosine).

| # | model | score | rank-1 opus12 | **DIR @ 0 wrong, opus12** | DIR @ 0 wrong clean / noisy | misID @ 0.1% FA bar, opus12 (mean count per seed) | stranger FA @ 0.1% FA bar, clean / opus12 / noisy | misID @ 1% FA bar, opus12 | bar @ 0 wrong |
|---|---|---|---|---|---|---|---|---|---|
| 1 | redimnet-b6-vox2-lm | centered | 99.6% | **88.4% ± 0.9** | 94.0% / 86.4% | 0.00% (0.0) | 0.00% / 0.00% / 0.27% | 0.00% (0.0) | 0.591 |
| 2 | redimnet2-b4-vox2-lm | centered | 99.5% | **85.8% ± 2.4** | 92.1% / 84.7% | 0.00% (0.0) | 0.00% / 0.00% / 0.27% | 0.00% (0.0) | 0.596 |
| 3 | redimnet2-b6-vox2-lm | raw | 99.6% | **82.8% ± 2.1** | 90.6% / 83.7% | 0.00% (0.0) | 0.00% / 0.00% / 0.27% | 0.00% (0.0) | 0.634 |
| 4 | wespeaker-resnet221-lm-coreml | centered | 99.1% | **73.5% ± 1.4** | 88.8% / 76.0% | 0.00% (0.0) | 0.27% / 0.00% / 0.00% | 0.00% (0.0) | 0.626 |
| 5 | wespeaker-campplus-lm | centered | 99.1% | **73.4% ± 7.2** | 87.4% / 75.8% | 0.00% (0.0) | 0.22% / 0.00% / 0.05% | 0.08% (1.0) | 0.658 |
| 6 | wespeaker-resnet293-lm-coreml | centered | 99.1% | **70.2% ± 2.0** | 87.0% / 74.9% | 0.00% (0.0) | 0.00% / 0.00% / 0.27% | 0.00% (0.0) | 0.639 |
| 7 | 3dspeaker-campplus-zh-en-common-advanced | raw | 98.3% | **70.2% ± 1.7** | 81.2% / 72.8% | 0.02% (0.2) | 0.21% / 0.00% / 0.06% | 0.05% (0.6) | 0.679 |
| 8 | **app-wespeaker-coreml** (baseline) | centered | 98.9% | **70.2% ± 2.5** | 86.7% / 74.5% | 0.00% (0.0) | 0.27% / 0.00% / 0.00% | 0.02% (0.2) | 0.622 |
| 9 | wespeaker-resnet34-lm | raw | 98.9% | **64.7% ± 6.2** | 84.0% / 71.1% | 0.00% (0.0) | 0.22% / 0.00% / 0.05% | 0.00% (0.0) | 0.659 |
| 10 | titanet-large | centered | 98.8% | **64.4% ± 12.4** | 76.4% / 40.0% | 0.00% (0.0) | 0.16% / 0.05% / 0.06% | 0.07% (0.8) | 0.647 |
| 11 | 3dspeaker-eres2net-en-voxceleb | raw | 98.9% | **60.6% ± 1.1** | 75.6% / 56.9% | 0.05% (0.6) | 0.11% / 0.16% / 0.00% | 0.05% (0.6) | 0.717 |

**Clean audio, every model**

Clean enrollment and clean probes, bar tuned on clean probes alone (so clean-only models compare fairly with full ones). `partial` = clean embeddings only so far.

| # | model | coverage | score | rank-1 | **DIR @ 0 wrong** | misID @ 0.1% FA bar | misID @ 1% FA bar | within-dataset DIR @ 0 | 1 clip / 3 clips DIR @ 0 | 2-session enrollment | raw / centered DIR @ 0 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | redimnet-b6-vox2-lm | full | centered | 99.7% | **95.7% ± 0.3** | 0.00% (0.0) | 0.00% (0.0) | 95.9% | 83.0% / 95.2% | 98.2% | 93.5% / 95.7% |
| 2 | redimnet2-b4-vox2-lm-coreml | partial (clean) | centered | 99.7% | **94.0% ± 0.9** | 0.00% (0.0) | 0.00% (0.0) | 94.0% | 80.8% / 94.4% | 97.6% | 92.7% / 94.0% |
| 3 | redimnet2-b4-vox2-lm | full | centered | 99.7% | **94.0% ± 0.9** | 0.00% (0.0) | 0.00% (0.0) | 94.0% | 80.8% / 94.4% | 97.6% | 92.7% / 94.0% |
| 4 | redimnet2-b3-vb2-vox2-cnc2-lm | partial (clean) | centered | 99.6% | **93.1% ± 0.7** | 0.00% (0.0) | 0.00% (0.0) | 93.3% | 86.1% / 93.5% | 97.6% | 90.7% / 93.1% |
| 5 | redimnet2-b6-vox2-lm-coreml | partial (clean) | centered | 99.7% | **92.3% ± 0.7** | 0.00% (0.0) | 0.00% (0.0) | 92.3% | 82.4% / 90.8% | 98.0% | 92.0% / 92.3% |
| 6 | redimnet2-b6-vox2-lm | full | centered | 99.7% | **92.3% ± 0.7** | 0.00% (0.0) | 0.00% (0.0) | 92.3% | 82.4% / 90.8% | 98.0% | 92.0% / 92.3% |
| 7 | wespeaker-resnet293-lm-coreml | full | centered | 99.6% | **91.4% ± 1.2** | 0.00% (0.0) | 0.00% (0.0) | 92.1% | 60.5% / 90.2% | 96.7% | 89.7% / 91.4% |
| 8 | redimnet-b2-vox2-lm | partial (clean) | centered | 99.7% | **89.4% ± 1.5** | 0.00% (0.0) | 0.00% (0.0) | 89.4% | 77.9% / 89.3% | 96.0% | 88.1% / 89.4% |
| 9 | wespeaker-resnet221-lm-coreml | full | centered | 99.7% | **88.8% ± 1.1** | 0.00% (0.0) | 0.00% (0.0) | 88.8% | 72.8% / 89.9% | 96.7% | 87.7% / 88.8% |
| 10 | wespeaker-campplus-lm | full | centered | 99.4% | **87.6% ± 4.3** | 0.00% (0.0) | 0.00% (0.0) | 91.0% | 73.8% / 90.1% | 92.7% | 83.8% / 87.6% |
| 11 | redimnet-M-vb2-vox2-cnc-ft_mix | partial (clean) | centered | 99.7% | **87.3% ± 1.1** | 0.00% (0.0) | 0.00% (0.0) | 87.3% | 81.9% / 88.2% | 95.1% | 83.6% / 87.3% |
| 12 | redimnet2-b2-vox2-lm | partial (clean) | centered | 99.6% | **87.1% ± 6.6** | 0.00% (0.0) | 0.02% (0.2) | 93.1% | 80.3% / 90.8% | 94.0% | 82.1% / 87.1% |
| 13 | **app-wespeaker-coreml** (baseline) | full | centered | 99.5% | **86.7% ± 2.2** | 0.00% (0.0) | 0.02% (0.2) | 88.1% | 72.7% / 86.6% | 92.8% | 83.8% / 86.7% |
| 14 | wespeaker-resnet34-lm | full | centered | 99.5% | **86.7% ± 2.2** | 0.00% (0.0) | 0.00% (0.0) | 88.6% | 62.0% / 86.2% | 93.4% | 84.2% / 86.7% |
| 15 | wespeaker-campplus | partial (clean) | centered | 99.6% | **85.5% ± 7.3** | 0.00% (0.0) | 0.05% (0.6) | 91.1% | 73.6% / 87.2% | 90.4% | 81.7% / 85.5% |
| 16 | wespeaker-resnet34 | partial (clean) | centered | 99.5% | **84.8% ± 2.7** | 0.00% (0.0) | 0.00% (0.0) | 86.0% | 66.7% / 83.4% | 92.0% | 81.5% / 84.8% |
| 17 | 3dspeaker-campplus-en-voxceleb | partial (clean) | centered | 99.4% | **83.8% ± 2.6** | 0.00% (0.0) | 0.00% (0.0) | 85.1% | 67.8% / 84.5% | 91.8% | 81.0% / 83.8% |
| 18 | 3dspeaker-eres2net-en-voxceleb | full | centered | 99.3% | **83.5% ± 2.8** | 0.02% (0.2) | 0.05% (0.6) | 88.6% | 40.6% / 83.9% | 91.8% | 79.7% / 83.5% |
| 19 | 3dspeaker-campplus-zh-en-common-advanced | full | raw | 99.0% | **81.7% ± 1.7** | 0.00% (0.0) | 0.02% (0.2) | 83.6% | 69.1% / 82.1% | 88.8% | 81.7% / 78.5% |
| 20 | titanet-large | full | centered | 99.2% | **77.5% ± 8.5** | 0.00% (0.0) | 0.00% (0.0) | 77.5% | 63.0% / 74.3% | 91.0% | 75.4% / 77.5% |
| 21 | titanet-small | partial (clean) | centered | 98.9% | **76.3% ± 6.0** | 0.00% (0.0) | 0.08% (1.0) | 76.4% | 54.6% / 70.3% | 86.6% | 68.6% / 76.3% |
| 22 | speakernet | partial (clean) | centered | 96.7% | **65.4% ± 4.3** | 0.00% (0.0) | 0.16% (2.0) | 66.5% | 35.3% / 60.7% | 70.5% | 61.4% / 65.4% |
| 23 | 3dspeaker-campplus-zh-cn-common | partial (clean) | centered | 91.5% | **52.1% ± 3.1** | 0.03% (0.4) | 0.24% (3.0) | 55.2% | 30.0% / 45.9% | 56.1% | 42.9% / 52.1% |
| 24 | speechbrain-xvector-vox | partial (clean) | raw | 83.9% | **34.5% ± 3.7** | 0.07% (0.8) | 0.31% (3.8) | 37.3% | 11.1% / 28.9% | 42.8% | 34.5% / 32.2% |

The variants (yodas strangers, opus12 enrollment, 2-session enrollment, one clip vs three), per-dataset numbers, and who gets confused with whom are in `results/lineup_summary.md`.

## Score fusion

Generated 2026-09-28T21:18:36 by `scripts/voiceprint/score_fusion.py` v1.0 on top of `score_verify.py` v1.4 (same trial lists, drop lists, embeddings and metric code). Human-labeled sets: vox1o, libri, ami, icsi. TAR, EER and Δ are in % (Δ in percentage points).

Complete pairs only (all four sets, every condition), cross-condition headline, fusion minus the better single model of the pair:

| pair | method | Δ TAR@1e-3 cross | p | Δ EER cross | significant? | Δ TAR@1e-3 vs best single of all candidates |
|---|---|---|---|---|---|---|
| redimnet2-b6-vox2-lm + app-wespeaker-coreml | concat | -0.2 [-1.1, +1.6] | 0.782 | +0.03 [-0.07, +0.11] | no | -0.2 [-1.1, +1.6] vs `redimnet2-b6-vox2-lm` |
| redimnet2-b6-vox2-lm + app-wespeaker-coreml | zavg | -0.3 [-1.3, +1.5] | 0.898 | +0.04 [-0.06, +0.13] | no | -0.3 [-1.3, +1.5] vs `redimnet2-b6-vox2-lm` |
| redimnet2-b6-vox2-lm + app-wespeaker-coreml | ztuned | +1.0* [+0.3, +2.0] | 0.012 | -0.12* [-0.18, -0.07] | yes (TAR and EER) | +1.0* [+0.3, +2.0] vs `redimnet2-b6-vox2-lm` |
| redimnet2-b4-vox2-lm + app-wespeaker-coreml | concat | +0.2 [-0.7, +2.0] | 0.335 | -0.10* [-0.21, -0.02] | no | -1.5 [-2.8, +0.4] vs `redimnet2-b6-vox2-lm` |
| redimnet2-b4-vox2-lm + app-wespeaker-coreml | zavg | +0.1 [-0.8, +2.0] | 0.455 | -0.08* [-0.19, -0.01] | no | -1.6 [-2.9, +0.3] vs `redimnet2-b6-vox2-lm` |
| redimnet2-b4-vox2-lm + app-wespeaker-coreml | ztuned | +1.0* [+0.4, +2.1] | 0.004 | -0.18* [-0.25, -0.13] | yes (TAR and EER) | -0.7 [-2.4, +1.0] vs `redimnet2-b6-vox2-lm` |
| redimnet2-b6-vox2-lm + wespeaker-resnet221-lm-coreml | concat | +1.0* [+0.3, +3.0] | 0.020 | -0.21* [-0.30, -0.12] | yes (TAR and EER) | +1.0* [+0.3, +3.0] vs `redimnet2-b6-vox2-lm` |
| redimnet2-b6-vox2-lm + wespeaker-resnet221-lm-coreml | zavg | +0.8* [+0.2, +2.9] | 0.044 | -0.19* [-0.29, -0.10] | yes (TAR and EER) | +0.8* [+0.2, +2.9] vs `redimnet2-b6-vox2-lm` |
| redimnet2-b6-vox2-lm + wespeaker-resnet221-lm-coreml | ztuned | +1.7* [+0.9, +2.8] | 0.004 | -0.23* [-0.29, -0.17] | yes (TAR and EER) | +1.7* [+0.9, +2.8] vs `redimnet2-b6-vox2-lm` |
| redimnet2-b4-vox2-lm + wespeaker-resnet221-lm-coreml | concat | +1.9* [+1.1, +4.0] | 0.004 | -0.36* [-0.47, -0.28] | yes (TAR and EER) | +0.2 [-1.0, +2.2] vs `redimnet2-b6-vox2-lm` |
| redimnet2-b4-vox2-lm + wespeaker-resnet221-lm-coreml | zavg | +1.8* [+1.0, +4.0] | 0.004 | -0.35* [-0.46, -0.26] | yes (TAR and EER) | +0.1 [-1.2, +2.0] vs `redimnet2-b6-vox2-lm` |
| redimnet2-b4-vox2-lm + wespeaker-resnet221-lm-coreml | ztuned | +1.9* [+1.5, +3.8] | 0.004 | -0.36* [-0.46, -0.29] | yes (TAR and EER) | +0.2 [-1.1, +2.3] vs `redimnet2-b6-vox2-lm` |

- Significant gains over the better single model of the pair: 8 of 12 comparisons. Largest: redimnet2-b4-vox2-lm + wespeaker-resnet221-lm-coreml, concat, +1.9* [+1.1, +4.0] TAR@1e-3 and -0.36* [-0.47, -0.28] EER (pp).
- Against the best single model on offer (the practical alternative), 4 of 12 clear a 95% CI: redimnet2-b6-vox2-lm + app-wespeaker-coreml (ztuned) +1.0* [+0.3, +2.0] vs `redimnet2-b6-vox2-lm`; redimnet2-b6-vox2-lm + wespeaker-resnet221-lm-coreml (concat) +1.0* [+0.3, +3.0] vs `redimnet2-b6-vox2-lm`; redimnet2-b6-vox2-lm + wespeaker-resnet221-lm-coreml (zavg) +0.8* [+0.2, +2.9] vs `redimnet2-b6-vox2-lm`; redimnet2-b6-vox2-lm + wespeaker-resnet221-lm-coreml (ztuned) +1.7* [+0.9, +2.8] vs `redimnet2-b6-vox2-lm`.
- `concat` (no fitted numbers, one vector per person, the simplest app version) is significant in 2 of 4 pairs; `ztuned` in 4 of 4.

12 fusion-versus-single comparisons are listed; with that many, expect about 0.6 to clear a 95% CI by chance, so a lone marginal star is not evidence.

Full tables (by condition, per set, weight sweep, method notes) are in the fusion summary file under `results/`.

## Latency

#### Voiceprint latency: what each finalist costs after a meeting

Generated 2026-09-28 21:57 by `scripts/voiceprint/bench_latency.py` (8 interleaved rounds). Raw data: `latency_raw.jsonl`, `latency_cold.jsonl`, `latency_plans.json`, `latency_turns.json` in this folder.

After a call, Nemotron splits the audio into speaker turns and every turn gets one voiceprint. A turn longer than 10 s is cut into windows (up to 10 s, a new window every 5 s), each window is embedded, and the vectors are averaged. So the cost is windows per hour times time per window. Everything below runs Core ML with compute units ALL on an M5 Max.

**The Mac was heavily loaded the whole time** (load average 156 to 468 on 18 cores, because other agents were embedding datasets). Raw milliseconds are noisy and, for anything that touches the CPU, inflated. Each round times every model once, one at a time, with the baseline in the same round, and the ratio is taken inside the round; those ratios are the trustworthy part. The rounds are split into calm and contended by how the baseline behaved (see the answer below), and "fastest 10%" (p10) is what a call costs when nothing else is competing.

#### Answer: extra seconds after a meeting, vs the app's current model

8 rounds were run. 4 were calm (the baseline, which does identical work every call, ran at 12 to 14 ms per call) and 4 were contended (25 to 115 ms per call; the CPU-only FBank stage stalls). The headline uses the calm rounds; the busy-Mac column uses all of them.

| model | extra, 30-min meeting | extra, 60-min meeting | range over calm rounds (60 min) | busy Mac, 60 min (all rounds, mean of raw calls) | its total voiceprint time, 60 min (calm) | cost vs baseline (calm) |
|---|---|---|---|---|---|---|
| **app-wespeaker-coreml** (baseline) | 0 | 0 | - | 0 | 12 s | 1.00x |
| **wespeaker-resnet293-lm** | +2.0 s | +4.1 s | +2.7 to +5.3 s | -22 s | 16 s | 1.34x |
| **wespeaker-resnet221-lm** | +0.7 s | +1.4 s | -0.1 to +2.4 s | -26 s | 14 s | 1.12x |
| **redimnet2-b6-vox2-lm** | +1.9 s | +3.9 s | +2.1 to +5.4 s | -17 s | 16 s | 1.33x |
| **redimnet2-b4-vox2-lm** | -0.9 s | -1.8 s | -3.1 to +1.1 s | -23 s | 11 s | 0.86x |

How this is priced: every window of the real turn mix (942 turns and 970 windows per hour, hop 5 s) is charged the time its model takes for a window of that length (the fused models take the length rounded up to one they accept; the baseline embeds 960 fixed 10 s pieces per hour whatever the turn length), plus, for the wespeaker builds, the measured cost of the input length changing from call to call. "Extra" is the model's time minus the baseline's time **in the same round**, median over rounds. Negative means faster than today. The calm columns are median-call costs on the calm rounds; the busy-Mac column is the plain mean of 300 raw calls in arrival order, stalls included, over all rounds. Both leave out load time, which is larger than any of the per-window differences (section 4).

Why two views: the baseline's FBank stage runs on the CPU only, and while the Mac is busy about one call in five stalls for 100 ms or more; the ANE and GPU models stay close to their median. On a quiet Mac the models are within a few seconds of each other per hour of meeting (the calm columns). On a Mac that is busy while the meeting is processed, the baseline's mean cost per window is 43 ms (mean of raw calls over all rounds) and the challengers' are 19 ms (wespeaker-resnet293-lm), 16 ms (wespeaker-resnet221-lm), 26 ms (redimnet2-b6-vox2-lm), 21 ms (redimnet2-b4-vox2-lm).

#### At a glance

Warm latency per window, calm rounds, ms at 2 / 4 / 8 / 10 s (the baseline is one fixed 10 s call for every length).

| model | ms per window at 2 / 4 / 8 / 10 s | extra, 30 min | extra, 60 min | warm load | first-ever load | memory growth (peak) | size on disk | runs on |
|---|---|---|---|---|---|---|---|---|
| **app-wespeaker-coreml** | 14 / 11 / 13 / 13 | 0 | 0 | 0.7 s | 1 s | +172 MB | 15 MB | GPU for the embedding net (124 of 124 ops), CPU for FBank |
| **wespeaker-resnet293-lm** | 10 / 20 / 41 / 53 | +2.0 s | +4.1 s | 24.8 s | 61 s | +154 MB | 59 MB | Neural Engine (493 of 522 ops, 29 on CPU) |
| **wespeaker-resnet221-lm** | 8 / 15 / 31 / 41 | +0.7 s | +1.4 s | 21.9 s | 35 s | +163 MB | 49 MB | Neural Engine (373 of 402 ops, 29 on CPU) |
| **redimnet2-b6-vox2-lm** | 10 / 23 / 40 / 44 | +1.9 s | +3.9 s | 4.2 s (39 s for all lengths) | 14 s (139 s all lengths) | +2347 MB | 55 MB | GPU (704 of 704 ops) |
| **redimnet2-b4-vox2-lm** | 8 / 15 / 21 / 25 | -0.9 s | -1.8 s | 4.0 s (34 s for all lengths) | 15 s (131 s all lengths) | +1684 MB | 32 MB | GPU (677 of 677 ops) |

#### Takeaways

- **app-wespeaker-coreml** (today): 12 s of voiceprint time per 60-minute meeting, loads in under a second, +172 MB, GPU for the embedding net (124 of 124 ops), CPU for FBank. Under CPU load its FBank stage stalls, so it is the model most sensitive to a busy Mac.
- **wespeaker-resnet293-lm**: +4.1 s per 60-minute meeting (+2.0 s per 30-minute) at the median call; 25 s warm load, 62 s first-ever; +154 MB; 53 ms for a full 10 s window; Neural Engine (493 of 522 ops, 29 on CPU).
- **wespeaker-resnet221-lm**: +1.4 s per 60-minute meeting (+0.7 s per 30-minute) at the median call; 22 s warm load, 36 s first-ever; +163 MB; 41 ms for a full 10 s window; Neural Engine (373 of 402 ops, 29 on CPU).
- **redimnet2-b6-vox2-lm**: +3.9 s per 60-minute meeting (+1.9 s per 30-minute) at the median call; 4 s warm load (39 s to have every length ready), 139 s first-ever with every length; +2347 MB; 44 ms for a full 10 s window; GPU (704 of 704 ops).
- **redimnet2-b4-vox2-lm**: -1.8 s per 60-minute meeting (-0.9 s per 30-minute) at the median call; 4 s warm load (34 s to have every length ready), 131 s first-ever with every length; +1684 MB; 25 ms for a full 10 s window; GPU (677 of 677 ops).

#### 1. Turns and windows per hour

The primary source is the speaker lab's real Nemotron output (45 synthetic YODAS3 meetings, 12 to 44 min each, 21 hours), with the app's turn rules re-applied (same-speaker gaps under 0.29 s joined, turns under 0.25 s dropped). The app embeds every turn of 0.25 s or more, including the short ones. AMI and ICSI (human labels, real meetings) are a cross-check.

| source | meetings | hours | turns / hour | windows / hour (hop 5 s) | fixed 10 s pieces / hour (app today) | median turn | p90 turn | turns > 10 s |
|---|---|---|---|---|---|---|---|---|
| nemotron-lab p3-A | 15 | 7.08 | 643 | 656 | 652 | 1.49 s | 4.6 s | 1.1% |
| nemotron-lab p3-B | 12 | 4.67 | 955 | 995 | 980 | 1.61 s | 5.39 s | 2.5% |
| nemotron-lab p3-C | 10 | 5.42 | 1168 | 1181 | 1178 | 1.58 s | 4.66 s | 0.8% |
| nemotron-lab p3-E | 8 | 4.19 | 1143 | 1200 | 1177 | 1.49 s | 5.09 s | 2.2% |
| nemotron-lab pooled | 45 | 21.35 | 942 | 970 | 960 | 1.54 s | 4.91 s | 1.6% |
| ami (human labels) | 96 | 50.49 | 806 | 1008 | 926 | 1.67 s | 10.38 s | 10.5% |
| icsi (human labels) | 75 | 71.69 | 1421 | 1528 | 1487 | 1.7 s | 6.46 s | 3.7% |

Turns are short: 35% are under 1 s and only 1.6% run past 10 s, so almost every turn is one window and the 5 s hop adds only 3% more windows than turns. The lab pool (942 turns/h) sits between AMI (806) and ICSI (1421, seven-person research meetings, overlap not resolved so it is an upper bound); the family rows show how much the count moves with the number of speakers (A is 1 to 3 speakers, C is 5 to 8).

For scale: the lab's whole post-call step (transcription, naming, everything) took a median 35.5 s for a median 29.3-minute call (1.18 s per meeting minute, 45 meetings).

#### 2. Time per window

Warm latency of one model call, median of 50 calls after 10 warm-ups at each length, per round; the cell is the median over the 4 calm rounds, with the fastest-10% value (p10) in brackets. The baseline always runs one fixed 10 s window (FBank on CPU, then the embedding net), so a 2 s turn costs what a 10 s turn does. The fused models take the audio at its own length, rounded up to a length they accept.

_(cut here; the rest is in the file)_

![Accuracy against latency](../../data/eval/voiceprint/results/report/accuracy_vs_latency.png)

Core ML builds converted so far (fused front end, raw audio in). Parity is the worst cosine against the reference runtime on 60 clips.

| build | precision | shapes | worst parity (all units / CPU) | ms per 4 s clip (all units / CPU) | runs on | size MB |
| --- | --- | --- | --- | --- | --- | --- |
| `3dspeaker-campplus-zh-en-common-advanced-coreml` | fp16 | multifunction | 0.999616 / 0.999836 | 75.0 / 13.1 | ane | 20.6 |
| `redimnet2-b4-vox2-lm-coreml` | fp32 | multifunction | 1.0 / 1.0 | 16.6 / 400.4 | gpu | 31.4 |
| `redimnet2-b6-vox2-lm-coreml` | fp32 | multifunction | 1.0 / 1.0 | 69.5 / 1298.7 | gpu | 54.6 |
| `titanet-large-coreml` | fp32 | multifunction | 1.0 / 1.0 | 3.7 / 169.3 | gpu | 90.2 |
| `wespeaker-resnet221-lm-coreml` | fp16 | enumerated | 0.999934 / 0.999904 | 14.6 / 249.8 | ane | 48.8 |
| `wespeaker-resnet293-lm-coreml` | fp16 | enumerated | 0.999947 / 0.999877 | 20.5 / 392.2 | ane | 58.5 |

Those ms numbers were taken on a machine running other jobs. Use them for order of magnitude only.

## End to end

#### Voiceprint end to end: real pipeline, Nemotron diarization, shipped cleanup and naming

#### Takeaways

- **Wrong silent names: 0 for every voiceprint**, out of 175 to 190 names given silently per config (129 meetings per config: the six main sets, the no-invite run of p2-X, and the sound-alike company p1-Fhard-1). Wrong suggestions ("Was this X?" with the wrong X): also 0. Across all pairs of different people in the three companies, the highest session-voiceprint cosine any model saw is 0.42 to 0.68, against invitee bars of 0.80 to 0.82.
- **Separation does not change.** Rows, fragments, blends, missed people and words right are identical to today's model in all 87 meetings of the six main sets for ReDimNet2 b4 and b6, and for ResNet293 in all but one (C-3308 of p3-C, words right 86.5% to 86.4%). The voiceprint only picks the fold target, and the fold rarely changes with the model.
- **Every model names every regular silently at the same meeting as today, with three one-meeting slips for b4** (Elena Rossi in p2-X and in p2-X-noinv, 6th time vs 5th; Robert Chen in p2-X-noinv, 5th vs 4th). It happens at the 3rd to 4th time we hear a person (p2-X worst case 6th). The simulator caps at that point, so the differences below are second order: fewer typed names and confirmations, and more later meetings named silently.
- **ReDimNet2 is a little better on naming work; ResNet293 is not.** Total naming work over the four company runs (F, X, X-noinv, Fhard): today 278, b4 263 (-5%), b6 253 (-9%), ResNet293 282 (+1%). Voices named silently: 178, 184, 190, 175. The clearest gap is the sound-alike company: work 82 today, 68 for b4 and b6 (-17%), 78 for ResNet293; silent names 48 today, 57 for b4 and b6.
- **Why:** on call-quality voices the weak end of same-person scores is much higher for ReDimNet2 (5th percentile of same-person scores 0.57 to 0.71 across F, X and Fhard vs 0.47 to 0.56 today, while the bars moved up by only 0.015 to 0.03), and lower for ResNet293 (0.33 to 0.43). ResNet293's bars are still clean-audio-only calibrations.
- **Speed:** on a quiet Mac, a 25-minute 7-speaker call takes 9.2 s of pipeline today, 9.2 s with b4 (1.00x), 10.7 s with b6 (1.17x), 11.7 s with ResNet293 (1.28x).
- **Pick:** b6 is best on naming (-9%, most silent names); b4 costs no speed and gets most of the gain (-5% total, same -17% on sound-alikes). This is one deterministic run per config on simulated calls with no error bars, so treat +-10 rows as noise; the safe reading is "no worse than today on any measure, faster to name people with ReDimNet2, wrong names 0".

Config for every row: `--backend nemotron --sep-fold 5 --sep-cap one --calendar-naming`. Only the voiceprint (embedder plus its calibrated thresholds) changes. Simulated meetings with answer keys (YODAS3), scored by `scripts/speaker_lab/score.py`.

| voiceprint | wrong silent names | naming work F / X / X-noinv / Fhard | voices named silently F / X / X-noinv / Fhard | regulars named silently F / X / X-noinv / Fhard | first silent at appearance # (median, worst) F / X | rows vs people | exact | words right | missed | speed, quiet Mac (paired test) | done |
|---|---|---|---|---|---|---|---|---|---|---|---|
| today (WeSpeaker ResNet34-LM, FluidAudio) | 0 | 66 / 67 / 63 / 82 | 54 / 36 / 40 / 48 | 7/7 / 6/6 / 6/6 / 7/7 | 3, 4 / 3.5, 6 | 317 vs 329 | 80% | 85.5% | 15 | 9.2 s per 25-min call (1.00x) | all |
| redimnet2-b4-vox2-lm | 0 | 60 / 69 / 66 / 68 | 56 / 34 / 37 / 57 | 7/7 / 6/6 / 6/6 / 7/7 | 3, 4 / 3.5, 6 | 317 vs 329 | 80% | 85.5% | 15 | 9.2 s per 25-min call (1.00x) | all |
| redimnet2-b6-vox2-lm | 0 | 59 / 65 / 61 / 68 | 57 / 36 / 40 / 57 | 7/7 / 6/6 / 6/6 / 7/7 | 3, 4 / 3.5, 6 | 317 vs 329 | 80% | 85.5% | 15 | 10.7 s per 25-min call (1.17x) | all |
| wespeaker-resnet293-lm | 0 | 74 / 67 / 63 / 78 | 50 / 35 / 39 / 51 | 7/7 / 6/6 / 6/6 / 7/7 | 3, 4 / 3.5, 6 | 317 vs 329 | 80% | 85.5% | 15 | 11.7 s per 25-min call (1.28x) | all |

Naming work: typed name 3, pick existing 2, confirm 1, wrong silent name 10, summed over the whole series (F = company p0-F, 24 meetings; X = company p2-X, 18 meetings, cross-recording voices; X-noinv = X with no calendar invite, so the lineup falls back to recently heard people; Fhard = company p1-Fhard-1, 24 meetings, sound-alike voices, bonus set). Lower is better. Regulars = people who appear in at least 4 meetings of the series. Rows / exact / words right / missed / seconds cover the sets every row has finished (p3-A, p3-B, p3-C, p3-E, p0-F, p2-X), one entry per channel and meeting; wrong silent names count every finished run including the no-invite run.

#### Separation, per set

Rows shown vs true people, exact meetings, words under the right person, missed people. Fresh-DB sets (p3-*) only exercise the voiceprint through the fold; F and X also exercise it through cross-meeting matching.

| voiceprint | p3-A | p3-B | p3-C | p3-E | p0-F | p2-X |
|---|---|---|---|---|---|---|
| today (WeSpeaker ResNet34-LM, FluidAudio) | 15/15 rows, 100% exact, 91.4% words, 0 missed | 42/42 rows, 100% exact, 85.0% words, 0 missed | 66/68 rows, 80% exact, 82.8% words, 2 missed | 39/38 rows, 62% exact, 83.7% words, 1 missed | 89/93 rows, 83% exact, 83.8% words, 4 missed | 66/73 rows, 56% exact, 85.6% words, 8 missed |
| redimnet2-b4-vox2-lm | 15/15 rows, 100% exact, 91.4% words, 0 missed | 42/42 rows, 100% exact, 85.0% words, 0 missed | 66/68 rows, 80% exact, 82.8% words, 2 missed | 39/38 rows, 62% exact, 83.7% words, 1 missed | 89/93 rows, 83% exact, 83.8% words, 4 missed | 66/73 rows, 56% exact, 85.6% words, 8 missed |
| redimnet2-b6-vox2-lm | 15/15 rows, 100% exact, 91.4% words, 0 missed | 42/42 rows, 100% exact, 85.0% words, 0 missed | 66/68 rows, 80% exact, 82.8% words, 2 missed | 39/38 rows, 62% exact, 83.7% words, 1 missed | 89/93 rows, 83% exact, 83.8% words, 4 missed | 66/73 rows, 56% exact, 85.6% words, 8 missed |
| wespeaker-resnet293-lm | 15/15 rows, 100% exact, 91.4% words, 0 missed | 42/42 rows, 100% exact, 85.0% words, 0 missed | 66/68 rows, 80% exact, 82.8% words, 2 missed | 39/38 rows, 62% exact, 83.7% words, 1 missed | 89/93 rows, 83% exact, 83.8% words, 4 missed | 66/73 rows, 56% exact, 85.6% words, 8 missed |

#### Regulars: appearance # of the first silent name (nth meeting with that person)

**p0-F**

| voiceprint | Priya Nair | Robert Chen | Sam Lee | Sam Patel | Kwame Mensah | Elena Rossi | Grace Kim | wrong suggestions |
|---|---|---|---|---|---|---|---|---|
| today (WeSpeaker ResNet34-LM, FluidAudio) | 3 | 4 | 3 | 3 | 3 | 4 | 3 | 0 |
| redimnet2-b4-vox2-lm | 3 | 4 | 3 | 3 | 3 | 4 | 3 | 0 |
| redimnet2-b6-vox2-lm | 3 | 4 | 3 | 3 | 3 | 4 | 3 | 0 |
| wespeaker-resnet293-lm | 3 | 4 | 3 | 3 | 3 | 4 | 3 | 0 |

**p2-X**

| voiceprint | Priya Nair | Sam Lee | Kwame Mensah | Robert Chen | Elena Rossi | Sam Patel | wrong suggestions |
|---|---|---|---|---|---|---|---|
| today (WeSpeaker ResNet34-LM, FluidAudio) | 3 | 3 | 3 | 6 | 5 | 4 | 0 |
| redimnet2-b4-vox2-lm | 3 | 3 | 3 | 6 | 6 | 4 | 0 |
| redimnet2-b6-vox2-lm | 3 | 3 | 3 | 6 | 5 | 4 | 0 |
| wespeaker-resnet293-lm | 3 | 3 | 3 | 6 | 5 | 4 | 0 |

**p2-X no invite**

| voiceprint | Priya Nair | Sam Lee | Kwame Mensah | Robert Chen | Elena Rossi | Sam Patel | wrong suggestions |
|---|---|---|---|---|---|---|---|
| today (WeSpeaker ResNet34-LM, FluidAudio) | 3 | 3 | 3 | 4 | 5 | 4 | 0 |
| redimnet2-b4-vox2-lm | 3 | 3 | 3 | 5 | 6 | 4 | 0 |
| redimnet2-b6-vox2-lm | 3 | 3 | 3 | 4 | 5 | 4 | 0 |
| wespeaker-resnet293-lm | 3 | 3 | 3 | 4 | 5 | 4 | 0 |

**p1-Fhard-1 (sound-alikes)**

_(cut here; the rest is in the file)_

## What didn't work

**The WeSpeaker front end.** Our first WeSpeaker numbers were wrong, and it was our harness, not the model. sherpa-onnx runs the WeSpeaker ONNX files with a different front end than the one they were trained with: no per-clip mean normalization, a povey window, mel up to 7,600 Hz. We caught it when we compared against the app's own Core ML model: the network gives cosine 1.0000 when both sides get the same features, but only 0.467 on average when each computes its own. Through sherpa, different people looked far too alike (mean different-speaker cosine 0.37 vs 0.14 with the right front end on the same AMI clips), and cross-session EER on 130 four-second clips was 11.98% vs 0.05%. Every WeSpeaker-family model now runs through `wespeaker_onnx` with WeSpeaker's own front end. The 3D-Speaker and NeMo ONNX files still go through sherpa-onnx's front end, and we have not audited theirs.

**Scoring today's model the app's way took care.** The app embeds a 10-second window around a turn, not a bare clip. A short clip at the start of a zero-padded window shifts the mean the front end subtracts, and every short clip tilts the same way (2 s AMI EER 33% padded vs 2.1% when the clip fills the window). The baseline is scored the tiled way, which matches the app's real meeting path.

**yodas is biased, so it doesn't rank.** Its labels came from TitaNet-large and CAM++ agreeing, and every clip was re-checked against those two, so scores there flatter them: `3dspeaker-campplus-zh-en-common-advanced` gets 0.49x the EER its human-set standing predicts and 0.29x the misses at FAR 1e-3; `redimnet2-b3-vb2-vox2-cnc2-lm` gets a similar lift without labeling anything, most likely because it was trained on YouTube too. Under 1.0x below means yodas flatters that model. We report yodas on its own and leave it out of every ranking.

| model | labeler? | yodas EER (%) | EER vs. what human sets predict | misses at 1e-3 vs. prediction |
|---|---|---|---|---|
| `redimnet2-b3-vb2-vox2-cnc2-lm` | no | 0.28 | 0.34x | 0.36x |
| `3dspeaker-campplus-zh-en-common-advanced` | yes | 0.70 | 0.49x | 0.29x |
| `3dspeaker-campplus-zh-cn-common` | no | 2.63 | 0.79x | 1.08x |
| `redimnet2-b2-vox2-lm` | no | 0.94 | 0.85x | 1.06x |
| `titanet-large` | yes | 1.18 | 0.89x | 0.68x |
| `wespeaker-resnet34` | no | 1.08 | 0.99x | 0.76x |
| `3dspeaker-eres2net-en-voxceleb` | no | 1.31 | 1.01x | 1.06x |
| `redimnet2-b6-vox2-lm` | no | 0.90 | 1.12x | 1.10x |
| `speakernet` | no | 3.62 | 1.23x | 1.16x |
| `app-wespeaker-coreml` | no | 1.50 | 1.30x | 0.94x |

**The most accurate models can't ship.** We ran them anyway as a reference for how much headroom exists, never as candidates. `redimnet2-b3-vb2-vox2-cnc2-lm` (93.9% clean): VoxBlink2 and CN-Celeb in training data; the MIT label on the repo (and on third-party mirrors) does not clear the dataset's non-commercial terms; `redimnet-M-vb2-vox2-cnc-ft_mix` (92.0% clean): VoxBlink2 (non-commercial models) and CN-Celeb (no commercial usage) in training data; repo MIT does not override dataset terms.

Also blocked and not scored (yet): `ecapa2`, `redimnet2-b6-vb2-vox2-cnc2-lm`. ECAPA2 is CC BY-NC; anything trained on VoxBlink2 or CN-Celeb is out whatever the repo's MIT label says.

**Weak models.** `speechbrain-xvector-vox` (44.5% clean; VoxCeleb1 + VoxCeleb2 training data), `3dspeaker-campplus-zh-cn-common` (47.4% clean; 3D-Speaker "common" set (~200k speakers)), `speakernet` (61.8% clean; NeMo speaker-verification recipe: VoxCeleb1+2…). That's 27 to 44 points below today's model on the same measure. Older designs and models trained for other languages don't earn a spot.

**fp16 Core ML.** Half precision broke some networks on CPU (worst parity `titanet-large-coreml` 0.61), so those builds are fp32.

## Caveats

- **Not every model is fully scored yet** (12 networks are missing some cells). Their pooled numbers average a different mix of sets and conditions than the complete rows, so compare with the paired Δ, which uses only shared cells.
- **Read speech and meetings, not your users.** The sets are VoxCeleb interviews, audiobooks, and two research-meeting corpora with headset mixes. AMI and ICSI are the closest to the product, and even they're English, scripted or research-group meetings.
- **Call audio is simulated.** Opus, phone and noisy-room copies are deterministic degradations, not recordings of real Zoom calls. The end-to-end stage is where real pipeline audio finally shows up.
- **Labels aren't perfect.** The audit found and dropped the obvious errors by model consensus, but the panel mostly shares VoxCeleb training, so it can share blind spots.
- **yodas has model-made labels** and is kept out of every ranking. It stays as a secondary check.
- **Picking the best of raw, centered and AS-norm per model** flatters every model slightly. The Δ intervals don't include that selection.
- **TAR at FAR 1e-4 is thin.** Even 30,000 different-person pairs allow only 3 false accepts per cell, so 1e-4 numbers are pooled under one threshold and noisy.
- **The naming simulation is a Python mirror of the app, not the app.** It assumes the diarizer is perfect, uses point estimates without intervals, and calibrates each model's bars on half the speakers. Its calibrated bars differ from the bars the app ships (see the note under the naming table).
- **License triage is engineering, not legal advice.** VoxCeleb-trained weights ship with credit; medium-risk items (TitaNet's telephone data, Alibaba's undisclosed 'common' data) need the owner's call.

## How to rerun

From the repo root, with the shared venv (`data/eval/voiceprint/venv`). Each step only redoes what changed.

```bash
VP=data/eval/voiceprint
$VP/venv/bin/python scripts/voiceprint/embed_daemon.py          # embeddings for every model x set x condition
$VP/venv/bin/python scripts/voiceprint/score_verify.py          # pairwise verification -> results/verify_summary.*
$VP/venv/bin/python scripts/voiceprint/naming_sim.py            # naming simulation -> results/naming/, naming_summary.md
$VP/venv/bin/python scripts/voiceprint/naming_sim.py --conds clean --tag clean   # clean-only bars, the like-for-like table
$VP/venv/bin/python scripts/voiceprint/score_lineup.py          # 334-person lineup -> results/lineup_summary.md
$VP/venv/bin/python scripts/voiceprint/score_fusion.py          # does fusing two models help -> results/fusion_summary.md
$VP/venv/bin/python scripts/voiceprint/bench_latency.py run && $VP/venv/bin/python scripts/voiceprint/bench_latency.py report   # -> results/latency.md
$VP/venv/bin/python scripts/voiceprint/build_report.py          # this file, the charts, and report/data.json
```

`build_report.py` reads the files listed in its docstring. It's safe to run at any point: a missing file becomes a pending row, and it never touches the app's real speaker database, prefs or capture library.

Inputs found this run: 17. Missing: none.

### Pending this run

- call-audio verification for 12 networks (3dspeaker-campplus-en-voxceleb, 3dspeaker-campplus-zh-cn-common, 3dspeaker-eres2net-base-200k-zh-cn-common, redimnet-M-vb2-vox2-cnc-ft_mix, redimnet-b2-vox2-lm...)
- naming with call audio for 15 models
