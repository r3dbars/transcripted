# Analytics Taxonomy Merge Cascade

## Symptom

Generated telemetry PRs kept going dirty in a pile. Merging one analytics event
would conflict the next branch because every PR edited the same Swift dictionary
and the same test allowlist.

## Root Cause

Each privacy-reviewed telemetry PR used to add one event in several lockstep
places:

- `Sources/Observability/AnalyticsEventPolicy.swift`
- `Tests/AnalyticsEventPolicyTests.swift`
- `docs/privacy-first-observability.md`
- product-health scripts that list PostHog events

The Swift policy and test entries are multi-line, brace-balanced blocks. They
are not safe for `merge=union`; git can produce a clean-looking but unbalanced
Swift file.

## Durable Fix

The compiled analytics allowlist is now loaded from line-oriented registry
files:

- `Resources/analytics-events.psv`
- `Resources/analytics-reviewed-properties.psv`

Each event or reviewed property is one independent line, and `.gitattributes`
marks `*.psv` as `merge=union`. After a union merge, run:

```bash
python3 scripts/ops/normalize-analytics-taxonomy.py
```

or check without writing:

```bash
python3 scripts/ops/normalize-analytics-taxonomy.py --check
```

The Swift API stays the same:

- `AnalyticsEventPolicy.policy(forEvent:)`
- `AnalyticsEventPolicy.allEventNames`
- `AnalyticsEventPolicy.allPolicies`

If the registry cannot be read, the allowlist fails closed to empty, so
`AnalyticsReporter` drops events instead of forwarding an unreviewed payload.

## Adding a Telemetry Event

1. Add one line to `Resources/analytics-events.psv`.
2. Add any new non-`_bucket` property to `Resources/analytics-reviewed-properties.psv`.
3. Add the event to `docs/privacy-first-observability.md`.
4. Run `python3 scripts/ops/normalize-analytics-taxonomy.py --check`.
5. Run the analytics policy and sanitizer tests.

Keep payloads enum-only, boolean, public-version, or bucketed. Do not add raw
titles, transcripts, paths, source apps, device names, speaker names, emails,
tokens, URLs, or free-form text.
