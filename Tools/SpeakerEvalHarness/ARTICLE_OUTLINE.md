# Applied article outline — "Choosing an on-device speaker-embedding model"

**Format:** applied engineering case study / experience report (company blog, Towards Data Science, or arXiv
technical report). NOT a novel-method academic paper — the contribution is *applied selection methodology +
hard-won on-device findings*, told as a debugging story.
**Audience:** ML / speech engineers shipping speaker ID, diarization, or any on-device embedding model.
**Length:** ~1,800–2,600 words + 4 figures. **Tone:** honest, first-person, "here's what actually happened,"
specific numbers, no hype.

**Title options (lead with the counterintuitive hook):**
1. *"The accuracy winner couldn't ship: choosing an on-device speaker-embedding model"*
2. *"Your speaker model's EER doesn't matter if it can't run on the device"*
3. *"Codec-robustness and conversion-survivability — what the leaderboards don't tell you about on-device speaker embeddings"*

**One-sentence thesis:** *For on-device speaker ID, the right model is decided by two axes the accuracy
leaderboards ignore — robustness to audio compression, and whether the model survives conversion to the
device's runtime — and the model that wins accuracy can lose on both.*

---

## 1. Hook — the bug (≈150 words)
- The product symptom: a transcription app merges two different people into one speaker; **worse on Zoom/phone**.
- Promise the reader a debugging story with two plot twists and a shippable answer.

## 2. The setup — where speaker labels come from (≈200 words)
- Two stages: **diarizer** ("who spoke when") → **matcher** ("have I heard this voice before?", via cosine
  similarity of embeddings against a threshold).
- The embedding ("voiceprint") is the load-bearing component. Frame the question: *is the bug in the knobs or
  the representation?*

## 3. Act I — the obvious fixes, and why they failed (≈350 words)
- Raise/lower the match threshold → **lowering made it worse.** The reveal: **compression pulls *different*
  speakers' embeddings together** (measured: same-vs-different separation 0.54 clean → 0.29 at low bitrate).
  *Counterintuitive lesson #1: a lenient threshold on compressed audio fuses strangers.*
- Three more dead ends in a sentence each: mean-centering, smarter clustering (even oracle-k), finer
  segmentation. All ≈ ties.
- **The near-miss (keep this — it's the credibility moment):** mean-centering looked like a huge win on the
  embedding-band metric, then did nothing end-to-end. *Lesson #2: a metric that improves in isolation is a
  hypothesis, not a result — test end-to-end.*
- Land the conclusion: **it's the embedding model, not the knobs.**
- **Figure 1:** the journey diagram (problem → 4 failed fixes → real cause → fix).

## 4. Act II — the bake-off (≈450 words)
- Method: re-extract embeddings for the **exact same** diarization segments with 8 models, on a **codec sweep**
  (clean → Opus 24/16/12/8k → G.711). Same segments → only the embedding changes (clean controlled comparison).
- Metrics, and *why*: within-meeting coverage/DER (separation) **+ threshold-free ROC-AUC** for cross-call
  separability. *Explain anisotropy:* SSL models (WavLM) cram everything into a narrow cone, so raw-cosine
  separation looks bad but ranking is fine — hence AUC, which is scale/anisotropy-immune. *Lesson #3: pick a
  metric that can't be gamed by the embedding's geometry.*
- **The negative control** (do not skip): a deliberately weak model (x-vector) — it lost on every arm,
  proving the win isn't "any swap helps." *Lesson #4: always include a control.*
- Results: strong discriminative models roughly **halve error on compressed audio** and stay flat where the old
  model collapses; near-perfect cross-call AUC.
- **Figure 2:** error-by-audio-type bars (current vs best). **Figure 3 / table:** the 8-model master scorecard.

## 5. Act III — the twist: accuracy ≠ shippable (≈450 words, the heart of the piece)
- Set up the two-axis decision: accuracy *and* on-device conversion-survivability.
- **CAM++ — the accuracy co-winner — fails CoreML conversion.** It converts and runs but emits garbage
  (parity cosine **0.23** vs 0.99 target). The honest diagnosis (and the self-correction): *not* float16/ANE
  precision, *not* the tiny-variance BatchNorm we first blamed — it's **architectural**: its deep DenseTDNN
  dense-concat/reshape graph accumulates error in *every* converter, even at float32/CPU. Per-op exact; error
  grows with depth. No clean fix.
- **ERes2Net — equally accurate — converts cleanly** (cosine **0.99999** fp16 / 1.0 fp32, 12.8 MB, Neural-Engine
  eligible) after one output-neutral patch. Verified on the *pretrained* weights (because the failure was
  weight-/architecture-specific, not generic).
- *Lesson #5: validate the conversion, not the leaderboard — "has an ONNX export" ≠ "produces correct outputs
  on-device."* This is the section that earns the article; it's not in any paper.
- **Figure 4:** the accuracy-vs-shippability decision map (ERes2Net top-right; CAM++ accurate-but-broken).

## 6. The takeaways for practitioners (≈250 words, bulleted)
- Stop tuning knobs; fix the representation. / Test end-to-end, never a proxy. / Use threshold-free, anisotropy-
  immune metrics. / Run a negative control. / **Benchmark conversion + on-device parity as a first-class axis.**
- The deeper residual is upstream (the diarizer/segmentation), not a consolidation knob — name it so readers
  don't chase the wrong thing.

## 7. Honest limitations (≈200 words — non-negotiable for credibility)
- Single corpus (**AMI**: 4-party, in-room, far-field) — *synthetically* codec-degraded, not real captured calls.
- Diarizer is a specific production pipeline → absolute numbers won't transfer; the **direction** (codec
  collapses separability; discriminative models are more robust; conversion can fail) is the transferable part.
- On-device **latency was inferred** from params/GMACs, not profiled on the Neural Engine.
- No real Zoom/Meet validation yet (in progress).
- State plainly what would make it a peer-reviewed result: real codec corpora + a second dataset + published-EER
  baselines.

## 8. Reproduce / appendix (≈150 words)
- The harness recipe (diarize once → swap embeddings → score), the models + licenses (all free; ERes2Net/CAM++
  3D-Speaker, ECAPA Apache-2.0, ReDimNet MIT), the codec arms, the conversion script. Link the eval code.

---

## Figures to reuse (already produced)
1. Journey diagram · 2. Error-by-audio bars (current vs best) · 3. 8-model master scorecard table
   (MASTER_SCORECARD.md) · 4. Accuracy-vs-shippability decision map (final ERes2Net version).

## Claims to double-check before publishing
- Re-state every number as **"on our AMI benchmark"** — don't imply production-measured.
- Don't claim a production accuracy gain until the **real-Zoom validation** runs.
- Confirm model **licenses** for redistribution/commercial framing; note the VoxCeleb2 non-commercial
  training-data nuance if you discuss shipping weights.
- Frame ERes2Net latency/ANE residency as **"converts to an ANE-eligible CoreML model, ~12.8 MB"** (measured)
  not "runs at X ms on ANE" (not profiled).
- Decide how much to name the product vs. keep it generic — the lessons stand either way.

## Distribution
- Primary: company engineering blog or Towards Data Science. Cross-post: arXiv (cs.SD/eess.AS) as a technical
  report for citability. Teaser: the X/LinkedIn thread we already drafted (BLOG_DRAFT_*.md) links to the full piece.
