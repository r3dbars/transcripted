# TESTS-INFRA-4: verdicts for the ten unlisted-script candidates

This record covers the ten candidates behind the report's `linux-checks.sh`
"not run" note at audited main `8a38235eef00816a79daa1324387a21ef880204d`.
The note is an advisory filename/self-test discovery heuristic, not proof that
every candidate is an independent safe test suite.

| Candidate | Disposition | Evidence and execution limit |
|---|---|---|
| `scripts/release/freeze-legacy-appcast.py` | Add `--self-test` to the required list | Its explicit temporary-root fixture exercises freeze/mark helpers, not the real release command. Only the self-test variant belongs in the portable lane. |
| `scripts/release/mark-appcast-critical.py` | Add `--self-test` to the required list | Fixture writes stay temporary; the tracked appcast is read and round-tripped into a temporary copy. Only the self-test variant belongs in the portable lane. |
| `scripts/dev/lint_rules/test_fixed_sleep_sync.py` | Exclude lint-rule modules from this note | This is a `RULE`/`check` implementation loaded by `lint.py`; its good/bad fixtures and history proofs belong to that runner. |
| `scripts/release/test-staged-sparkle-update.py` | Exclude this exact hosted harness path | It downloads release assets, starts a local HTTP server, launches and updates an app. Do not promote it into portable checks or execute it here. |
| `scripts/hillclimb/test_hillclimb.py` | Keep the hill-climb CI change in #2371 | Covered by its proposed top-level discovery; no new execution in this record. |
| `scripts/hillclimb/test_hc_proc.py` | Keep the hill-climb CI change in #2371 | The subprocess-group/watchdog suite is discovered there; no new execution here. |
| `scripts/hillclimb/test_lab_control.py` | Keep the hill-climb CI change in #2371 | Lab-control stand-in and injected-reader tests are discovered there; no native/defaults run here. |
| `scripts/hillclimb/benches/test_dictation_stop.py` | Keep the hill-climb CI change in #2371 | The fake bench-adapter suite is discovered in its benches pass; no dictation run here. |
| `scripts/hillclimb/benches/test_meeting_import.py` | Keep the hill-climb CI change in #2371 | The fake CLI/owned-fixture suite is discovered there; no import/model run here. |
| `scripts/hillclimb/benches/test_speaker_autoeval.py` | Keep the hill-climb CI change in #2371 | The fake-harness suite is discovered there; no real speaker harness run here. |

[PR #2371](https://github.com/r3dbars/transcripted/pull/2371), head
`278da976701ceb63e3c40e75a4177802c6d5d13b`, proposes the existing
`hillclimb.py --self-test` entry in the Linux runner. At verification it is open
and unmerged; its recorded local/Ubuntu results are not rerun or claimed as
landed here. The six hill-climb note entries remain visible until that wiring
is integrated. They are not six new fixes in this PR.

The broad audit PR #2336 proposes the two release registrations and discovery
exclusions. This dedicated extraction leaves its other changes alone. The staged
harness exclusion uses an exact path, so a similarly named unrelated test still
appears. No release implementation, appcast, workflow or hill-climb code changes.

These are source-based execution boundaries; immutable validation receipts belong
to the dedicated PR. A passing owned fixture does not establish a real Sparkle
upgrade, release safety, native/account isolation or hardware proof.
