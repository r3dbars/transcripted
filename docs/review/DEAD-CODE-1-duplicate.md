# DEAD-CODE-1: duplicate of UI-SETTINGS-A-4

DEAD-CODE-1 and UI-SETTINGS-A-4 identify the same abandoned Home feedback
sheet and its legacy model chain. They share one implementation proposal:
[PR #2613](https://github.com/r3dbars/transcripted/pull/2613), at commit
`eb7c3f6633169fc41e1a2c62b85d4c9f627618f5`.

That proposal removes the unused sheet, its models, the unused preview feedback
target, and the orphan reference hash with its obsolete tests. Preview target
construction still runs on audited main `8a38235`; its value has no product
consumer. This is not a claim that every legacy instruction is unexecuted.

The current Report issue action opens the retained Feedback composer. That
composer, Email Support, Send Diagnostics and their consent behavior remain
outside the removal. The separate contextual builder finding
OBSERVABILITY-6 has its own scope.

This document records the duplicate without proposing a second code removal.
The implementation is an open draft, not a landed fix. Review its actual diff
and validation in #2613; accepting this disposition alone does not resolve the
code finding or provide additional app or hardware proof.
