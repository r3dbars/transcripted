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

## Status: the durable fix has landed

The registry is now single-sourced from union-mergeable `.psv` data files, so the
Swift policy is no longer a hand-merge point. Jump to **Durable fix (implemented)**
below for the current layout. The two sections that follow explain why the naive
shortcut (union-merging the `.swift` directly) was rejected.

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

## Durable fix (implemented)

The taxonomy is single-sourced from line-oriented data, so the brace-balanced
Swift is no longer hand-merged:

1. **`Resources/analytics-events.psv`** is the registry — one
   `event_name|prop_a,prop_b,…` line per event (empty allow-list = `event|`).
   Each line is independent, so it is safe to `merge=union` (`*.psv` in
   `.gitattributes`). `scripts/ops/normalize-analytics-taxonomy.py` re-sorts and
   dedupes after a union merge; `--check` is the hygiene gate.
2. **`AnalyticsEventPolicy` loads and compiles that file at runtime** (bundle in
   a shipped app, repo checkout under test/CI). Loading fails closed: an
   unreadable registry yields an empty allowlist and `AnalyticsReporter` drops
   every event rather than leaking an unreviewed payload. The public API
   (`policy(forEvent:)`, `allEventNames`, `allPolicies`) is unchanged.
3. **The privacy guardrail moved too**:
   `Resources/analytics-reviewed-properties.psv` (also `merge=union`) holds the
   reviewed non-bucket property allowlist that the tests enforce, so reviewing a
   new property is a one-line append instead of an edit to a shared Swift set.
4. The docs↔source parity, forbidden-fragment, reviewed-non-bucket, and a new
   **duplicate-event guard** all live in `Tests/AnalyticsEventPolicyTests.swift`
   and read the same data files, so the guardrails are preserved.

A new telemetry event is now: append one line to `analytics-events.psv`, append
any new reviewed property to `analytics-reviewed-properties.psv`, and append the
event to the `## Allowlisted analytics events` doc list — all three are
`merge=union`, so two telemetry PRs adding different events never conflict.

### Still hand-merged (follow-ups, out of scope for the registry fix)

These mirror the event list but are not the registry and were left as-is:

- `scripts/ops/health-probe.sh` carries the workflow-event list as a single
  string literal that cannot be union-merged. Pointing it at the `.psv` is the
  obvious next step.
- `scripts/ops/posthog-activation-funnel.py` /
  `scripts/ops/generate-nightly-digest.py` keep per-line event tuples.
- Per-event `runSuite(…)` blocks in the test are bespoke assertions, not a
  registry; they remain ordinary, optional test code.
