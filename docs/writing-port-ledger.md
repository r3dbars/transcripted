# Writing port ledger

The master checklist for porting Tilde into Transcripted Writing. Source of truth
is the read-only export of Tilde commit `f36f6562` at `~/tilde-port/tilde-f36f6562/`.
Plan: [writing-plan.md](writing-plan.md).

Statuses: `todo`, `ported` (merged into the phase branch, parity diff checked),
`reviewed` (passed the phase review), `replaced` (rewritten as Transcripted code
per the plan), `not-ported` (dev-only; its call sites are stripped).

Parity check for everything `ported` or `reviewed`:

```bash
python3 ~/tilde-port/parity-diff.py --ledger docs/writing-port-ledger.md --repo .
```

## Renames

| Tilde | Transcripted |
| --- | --- |
| module `TildeCore` | `TranscriptedWritingCore` (SPM); compiled into the app module by `build.sh` |
| app bundle ID `bar.r3d.tilde` | `com.justinbetker.draft` |
| keyboard bundle ID and `TISInputSourceID` `bar.r3d.inputmethod.InlineGhost` | `com.justinbetker.draft.inputmethod.Transcripted` |
| keyboard display name "Tilde" | "Transcripted" (decision 13) |
| keyboard bundle `InlineGhostIME.app` | `Transcripted Keyboard.app` |
| `InputMethodConnectionName` `InlineGhostIME_1_Connection` | `TranscriptedKeyboard_1_Connection` |
| `~/Library/Application Support/Tilde/` | `~/Library/Application Support/Transcripted/writing/` |
| `…/Tilde/Models/<id>/model.gguf` | `~/Library/Application Support/Transcripted/models/writing/<id>/model.gguf` |
| `~/Library/Logs/Tilde/diagnostics.log` | `~/Library/Application Support/Transcripted/logs/writing-diagnostics.log` |
| Keychain service `bar.r3d.tilde.personal-history` | `com.justinbetker.draft.writing.personal-history` |
| llama port `17872` | `17891` |
| `TILDE_ALLOW_UNSIGNED_LOCAL_PEER` (DEBUG) | `TRANSCRIPTED_WRITING_ALLOW_UNSIGNED_LOCAL_PEER` (DEBUG) |
| other `TILDE_*` overrides | removed |
| `llama-server` helper | Tilde's shipped build. Code bytes with the signature removed: SHA-256 `3f6895ab8d077b02803761fb8cc254073d2c7b4006fbacbef4c844879333fffc`. Re-signed by Transcripted's build (team `XG6WL66WUQ`, same as Tilde). |

## Sources

| Tilde | Transcripted | Status | Phase | Notes |
| --- | --- | --- | --- | --- |
| `Sources/TildeCore/Engine/CompletionOutputCleaner.swift` | `Sources/TranscriptedWriting/Core/Engine/CompletionOutputCleaner.swift` | ported | 1 |  |
| `Sources/TildeCore/Engine/GhostBrainWire.swift` | `Sources/TranscriptedWriting/Core/Engine/GhostBrainWire.swift` | ported | 1 |  |
| `Sources/TildeCore/Engine/IntentPromptHint.swift` | `Sources/TranscriptedWriting/Core/Engine/IntentPromptHint.swift` | ported | 1 |  |
| `Sources/TildeCore/Engine/PreparedCompletionContext.swift` | `Sources/TranscriptedWriting/Core/Engine/PreparedCompletionContext.swift` | ported | 1 |  |
| `Sources/TildeCore/Engine/PreviewModelAsset.swift` | `—` | not-ported | 1 | 26B preview only. Strip call sites in ModelManager. |
| `Sources/TildeCore/Engine/ProductionModelAsset.swift` | `Sources/TranscriptedWriting/Core/Engine/ProductionModelAsset.swift` | ported | 1 |  |
| `Sources/TildeCore/Engine/Qwen9BModelAsset.swift` | `Sources/TranscriptedWriting/Core/Engine/Qwen9BModelAsset.swift` | ported | 1 |  |
| `Sources/TildeCore/Engine/RawContinuationPrompt.swift` | `Sources/TranscriptedWriting/Core/Engine/RawContinuationPrompt.swift` | ported | 1 |  |
| `Sources/TildeCore/Geometry/InlineGhostFontPolicy.swift` | `Sources/TranscriptedWriting/Core/Geometry/InlineGhostFontPolicy.swift` | ported | 1 |  |
| `Sources/TildeCore/Geometry/InlineGhostLegibility.swift` | `Sources/TranscriptedWriting/Core/Geometry/InlineGhostLegibility.swift` | ported | 1 |  |
| `Sources/TildeCore/PersonalHistory/PersonalHistoryEvent.swift` | `Sources/TranscriptedWriting/Core/PersonalHistory/PersonalHistoryEvent.swift` | ported | 1 |  |
| `Sources/TildeCore/PersonalHistory/PersonalSuggestionPolicy.swift` | `Sources/TranscriptedWriting/Core/PersonalHistory/PersonalSuggestionPolicy.swift` | ported | 1 |  |
| `Sources/TildeCore/PersonalHistory/PersonalVocabularyShadow.swift` | `Sources/TranscriptedWriting/Core/PersonalHistory/PersonalVocabularyShadow.swift` | ported | 1 |  |
| `Sources/TildeCore/PersonalHistory/PsychicReplay.swift` | `—` | not-ported | 1 | Dev-only replay eval. |
| `Sources/TildeCore/PersonalHistory/ReplayEval.swift` | `—` | not-ported | 1 | Dev-only replay eval. |
| `Sources/TildeCore/PersonalHistory/SuggestionArbiter.swift` | `Sources/TranscriptedWriting/Core/PersonalHistory/SuggestionArbiter.swift` | ported | 1 | Inlined `PersonalReplayEval.normalizeWord` as a private helper (ReplayEval not ported). |
| `Sources/TildeCore/PersonalHistory/SuggestionCandidateSet.swift` | `Sources/TranscriptedWriting/Core/PersonalHistory/SuggestionCandidateSet.swift` | ported | 1 |  |
| `Sources/TildeCore/Policy/H01BlockRandomization.swift` | `—` | not-ported | 1 | Dev-only H01 randomization. Strip call sites in the keyboard, server, engine and settings. |
| `Sources/TildeCore/Policy/LiveOnlineOpportunity.swift` | `Sources/TranscriptedWriting/Core/Policy/LiveOnlineOpportunity.swift` | ported | 1 |  |
| `Sources/TildeCore/Policy/LocalOutcomeDiary.swift` | `Sources/TranscriptedWriting/Core/Policy/LocalOutcomeDiary.swift` | ported | 1 | No shipping users at f36f6562. Port only if a ported file needs it. Ported as-is per work order W1a: no ported Core file needs it, `RetainedSpanWatchTests` does. |
| `Sources/TildeCore/Policy/OpportunityCharacterMeter.swift` | `Sources/TranscriptedWriting/Core/Policy/OpportunityCharacterMeter.swift` | ported | 1 |  |
| `Sources/TildeCore/Policy/RetainedCharacterObservation.swift` | `Sources/TranscriptedWriting/Core/Policy/RetainedCharacterObservation.swift` | ported | 1 |  |
| `Sources/TildeCore/Policy/SuggestionActivationPolicy.swift` | `Sources/TranscriptedWriting/Core/Policy/SuggestionActivationPolicy.swift` | ported | 1 |  |
| `Sources/TildeCore/Policy/SuggestionDecisionReason.swift` | `Sources/TranscriptedWriting/Core/Policy/SuggestionDecisionReason.swift` | ported | 1 |  |
| `Sources/TildeCore/Policy/SuggestionRevealDelayPolicy.swift` | `Sources/TranscriptedWriting/Core/Policy/SuggestionRevealDelayPolicy.swift` | ported | 1 |  |
| `Sources/TildeCore/Policy/TextFreeOnlineEvent.swift` | `Sources/TranscriptedWriting/Core/Policy/TextFreeOnlineEvent.swift` | ported | 1 |  |
| `Sources/TildeCore/Runtime/PreviewModelChoice.swift` | `—` | not-ported | 1 | Preview builds only. Strip call sites. |
| `Sources/TildeCore/Runtime/ProcessPeerIdentityCache.swift` | `Sources/TranscriptedWriting/Core/Runtime/ProcessPeerIdentityCache.swift` | ported | 1 |  |
| `Sources/TildeCore/Runtime/TildeConfiguration.swift` | `Sources/TranscriptedWriting/Core/Runtime/TildeConfiguration.swift` | ported | 1 | Rename Tilde-branded types only if the plan's rename table says so. |
| `Sources/TildeCore/Runtime/TildeModelChoice.swift` | `Sources/TranscriptedWriting/Core/Runtime/TildeModelChoice.swift` | ported | 1 |  |
| `Sources/TildeCore/Runtime/TildeProductProfile.swift` | `Sources/TranscriptedWriting/Core/Runtime/TildeProductProfile.swift` | ported | 1 | Keeps `.production` and `.preview9B`, drops 26B and Model Preview. `.preview9B` stays because the Qwen model choice uses its completion behavior; its bundle IDs are Tilde preview identities no Transcripted build uses. Collapse it into a Qwen completion profile once the runtime no longer reads it (phase 2 cleanup). |
| `Sources/TildeCore/Scene/IntentFutureFusion.swift` | `Sources/TranscriptedWriting/Core/Scene/IntentFutureFusion.swift` | ported | 1 |  |
| `Sources/TildeCore/Scene/IntentFutures.swift` | `Sources/TranscriptedWriting/Core/Scene/IntentFutures.swift` | ported | 1 |  |
| `Sources/TildeCore/Scene/SceneSuggestionPolicy.swift` | `Sources/TranscriptedWriting/Core/Scene/SceneSuggestionPolicy.swift` | ported | 1 |  |
| `Sources/TildeCore/Scene/ScreenScene.swift` | `Sources/TranscriptedWriting/Core/Scene/ScreenScene.swift` | ported | 1 |  |
| `Sources/TildeCore/Scene/ScreenSceneSnapshotBridge.swift` | `Sources/TranscriptedWriting/Core/Scene/ScreenSceneSnapshotBridge.swift` | ported | 1 |  |
| `Sources/TildeCore/Scene/SensitiveScenePolicy.swift` | `Sources/TranscriptedWriting/Core/Scene/SensitiveScenePolicy.swift` | ported | 1 |  |
| `Sources/TildeCore/ScreenMemory/CaptureChangeDetector.swift` | `Sources/TranscriptedWriting/Core/ScreenMemory/CaptureChangeDetector.swift` | ported | 1 |  |
| `Sources/TildeCore/ScreenMemory/CaptureKindPolicy.swift` | `Sources/TranscriptedWriting/Core/ScreenMemory/CaptureKindPolicy.swift` | ported | 1 |  |
| `Sources/TildeCore/ScreenMemory/CaptureTriggerPolicy.swift` | `Sources/TranscriptedWriting/Core/ScreenMemory/CaptureTriggerPolicy.swift` | ported | 1 |  |
| `Sources/TildeCore/ScreenMemory/ContextResetDetector.swift` | `Sources/TranscriptedWriting/Core/ScreenMemory/ContextResetDetector.swift` | ported | 1 |  |
| `Sources/TildeCore/ScreenMemory/DefaultExcludedApps.swift` | `Sources/TranscriptedWriting/Core/ScreenMemory/DefaultExcludedApps.swift` | ported | 1 |  |
| `Sources/TildeCore/ScreenMemory/ScreenMemoryStatus.swift` | `Sources/TranscriptedWriting/Core/ScreenMemory/ScreenMemoryStatus.swift` | ported | 1 |  |
| `Sources/TildeCore/ScreenMemory/ScreenSnapshot.swift` | `Sources/TranscriptedWriting/Core/ScreenMemory/ScreenSnapshot.swift` | ported | 1 |  |
| `Sources/TildeCore/Suggestions/CompletionSuggestion.swift` | `Sources/TranscriptedWriting/Core/Suggestions/CompletionSuggestion.swift` | ported | 1 |  |
| `Sources/TildeCore/Suggestions/FactualGroundingPolicy.swift` | `Sources/TranscriptedWriting/Core/Suggestions/FactualGroundingPolicy.swift` | ported | 1 |  |
| `Sources/TildeCore/Suggestions/InlineSuggestionState.swift` | `Sources/TranscriptedWriting/Core/Suggestions/InlineSuggestionState.swift` | ported | 1 |  |
| `Sources/TildeCore/Suggestions/SceneEchoPolicy.swift` | `Sources/TranscriptedWriting/Core/Suggestions/SceneEchoPolicy.swift` | ported | 1 |  |
| `Sources/TildeCore/Suggestions/StableStreamPrefix.swift` | `Sources/TranscriptedWriting/Core/Suggestions/StableStreamPrefix.swift` | ported | 1 |  |
| `Sources/TildeCore/Text/DiagnosticsMetadataRedactor.swift` | `Sources/TranscriptedWriting/Core/Text/DiagnosticsMetadataRedactor.swift` | ported | 1 |  |
| `Sources/TildeCore/Text/SecretRules.swift` | `Sources/TranscriptedWriting/Core/Text/SecretRules.swift` | ported | 1 |  |
| `Sources/InlineGhostIME/GhostBrainClient.swift` | `Sources/TranscriptedKeyboard/GhostBrainClient.swift` | ported | 1 | Fable porter. Peer auth expects the Transcripted app identity through `TildeProductProfile`; no drift. |
| `Sources/InlineGhostIME/GhostInputController.swift` | `Sources/TranscriptedKeyboard/GhostInputController.swift` | ported | 1 | Fable porter. H01 stripped (`experimentArm` sent as nil, `variant` left to the ledger's default). No accept-key help text lives in this file; the keyCode-50 comment already says "backtick/tilde key". |
| `Sources/InlineGhostIME/GhostOutcomeLedger.swift` | `Sources/TranscriptedKeyboard/GhostOutcomeLedger.swift` | ported | 1 | Plaintext word diary dropped: `append(event:)` writes only text-free v3 events; kept/edited checks still run from in-memory accepted text. Queue label renamed. |
| `Sources/InlineGhostIME/GhostProvenance.swift` | `Sources/TranscriptedKeyboard/GhostProvenance.swift` | ported | 1 | No drift. |
| `Sources/InlineGhostIME/GhostStats.swift` | `Sources/TranscriptedKeyboard/GhostStats.swift` | ported | 1 | Queue label renamed. |
| `Sources/InlineGhostIME/Info.plist` | `Sources/TranscriptedKeyboard/Info.plist` | ported | 1 | Identity renames per plan; version keys are placeholders stamped by `scripts/entrypoints/lib/bundle-input-method.sh`. |
| `Sources/InlineGhostIME/PersonalHistoryCapture.swift` | `Sources/TranscriptedKeyboard/PersonalHistoryCapture.swift` | ported | 1 | Straight port in phase 1 (queue label renamed); Backspace tracking lands in phase 3. |
| `Sources/InlineGhostIME/main.swift` | `Sources/TranscriptedKeyboard/main.swift` | ported | 1 | No dev flags exist at `f36f6562`; no drift. |
| `Sources/TildeApp/App/AppDelegate.swift` | `Sources/Writing/WritingController.swift` | replaced | 2 | Lifecycle wiring only; no dev flags, no relaunches mid-meeting. |
| `Sources/TildeApp/App/GhostBrainServerHost.swift` | `Sources/TranscriptedWriting/Runtime/GhostBrainServerHost.swift` | ported | 2 | Fable porter. Socket under Transcripted app support; peer auth with Transcripted identities; H01 and preview strips. `start()` reports a duplicate instance as `false`; nothing terminates. The app-scope suggestion gate (Tilde bug fix) is phase 3, through `suggestionsGate`. |
| `Sources/TildeApp/App/GhostKeyboardInstallerHost.swift` | `Sources/TranscriptedWriting/Runtime/KeyboardInstaller.swift` | ported | 2 | Type name kept (`GhostKeyboardInstallerHost`). Bundled path is `Contents/Library/Input Methods/<profile.inputMethodInstalledBundleName>`. TISEnableInputSource: P2-B. |
| `Sources/TildeApp/App/OutcomeLedgerSummary.swift` | `Sources/TranscriptedWriting/Runtime/Stats/OutcomeLedgerSummary.swift` | ported | 2 |  |
| `Sources/TildeApp/App/PersonalSuggestionStats.swift` | `Sources/TranscriptedWriting/Runtime/Stats/PersonalSuggestionStats.swift` | ported | 2 |  |
| `Sources/TildeApp/App/StatusMenuHost.swift` | `—` | not-ported | 4 | Decision 12: no menu bar row. Status moves to the Writing tab. |
| `Sources/TildeApp/App/TildeApplicationState.swift` | `Sources/Writing/WritingController.swift` | replaced | 2 |  |
| `Sources/TildeApp/App/TildeInstallationLocation.swift` | `—` | not-ported | 2 | Transcripted handles its own install location. |
| `Sources/TildeApp/App/TildeLocalOutcomeStores.swift` | `Sources/TranscriptedWriting/Runtime/Stats/WritingLocalOutcomeStores.swift` | ported | 2 | Type name kept (`TildeLocalOutcomeStores`). |
| `Sources/TildeApp/App/TildeProgress.swift` | `Sources/TranscriptedWriting/Runtime/Stats/WritingProgress.swift` | ported | 2 | Type name kept (`TildeProgress`). |
| `Sources/TildeApp/App/TildeSettings.swift` | `Sources/TranscriptedWriting/Runtime/TildeSettings.swift` | ported | 2 | Straight port, type name kept; the H01, local-OCR-evaluation and incremental-OCR keys are stripped. The bridge's `WritingPreferences` (P2-B) wraps it. |
| `Sources/TildeApp/App/TildeSettingsSupportingViews.swift` | `Sources/UI/Settings/Writing/` | replaced | 4 |  |
| `Sources/TildeApp/App/TildeSettingsViewModel.swift` | `Sources/Writing/WritingSettingsModel.swift` | replaced | 4 |  |
| `Sources/TildeApp/App/TildeSettingsWindowController.swift` | `Sources/UI/Settings/Writing/` | replaced | 4 | Writing tab settings section. |
| `Sources/TildeApp/App/TildeSetupState.swift` | `Sources/Writing/WritingSetupState.swift` | replaced | 4 | Approved three-step setup. |
| `Sources/TildeApp/App/TildeSetupWindowController.swift` | `Sources/UI/Settings/Writing/` | replaced | 4 | Intro pages and setup steps. |
| `Sources/TildeApp/App/TildeStats.swift` | `Sources/TranscriptedWriting/Runtime/Stats/WritingStats.swift` | ported | 2 | Type name kept (`TildeStats`). |
| `Sources/TildeApp/App/YourTildeView.swift` | `Sources/UI/Settings/Writing/` | replaced | 4 | Everyday view stats. |
| `Sources/TildeApp/App/main.swift` | `—` | not-ported | 2 | Dev flags only. |
| `Sources/TildeApp/Mac/DiagnosticsLog.swift` | `Sources/TranscriptedWriting/Runtime/DiagnosticsLog.swift` | ported | 2 | Write under Transcripted's logs. Deviation: never writes under tests or with `TRANSCRIPTED_DISABLE_FILE_LOGGER=1`, same as `FileLogger`. |
| `Sources/TildeApp/Mac/SecureLocalStorage.swift` | `Sources/TranscriptedWriting/Runtime/PersonalHistory/SecureLocalStorage.swift` | ported | 2 | Straight port; moved from phase 3. |
| `Sources/TildeApp/PersonalHistory/PersonalBrainStatus.swift` | `—` | not-ported | 3 | Only used by a dev JSON flag. |
| `Sources/TildeApp/PersonalHistory/PersonalHistoryController.swift` | `Sources/TranscriptedWriting/Runtime/PersonalHistory/PersonalHistoryController.swift` | ported | 2 | Straight port; moved from phase 3. Phase 3 gates it on Save my writing and the app scope. |
| `Sources/TildeApp/PersonalHistory/PersonalHistoryStore.swift` | `Sources/TranscriptedWriting/Runtime/PersonalHistory/PersonalHistoryStore.swift` | ported | 2 | Straight port; moved from phase 3 (Keychain service renamed). Phase 3: predictor state stays app-owned; user-facing text goes to Markdown day files (decision 6). |
| `Sources/TildeApp/PersonalHistory/ReplayEvalCommand.swift` | `—` | not-ported | 3 | Dev-only. |
| `Sources/TildeApp/PersonalHistory/ReplayEvalOwnership.swift` | `—` | not-ported | 3 | Dev-only. |
| `Sources/TildeApp/Runtime/LlamaCompletionEngine.swift` | `Sources/TranscriptedWriting/Runtime/LlamaCompletionEngine.swift` | ported | 2 | H01 stripped: no `experimentDefaults`, `visibleCleaner` or `experimentArm`. |
| `Sources/TildeApp/Runtime/LlamaCompletionStreamTransport.swift` | `Sources/TranscriptedWriting/Runtime/LlamaCompletionStreamTransport.swift` | ported | 2 |  |
| `Sources/TildeApp/Runtime/LlamaRestartPolicy.swift` | `Sources/TranscriptedWriting/Runtime/LlamaRestartPolicy.swift` | ported | 2 |  |
| `Sources/TildeApp/Runtime/LlamaServerProcessHost.swift` | `Sources/TranscriptedWriting/Runtime/LlamaServerProcessHost.swift` | ported | 2 | Fable porter. Port is injected (the profile's 17891). `TILDE_DEV_*` overrides and the dev model provider stripped; the default provider is `{ nil }`. |
| `Sources/TildeApp/Runtime/LocalhostURLSession.swift` | `Sources/TranscriptedWriting/Runtime/LocalhostURLSession.swift` | ported | 2 |  |
| `Sources/TildeApp/Runtime/ModelManager.swift` | `Sources/TranscriptedWriting/Runtime/ModelManager.swift` | ported | 2 | Preview descriptors and `TILDE_MODEL_DIRECTORY` stripped. Default root is still `<support dir>/Models`; the bridge injects `rootDirectory:` (`Transcripted/models/writing`), Tilde-model adoption and the no-relaunch switch (P2-B). |
| `Sources/TildeApp/Runtime/PreviewModelSelection.swift` | `—` | not-ported | 2 | Preview builds only. Strip call sites. |
| `Sources/TildeApp/Runtime/ScaffoldPrewarmer.swift` | `Sources/TranscriptedWriting/Runtime/ScaffoldPrewarmer.swift` | ported | 2 |  |
| `Sources/TildeApp/Runtime/TildeModelSelection.swift` | `Sources/TranscriptedWriting/Runtime/WritingModelSelection.swift` | ported | 2 | Type name kept (`TildeModelSelection`). Release-proof and `PreviewModelSelection` paths stripped. Qwen greyed out under 16 GB: P2-B. |
| `Sources/TildeApp/ScreenMemory/AXWindowTextReader.swift` | `Sources/TranscriptedWriting/Runtime/ScreenMemory/AXWindowTextReader.swift` | ported | 2 | Fable porter. |
| `Sources/TildeApp/ScreenMemory/AccessibilityPermission.swift` | `Sources/TranscriptedWriting/Runtime/ScreenMemory/AccessibilityPermission.swift` | ported | 2 | No launch-time prompt; Transcripted already holds Accessibility. `request()` stays; callers decide. |
| `Sources/TildeApp/ScreenMemory/GLiNERRedactionHelperHost.swift` | `—` | not-ported | 2 | Dev-only GLiNER. |
| `Sources/TildeApp/ScreenMemory/LocalOCREvaluationStore.swift` | `—` | not-ported | 2 | Dev-only. Strip call sites. |
| `Sources/TildeApp/ScreenMemory/LuminanceGridSampler.swift` | `Sources/TranscriptedWriting/Runtime/ScreenMemory/LuminanceGridSampler.swift` | ported | 2 | Unreferenced once the incremental-OCR flag is gone; kept as a ported unit. |
| `Sources/TildeApp/ScreenMemory/RedactionEvalCommand.swift` | `—` | not-ported | 2 | Dev-only. |
| `Sources/TildeApp/ScreenMemory/RedactionService.swift` | `—` | not-ported | 2 | Only used by eval and proof paths. |
| `Sources/TildeApp/ScreenMemory/ScreenCaptureService.swift` | `Sources/TranscriptedWriting/Runtime/ScreenMemory/ScreenCaptureService.swift` | ported | 2 | Fable porter. OCR evaluation store and incremental-OCR flag stripped, so every Vision pass is a full OCR (the flag's default). |
| `Sources/TildeApp/ScreenMemory/ScreenLockObserver.swift` | `Sources/TranscriptedWriting/Runtime/ScreenMemory/ScreenLockObserver.swift` | ported | 2 |  |
| `Sources/TildeApp/ScreenMemory/ScreenMemoryProofStimulus.swift` | `—` | not-ported | 2 | Release-proof only. |
| `Sources/TildeApp/ScreenMemory/ScreenRecordingPermission.swift` | `Sources/TranscriptedWriting/Runtime/ScreenMemory/ScreenRecordingPermission.swift` | ported | 2 | Not in the global permission enum (plan: Permissions changes). `request()` stays; callers decide. |
| `Sources/TildeApp/ScreenMemory/ScreenTextRecognizer.swift` | `Sources/TranscriptedWriting/Runtime/ScreenMemory/ScreenTextRecognizer.swift` | ported | 2 |  |
| `Sources/TildeApp/ScreenMemory/WindowAttribution.swift` | `Sources/TranscriptedWriting/Runtime/ScreenMemory/WindowAttribution.swift` | ported | 2 |  |

## Deviations from Tilde (recorded after the phase 2 review)

- **Keyboard summon:** the keyboard doesn't reopen Transcripted when it's already running (`GhostInputController.summonBrainIfNeeded`). A running app means the model or helper is still loading, and a reopen event would show the window.
- **Owner seal check:** `KeyboardInstaller` validates the app's own code seal once per launch (about 0.2 s over the whole bundle). Keyboard bundles are still checked every time.
- **Quiet-quit:** set only when the user quits. Logout, restart and shutdown carry a system quit reason and leave it clear, so the keyboard can wake Transcripted after a reboot (`WritingController.noteTerminationRequest`).
- **Model switch:** `ModelManager.cancel()` stops a superseded download. Tilde relaunched instead. `waitUntilSettled` returns when cancelled.
- **Diagnostics:** `DiagnosticsLog` never writes under tests or with `TRANSCRIPTED_DISABLE_FILE_LOGGER=1`.
- **Integer keyboard build:** the keyboard's `CFBundleVersion` is an integer derived from the app version (1.1.66 → 1001066), which the installer's upgrade check requires.
- **Word diary:** the keyboard persists only text-free kept/edited results. Accepted text is saved only through Save my writing.
- **Socket path:** it's about 9 bytes longer than Tilde's. Usernames over about 28 characters would exceed `sun_path` (104 bytes), and Writing then stays off with a log line. Rare; revisit if it's ever reported.

## Follow-ups

- Phase 4: user-visible runtime strings still say "Tilde" (outcome-ledger and runtime status text such as "reinstall Tilde", "Tilde held back…"). Rename them to Transcripted/Writing copy when the Writing tab lands, and update the tests that assert them.
- Phase 2 cleanup: collapse `.preview9B` into a Qwen completion profile once nothing reads its preview identities.
- Before rollout: the `llama-server` pin depends on `codesign --remove-signature` output staying byte-stable across toolchains (it fails closed). Revisit with the reproducible build recipe (plan decision 9).

## Tests

| Tilde | Transcripted | Status | Phase | Notes |
| --- | --- | --- | --- | --- |
| `Tests/TildeCoreTests/CompletionCleanSettlementTests.swift` | `Tests/TranscriptedWritingTests/Core/CompletionCleanSettlementTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/CompletionOutputCleanerTests.swift` | `Tests/TranscriptedWritingTests/Core/CompletionOutputCleanerTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/CompletionSuggestionTests.swift` | `Tests/TranscriptedWritingTests/Core/CompletionSuggestionTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/DiagnosticsMetadataRedactorTests.swift` | `Tests/TranscriptedWritingTests/Core/DiagnosticsMetadataRedactorTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/FactualGroundingPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/FactualGroundingPolicyTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/GhostBrainWireTests.swift` | `Tests/TranscriptedWritingTests/Core/GhostBrainWireTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/H01BlockRandomizationTests.swift` | — | not-ported | 1 | Tests a dev-only path. |
| `Tests/TildeCoreTests/InlineGhostFontPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/InlineGhostFontPolicyTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/InlineGhostLegibilityPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/InlineGhostLegibilityPolicyTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/InlineSuggestionStateTests.swift` | `Tests/TranscriptedWritingTests/Core/InlineSuggestionStateTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/IntentFutureFusionTests.swift` | `Tests/TranscriptedWritingTests/Core/IntentFutureFusionTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/IntentFuturesTests.swift` | `Tests/TranscriptedWritingTests/Core/IntentFuturesTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/IntentPromptHintTests.swift` | `Tests/TranscriptedWritingTests/Core/IntentPromptHintTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/OpportunityCharacterMeterTests.swift` | `Tests/TranscriptedWritingTests/Core/OpportunityCharacterMeterTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/PersonalHistoryEventTests.swift` | `Tests/TranscriptedWritingTests/Core/PersonalHistoryEventTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/PersonalStreamGatePolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/PersonalStreamGatePolicyTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/PersonalSuggestionPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/PersonalSuggestionPolicyTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/PersonalTrainedModelTests.swift` | `Tests/TranscriptedWritingTests/Core/PersonalTrainedModelTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/PersonalVocabularyShadowTests.swift` | `Tests/TranscriptedWritingTests/Core/PersonalVocabularyShadowTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/PreparedCompletionContextGoldens.swift` | `Tests/TranscriptedWritingTests/Core/PreparedCompletionContextGoldens.swift` | ported | 1 | |
| `Tests/TildeCoreTests/PreparedCompletionContextTests.swift` | `Tests/TranscriptedWritingTests/Core/PreparedCompletionContextTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/ProcessPeerIdentityCacheTests.swift` | `Tests/TranscriptedWritingTests/Core/ProcessPeerIdentityCacheTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/PsychicReplayTests.swift` | — | not-ported | 1 | Tests a dev-only path. |
| `Tests/TildeCoreTests/RawContinuationPromptTests.swift` | `Tests/TranscriptedWritingTests/Core/RawContinuationPromptTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/ReplayEvalTests.swift` | — | not-ported | 1 | Tests a dev-only path. |
| `Tests/TildeCoreTests/RetainedCharacterObservationTests.swift` | `Tests/TranscriptedWritingTests/Core/RetainedCharacterObservationTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/RetainedSpanWatchTests.swift` | `Tests/TranscriptedWritingTests/Core/RetainedSpanWatchTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/SceneEchoPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/SceneEchoPolicyTests.swift` | ported | 1 | Trimmed `.preview26B`/`.modelPreview` from the shipping-profiles loop (profiles not ported). |
| `Tests/TildeCoreTests/SceneSuggestionPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/SceneSuggestionPolicyTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/ScreenMemory/CaptureChangeDetectorTests.swift` | `Tests/TranscriptedWritingTests/Core/ScreenMemory/CaptureChangeDetectorTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/ScreenMemory/CaptureKindPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/ScreenMemory/CaptureKindPolicyTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/ScreenMemory/CaptureTriggerPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/ScreenMemory/CaptureTriggerPolicyTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/ScreenMemory/ContextResetDetectorTests.swift` | `Tests/TranscriptedWritingTests/Core/ScreenMemory/ContextResetDetectorTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/ScreenMemory/DefaultExcludedAppsTests.swift` | `Tests/TranscriptedWritingTests/Core/ScreenMemory/DefaultExcludedAppsTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/ScreenMemory/RedactionCorpusSanityTests.swift` | — | not-ported | 1 | Reads the dev-only redaction eval corpus (`script/testdata/`), which isn't part of the shipping product. |
| `Tests/TildeCoreTests/ScreenMemory/ScreenMemoryStatusTests.swift` | `Tests/TranscriptedWritingTests/Core/ScreenMemory/ScreenMemoryStatusTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/ScreenSceneSnapshotBridgeTests.swift` | `Tests/TranscriptedWritingTests/Core/ScreenSceneSnapshotBridgeTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/ScreenSceneTests.swift` | `Tests/TranscriptedWritingTests/Core/ScreenSceneTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/SecretRulesTests.swift` | `Tests/TranscriptedWritingTests/Core/SecretRulesTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/SensitiveScenePolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/SensitiveScenePolicyTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/StableStreamPrefixTests.swift` | `Tests/TranscriptedWritingTests/Core/StableStreamPrefixTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/SuggestionActivationPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/SuggestionActivationPolicyTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/SuggestionArbiterTests.swift` | `Tests/TranscriptedWritingTests/Core/SuggestionArbiterTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/SuggestionCandidateSetTests.swift` | `Tests/TranscriptedWritingTests/Core/SuggestionCandidateSetTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/SuggestionDecisionReasonTests.swift` | `Tests/TranscriptedWritingTests/Core/SuggestionDecisionReasonTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/SuggestionRevealDelayPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/SuggestionRevealDelayPolicyTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/TextFreeCandidateSourceTests.swift` | `Tests/TranscriptedWritingTests/Core/TextFreeCandidateSourceTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/TildeConfigurationTests.swift` | `Tests/TranscriptedWritingTests/Core/TildeConfigurationTests.swift` | ported | 1 | |
| `Tests/TildeCoreTests/TildeProductProfileTests.swift` | `Tests/TranscriptedWritingTests/Core/TildeProductProfileTests.swift` | ported | 1 | Trimmed: `resolvesExplicitPreviewProfile` and `modelPreviewChoicesHaveStableOwnerFacingLabels` (only tested dropped profiles / `PreviewModelChoice`), plus the 26B and Model Preview assertions in the other tests. |
| `Tests/TildeAppTests/GhostBrainServerHostPersonalGuardTests.swift` | `Tests/TranscriptedWritingTests/Runtime/GhostBrainServerHostPersonalGuardTests.swift` | ported | 2 |  |
| `Tests/TildeAppTests/GhostBrainServerHostStreamingGateTests.swift` | `Tests/TranscriptedWritingTests/Runtime/GhostBrainServerHostStreamingGateTests.swift` | ported | 2 |  |
| `Tests/TildeAppTests/GhostInputControllerTests.swift` | `Tests/TranscriptedWritingTests/Runtime/GhostInputControllerTests.swift` | ported | 2 |  |
| `Tests/TildeAppTests/GhostKeyboardInstallerHostTests.swift` | `Tests/TranscriptedWritingTests/Runtime/GhostKeyboardInstallerHostTests.swift` | ported | 2 | Trimmed the `TildeLaunchModeTests` suite (`productionMode`, `releaseProofMode`, `rejectsUnknownArguments`, `personalBrainStatusInvocation`, `replayEvalInvocation`): `TildeLaunchMode`/`TildeInvocation` live in the replaced AppDelegate. Installed bundle is `Transcripted Keyboard.app`. |
| `Tests/TildeAppTests/GhostStatsTests.swift` | `Tests/TranscriptedWritingTests/Runtime/GhostStatsTests.swift` | ported | 2 |  |
| `Tests/TildeAppTests/H01HarnessWiringTests.swift` | — | not-ported | 2 | Tests a dev-only path. |
| `Tests/TildeAppTests/IgnoreApplicationMenuItemTests.swift` | — | not-ported | 2 | Tests `IgnoreApplicationMenuItem` in `StatusMenuHost` (not-ported, decision 12). |
| `Tests/TildeAppTests/IntentFuturesPromptIntegrationTests.swift` | `Tests/TranscriptedWritingTests/Runtime/IntentFuturesPromptIntegrationTests.swift` | ported | 2 |  |
| `Tests/TildeAppTests/LlamaCompletionStreamCutTests.swift` | `Tests/TranscriptedWritingTests/Runtime/LlamaCompletionStreamCutTests.swift` | ported | 2 |  |
| `Tests/TildeAppTests/LlamaCompletionStreamingTests.swift` | `Tests/TranscriptedWritingTests/Runtime/LlamaCompletionStreamingTests.swift` | ported | 2 | Test base URLs use port 17891. |
| `Tests/TildeAppTests/LlamaRestartPolicyTests.swift` | `Tests/TranscriptedWritingTests/Runtime/LlamaRestartPolicyTests.swift` | ported | 2 |  |
| `Tests/TildeAppTests/LocalOCREvaluationStoreTests.swift` | — | not-ported | 2 | Tests a dev-only path. |
| `Tests/TildeAppTests/ModelManagerTests.swift` | `Tests/TranscriptedWritingTests/Runtime/ModelManagerTests.swift` | ported | 2 |  |
| `Tests/TildeAppTests/OutcomeLedgerSummaryTests.swift` | `Tests/TranscriptedWritingTests/Runtime/OutcomeLedgerSummaryTests.swift` | ported | 2 | Trimmed `menuPresentation` (renders through `StatusMenuHost.Presentation`, not-ported). |
| `Tests/TildeAppTests/PersonalBrainStatusTests.swift` | — | not-ported | 2 | Tests a dev-only path. |
| `Tests/TildeAppTests/PersonalHistoryCaptureTests.swift` | `Tests/TranscriptedWritingTests/Runtime/PersonalHistoryCaptureTests.swift` | ported | 2 |  |
| `Tests/TildeAppTests/PersonalHistoryControllerTests.swift` | `Tests/TranscriptedWritingTests/Runtime/PersonalHistoryControllerTests.swift` | ported | 2 |  |
| `Tests/TildeAppTests/PersonalHistoryStoreTests.swift` | `Tests/TranscriptedWritingTests/Runtime/PersonalHistoryStoreTests.swift` | ported | 2 | Sealed fixtures authenticate with the profile value `com.justinbetker.draft.personal-history.v1`. |
| `Tests/TildeAppTests/PersonalTrainedModelStoreTests.swift` | `Tests/TranscriptedWritingTests/Runtime/PersonalTrainedModelStoreTests.swift` | ported | 2 |  |
| `Tests/TildeAppTests/PreparedContextStreamingTests.swift` | `Tests/TranscriptedWritingTests/Runtime/PreparedContextStreamingTests.swift` | ported | 2 | `experimentDefaults: nil` dropped (H01 strip); port 17891. |
| `Tests/TildeAppTests/PreviewModelSelectionTests.swift` | — | not-ported | 2 | Tests a dev-only path. |
| `Tests/TildeAppTests/ProfileDisplayFilterTests.swift` | `Tests/TranscriptedWritingTests/Runtime/ProfileDisplayFilterTests.swift` | ported | 2 | Trimmed `.preview26B`/`.modelPreview` from the two shipping-profile loops (profiles not ported); `experimentDefaults: nil` dropped; port 17891. |
| `Tests/TildeAppTests/ProfileSceneOptionsTests.swift` | `Tests/TranscriptedWritingTests/Runtime/ProfileSceneOptionsTests.swift` | ported | 2 | Trimmed `.preview26B`/`.modelPreview` from the production loop (profiles not ported). |
| `Tests/TildeAppTests/ReplayEvalCommandTests.swift` | — | not-ported | 2 | Tests a dev-only path. |
| `Tests/TildeAppTests/ReplayEvalOwnershipTests.swift` | — | not-ported | 2 | Tests a dev-only path. |
| `Tests/TildeAppTests/RuntimeBoundaryTests.swift` | `Tests/TranscriptedWritingTests/Runtime/RuntimeBoundaryTests.swift` | ported | 2 | Redirect URL uses port 17891. |
| `Tests/TildeAppTests/ScaffoldPrewarmerTests.swift` | `Tests/TranscriptedWritingTests/Runtime/ScaffoldPrewarmerTests.swift` | ported | 2 | Port 17891. |
| `Tests/TildeAppTests/ScreenMemory/GLiNERRedactionHelperHostTests.swift` | — | not-ported | 2 | Tests a dev-only path. |
| `Tests/TildeAppTests/ScreenMemory/RedactionServiceTests.swift` | — | not-ported | 2 | Tests `RedactionService` (not-ported; eval and proof paths only). |
| `Tests/TildeAppTests/ScreenMemory/ScreenCaptureServiceTests.swift` | `Tests/TranscriptedWritingTests/Runtime/ScreenMemory/ScreenCaptureServiceTests.swift` | ported | 2 | Trimmed the paired OCR evaluation tests (`pairedEvaluationGatesAndFilters`, `pairedEvaluationRechecksSafety`, `pairedEvaluationSuppressesConcurrentReferencePasses`, `pairedEvaluationReferenceFailure`) with their `evaluationBlock`, `EvaluationRecordBox` and `AsyncTestGate` helpers: the OCR evaluation store and its init params are stripped. |
| `Tests/TildeAppTests/ScreenMemory/ScreenMemoryProofStimulusTests.swift` | — | not-ported | 2 | Tests a dev-only path. |
| `Tests/TildeAppTests/ScreenMemory/WindowAttributionTests.swift` | `Tests/TranscriptedWritingTests/Runtime/ScreenMemory/WindowAttributionTests.swift` | ported | 2 |  |
| `Tests/TildeAppTests/SecureLocalStorageTests.swift` | `Tests/TranscriptedWritingTests/Runtime/SecureLocalStorageTests.swift` | ported | 2 |  |
| `Tests/TildeAppTests/StatusMenuPresentationTests.swift` | — | not-ported | 2 | Tests `StatusMenuHost.Presentation` (not-ported, decision 12). |
| `Tests/TildeAppTests/TildeApplicationStateTests.swift` | — | replaced | 2 | Tests `TildeApplicationState`, replaced by `WritingController`. |
| `Tests/TildeAppTests/TildeInstallationLocationTests.swift` | — | not-ported | 2 | Tests `TildeInstallationLocation` (not-ported). |
| `Tests/TildeAppTests/TildeLocalOutcomeStoresTests.swift` | `Tests/TranscriptedWritingTests/Runtime/TildeLocalOutcomeStoresTests.swift` | ported | 2 | Path assertion checks `Transcripted/writing` instead of `Tilde`. |
| `Tests/TildeAppTests/TildeProgressTests.swift` | `Tests/TranscriptedWritingTests/Runtime/TildeProgressTests.swift` | ported | 2 | Trimmed `milestoneCopy` (`TildeProgressPresentation` lives in the replaced YourTildeView). |
| `Tests/TildeAppTests/TildeSettingsPresentationTests.swift` | — | replaced | 2 | Tests `TildeSettingsPresentation` in the replaced TildeSettingsViewModel. |
| `Tests/TildeAppTests/TildeSettingsTests.swift` | `Tests/TranscriptedWritingTests/Runtime/TildeSettingsTests.swift` | ported | 2 | Trimmed `localOCREvaluationPreference`, `incrementalOCRToggle`, `incrementalOCRExplicitOffPersists` and the incremental-OCR default assertion in `absentKeysUseProductDefaults` (keys stripped), plus `modelPresentation` (`TildeModelPresentation` lives in the replaced view model). |
| `Tests/TildeAppTests/TildeSettingsViewModelTests.swift` | — | replaced | 2 | Tests the replaced TildeSettingsViewModel. |
| `Tests/TildeAppTests/TildeSetupStateTests.swift` | — | replaced | 2 | Tests the replaced TildeSetupState. |
| `Tests/TildeAppTests/TildeStatsTests.swift` | `Tests/TranscriptedWritingTests/Runtime/TildeStatsTests.swift` | ported | 2 |  |
