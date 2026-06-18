<!-- Public dev-blog draft. Charts: chart 1 = investigation_journey, chart 2 = payoff_speakers_separated
     (both rendered in-session; export the SVGs to embed). Data tables included so the post stands alone. -->

# We almost shipped the wrong fix: hunting down speaker confusion in a transcription app

*How a "just tune the threshold" bug turned into a detective story — and why the real fix was a free model swap, not a setting.*

Our app, Transcripted, listens to meetings and writes them down — who said what. Most of the time it's great. But it had an embarrassing failure: it would sometimes **merge two different people into one speaker**, or split one person across several. And it was noticeably worse on compressed audio — Zoom calls, phone bridges.

We thought this would be a quick tuning fix. It turned into a multi-week investigation that overturned our assumptions twice. Here's the whole story, including the fix that *almost* fooled us.

## The obvious fix that backfired

Speaker labeling works in two steps: a **diarizer** splits the audio into "who spoke when," and a **matcher** decides whether a voice is someone it's heard before — by comparing "voiceprints" (embeddings) with a similarity threshold. If two people get merged, the obvious culprit is the matcher being too eager. So: **raise** the threshold (be pickier), right?

We measured it on real labeled audio. Raising the threshold barely helped — and *lowering* it (which we tested to map the whole curve) made things **dramatically worse**, especially on compressed audio.

The reason turned out to be the most interesting finding of the whole project: **compression makes different people's voiceprints look *more alike*.** We measured the gap between "same person" and "different person" similarity as we squeezed the audio through codecs:

| audio | same-vs-different separation |
|---|---|
| clean | 0.54 |
| aggressive VoIP | 0.42 |
| very low bitrate | **0.29** |

The codec smears everyone toward the same blurry average. So on a compressed call, a lenient threshold doesn't reunite a person with their past self — it fuses *strangers*. The threshold wasn't the lever. It was barely a lever at all.

## Three more dead ends

We're stubborn, so we kept testing matcher-side fixes:

- **Re-centering the voiceprints** (removing that shared "blur" direction): looked promising — more on this below.
- **Smarter clustering** — we even handed the algorithm the *exact* number of speakers ("oracle-k"). It tied the shipping system. No win.
- **Finer / overlap-aware segmentation** — we restricted to clean, single-speaker snippets. Still couldn't separate the speakers.

Each one independently said the same thing: the problem isn't *how we group or compare* the voiceprints. It's the voiceprints themselves.

## The fix that almost fooled us

The re-centering idea deserves its own paragraph, because it's the part I'm most glad we double-checked.

On the raw voiceprint math, re-centering looked like a *huge* win — it restored the same-vs-different separation from 0.29 all the way back to ~0.77 on heavily compressed audio. On that chart, it was a slam dunk. We were ready to call it the fix.

Then we ran it **end-to-end through the actual matcher** — not the proxy metric, the real pipeline that produces speaker labels. It did **nothing** for the user-facing error. It had just shuffled "merge" errors into "split" errors. The beautiful chart was measuring something real, but not something that mattered downstream.

The lesson burned in: **a metric that improves in isolation is a hypothesis, not a result.** We only caught it because we'd made a habit of adversarial verification — every promising finding gets a "does this actually help end-to-end, and can an independent check break it?" pass. That pass saved us from shipping a no-op.

## The real culprit

With every cheap fix eliminated, the conclusion was unavoidable: the **voice-fingerprint model itself** (an older speaker-embedding network) was the ceiling — and compression made it worse. The accuracy "floor" we'd assumed was just hard physics (people in the same room, sharing a mic) was, to a large degree, *the model*.

So we ran a bake-off: re-extract voiceprints for the *exact same* audio segments with several strong, **free, open** speaker-embedding models, and compare apples-to-apples.

The result was the payoff we'd been chasing. A better model recovered far more speakers, especially on compressed audio:

| audio | current model | best model |
|---|---|---|
| clean | 73% | 81% |
| compressed (Zoom-ish) | 63% | **77%** |
| phone-band | 63% | **83%** |

*(% of speakers correctly told apart. Errors roughly **halved** on phone-band audio; cross-call matching went from ~95–98% to near-perfect.)*

And crucially — we ran a **negative control**: a deliberately *weak* model. It lost, badly. That mattered. It proved the win wasn't "any swap helps" or a quirk of our test harness; only genuinely better models won. The effect is real.

## What we'd tell another team

Four takeaways, in rough order of how much they surprised us:

1. **When accuracy plateaus, fix the representation, not the knobs.** Thresholds, clustering, and post-processing were *all* weaker levers than the embedding. We'd have wasted weeks tuning them.
2. **Test end-to-end, never on a proxy.** Our most beautiful intermediate metric was a mirage. The only number that counts is the one the user feels.
3. **Run a negative control.** "Our fix improved the metric" is much more convincing when "a deliberately bad change made it worse" on the same harness.
4. **Compression is an adversary, not just noise.** It doesn't randomly degrade voiceprints — it systematically pulls *different* speakers together. That single insight explained why our first instinct was exactly backwards.

## The honest caveats

We tested on a public meeting-room dataset (4 people, one room, far-field mics) — *harder* than a typical Zoom call where everyone's on a separate stream, so the real-world numbers should be friendlier. We haven't yet validated on captured Zoom audio, and the most *shippable* model (the one that converts cleanest to on-device Apple silicon) still needs its accuracy confirmed in our harness. There's also a downstream setting that currently caps the gains and needs loosening. None of that changes the direction — it just sequences the work.

But the headline holds, and it's a good one: **the problem wasn't a setting we'd mis-tuned. It was the voiceprint model — and the upgrade is free, local, and roughly halves the errors where it hurts most.**

*The full investigation — four detailed reports and all the evaluation code — is in our repo. Everything here was measurement; we didn't change a line of the app to learn it.*
