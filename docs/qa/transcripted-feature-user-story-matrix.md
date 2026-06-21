# Transcripted Feature User Story QA Matrix

Canonical source for this pass:

- Local CSV: `docs/qa/transcripted-feature-user-story-matrix.csv`
- Google Sheet: https://docs.google.com/spreadsheets/d/1mXEEADKjbl5VBmzSui4w2lKGUNMEvYWO2X9eCVVcCFY/edit
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

- Stories tracked: 80
- Status counts after this pass: `PASS` 27, `RETEST PASS` 3,
  `UNKNOWN` 50, `FAIL` 0, `BLOCKED` 0
- Full automated QA: `PASS` at `/tmp/transcripted-qa-bench/qa-20260621-152351/qa-report.md`
- UI automation: initial `INCOMPLETE` at `/tmp/transcripted-qa-bench/qa-20260621-152717/qa-report.md`,
  then `PASS` at `/tmp/transcripted-qa-bench/qa-20260621-153239/qa-report.md`
  after clearing a stale idle Transcripted instance from another worktree.
- Live capture smoke: `PASS` via `bash run-live-capture-smoke.sh --skip-build`;
  real mic + system-audio capture started/stopped and wrote scratch files on
  this Mac.
- Private corpus validation: `PASS` at `/tmp/transcripted-qa-bench/qa-20260621-153651/qa-report.md`;
  reports stay local/redacted.
- Packaged no-publish smoke: `PASS` at `/tmp/transcripted-qa-bench/qa-20260621-153703/qa-report.md`;
  this did not cut, tag, notarize, publish, update appcast, update Homebrew,
  deploy, or release anything.
- Live sidecar preview security retest: `PASS` in commit `5f827929`; focused
  preview-server tests, dependency rebuild, app build, full fast tests,
  integration smoke, and diff hygiene all passed.
- Agent config merge edge cases: `PASS`; focused `AgentMCPConnector` and
  `ClaudeDesktopIntegrationInstaller` suites passed and cover malformed config,
  backups, stale commands/helpers, idempotent reconnects, and preserved servers.
- Focused deterministic proof added for custom dictionary, filler cleanup,
  saved daily Markdown, retained audio cleanup/retention boundaries, model cache
  management, and single-instance lock behavior. These remain good candidates
  for later manual UX feel checks, but their code contracts passed.
- MCP and local diagnostics proof added: `Tools/TranscriptedMCP`,
  `Tools/TranscriptedCaptureKit`, reliability packet, log rotation, and support
  diagnostics focused suites passed without uploading private capture content.
- Imported-audio bad-input handling: `PASS`; focused
  `MeetingImportedAudioPreparerTests` passed 58/58 and proves unsupported
  file/folder/date-policy handling without needing private audio content.
- Import-audio entry/transcription proof was refreshed while staying
  `UNKNOWN`: `UIAutomationSurfaceContractTests` passed 233/233,
  `HomeImportAudioActionTests` passed 6/6, and
  `MeetingImportedAudioPreparerTests` passed 58/58. Native file-picker and real
  imported-media UX proof are still missing, so these rows did not move green.
- Secure input fallback proof was strengthened while staying `UNKNOWN`:
  `AccessibilityBridgeTests` passed 12/12, `ClipboardRestoringTextPasterTests`
  passed 58/58, `bash build.sh --no-open` passed, the full fast suite passed
  10561/10561, and Codex review was clean. Real secure/password-field behavior
  still needs manual or UI automation proof.
- Meeting prompt false-positive proof was strengthened while staying `UNKNOWN`:
  `MeetingPromptDetectorTests` passed 57/57, `MeetingPromptHeuristicsTests`
  passed 58/58, and `SyntheticMeetingPromptTests` passed 71/71. Real
  media-playback/browser non-call/native app negative cases still need manual
  or UI automation proof.
- Update actions during active capture: `RETEST PASS` in commit `2d622a78`;
  menu/settings update actions now stay disabled during dictation, meeting
  recording, meeting processing, or speaker-review work. Focused policy tests,
  app build with launch smoke, full fast tests, UI bench, and Codex review all
  passed.
- Cross-feature mutual exclusion: `RETEST PASS` in commit `36fea2d0`;
  dictation start now refuses to begin while meeting recording, meeting
  processing, or speaker-review work is active. Focused policy tests, app build
  with launch smoke, full fast tests, and Codex review all passed.
- Storage relocation edge cases: `RETEST PASS` in commit `4e57b5da`;
  capture-library selection now prepares the chosen root, meeting folder, and
  dictation folder before saving the preference, rejects unusable destinations,
  preserves the current library on failed replacement, refreshes Settings state,
  and alerts the user. Focused storage tests, app build with launch smoke, full
  fast tests, diff hygiene, Codex review, and Local lane review all passed.
- Manual/hardware gaps still `UNKNOWN`: real meeting-app volume behavior,
  Bluetooth/AirPods route churn, sleep/wake during active capture, secure-field
  pasteback behavior, Transcripted-vs-corpus comparison, summary quality/feel,
  and real Sparkle install/update prompt behavior.
- Initial logistics issue: first full bench failed because dependencies were
  missing/stale; `bash build-deps.sh --force` rebuilt them, and the retest
  passed.
- Non-blocking local artifact warning: current local artifact validation found
  no JSON sidecars and some older local transcripts without `capture_quality`.
  This was recorded as local-state warning, not a code regression from this
  matrix pass.

The CSV is the row-level tracker. This Markdown file exists so repo readers can
find the canonical matrix and understand the status contract quickly.
