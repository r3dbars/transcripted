# Obsidian formatting API: owner decision

Status: **unselected proposal** for CORE-REST-13. This worksheet changes no
writer, public API, preference, reader, or existing captured transcript.

## Verified source boundary

Reviewed main: `8a38235eef00816a79daa1324387a21ef880204d`. These are source
observations, not executed format tests or an external consumer inventory.

- The [app's task-manager construction](../../Sources/Meeting/MeetingSessionController+State.swift)
  explicitly supplies plain `TranscriptFormatOptions()`. Its comment explains
  that the old `enableObsidianFormat` preference was retired; a leftover true
  preference must not reactivate it. The
  [CLI import writer](../../Tools/TranscriptedCLI/Sources/TranscriptedCLI/MeetingImportWorkflow.swift)
  also uses the default false value. No tracked production caller explicitly
  enables Obsidian metadata.
- [TranscriptFormatOptions](../../Sources/TranscriptedCore/Storage/TranscriptFormatOptions.swift)
  is nevertheless public. Its `includeObsidianMetadata` property and initializer
  argument allow explicit opt-in, defaulting to false. `withAudioSources`
  preserves the flag. The public manager's format-options provider can carry
  it to the formatter as well.
- The public [formatter](../../Sources/TranscriptedCore/Storage/TranscriptFormatter.swift)
  and [saver](../../Sources/TranscriptedCore/Storage/TranscriptSaver.swift)
  accept those options. With explicit opt-in, the formatter adds `tags`,
  `aliases`, and `cssclasses`, wraps confirmed named body speakers in wiki
  links, and adds a linked participants section when named speakers exist.
  These branches remain reachable by a library consumer.
- Tracked tests enable the option, including the
  [imported-audio golden test](../../Tests/TranscriptedCoreTests/StorageTests/MeetingMarkdownGoldenTests.swift).
  They specify output compatibility; their existence does not prove current
  app usage. This review does not establish that external consumers are absent.
- Existing-file compatibility is separate from producing new Obsidian output.
  [RetroactiveSpeakerUpdater](../../Sources/TranscriptedCore/Speaker/RetroactiveSpeakerUpdater.swift)
  detects the existing format and its
  [rewrite helper](../../Sources/TranscriptedCore/Speaker/RetroactiveSpeakerUpdater+TranscriptRewrite.swift)
  preserves the relevant link style. The
  [capture format contract](../capture-format.md) also retains legacy-reader
  compatibility. Removing the opt-in writer would not justify deleting these
  readers or changing existing files.

The accompanying format-document correction qualifies its former blanket
claim that new transcripts never contain this output. The app and CLI remain
plain; the public Core opt-in remains available.

## Choices for the owner

All choices remain unchecked.

- [ ] **A — Retain Core's explicit opt-in.** Keep plain app and CLI output,
  accurately document the library option, and preserve its formatting contract.
  This does not restore the old setting.
- [ ] **B — Retire the new-output option through an approved compatibility
  change.** Inventory supported library consumers and choose a migration or
  deprecation contract before removing the public property/initializer argument
  and writer branches. Preserve legacy reading and speaker-rename behavior.
- [ ] **C — Revise the intended compatibility or output scope.** Specify a
  different outcome before implementation.

Owner selection: **pending**. There is no automatic API deletion or selected
format policy in this proposal.

## Future proof after a choice

This plan is unexecuted, not an approved runnable fixture. Exercise the actual
formatter with explicit false and true options, synthetic utterances and
speaker mappings, and fixed dates. Verify tags, confirmed-name wiki links,
participants, and plain defaults separately. Compile an external-style
consumer against any retained or migrated public API. Do not construct the
app, load models, or use standard preferences for a pure formatting check.

Separately retain tests for reading and renaming synthetic legacy files under
owned temporary roots. Audit constructor and cleanup paths before running
those cases. A writer retirement does not authorize rewriting user files or
dropping legacy parsing. No test, model, database, preference store, native
app, or harness was executed for this worksheet.
