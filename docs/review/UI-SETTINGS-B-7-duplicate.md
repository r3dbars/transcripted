# UI-SETTINGS-B-7: duplicate unused speaker-name combo box

UI-SETTINGS-B-7 and UI-SETTINGS-A-10 identify the same unused
`RetainedDataSourceComboBox`. Its removal is proposed in
[PR #2490](https://github.com/r3dbars/transcripted/pull/2490), at commit
`eb382b08a833f95bde429102051bc616736bdb2a`, based on audited main
`8a38235eef00816a79daa1324387a21ef880204d`. UI-SETTINGS-A-10 remains that
PR's primary report ID; this document records B7 separately.

On audited main the combo box is constructed only by its dedicated lifetime
fixture. The proposal removes the class, that fixture, its fast-source entry and
the guide's leftover-combo-box clause. It preserves the historical inventory's
original conversion account while adding a factual fixture-retirement sentence.
This is one shared removal, not another code fix for B7.

The live `SpeakerNameAutocompleteField` uses an `NSTextField`; its implementation
and four production call sites are unchanged by #2490. The disposition does not
remove current naming, suggestion, review, rename, merge or delete surfaces.
The broad audit proposal's guide acknowledgement is not itself this removal.

At verification, #2490 is an open, unmerged draft. Its recorded final canonical
proof includes 25 PASS and an explicitly refused fast suite (FAIL, exit 3).
It records app compilation, but UI and speed verification were skipped; the
native naming interaction suite was not run. Those are the existing proposal's
bounded results, not tests rerun for this disposition. Accepting this document
does not apply #2490, establish current interaction proof or resolve a new crash.
Review the actual removal and validation there. No new UI, audio, model or
account flow was executed, and no landed fix is claimed.
