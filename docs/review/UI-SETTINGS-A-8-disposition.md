# UI-SETTINGS-A-8: row-identity facet of the shared capture-list proposal

UI-SETTINGS-A-8 concerns position-based day-list row identity. UI-SETTINGS-A-1
concerns lazy layout of variable-height day sections and the reported Load More
freeze. These are distinct facets of the shared capture-list proposal in
[PR #2333](https://github.com/r3dbars/transcripted/pull/2333), at commit
`60b5ac37b7bae32502241824059f897973e0b2b9`, based on audited main
`8a38235eef00816a79daa1324387a21ef880204d`. UI-SETTINGS-A-1 remains that PR's
primary report ID; this document gives A8 its own disposition.

On audited main, the outer row `ForEach` in `HomeDayGroupedList` uses enumerated
position as its identity, while each child row separately has the capture ID.
The proposal makes the `ForEach` use `HomeDayGroupedRows` values identified by
the capture ID. Its helper returns `id(item)` rather than the offset and retains
the existing divider rule. The same PR separately changes the day-section
`LazyVStack` to `VStack`; that layout change is not another name for the identity fix.

The proposal's `HomeDayGroupedRowsTests` checks identity when appending older
rows, prepending a new capture and combining day sections, plus item/divider
outputs. Its PR body reports 13 passing identity assertions and the earlier
nine-failure baseline. Those are existing recorded claims, not tests rerun for
this disposition, and they do not prove native scroll or view-rebuild behavior.

At verification, #2333 is an open, unmerged draft. It still requires the macOS 26
native scroll scenario and visual confirmation; the cause of the reported
freeze remains a hypothesis. Its canonical proof records safety-guard refusals,
and its native executable was compiled but not run. Accepting this document
does not apply #2333, resolve that freeze report or add a second implementation.
Review the actual patch and bounded evidence in #2333. No new app, native,
account-isolation or hardware proof is claimed here.
