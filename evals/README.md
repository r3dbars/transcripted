# Draft Evals

Automated scoring for Draft model quality. Compares model outputs against your real acceptance history — what you actually sent vs. what each model would have generated.

## The idea

Your `feedback.jsonl` records every draft you've accepted or edited. Each entry has:
- `raw_text` — what you said into the mic
- `drafted_text` — what Claude originally produced
- `accepted_text` — what you actually sent (the gold standard)

The eval script replays your `raw_text` inputs through any model, measures how close the output is to what you actually sent, and gives you a similarity score. Now you have a number instead of a gut feeling.

## Setup

```bash
cd evals
pip install anthropic   # optional — script uses urllib directly, no deps required
```

No dependencies. Pure Python stdlib.

## Usage

**Compare Haiku vs Sonnet on your last 30 drafts:**
```bash
ANTHROPIC_API_KEY=sk-ant-... python eval.py --limit 30
```

**Single model:**
```bash
python eval.py --models sonnet --limit 50
```

**With LLM-as-judge scoring (better signal, costs extra):**
```bash
python eval.py --models haiku sonnet --judge
```

**Custom feedback file:**
```bash
python eval.py --feedback ~/Desktop/feedback.jsonl
```

## What it measures

| Metric | What it means |
|--------|---------------|
| **Style similarity** | How close the model output is to what you actually sent (0–1, higher = better) |
| **Baseline similarity** | How close the *original* draft was to what you sent — the model's score to beat |
| **Delta** | Style similarity − baseline. Positive = model improved over baseline. |
| **Verbatim acceptance rate** | % of original drafts you took with zero edits |
| **LLM judge score** | Claude rates the output 0–10 for voice match (optional, `--judge` flag) |

## Reading the output

```
Model: sonnet
Entries evaluated: 30
Style similarity (vs what you actually sent):
  This model:    0.812  (81.2%)
  Original draft:0.743  (74.3%)
  Delta:         +0.069  ↑ better than baseline
Verbatim acceptance rate: 43.3%
```

A delta of +0.05 or higher means the model would have produced meaningfully better drafts than the ones you received.

## Saved results

Every run saves `eval_results.json` with per-case detail — the raw input, original draft, what you sent, and what each model would have generated. Useful for debugging low-scoring cases.

## When to run this

- **Before/after changing models** — did switching to Sonnet actually help?
- **Before/after prompt changes** — did the new system prompt improve quality?
- **Periodically** — as your style profile grows, does quality improve?
- **When something feels off** — quantify whether it's real

## How it works (for the curious)

```
feedback.jsonl
    └── raw_text ──→ [model] ──→ output
                                    ↓
                            levenshtein distance
                                    ↓
    accepted_text ──────────→ similarity score
```

Levenshtein distance measures character-level edit distance. Normalized to 0–1 by dividing by the max string length. 1.0 = identical, 0.0 = completely different.

The baseline is the original draft that was already generated at accept time — so the eval tells you whether a new model/prompt would have done *better* than what you actually received.
