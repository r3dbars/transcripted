# BUILD-CI-13: Companion coverage in the shared portable-check proposal

BUILD-CI-13 identifies missing CI coverage for TranscriptedCompanion's portable
checks. The shared correction is proposed in
[PR #2373](https://github.com/r3dbars/transcripted/pull/2373), at commit
`db82f431fba8e3f23deaa4c18c465e6740a3d10d`, based on audited main
`8a38235eef00816a79daa1324387a21ef880204d`. TOOLS-MCP-18 remains its primary
report ID for the same missing Companion-check coverage. SCRIPTS-DEV-7 records
the related missing path-to-check mapping; that is a separate report record.

The proposal adds source validation and the package/launcher unit suites to
`scripts/dev/linux-checks.sh`, which the existing Repo Hygiene workflow invokes.
It also adds a test-matrix rule for Companion paths and `script/build_and_run.sh`.
The two unit fixtures use the OS temporary directory rather than `/private/tmp`.
The Companion guide distinguishes these portable checks from manual handshake,
Codex discovery and preview UI checks. No new Swift Tools package CI job is added:
the existing portable Repo Hygiene lane owns this coverage.

The source-validation branch returns before the Mac build/package path. The
unit fixtures check rejection of unrelated package files and the launch wrapper's
running-app refusal. Passing them does not establish installed plugin, host-client,
preview UI or live-capture behavior. The original PR records local and exact-head
Ubuntu successes; those results were not rerun for this disposition.

At verification, #2373 is open and unmerged. This dedicated BUILD-CI-13 record
adds no second implementation and does not apply the shared patch. Review the
actual source changes and bounded validation in #2373. No package installation,
app launch, host-client session or live capture was performed for this document;
no landed fix or native/account-isolation proof is claimed.
