# Analytics Taxonomy Merge Cascade — root cause & fix

## Symptom

Dozens of auto-generated telemetry PRs sit `DIRTY` at once. Merging any one of
them instantly re-conflicts all the others, faster than they can be rebased.

## Root cause

Every privacy-reviewed telemetry PR adds one or more analytics events, and each
new event is appended at the **same anchor** in a set of lockstep files:

- `Sources/Observability/AnalyticsEventPolicy.swift` — the `allowedPolicies`
  dictionary (plus a `…Properties` set above it)
- `Tests/AnalyticsEventPolicyTests.swift` — an additive `runSuite(…)` block
- `docs/privacy-first-observability.md` — the `## Allowlisted analytics events`
  list (and sibling planning docs)
- `scripts/ops/generate-nightly-digest.py`,
  `scripts/ops/posthog-activation-funnel.py` — per-line event tuples
- `scripts/ops/health-probe.sh` — the event list as a **single-line string**

Because every PR edits the identical anchor, one merge dirties all the rest.

## What works: union merge on the line-oriented docs

The markdown registries list one event per self-contained line
(`` - `event_name` ``). A union merge of two such inserts is always a valid
superset, and the docs↔source parity test sorts before comparing, so order is
irrelevant. `.gitattributes` therefore sets `merge=union` on those docs only.

## What does NOT work: union merge on the Swift policy (verified trap)

It is tempting to also `merge=union` `AnalyticsEventPolicy.swift`. **Do not.**
The dictionary entries and `…Properties` sets are multi-line, brace-balanced
blocks, and when two PRs insert at the same anchor git aligns the shared trailing
`]` / `)` as common context. A union merge then emits *both* opening blocks but
only *one* closing delimiter:

```swift
private static let workflowAbandonedProperties: Set<String> = [
    ...
    "workflow_kind",
private static let productFrictionProperties: Set<String> = [   // ← previous set never closed
    ...
    "surface",
]
```

Git reports a **clean auto-merge** (no conflict markers); the file is silently
unbalanced and will not compile. Reproduced on `#1210` ⊕ `#1222`: the result had
`[` 74/`]` 73 and `(` 105/`)` 104. Only Swift CI catches it — a conflict that
*looks* resolved is worse than one that doesn't. The same applies to the test
file's `runSuite { … }` blocks.

So the Swift policy + its test are intentionally left to normal (conflicting)
merges until the durable fix below lands.

## Durable fix (recommended — needs a scope decision)

Single-source the taxonomy so the brace-balanced Swift is **generated**, never
hand-merged:

1. Move the allowlist to one line-oriented data file — e.g.
   `analytics-events.psv`: `event_name|prop_a,prop_b,…`, one event per line.
   This file is safely `merge=union` (each line independent) + a trivial
   normalizer (`sort -u`) keeps it canonical and dedups.
2. Generate (or load at runtime) `AnalyticsEventPolicy`, the doc list, and the
   ops-script event tuples from that single source. The duplicate-event guard
   stays in `Tests/AnalyticsEventPolicyTests.swift`.
3. Make `scripts/ops/health-probe.sh` read the same file instead of hard-coding
   a single-line copy (its current shape can't be union-merged at all).

That removes every hand-merge point and makes the taxonomy single-sourced.

Until then: rebasing a telemetry PR needs only a trivial keep-both resolution of
the Swift policy/test conflict (add the missing closing `]`/`)` so both events
remain). The doc/script conflicts auto-resolve via the union attribute above.
