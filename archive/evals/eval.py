#!/usr/bin/env python3
"""
Draft Eval — score and compare models against your real acceptance history.

Reads feedback.jsonl (your accepted drafts), reruns each raw input through
one or more models, and measures how close the output was to what you
actually sent. Gives you a number instead of a gut feeling.

Usage:
    python eval.py                                   # compare haiku vs sonnet
    python eval.py --models sonnet                   # single model
    python eval.py --limit 20                        # run on last 20 entries
    python eval.py --feedback /path/to/feedback.jsonl
    python eval.py --prompts /path/to/prompts.json   # use your style profile
    python eval.py --judge                           # add LLM-as-judge scoring (costs extra)
"""

import argparse
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional
import urllib.request
import urllib.error

# ── Model aliases ──────────────────────────────────────────────────────────────
MODELS = {
    "haiku":  "claude-haiku-4-5-20251001",
    "sonnet": "claude-sonnet-4-20250514",
    "opus":   "claude-opus-4-20250514",
}

DEFAULT_FEEDBACK = Path.home() / "Library/Application Support/Draft/feedback.jsonl"
DEFAULT_PROMPTS  = Path.home() / "Library/Application Support/Draft/prompts.json"

DEFAULT_SYSTEM_PROMPT = (
    "You are a writing assistant. Take the user's rough spoken text and rewrite it "
    "as a clear, well-structured message. Preserve the original meaning, intent, and tone. "
    "Don't add information that wasn't in the original. Keep it concise and natural-sounding. "
    "Output ONLY the message text, nothing else."
)

# ── Data types ─────────────────────────────────────────────────────────────────
@dataclass
class FeedbackEntry:
    timestamp: str
    raw_text: str
    drafted_text: str     # Original Claude output at the time
    accepted_text: str    # What the user actually sent (the gold standard)
    action: str
    example_count: int
    formality: Optional[str] = None

@dataclass
class EvalResult:
    entry: FeedbackEntry
    model: str
    model_output: str
    # Edit distance from model output → accepted_text (lower = better)
    output_distance: int
    output_similarity: float        # 0–1, higher = better
    # Edit distance from original drafted_text → accepted_text (baseline)
    baseline_distance: int
    baseline_similarity: float
    # Did user take the original draft as-is?
    was_accepted_verbatim: bool
    # LLM judge score (0–10), if --judge flag used
    judge_score: Optional[float] = None

@dataclass
class ModelSummary:
    model: str
    n: int
    avg_similarity: float
    avg_baseline_similarity: float
    improvement_over_baseline: float  # positive = better than original
    verbatim_acceptance_rate: float   # % where original draft was taken as-is
    avg_judge_score: Optional[float] = None
    results: list = field(default_factory=list)

# ── Edit distance ──────────────────────────────────────────────────────────────
def levenshtein(a: str, b: str) -> int:
    """Character-level Levenshtein distance."""
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    m, n = len(a), len(b)
    dp = list(range(n + 1))
    for i in range(1, m + 1):
        prev = dp[0]
        dp[0] = i
        for j in range(1, n + 1):
            temp = dp[j]
            if a[i - 1] == b[j - 1]:
                dp[j] = prev
            else:
                dp[j] = 1 + min(prev, dp[j], dp[j - 1])
            prev = temp
    return dp[n]

def similarity(a: str, b: str) -> float:
    """Normalized similarity: 1.0 = identical, 0.0 = completely different."""
    if not a and not b:
        return 1.0
    max_len = max(len(a), len(b))
    if max_len == 0:
        return 1.0
    return 1.0 - levenshtein(a, b) / max_len

# ── Anthropic API ──────────────────────────────────────────────────────────────
def call_anthropic(
    raw_text: str,
    system_prompt: str,
    model: str,
    api_key: str,
    max_tokens: int = 512,
    retries: int = 3,
) -> str:
    """Call the Anthropic Messages API. Returns the text content."""
    url = "https://api.anthropic.com/v1/messages"
    payload = {
        "model": model,
        "max_tokens": max_tokens,
        "system": system_prompt,
        "messages": [{"role": "user", "content": raw_text}],
    }
    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
    }
    data = json.dumps(payload).encode()

    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, data=data, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = json.loads(resp.read())
                return body["content"][0]["text"].strip()
        except urllib.error.HTTPError as e:
            err_body = e.read().decode()
            if e.code == 429 or e.code >= 500:
                wait = 2 ** attempt
                print(f"  ⚠ HTTP {e.code}, retrying in {wait}s…", file=sys.stderr)
                time.sleep(wait)
            else:
                raise RuntimeError(f"API error {e.code}: {err_body}") from e
        except Exception as exc:
            if attempt == retries - 1:
                raise
            time.sleep(2 ** attempt)
    raise RuntimeError(f"Failed after {retries} attempts")

def call_judge(
    raw_text: str,
    reference: str,
    candidate: str,
    style_examples: list[str],
    api_key: str,
) -> float:
    """
    Ask Claude to score how well the candidate output matches the user's voice.
    Returns a score from 0–10.
    """
    examples_block = "\n".join(
        f"- {e}" for e in style_examples[:10]
    ) if style_examples else "(none available)"

    judge_prompt = f"""You are evaluating whether an AI-generated message sounds like a specific person.

USER'S VOICE — examples of messages they have actually sent:
{examples_block}

ORIGINAL REQUEST (what they said into the mic):
{raw_text}

WHAT THEY ACTUALLY SENT (ground truth):
{reference}

CANDIDATE OUTPUT (what the model generated):
{candidate}

Score the candidate output from 0–10:
- 10: Indistinguishable from what the user actually sent. Same voice, register, length.
- 7–9: Very close. Minor wording differences but same feel.
- 4–6: Correct information but noticeably different style or tone.
- 1–3: Wrong register, too formal/informal, or missing their patterns.
- 0: Completely off.

Reply with ONLY a single integer or decimal (e.g. "8" or "7.5"). Nothing else."""

    try:
        response = call_anthropic(
            raw_text=judge_prompt,
            system_prompt="You are a precise writing style evaluator. Output only a number.",
            model=MODELS["haiku"],  # Use Haiku for judging — cheap and sufficient
            api_key=api_key,
            max_tokens=10,
        )
        # Extract first number from response
        match = re.search(r"\d+(\.\d+)?", response)
        return float(match.group()) if match else 5.0
    except Exception:
        return 5.0  # Default to mid-score on failure

# ── Loaders ────────────────────────────────────────────────────────────────────
def load_feedback(path: Path, limit: Optional[int] = None) -> list[FeedbackEntry]:
    if not path.exists():
        print(f"❌ feedback.jsonl not found at {path}", file=sys.stderr)
        print("   Have you used Draft yet? Accept some drafts first to build the dataset.", file=sys.stderr)
        sys.exit(1)

    entries = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
                entries.append(FeedbackEntry(
                    timestamp=d.get("timestamp", ""),
                    raw_text=d.get("raw_text", "").strip(),
                    drafted_text=d.get("drafted_text", "").strip(),
                    accepted_text=d.get("accepted_text", "").strip(),
                    action=d.get("action", "copy"),
                    example_count=d.get("example_count", 0),
                    formality=d.get("formality"),
                ))
            except json.JSONDecodeError:
                continue

    # Only entries where the user accepted/edited (accepted_text exists)
    entries = [e for e in entries if e.raw_text and e.accepted_text]

    # Most recent first, then apply limit
    entries = sorted(entries, key=lambda e: e.timestamp, reverse=True)
    if limit:
        entries = entries[:limit]

    return entries

def load_system_prompt(prompts_path: Optional[Path]) -> str:
    """Load the drafting system prompt from prompts.json, or fall back to default."""
    if prompts_path and prompts_path.exists():
        try:
            with open(prompts_path) as f:
                config = json.load(f)
            # Prefer ghostwriting_system if it has style examples injected;
            # fall back to drafting_system for a fair baseline comparison
            prompt = config.get("drafting_system") or config.get("ghostwriting_system") or DEFAULT_SYSTEM_PROMPT
            # Strip the {STYLE_SUMMARY} placeholder — fair comparison uses no personalization
            prompt = re.sub(r"<style_profile>.*?</style_profile>", "", prompt, flags=re.DOTALL).strip()
            return prompt
        except Exception:
            pass
    return DEFAULT_SYSTEM_PROMPT

# ── Core eval loop ─────────────────────────────────────────────────────────────
def run_eval(
    entries: list[FeedbackEntry],
    model_keys: list[str],
    system_prompt: str,
    api_key: str,
    use_judge: bool = False,
) -> dict[str, ModelSummary]:
    """Run the eval. Returns a dict of model_key → ModelSummary."""

    # Collect accepted_texts for judge style examples
    style_examples = [e.accepted_text for e in entries[:20]]

    summaries: dict[str, ModelSummary] = {}

    for model_key in model_keys:
        model_id = MODELS.get(model_key, model_key)
        print(f"\n🔄 Evaluating {model_key} ({model_id}) on {len(entries)} entries…")
        results: list[EvalResult] = []

        for i, entry in enumerate(entries):
            print(f"  [{i+1}/{len(entries)}] {entry.raw_text[:60]}…", end=" ", flush=True)

            try:
                output = call_anthropic(
                    raw_text=entry.raw_text,
                    system_prompt=system_prompt,
                    model=model_id,
                    api_key=api_key,
                )
            except Exception as e:
                print(f"ERROR: {e}")
                continue

            out_sim = similarity(output, entry.accepted_text)
            base_sim = similarity(entry.drafted_text, entry.accepted_text)
            out_dist = levenshtein(output, entry.accepted_text)
            base_dist = levenshtein(entry.drafted_text, entry.accepted_text)
            verbatim = entry.drafted_text.strip() == entry.accepted_text.strip()

            judge_score = None
            if use_judge:
                judge_score = call_judge(
                    raw_text=entry.raw_text,
                    reference=entry.accepted_text,
                    candidate=output,
                    style_examples=style_examples,
                    api_key=api_key,
                )

            result = EvalResult(
                entry=entry,
                model=model_key,
                model_output=output,
                output_distance=out_dist,
                output_similarity=out_sim,
                baseline_distance=base_dist,
                baseline_similarity=base_sim,
                was_accepted_verbatim=verbatim,
                judge_score=judge_score,
            )
            results.append(result)

            delta = out_sim - base_sim
            marker = "✅" if delta >= 0 else "⚠️"
            judge_str = f" judge={judge_score:.1f}" if judge_score is not None else ""
            print(f"{marker} sim={out_sim:.2f} (baseline={base_sim:.2f}, Δ={delta:+.2f}){judge_str}")

            time.sleep(0.3)  # Rate limit buffer

        if not results:
            continue

        n = len(results)
        avg_sim = sum(r.output_similarity for r in results) / n
        avg_base = sum(r.baseline_similarity for r in results) / n
        verbatim_rate = sum(1 for r in results if r.was_accepted_verbatim) / n
        avg_judge = (
            sum(r.judge_score for r in results if r.judge_score is not None) /
            max(1, sum(1 for r in results if r.judge_score is not None))
        ) if use_judge else None

        summaries[model_key] = ModelSummary(
            model=model_key,
            n=n,
            avg_similarity=avg_sim,
            avg_baseline_similarity=avg_base,
            improvement_over_baseline=avg_sim - avg_base,
            verbatim_acceptance_rate=verbatim_rate,
            avg_judge_score=avg_judge,
            results=results,
        )

    return summaries

# ── Report ─────────────────────────────────────────────────────────────────────
def print_report(summaries: dict[str, ModelSummary], use_judge: bool) -> None:
    print("\n" + "═" * 60)
    print("  DRAFT EVAL RESULTS")
    print("═" * 60)

    for key, s in summaries.items():
        model_id = MODELS.get(key, key)
        improvement_str = f"{s.improvement_over_baseline:+.3f}"
        direction = "↑ better than baseline" if s.improvement_over_baseline > 0 else "↓ worse than baseline"
        print(f"\n  Model: {key} ({model_id})")
        print(f"  Entries evaluated: {s.n}")
        print(f"  ─────────────────────────────────────────")
        print(f"  Style similarity (vs what you actually sent):")
        print(f"    This model:    {s.avg_similarity:.3f}  ({s.avg_similarity * 100:.1f}%)")
        print(f"    Original draft:{s.avg_baseline_similarity:.3f}  ({s.avg_baseline_similarity * 100:.1f}%)")
        print(f"    Delta:         {improvement_str}  {direction}")
        print(f"  Verbatim acceptance rate: {s.verbatim_acceptance_rate:.1%}  (drafts taken with zero edits)")
        if use_judge and s.avg_judge_score is not None:
            print(f"  LLM judge score: {s.avg_judge_score:.1f}/10")

    # Winner
    if len(summaries) > 1:
        best = max(summaries.values(), key=lambda s: s.avg_similarity)
        print(f"\n  🏆 Best model: {best.model} (similarity={best.avg_similarity:.3f})")

    # Worst performing individual cases
    all_results = [r for s in summaries.values() for r in s.results]
    worst = sorted(all_results, key=lambda r: r.output_similarity)[:3]
    if worst:
        print(f"\n  ⚠️  Lowest scoring cases (investigate these):")
        for r in worst:
            print(f"    [{r.model}] sim={r.output_similarity:.2f}")
            print(f"      Input:     {r.entry.raw_text[:80]}")
            print(f"      Model out: {r.model_output[:80]}")
            print(f"      You sent:  {r.entry.accepted_text[:80]}")

    print("\n" + "═" * 60)

    # Save detailed results to JSON
    output_path = Path("eval_results.json")
    report = {
        "summaries": [
            {
                "model": s.model,
                "n": s.n,
                "avg_similarity": s.avg_similarity,
                "avg_baseline_similarity": s.avg_baseline_similarity,
                "improvement_over_baseline": s.improvement_over_baseline,
                "verbatim_acceptance_rate": s.verbatim_acceptance_rate,
                "avg_judge_score": s.avg_judge_score,
            }
            for s in summaries.values()
        ],
        "cases": [
            {
                "model": r.model,
                "raw_text": r.entry.raw_text,
                "drafted_text": r.entry.drafted_text,
                "accepted_text": r.entry.accepted_text,
                "model_output": r.model_output,
                "output_similarity": r.output_similarity,
                "baseline_similarity": r.baseline_similarity,
                "delta": r.output_similarity - r.baseline_similarity,
                "judge_score": r.judge_score,
            }
            for s in summaries.values()
            for r in s.results
        ],
    }
    with open(output_path, "w") as f:
        json.dump(report, f, indent=2)
    print(f"  Detailed results saved to {output_path.absolute()}")

# ── Main ───────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="Evaluate Draft model quality against your real acceptance history."
    )
    parser.add_argument(
        "--models",
        nargs="+",
        default=["haiku", "sonnet"],
        help="Models to compare. Options: haiku, sonnet, opus (or full model IDs). Default: haiku sonnet",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Max number of entries to evaluate (most recent first). Default: all",
    )
    parser.add_argument(
        "--feedback",
        type=Path,
        default=DEFAULT_FEEDBACK,
        help=f"Path to feedback.jsonl. Default: {DEFAULT_FEEDBACK}",
    )
    parser.add_argument(
        "--prompts",
        type=Path,
        default=DEFAULT_PROMPTS,
        help=f"Path to prompts.json (uses your style profile). Default: {DEFAULT_PROMPTS}",
    )
    parser.add_argument(
        "--judge",
        action="store_true",
        help="Add LLM-as-judge scoring (costs extra API calls, uses Haiku for judging)",
    )
    parser.add_argument(
        "--api-key",
        default=os.environ.get("ANTHROPIC_API_KEY", ""),
        help="Anthropic API key. Falls back to ANTHROPIC_API_KEY env var.",
    )
    args = parser.parse_args()

    if not args.api_key:
        print("❌ No API key. Set ANTHROPIC_API_KEY or pass --api-key.", file=sys.stderr)
        sys.exit(1)

    # Validate model names
    for m in args.models:
        if m not in MODELS and not m.startswith("claude-"):
            print(f"❌ Unknown model '{m}'. Choose from: {list(MODELS.keys())} or a full claude-* model ID.", file=sys.stderr)
            sys.exit(1)

    print(f"📂 Loading feedback from {args.feedback}")
    entries = load_feedback(args.feedback, limit=args.limit)
    print(f"✅ {len(entries)} usable entries found")

    system_prompt = load_system_prompt(args.prompts)
    print(f"📝 System prompt: {'from prompts.json' if args.prompts and args.prompts.exists() else 'default'}")
    if args.judge:
        print("⚖️  LLM-as-judge scoring enabled")

    summaries = run_eval(
        entries=entries,
        model_keys=args.models,
        system_prompt=system_prompt,
        api_key=args.api_key,
        use_judge=args.judge,
    )

    print_report(summaries, use_judge=args.judge)

if __name__ == "__main__":
    main()
