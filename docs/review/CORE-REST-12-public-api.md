# CORE-REST-12: public API compatibility decision

Owner decision pending. All choices below are unchecked. This proposal records the API boundary before changing it.

The audit groups unused or test-facing Models and Storage API together. These declarations are still public on the reviewed main commit (`8a38235e`). Core is a separately built library and standalone package, so a repository search alone cannot establish whether someone imports those declarations elsewhere. The audit's partial-fix label is not evidence that removal has landed.

## Current candidates

| Public declaration | Current source and behavior |
| --- | --- |
| `DisplayStatus.statusText` | [DisplayStatus.swift](../../Sources/TranscriptedCore/Models/DisplayStatus.swift) maps each state to a string. |
| `DisplayStatus.icon` | The same file maps states to SF Symbol names. |
| `PipelineError.isRetryable` | [TranscriptionTypes.swift](../../Sources/TranscriptedCore/Models/TranscriptionTypes.swift) classifies pipeline errors. Existing tests explicitly assert that public classification. |
| `TranscriptionResult.persistentSpeakerIds` | The same file unions non-nil utterance profile IDs across both channels. Existing tests assert that public projection. |
| `TranscriptSaver.saveTranscript` overload without a `formatOptions` parameter | [TranscriptSaver.swift](../../Sources/TranscriptedCore/Storage/TranscriptSaver.swift) forwards to the convenience overload with default format options. |
| `TranscriptSaver.saveTranscript` overload with a `formatOptions` parameter and without a `transcriptionEngine` parameter | The same file forwards to the engine-taking implementation with `.parakeetLocal`. |

The direct test references are in [TranscriptionPipelineStateTests.swift](../../Tests/TranscriptedCoreTests/PipelineTests/TranscriptionPipelineStateTests.swift). They demonstrate current test use, not external adoption or a promise that every candidate is unused. Calls with default arguments also need overload resolution checked before changing the save conveniences. Similar `isRetryable` members on other types are separate APIs.

## Decision to make

What compatibility commitment should these public Core declarations carry?

- [ ] Retain the current surface. Record which declarations are supported conveniences and keep their behavior covered.
- [ ] Deprecate selected declarations first. Choose replacements and a removal policy for each selected member before preparing annotations or removing it.
- [ ] Approve a deliberate breaking cleanup of selected declarations. Name the exact members and release boundary, then update every affected repository caller and test in this same issue's PR.

Selected members: **unset**. Compatibility commitment: **unset**. Replacement APIs and removal version: **unset**. No retention period or release number is assumed.

## Evidence needed for a code change

For each selected member, record a typed caller inventory across the app, CLI/tools, and package tests; identify any known external consumers; and explain the migration. Preserve the engine-taking save implementation and its output contract. Keep cleanup of unrelated private helpers in its own scope.

A follow-up implementation on this PR needs an independent full diff review and the mapped Core, standalone-package, and app checks at its exact head. Current tests were inspected as source only; no model, database, save, preference, or native runtime was invoked to prepare this decision.
