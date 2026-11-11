# CORE-REST-5: decide when a transcription may teach speaker identity

Status: owner decision pending. This record selects no learning policy.

At audited main `8a38235eef00816a79daa1324387a21ef880204d`, system-speaker
resolution runs inside `transcribeMultichannel`, before the runner's transcript
save. `TranscriptionPipeline+SystemSpeakerIdentity.swift` creates new/spin-off
profiles and writes surviving matches through `SpeakerStore.addOrUpdateSpeaker`.
`TranscriptionPipeline+MicDiarization.swift` has corresponding writes for split
local speakers. Here, the comments saying write-back is deferred mean after
cluster fusion, not after the transcript commits.

The concrete database performs those mutations synchronously on its queue.
An accepted update changes appearance metadata; a positive blend can also change
voiceprints/exemplars. A zero blend excludes incoming embedding weight and exemplar
updates, but still normalizes/writes the existing embedding and updates confidence,
count and last-seen; a successful update also calls contribution recording.
New profiles can be inserted. The runner's later save failure or
cancellation rollback is not a transaction encompassing these earlier mutations.
Thus a run that reaches identity writes and later fails can leave speaker-state
changes. This does not mean every cancelled run or retry necessarily writes.
The evidence is static ordering and database code, not a reproduced failed run.

| Policy | User-visible consequence | Design work before implementation |
|---|---|---|
| Learn during processing | A failed or cancelled transcript can still influence future identification | Make that behavior intentional and define retry deduplication/appearance counting |
| Learn only after transcript commit | Failed or cancelled work before the chosen commit point teaches nothing | Stage stable identities and learning deltas; define the exact commit point and crash recovery |
| Learn after explicit review | Automatic transcription does not by itself approve identity learning | Define pending profiles, review/discard behavior and the retained evidence needed for approval |

Select the policy and separately decide how retries count appearances. A simple
move of writes below Markdown save would not establish an atomic commit across
Markdown, SQLite, audio and pending review. Restoring whole old profile snapshots
could also overwrite newer legitimate learning; rollback ownership and concurrent
jobs need an explicit design. Existing identity matches and naming thresholds
should not be changed implicitly while fixing transaction ordering.

For the selected patch, use an injected recording store and an owned temporary
database. Cover success, cancellation before/after identity resolution, save
failure, replacement/retry of the same capture, new-profile creation, zero-blend
matches and failure after the selected commit point. Prove the chosen appearance
counts and identity state after reopen. Native-model quality is separate proof;
never use the owner's speaker database to exercise rollback or cleanup.

This worksheet changes no learning, retry, storage or deletion behavior. No
models, database, audio pipeline or app were executed. The issue stays unresolved
until the owner selects a policy and the implementation and validation are done.
