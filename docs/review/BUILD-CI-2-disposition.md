# BUILD-CI-2: full-gate coverage in the shared validation proposal

BUILD-CI-2 describes missing Swift CI validation in `check.sh full`.
The shared correction is proposed in [PR #2388](https://github.com/r3dbars/transcripted/pull/2388),
at commit `7eeaef0fadc463c99d309f6b41bec6fa3aa634ab`, based on audited main
`8a38235eef00816a79daa1324387a21ef880204d`. TOOLS-CLI-14 remains its primary
report ID, focusing on the omitted Live package and CLI build-mode lanes.
BUILD-CI-2 records the broader full-gate coverage facet, not another implementation.

The proposal adds the Speaker settings model and Speakers scroll smokes, Live
package tests, audio/meeting/retrieval CLI transitions and the performance budget.
It clears inherited CLI mode flags first. The budget requires the current build's
launch receipt; the gate invalidates an older receipt and blocks the dependent
build/budget after an ownership/reset failure, including with `--keep-going`.
The help and root guide describe matching validation steps rather than a global
CI order: Swift CI runs separate jobs in parallel.

SCRIPTS-DEV-4 describes overlapping omitted full-gate steps; TESTS-INFRA-6 also
includes the inaccurate same-order wording. They remain separate report records;
this disposition does not apply another copy of the executable fix.
The actual command-fake fixture exercises the real gate in an owned copy; its
coverage does not establish native end-to-end parity.

At verification, #2388 is open and unmerged. Its recorded canonical proof includes
an explicitly refused fast suite (FAIL, exit 3); native full-mode proof remains
pending approved isolation/CI, and a missing current launch receipt must still fail
the required budget. This disposition adds no runtime or CI-parity proof and does
not apply the patch. Review the source, fixture and bounded evidence in #2388.
No full gate, native harness or broad bench was executed for this document.
