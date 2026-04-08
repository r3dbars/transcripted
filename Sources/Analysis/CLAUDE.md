# Analysis directory

## Current status

No Swift sources currently live in `Sources/Analysis/` on `main`.

Older docs described an `AnalysisEngine` / `InsightCard` prompt-improvement loop. That code is not present in the current tree.

## Agent notes

- Treat references to `AnalysisEngine`, `InsightCard`, or automatic prompt rewriting as historical unless those types are reintroduced in code.
- `Tests/InsightCardTests.swift` still exists, but it is not part of the current `run-tests.sh` wiring.
