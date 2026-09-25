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
| `Sources/TildeCore/Runtime/TildeProductProfile.swift` | `Sources/TranscriptedWriting/Core/Runtime/TildeProductProfile.swift` | ported | 1 | Keep the production and Qwen profiles; drop preview-build profiles. |
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
| `Sources/InlineGhostIME/GhostBrainClient.swift` | `Sources/TranscriptedKeyboard/GhostBrainClient.swift` | todo | 1 | Fable porter. Peer auth: expect the Transcripted app identity. |
| `Sources/InlineGhostIME/GhostInputController.swift` | `Sources/TranscriptedKeyboard/GhostInputController.swift` | todo | 1 | Fable porter. Strip H01. Help text: fix the ISO key name. |
| `Sources/InlineGhostIME/GhostOutcomeLedger.swift` | `Sources/TranscriptedKeyboard/GhostOutcomeLedger.swift` | todo | 1 | Drop the plaintext word diary; keep text-free kept/edited results. |
| `Sources/InlineGhostIME/GhostProvenance.swift` | `Sources/TranscriptedKeyboard/GhostProvenance.swift` | todo | 1 |  |
| `Sources/InlineGhostIME/GhostStats.swift` | `Sources/TranscriptedKeyboard/GhostStats.swift` | todo | 1 |  |
| `Sources/InlineGhostIME/Info.plist` | `Sources/TranscriptedKeyboard/Info.plist` | todo | 1 | Identity renames per plan. |
| `Sources/InlineGhostIME/PersonalHistoryCapture.swift` | `Sources/TranscriptedKeyboard/PersonalHistoryCapture.swift` | todo | 1 | Straight port in phase 1; Backspace tracking lands in phase 3. |
| `Sources/InlineGhostIME/main.swift` | `Sources/TranscriptedKeyboard/main.swift` | todo | 1 | Strip dev flags. |
| `Sources/TildeApp/App/AppDelegate.swift` | `Sources/Writing/WritingController.swift` | replaced | 2 | Lifecycle wiring only; no dev flags, no relaunches mid-meeting. |
| `Sources/TildeApp/App/GhostBrainServerHost.swift` | `Sources/TranscriptedWriting/Runtime/GhostBrainServerHost.swift` | todo | 2 | Fable porter. Socket under Transcripted app support; peer auth with Transcripted identities; strip H01; app-scope gate on suggestions (Tilde bug fix). |
| `Sources/TildeApp/App/GhostKeyboardInstallerHost.swift` | `Sources/TranscriptedWriting/Runtime/KeyboardInstaller.swift` | todo | 2 | Add TISEnableInputSource. |
| `Sources/TildeApp/App/OutcomeLedgerSummary.swift` | `Sources/TranscriptedWriting/Runtime/Stats/OutcomeLedgerSummary.swift` | todo | 2 |  |
| `Sources/TildeApp/App/PersonalSuggestionStats.swift` | `Sources/TranscriptedWriting/Runtime/Stats/PersonalSuggestionStats.swift` | todo | 2 |  |
| `Sources/TildeApp/App/StatusMenuHost.swift` | `—` | not-ported | 4 | Decision 12: no menu bar row. Status moves to the Writing tab. |
| `Sources/TildeApp/App/TildeApplicationState.swift` | `Sources/Writing/WritingController.swift` | replaced | 2 |  |
| `Sources/TildeApp/App/TildeInstallationLocation.swift` | `—` | not-ported | 2 | Transcripted handles its own install location. |
| `Sources/TildeApp/App/TildeLocalOutcomeStores.swift` | `Sources/TranscriptedWriting/Runtime/Stats/WritingLocalOutcomeStores.swift` | todo | 2 |  |
| `Sources/TildeApp/App/TildeProgress.swift` | `Sources/TranscriptedWriting/Runtime/Stats/WritingProgress.swift` | todo | 2 |  |
| `Sources/TildeApp/App/TildeSettings.swift` | `Sources/Writing/WritingPreferences.swift` | replaced | 2 | Strip H01, OCR eval and incremental-OCR keys. |
| `Sources/TildeApp/App/TildeSettingsSupportingViews.swift` | `Sources/UI/Settings/Writing/` | replaced | 4 |  |
| `Sources/TildeApp/App/TildeSettingsViewModel.swift` | `Sources/Writing/WritingSettingsModel.swift` | replaced | 4 |  |
| `Sources/TildeApp/App/TildeSettingsWindowController.swift` | `Sources/UI/Settings/Writing/` | replaced | 4 | Writing tab settings section. |
| `Sources/TildeApp/App/TildeSetupState.swift` | `Sources/Writing/WritingSetupState.swift` | replaced | 4 | Approved three-step setup. |
| `Sources/TildeApp/App/TildeSetupWindowController.swift` | `Sources/UI/Settings/Writing/` | replaced | 4 | Intro pages and setup steps. |
| `Sources/TildeApp/App/TildeStats.swift` | `Sources/TranscriptedWriting/Runtime/Stats/WritingStats.swift` | todo | 2 |  |
| `Sources/TildeApp/App/YourTildeView.swift` | `Sources/UI/Settings/Writing/` | replaced | 4 | Everyday view stats. |
| `Sources/TildeApp/App/main.swift` | `—` | not-ported | 2 | Dev flags only. |
| `Sources/TildeApp/Mac/DiagnosticsLog.swift` | `Sources/TranscriptedWriting/Runtime/DiagnosticsLog.swift` | todo | 2 | Write under Transcripted's logs. |
| `Sources/TildeApp/Mac/SecureLocalStorage.swift` | `Sources/TranscriptedWriting/Runtime/PersonalHistory/SecureLocalStorage.swift` | todo | 3 | Keychain service renamed. |
| `Sources/TildeApp/PersonalHistory/PersonalBrainStatus.swift` | `—` | not-ported | 3 | Only used by a dev JSON flag. |
| `Sources/TildeApp/PersonalHistory/PersonalHistoryController.swift` | `Sources/TranscriptedWriting/Runtime/PersonalHistory/PersonalHistoryController.swift` | todo | 3 | Gate on Save my writing and app scope. |
| `Sources/TildeApp/PersonalHistory/PersonalHistoryStore.swift` | `Sources/TranscriptedWriting/Runtime/PersonalHistory/PersonalHistoryStore.swift` | todo | 3 | Predictor state stays app-owned; user-facing text goes to Markdown day files (decision 6). |
| `Sources/TildeApp/PersonalHistory/ReplayEvalCommand.swift` | `—` | not-ported | 3 | Dev-only. |
| `Sources/TildeApp/PersonalHistory/ReplayEvalOwnership.swift` | `—` | not-ported | 3 | Dev-only. |
| `Sources/TildeApp/Runtime/LlamaCompletionEngine.swift` | `Sources/TranscriptedWriting/Runtime/LlamaCompletionEngine.swift` | todo | 2 | Strip H01 and preview paths. |
| `Sources/TildeApp/Runtime/LlamaCompletionStreamTransport.swift` | `Sources/TranscriptedWriting/Runtime/LlamaCompletionStreamTransport.swift` | todo | 2 |  |
| `Sources/TildeApp/Runtime/LlamaRestartPolicy.swift` | `Sources/TranscriptedWriting/Runtime/LlamaRestartPolicy.swift` | todo | 2 |  |
| `Sources/TildeApp/Runtime/LlamaServerProcessHost.swift` | `Sources/TranscriptedWriting/Runtime/LlamaServerProcessHost.swift` | todo | 2 | Fable porter. New port, not 17872. |
| `Sources/TildeApp/Runtime/LocalhostURLSession.swift` | `Sources/TranscriptedWriting/Runtime/LocalhostURLSession.swift` | todo | 2 |  |
| `Sources/TildeApp/Runtime/ModelManager.swift` | `Sources/TranscriptedWriting/Runtime/ModelManager.swift` | todo | 2 | Transcripted paths; adopt a verified Tilde model; no relaunch on switch; strip preview asset. |
| `Sources/TildeApp/Runtime/PreviewModelSelection.swift` | `—` | not-ported | 2 | Preview builds only. Strip call sites. |
| `Sources/TildeApp/Runtime/ScaffoldPrewarmer.swift` | `Sources/TranscriptedWriting/Runtime/ScaffoldPrewarmer.swift` | todo | 2 |  |
| `Sources/TildeApp/Runtime/TildeModelSelection.swift` | `Sources/TranscriptedWriting/Runtime/WritingModelSelection.swift` | todo | 2 | Qwen greyed out under 16 GB. |
| `Sources/TildeApp/ScreenMemory/AXWindowTextReader.swift` | `Sources/TranscriptedWriting/Runtime/ScreenMemory/AXWindowTextReader.swift` | todo | 2 | Fable porter. |
| `Sources/TildeApp/ScreenMemory/AccessibilityPermission.swift` | `Sources/TranscriptedWriting/Runtime/ScreenMemory/AccessibilityPermission.swift` | todo | 2 | No launch-time prompt; Transcripted already holds Accessibility. |
| `Sources/TildeApp/ScreenMemory/GLiNERRedactionHelperHost.swift` | `—` | not-ported | 2 | Dev-only GLiNER. |
| `Sources/TildeApp/ScreenMemory/LocalOCREvaluationStore.swift` | `—` | not-ported | 2 | Dev-only. Strip call sites. |
| `Sources/TildeApp/ScreenMemory/LuminanceGridSampler.swift` | `Sources/TranscriptedWriting/Runtime/ScreenMemory/LuminanceGridSampler.swift` | todo | 2 |  |
| `Sources/TildeApp/ScreenMemory/RedactionEvalCommand.swift` | `—` | not-ported | 2 | Dev-only. |
| `Sources/TildeApp/ScreenMemory/RedactionService.swift` | `—` | not-ported | 2 | Only used by eval and proof paths. |
| `Sources/TildeApp/ScreenMemory/ScreenCaptureService.swift` | `Sources/TranscriptedWriting/Runtime/ScreenMemory/ScreenCaptureService.swift` | todo | 2 | Fable porter. Strip OCR evaluation store and incremental-OCR flag. |
| `Sources/TildeApp/ScreenMemory/ScreenLockObserver.swift` | `Sources/TranscriptedWriting/Runtime/ScreenMemory/ScreenLockObserver.swift` | todo | 2 |  |
| `Sources/TildeApp/ScreenMemory/ScreenMemoryProofStimulus.swift` | `—` | not-ported | 2 | Release-proof only. |
| `Sources/TildeApp/ScreenMemory/ScreenRecordingPermission.swift` | `Sources/TranscriptedWriting/Runtime/ScreenMemory/ScreenRecordingPermission.swift` | todo | 2 | Not in the global permission enum (plan: Permissions changes). |
| `Sources/TildeApp/ScreenMemory/ScreenTextRecognizer.swift` | `Sources/TranscriptedWriting/Runtime/ScreenMemory/ScreenTextRecognizer.swift` | todo | 2 |  |
| `Sources/TildeApp/ScreenMemory/WindowAttribution.swift` | `Sources/TranscriptedWriting/Runtime/ScreenMemory/WindowAttribution.swift` | todo | 2 |  |

## Tests

| Tilde | Transcripted | Status | Phase | Notes |
| --- | --- | --- | --- | --- |
| `Tests/TildeCoreTests/CompletionCleanSettlementTests.swift` | `Tests/TranscriptedWritingTests/Core/CompletionCleanSettlementTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/CompletionOutputCleanerTests.swift` | `Tests/TranscriptedWritingTests/Core/CompletionOutputCleanerTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/CompletionSuggestionTests.swift` | `Tests/TranscriptedWritingTests/Core/CompletionSuggestionTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/DiagnosticsMetadataRedactorTests.swift` | `Tests/TranscriptedWritingTests/Core/DiagnosticsMetadataRedactorTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/FactualGroundingPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/FactualGroundingPolicyTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/GhostBrainWireTests.swift` | `Tests/TranscriptedWritingTests/Core/GhostBrainWireTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/H01BlockRandomizationTests.swift` | — | not-ported | 1 | Tests a dev-only path. |
| `Tests/TildeCoreTests/InlineGhostFontPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/InlineGhostFontPolicyTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/InlineGhostLegibilityPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/InlineGhostLegibilityPolicyTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/InlineSuggestionStateTests.swift` | `Tests/TranscriptedWritingTests/Core/InlineSuggestionStateTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/IntentFutureFusionTests.swift` | `Tests/TranscriptedWritingTests/Core/IntentFutureFusionTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/IntentFuturesTests.swift` | `Tests/TranscriptedWritingTests/Core/IntentFuturesTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/IntentPromptHintTests.swift` | `Tests/TranscriptedWritingTests/Core/IntentPromptHintTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/OpportunityCharacterMeterTests.swift` | `Tests/TranscriptedWritingTests/Core/OpportunityCharacterMeterTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/PersonalHistoryEventTests.swift` | `Tests/TranscriptedWritingTests/Core/PersonalHistoryEventTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/PersonalStreamGatePolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/PersonalStreamGatePolicyTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/PersonalSuggestionPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/PersonalSuggestionPolicyTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/PersonalTrainedModelTests.swift` | `Tests/TranscriptedWritingTests/Core/PersonalTrainedModelTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/PersonalVocabularyShadowTests.swift` | `Tests/TranscriptedWritingTests/Core/PersonalVocabularyShadowTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/PreparedCompletionContextGoldens.swift` | `Tests/TranscriptedWritingTests/Core/PreparedCompletionContextGoldens.swift` | todo | 1 | |
| `Tests/TildeCoreTests/PreparedCompletionContextTests.swift` | `Tests/TranscriptedWritingTests/Core/PreparedCompletionContextTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/ProcessPeerIdentityCacheTests.swift` | `Tests/TranscriptedWritingTests/Core/ProcessPeerIdentityCacheTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/PsychicReplayTests.swift` | — | not-ported | 1 | Tests a dev-only path. |
| `Tests/TildeCoreTests/RawContinuationPromptTests.swift` | `Tests/TranscriptedWritingTests/Core/RawContinuationPromptTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/ReplayEvalTests.swift` | — | not-ported | 1 | Tests a dev-only path. |
| `Tests/TildeCoreTests/RetainedCharacterObservationTests.swift` | `Tests/TranscriptedWritingTests/Core/RetainedCharacterObservationTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/RetainedSpanWatchTests.swift` | `Tests/TranscriptedWritingTests/Core/RetainedSpanWatchTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/SceneEchoPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/SceneEchoPolicyTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/SceneSuggestionPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/SceneSuggestionPolicyTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/ScreenMemory/CaptureChangeDetectorTests.swift` | `Tests/TranscriptedWritingTests/Core/ScreenMemory/CaptureChangeDetectorTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/ScreenMemory/CaptureKindPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/ScreenMemory/CaptureKindPolicyTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/ScreenMemory/CaptureTriggerPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/ScreenMemory/CaptureTriggerPolicyTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/ScreenMemory/ContextResetDetectorTests.swift` | `Tests/TranscriptedWritingTests/Core/ScreenMemory/ContextResetDetectorTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/ScreenMemory/DefaultExcludedAppsTests.swift` | `Tests/TranscriptedWritingTests/Core/ScreenMemory/DefaultExcludedAppsTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/ScreenMemory/RedactionCorpusSanityTests.swift` | `Tests/TranscriptedWritingTests/Core/ScreenMemory/RedactionCorpusSanityTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/ScreenMemory/ScreenMemoryStatusTests.swift` | `Tests/TranscriptedWritingTests/Core/ScreenMemory/ScreenMemoryStatusTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/ScreenSceneSnapshotBridgeTests.swift` | `Tests/TranscriptedWritingTests/Core/ScreenSceneSnapshotBridgeTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/ScreenSceneTests.swift` | `Tests/TranscriptedWritingTests/Core/ScreenSceneTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/SecretRulesTests.swift` | `Tests/TranscriptedWritingTests/Core/SecretRulesTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/SensitiveScenePolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/SensitiveScenePolicyTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/StableStreamPrefixTests.swift` | `Tests/TranscriptedWritingTests/Core/StableStreamPrefixTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/SuggestionActivationPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/SuggestionActivationPolicyTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/SuggestionArbiterTests.swift` | `Tests/TranscriptedWritingTests/Core/SuggestionArbiterTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/SuggestionCandidateSetTests.swift` | `Tests/TranscriptedWritingTests/Core/SuggestionCandidateSetTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/SuggestionDecisionReasonTests.swift` | `Tests/TranscriptedWritingTests/Core/SuggestionDecisionReasonTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/SuggestionRevealDelayPolicyTests.swift` | `Tests/TranscriptedWritingTests/Core/SuggestionRevealDelayPolicyTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/TextFreeCandidateSourceTests.swift` | `Tests/TranscriptedWritingTests/Core/TextFreeCandidateSourceTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/TildeConfigurationTests.swift` | `Tests/TranscriptedWritingTests/Core/TildeConfigurationTests.swift` | todo | 1 | |
| `Tests/TildeCoreTests/TildeProductProfileTests.swift` | `Tests/TranscriptedWritingTests/Core/TildeProductProfileTests.swift` | todo | 1 | |
| `Tests/TildeAppTests/GhostBrainServerHostPersonalGuardTests.swift` | `Tests/TranscriptedWritingTests/Runtime/GhostBrainServerHostPersonalGuardTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/GhostBrainServerHostStreamingGateTests.swift` | `Tests/TranscriptedWritingTests/Runtime/GhostBrainServerHostStreamingGateTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/GhostInputControllerTests.swift` | `Tests/TranscriptedWritingTests/Runtime/GhostInputControllerTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/GhostKeyboardInstallerHostTests.swift` | `Tests/TranscriptedWritingTests/Runtime/GhostKeyboardInstallerHostTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/GhostStatsTests.swift` | `Tests/TranscriptedWritingTests/Runtime/GhostStatsTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/H01HarnessWiringTests.swift` | — | not-ported | 2 | Tests a dev-only path. |
| `Tests/TildeAppTests/IgnoreApplicationMenuItemTests.swift` | `Tests/TranscriptedWritingTests/Runtime/IgnoreApplicationMenuItemTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/IntentFuturesPromptIntegrationTests.swift` | `Tests/TranscriptedWritingTests/Runtime/IntentFuturesPromptIntegrationTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/LlamaCompletionStreamCutTests.swift` | `Tests/TranscriptedWritingTests/Runtime/LlamaCompletionStreamCutTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/LlamaCompletionStreamingTests.swift` | `Tests/TranscriptedWritingTests/Runtime/LlamaCompletionStreamingTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/LlamaRestartPolicyTests.swift` | `Tests/TranscriptedWritingTests/Runtime/LlamaRestartPolicyTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/LocalOCREvaluationStoreTests.swift` | — | not-ported | 2 | Tests a dev-only path. |
| `Tests/TildeAppTests/ModelManagerTests.swift` | `Tests/TranscriptedWritingTests/Runtime/ModelManagerTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/OutcomeLedgerSummaryTests.swift` | `Tests/TranscriptedWritingTests/Runtime/OutcomeLedgerSummaryTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/PersonalBrainStatusTests.swift` | — | not-ported | 2 | Tests a dev-only path. |
| `Tests/TildeAppTests/PersonalHistoryCaptureTests.swift` | `Tests/TranscriptedWritingTests/Runtime/PersonalHistoryCaptureTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/PersonalHistoryControllerTests.swift` | `Tests/TranscriptedWritingTests/Runtime/PersonalHistoryControllerTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/PersonalHistoryStoreTests.swift` | `Tests/TranscriptedWritingTests/Runtime/PersonalHistoryStoreTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/PersonalTrainedModelStoreTests.swift` | `Tests/TranscriptedWritingTests/Runtime/PersonalTrainedModelStoreTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/PreparedContextStreamingTests.swift` | `Tests/TranscriptedWritingTests/Runtime/PreparedContextStreamingTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/PreviewModelSelectionTests.swift` | — | not-ported | 2 | Tests a dev-only path. |
| `Tests/TildeAppTests/ProfileDisplayFilterTests.swift` | `Tests/TranscriptedWritingTests/Runtime/ProfileDisplayFilterTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/ProfileSceneOptionsTests.swift` | `Tests/TranscriptedWritingTests/Runtime/ProfileSceneOptionsTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/ReplayEvalCommandTests.swift` | — | not-ported | 2 | Tests a dev-only path. |
| `Tests/TildeAppTests/ReplayEvalOwnershipTests.swift` | — | not-ported | 2 | Tests a dev-only path. |
| `Tests/TildeAppTests/RuntimeBoundaryTests.swift` | `Tests/TranscriptedWritingTests/Runtime/RuntimeBoundaryTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/ScaffoldPrewarmerTests.swift` | `Tests/TranscriptedWritingTests/Runtime/ScaffoldPrewarmerTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/ScreenMemory/GLiNERRedactionHelperHostTests.swift` | — | not-ported | 2 | Tests a dev-only path. |
| `Tests/TildeAppTests/ScreenMemory/RedactionServiceTests.swift` | `Tests/TranscriptedWritingTests/Runtime/ScreenMemory/RedactionServiceTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/ScreenMemory/ScreenCaptureServiceTests.swift` | `Tests/TranscriptedWritingTests/Runtime/ScreenMemory/ScreenCaptureServiceTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/ScreenMemory/ScreenMemoryProofStimulusTests.swift` | — | not-ported | 2 | Tests a dev-only path. |
| `Tests/TildeAppTests/ScreenMemory/WindowAttributionTests.swift` | `Tests/TranscriptedWritingTests/Runtime/ScreenMemory/WindowAttributionTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/SecureLocalStorageTests.swift` | `Tests/TranscriptedWritingTests/Runtime/SecureLocalStorageTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/StatusMenuPresentationTests.swift` | `Tests/TranscriptedWritingTests/Runtime/StatusMenuPresentationTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/TildeApplicationStateTests.swift` | `Tests/TranscriptedWritingTests/Runtime/TildeApplicationStateTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/TildeInstallationLocationTests.swift` | `Tests/TranscriptedWritingTests/Runtime/TildeInstallationLocationTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/TildeLocalOutcomeStoresTests.swift` | `Tests/TranscriptedWritingTests/Runtime/TildeLocalOutcomeStoresTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/TildeProgressTests.swift` | `Tests/TranscriptedWritingTests/Runtime/TildeProgressTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/TildeSettingsPresentationTests.swift` | `Tests/TranscriptedWritingTests/Runtime/TildeSettingsPresentationTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/TildeSettingsTests.swift` | `Tests/TranscriptedWritingTests/Runtime/TildeSettingsTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/TildeSettingsViewModelTests.swift` | `Tests/TranscriptedWritingTests/Runtime/TildeSettingsViewModelTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/TildeSetupStateTests.swift` | `Tests/TranscriptedWritingTests/Runtime/TildeSetupStateTests.swift` | todo | 2 | |
| `Tests/TildeAppTests/TildeStatsTests.swift` | `Tests/TranscriptedWritingTests/Runtime/TildeStatsTests.swift` | todo | 2 | |
