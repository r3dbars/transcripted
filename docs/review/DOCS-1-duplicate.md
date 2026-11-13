# DOCS-1: duplicate window-coverage description

DOCS-1 identifies the same stale window-scan description covered by the
SCRIPTS-DEV-10 proposal in [PR #2381](https://github.com/r3dbars/transcripted/pull/2381),
at commit `76229f7ea11c41b85f898e27ba1e8bbc6dffe21d`, based on audited main
`8a38235eef00816a79daa1324387a21ef880204d`. SCRIPTS-DEV-10 remains that PR's primary report ID.

The report marks DOCS-1 fixed within the pending broad audit proposal. That
report status is not evidence of a merge. The extracted #2381 proposal corrects
the root, UI and Overlay agent guides and the Writing design record: the static
scan belongs to `scripts/dev/check-window-inventory.py`, which checks `Sources/`
against `.agents/window-inventory.json`; `Tests/OverlayScreenSharePrivacyTests.swift`
builds real windows and checks their sharing behavior. The fifth changed file,
the Settings guide, addresses overlapping stale pin-list wording.

This document records DOCS-1 separately without repeating the correction.
TESTS-FAST-7 has its own overlapping disposition in
[PR #2622](https://github.com/r3dbars/transcripted/pull/2622).
The historical source-text inventory and the separate DOCS-2 and DOCS-11 scopes
are not additional fixes claimed here.

At verification, #2381 is open and unmerged. Accepting this disposition alone
does not apply its documentation patch, change the window checks or establish
new app, screen-sharing or hardware proof. Review the proposed correction and
its validation in #2381; there is one shared correction, not another implementation.
