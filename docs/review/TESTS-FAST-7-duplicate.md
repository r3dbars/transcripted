# TESTS-FAST-7: duplicate source-pin and window-coverage guidance

TESTS-FAST-7 overlaps SCRIPTS-DEV-10: both identify stale lists of source-pinned
files and the claim that `OverlayScreenSharePrivacyTests` scans `Sources/UI`.
The shared correction is proposed in [PR #2381](https://github.com/r3dbars/transcripted/pull/2381),
at commit `76229f7ea11c41b85f898e27ba1e8bbc6dffe21d`, based on audited main
`8a38235eef00816a79daa1324387a21ef880204d`. SCRIPTS-DEV-10 remains that PR's primary report ID.

The five-file proposal updates the root, UI, Overlay and Settings agent guides
and the Writing design record. It replaces hand-kept pin lists with the source-pin
checker's resolved targets. It distinguishes the static window inventory scan
in `scripts/dev/check-window-inventory.py` over `Sources/` from the real-window
sharing checks in `Tests/OverlayScreenSharePrivacyTests.swift`.

The report labels TESTS-FAST-7 partly fixed: its historical inventory wording
was already addressed in the broad audit proposal, while the Writing plan and
stale pin lists remained. This disposition does not repeat those edits or
reclassify the historical inventory. Related DOCS-1 records the overlapping
scanner description; the separate DOCS-2 and DOCS-11 scopes are not claimed here.

This document gives TESTS-FAST-7 its own reviewable disposition, not a second
implementation. At verification, #2381 is open and unmerged; neither its proposed
correction nor the report's earlier partial fix is claimed as landed. Accepting
this document alone does not apply #2381 or provide new test, app, screen-sharing
or hardware proof. Review the implementation diff and its validation in #2381.
