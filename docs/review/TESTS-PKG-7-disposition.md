# TESTS-PKG-7: constructed source-root scan in the shared guard proposal

TESTS-PKG-7 identifies a package test that scans `Sources` as text without being
counted by the source-text guards. SCRIPTS-DEV-11 describes the same constructed
root gap and duplicate scan. The shared correction is proposed in
[PR #2498](https://github.com/r3dbars/transcripted/pull/2498), at commit
`cbdc067eb3b660d721589e898238e919b67ac16f`, based on audited main
`8a38235eef00816a79daa1324387a21ef880204d`. SCRIPTS-DEV-11 remains its primary
report ID; this dedicated package-test record adds no second implementation.

The proposal makes the test-shape matcher recognize exact bare `"Sources"` as
well as `"Sources/..."`. Its owned Python fixture covers constructed/direct roots,
comments, similar names, resources and refusal to grandfather a new source read
with `--shrink`. This is still a literal-path heuristic, not general Swift dataflow
analysis, and it does not claim to change every source-text guard.

It removes only `AudioTapInstallGuardTests.testEveryProductionInstallTapIsGuarded`,
the duplicate source-scanning method. The three actual guard/error behavior tests
remain byte-identical. The existing audio-tap lint rule and all baselines remain
unchanged; the rule already checks guarded installation, intervening queue hops
and nil formats across its Sources/Tools scope.

At verification, #2498 is an open, unmerged draft. Its recorded Python/static
validation is distinct from its canonical 15 PASS and three guarded FAIL results
(exit 3: full fast suite, integration smoke and root package tests). Native/audio
and retained XCTest behavior were not executed. Those are existing PR results,
not checks rerun for this disposition. Accepting this record does not apply the
patch, certify hardware behavior or establish a landed fix. Review the actual
proposal and bounded validation in #2498; no Swift/native/audio run occurred here.
