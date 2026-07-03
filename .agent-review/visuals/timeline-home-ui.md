# Timeline Home UI Evidence

Date: 2026-07-03

Scope: Phase 4 UI-only Timeline Home preview.

Preview gate:

- Environment: `TRANSCRIPTED_TIMELINE_HOME_PREVIEW=1`
- UserDefaults: `timeline-home-preview-enabled`
- Default: off, so the current Home remains the normal user-facing surface.

Visual pass:

- Added compact timeline canvas, day navigation, live status card, detail panel,
  and category tokens.
- The canvas uses the planned 4 AM day boundary and 60 px/hour scale.
- The sample cards include activity, meeting, dictation, and idle states.
- No screenshot was captured in this run because `build.sh --no-open` could not
  compile the app without rebuilding missing dependency artifacts, and
  `build-deps.sh --force` failed on local disk/temp state.

Verification:

- `swiftc -typecheck -parse-as-library -target arm64-apple-macos14.0 Sources/UI/Timeline/*.swift`
- `python3 scripts/dev/check-build-source-lists.py`
- `bash run-tests.sh --filter TimelineHomePresentationTests`
- `bash run-tests.sh`
