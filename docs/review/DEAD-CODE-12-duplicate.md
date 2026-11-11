# DEAD-CODE-12: duplicate microphone-monitor compatibility shim

DEAD-CODE-12 and SUPPORT-2 identify the same obsolete compatibility file,
`ZoomMicrophoneSharingMonitor.swift`. Its removal is proposed in
[PR #2476](https://github.com/r3dbars/transcripted/pull/2476), at commit
`d0ecd3d2f52866ac40224beb1349664d623e87e1`, based on audited main
`8a38235eef00816a79daa1324387a21ef880204d`. SUPPORT-2 remains its primary ID.

The file contains a typealias to `CallAppMicrophoneSharingMonitor` and an
`isZoomRunning` forwarding property. On audited main, their executable use is
confined to one compatibility test. The four-file proposal removes the shim,
that obsolete test, the fast-runner source entry and the stale agent-guide
clause. The active monitor source and its other behavior tests are preserved.
This describes current-main references, not compatibility with every old branch.

The existing PR records a focused 48-assertion pass using injected application
readers and a private notification center. It also records broad-fast refusal
(FAIL, exit 3) and skipped speed verification while the owner's app was running.
Those are its recorded results; this document runs no monitor or native test.

This dedicated disposition adds no second removal. At verification, #2476 is an
open, unmerged draft. Accepting this document does not apply its cleanup or prove
microphone-sharing, capture, Bluetooth or full-suite behavior. Review that actual
proposal and its bounded evidence; no landed fix or new runtime proof is claimed.
