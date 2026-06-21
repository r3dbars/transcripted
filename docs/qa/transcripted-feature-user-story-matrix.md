# Transcripted Feature User Story QA Matrix

Canonical source for this pass:

- Local CSV: `docs/qa/transcripted-feature-user-story-matrix.csv`
- Google Sheet: https://docs.google.com/spreadsheets/d/1Ho4tFA-_aAtJ2MMXlnbvk6y8mPaSl5Nh1_Itzt7yLjs/edit
- Created from current repo docs and source on 2026-06-21

Status meanings:

- `PASS`: deterministic and/or UI proof passed for that story.
- `FAIL`: a user-facing behavior failed.
- `UNKNOWN`: proof needs real UI, TCC, hardware, local corpus, or manual feel that was not completed yet.
- `BLOCKED`: the test could not run because of environment/tooling.
- `FIXED`: a scoped fix was made and awaits retest.
- `RETEST PASS`: the fixed behavior passed the same scenario after the fix.

Privacy boundary:

Do not put raw transcript text, audio references, meeting titles, speaker names,
emails, tokens, raw URLs, raw source apps, raw device names, identities, or
absolute private paths in the matrix. Use feature names, coarse permission
classes, test commands, and local evidence paths only.

Current inventory summary:

- Onboarding and permissions
- Menu bar and model status
- Dictation, triggers, pasteback, Auto Enter, custom dictionary, saved Markdown
- Home, recent captures, artifact open/reveal/rename/delete, failed meeting rows
- Meetings, prompts, live recording, import, retry, retained audio, transcript Markdown
- Speaker naming, People settings, retroactive updates
- Local meeting summaries
- Settings, storage, models, launch/login, quit safety
- Agent/MCP integration
- Support diagnostics
- Privacy, observability, updates
- Wake/audio recovery
- Build and QA scripts
- Additional gap rows from the Claude completeness review:
  imported-audio bad inputs, secure-field pasteback fallback, agent config merge
  edges, live-sidecar preview security, discard/save races, cross-feature mutual
  exclusion, storage relocation edge cases, retained-audio retention boundaries,
  meeting prompt false positives, permission deny/revoke paths, and update while
  recording.

Current proof summary:

- Stories tracked: 79
- Status counts after this pass: `PASS` 4, `UNKNOWN` 74, `BLOCKED` 1
- Full automated QA: `PASS` at `/tmp/transcripted-qa-bench/qa-20260621-152351/qa-report.md`
- UI automation: `INCOMPLETE` at `/tmp/transcripted-qa-bench/qa-20260621-152717/qa-report.md`
- UI blocker: existing Transcripted process from another worktree made menu bar
  accessibility targeting ambiguous; Apple Events automation also warned.
- Live/hardware blocker: live-capture permission-state had the same existing
  instance and automation warnings, so real mic, system-audio, meeting-app,
  Bluetooth/AirPods, sleep/wake, and human-feel proof stays `UNKNOWN`.
- Initial logistics issue: first full bench failed because dependencies were
  missing/stale; `bash build-deps.sh --force` rebuilt them, and the retest
  passed.
- Non-blocking local artifact warning: current local artifact validation found
  no JSON sidecars and some older local transcripts without `capture_quality`.
  This was recorded as local-state warning, not a code regression from this
  matrix pass.

The CSV is the row-level tracker. This Markdown file exists so repo readers can
find the canonical matrix and understand the status contract quickly.
