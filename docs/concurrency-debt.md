# Concurrency debt

Swift 6 strict concurrency flags data races and wrong-thread calls. The app still builds in Swift 5 mode, so we don't get errors for them. We get a count instead.

`scripts/dev/concurrency-census.sh` does a `swiftc -typecheck` pass with `-strict-concurrency=complete` and counts the concurrency warnings per `Sources/` folder. The parser is `scripts/dev/concurrency-census.py`; it dedups by (file, line, message). The counts live in `.agents/concurrency-baseline.json`.

```bash
bash scripts/dev/concurrency-census.sh            # report
bash scripts/dev/concurrency-census.sh --check    # fail if any folder went up
bash scripts/dev/concurrency-census.sh --shrink   # lower the baseline to the new counts
```

`--shrink` is the only allowed way to edit the baseline. Never raise it. It only lowers folders already in the baseline, and refuses (without writing) if any folder went up or isn't in the baseline yet. A folder that reaches zero keeps its `0` entry.

**What the census covers.** The app target (`Sources/**` minus the two trees below) plus `TranscriptedWritingCore` (`Sources/TranscriptedWriting/Core`), which is compiled first as its own module under the same flag. It does not cover `Sources/TranscriptedCore/**` (the prebuilt library) or `Sources/TranscriptedKeyboard/**`. Warnings there are not counted, so a zero in the baseline says nothing about those trees.

## Where it stands

As of 2026-10-18 the census is at zero in every folder it covers. The baseline keeps an explicit `0` for Capture, Speech and UI, so `--check` fails if a warning comes back there. A folder that isn't listed fails `--check` as soon as it has a warning too, as long as the baseline isn't empty.

This page used to carry the backlog: 94 warnings at `ab7e811c`, with a RISKY or LEAVE call for each hot-path or audio item. The October 2026 cleanup lanes cleared them. `git log -- .agents/concurrency-baseline.json` lists the commits, and `git show 3eeb26873:docs/concurrency-debt.md` has the last version of the tables. Their line numbers no longer match the code, so don't use them as pointers.

Some of those fixes are promises the compiler can't check: `@unchecked Sendable` on lock- or queue-confined types, and `nonisolated(unsafe)` on constants and lock-guarded statics. If a race shows up, grep `Sources/` for those two first. Each one should say which lock or queue makes it true.

## New warnings

Fix them; don't grow the baseline. Anything on the AirPods-sensitive engine path or the CoreAudio device-switching path needs owner review before an isolation or `@Sendable` change, so read `Sources/Speech/AGENTS.md` first. Prefer typing a callback `@MainActor @Sendable` when every caller is already on main. Reach for `@unchecked Sendable` only after checking that every mutable access goes through one lock or queue, and write that down next to the conformance.
