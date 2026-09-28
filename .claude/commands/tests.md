# Test Generator

Generate focused tests for the function or file the user names.

Input: `$ARGUMENTS`

## Task

Read the target file or recently changed code. Find the new or under-tested
function, type, or behavior with the clearest test seam. Add 3-5 useful tests:

- one happy path
- two edge cases
- one failure or guardrail case
- one regression case when the surrounding history shows a known bug

Match the style of existing tests in this repo. Follow "Test rules" in
`Tests/README.md`: each test checks a named promise through inputs and outputs.

Before writing, state the promise each test protects in one plain sentence and
use it as the `runSuite` (or test) name. Draft from the promise and the public
signature, not the function body. After writing, break the code on purpose
(flip the condition, drop the call), confirm the test goes red, and restore it.

## Repo Test Rules

- For root fast tests, use the lightweight `runSuite` style under `Tests/`.
- Root fast tests are discovered by convention, not a manifest: `Tests/FooTests.swift`
  must expose exactly one top-level `testFoo()` entry function. The runner fails
  before compiling if that entry function is missing or duplicated.
- For `Sources/TranscriptedCore/` package seams, prefer
  `Tests/TranscriptedCoreTests/` and run `swift test`.
- For `Sources/Meeting/` or `Sources/TranscriptedCore/`, also run
  `bash run-integration-smoke.sh`.
- After Swift source changes, run `bash build.sh --no-open` and `bash run-tests.sh`.
- For `Sources/Meeting/` or `Sources/TranscriptedCore/`, run `bash build-deps.sh --force` first.
- Never read `Sources/` as text and never assert on wall-clock elapsed time.
  `python3 scripts/dev/check-test-shape.py` fails on both. If the only way to
  reach the behavior is a source-text check, stop and propose the seam instead
  (pull the decision into a small function, inject a clock or a fake).
- A flaky test gets fixed or benched in `Tests/quarantine.txt` the same day.
- No Swift toolchain (Linux/cloud)? Write the test, say it's uncompiled, and let CI run it.
- For tests-only changes, run the narrowest useful check first, then
  `bash check.sh` for the rest of the mapped checks.

## Safety

- Keep fixtures local and privacy-safe.
- Do not include raw transcript text, audio references, meeting titles, speaker
  names, emails, tokens, absolute file paths, or real device names.
- Do not add broad refactors just to make tests easier.
- If the code has no safe test seam, explain the blocker and suggest the
  smallest seam to add.
