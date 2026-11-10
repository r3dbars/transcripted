# Speaker merge Undo: decision pending

Owner worksheet for audit item CORE-SPEAKER-1. No option is selected. This
document changes neither the protected Speakers flow nor clip retention.

## Current source behavior

- `Sources/Meeting/SpeakerSettingsStore.swift` calls the clip transfer before
  both reviewed-voice and manual merges. After the identity merge commits, its
  callback attempts to delete the absorbed person's clips in the preferred and legacy
  directories.
- `Sources/TranscriptedCore/Speaker/SpeakerClipExtractor.swift` preserves an
  existing target clip. If the target has none, it copies the source clip to
  the target under ordered persist locks and returns the copied WAV hash.
- That hash currently protects rollback when the identity merge fails. It is
  not persisted for a later successful merge's Undo.
- `SpeakerSettingsStore.unmergeMostRecent` delegates to the database.
  `Sources/TranscriptedCore/Speaker/SpeakerProfileProvenance.swift` restores
  database snapshots and provenance in a transaction; it does not restore
  sample files. The restored person can therefore lack their old sample,
  while the kept person can retain an inherited sample from the mistaken
  merge. An existing target sample is not overwritten by the transfer.
- `Sources/TranscriptedCore/Speaker/SpeakerVoiceprintMigration.swift` also
  looks for clips keyed by absorbed profile IDs. Keeping those files would
  affect available migration evidence, not just card playback.

These are source findings. No real speaker database, sample playback, merge,
Undo or voiceprint migration was exercised for this worksheet.

## Decisions for Justin

- [ ] Preserve absorbed samples while a merge is undoable, and make Undo
  restore sample ownership as well as database identity. This retains audio
  that today's successful merge attempts to delete. Its lifetime and deletion rules
  must be decided before implementation.
- [ ] Keep today's immediate sample deletion after a successful merge. A
  separate approved design must explain the limited sample restoration in
  Undo and handle an inherited sample after a mistaken merge.
- [ ] Request another design before choosing either behavior.

If preserving samples is approved, the remaining choices are unselected:

- How long is Undo supported, and when are held samples deleted?
- How should Delete person, automatic pruning and older merge histories
  interact with held samples? Coordinate this with CORE-SPEAKER-2.
- Store the transfer/ownership receipt in the merge database or an owned
  sidecar? Define migration and missing/corrupt-receipt behavior.
- If a newer sample replaced either person's sample, should Undo preserve
  the newer sample and report a partial restoration?

## Required implementation proof after a decision

Use only owned fixture directories and injected databases. Cover a target
with and without a sample, a later replacement, preferred/legacy locations,
failed merge, repeated Undo, missing receipt, partial file failure, and the
chosen cleanup policy. Keep ordered persist locking and receipt validation;
do not delete or overwrite a newer sample solely because its UUID matches.
Define recovery when file operations and the database transaction disagree.
Real playback and the protected merge/Undo flow still need app verification.
