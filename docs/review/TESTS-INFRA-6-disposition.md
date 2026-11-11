# TESTS-INFRA-6: validation coverage and ordering in the shared full gate

TESTS-INFRA-6 identifies `check.sh full` claiming to run Swift CI's checks in
the same order while omitting required validation. The shared correction is
proposed in [PR #2388](https://github.com/r3dbars/transcripted/pull/2388), at commit
`7eeaef0fadc463c99d309f6b41bec6fa3aa634ab`, based on audited main
`8a38235eef00816a79daa1324387a21ef880204d`. TOOLS-CLI-14 remains its primary
report ID for the Live/CLI-mode omissions. This dedicated test-infrastructure
record describes overlapping coverage and ordering claims, not another code fix.

The proposal's full arm adds the two Speakers smokes, Live package tests, three
CLI mode transitions and the performance budget. Its header/help/root guide
promise the same validation steps, not a single order across parallel CI jobs.
Inherited CLI mode flags are cleared, and a current launch receipt is required
for the budget. An ownership/reset failure blocks the dependent build and budget
even when independent checks continue under `--keep-going`.

The included command-fake fixture checks the real gate in an owned copy:
coverage/order, mode cleanup, fail-stop, keep-going and stale-receipt controls.
Its fake commands do not execute native suites or establish end-to-end CI parity.
BUILD-CI-2 and SCRIPTS-DEV-4 are separate overlapping report records referring
to this same proposal; they do not imply additional executable implementations.

At verification, #2388 is open and unmerged. Its recorded canonical proof still
includes a deliberately refused fast suite (FAIL, exit 3), and native full-mode
proof remains pending approved isolation/CI. A missing current receipt must
still fail the required budget. Accepting this document does not apply #2388,
clear those proof gaps or establish a landed fix. Review the actual patch and
bounded evidence there. No full gate, native harness or broad bench was run
for this disposition.
