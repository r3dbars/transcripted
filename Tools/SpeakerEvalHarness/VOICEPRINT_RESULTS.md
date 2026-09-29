# Voiceprint bake-off: results

_Generated 2026-09-28 20:22 by `scripts/voiceprint/build_report.py` from `data/eval/voiceprint/results`. Rerun it any time; numbers that haven't landed show as pending. The charts and raw tables live under `data/eval/voiceprint/results/report/` (gitignored with the rest of `data/`)._

> **Not final.** The embedding daemon still had 158 jobs queued at 20:21:52, so some models are missing conditions. Rows say how many cells they have.

## The short version

- We scored **23 voiceprint networks** (25 builds, 21 networks we could legally ship) on 11,399 clips (after the audit drops) of 334 real people in four human-labeled sets, plus a fifth set with model-made labels that we keep out of the ranking.
- Today's model (`app-wespeaker-coreml`) accepts 74.6% [72.3, 77.5] of same-person pairs on call audio at 1 false accept in 1,000.
- **No winner yet.** `redimnet2-b4-vox2-lm` leads so far (+9.0 [+4.7, +11.5]* points vs today's model on the cells it has: 30 of 60) but isn't fully scored.
- Wrong silent names: **0 for all 23 models simulated.** That was the hard gate.
- Still pending: latency benchmark (ms/clip uses rough embed-job timings until then); end-to-end pipeline results; call-audio verification for 18 networks (3dspeaker-campplus-en-voxceleb, 3dspeaker-campplus-zh-cn-common, 3dspeaker-eres2net-base-200k-zh-cn-common, redimnet-M-vb2-vox2-cnc-ft_mix, redimnet-b2-vox2-lm...); full cell coverage for 3 networks (3dspeaker-campplus-zh-en-common-advanced, redimnet2-b4-vox2-lm, wespeaker-resnet34-lm); naming with call audio for 18 models; 158 embedding jobs still queued.

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
| 1 | `app-wespeaker-coreml` **(baseline)** | yes, credit | 6.6 | 88.7 | 74.6 [72.3, 77.5] | ref | 4.25 | 87% / 70% | 53% / 5.1% | 0 | ~16 | 60/60 |
| 2 | `3dspeaker-eres2net-en-voxceleb` | yes, credit | 6.6 | 86.6 | 70.9 [68.5, 74.2] | -3.7 [-5.4, -1.7]* | 4.89 | 80% / 61% | 6.1% / 1.7% | 0 | ~151 | 60/60 |
| 3 | `redimnet2-b4-vox2-lm` | yes, credit | 6.7 | 92.8 | 80.0 [74.8, 84.3] | +9.0 [+4.7, +11.5]* | 3.49 | 94% / 86% | 60% / 1.8% | 0 | ~79 | 30/60 partial |
| 4 | `wespeaker-resnet34-lm` | yes, credit | 6.6 | 89.3 | 74.0 [71.2, 76.6] | +0.7 [-0.5, +1.0] | 4.69 | 84% / 65% | 53% / 7.4% | 0 | ~134 | 48/60 partial |
| 5 | `3dspeaker-campplus-zh-en-common-advanced` | yes (medium risk) | 6.9 | 83.4 | 71.6 [67.6, 75.1] | -0.5 [-3.8, +2.0] | 4.85 | 82% / 70% | 34% / 0% | 0 | ~66 | 24/60 partial |
| 6 | `redimnet2-b3-vb2-vox2-cnc2-lm` | no (reference only) | 4.5 | 93.9 | pending | – | pending | 93% / pending | 71% / pending | 0 | ~82 | 12/60 partial |
| 7 | `redimnet2-b6-vox2-lm` | yes, credit | 12.4 | 93.6 | pending | – | pending | 92% / pending | 52% / pending | 0 | ~162 | 12/60 partial |
| 8 | `redimnet2-b6-vox2-lm-coreml` _(Core ML)_ | yes, credit | 12.4 | 93.6 | pending | – | pending | 92% / pending | 52% / pending | 0 | ~623 | 12/60 partial |
| 9 | `redimnet-b6-vox2-lm` | yes, credit | 15.0 | 92.9 | pending | – | pending | 96% / pending | 39% / pending | 0 | ~151 | 12/60 partial |
| 10 | `redimnet2-b4-vox2-lm-coreml` _(Core ML)_ | yes, credit | 6.7 | 92.8 | pending | – | pending | 94% / pending | 60% / pending | 0 | ~598 | 12/60 partial |
| 11 | `wespeaker-resnet293-lm-coreml` _(Core ML)_ | yes, credit | 28.6 | 92.2 | pending | – | pending | 91% / pending | 52% / pending | 0 | ~89 | 12/60 partial |
| 12 | `redimnet-M-vb2-vox2-cnc-ft_mix` | no (reference only) | 4.8 | 92.0 | pending | – | pending | 87% / pending | 60% / pending | 0 | ~92 | 12/60 partial |
| 13 | `wespeaker-resnet221-lm-coreml` _(Core ML)_ | yes, credit | 23.7 | 92.0 | pending | – | pending | 89% / 73% | 52% / pending | 0 | ~89 | 12/60 partial |
| 14 | `redimnet2-b2-vox2-lm` | yes, credit | 3.7 | 90.2 | pending | – | pending | 87% / pending | 51% / pending | 0 | ~101 | 12/60 partial |
| 15 | `wespeaker-campplus` | yes, credit | 7.2 | 89.6 | pending | – | pending | 85% / pending | 48% / pending | 0 | ~172 | 12/60 partial |
| 16 | `wespeaker-resnet34` | yes, credit | 6.6 | 89.2 | pending | – | pending | 85% / pending | 58% / pending | 0 | ~183 | 12/60 partial |
| 17 | `redimnet-b2-vox2-lm` | yes, credit | 5.1 | 89.0 | pending | – | pending | 89% / pending | 57% / pending | 0 | ~62 | 12/60 partial |
| 18 | `wespeaker-campplus-lm` | yes, credit | 7.2 | 87.4 | pending | – | pending | 88% / 73% | 47% / pending | 0 | ~157 | 12/60 partial |
| 19 | `3dspeaker-campplus-en-voxceleb` | yes, credit | 7.2 | 87.1 | pending | – | pending | 84% / pending | 10% / pending | 0 | ~208 | 12/60 partial |
| 20 | `titanet-large` | yes, credit (medium risk) | 25.3 | 84.7 | pending | – | pending | 77% / pending | 25% / pending | 0 | ~194 | 12/60 partial |
| 21 | `titanet-small` | yes, credit (medium risk) | 10.0 | 80.4 | pending | – | pending | 76% / pending | 23% / pending | 0 | ~75 | 12/60 partial |
| 22 | `3dspeaker-eres2net-base-200k-zh-cn-common` | yes (medium risk) | 9.9 | 64.3 | pending | – | pending | pending | 18% / pending | 0 | ~329 | 9/60 partial |
| 23 | `speakernet` | yes, credit | 5.8 | 61.8 | pending | – | pending | 65% / pending | 13% / pending | 0 | ~51 | 12/60 partial |
| 24 | `3dspeaker-campplus-zh-cn-common` | yes (medium risk) | 6.9 | 47.4 | pending | – | pending | 52% / pending | 7.1% / pending | 0 | ~137 | 12/60 partial |
| 25 | `speechbrain-xvector-vox` | yes, credit | 4.2 | 44.5 | pending | – | pending | 34% / pending | 0.2% / pending | 0 | ~9.6 | 12/60 partial |

**Set up but not scored yet** (no embeddings scored): `3dspeaker-campplus-zh-en-common-advanced-coreml` (yes (medium risk)), `3dspeaker-eres2net-zh-cn-common` (yes (medium risk)), `3dspeaker-eres2netv2-zh-cn-common` (yes (medium risk)), `ecapa2` (no (reference only)), `redimnet2-b6-vb2-vox2-cnc2-lm` (no (reference only)), `speechbrain-ecapa-vox` (yes, credit), `speechbrain-resnet-vox` (yes, credit), `titanet-large-coreml` (yes, credit (medium risk)), `unispeech-sat-base-plus-sv` (unclear), `wavlm-base-plus-sv` (unclear), `wespeaker-resnet152-lm` (yes, credit), `wespeaker-resnet221-lm` (yes, credit), `wespeaker-resnet293-lm` (yes, credit).

### By condition and clip length

TAR at FAR 1e-3 / EER, both in %. The clean>x columns enroll clean and test on the degraded copy; the last three are call audio by clip length.

| model | clean | clean>opus12 | clean>phone | clean>noisy | 2 s | 4 s | 8 s |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `app-wespeaker-coreml` **(baseline)** | 88.7 / 1.77 | 79.0 / 2.94 | pending | 70.2 / 5.56 | 52.8 / 7.27 | 78.2 / 3.81 | 92.8 / 1.67 |
| `3dspeaker-eres2net-en-voxceleb` | 86.6 / 2.05 | 77.6 / 3.05 | pending | 64.3 / 6.73 | 47.3 / 8.21 | 74.8 / 4.43 | 90.7 / 2.04 |
| `redimnet2-b4-vox2-lm` | 92.8 / 1.31 | 82.2 / 2.83 | pending | 76.8 / 5.06 | 58.1 / 6.65 | 84.5 / 2.99 | 97.4 / 0.82 |
| `wespeaker-resnet34-lm` | 89.3 / 1.78 | 79.5 / 3.04 | pending | 68.6 / 6.35 | 51.2 / 7.97 | 77.5 / 4.20 | 93.4 / 1.91 |
| `3dspeaker-campplus-zh-en-common-advanced` | 83.4 / 2.45 | 76.5 / 3.78 | pending | 66.8 / 5.92 | 44.0 / 8.45 | 76.1 / 4.78 | 94.8 / 1.32 |

![Clean vs call-audio accuracy for the top models](../../data/eval/voiceprint/results/report/clean_vs_call.png)

## Winner and runner-up

The rule: a shippable license, every cell scored, zero wrong silent names in the naming simulation. Then the highest call-audio accuracy. We don't crown anyone while a candidate that looks better on the cells it has is still being scored.

**No winner yet.**

### Leading so far (not final, cells missing): `redimnet2-b4-vox2-lm`

- **Call audio:** 80.0% [74.8, 84.3] at 1 in 1,000 false accepts; EER 3.49%. Clean: 92.8% [90.8, 94.3]. Scored on 30 of 60 cells.
- **Against today's model** (74.6% [72.3, 77.5]): +9.0 [+4.7, +11.5]* points, paired on 9 shared call-audio cells. That's clearly better.
- **Naming:** names 60% of a regular's appearances from meeting 3 on (clean bars), median first automatic name at meeting 3; wrong silent names 0; 140 wrong suggestions (1.4%). With call audio in the calibration: 1.8%.
- **Lineup (DIR at zero wrong names):** 94% clean, 86% on opus12 probes.
- **Size and speed:** 6.7M parameters; about 79 ms per clip (rough embed-job timing on a busy machine).
- **Core ML build** (`redimnet2-b4-vox2-lm-coreml`): fp32, worst parity 1.0, 31.4 MB, runs on gpu.
- **License:** MIT weights (repo license, release assets); credit VoxCeleb. (eligible-attribution, low risk). Trained on: VoxCeleb2 dev (vox2), pretrain then large-margin finetune (lm).

### Best fully scored shippable model so far: `3dspeaker-eres2net-en-voxceleb`

- **Call audio:** 70.9% [68.5, 74.2] at 1 in 1,000 false accepts; EER 4.89%. Clean: 86.6% [84.5, 89.0].
- **Against today's model** (74.6% [72.3, 77.5]): -3.7 [-5.4, -1.7]* points, paired on 24 shared call-audio cells. That's not better.
- **Naming:** names 6.1% of a regular's appearances from meeting 3 on (clean bars), median first automatic name at meeting never; wrong silent names 0; 522 wrong suggestions (2.6%). With call audio in the calibration: 1.7%.
- **Lineup (DIR at zero wrong names):** 80% clean, 61% on opus12 probes.
- **Size and speed:** 6.6M parameters; about 151 ms per clip (rough embed-job timing on a busy machine).
- **License:** Apache 2.0 weights; credit VoxCeleb. The repo's June 2026 'research-only' note (scripts/entrypoints/build.sh, build-beta.sh) is not supported by the model card. (eligible-attribution, low risk). Trained on: VoxCeleb (English), 3D-Speaker recipe.

## Naming simulation

This is what a user feels. For each model we replay realistic runs of meetings (AMI and ICSI as they happened, LibriSpeech and VoxCeleb as invented recurring groups), with the app's naming rules mirrored in Python: match against the profiles from before each meeting, name silently only when confirmations, similarity bar and margin all agree, otherwise suggest or ask. A simulated user always knows who is who and corrects mistakes. Bars are calibrated on half the speakers and scored on the other half, both ways.

Work per meeting: type a name 3, pick a known person 2, confirm a suggestion 1, fix a wrong suggestion 3, fix a wrong silent name 10.

| model | ship? | wrong silent names (all runs) | look-alike pairs over bar | strangers wrongly named | wrong suggestions | auto from mtg 3+ (clean bars) | first auto: median / p90 meeting | work per meeting | with call audio: auto from mtg 3+ / wrong / work |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `redimnet2-b3-vb2-vox2-cnc2-lm` | no (reference only) | 0 | 0 / 14,647 | 0 | 60 (0.8%) | 71% | 3 / never | 3.98 | pending |
| `redimnet2-b4-vox2-lm` | yes, credit | 0 | 0 / 24,621 | 0 | 140 (1.4%) | 60% | 3 / never | 4.14 | 1.8% / 0 / 5.46 |
| `redimnet-M-vb2-vox2-cnc-ft_mix` | no (reference only) | 0 | 0 / 14,647 | 0 | 186 (1.8%) | 60% | 3 / never | 4.08 | pending |
| `wespeaker-resnet34` | yes, credit | 0 | 0 / 14,647 | 0 | 220 (2.1%) | 58% | 3 / never | 4.15 | pending |
| `redimnet-b2-vox2-lm` | yes, credit | 0 | 0 / 14,647 | 0 | 224 (2.1%) | 57% | 3 / never | 4.15 | pending |
| `app-wespeaker-coreml` **(baseline)** | yes, credit | 0 | 0 / 43,941 | 0 | 238 (2.1%) | 53% | 4 / never | 4.25 | 5.1% / 0 / 5.29 |
| `wespeaker-resnet34-lm` | yes, credit | 0 | 0 / 43,941 | 0 | 224 (2.0%) | 53% | 4 / never | 4.25 | 7.4% / 0 / 5.18 |
| `wespeaker-resnet293-lm-coreml` _(Core ML)_ | yes, credit | 0 | 0 / 14,647 | 0 | 144 (1.3%) | 52% | 4 / never | 4.25 | pending |
| `redimnet2-b6-vox2-lm` | yes, credit | 0 | 0 / 14,647 | 0 | 128 (1.1%) | 52% | 4 / never | 4.24 | pending |
| `wespeaker-resnet221-lm-coreml` _(Core ML)_ | yes, credit | 0 | 0 / 14,647 | 0 | 162 (1.4%) | 52% | 4 / never | 4.27 | pending |
| `redimnet2-b2-vox2-lm` | yes, credit | 0 | 0 / 14,647 | 0 | 228 (1.9%) | 51% | 4 / never | 4.27 | pending |
| `wespeaker-campplus` | yes, credit | 0 | 0 / 14,647 | 0 | 224 (1.8%) | 48% | 4 / never | 4.32 | pending |
| `wespeaker-campplus-lm` | yes, credit | 0 | 0 / 14,647 | 0 | 226 (1.9%) | 47% | 4 / never | 4.37 | pending |
| `redimnet-b6-vox2-lm` | yes, credit | 0 | 0 / 14,647 | 0 | 146 (1.1%) | 39% | never / never | 4.46 | pending |
| `3dspeaker-campplus-zh-en-common-advanced` | yes (medium risk) | 0 | 0 / 43,941 | 0 | 456 (3.1%) | 34% | never / never | 4.54 | 0% / 0 / 5.25 |
| `titanet-large` | yes, credit (medium risk) | 0 | 0 / 14,647 | 0 | 384 (2.4%) | 25% | never / never | 4.72 | pending |
| `titanet-small` | yes, credit (medium risk) | 0 | 0 / 14,647 | 0 | 622 (3.7%) | 23% | never / never | 4.75 | pending |
| `3dspeaker-eres2net-base-200k-zh-cn-common` | yes (medium risk) | 0 | 0 / 13,887 | 0 | 812 (5.6%) | 18% | never / never | 4.72 | pending |
| `speakernet` | yes, credit | 0 | 0 / 14,647 | 0 | 1168 (6.8%) | 13% | never / never | 5.13 | pending |
| `3dspeaker-campplus-en-voxceleb` | yes, credit | 0 | 0 / 14,647 | 0 | 532 (2.8%) | 10% | never / never | 4.94 | pending |
| `3dspeaker-campplus-zh-cn-common` | yes (medium risk) | 0 | 0 / 14,647 | 0 | 1168 (6.6%) | 7.1% | never / never | 5.26 | pending |
| `3dspeaker-eres2net-en-voxceleb` | yes, credit | 0 | 0 / 43,941 | 0 | 522 (2.6%) | 6.1% | never / never | 4.99 | 1.7% / 0 / 5.31 |
| `speechbrain-xvector-vox` | yes, credit | 0 | 0 / 14,647 | 0 | 1186 (7.1%) | 0.2% | never / never | 5.62 | pending |

For scale, today's model with the app's shipped bars (0.70 / 0.80 / 0.92, no calibration) names 47% of regulars' appearances from meeting 3 on clean audio and 34% on call audio, with 0 wrong silent names. Our calibration (zero wrong names plus a safety margin, same recipe for every model) gives the same model 53% with clean-only bars, and 11% clean / 5.1% call once call audio is in the calibration. Absolute rates move a lot with how strict the bars are, so read the table as models against each other, not against the live app.

Notes on reading it:

- **Clean-only bars** are calibrated on clean audio for every model, so they compare fairly. **With call audio** bars are calibrated on every condition a model has, like the app, which makes them stricter; compare those columns only between models that have the same coverage.
- No confidence intervals here: the simulation is point estimates over many seeded runs (48 per model in the last check), not a bootstrap.
- A model shows a look-alike pair when two different held-out people clear the lineup bar against each other. It over-counts on purpose.

## Lineup (334 people)

Everyone at once: all labeled people share one database and each probe has to pick the right name, or none for a stranger. The number in the model table is **DIR at zero wrong names**: the share of known people shown with the right name at the lowest bar where nobody, known or stranger, gets a wrong name. Higher is better; the table shows clean / opus12 probes, one bar per model.

Generated 2026-09-28 20:18 by `scripts/voiceprint/score_lineup.py`. All 334 people of vox1o, libri, ami and icsi (after the audit drop lists) share one database. Per seed, about 233 are enrolled (their earliest session, all clips) and about 101 are strangers who are never enrolled: every `stranger_only` person plus 20% of each set's multi-session people. Probes are every later session of an enrolled person and every session of a stranger. Numbers are means over 5 seeds (which people are strangers, which clips make the 1- and 3-clip probes).

How to read it. A name is shown when the top match's cosine clears the model's bar. **DIR** = known person, right name shown. **misID** = known person, wrong name shown. **stranger FA** = stranger given someone's name. **DIR @ 0 wrong** = DIR at the lowest bar where nobody (known or stranger) gets a wrong name. **One bar per model** (per talk time): set on clean + opus12 + noisy probes pooled, because the app can't tell a clean room from a weak call; the columns then show each condition at that one bar. `0.1% FA bar` = the bar letting through at most 0.1% of stranger probes; with 1,129 stranger probes per seed over 3 conditions that allows 1 stranger false alarm(s) in the pooled set.

People: 334 human-labeled (43 `stranger_only`), plus 236 yodas `stranger_only` people for the extra-distractor check. Drops applied: vox1o 114, libri 9, ami 344, icsi 3, yodas 0.

**Call audio, models with full coverage (opus12 probes)**

Ranked by the headline: **DIR at zero wrong names on opus12 probes**, clean enrollment (1 session), all clips, pooled lineup, one bar per model. `score` = the scoring that wins the headline for that model (raw cosine or centered cosine).

| # | model | score | rank-1 opus12 | **DIR @ 0 wrong, opus12** | DIR @ 0 wrong clean / noisy | misID @ 0.1% FA bar, opus12 (mean count per seed) | stranger FA @ 0.1% FA bar, clean / opus12 / noisy | misID @ 1% FA bar, opus12 | bar @ 0 wrong |
|---|---|---|---|---|---|---|---|---|---|
| 1 | redimnet2-b4-vox2-lm | centered | 99.5% | **85.8% ± 2.4** | 92.1% / 84.7% | 0.00% (0.0) | 0.00% / 0.00% / 0.27% | 0.00% (0.0) | 0.596 |
| 2 | wespeaker-resnet221-lm-coreml | centered | 99.1% | **73.5% ± 1.4** | 88.8% / 76.0% | 0.00% (0.0) | 0.27% / 0.00% / 0.00% | 0.00% (0.0) | 0.626 |
| 3 | wespeaker-campplus-lm | centered | 99.1% | **73.4% ± 7.2** | 87.4% / 75.8% | 0.00% (0.0) | 0.22% / 0.00% / 0.05% | 0.08% (1.0) | 0.658 |
| 4 | 3dspeaker-campplus-zh-en-common-advanced | raw | 98.3% | **70.2% ± 1.7** | 81.2% / 72.8% | 0.02% (0.2) | 0.21% / 0.00% / 0.06% | 0.05% (0.6) | 0.679 |
| 5 | **app-wespeaker-coreml** (baseline) | centered | 98.9% | **70.2% ± 2.5** | 86.7% / 74.5% | 0.00% (0.0) | 0.27% / 0.00% / 0.00% | 0.02% (0.2) | 0.622 |
| 6 | wespeaker-resnet34-lm | raw | 98.9% | **64.7% ± 6.2** | 84.0% / 71.1% | 0.00% (0.0) | 0.22% / 0.00% / 0.05% | 0.00% (0.0) | 0.659 |
| 7 | 3dspeaker-eres2net-en-voxceleb | raw | 98.9% | **60.6% ± 1.1** | 75.6% / 56.9% | 0.05% (0.6) | 0.11% / 0.16% / 0.00% | 0.05% (0.6) | 0.717 |

**Clean audio, every model**

Clean enrollment and clean probes, bar tuned on clean probes alone (so clean-only models compare fairly with full ones). `partial` = clean embeddings only so far.

| # | model | coverage | score | rank-1 | **DIR @ 0 wrong** | misID @ 0.1% FA bar | misID @ 1% FA bar | within-dataset DIR @ 0 | 1 clip / 3 clips DIR @ 0 | 2-session enrollment | raw / centered DIR @ 0 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | redimnet-b6-vox2-lm | partial (clean) | centered | 99.7% | **95.7% ± 0.3** | 0.00% (0.0) | 0.00% (0.0) | 95.9% | 83.0% / 95.2% | 98.2% | 93.5% / 95.7% |
| 2 | redimnet2-b4-vox2-lm-coreml | partial (clean) | centered | 99.7% | **94.0% ± 0.9** | 0.00% (0.0) | 0.00% (0.0) | 94.0% | 80.8% / 94.4% | 97.6% | 92.7% / 94.0% |
| 3 | redimnet2-b4-vox2-lm | full | centered | 99.7% | **94.0% ± 0.9** | 0.00% (0.0) | 0.00% (0.0) | 94.0% | 80.8% / 94.4% | 97.6% | 92.7% / 94.0% |
| 4 | redimnet2-b3-vb2-vox2-cnc2-lm | partial (clean) | centered | 99.6% | **93.1% ± 0.7** | 0.00% (0.0) | 0.00% (0.0) | 93.3% | 86.1% / 93.5% | 97.6% | 90.7% / 93.1% |
| 5 | redimnet2-b6-vox2-lm-coreml | partial (clean) | centered | 99.7% | **92.3% ± 0.7** | 0.00% (0.0) | 0.00% (0.0) | 92.3% | 82.4% / 90.8% | 98.0% | 92.0% / 92.3% |
| 6 | redimnet2-b6-vox2-lm | partial (clean) | centered | 99.7% | **92.3% ± 0.7** | 0.00% (0.0) | 0.00% (0.0) | 92.3% | 82.4% / 90.8% | 98.0% | 92.0% / 92.3% |
| 7 | wespeaker-resnet293-lm-coreml | partial (clean) | centered | 99.6% | **91.4% ± 1.2** | 0.00% (0.0) | 0.00% (0.0) | 92.1% | 60.5% / 90.2% | 96.7% | 89.7% / 91.4% |
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
| 20 | titanet-large | partial (clean) | centered | 99.2% | **77.5% ± 8.5** | 0.00% (0.0) | 0.00% (0.0) | 77.5% | 63.0% / 74.3% | 91.0% | 75.4% / 77.5% |
| 21 | titanet-small | partial (clean) | centered | 98.9% | **76.3% ± 6.0** | 0.00% (0.0) | 0.08% (1.0) | 76.4% | 54.6% / 70.3% | 86.6% | 68.6% / 76.3% |
| 22 | speakernet | partial (clean) | centered | 96.7% | **65.4% ± 4.3** | 0.00% (0.0) | 0.16% (2.0) | 66.5% | 35.3% / 60.7% | 70.5% | 61.4% / 65.4% |
| 23 | 3dspeaker-campplus-zh-cn-common | partial (clean) | centered | 91.5% | **52.1% ± 3.1** | 0.03% (0.4) | 0.24% (3.0) | 55.2% | 30.0% / 45.9% | 56.1% | 42.9% / 52.1% |
| 24 | speechbrain-xvector-vox | partial (clean) | raw | 83.9% | **34.5% ± 3.7** | 0.07% (0.8) | 0.31% (3.8) | 37.3% | 11.1% / 28.9% | 42.8% | 34.5% / 32.2% |

The variants (yodas strangers, opus12 enrollment, 2-session enrollment, one clip vs three), per-dataset numbers, and who gets confused with whom are in `results/lineup_summary.md`.

## Score fusion

Generated 2026-09-28T20:06:59 by `scripts/voiceprint/score_fusion.py` v1.0 on top of `score_verify.py` v1.4 (same trial lists, drop lists, embeddings and metric code). Human-labeled sets: vox1o, libri, ami, icsi. TAR, EER and Δ are in % (Δ in percentage points).

Complete pairs only (all four sets, every condition), cross-condition headline, fusion minus the better single model of the pair:

| pair | method | Δ TAR@1e-3 cross | p | Δ EER cross | significant? |
|---|---|---|---|---|---|
| redimnet2-b4-vox2-lm + app-wespeaker-coreml | concat | +0.2 [-0.7, +2.0] | 0.358 | -0.10* [-0.21, -0.01] | no |
| redimnet2-b4-vox2-lm + app-wespeaker-coreml | zavg | +0.1 [-0.9, +1.9] | 0.468 | -0.08 [-0.20, +0.01] | no |
| redimnet2-b4-vox2-lm + app-wespeaker-coreml | ztuned | +1.0* [+0.4, +2.1] | 0.010 | -0.18* [-0.25, -0.13] | yes (TAR and EER) |
| redimnet2-b4-vox2-lm + app-wespeaker-coreml | zavg-percond | +0.1 [-0.9, +1.9] | 0.478 | -0.08 [-0.20, +0.01] | no |

4 fusion-versus-single comparisons are listed; with that many, expect about 0.2 to clear a 95% CI by chance, so a lone marginal star is not evidence.

Full tables (by condition, per set, weight sweep, method notes) are in the fusion summary file under `results/`.

## Latency

pending: `results/latency.md` hasn't been written yet. The `ms/clip` column above uses the embedding job's own timings (median per clip on a busy machine, mixed devices), which are only good for spotting order of magnitude.

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

pending: `results/e2e_summary.md` hasn't been written yet (the winner has to be wired into the app first).

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

- **Not every model is fully scored yet** (21 networks are missing some cells). Their pooled numbers average a different mix of sets and conditions than the complete rows, so compare with the paired Δ, which uses only shared cells.
- **Read speech and meetings, not your users.** The sets are VoxCeleb interviews, audiobooks, and two research-meeting corpora with headset mixes. AMI and ICSI are the closest to the product, and even they're English, scripted or research-group meetings.
- **Call audio is simulated.** Opus, phone and noisy-room copies are deterministic degradations, not recordings of real Zoom calls. The end-to-end stage is where real pipeline audio finally shows up.
- **Labels aren't perfect.** The audit found and dropped the obvious errors by model consensus, but the panel mostly shares VoxCeleb training, so it can share blind spots.
- **yodas has model-made labels** and is kept out of every ranking. It stays as a secondary check.
- **Picking the best of raw, centered and AS-norm per model** flatters every model slightly. The Δ intervals don't include that selection.
- **TAR at FAR 1e-4 is thin.** Even 30,000 different-person pairs allow only 3 false accepts per cell, so 1e-4 numbers are pooled under one threshold and noisy.
- **The naming simulation is a Python mirror of the app, not the app.** It assumes the diarizer is perfect, uses point estimates without intervals, and calibrates each model's bars on half the speakers. Its calibrated bars differ from the bars the app ships (see the note under the naming table).
- **License triage is engineering, not legal advice.** VoxCeleb-trained weights ship with credit; medium-risk items (TitaNet's telephone data, Alibaba's undisclosed 'common' data) need the owner's call.
- **Latency numbers here are rough.** They come from the embedding job's timings on a machine running other jobs, across different devices (CPU, MPS, Core ML). Use them for order of magnitude. `latency.md` has the real benchmark once it exists.

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

Inputs found this run: 15. Missing: `latency.md`, `e2e_summary.md`.

### Pending this run

- latency benchmark (ms/clip uses rough embed-job timings until then)
- end-to-end pipeline results
- call-audio verification for 18 networks (3dspeaker-campplus-en-voxceleb, 3dspeaker-campplus-zh-cn-common, 3dspeaker-eres2net-base-200k-zh-cn-common, redimnet-M-vb2-vox2-cnc-ft_mix, redimnet-b2-vox2-lm...)
- full cell coverage for 3 networks (3dspeaker-campplus-zh-en-common-advanced, redimnet2-b4-vox2-lm, wespeaker-resnet34-lm)
- naming with call audio for 18 models
- 158 embedding jobs still queued
