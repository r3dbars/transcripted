# Expanded 1.1.77 integration: all 88 remaining PRs

The owner asked for every open PR to go into 1.1.77. This branch takes the
existing four-PR candidate and merges the other 88 PRs into it, so all 92 PR heads
end up as ancestors. It's a source candidate, **not** a green or qualified build.
Nothing was built, signed, notarized, tagged or published. The source version stays
1.1.76.

- Branch: `codex/reliability-117-all-prs-20261113`
- Base: the four-PR candidate `50ece593c43565cad197df03fe0df49477480e0b` (main
  `5a72538a991a` plus #2679 `c86e8a330`, #2664 `9634b08e0`, #2686 `6ca853d53`,
  #2687 `3649b5435`; all still ancestors).
- Last merge commit: `110464799038126d9142e5af625cb75f9350567c` (tree `c945e54db388eca3076c367efb786bcdafc03698`). The commit after it adds only this
  file, the manifest, and one doc-path fix.
- Machine-readable record: [`docs/expanded-117-integration-manifest.json`](expanded-117-integration-manifest.json),
  one entry per PR: frozen head, upstream base ref and SHA, review class, merge commit,
  conflict files, resolution.
- Input: the frozen remaining-PR manifest (sha256
  `a9def12d06319b04ebe39b871551f1642dd8377bd91a05fbc8d7abe28948e90b`, 88 entries). Each
  PR's `refs/pull/N/head` matched its frozen head when fetched.

Every merge is a normal `--no-ff` merge, authored and committed as `r3dbars`.
No original PR branch or `main` was changed.

## How conflicts were resolved

Most of these PRs were cut from main `8a38235`, about 590 commits back. Since then,
the direct-push audit commit `4f99d3888`, wave 2 (#2667) and wave 3 (#2685) landed
most of their content, often in different words. An independent read-only dependency
review classified all 88 PRs, and this branch follows its per-PR table:

| Class | Count | Meaning | Resolution |
| --- | --- | --- | --- |
| A | 19 | already on main | merged, no file changes (all 19 confirmed tree-neutral) |
| B | 30 | landed with different wording | every conflict hunk resolved to the candidate side |
| C | 23 | docs record | clean add |
| D | 4 | owner worksheet | clean add, **no option selected** |
| E | 7 | real residual | manual union (see table) |
| F | 2 | real code, clean | merged (#2671, #2676) |
| audio | 3 | #2639 / #2646 / #2675 | see "Audio" |

`check-superseded.py --pr` printed OK for all 88. It can't see a direct push or a
cherry-pick, so here it isn't evidence that a PR is new. Containment came from the
review's hunk-level checks instead.

Rules followed throughout: keep fixes the candidate already landed; no test, threshold,
privacy or isolation check weakened; no worksheet option turned into behavior; no
`.agents/*-baseline.json` touched.

### Notable unions

- **#2648 + #2651, `scripts/dev/test-matrix-checks.py`:** three self-test blocks now
  sit together: the candidate's `unselected_cases`, #2648's `guard_owners` and #2651's
  scorecard block. In #2648's owner list, `RetroactiveSpeakerUpdater+Scanning.swift`
  became `TranscriptFrontmatterScanner.swift`, which is the file
  `check-banned-calls.py` reads now (#2659). #2651's YAML rule was dropped because the
  candidate already has an identical one. Each block was mutation-checked.
- **#2658:** its beta-build-arguments rule went in as its own matrix entry. `build-beta.sh`
  composes with the candidate's model-manifest block. It's release-impacting, so it needs
  the full QA bench.
- **#2565, #2589, #2607:** the candidate already had each fix in its own form. The PRs'
  extra tests are kept and pass against the candidate code (see Checks).
- **#2653:** git's text merge duplicated a whole `scripts/README.md` section outside
  the conflict markers. The candidate file was restored exactly, since it already lists
  every script the PR adds.

## Audio: #2675, #2639, #2646

- **#2675 `eda041f3a`: adopted.** Clean merge. It fixes the two real start/stop races
  that #2639 was after. No AVAudioEngine construction, no `inputNode` access, no
  default-input writes, so Bluetooth-default behavior doesn't change. `Audio.swift` is
  now 788 lines, close to the 800 cap.
  - **Known risk (P2, bounded):** `recordingJournal.begin(...)` now runs inside
    `journalSessionLock` and does a synchronous first persist on the journal queue,
    which can sit behind the previous recording's async writes. `Audio.stop()` runs on
    the main actor and takes that lock through `takeJournalSession()`. So a Stop that
    lands during a start waits on journal disk I/O on the main thread. A later fix could
    reserve the session under the lock and persist outside it.
  - **Before promotion:** a manual meeting **stop during start**, and a mid-meeting
    **AirPods route change**, on real hardware.
- **#2639 `0fac2ffb4`: history only, design not adopted.** Merged with `-s ours`.
  Pre-merge and post-merge trees are both `c945e54db388eca3076c367efb786bcdafc03698`, and
  `git diff HEAD^1 HEAD` is empty. Reason: as written, a Stop during start preflight
  hits a generation mismatch in `sealStop` and returns before resetting `isStarting`.
  That blocks every later meeting start until relaunch, and main doesn't have this bug.
  None of its new files (`RecordingArtifact*`, `JournalCommandDispatcher`,
  `MicArtifactTransactions`, `RecordingGenerationClock`, `MeetingRecordingJournalTypes`,
  `Audio+ArtifactOwnership`, `MeetingCaptureTerminalPolicy`), its 5 tests or its
  `run-tests.sh`/`run-e2e-smoke.sh` entries are in the tree. Open owner items carried
  forward: discard ordering in `stopAndDiscardFiles` (needs its own small PR with a
  bridge-level test), and whether a late discard should skip audio owned by journal
  recovery.
- **#2646 `632b19bf7`: history only.** Merged with `-s ours`, same pre/post tree. Its
  change is already on main as cherry-pick `4f88bb6f2`, and `e31cf610d` annotated the
  `graphSnapshot` tuple for older toolchains. The candidate's annotated version stays.
  GitHub hygiene for later: #2646's base is #2639's branch. Retarget it to `main` before
  any branch deletion, or deleting that branch closes #2646 unmerged.

## Visible changes to check in the next manual test

The owner authorized these with the all-88 integration.

- **#2671, stale Accessibility grant notice.** After 3 `paste_not_confirmed` takes in a
  row with no clipboard read, across at least 2 apps (in memory, one launch):
  - Island: title "Not pasted", hint "Paste keeps failing. Turn Accessibility off and
    on.", and the button is "Settings" (opens the Accessibility pane) instead of Paste.
  - Without the island: a longer notice that points at turning Transcripted off and on
    in Privacy & Security > Accessibility, and says the text is on the clipboard.
  - A Paste retry that ends `paste_not_confirmed` now says "Maybe pasted", like the
    first attempt.
  - New analytics property `ax_regrant_suggested` on `dictation_stop_latency_measured`
    (registered; `check-telemetry-keys.py` passes). Bundle ids stay in memory.
- **#2676, Not now on a native call (Teams, Zoom).** Not now now quiets that call, not
  the whole provider for 2 h. When the detected call ends, the quiet drops to the same
  60 s grace a recorded call gets. A Not now tapped after hang-up cuts to the grace right
  away. Calendar Not now, Record, the learned streak and browser prompts are unchanged.
  - **Tradeoff to check by hand:** a genuinely new call from the **same provider that
    starts within 60 s of hang-up** is treated as the same call and **won't prompt**. One
    that starts after the 60 s still does.
  - This touches the protected meeting-detection record / dismiss / remind flow.
  - The PR body's top half describes Sentry session rotation (that's #2683, already on
    main). The PR's own change is the Not now behavior above.

## Stale statuses in the docs records

Several class-C records (#2612, #2616, #2622–#2625, #2627–#2633, #2635, #2637, #2638,
#2640–#2642, #2644) say the PR they point to was "open and unmerged". That was true at
main `8a38235`, which is when they were written. All 15 of those PRs have since been
merged: #2333, #2373, #2381, #2388, #2409, #2430, #2438, #2447, #2448, #2459, #2476,
#2490, #2492, #2498 and #2613. Each one's head is an ancestor of main `5a72538a9`
(checked with read-only `gh pr view` plus `git merge-base --is-ancestor`). The
records were kept as written, as history. The one edit:
`docs/review/DEAD-CODE-12-duplicate.md` named the removed shim's file path, which
`check-doc-paths.py` rejects, so it now names the type and carries a history note.

## Checks

Run on this branch in an isolated worktree. No app launch, no owner state touched.

- Focused offline checks on the final merge tree, all exit 0: `check-module-boundaries`,
  `check-known-traps`, `check-file-size`, `check-telemetry-keys`,
  `check-build-source-lists`, `check-test-shape`, `check-source-pins --count-baseline`,
  `check-banned-calls`, `check-window-inventory`, `check-analytics-emitters`,
  `test-matrix-checks.py --self-test`. `check-doc-paths` found the one DEAD-CODE-12
  path (fixed above).
- `swift test --package-path Tools/TranscriptedMCP --filter TranscriptIndexTests`:
  35/35 PASS. That includes #2607's stricter assertion. Packages came from the local
  SwiftPM cache.
- Standalone fast-test runs (`Tests/TestHelpers.swift` plus only the sources each test
  needs, built with `swiftc`):
  - #2589 `NextSentenceLineProcessTests`: 4/4. Mutant with `stderrTail()` back on
    `queue.sync`: traps (exit 133).
  - #2565 `DictationAudioInfoStoreTests`: 14/14. Mutant without the `!=` guard:
    8 failures.
  - #2671 `StaleAccessibilityGrantPolicyTests`: 29/29.
- `BetaBuildArgumentsTests.py`: 8/8. `bash -n` on `build-beta.sh` and
  `lib/beta-build-arguments.sh`: OK.
- `check.sh quick`: see the coordinator brief for the result on the final head.
- **Not run:** `build-deps.sh` (Core changed via #2675, so the prebuilt archive needs
  `--force`), the app build, full `run-tests.sh`, root `swift test` (including #2675's
  `MeetingJournalStartStopRaceTests` and `MicRecoveryRetirementTests`), the
  MeetingPromptDetector fast tests for #2676, smokes, the full QA bench, hosted CI, and
  all manual and hardware proof. Earlier proof of the four-PR candidate doesn't cover
  this tree.

## Per-PR record

Class letters are from the dependency review. "no-net-change" means the merge left the
tree identical to its first parent.

| PR | Frozen head | Class | Merge | Merge commit | Conflicts | Resolution |
| --- | --- | --- | --- | --- | --- | --- |
| #2559 | `759569b14` | B | resolved, no-net-change | `73542e91f` | `FloatingOverlayController.swift` | FloatingOverlayController.swift: kept candidate (epoch and `anchorRect:` already gone on main via 4f99d3888). |
| #2560 | `308d5235b` | A | clean, no-net-change | `20669c46c` | - | clean merge |
| #2562 | `71af8cddf` | B | resolved, changes | `4da48ef09` | `EmbeddingClusterer.swift`, `SpeakerDatabase.swift` | EmbeddingClusterer.swift, SpeakerDatabase.swift: comment-only; kept candidate wording. |
| #2563 | `4b620d581` | B | resolved, no-net-change | `460d9ee0d` | `MeetingQuickSummaryExtractor.swift`, `MeetingQuickSummaryWriter.swift`, `MeetingSessionController+Subscriptions.swift` | MeetingQuickSummaryExtractor/Writer, MeetingSessionController+Subscriptions: comment-only; kept candidate wording. |
| #2564 | `20b9aa2cd` | A | clean, no-net-change | `78037580e` | - | clean merge |
| #2565 | `2a61f628a` | E | resolved, changes | `c4d2cf562` | `DictationPlaybackController.swift` | DictationPlaybackController.swift: candidate already guarded both writes inline. Took the PR's `updateInfo(_:for:)` calls (same behavior) so its new test has the helper it calls. Test runs by convention (`DictationAudioInfoStoreTests.swift` -> `testDictationAudioInfoStore()`). |
| #2566 | `cf0c6855f` | B | resolved, no-net-change | `00639540a` | `auto-call-detection-spec.md` | docs/auto-call-detection-spec.md: kept candidate (per review table). Candidate names no products but still has a generic 'Observed approaches' section about other desktop recorders; flagged for owner, not changed here. |
| #2567 | `8d433d36f` | B | resolved, no-net-change | `b7da53c17` | `FloatingOverlayController.swift` | FloatingOverlayController.swift: kept candidate signature (no `anchorRect:`); no `resizePanelToCompact` references remain. |
| #2569 | `b2dbee9bf` | A | clean, no-net-change | `94e940383` | - | clean merge |
| #2572 | `ba6b6995d` | B | resolved, no-net-change | `b23af7470` | `AGENTS.md`, `AGENTS.md` | Sources/UI/AGENTS.md, Sources/UI/Settings/AGENTS.md: doc wording; kept candidate. |
| #2573 | `8c0796e26` | B | resolved, no-net-change | `a9d92f4b8` | `AGENTS.md` | Sources/UI/Shared/AGENTS.md: kept candidate (PR only adds 'cancellable'). |
| #2575 | `b7b44a36b` | B | resolved, no-net-change | `5cbba96d6` | `NotchIslandView.swift` | NotchIslandView.swift: comment wording; kept candidate. |
| #2576 | `14643c5a9` | B | resolved, no-net-change | `72603706a` | `MeetingSessionController+State.swift`, `SpeakerSettingsStore.swift` | MeetingSessionController+State.swift, SpeakerSettingsStore.swift: comment wording; kept candidate. |
| #2577 | `7c6cf1023` | A | clean, no-net-change | `7197b01ac` | - | clean merge |
| #2578 | `9845bf0e4` | B | resolved, no-net-change | `b2226cec7` | `MeetingMicrophoneSettingRow.swift` | MeetingMicrophoneSettingRow.swift: candidate already uses one `static let infoMessage` with the identical string; kept candidate. |
| #2579 | `5c47fd9f8` | A | clean, no-net-change | `aa19f0fb2` | - | clean merge |
| #2580 | `4c894f0f9` | B | resolved, no-net-change | `2f9838bee` | `MenuBarPanelController.swift` | MenuBarPanelController.swift: comment reflow; kept candidate. |
| #2581 | `129b47249` | A | clean, no-net-change | `7b48fcabc` | - | clean merge |
| #2582 | `39ff1ab32` | A | clean, no-net-change | `f5b99ed09` | - | clean merge |
| #2583 | `0c667ecdb` | B | resolved, no-net-change | `a7f5a2e3c` | `AGENTS.md`, `TranscriptedSettingsView+Pages.swift` | Settings/AGENTS.md, TranscriptedSettingsView+Pages.swift: wording; kept candidate. |
| #2584 | `bc0f39149` | B | resolved, no-net-change | `e38fb8639` | `HomeView.swift` | HomeView.swift: candidate already computes `isPlayingThis` (same expression); kept candidate. |
| #2585 | `c77b20cd7` | A | clean, no-net-change | `94aeb23c1` | - | clean merge |
| #2586 | `0629d725a` | D | clean, changes | `229cdf21f` | - | clean merge |
| #2587 | `b8abe42a6` | A | clean, no-net-change | `cb9ea968c` | - | clean merge |
| #2588 | `bd6061157` | A | clean, no-net-change | `10b6786ed` | - | clean merge |
| #2589 | `9298ae53f` | E | resolved, changes | `0ca7b636c` | `NextSentenceLineProcess.swift`, `run-tests.sh` | NextSentenceLineProcess.swift, run-tests.sh: candidate already reads `stderrTail()` under `lock` (plus EOF guard and read counter); kept candidate source and list (file already listed once). PR's new test merged and passes against candidate code. |
| #2590 | `6da667b51` | B | resolved, no-net-change | `d08a2be8c` | `NextSentenceSounds.swift`, `NextSentenceSynth.swift` | NextSentenceSounds/Synth.swift: candidate already has the stronger AirPods/inputNode note; kept candidate. |
| #2591 | `388a9d4ea` | B | resolved, changes | `55ae0c259` | `WritingController+Actions.swift`, `WritingController.swift` | WritingController(+Actions).swift: candidate's async, cancellation-aware keyboard flow kept; the three write-only vars are gone. |
| #2592 | `01291481a` | B | resolved, changes | `5e561dc53` | `RawContinuationPrompt.swift`, `ScreenScene.swift` | RawContinuationPrompt.swift, ScreenScene.swift: comment wording; kept candidate. |
| #2593 | `f3e66de63` | B | resolved, no-net-change | `05f4ce921` | `LiveMeetingTranscriptService.swift` | LiveMeetingTranscriptService.swift: candidate already has the fix (`queue: nil` + async hop to main); kept candidate comment. |
| #2594 | `2e62c7b7f` | B | resolved, no-net-change | `639dbbf32` | `ScreenCaptureService.swift` | ScreenCaptureService.swift: comment; kept candidate. |
| #2595 | `86df283d6` | B | resolved, no-net-change | `95c9533e3` | `AB_DOT_VS_CLOUD.md`, `Package.swift` | AB_DOT_VS_CLOUD.md, SpeakerEvalHarness/Package.swift: wording; kept candidate. |
| #2596 | `613abadc2` | A | clean, no-net-change | `1be4d9212` | - | clean merge |
| #2597 | `1dddb95a9` | B | resolved, no-net-change | `ea53911df` | `AppLogger.swift`, `FileLogger.swift` | AppLogger.swift, FileLogger.swift: header comments; kept candidate. |
| #2598 | `d45345097` | B | resolved, no-net-change | `64b215bd1` | `test-matrix.yml` | test-matrix.yml: deleted-file selector already absent; kept candidate. |
| #2599 | `6bcba8deb` | A | clean, no-net-change | `67e36696d` | - | clean merge |
| #2600 | `bae5cdfbd` | B | resolved, no-net-change | `f813a0ad7` | `test-matrix.yml` | test-matrix.yml: candidate rule already equals the smoke script's compiled source set (checked); kept candidate. |
| #2601 | `7d1daf35f` | D | clean, changes | `09d7dc483` | - | clean merge |
| #2602 | `678d43fca` | A | clean, no-net-change | `dc2dc39f5` | - | clean merge |
| #2603 | `c88525308` | A | clean, no-net-change | `03002b4dc` | - | clean merge |
| #2604 | `b1e934e1c` | B | resolved, changes | `eb0117efa` | `ProductionModelAsset.swift`, `PersonalVocabularyShadow.swift`, `TildeProductProfile.swift`, `ScreenScene.swift`, `ScreenSceneSnapshotBridge.swift`, `CaptureTriggerPolicy.swift`, `ScreenMemoryStatus.swift`, `FactualGroundingPolicy.swift`, `SecretRules.swift` | 9 Writing Core files, comment-only: kept candidate everywhere (per table). Follow-up for the owner: candidate's `CaptureTriggerPolicy.cadenceCapSeconds` doc says 'hard ceiling regardless of triggers' but code applies it to `.typingPause` only; `PersonalVocabularyShadow.predictNextWord` doc still mentions a live A/B test. |
| #2607 | `4d59e3091` | E | resolved, changes | `9e64847c5` | `TranscriptIndexTests.swift` | TranscriptIndexTests.swift: kept candidate fixture rows, took the PR's stricter per-query assertion (filename + exact snippet text). `swift test --package-path Tools/TranscriptedMCP --filter TranscriptIndexTests` 35/35 PASS. |
| #2608 | `768d15089` | B | resolved, no-net-change | `5d0e4ae5f` | `speaker-recognition-metrics.md` | docs/speaker-recognition-metrics.md: wording; kept candidate. |
| #2611 | `5ba4bfc79` | B | resolved, no-net-change | `05f5a188e` | `swift-ci.yml`, `mac-runner.sh` | swift-ci.yml, mac-runner.sh: comment wording; kept candidate. No runner logic touched. |
| #2612 | `6057b8e51` | C | clean, changes | `559e83061` | - | clean merge |
| #2615 | `6d6e4ef47` | A | clean, no-net-change | `1c9d401cc` | - | clean merge |
| #2616 | `99f8e1e23` | C | clean, changes | `1f0eb3394` | - | clean merge |
| #2617 | `01dde5203` | A | clean, no-net-change | `4beb63a8e` | - | clean merge |
| #2620 | `6821d1a0a` | C | clean, changes | `34f009a42` | - | clean merge |
| #2621 | `1eed7f550` | C | clean, changes | `6934965cc` | - | clean merge |
| #2622 | `285f3c69b` | C | clean, changes | `e416084f5` | - | clean merge |
| #2623 | `a81d75079` | C | clean, changes | `2bb3c63e5` | - | clean merge |
| #2624 | `337fc8885` | C | clean, changes | `347ed8a0a` | - | clean merge |
| #2625 | `8014be2ad` | C | clean, changes | `55e93429d` | - | clean merge |
| #2627 | `76d7aefcc` | C | clean, changes | `ddb4492ad` | - | clean merge |
| #2628 | `54b126f71` | C | clean, changes | `cc04e61a9` | - | clean merge |
| #2629 | `9273a59bd` | C | clean, changes | `5cee0e592` | - | clean merge |
| #2630 | `5becc059d` | C | clean, changes | `b796578db` | - | clean merge |
| #2631 | `c5a49c692` | C | clean, changes | `9066f639d` | - | clean merge |
| #2632 | `4a261fabf` | C | clean, changes | `6cfc35095` | - | clean merge |
| #2633 | `b0cbd7e63` | C | clean, changes | `33d2c6cc4` | - | clean merge |
| #2635 | `3ebfe0690` | C | clean, changes | `7c117538f` | - | clean merge |
| #2636 | `58e92b84e` | B | resolved, no-net-change | `91ce70b92` | `writing-port-ledger.md` | docs/writing-port-ledger.md: kept candidate row; wrapper file absent. |
| #2637 | `665a90a8f` | C | clean, changes | `be8e72e38` | - | clean merge |
| #2638 | `23b9b2657` | C | clean, changes | `2030a35de` | - | clean merge |
| #2639 | `0fac2ffb4` | AUDIO | tree-neutral (-s ours), no-net-change | `341b19c8b` | - | History only, design not adopted. As written, a Stop during start preflight returns before resetting `isStarting`, which then blocks every later meeting start until relaunch. Its new RecordingArtifact*/Journal*/terminal-policy files, 5 tests and run-tests/e2e list entries are NOT in the tree. Pre/post tree identical. |
| #2640 | `74c774ce8` | C | clean, changes | `79d15170b` | - | clean merge |
| #2641 | `b1be7183c` | C | clean, changes | `cf734995e` | - | clean merge |
| #2642 | `d1a592860` | C | clean, changes | `48ef655a9` | - | clean merge |
| #2644 | `f84a33115` | C | clean, changes | `3bd28c981` | - | clean merge |
| #2646 | `632b19bf7` | AUDIO | tree-neutral (-s ours), no-net-change | `110464799` | - | History only. Content already on main as cherry-pick 4f88bb6f2 plus e31cf610d's annotated `graphSnapshot` tuple; candidate version kept. Pre/post tree identical. |
| #2648 | `3042ecc58` | E | resolved, changes | `27a72df95` | `test-matrix.yml`, `test-matrix-checks.py` | test-matrix.yml: kept candidate selector (`TranscriptFrontmatterScanner.swift`, the file check-banned-calls.py reads since #2659). test-matrix-checks.py: kept candidate `unselected_cases` and added the PR's `guard_owners` block with its `RetroactiveSpeakerUpdater+Scanning.swift` row pointed at `TranscriptFrontmatterScanner.swift`. Same 14 owners, same assertions. Mutation: removing the scanner selector fails the self-test. |
| #2649 | `757c6161e` | D | clean, changes | `c3c0641f8` | - | clean merge |
| #2650 | `1d8a4b863` | B | resolved, no-net-change | `96a4123d9` | `AGENTS.md` | .agents/AGENTS.md: kept candidate. |
| #2651 | `30540d757` | E | resolved, changes | `38d16cf2a` | `test-matrix.yml`, `test-matrix-checks.py` | test-matrix.yml: dropped the PR's scorecard rule, because candidate already has a byte-identical one. test-matrix-checks.py: added the PR's scorecard self-test next to the other two blocks (all three kept). Mutation: dropping the fixtures glob fails it. |
| #2652 | `188acdd4f` | D | clean, changes | `7fcd53aad` | - | clean merge |
| #2653 | `8218cfcd7` | B | resolved, no-net-change | `7b079b187` | `README.md` | scripts/README.md: every script the PR lists is already listed on candidate; text merge had duplicated the ops/labs block outside the markers, so restored candidate file exactly. |
| #2654 | `c7734c43a` | A | clean, no-net-change | `3e3165c7e` | - | clean merge |
| #2655 | `9d0190ac1` | B | resolved, no-net-change | `a0d427db2` | `DictationStoppedAudioRecoveryTests.swift` | DictationStoppedAudioRecoveryTests.swift: candidate registers the retry registry and `testStoppedAudioPersistCause()`; kept candidate. |
| #2656 | `c99cdfe96` | E | resolved, changes | `33b834abe` | `linux-checks.sh` | linux-checks.sh: took the PR's narrower `! -path 'scripts/release/test-staged-sparkle-update.py'`. The new verdict doc merged clean. |
| #2657 | `d8e1bbc86` | A | clean, no-net-change | `2ccec2267` | - | clean merge |
| #2658 | `2323a7449` | E | resolved, changes | `24ac8b0e8` | `test-matrix.yml` | test-matrix.yml: union. Candidate's top rules kept; the PR's beta-build-arguments rule added as its own entry. build-beta.sh merged clean around the candidate's model-manifest block. Release workflow's `bash build-beta.sh '' GitHub` still resolves to user name `GitHub`. Release-impacting: needs the full QA bench. |
| #2660 | `9caa4aa20` | B | resolved, no-net-change | `398cce232` | `release-packaging.md` | docs/release-packaging.md: kept candidate (PR line has a typo: 'published76'). The other fixture-pin lines were already on candidate. |
| #2661 | `37a10b41e` | C | clean, changes | `86cfd9c5f` | - | clean merge |
| #2663 | `b72a7bf74` | A | clean, no-net-change | `80e51a570` | - | clean merge |
| #2671 | `838aad308` | F | clean, changes | `13abce2ba` | - | clean merge |
| #2675 | `eda041f3a` | AUDIO | clean, changes | `13fa993d7` | - | Adopted as content. Clean merge. Fixes the two real start/stop races from #2639. Known risk (P2): `recordingJournal.begin(...)` now runs inside `journalSessionLock` and does a synchronous first persist on the journal queue; a main-actor Stop that lands in that window waits on journal disk I/O. Needs a stop-during-start and AirPods route-change test before promotion. |
| #2676 | `7fb4559ad` | F | clean, changes | `efaab8fc8` | - | clean merge |
