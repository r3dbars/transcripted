# Harness automation: decision pending

Owner worksheet for TESTS-INFRA-2. No option is selected. This document
changes no runner, CI policy, product flow or test execution.

## Current source evidence

The report names three standalone Swift harnesses. On reviewed main
`8a38235eef00816a79daa1324387a21ef880204d`:

| Harness | Runner | Current automation |
| --- | --- | --- |
| `Tests/Integration/HomeMeetingDeletion/ReservationSmoke.swift` | `scripts/dev/test-home-deletion-reservation.sh` | A manual command is documented in `Tests/Integration/HomeMeetingDeletion/README.md`; no automatic compilation caller was found. |
| Post-call discard harness (retired in integration) | None | Frozen PR #2512 removes the unreferenced harness and runner; no new caller is proposed. |
| `Tests/UI/CallAppHintHarness.swift` and `CallAppHintHarnessIsolation.swift` | `scripts/dev/run-call-app-hint-harness.sh` | The matrix selects shell syntax and `scripts/dev/test-call-app-hint-harness.py`; these offline wrapper contracts do not compile or execute the actual Swift page harness. |

The Call App isolation helper separately has fast-test coverage in
`Tests/CallAppHintHarnessIsolationTests.swift`; that does not compile or
exercise the page harness.

The blanket claim that none has a matrix rule is therefore too broad. The
remaining question is whether actual Swift compilation/execution should be
automatic, or whether a deliberately manual check is the supported contract.

The Home deletion runner requires existing test-enabled debug Core artifacts
and external dependencies, and refuses missing or stale inputs. Its documented
scope is helper/Core reservation and synthetic Trash/restore behavior, not
native Home UI or real Trash permissions. The UI harness runners compile app
sources and use an alternate entry point; compilation and UI execution are
different checks.

[Frozen PR #2512](https://github.com/r3dbars/transcripted/pull/2512) retires
the unused post-call harness in this integration candidate. This worksheet
still selects no automation option for the retained harnesses. The retirement
is candidate source state, not evidence of main promotion or native execution.

## Choices for Justin

- [ ] **A — Keep selected harnesses manual.** Name each retained command,
  prerequisites, supported isolation, proof boundaries and owner in the test
  guide. Explicitly accept that ordinary PRs will not catch Swift API drift.
- [ ] **B — Add automatic compilation checks.** Select the retained harnesses
  and their source dependencies in the matrix and an existing macOS CI job.
  Budget the additional compilation work. A successful compile is not UI,
  interaction or real-device proof.
- [ ] **C — Add execution in reviewed isolation.** First audit each fixture's
  state and cleanup, then select appropriate dedicated helper or UI checks.
  Preserve separate native/hardware proof requirements and report failures
  or skips honestly.
- [ ] **D — Revise the retained harness set before choosing automation.**

The choice may differ by harness. It must not silently turn every Settings or
Overlay edit into a whole-app harness build, or describe syntax/offline guard
success as a passing Swift interaction test.

## Proof before implementing the choice

Verify current source lists and all callers, test selection and failure
propagation, artifact freshness and owned cleanup. Review any defaults,
library, Trash, permission or window reachability before executing a harness.
A temporary HOME alone is not macOS account isolation. Actual UI launches need
the repository's approved isolation; helper checks need an independently
reviewed state boundary.

No harness, native UI, Core package test, preference store or real user file was
executed or changed for this worksheet. Historical passing notes in the
integration README are not a current run on this head.
