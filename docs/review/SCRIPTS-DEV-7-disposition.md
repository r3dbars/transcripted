# SCRIPTS-DEV-7: Companion matrix mapping in the shared portable-check proposal

SCRIPTS-DEV-7 identifies the missing test-matrix rule for Companion changes.
The mapping correction is proposed in
[PR #2373](https://github.com/r3dbars/transcripted/pull/2373), at commit
`db82f431fba8e3f23deaa4c18c465e6740a3d10d`, based on audited main
`8a38235eef00816a79daa1324387a21ef880204d`. TOOLS-MCP-18 remains its primary
report ID for missing Companion-check coverage. BUILD-CI-13 records the related
CI-lane omission. This dedicated script-mapping record adds no second code fix.

The proposal maps `Tools/TranscriptedCompanion/**` and `script/build_and_run.sh`
to source validation, `test-package.py` and `test-launcher.py`. It also includes
those checks in the existing Repo Hygiene Linux-check lane, replaces the two
fixtures' macOS-specific temporary-root argument with the OS default, and updates
the Companion guide's automated/manual distinction. These are shared changes,
not independent implementations for each report ID.

`package.py --validate-only` returns before the Mac build/package path. The
package and launcher unit fixtures check unrelated-file rejection and preservation
of a running app through the wrapper's refusal. They do not prove installed
package handshake, Codex discovery, preview UI or live capture. The original
PR's recorded mapping and CI successes were not rerun for this disposition.

At verification, #2373 is open and unmerged. Accepting this document does not
apply its matrix rule or establish installed-host/native/account-isolation proof.
Review the actual five-file proposal and bounded validation in #2373. No package
installation, app launch, host-client session or live capture was performed for
this record, and no landed fix is claimed.
