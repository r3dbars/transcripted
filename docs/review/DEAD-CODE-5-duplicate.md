# DEAD-CODE-5: duplicate unused paste-retry telemetry finding

DEAD-CODE-5 and OBSERVABILITY-7 identify the same test-only telemetry wrapper,
`DictationPasteRetryTelemetry`, and event `dictation_paste_retry_completed`.
The shared removal proposal is [PR #2447](https://github.com/r3dbars/transcripted/pull/2447),
at commit `5d0dc3d7e11ca3cea4bd0003d547d139d65413a2`, based on audited main
`8a38235eef00816a79daa1324387a21ef880204d`. OBSERVABILITY-7 remains its primary ID.

On audited main the wrapper has no production caller. The six-file proposal
removes it, its private outcome mapper and three wrapper-only tests, alongside
its analytics registry, documentation and fast-source-list entries. This is
one removal proposal. It does not remove current paste or Paste again behavior,
change a live outcome, or add an event or off-device payload.

The existing PR records independent review and 31 mapped source-tree checks
before an identical-source commit, including analytics checks and MCP tests.
That is attributed historical source-tree evidence, not exact-head hosted CI
or a test run for this document. Its broad-fast safety refusal remains FAIL,
and speed verification skipped while the owner's app was running. Real paste,
native keyboard, live analytics delivery and performance remain unverified.

At verification, #2447 is an open, unmerged draft. This dedicated disposition
adds no second implementation. Accepting it does not apply that proposal or
establish a landed fix or runtime proof. Review the actual patch and bounded
evidence in #2447; no paste or live analytics delivery was exercised here.
