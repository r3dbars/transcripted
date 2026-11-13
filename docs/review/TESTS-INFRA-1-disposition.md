# TESTS-INFRA-1: pinned offline release-health fixture drift

TESTS-INFRA-1 reports that pinned release-health commands still select the
archived 1.1.75 inputs after tracked release metadata advances to 1.1.76.
SCRIPTS-OPS-B explicitly identifies the same correction. Its implementation is
proposed in [PR #2660](https://github.com/r3dbars/transcripted/pull/2660), at commit
`9caa4aa20a315e209b4116dae633781cf2b82905`, based on audited main
`8a38235eef00816a79daa1324387a21ef880204d`. SCRIPTS-OPS-B remains its primary
report ID; this dedicated infrastructure record adds no second executable fix.

The four-line proposal advances the explicit appcast/GitHub metadata pair in
`.agents/test-matrix.yml`, `scripts/ops/transcripted-qa-bench.sh`, `scripts/README.md`
and `docs/release-packaging.md` to the existing archived 1.1.76 fixtures. The two
accompanying version descriptions advance with those commands. Checker logic,
fixtures, Info/cask metadata and the frozen legacy feed remain unchanged.

Its owned offline proof uses 35 bound files, synthetic Git history/refs/tags,
explicit automation/feed/metadata/report paths and network-denied subprocesses.
The actual 1.1.76 strict invocation exits 0 with score 100 and zero findings;
the 1.1.75 negative exits 1 with exactly `appcast-version-mismatch`,
`cask-version-mismatch` and `github-release-asset-digest`. This is selective static
fixture and synthetic-history proof, not an audit of real history or live health.

At verification, #2660 is an open, unmerged draft. Its canonical result is FAIL:
16 PASS, three guard FAIL (quick bench, QA package tests and full fast tests),
one preflight orchestration SKIPPED and beta packaging BLOCKED for operator input.
Standalone preflight/verifier exit 0; the verifier applies no app check, and the
outer full bench is refused with exit 3. These are #2660 results, not reruns here.
This record changes no release surface and establishes no landed, native, live
release-health or full-bench proof. Review the actual proposal before acceptance.
