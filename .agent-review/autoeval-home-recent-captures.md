# Autoeval: Settings Home Recent Captures

## Verdict
winner

The kept change cuts the 10k fake-library full snapshot from `474.4 ms` average to `235.6 ms` average, with cancellation returning immediately in the benchmark.

## Metric
- Primary: wall-clock time for `RecentCaptureLoader.load(dictationLimit: 11, meetingLimit: 11, includeDictationCounts: true)`.
- Fixtures: generated temp capture libraries only, split evenly between meeting Markdown files and dictation day files.
- Guardrails: newest-first rows, requested dictation counts, requested word totals, and canceled loads returning no stale rows.

## Baseline
- Command: `bash scripts/dev/benchmark-home-recent-captures.sh`
- Raw result:

| captures | meetings | dictations | reps | raw load ms | avg load ms | best load ms | cancel ms |
|---:|---:|---:|---:|---|---:|---:|---:|
| 1000 | 500 | 500 | 3 | 58.0, 52.3, 50.7 | 53.7 | 50.7 | 50.7 |
| 10000 | 5000 | 5000 | 3 | 484.9, 483.8, 454.5 | 474.4 | 454.5 | 451.7 |

## Knobs Tested
| # | Knob | Status | Change | Command | Raw result | Decision |
|---|------|--------|--------|---------|------------|----------|
| 1 | Concurrent loader phases | kept | Run meeting scan, recent dictation scan, and optional dictation counts as child tasks. | `bash scripts/dev/benchmark-home-recent-captures.sh` | 1k avg `36.6 ms`; 10k avg `246.3 ms`; cancel `230.7 ms` at 10k | Kept. Big 10k win with same snapshot shape. |
| 2 | One meeting metadata read | kept | Reuse the resource-value read for file type and date instead of reading file metadata twice. | `bash scripts/dev/benchmark-home-recent-captures.sh` | 1k avg `27.4 ms`; 10k avg `237.1 ms`; cancel `222.3 ms` at 10k | Kept. Small additional win, no behavior change intended. |
| 3 | Cancellation bridge and scan checks | kept | Make cancellation sticky in `LoadTaskBox`; check cancellation inside large meeting/dictation loops. | `bash scripts/dev/benchmark-home-recent-captures.sh` | 1k avg `27.8 ms`; 10k avg `233.1 ms`; cancel `0.0 ms` at 10k | Kept. Fixes stale-row cancellation path. |
| 4 | Stream dictation count lines | rejected | Use `String.enumerateLines` in dictation count parsing. | `bash scripts/dev/benchmark-home-recent-captures.sh` | 1k avg `27.6 ms`; 10k avg `317.1 ms`; cancel `0.1 ms` at 10k | Rejected and reverted. Slower on 10k. |
| 5 | Final kept state | kept | Re-run after reverting losing line-stream parser. | `bash scripts/dev/benchmark-home-recent-captures.sh` | 1k raw `34.6, 26.9, 26.0`, avg `29.2 ms`; 10k raw `253.2, 227.4, 226.3`, avg `235.6 ms`; cancel `0.0 ms` at 10k | Final winner. |

## Kept Changes
- `Sources/UI/Shared/RecentCaptureScanners.swift`: parallelizes independent scan phases, removes duplicate meeting metadata reads, and makes cancellation reliable.
- `Sources/Dictation/DictationTranscriptStore.swift`: checks `Task.isCancelled` inside large dictation scans.
- `Tests/RecentCaptureScannersTests.swift`: adds temp-library loader tests for sorting, counts, and cancellation.
- `Tests/Benchmarks/HomeRecentCaptureBenchmark.swift` and `scripts/dev/benchmark-home-recent-captures.sh`: deterministic local benchmark using generated fixtures only.

## Rejected Changes
- Streaming dictation count parsing with `enumerateLines`; it raised 10k average load time from the kept `~233 ms` range to `317.1 ms`.

## Untested Or Ruled-Out Knobs
- Defer Home stats counts behind visible rows: ruled out for this pass because the full snapshot already improved by about 50% without changing Home's stats timing.
- Top-N meeting partial sort: ruled out for this pass because non-meeting Markdown can be skipped after preview, so a naive top-N candidate cap can return fewer valid meetings than the current exact newest-first scan.

## Risks
- The benchmark uses many small synthetic files. Real libraries with very large Markdown transcripts may still be dominated by reading the visible meeting files for speaker status.
- The loader now does more work concurrently, so very slow disks could see more simultaneous I/O. The measured wall-clock result still improved on the target fixture sizes.

## Verification
- `bash build-deps.sh --force` passed after the fresh worktree was missing dependency artifacts.
- `bash build.sh --no-open` passed.
- `bash run-tests.sh` passed: `3037 tests, 3037 passed, 0 failed`.

## Next Run
- Add a fixture variant with large visible meeting transcripts and test a bounded speaker-status scan that avoids reading full Markdown when only labels are needed.
