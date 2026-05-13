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

Match the style of existing tests in this repo. Prefer behavior tests over
implementation-detail tests.

## Repo Test Rules

- For root fast tests, use the lightweight `runSuite` style under `Tests/`.
- Register every new root fast test file in `Tests/FastTests.manifest`.
- For `Sources/TranscriptedCore/` package seams, prefer
  `Tests/TranscriptedCoreTests/` and run `swift test`.
- For `Sources/Meeting/` or `Sources/TranscriptedCore/`, also run
  `bash run-integration-smoke.sh`.
- After Swift source changes, run `bash build.sh` and `bash run-tests.sh`.
- For tests-only changes, run the narrowest useful check first, then the repo
  check that owns that test surface.

## Safety

- Keep fixtures local and privacy-safe.
- Do not include raw transcript text, audio references, meeting titles, speaker
  names, emails, tokens, absolute file paths, or real device names.
- Do not add broad refactors just to make tests easier.
- If the code has no safe test seam, explain the blocker and suggest the
  smallest seam to add.
