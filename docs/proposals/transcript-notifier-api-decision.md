# Transcript notifier API: owner decision

Status: **unselected proposal** for CORE-REST-6. This document retires no API,
adds no notification integration, and changes no permission or product behavior.

## Verified source boundary

Reviewed main: `8a38235eef00816a79daa1324387a21ef880204d`. These observations
come from tracked source and caller review, not execution or an external
consumer inventory.

- No tracked type conforms to the public, main-actor-isolated
  [TranscriptNotifier](../../Sources/TranscriptedCore/Protocols/TranscriptNotifier.swift)
  protocol. Its three requirements cover saved transcripts, failed transcription,
  and requesting notification permission.
- The [app's manager construction](../../Sources/Meeting/MeetingSessionController+State.swift)
  and [speaker-evaluation host](../../Tools/SpeakerEvalHarness/Sources/speaker-eval-harness/MeetingLab.swift)
  omit the optional notifier argument. Tracked tests that explicitly pass it
  pass `nil`. The claimed concrete `UserNotificationsNotifier` does not exist
  in this repository.
- The absence of an app conformer does not make this a private implementation
  detail. [TranscriptionTaskManager](../../Sources/TranscriptedCore/Pipeline/TranscriptionTaskManager.swift)
  exposes a public optional initializer argument and public notifier property.
  Its [public permission forwarder](../../Sources/TranscriptedCore/Pipeline/TranscriptionTaskManager+CleanupPaths.swift)
  delegates to that object; no tracked host calls that forwarder.
  Three public [TranscriptSaver](../../Sources/TranscriptedCore/Storage/TranscriptSaver.swift)
  overloads also accept a notifier.
- The callback plumbing is reachable when an embedder supplies a conformer.
  The saver schedules a saved callback on the main actor after a successful
  save. The manager's [committed side effects](../../Sources/TranscriptedCore/Pipeline/TranscriptionPipelineRunner+SideEffects.swift)
  deliver its saved callback; failure paths invoke the failure hook.
  A `nil` notifier makes these hooks no-ops. This review does not establish
  that out-of-repository consumers are absent.

The factual header correction accompanying this worksheet removes the claim
that the app supplies a concrete implementation and describes permission
requests as an embedder contract. Public declarations and runtime bodies stay
unchanged.

## Choices for the owner

All choices remain unchecked.

- [ ] **A — Retain the optional public seam.** Keep the API for embedders while
  accurately documenting that current in-repository hosts do not supply it.
  This does not add system notifications to the app.
- [ ] **B — Retire the seam through an approved compatibility change.** Inventory
  supported external consumers and choose a migration or deprecation contract
  before removing the protocol, initializer arguments, saver parameters,
  permission forwarder, or callback plumbing. App caller absence alone does
  not establish that removal is compatible.
- [ ] **C — Revise the intended API or notification scope.** Specify another
  outcome before implementation.

Owner selection: **pending**. The public seam is preserved while that decision
is unresolved. This worksheet does not choose notification presentation,
sounds, permissions, or event payload policy.

## Future proof after a choice

This plan is unexecuted, not a passing integration test or an approved runnable
fixture. For retention or migration work, compile a small external-style
consumer against the actual public protocol and affected manager/saver APIs.
Use a memory-only conformer to observe callbacks; do not request real
notification permission. Audit every constructor, injected storage path,
stats dependency, and cleanup boundary before any behavioral execution.

For retirement, first document consumer coverage and expected source breaks,
then check the approved migration against those consumers. A public-symbol
compile check does not prove callback timing, delivery, app notification UX,
or native permission behavior. No model, database, permission store, native
app, or harness was executed for this proposal.
