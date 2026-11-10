# Content-sharing boundary decision (DOCS-22)

Status: **Unselected — owner review required.** This worksheet proposes updates
to `docs/threat-model.md`; it does not change that reviewer map or `SECURITY.md`.
The source review uses main `8a38235eef00816a79daa1324387a21ef880204d`.

The current boundary table omits local Screen Memory, user-sent feedback and
the opt-in Write for Me preview. Describing their controls is not a judgment
that those controls are sufficient or that a finding should be excluded.

Owner choice:

- [ ] Approve the exact additions and qualifications below.
- [ ] Revise the boundary descriptions before changing the reviewer map.

Neither choice is selected. Existing finding criteria, severity guidance,
exclusions and accepted risks remain outside this proposed edit.

## Proposed boundary-table additions

Add these rows to the existing Trust boundaries table:

| Boundary | What crosses it | Control described by current source |
|---|---|---|
| Focused window → local Writing | Accessibility text or a screenshot recognized with OCR | Screen Recording permission, feature and focused-window gates, secure-input/app exclusions. Screen Memory holds snapshots in memory for local Autocomplete |
| Mac → Transcripted support endpoint | Feedback message, optional reply address, chosen screenshots, app version, and optional OS/build information with up to three bounded failure summaries (kind, stage and version) | Fixed HTTPS feedback endpoint. The user reviews the draft and presses Send. Capture-library files and raw app logs are not attached automatically |
| Mac → Claude through the user's signed-in `claude` CLI | Write for Me prompt: focused-window screenshot/text, matching saved-capture passages, and earlier dictation or writing examples | Developer Preview feature, off by default and invoked by the user. Separate from analytics/crash-reporting switches. Text scrubbing is best effort; it does not redact screenshot pixels |

## Proposed asset qualifications

In asset 1, replace only its final sentence with:

> Core capture and transcription stay local. Connected agents, optional Write
> for Me, and user-sent feedback have content-sharing paths described below.

Replace asset 3 with:

> **The user's other apps.** Transcripted can hold Microphone, System Audio
> Recording, Accessibility and Calendar permissions. Writing can also request
> Screen Recording. Paste-back types into other apps. Code that gets into the
> app inherits its granted permissions.

The remaining asset list and boundary rows are unchanged by this proposal.

## Source basis and limits

The Screen Memory permission and capture services establish the local window
boundary. `Sources/Support/NextSentencePreferences.swift` and the context,
controller, privacy, prompt and Claude files under `Sources/Writing/NextSentence/`
establish the preview's default, request inputs and text-only scrubbing.
`Sources/UI/Settings/FeedbackComposerModel.swift` gates sending on review;
`Sources/UI/Shared/FeedbackSubmissionClient.swift` defines the fixed HTTPS
destination and validates optional diagnostics and attachment limits.
The Settings caller derives failure summaries from `UsageHealthStore` metadata,
not raw app-log text.

No live TCC prompt, real-user capture, content transmission or provider
retention was tested. This is a source-backed disclosure proposal, not a
security scan verdict or approval of a new trust relationship. Recheck the
target and owning source before applying any approved text.
