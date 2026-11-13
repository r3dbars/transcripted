# SCRIPTS-DEV-4: full-gate commands and help in the shared proposal

SCRIPTS-DEV-4 identifies missing CI validation behind `check.sh full` and its
claim to run what Swift CI runs. The correction is proposed in
[PR #2388](https://github.com/r3dbars/transcripted/pull/2388), at commit
`7eeaef0fadc463c99d309f6b41bec6fa3aa634ab`, based on audited main
`8a38235eef00816a79daa1324387a21ef880204d`. TOOLS-CLI-14 remains its primary
report ID for the omitted Live and CLI build-mode lanes. This record addresses
the overlapping script/help scope, not another executable implementation.

The proposal adds the two Speakers smokes, Live package tests and three CLI
mode transitions to the full arm. It also adds the performance budget after the
app build, rather than documenting that budget as CI-only. The help, header and
root guide describe the same validation steps without claiming a global order
across CI jobs. Inherited CLI mode flags are cleared before the transitions.

The shared follow-up invalidates an older launch receipt and gates the dependent
build/budget on successful ownership/reset, even with `--keep-going`. A skipped
launch cannot satisfy the budget with a stale report. Its command-fake fixture
covers the actual gate's commands and failure controls without native execution.
BUILD-CI-2 and TESTS-INFRA-6 remain separate overlapping report records.

At verification, #2388 is open and unmerged. Its recorded canonical proof still
contains the fast-suite guard refusal (FAIL, exit 3); full native parity remains
pending approved isolation/CI. Accepting this dedicated disposition does not
apply the shared patch or prove the full gate works end to end. Review the
actual source and bounded validation in #2388. No full gate, native harness or
broad bench was executed for this document, and no landed fix is claimed.
