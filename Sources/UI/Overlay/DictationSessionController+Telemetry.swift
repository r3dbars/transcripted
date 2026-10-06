// DictationSessionController+Telemetry.swift
// Start, stop and delivery diagnostics and analytics for dictation sessions.

import AppKit

extension DictationSessionController {
    /// Whether any dictation has been requested since this process launched.
    /// The first one is where a cold start shows (models warming at launch,
    /// the first mic bind), so both start events say whether they are it.
    private static var hasRequestedDictationThisLaunch = false

    /// Every dictation start a user asked for, emitted before anything can
    /// refuse or fail it. This is the denominator `dictation_started` cannot
    /// be: see the note at the call site in `startDictation`.
    ///
    /// `model_state` is sampled here rather than inferred later because a
    /// start that arrives while the model is still warming up fails for a
    /// different reason than one that arrives against a ready engine, and by
    /// the time a failure is reported the state has usually moved on.
    func trackDictationStartRequested(
        appState: TranscriptedAppState,
        trigger: DictationTrigger,
        isRetry: Bool
    ) {
        currentRequestIsFirstSinceLaunch = !Self.hasRequestedDictationThisLaunch
        Self.hasRequestedDictationThisLaunch = true
        var properties = appState.sttRouter.dictationAudioRouteAnalyticsContext
        properties["trigger"] = trigger.rawValue
        properties["start_retry"] = isRetry ? "true" : "false"
        properties["first_since_launch"] = currentRequestIsFirstSinceLaunch ? "true" : "false"
        properties["model_state"] = ProductFrictionTelemetry.modelState(
            isReady: appState.sttRouter.isModelLoaded
        )
        properties.merge(dictationSpeedContext(appState: appState)) { current, _ in current }

        AnalyticsReporter.track(
            "dictation_start_requested",
            properties: properties
        )
        DiagnosticsTrail.record(
            logger: appState.logger,
            engine: "dictation",
            event: "dictation_start_requested",
            message: "Dictation start requested",
            context: properties
        )
    }

    /// A start request refused by one of `startDictation`'s admission guards,
    /// before a session exists.
    ///
    /// It does not route through `trackDictationStartFailed` because that
    /// helper stamps `currentDictationSessionID`, which at this point still
    /// belongs to the *previous* dictation. A refused request has no session
    /// of its own, and borrowing the last one's id would invent a correlation
    /// that is not there. `start_attempt_bucket` is `"0"` for the same reason
    /// the permission failures report it that way: no microphone start was
    /// ever attempted.
    func trackDictationStartRefused(
        appState: TranscriptedAppState,
        trigger: DictationTrigger,
        failureKind: String
    ) {
        var properties = appState.sttRouter.dictationAudioRouteAnalyticsContext
        properties["start_attempt_bucket"] = "0"
        emitDictationStartFailed(
            failureKind,
            properties: properties,
            trigger: trigger
        )
    }

    func trackDictationStartFailed(
        _ failureKind: String,
        extra: [String: String] = [:]
    ) {
        emitDictationStartFailed(
            failureKind,
            properties: dictationAnalyticsProperties(extra: extra),
            trigger: currentDictationTrigger
        )
    }

    private func emitDictationStartFailed(
        _ failureKind: String,
        properties: [String: String],
        trigger: DictationTrigger
    ) {
        var analyticsProperties = properties
        analyticsProperties["failure_kind"] = failureKind
        analyticsProperties["trigger"] = trigger.rawValue

        AnalyticsReporter.track(
            "dictation_start_failed",
            properties: analyticsProperties
        )
        ProductFrictionTelemetry.track(
            surface: .dictation,
            stage: "dictation_start",
            result: .blocked,
            failureKind: failureKind,
            routeShape: analyticsProperties["route_shape"],
            modelState: ProductFrictionTelemetry.modelState(isReady: appState?.sttRouter.isModelLoaded),
            context: analyticsProperties
        )
    }

    func trackDictationDeliveryFriction(
        pasteOutcome: DictationPasteOutcome,
        saveSucceeded: Bool,
        elapsedSeconds: Double
    ) {
        if pasteOutcome.delivery == .failed {
            ProductFrictionTelemetry.track(
                surface: .dictation,
                stage: "pasteback",
                result: .failed,
                failureKind: pasteOutcome.failureReason?.rawValue ?? "pasteback_failed",
                elapsedBucket: AnalyticsReporter.durationBucket(seconds: elapsedSeconds),
                routeShape: dictationAnalyticsProperties()["route_shape"],
                modelState: ProductFrictionTelemetry.modelState(isReady: appState?.sttRouter.isModelLoaded)
            )
        } else if let copyReason = pasteOutcome.copyReason {
            ProductFrictionTelemetry.track(
                surface: .dictation,
                stage: "pasteback",
                result: .fallback,
                failureKind: "pasteback_\(copyReason.diagnosticName)",
                elapsedBucket: AnalyticsReporter.durationBucket(seconds: elapsedSeconds),
                routeShape: dictationAnalyticsProperties()["route_shape"],
                modelState: ProductFrictionTelemetry.modelState(isReady: appState?.sttRouter.isModelLoaded)
            )
        }

        guard !saveSucceeded else { return }
        ProductFrictionTelemetry.track(
            surface: .dictation,
            stage: "artifact_save",
            result: .failed,
            failureKind: "dictation_save_failed",
            elapsedBucket: AnalyticsReporter.durationBucket(seconds: elapsedSeconds),
            routeShape: dictationAnalyticsProperties()["route_shape"],
            modelState: ProductFrictionTelemetry.modelState(isReady: appState?.sttRouter.isModelLoaded)
        )
    }

    func recordDictationStopLatency(
        appState: TranscriptedAppState,
        timing: DictationStopTiming,
        sessionID: UUID,
        stopTrigger: DictationTrigger,
        startTrigger: DictationTrigger,
        pasteOutcome: DictationPasteOutcome,
        autoSendOutcome: DictationAutoSendOutcome,
        wordCount: Int,
        charCount: Int,
        cleanupEnabled: Bool,
        cleanupChanged: Bool,
        saveSucceeded: Bool
    ) {
        let measurements = timing.measurements()
        let saveOutcome = saveSucceeded ? "saved" : "failed"
        let outcome: String
        if !saveSucceeded {
            outcome = "save_failed"
        } else if pasteOutcome.delivery == .failed {
            outcome = "delivery_failed"
        } else {
            outcome = "completed"
        }

        var localContext: [String: String] = [
            "dictation_session_id": sessionID.uuidString,
            "start_trigger": startTrigger.rawValue,
            "stop_trigger": stopTrigger.rawValue,
            "delivery": pasteOutcome.delivery.rawValue,
            "auto_send": autoSendOutcome.diagnosticName,
            "save_outcome": saveOutcome,
            "outcome": outcome,
            "cleanup_enabled": "\(cleanupEnabled)",
            "cleanup_changed": "\(cleanupChanged)",
            "chars": "\(charCount)",
            "words": "\(wordCount)",
        ]
        if let copyReason = pasteOutcome.copyReason?.diagnosticName {
            localContext["copy_reason"] = copyReason
        }
        for (key, value) in measurements {
            localContext[key] = "\(value)"
        }
        if let firstSoundMs = pressToFirstSoundMilliseconds(appState: appState, stopRequestedAt: timing.requestedAt) {
            localContext["press_to_first_sound_ms"] = "\(firstSoundMs)"
        }

        DiagnosticsTrail.record(
            logger: appState.logger,
            level: pasteOutcome.delivery == .pasted && saveSucceeded ? .info : .warning,
            engine: "dictation",
            event: "dictation_stop_latency_measured",
            message: "Measured dictation stop latency",
            context: dictationContext(extra: localContext)
        )

        var analyticsProperties = dictationAnalyticsProperties(
            extra: [
                "trigger": stopTrigger.rawValue,
                "delivery": pasteOutcome.delivery.rawValue,
                "auto_send": autoSendOutcome.diagnosticName,
                "save_outcome": saveOutcome,
                "outcome": outcome,
                "cleanup_enabled": "\(cleanupEnabled)",
                "cleanup_changed": "\(cleanupChanged)",
                "word_count_bucket": AnalyticsReporter.wordCountBucket(wordCount),
            ]
        )
        if let copyReason = pasteOutcome.copyReason?.diagnosticName {
            analyticsProperties["copy_reason"] = copyReason
        }
        let autoSendTelemetry = DictationAutoSendTelemetry.snapshot(
            request: autoSendRequestDecision,
            pasteOutcome: pasteOutcome,
            sendOutcome: autoSendOutcome
        )
        analyticsProperties.merge(autoSendTelemetry.analyticsProperties) { _, new in new }
        analyticsProperties["target_confirmation_mode"] = DictationTargetConfirmationMode.resolve(
            outcome: pasteOutcome,
            diagnostic: textPaster.lastConfirmationDiagnostic
        ).rawValue
        let timingBuckets: [(metric: String, bucket: String)] = [
            ("stop_to_mic_stop_ms", "mic_stop_bucket"),
            ("snapshot_resample_ms", "resample_bucket"),
            ("recovery_checkpoint_ms", "checkpoint_bucket"),
            ("model_wait_ms", "model_wait_bucket"),
            ("decode_ms", "decode_bucket"),
            ("cleanup_ms", "cleanup_bucket"),
            ("paste_ms", "paste_bucket"),
            ("paste_confirmation_wait_ms", "paste_confirm_bucket"),
            ("auto_enter_ms", "auto_enter_bucket"),
            ("save_ms", "save_bucket"),
            ("stop_to_paste_ms", "stop_to_paste_bucket"),
            ("stop_to_done_ms", "stop_to_done_bucket"),
        ]
        for timingBucket in timingBuckets {
            guard let milliseconds = measurements[timingBucket.metric] else { continue }
            analyticsProperties[timingBucket.bucket] = AnalyticsReporter.latencyBucket(milliseconds: milliseconds)
        }
        // Exact (10 ms) timings next to the buckets, so PostHog can compute
        // real percentiles per model and per kind of Mac.
        let exactTimings: [(metric: String, key: String)] = [
            ("decode_ms", "decode_latency_ms"),
            ("stop_to_paste_ms", "stop_to_paste_latency_ms"),
            // When Cmd+V went out: the text usually shows here, before the
            // confirmation wait that stop_to_paste includes.
            ("stop_to_paste_dispatch_ms", "stop_to_paste_dispatch_latency_ms"),
        ]
        for exactTiming in exactTimings {
            guard let milliseconds = measurements[exactTiming.metric] else { continue }
            analyticsProperties[exactTiming.key] = MachineClassTelemetry.roundedMilliseconds(milliseconds)
        }
        if let firstSoundMs = pressToFirstSoundMilliseconds(appState: appState, stopRequestedAt: timing.requestedAt) {
            analyticsProperties["first_sound_latency_bucket"] = AnalyticsReporter.latencyBucket(milliseconds: firstSoundMs)
            analyticsProperties["first_sound_latency_ms"] = MachineClassTelemetry.roundedMilliseconds(firstSoundMs)
        }
        if let micBackend = timing.micBackend {
            analyticsProperties["mic_backend"] = micBackend
        }
        analyticsProperties.merge(dictationSpeedContext(appState: appState)) { current, _ in current }

        AnalyticsReporter.track(
            "dictation_stop_latency_measured",
            properties: analyticsProperties
        )
    }

    func dictationContext(extra: [String: String] = [:]) -> [String: String] {
        var context: [String: String] = [
            "session_id": currentDictationSessionID.uuidString,
            "correlation_id": currentDictationSessionID.uuidString,
            "trigger": currentDictationTrigger.rawValue,
            "audio_device": appState?.sttRouter.inputDeviceName ?? ""
        ]
        if let routeContext = appState?.sttRouter.dictationAudioRouteAnalyticsContext {
            for (key, value) in routeContext {
                context[key] = value
            }
        }

        for (key, value) in extra {
            context[key] = value
        }

        return context
    }

    /// Model and coarse Mac class, so dictation speed can be compared across
    /// models and machines. No device or user identifiers.
    func dictationSpeedContext(appState: TranscriptedAppState) -> [String: String] {
        var context = MachineClassTelemetry.current
        // The lease is the model this recording actually uses, even if the
        // setting changes mid-dictation.
        let model = appState.sttRouter.recordingModelLease?.model ?? appState.sttRouter.selectedModel
        context["stt_model"] = model.rawValue
        return context
    }

    /// Key press to the first real audio buffer of this dictation. Nil when
    /// the audio didn't come through the dictation engine (for example the
    /// shared meeting mic) or the stamp belongs to another session.
    private func pressToFirstSoundMilliseconds(
        appState: TranscriptedAppState,
        stopRequestedAt: CFAbsoluteTime
    ) -> Int? {
        guard let firstSampleAt = appState.sttRouter.parakeetEngine.firstAudioSampleTime(),
              firstSampleAt >= sessionStartTime,
              firstSampleAt <= stopRequestedAt else { return nil }
        return Int(((firstSampleAt - sessionStartTime) * 1_000).rounded())
    }

    func dictationAnalyticsProperties(extra: [String: String] = [:]) -> [String: String] {
        var properties = appState?.sttRouter.dictationAudioRouteAnalyticsContext ?? [:]
        properties["session_id"] = currentDictationSessionID.uuidString
        properties["correlation_id"] = currentDictationSessionID.uuidString
        properties["trigger"] = currentDictationTrigger.rawValue
        for (key, value) in extra {
            properties[key] = value
        }
        return properties
    }
}
