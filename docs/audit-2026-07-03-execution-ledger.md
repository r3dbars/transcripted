# Transcripted Audit Execution Ledger - 2026-07-03

Source audit: `.claude/worktrees/blissful-lichterman-515852/docs/audit-2026-07-03.md`

Audit baseline: `2025c31e` on `claude/blissful-lichterman-515852`.
Ledger bootstrap PR: #1386, reviewed and merged into `main` at
`dff36a546564351a16cf3ee02537bda2099d6328`.

Scope: all non-`[FIXED]` findings from the audit. Open findings still need code-level
claim verification before fixing because the audit notes that open items were not all
independently re-verified.

Summary: 53 non-fixed findings: 13 high, 30 medium, 10 low. No critical findings remain
open in the source audit.

Last GitHub refresh: 2026-07-03 15:05 CDT.

## Ledger Status

| PR | Purpose | Review verdict | Merge status | Checks | Remaining proof |
| --- | --- | --- | --- | --- | --- |
| [#1386](https://github.com/r3dbars/transcripted/pull/1386) | Bootstrap this execution ledger | Reviewed; accepted | Merged to `main` at `dff36a546564351a16cf3ee02537bda2099d6328` | Repo Hygiene success; Swift CI `build-and-test` success; hardware smokes skipped | None for docs; implementation findings still open |

## Unmapped PR Watchlist

These PRs are live Transcripted implementation work but are not linked to an audit finding
until the PR body or reviewer explicitly claims coverage.

| PR | Title | Current status | Tests/review | Manual proof |
| --- | --- | --- | --- | --- |
| [#1387](https://github.com/r3dbars/transcripted/pull/1387) | Fix dictation audio-engine rebuild loop on Bluetooth/AirPods routes | Open; non-draft; GitHub merge state `CLEAN` | Repo Hygiene success; Swift CI `build-and-test` success; hardware smokes skipped; no review verdict yet | Real AirPods hardware verification still pending |

## Test Profiles

- `T-app`: `bash build.sh --no-open` and `bash run-tests.sh`.
- `T-meeting`: `bash build-deps.sh --force`, `bash build.sh --no-open`, `bash run-tests.sh`, and `bash run-integration-smoke.sh`.
- `T-core`: `T-meeting` plus `swift test` when the shared core package seam changes.
- `T-ui`: `T-app` plus focused UI/AX/manual smoke for the affected overlay, menu, or settings flow.
- `T-hotkey`: `T-app` plus Accessibility permission and physical-hotkey manual proof.
- `T-storage`: `T-meeting` plus custom-library/unmounted-volume fixture proof.
- `T-import`: `T-meeting` plus imported-audio/video fixture proof.
- `T-perf`: mapped build/tests plus a focused before/after perf or large-fixture proof.
- `T-sidecar`: `T-meeting` plus live meeting sidecar/preview stale-state proof.
- `T-ledger`: `git diff --check`; docs-only PR review.

## Ledger

| # | Sev | Finding | Subsystem | Assigned worker lane | PR URL | Review verdict | Merge status | Status | Tests | Remaining proof needed |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 5 | High | Self-stopped meeting capture is not surfaced; overlay still looks live | Meeting capture | Codex - meeting capture | TBD | Not reviewed | No implementation PR | Open; verify first | T-meeting | Internal stop fixture, partial-audio preservation, user-visible error |
| 6 | High | System-audio writes silently stop after 10 write errors | Core audio | Codex - core audio | TBD | Not reviewed | No implementation PR | Open; verify first | T-core | Forced system write failure, health/frontmatter/error proof |
| 7 | High | Stop during dictation device recovery destroys preserved audio | Dictation recovery | Codex - dictation recovery | TBD | Not reviewed | No implementation PR | Open; verify first | T-app + manual device-change | Route-change stop proof that recovered audio transcribes |
| 9 | High | Queued transcription jobs starve after synchronous rejection | Meeting queue | Codex - meeting queue | TBD | Not reviewed | No implementation PR | Open; verify first | T-meeting | Queue fixture with too-short job followed by valid job |
| 10 | High | SCK system-audio stream death is not detected mid-recording | Core audio | Codex - core audio | TBD | Not reviewed | No implementation PR | Open; verify first | T-core + manual SCK failure | Stream delegate/watchdog proof and surfaced failure |
| 11 | High | Mic-only recovery retries become permanently untranscribable | Meeting pipeline | Codex - meeting pipeline | TBD | Not reviewed | No implementation PR | Open; duplicate root with #36 | T-core | Mic-only failed-queue retry produces transcript or honest retry state |
| 12 | High | Unavailable capture library deletes failed-meeting queue entries | Data integrity | Codex - storage/data | TBD | Not reviewed | No implementation PR | Open; verify first | T-storage | Unmounted-root fixture keeps queue entries without persisting loss |
| 13 | High | Capture-library relocation discards queued failed meetings | Data integrity | Codex - storage/data | TBD | Not reviewed | No implementation PR | Open; verify first | T-storage | Relocation fixture rewrites or heals failed-queue audio paths |
| 15 | High | Menubar paste-last cancels clipboard restore | Clipboard/paste | Codex - clipboard | TBD | Not reviewed | No implementation PR | Open; verify first | T-ui | Menubar paste restores prior clipboard after popover close |
| 16 | High | Hardcoded Cmd+V keycode breaks non-QWERTY layouts | Clipboard/paste | Codex - clipboard | TBD | Not reviewed | No implementation PR | Open; verify first | T-ui + manual layout | Dvorak/non-QWERTY paste proof or layout-translation unit proof |
| 18 | High | Quit during transcription lacks confirmation; queued imports deleted | Meeting/import queue | Codex - meeting queue | TBD | Not reviewed | No implementation PR | Open; overlaps #35 | T-import | Quit gate and queued import preservation proof |
| 19 | High | Dictation is blocked during background meeting/import transcription | Dictation/meeting concurrency | Codex - dictation concurrency | TBD | Not reviewed | No implementation PR | Open; verify first | T-meeting | Dictation during background transcription is allowed or copy is honest |
| 20 | High | Paste-back reports success before proving text landed | Clipboard/paste | Codex - clipboard | TBD | Not reviewed | No implementation PR | Open; verify first | T-ui + manual paste targets | Swallowed-paste path downgrades to copied or preserves clipboard |
| 22 | Medium | System-wide event tap runs on main run loop | Hotkeys/perf | Codex - hotkeys | TBD | Not reviewed | No implementation PR | Open; duplicate root with #30 | T-hotkey + T-perf | Dedicated tap-thread proof and no hotkey regression |
| 23 | Medium | CoreAudio device enumeration blocks main actor during route churn | Speech/audio perf | Codex - speech perf | TBD | Not reviewed | No implementation PR | Open; verify first | T-app + manual device churn | Timed/off-main enumeration proof under route churn |
| 24 | Medium | Failed-meeting audio archiving copies large WAVs on main actor | Meeting perf | Codex - meeting perf | TBD | Not reviewed | No implementation PR | Open; verify first | T-meeting + T-perf | External-library large-copy proof off main actor |
| 25 | Medium | Meeting transcription keeps whole tracks in RAM with 2x transient | Core pipeline perf | Claude review + Codex fix | TBD | Not reviewed | No implementation PR | Open; high-risk refactor | T-core + T-perf | Large-meeting memory profile and transcript equivalence |
| 26 | Medium | Live transcript drawer rebuilds full transcript per partial update | Overlay perf | Codex - UI perf | TBD | Not reviewed | No implementation PR | Open; verify first | T-ui + T-perf | Long-meeting drawer update profile |
| 27 | Medium | Meeting prompt detector queries Calendar every 20 seconds forever | Prompt perf | Codex - prompts | TBD | Not reviewed | No implementation PR | Open; verify first | T-app + T-perf | Cached calendar snapshot and invalidation proof |
| 28 | Medium | Live sidecar rewrites preview HTML on every append | Live sidecar perf | Codex - sidecar | TBD | Not reviewed | No implementation PR | Open; verify first | T-sidecar + T-perf | Long live transcript append I/O proof |
| 29 | Medium | Home re-parses all dictation day files on refresh/load-more | Home perf | Codex - home/history | TBD | Not reviewed | No implementation PR | Open; verify first | T-app + T-perf | Large-history cache fixture proof |
| 30 | Medium | Event tap reads UserDefaults-backed bindings per keystroke | Hotkeys/perf | Codex - hotkeys | TBD | Not reviewed | No implementation PR | Open; duplicate root with #22 | T-hotkey + T-perf | Cached bindings and hotkey-change invalidation proof |
| 31 | Medium | Accessibility grant after launch does not retry event-tap install | Hotkeys/permissions | Codex - hotkeys | TBD | Not reviewed | No implementation PR | Open; verify first | T-hotkey | Grant-after-launch retry proof |
| 32 | Medium | Fn advisory is conflated with real hotkey registration failure | Hotkeys/wake | Codex - hotkeys | TBD | Not reviewed | No implementation PR | Open; verify first | T-hotkey | Wake recovery uses install error, advisory remains UI-only |
| 33 | Medium | Missed keyUp while tap is disabled leaves push-to-talk recording | Hotkeys/PTT | Codex - hotkeys | TBD | Not reviewed | No implementation PR | Open; verify first | T-hotkey | Tap-disabled release reconciliation proof |
| 34 | Medium | System wake discards buffered dictation audio | Dictation recovery | Codex - dictation recovery | TBD | Not reviewed | No implementation PR | Open; verify first | T-app + manual wake | Wake interruption preserves/transcribes buffered audio |
| 35 | Medium | Imported-audio jobs are discarded on quit | Import queue | Codex - import queue | TBD | Not reviewed | No implementation PR | Open; overlaps #18 | T-import | Active and queued imports survive or warn on quit |
| 36 | Medium | Mic-only failed meetings become non-retryable | Meeting pipeline | Codex - meeting pipeline | TBD | Not reviewed | No implementation PR | Open; duplicate root with #11 | T-core | Mic-only retry path stays retryable and produces output |
| 37 | Medium | Mic device-switch recovery loses timeline alignment | Core audio | Claude review + Codex fix | TBD | Not reviewed | No implementation PR | Open; verify first | T-core + manual device switch | Gap calculation and merged-track alignment proof |
| 38 | Medium | Concurrent transcript rewrites can lose updates or resurrect stale files | Data integrity | Claude review + Codex fix | TBD | Not reviewed | No implementation PR | Open; verify first | T-meeting | Concurrent restyle/rename/speaker-update fixture proof |
| 39 | Medium | Auto Enter sends Return/Cmd+Enter without target or paste verification | Dictation paste | Codex - clipboard | TBD | Not reviewed | No implementation PR | Open; verify first | T-ui | App-switch and clipboard-manager proof |
| 40 | Medium | Unmounted custom library is recreated under `/Volumes` | Storage | Codex - storage/data | TBD | Not reviewed | No implementation PR | Open; verify first | T-storage | Unmounted-volume proof avoids phantom path and warns user |
| 43 | Medium | Capture pill still lacks Remind me soon | Meeting prompts | Codex - prompts | TBD | Not reviewed | No implementation PR | Partial; timeout fixed, action open | T-ui | Pill button wired to reminder backoff; no timeout regression |
| 44 | Medium | Detected prompts are suppressed while prior meeting transcribes | Meeting prompts | Codex - prompts | TBD | Not reviewed | No implementation PR | Open; verify first | T-meeting | Back-to-back-call prompt proof during transcription |
| 45 | Medium | Video meeting recordings cannot be imported | Import UX | Codex - import | TBD | Not reviewed | No implementation PR | Open; verify first | T-import | MP4/MOV with audio track imports; no-audio movie errors honestly |
| 46 | Medium | Warm-up/recovery speech is not captured; PTT release cancels silently | Dictation start | Codex - dictation recovery | TBD | Not reviewed | No implementation PR | Open; verify first | T-app + manual warm-up | PTT warm-up UX proof; buffered-audio proof if implemented |
| 47 | Medium | Five-minute dictation cap has no warning and suppresses paste | Dictation UX | Codex - dictation UX | TBD | Not reviewed | No implementation PR | Open; verify first | T-ui | Warning/countdown and active-target paste/save-only proof |
| 48 | Medium | Actionable error overlays cannot be dismissed | Overlay UX | Codex - overlay UI | TBD | Not reviewed | No implementation PR | Open; verify first | T-ui | Escape/close/action behavior proof |
| 49 | Medium | Dictation overlay AX placement flips against wrong screen | Overlay placement | Codex - overlay UI | TBD | Not reviewed | No implementation PR | Open; verify first | T-ui + manual multi-monitor | Multi-display focused-field placement proof |
| 50 | Medium | Recording overlay Combine sinks freeze in modal/menu tracking modes | Overlay UX | Codex - overlay UI | TBD | Not reviewed | No implementation PR | Open; verify first | T-ui | Modal/menu tracking proof that timer/levels continue |
| 51 | Medium | Meetings-first users get wrong permission warnings/readiness | Permissions UX | Codex - settings/permissions | TBD | Not reviewed | No implementation PR | Open; verify first | T-ui | Meetings-first onboarding/settings readiness proof |
| 52 | Medium | Storage Reset to Default has no confirmation | Storage UX | Codex - storage/settings | TBD | Not reviewed | No implementation PR | Open; verify first | T-storage | Reset flow offers copy/switch/cancel and preserves visibility |
| 53 | Medium | System Audio Recording status cache is not revalidated | Permissions UX | Codex - settings/permissions | TBD | Not reviewed | No implementation PR | Open; verify first | T-ui + manual permission | Grant/revoke status refresh proof |
| 54 | Low | Meeting overlay pushes layout at 5 Hz for duration label | Overlay perf | Codex - UI perf | TBD | Not reviewed | No implementation PR | Open; verify first | T-ui + T-perf | Whole-second duration collapse proof |
| 55 | Low | Clipboard snapshot materializes all pasteboard data on main actor | Clipboard perf | Codex - clipboard | TBD | Not reviewed | No implementation PR | Open; verify first | T-ui + T-perf | Large clipboard paste latency proof |
| 56 | Low | PTT debounce can swallow a held-key start | Hotkeys/PTT | Codex - hotkeys | TBD | Not reviewed | No implementation PR | Open; verify first | T-hotkey | Rapid PTT tap-then-hold fixture/manual proof |
| 57 | Low | Dictation audio is memory-only; crash loses up to 5 minutes | Dictation recovery | Claude review + Codex fix | TBD | Not reviewed | No implementation PR | Open; larger design | T-app + manual crash/relaunch | Temp audio journal and recovery proof |
| 58 | Low | Live sidecar append errors are swallowed | Live sidecar | Codex - sidecar | TBD | Not reviewed | No implementation PR | Open; verify first | T-sidecar | Consecutive write-failure state/banner proof |
| 59 | Low | Meeting failure feedback auto-hides and truncates detail | Meeting UX | Codex - overlay UI | TBD | Not reviewed | No implementation PR | Open; verify first | T-ui | Persistent/wrapping failure state and Home retry visibility proof |
| 60 | Low | Speaker-review window steals focus when transcription completes | Speaker review UX | Codex - settings/people | TBD | Not reviewed | No implementation PR | Open; verify first | T-ui | Non-activating/deferred review proof |
| 61 | Low | Capture pill primary-display placement and app-wide Return hijack | Prompt UI | Codex - prompts | TBD | Not reviewed | No implementation PR | Open; duplicate root with #63 plus fixed #14 | T-ui | Display placement proof; key handling should already be fixed upstream |
| 62 | Low | Hotkey presses during dictation transcription window are swallowed | Dictation UX | Codex - dictation UX | TBD | Not reviewed | No implementation PR | Open; verify first | T-hotkey | Visible toast or queued-start proof during drafting/transcribing |
| 63 | Low | Capture pill appears on `NSScreen.main`, not working display | Prompt UI | Codex - prompts | TBD | Not reviewed | No implementation PR | Open; duplicate root with #61 | T-ui | Mouse/frontmost-screen placement proof |

## Cleanup Recommendations

- Collapse duplicate roots before opening fix PRs: #11/#36, #22/#30, #61/#63, and likely #18/#35.
- Keep risky data-integrity or pipeline refactors small and independently reviewed: #25, #37, #38, and #57 should get a Claude design/review pass before implementation.
- Prefer focused PRs by subsystem over one mega-fix: meeting capture, storage/data integrity, hotkeys, clipboard/paste, prompts, import queue, overlay/settings UX, and perf.
- Keep deterministic tests, mocked/proxy proof, telemetry, and manual hardware/install proof separate. Missing manual proof should stay `UNKNOWN`, not green.
