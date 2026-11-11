# BUILD-CI-14: duplicate fast-runner lock comment

BUILD-CI-14 identifies the stale cache-lock comment in
`scripts/entrypoints/run-tests.sh`: it says 30 minutes, while
`acquire_cache_lock` checks `find` with `-mmin +60`. The threshold is already
60 minutes; this finding calls for a comment correction, not a behavior change.

That correction is proposed in [PR #2448](https://github.com/r3dbars/transcripted/pull/2448),
at commit `bfc3b9bac0a7763804877735335a7d475e061bc2`, based on audited main
`8a38235eef00816a79daa1324387a21ef880204d`. TESTS-INFRA-11 remains that PR's
primary report ID: its broader three-comment scope also removes the obsolete
stable-runner-path rationale and replaces a stale literal object count with
`APP_SOURCES` membership. The actual runner uses a PID-suffixed filename.
Executable logic and source lists are unchanged by that proposal.

The report lists the same comment edits under both IDs within the pending
broad audit proposal. This dedicated BUILD-CI-14 disposition records the overlap
without repeating the patch or claiming another implementation. The unrelated
source-list addition in the broad proposal is excluded from #2448.

At verification, #2448 is an open, unmerged draft. Accepting this document alone
does not apply the correction or establish cache-lock concurrency, fast-suite,
app or hardware proof. Review its actual diff and validation in #2448, including
the explicitly refused fast-suite execution. No landed fix is claimed here.
