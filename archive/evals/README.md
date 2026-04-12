# Draft Evals (Legacy)

> **Note:** This eval tool was built when Draft used cloud APIs for benchmarking different models. Draft now runs fully local (Qwen 3.5-4B via MLX) with no external API calls. This tool still works for comparing cloud model outputs against your acceptance history, but is not part of the app's normal workflow.

Automated scoring for Draft model quality. Compares model outputs against your real acceptance history — what you actually sent vs. what each model would have generated.

## The idea

Your `feedback.jsonl` records every draft you've accepted or edited. Each entry has:
- `raw_text` — what you said into the mic
- `drafted_text` — what the model originally produced
- `accepted_text` — what you actually sent (the gold standard)

The eval script replays your `raw_text` inputs through any model, measures how close the output is to what you actually sent, and gives you a similarity score. Now you have a number instead of a gut feeling.

## Setup

```bash
cd archive/evals
pip install anthropic   # optional — script uses urllib directly, no deps required
```

No dependencies. Pure Python stdlib.

## Usage

```bash
ANTHROPIC_API_KEY=sk-ant-... python eval.py --limit 30
python eval.py --models sonnet --limit 50
python eval.py --models haiku sonnet --judge
python eval.py --feedback ~/Desktop/feedback.jsonl
```

## What it measures

| Metric | What it means |
|--------|---------------|
| **Style similarity** | How close the model output is to what you actually sent (0-1, higher = better) |
| **Baseline similarity** | How close the *original* draft was to what you sent -- the model's score to beat |
| **Delta** | Style similarity - baseline. Positive = model improved over baseline. |
| **Verbatim acceptance rate** | % of original drafts you took with zero edits |
| **LLM judge score** | Model rates the output 0-10 for voice match (optional, `--judge` flag) |

## How it works

```
feedback.jsonl
    +-- raw_text --> [model] --> output
                                    |
                            levenshtein distance
                                    |
    accepted_text ----------> similarity score
```

Levenshtein distance measures character-level edit distance. Normalized to 0-1 by dividing by the max string length. 1.0 = identical, 0.0 = completely different.
