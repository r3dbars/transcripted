import Foundation

func testWorkCircuitDiagnostics() {
    runSuite("Native work diagnostics distinguish bounded worker sources without raw operations") {
        let hal = WorkCircuitDiagnostics.properties(source: .systemInput, operation: "start_recording_selection", inflight: 2)
        assertEqual(hal, ["work_source": "system_input", "work_step": "selection", "inflight_bucket": "2_3"])
        let graph = WorkCircuitDiagnostics.properties(source: .engineGraph, operation: "start_recording_snapshot", inflight: 4)
        assertEqual(graph, ["work_source": "engine_graph", "work_step": "snapshot", "inflight_bucket": "4_plus"])
        let unknown = WorkCircuitDiagnostics.properties(source: .systemInput, operation: "private-device-label", inflight: -1)
        assertEqual(unknown["work_step"], "unknown", "unexpected operation labels never become telemetry")
        assertEqual(unknown["inflight_bucket"], "unknown", "invalid counts stay unknown")
    }

    runSuite("Reviewed work diagnostics survive both real off-device policies and sanitizers") {
        let allowed = AnalyticsEventPolicy.policy(forEvent: "reliability_failure_observed")?.allowedProperties ?? []
        for source in WorkCircuitDiagnostics.Source.allCases {
            for count in [0, 1, 2, 3, 4, 100] {
                let context = WorkCircuitDiagnostics.properties(source: source, operation: "start_recording", inflight: count)
                assertEqual(SentryEventPolicy.diagnosticTags(forEngine: "parakeet", event: "audio_engine_work_circuit_open", context: context), context)
                assertEqual(SentryPayloadSanitizer.sanitizeContext(context), context)
                assertEqual(AnalyticsPayloadSanitizer.sanitizeProperties(context, allowedKeys: allowed), context)
            }
        }
    }

    runSuite("Work diagnostic keys reject free text, plausible unknown codes and untyped payloads") {
        let allowed = AnalyticsEventPolicy.policy(forEvent: "reliability_failure_observed")?.allowedProperties ?? []
        for key in WorkCircuitDiagnostics.keys {
            for invalid in ["private-device-label", "private words", "123456", "system_input\n", "/private/meeting.wav"] {
                let context = [key: invalid]
                assertEqual(SentryPayloadSanitizer.sanitizeTags(context), [:], "Sentry tag values must use the fixed vocabulary")
                assertEqual(SentryPayloadSanitizer.sanitizeContext(context), [:], "Sentry extras must use the fixed vocabulary")
                assertEqual(AnalyticsPayloadSanitizer.sanitizeProperties(context, allowedKeys: allowed), [:], "PostHog must use the same fixed vocabulary")
                assertTrue(SentryPayloadSanitizer.sanitizeAnyDictionary([key: [invalid]]).isEmpty, "untyped Sentry arrays must not bypass enum validation")
            }
            assertTrue(SentryPayloadSanitizer.sanitizeAnyDictionary([key: 123]).isEmpty, "untyped numeric values are not a reviewed bucket")
        }
    }
}
