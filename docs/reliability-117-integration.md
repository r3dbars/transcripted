# 1.1.77 reliability integration ledger

Combined source candidate for 1.1.77. It's a merge of four open PRs on one
frozen base. It is **not** a green candidate: the merges preserve each PR's
ancestry, but the combined tree hasn't run hosted CI or the full bench yet.
The source version stays 1.1.76. No bump, tag, publish, dispatch, signing, or
notarization happened here.

Branch: `codex/reliability-117-integration-20261113`

## Inputs

Base (frozen): `5a72538a991a9fba22d0a0375db3e2e4f32dcb91`. Remote `main`
matched it when this was assembled (2026-11-13), so no drift.

| Order | PR | Branch | Exact head |
| --- | --- | --- | --- |
| 1 | #2679 | `claude/intfix-release-ci` | `c86e8a330e31885c32f9265293c32bd1ce22c159` |
| 2 | #2664 | `claude/fix-package-model-provenance-record` | `9634b08e0f85f4c8a605ba7da14dc7b9307af273` |
| 3 | #2686 | `codex/fix-meeting-completion-hang-20261113` | `6ca853d5329beafd21ba8d586ebfb33c8dc6168a` |
| 4 | #2687 | `fix/telemetry-permission-snapshot` | `3649b54354095a2cd05ae8bd07d1329c26f8eafb` |

All four heads are based on the frozen base, and all four are ancestors of the
integration branch. Each was merged with a normal `--no-ff` merge; the original
PR branches and `main` were not touched.

## What each brings

- **#2679** Release Candidate's prep-branch diff guard accepts exactly
  `Info.plist` and the generated
  `Tools/TranscriptedMCP/Sources/TranscriptedMCP/BuildVersion.swift`, then runs
  `bump-release-version.py --check` after the guard. A contract suite pins this.
- **#2664** `build-beta.sh` writes `build/Transcripted-model-manifest.json`
  (`scripts/release/write-model-manifest.py`). Release Candidate fails if the
  manifest is missing (`test -s`), uploads it with the unsigned build, copies it
  into the verification job, and keeps it in the final candidate artifact. A
  contract suite pins each of those steps.
- **#2686** Speaker naming cleanup runs off the main actor
  (`SpeakerNamingCoordinator.swift`), with a responsiveness test.
- **#2687** Telemetry permission context reads from an in-memory snapshot
  (`TelemetryPermissionSnapshot.swift`), with tests and the run-tests source
  list entry.

## Conflicts

One, mechanical, in the #2664 merge:

- `Tests/CIWorkflowContractTests.swift`: #2679 and #2664 each appended a new
  `runSuite` after the same existing suite. Both suites were kept unchanged:
  #2679's version-bump guard suite first, then #2664's model-manifest suite.
  There was no overlap in what they assert.

`.github/workflows/release-candidate.yml`, `docs/release-packaging.md`, and
`scripts/README.md` auto-merged; their hunks touch different steps and lines.
The merged workflow has both the two-file guard and the manifest
fail/upload/copy/retain steps. #2686 and #2687 merged with no conflicts.

## Checks run on the combined tree

- `bash check.sh quick`: PASS (Linux-safe repo checks, 114 passed, includes test
  shape, the compiled MCP version check, and the 1.1.77 bump dry run).
- `python3 scripts/release/test-write-model-manifest.py`: PASS (7 tests).
- `python3 scripts/release/bump-release-version.py --check`: PASS.
- `test-mcp-publish-tools.py`, `test-register-sentry-release.py`,
  `test-signed-candidate-cli.py`: PASS.
- `Tests/CIWorkflowContractTests.swift` compiled on its own with
  `Tests/TestHelpers.swift`: 90 of 90 assertions pass, including both new
  release suites.

Not run here: the app build, `run-tests.sh`, `swift test`, smokes, and the full
bench. The parent dispatches hosted CI and the full bench on this head.

## Per-PR evidence and limits

- **#2679**: CI passed on its own head.
- **#2664**: on its original CI the app-build step compiled, but the 10k Home
  benchmark came in at 844.5 against a 750 limit. Independent triage of
  identical code inputs points to a runner outlier. One retry hasn't started
  yet because spm-tests was still running.
- **#2686**: full CI and full bench PASS on its own head.
- **#2687**: normal CI and the full bench are still pending.
- Sentry issue 6T isn't closed by #2687: other `UserDefaults` access on main
  still exists.
- Manual, hardware, and signed-candidate behavior is not proved for any of
  these, alone or combined.
