# Meeting transcription language

Settings → Model includes a **Meeting language** picker for meetings and
imported recordings. Dictation is unchanged.

- **Auto** is the default. With Whisper, the pipeline checks up to three
  non-overlapping, speech-candidate windows from across the available recording
  tracks before transcribing speaker segments. If there are at least two
  windows and every sampled window confidently agrees, every segment uses
  that language. Weak, conflicting, or
  insufficient evidence keeps Whisper's automatic decoding behavior.
- An explicit language, such as **Finnish**, tells Whisper to use that language
  for every segment. It does not translate speech and does not eliminate every
  possible recognition error or hallucination.
- Parakeet V3 retains its built-in multilingual decoding. Parakeet V2 remains
  English-only. These engines cannot enforce an exact spoken-language choice,
  so explicit choices require selecting a Whisper model. The picker does not
  silently change models or download one.

The choice is captured when recording or import begins. Changing Settings
affects subsequent jobs, not existing captures or queued work. Import journals,
recording journals, and failed jobs preserve that choice across relaunch and
retry. Older records without the field retain Auto. Saved retranscription
preserves the original requested choice; Auto is evaluated again rather than
promoting an earlier automatic guess into an explicit instruction.

Retry and saved retranscription use the currently selected model, as before.
If a capture has an explicit language but you have since selected Parakeet,
select a Whisper model before retrying. The app preserves the language and
shows an actionable error instead of silently ignoring it, switching models,
or downloading a model. Restoring Auto in Settings only affects new captures;
it does not erase a saved explicit choice.

The detected result describes bounded acoustic evidence, not proof that every
speaker in a long recording uses the same language. Recordings with language
switches outside the sampled regions still need representative multilingual
evaluation. No audio or recognized text is sent to a language-detection service.

## Implementation and verification

The app owns the preference and picker. Core owns immutable
`TranscriptionLanguageSelection` / `TranscriptionLanguageContext` values, sample
selection, and job/persistence plumbing. `MeetingSTTAdapter` and `STTRouter`
pass context per call; there is no shared mutable language on the speech engine.
Whisper's pinned detector returns log probabilities; the confidence policy
requires a finite probability of at least 0.80 and agreement across all sampled
windows. This is a conservative starting policy, not a calibrated accuracy claim.

Automated coverage includes sampling bounds, silence/short audio, disagreement,
invalid probabilities, per-job isolation, explicit segment options, legacy
decoding, journals, retry retention, and additive Markdown metadata. Real
Finnish, English-introduction, and multilingual accuracy comparisons are a
separate acceptance gate; passing fake-engine tests is not model-quality proof.
