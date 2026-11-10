# Speaker deletion decision

**Proposed — owner decision pending.** All options below are unselected. This
worksheet approves no retention, schema, privacy-policy or behavior change.

## Current logical scope

The Settings Delete path removes the active saved voice profile, then attempts
to delete its review sample WAV and sidecar from the supported clip locations.
Clip-file removal errors are logged rather than propagated to the Delete result,
so successful profile removal does not guarantee sample-clip erasure. Saved
transcript content stays unchanged.

Local provenance and merge-recovery data can retain earlier voice representations
and names. That history supports reconstructing profiles when a merge is undone.
This describes the inspected code, not a new retention promise: see the
[Settings delete path](../Sources/UI/Settings/SpeakerPeopleSettingsViewModel.swift),
[clip removal](../Sources/TranscriptedCore/Speaker/SpeakerClipExtractor.swift) and
[merge recovery](../Sources/TranscriptedCore/Speaker/SpeakerProfileProvenance.swift).

## Unselected options

| Option | Intended Delete behavior | Consequence to decide |
| --- | --- | --- |
| A. Erase associated history | Remove the selected active profile/sample and the agreed associated voice/name history. | Affected merges can no longer restore it; define which histories are affected while preserving unrelated people's undo. |
| B. Retain recovery history | Remove the active profile/sample but explicitly retain local data needed for merge recovery. | State what remains in the Delete confirmation and decide its retention scope. |
| C. Bounded recovery window | Keep agreed recovery data for an owner-chosen interval, then erase it and disable affected undo. | Choose a duration and expiry behavior; no duration is inferred from recording or audio-retention settings. |

## Scope the owner needs to select

- **Related merges:** only merges into the deleted person, or every merge in
  which that person appears, including being merged into another surviving
  person? Unrelated people's undo must remain usable.
- **Automatic cleanup:** apply the same rule to automatically pruned unnamed
  voices and failed-enrollment rollback, or only an explicit Delete action?
- **Identifier-only records:** retain recovery/migration/statistical records
  after removing voice/name content, or remove or de-identify those too?

## Implementation and verification after a decision

Record the selected option and scope before changing code. Preserve saved
transcripts and meeting audio within this decision's scope. Implementation must
address dependent undo ordering, migration-resume markers and deletion failures;
a few extra DELETE statements alone do not establish the chosen guarantee.

Use owned synthetic profile/history/clip fixtures to check the selected logical
content removal, affected undo refusal, unrelated undo preservation, migration
resume and failure handling. No implementation or test result is established by
this worksheet. Physical overwrite, backups, other model stores and live UI
behavior require separately scoped verification before any broader erasure claim.
