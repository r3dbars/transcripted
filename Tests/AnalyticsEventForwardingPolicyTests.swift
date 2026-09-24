// Pinned-device mic rollout telemetry: which local EventReporter events are
// forwarded to PostHog, with which bounded values, and which meeting
// snapshot fields reach the meeting analytics events.
//
// `AnalyticsEventForwardingPolicy` and `AnalyticsPayloadSanitizer` are in
// run-tests.sh's APP_SOURCES, so these are behavioral checks. EventReporter.swift
// is not (it drags in the file writer and CrashReporter), so its one call into
// the policy is pinned as source text at the end.

import Foundation

func testAnalyticsEventForwardingPolicy() {
    let pinnedSourceEvents = [
        "pinned_microphone_recording_started",
        "pinned_microphone_restarted",
        "pinned_microphone_device_switched",
        "pinned_microphone_fell_back_to_engine",
        "pinned_microphone_silent_input",
    ]

    runSuite("Every forwarded pinned-mic event is a registered PostHog event") {
        for name in AnalyticsEventForwardingPolicy.forwardedEventNames {
            assertNotNil(
                AnalyticsEventPolicy.policy(forEvent: name),
                "\(name) must be in Resources/analytics-events.psv or AnalyticsReporter drops it"
            )
        }

        var produced: Set<String> = []
        for event in pinnedSourceEvents {
            let forwarded = AnalyticsEventForwardingPolicy.forwardedEvent(engine: "parakeet", event: event, context: [:])
            assertNotNil(forwarded, "\(event) should be forwarded")
            if let forwarded { produced.insert(forwarded.name) }
        }
        assertEqual(
            produced,
            Set(AnalyticsEventForwardingPolicy.forwardedEventNames),
            "forwardedEventNames must list exactly what the table produces"
        )
    }

    runSuite("Forwarded pinned-mic properties are all allowlisted and survive the sanitizer") {
        let contexts: [String: [String: String]] = [
            "pinned_microphone_recording_started": [
                "backend": "pinned_ioproc",
                "reason": DictationInputDeviceSelectionReason.preferredBuiltInForBluetoothHeadset.rawValue,
                "selected_input_class": "built_in",
                "default_input_overridden": "true",
                "start_ms": "180",
            ],
            "pinned_microphone_restarted": ["trigger": "stall"],
            "pinned_microphone_device_switched": ["reason": DictationInputDeviceSelectionReason.defaultIsSafe.rawValue],
            "pinned_microphone_fell_back_to_engine": ["stage": "setup_timeout"],
            "pinned_microphone_silent_input": ["selected_input_class": "external", "action": "switched"],
        ]

        for (event, context) in contexts {
            guard let forwarded = AnalyticsEventForwardingPolicy.forwardedEvent(
                engine: "parakeet", event: event, context: context
            ), let policy = AnalyticsEventPolicy.policy(forEvent: forwarded.name) else {
                assertTrue(false, "\(event) should forward to a registered event")
                continue
            }
            for key in forwarded.properties.keys {
                assertTrue(policy.allowedProperties.contains(key), "\(forwarded.name) must allowlist \(key)")
            }
            let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
                forwarded.properties,
                allowedKeys: policy.allowedProperties
            )
            assertEqual(sanitized, forwarded.properties, "\(forwarded.name) properties should reach PostHog unchanged")
        }
    }

    runSuite("Pinned-mic start forwards bounded selection facts and a start latency bucket") {
        let forwarded = AnalyticsEventForwardingPolicy.forwardedEvent(
            engine: "parakeet",
            event: "pinned_microphone_recording_started",
            context: [
                "backend": "pinned_ioproc",
                "reason": DictationInputDeviceSelectionReason.preferredBuiltInForBluetoothHeadset.rawValue,
                "selected_input_class": "built_in",
                "default_input_overridden": "true",
                "start_ms": "180",
            ]
        )

        assertEqual(forwarded?.name, "dictation_pinned_microphone_recording_started")
        assertEqual(forwarded?.properties, [
            "mic_backend": "pinned_ioproc",
            "selection_reason": "preferredBuiltInForBluetoothHeadset",
            "selected_input_class": "built_in",
            "selection_overrode_default": "true",
            "start_latency_bucket": "100_249ms",
        ], "start should carry exactly the reviewed rollout facts")
    }

    runSuite("Pinned-mic values outside their sets become unknown or are left out") {
        let started = AnalyticsEventForwardingPolicy.forwardedEvent(
            engine: "parakeet",
            event: "pinned_microphone_recording_started",
            context: [
                "backend": "Jane's AirPods Pro",
                "reason": "picked /Users/jane/Library/whatever",
                "selected_input_class": "Jane's AirPods Pro",
                "default_input_overridden": "maybe",
                "start_ms": "slow",
                "audio_device": "Jane's AirPods Pro",
                "device_uid": "BuiltInMicrophoneDevice",
                "file_path": "/Users/jane/private.wav",
            ]
        )
        assertEqual(started?.properties, [
            "mic_backend": "unknown",
            "selection_reason": "unknown",
            "selected_input_class": "unknown",
        ], "free text must never be forwarded, and unparseable fields are dropped")

        assertEqual(
            AnalyticsEventForwardingPolicy.forwardedEvent(
                engine: "parakeet", event: "pinned_microphone_restarted", context: ["trigger": "format_change"]
            )?.properties,
            ["restart_trigger": "format_change"]
        )
        assertEqual(
            AnalyticsEventForwardingPolicy.forwardedEvent(
                engine: "parakeet", event: "pinned_microphone_restarted", context: ["trigger": "user pulled the cable"]
            )?.properties,
            ["restart_trigger": "unknown"]
        )
        for stage in ["setup_timeout", "unavailable", "start_failed"] {
            assertEqual(
                AnalyticsEventForwardingPolicy.forwardedEvent(
                    engine: "parakeet", event: "pinned_microphone_fell_back_to_engine", context: ["stage": stage]
                )?.properties,
                ["stage": stage],
                "\(stage) is a reviewed fallback stage"
            )
        }
        assertEqual(
            AnalyticsEventForwardingPolicy.forwardedEvent(
                engine: "parakeet",
                event: "pinned_microphone_fell_back_to_engine",
                context: ["stage": "prepare: The operation couldn't be completed. (OSStatus error 560227702.)"]
            )?.properties,
            ["stage": "unknown"],
            "a raw error must not ride in the stage"
        )
        assertEqual(
            AnalyticsEventForwardingPolicy.forwardedEvent(
                engine: "parakeet", event: "pinned_microphone_device_switched", context: ["reason": "Studio Display Microphone"]
            )?.properties,
            ["selection_reason": "unknown"]
        )
        assertEqual(
            AnalyticsEventForwardingPolicy.forwardedEvent(
                engine: "parakeet",
                event: "pinned_microphone_silent_input",
                context: ["selected_input_class": "bluetooth", "action": "kept"]
            )?.properties,
            ["selected_input_class": "bluetooth", "action": "kept"]
        )
        assertEqual(
            AnalyticsEventForwardingPolicy.forwardedEvent(
                engine: "parakeet",
                event: "pinned_microphone_silent_input",
                context: ["selected_input_class": "USB Audio CODEC", "action": "unplug"]
            )?.properties,
            ["selected_input_class": "unknown", "action": "unknown"]
        )
    }

    runSuite("Only the pinned-mic lifecycle is forwarded") {
        for (engine, event) in [
            ("parakeet", "recording_interrupted"),
            ("parakeet", "audio_samples_detected"),
            ("parakeet", "transcription_failed"),
            ("meeting", "pinned_microphone_recording_started"),
            ("dictation", "pinned_microphone_restarted"),
        ] {
            assertNil(
                AnalyticsEventForwardingPolicy.forwardedEvent(engine: engine, event: event, context: ["trigger": "stall"]),
                "\(engine).\(event) must not be forwarded"
            )
        }
    }

    runSuite("Pinned-mic dictation events are PostHog-only, never Sentry issues") {
        for event in pinnedSourceEvents {
            assertNil(
                SentryEventPolicy.policy(forEngine: "parakeet", event: event),
                "\(event) is a rollout rate, not a failure; keep it out of Sentry"
            )
        }
    }

    runSuite("Meeting analytics events carry the mic backend and pinned health buckets") {
        let meetingEvents = [
            "meeting_capture_health_snapshot",
            "meeting_capture_stopped_under_controller",
            "meeting_recording_cancelled",
            "meeting_recording_start_failed",
            "meeting_recording_started",
            "meeting_recording_stopped",
            "meeting_transcript_failed",
            "meeting_transcript_skipped",
        ]
        let snapshotFields = [
            "mic_backend": "pinned_ioproc",
            "pinned_mic_dropped_callback_bucket": "10_plus",
            "pinned_mic_gap_bucket": "2_3",
            "pinned_mic_padded_bucket": "lt_1s",
            "pinned_mic_restart_bucket": "1",
        ]
        let rawCounts = [
            "pinned_mic_dropped_callback_count": "14",
            "pinned_mic_gap_count": "3",
            "pinned_mic_padded_seconds": "0",
            "pinned_mic_restart_count": "1",
        ]

        for event in meetingEvents {
            guard let policy = AnalyticsEventPolicy.policy(forEvent: event) else {
                assertTrue(false, "\(event) should be registered")
                continue
            }
            // Same set as the comparable mic-health field.
            assertTrue(policy.allowedProperties.contains("mic_recovering"), "\(event) carries mic health")
            let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
                snapshotFields.merging(rawCounts) { current, _ in current },
                allowedKeys: policy.allowedProperties
            )
            assertEqual(sanitized, snapshotFields, "\(event) keeps the backend and buckets and drops raw counts")
        }

        assertEqual(
            AnalyticsPayloadSanitizer.sanitizeProperties(
                ["mic_backend": "Jane's MacBook Pro Microphone"],
                allowedKeys: ["mic_backend"]
            ),
            [:],
            "mic_backend must be a code, not a device label"
        )
        assertEqual(
            AnalyticsPayloadSanitizer.sanitizeProperties(["mic_backend": "av_audio_engine"], allowedKeys: ["mic_backend"]),
            ["mic_backend": "av_audio_engine"]
        )

        let everyAllowed = Set(AnalyticsEventPolicy.allPolicies.flatMap { $0.allowedProperties })
        for key in rawCounts.keys {
            assertFalse(everyAllowed.contains(key), "raw pinned count \(key) must stay local")
        }
    }

    runSuite("EventReporter forwards the caller's context, not the merged engine state") {
        let source = readSourceFixture("Sources/Observability/EventReporter.swift")
        assertTrue(
            source.contains("AnalyticsEventForwardingPolicy.forwardedEvent("),
            "EventReporter.capture must consult the forwarding policy or the pinned-mic counts never leave the device"
        )
        assertTrue(
            source.contains("context: context ?? [:]"),
            "the policy gets the caller's context; mergedContext carries engine state it has no business reading"
        )
    }
}
