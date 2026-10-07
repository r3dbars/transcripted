# .agents

Machine-read config for agent workflow and the ratchet baselines behind the repo checks. Not code, but wrong edits here silently loosen a guard.

## Files

- `agent-contract.json` — areas, path prefixes, owning docs, invariants, manual proof. Read by `scripts/dev/agent-context.py` and `scripts/dev/agent-check.py`. A new `AGENTS.md` for an area belongs in its `docs` list.
- `test-matrix.yml` — changed path to required checks. Drives `bash check.sh`, `scripts/dev/agent-preflight.sh`, and `scripts/dev/test-matrix-checks.py`. Commands run only from the allowed executables in `scripts/dev/agent-check.py`.
- `qa-gates.yml`, `board-scorecard.yml` — risk-to-gate map and per-board scoring registry (`docs/board-scorecard.md`).
- `modules.json` — every `Sources/**/*.swift` file maps to one module, with the modules and Core tiers it may name. A new top-level `Sources/` folder needs an entry here and an `AGENTS.md`.
- `plugins/marketplace.json` — local plugin marketplace entry for the companion build.
- `*-baseline.json` — grandfathered violations. See below.

## Baselines only shrink

| Baseline | Guard | Shrink with |
| --- | --- | --- |
| `file-size-baseline.json` (Swift files over 800 lines) | `scripts/dev/check-file-size.py` | `--shrink` |
| `test-shape-baseline.json` (source-text and wall-clock tests) | `scripts/dev/check-test-shape.py` | `--shrink` |
| `source-pin-baseline.json` (`resolved-pins` counts per test file) | `scripts/dev/check-source-pins.py` | `--count-baseline --shrink` |
| `module-boundary-baseline.json` (file, module, type crossings) | `scripts/dev/check-module-boundaries.py` | `--shrink` |
| `concurrency-baseline.json` (Swift 6 warnings per `Sources/` folder) | `scripts/dev/concurrency-census.sh` | `--shrink` |

- The `--shrink` flags lower counts and drop dead entries. They never raise a count or add a file.
- Raising a baseline or adding an entry is a reviewed human edit with the reason in the PR. Don't do it to make a check pass; split the file, move the type down, or pass plain values instead.
- A baseline entry that no longer applies fails the check until you shrink it, so the files carry no dead entries.
- `check-module-boundaries.py` is a lexer. A surprising violation is more likely a checker bug than a real edge: fix the checker or add to `ambiguousNames` with a reason, don't baseline noise.
- `concurrency-census.sh` needs prebuilt deps (`bash build-deps.sh`).

## Editing the contract and matrix

- Keep `agent-contract.json` `docs` entries pointing at files that exist, and consistent with `agentsDoc` in `modules.json`.
- Run `python3 scripts/dev/agent-context.py <paths>` to see what an area change resolves to, and `python3 scripts/dev/agent-check.py --self-test` after changing the matrix or contract.
- `AGENTS.md` at the repo root wins for workflow when it disagrees with these files.
