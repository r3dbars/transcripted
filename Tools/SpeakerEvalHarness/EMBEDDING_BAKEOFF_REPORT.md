# Embedding bake-off — the lever is the embedding model, and a better one delivers

**Date:** 2026-06-18 · **Corpus:** AMI scale set, 32 meetings × 4 recurring speakers, 6 codec arms
(clean → Opus 24/16/12/8k → G.711). **Measurement only — no app code changed; no re-diarization.** Each
candidate re-extracted embeddings for the **exact same** dump segments (same diarizer spans, only the
embedding vector differs — a clean controlled comparison) via a throwaway venv (`.venv_emb`, gitignored).

> **Why this experiment.** The prior reports ruled out every tunable downstream knob (match threshold,
> mean-centering, clustering, segmentation) and concluded the within-meeting speaker-merging ceiling is the
> **embedding model** (WeSpeaker ResNet34-LM). This tests that directly: swap in stronger open speaker-embedding
> models and measure whether the floor moves.

> **Validity.** WeSpeaker/`app` reproduces prior numbers exactly; all metrics independently recomputed from the
> dumps by a verifier (`scripts/verify_bakeoff.py`); 0 zero-norm / 0 non-finite across 19k+ segments.

---

## Bottom line

**Yes — a better embedding model breaks the floor.** The shipping WeSpeaker is the bottleneck, and swapping it
for a strong discriminative model (ReDimNet-b6 or ECAPA) recovers more speakers within a meeting, **halves the
error on phone-band audio**, and gives near-perfect cross-call matching — codec-robust, and from *smaller*
models. But "best accuracy" and "best to ship on-device" are **different answers**, and the full user-facing
win is **capped by a separate within-meeting consolidation knob** (`0.88`) that must be loosened next.

**🟢 GREEN** — broad, statistically-robust win (opus8k 30/32 meetings, p=2.5e-7), verified end-to-end through
the real matcher.

---

## Update (2026-06-18): CAM++ benched — the shippable winner is now confirmed

We subsequently ran **CAM++** and **ERes2Net** (Alibaba 3D-Speaker, via modelscope; front-end handled by the
official toolkit, sanity-gated: same-spk cosine 0.90 vs diff 0.10) through the exact same bench. This **closes
the one gap** in the original recommendation — the shippable model now has real in-harness numbers, and they're
top-tier:

| model | dim | clean DER | opus8k DER | g711u DER | cross-call AUC | isotropic? | on-device path |
|---|---|---|---|---|---|---|---|
| WeSpeaker (current) | 256 | 0.319 | 0.480 | 0.432 | 0.95–0.98 | yes | shipping |
| **CAM++** | 512 | **0.274** | **0.301** | **0.294** | **1.0000 (all arms)** | yes | **official ONNX → CoreML (cleanest)** |
| ERes2Net | 192 | **0.238** | 0.329 | 0.274 | 1.0000 | yes | official ONNX → CoreML |
| ReDimNet-b6 | 192 | 0.252 | 0.276 | 0.221 | ~1.0 | yes | **export blocker (ANE-hostile)** |
| ECAPA-TDNN | 192 | 0.267 | 0.307 | 0.281 | ~1.0 | yes | DIY ONNX |

**Revised recommendation: ship CAM++.** It matches ReDimNet/ECAPA on accuracy (DER ~0.27–0.30 flat across all
compression vs WeSpeaker's 0.32→0.48; AUC a perfect 1.0 on every arm; purity 0.84–0.87 — highest tier), is
**isotropic** (clean drop-in, no whitening), is **lighter than today's model**, and has the **cleanest
on-device conversion** (official ONNX → coremltools → ANE). The earlier tension ("ReDimNet most accurate but
unshippable; CAM++ shippable but unmeasured") is **resolved — CAM++ is both.** ERes2Net (192-dim, best clean
DER) is the runner-up; ReDimNet-b6/ECAPA remain strong but are harder to ship.

Full per-arm numbers for all 8 models: **[MASTER_SCORECARD.md](MASTER_SCORECARD.md)**. The original
ReDimNet-focused analysis below still stands; CAM++ simply makes the *shippable* pick a measured one.

> **Negative control held:** x-vector (a deliberately weak model) was worst on every arm (DER ~0.5),
> confirming only genuinely strong models win — this is not "any swap helps."

---

## 1. Accuracy winner: ReDimNet-b6 (192-dim)

Within-meeting oracle-k (so coverage gains are real separation, not over-fragmentation — purity held ≥ 0.83):

| arm | model | coverage | purity | DER |
|---|---|---|---|---|
| clean | WeSpeaker → **ReDimNet-b6** | 0.727 → **0.812** | 0.831 → 0.836 | 0.319 → **0.252** |
| opus8k | WeSpeaker → **ReDimNet-b6** | 0.625 → **0.766** | 0.753 → **0.850** | 0.480 → **0.276** |
| g711u | WeSpeaker → **ReDimNet-b6** | 0.633 → **0.828** | 0.781 → **0.867** | 0.432 → **0.221** |
| opus12k | WeSpeaker → ReDimNet-b6 | 0.664 → 0.695 | 0.798 → 0.796 | 0.375 → 0.313 |

- **Statistically robust, broad win** (paired per-meeting, n=32): opus8k **30/2** meetings (sign-test p=2.5e-7,
  bootstrap ΔDER CI [−0.261, −0.149]); g711u **28/4** (p=1.9e-5); clean 22/10 (CI just clears zero).
- **Cross-call discrimination near-perfect:** AUC ≥ 0.998 every arm; raw cosine separation 0.60–0.72 vs
  WeSpeaker 0.29–0.54. **Isotropic — no whitening needed** (unlike the SSL models, below). 192-dim (smaller
  than the shipping 256-dim).
- **Codec-robust:** DER barely moves clean→g711u (0.25→0.22), where WeSpeaker degrades hard (0.32→0.43).

**Full field** (clean / opus8k AUC · within-cov):
- **ReDimNet-b6** — AUC ~1.0, cov 0.81/0.77 — **best, isotropic, 192-d.**
- **ECAPA-TDNN** — AUC ~1.0, cov 0.80/0.74 — near-tied runner-up, isotropic, 192-d, **best on opus12k.**
- **WavLM-SV / UniSpeech-SAT** (SSL) — AUC ~0.99 but **anisotropic** (raw sep 0.23–0.28; need whitening); cov ~0.71.
- **WeSpeaker (current)** — AUC 0.95–0.98, cov 0.63–0.73 — the baseline being beaten.

**Soft spot (flagged):** ReDimNet dips on **opus12k** (cov 0.812→0.695, ~3 meetings; ΔDER CI grazes zero). It
still beats WeSpeaker there, but **ECAPA is the cleaner opus12k pick** (cov 0.719, DER 0.303, bootstrap-robust,
beats ReDimNet 19/13 head-to-head) — and ECAPA is also more shippable (below).

## 2. End-to-end through the real matcher — it reaches, and the cap is elsewhere

Replaying ReDimNet embeddings through the real clusterer + DB matcher (match threshold swept, since ReDimNet's
cosine scale runs hotter than WeSpeaker's 0.60):

- **It restores granularity WeSpeaker physically cannot reach.** On compressed audio WeSpeaker tops out at
  **10 profiles (opus8k) / 27 (g711u)** at *any* threshold — its low false-merge counts are an artifact of
  collapsing ~32 people into a handful of profiles. ReDimNet reaches **32 (opus8k @0.69) / 33 (g711u @0.63)**.
- **DER improves at every arm's best operating point:** clean 0.44→0.37, opus8k 0.61→0.54, g711u 0.57→0.51.
- **Recommended match threshold ≈ 0.62–0.65** (clean 0.55–0.58; opus8k 0.69; g711u 0.62–0.63). Do **not**
  inherit 0.60 — recalibrate per embedding.
- **Honest cap:** the within-meeting `consolidateSameVoiceClusters@0.88` post-process is now the binding
  constraint, not the embedding. The diarizer recovers only **3.66 (ReDimNet) vs 3.25 (WeSpeaker)** of 4
  speakers/meeting on clean before the matcher runs, so user-facing people-trapped stays 26–30/32 at every
  usable threshold. **Next lever after the embedding swap is the 0.88 consolidation** (and note
  `--consolidation none` does not disable it — see DIARIZER_ARM_REPORT.md §3).

## 3. Shippability — best accuracy ≠ best to ship on-device

Transcripted runs WeSpeaker via CoreML on the Apple Neural Engine. Conversion is the deciding factor:

| model | code license | CoreML/ONNX path | size | on-device risk |
|---|---|---|---|---|
| **CAM++** (3D-Speaker/wespeaker) | permissive | **official ONNX → coremltools → ANE (cleanest)** | **7.18M**, 192-d (< baseline) | **Medium — recommended first** |
| ERes2NetV2 (3D-Speaker) | permissive | official ONNX, same clean path | 17.8M, 192-d | Medium (heavier, short-clip-tuned) |
| ECAPA-TDNN (SpeechBrain) | Apache-2.0 | DIY — export encoder, Fbank in Swift | 6.2–20.8M | Medium-High |
| **ReDimNet-b6** (accuracy winner) | MIT | **documented ONNX-export failure; ANE-hostile** (reshape-dim + attention); 20.27 GMACs | 15.0M | **High — not on-device-ready** |
| ReDimNet-b2/b3 | MIT | same export blocker (cheaper if solved) | 3–4.7M | High |
| WeSpeaker ResNet34-LM (baseline) | shipping today | already CoreML/ANE | 256-d | baseline |

**Recommendation: ship CAM++ first** (clean conversion, smaller than today's model, efficiency-first design),
keep **ReDimNet-b6 as the research/accuracy ceiling**, and **ECAPA as the Apache-2.0, opus12k-robust alternate**.
**License:** all code permissive; all candidates are VoxCeleb2-trained (CC BY-NC-ND, non-commercial — propagation
to weights legally unsettled), but **Transcripted already ships VoxCeleb-derived WeSpeaker**, so this is no new
risk category. Prefer **CnCeleb / in-house CAM++ checkpoints** to reduce it.

## 4. Caveats — measured vs inferred

- **Measured:** ReDimNet-b6, ECAPA, WavLM, UniSpeech-SAT vs WeSpeaker on AMI, identical segments. End-to-end
  ReDimNet through the real matcher.
- **Inferred, NOT measured:** **CAM++ / ERes2NetV2 were never run in this harness** — their accuracy is from
  literature. The *shippability winner has zero in-harness accuracy data.* All Apple-Silicon latency figures are
  inferred from GMACs/params, **not profiled on ANE.**
- **Domain gap:** all numbers are **AMI 4-party in-room**; codec arms proxy call compression but **no real
  captured Zoom audio was tested.** Codec-robustness is the most transferable result; absolute DER is not.
- **Known gaps:** ReDimNet opus12k dip warrants one confirming re-run. (ECAPA is now evaluated on all 6 arms —
  g711u cov 0.797 / DER 0.281 / AUC 1.0, confirming it as a strong, fully-evaluable runner-up.)
- **Negative control (validity):** x-vector (`spkrec-xvect-voxceleb`, a weaker model) was run as a control and
  **does not beat WeSpeaker** — within-meeting DER 0.49–0.51 (worst of the field) on clean/opus8k/g711u. So the
  bake-off is not "any model swap helps"; only genuinely strong models (ReDimNet, ECAPA) win. (Note x-vector
  still has high cross-meeting AUC ~0.997 — coarse cross-call ID and fine within-meeting separation are
  different capabilities; the strong models win on both.)

## 5. Recommended path to ship

1. **Convert CAM++** (official ONNX → coremltools); confirm ANE residency + per-clip latency in Xcode before
   integration. Prefer a CnCeleb/in-house checkpoint.
2. **Run CAM++ (and ERes2NetV2) through this exact bake-off** — same AMI dumps/arms — and gate on it
   matching/beating WeSpeaker. (This is the missing data.)
3. **Wire into FluidAudio's CoreML embedding path** (drop-in for the 256-d extractor; new model is 192-d —
   check downstream dim assumptions).
4. **Re-run on-device** to confirm CoreML/ANE parity (quantization shifts cosine scale).
5. **Recalibrate the match threshold** per embedding (sweep; don't inherit 0.60).
6. **Then loosen `consolidateSameVoiceClusters@0.88`** — the bake-off proves the embedding is no longer the
   bottleneck; the within-meeting consolidation is.
7. **Validate on real captured Zoom audio** before shipping.

## Reproduce

```bash
python -m venv .venv_emb && . .venv_emb/bin/activate
pip install torch torchaudio speechbrain transformers soundfile numpy
MODELS="ecapa wavlm unisat redimnet_b6" ARMS="clean opus12k opus8k g711u" bash scripts/run_embed_bakeoff.sh
deactivate
for arm in clean opus12k opus8k g711u; do for m in "" ecapa wavlm redimnet_b6; do
  python3 scripts/model_scorecard.py --arm $arm --model "$m" --out-json data/eval/scorecards/${arm}__${m:-wespeaker}.json
done; done
python3 scripts/verify_bakeoff.py     # independent recompute + paired sign test + bootstrap CI
```
`.venv_emb/` and all `data/` artifacts are gitignored. Models: ECAPA `speechbrain/spkrec-ecapa-voxceleb`,
WavLM `microsoft/wavlm-base-plus-sv`, UniSpeech-SAT `microsoft/unispeech-sat-base-plus-sv`, ReDimNet
`torch.hub IDRnD/ReDimNet b6`.
