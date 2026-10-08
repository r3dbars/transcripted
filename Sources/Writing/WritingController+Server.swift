#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import AppKit
import CoreGraphics
import Foundation

extension WritingController {
    // MARK: - Socket server

    func makeServerHost(_ runtime: Runtime, model: TildeModelChoice) -> GhostBrainServerHost {
        let profile = TildeProductProfile.current
        let completionProfile = TildeModelSelection.completionProfile(for: profile, productionChoice: model)
        // One configuration for both processes: the build's interaction
        // policy, the model choice's generator and decision policies.
        let configuration = TildeEffectiveConfiguration.resolve(
            build: profile,
            completionProfile: completionProfile,
            modelIdentifier: runtime.models.manager.descriptor.identifier
        )
        // Phrase continuations go to the llama engine. Mid-word completion
        // belongs only to the keyboard's system spell-checker path.
        return GhostBrainServerHost(
            runtime: runtime.llamaServerHost,
            personalHistory: WritingPausableIngest(
                base: WritingHistoryIngest(
                    dayFiles: runtime.dayFiles.recorder,
                    appScope: { Self.preferences().appScope }
                ),
                isPaused: { Self.settings().pausedUntil != nil }
            ),
            sceneProvider: Self.sceneProvider(for: runtime.screenCaptureService),
            targetProvider: { appBundleIdentifier, fieldSessionIdentifier in
                Self.suggestionTargetProvider(appBundleIdentifier, fieldSessionIdentifier)
            },
            // A bare activity pulse only — see GhostBrainServerHost's doc comment.
            onCompletionActivity: Self.completionActivityHandler(
                for: runtime.screenCaptureService,
                prewarmer: runtime.scaffoldPrewarmer
            ),
            onScreenMemoryEvent: Self.screenMemoryEventHandler(for: runtime.screenCaptureService),
            suggestionsGate: { Self.suggestionsGate(appBundleIdentifier: $0) },
            personalSuggestionsGate: { Self.personalSuggestionsGate() },
            personalNextWordProvider: Self.personalNextWordProvider(for: runtime.personalHistoryController),
            configuration: configuration,
            productProfile: completionProfile
        )
    }

    /// A model switch swaps the model store and the served configuration.
    /// The socket goes away for a moment; the keyboard treats that like the
    /// helper being down, which it is for the whole switch anyway.
    func rebuildRuntime(for model: TildeModelChoice) {
        guard let runtime else { return }
        // The superseded manager's download would otherwise keep running.
        runtime.models.manager.cancel()
        runtime.models.manager = makeModelManager(for: model)
        activeModel = model
        ghostBrainServerHost?.stop()
        let server = makeServerHost(runtime, model: model)
        if server.start() {
            ghostBrainServerHost = server
        } else {
            ghostBrainServerHost = nil
            log("WRITING | socket server did not restart after the model switch")
        }
    }

    func persistModelChoice(_ model: TildeModelChoice) {
        TildeModelSelection.persist(model, defaults: Self.appDefaults())
        selectedModel = model
        DiagnosticsLog.shared.record("model-selected", metadata: ["model": model.rawValue])
    }

    func stopHelper() async {
        guard let host = runtime?.llamaServerHost else { return }
        // Up to 1.2 s of TERM-then-KILL; keep it off the main thread.
        await Task.detached(priority: .userInitiated) { host.stop() }.value
    }

    /// Delete model, Autocomplete already saved off: ends model work and
    /// waits for the helper to exit. `applyRunState()` settles the rest.
    func stopModelWork() async {
        let previous = modelTask
        modelTask?.cancel()
        modelTask = nil
        modelTaskID = nil
        wakeTask?.cancel()
        wakeTask = nil
        autocompleteRuntimeActive = false
        runtime?.models.manager.cancel()
        await previous?.value
        await stopHelper()
    }

    func startHelper() {
        guard isRunning, autocompleteRuntimeActive else { return }
        runtime?.llamaServerHost.start()
    }

    // MARK: - Server closures

    /// Screen Recording is required for any suggestion, and the request's app
    /// must be in the Writing scope; see `WritingSuggestionsGate` for the
    /// whole rule. Read fresh on every completion request (never cached), so
    /// a permission revoked or granted mid-session applies to the very next
    /// request.
    private nonisolated static func suggestionsGate(appBundleIdentifier: String?) -> Bool {
        WritingSuggestionsGate.allows(WritingSuggestionsGate.Inputs(
            preferences: preferences(),
            appBundleIdentifier: appBundleIdentifier,
            screenRecordingGranted: ScreenRecordingPermission.isGranted()
        ))
    }

    /// Tilde had one choice: Personal History on meant personal suggestions
    /// on. Transcripted splits them (decision 11): personalized suggestions
    /// are their own switch, off by default, and still need Save my writing,
    /// which is what the predictor learns from.
    private nonisolated static func personalSuggestionsGate() -> Bool {
        preferences().personalSuggestionsAllowed
    }

    /// `nonisolated` for the same reason `sceneProvider`/
    /// `completionActivityHandler` are: the closure captures and calls an
    /// actor-isolated method (`PersonalHistoryController.
    /// personalNextWordPrediction`) from inside a `@MainActor` type.
    /// Per-app exclusions are enforced on the other side of this closure,
    /// inside the controller — see its doc comment.
    private nonisolated static func personalNextWordProvider(
        for controller: PersonalHistoryController
    ) -> @Sendable ([String], String?) async -> PersonalNextWordPrediction? {
        { tailWords, appBundleIdentifier in
            await controller.personalNextWordPrediction(
                afterTailWords: tailWords,
                appBundleIdentifier: appBundleIdentifier
            )
        }
    }

    /// `nonisolated` so the closure it returns has no ambiguous isolation of
    /// its own to infer: the compiler cannot otherwise tell whether a closure
    /// written inside a `@MainActor` type belongs to the main actor or to
    /// `ScreenCaptureService`'s own actor.
    private nonisolated static func completionActivityHandler(
        for service: ScreenCaptureService,
        prewarmer: ScaffoldPrewarmer
    ) -> @Sendable () -> Void {
        {
            prewarmer.noteCompletionActivity()
            Task { await service.noteCompletionActivity() }
        }
    }

    private nonisolated static func screenMemoryEventHandler(
        for service: ScreenCaptureService
    ) -> @Sendable (ScreenMemoryInputEvent) -> Void {
        { event in
            Task {
                guard event.kind != .textFieldBlurred else {
                    await service.noteTextFieldBlurred(sessionIdentifier: event.sessionIdentifier)
                    return
                }
                let target = Self.currentTypingTarget(sessionIdentifier: event.sessionIdentifier)
                // Screen Memory reads only apps in the Writing scope. A field
                // outside it ends the capture session instead of starting one.
                guard Self.preferences().allows(appBundleIdentifier: target?.bundleIdentifier) else {
                    await service.noteTextFieldBlurred(sessionIdentifier: event.sessionIdentifier)
                    return
                }
                switch event.kind {
                case .textFieldFocused:
                    _ = await service.noteTextFieldFocused(
                        sessionIdentifier: event.sessionIdentifier,
                        target: target
                    )
                case .typingPaused:
                    _ = await service.noteTypingPaused(
                        sessionIdentifier: event.sessionIdentifier,
                        target: target
                    )
                case .textFieldBlurred:
                    break
                case .contentReset:
                    _ = await service.noteContentReset(
                        sessionIdentifier: event.sessionIdentifier,
                        target: target
                    )
                }
            }
        }
    }

    /// The same settings gate `screenCaptureService`'s own `enabled`
    /// closure uses — a request must never surface screen context capture
    /// itself would refuse to have started. When the toggle is off, or
    /// Screen Recording was never granted (so no snapshot exists),
    /// `freshScene` returns `nil` and the prompt falls back to plain
    /// autocomplete — degraded, not dead.
    private nonisolated static func sceneProvider(
        for service: ScreenCaptureService
    ) -> @Sendable (
        String?, String, String?, TypingTargetIdentity?
    ) async -> ScreenScene.Scene? {
        { appBundleIdentifier, fieldText, fieldSessionIdentifier, expectedTarget in
            guard settings().screenMemoryEnabled,
                  preferences().allows(appBundleIdentifier: appBundleIdentifier) else { return nil }
            return await service.freshScene(
                frontmostBundleID: appBundleIdentifier,
                fieldText: fieldText,
                fieldSessionIdentifier: fieldSessionIdentifier,
                expectedTarget: expectedTarget
            )
        }
    }

    private nonisolated static func suggestionTargetProvider(
        _ appBundleIdentifier: String?,
        _ fieldSessionIdentifier: String?
    ) -> TypingTargetIdentity? {
        guard let fieldSessionIdentifier,
              let target = currentTypingTarget(sessionIdentifier: fieldSessionIdentifier),
              appBundleIdentifier == nil || target.bundleIdentifier == appBundleIdentifier else {
            return nil
        }
        return target
    }
}
