# Analysis directory

## Current status

No Swift sources currently live in `Sources/Analysis/` on `main`.

Older docs described an `AnalysisEngine` / `InsightCard` prompt-improvement loop. That code is not present in the current tree.

## Agent notes

- Treat references to `AnalysisEngine`, `InsightCard`, or automatic prompt rewriting as historical unless those types are reintroduced in code.
- The old `InsightCard` test file has been removed from the current fast suite along with the stale analysis loop references.
