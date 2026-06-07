import Foundation

func testMeetingRouteFixture() {
    runSuite("Deterministic meeting route fixtures classify Zoom/WebRTC-shaped routes") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("transcripted-route-fixtures-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for scenario in MeetingRouteFixtureScenario.issue500Scenarios {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let result = scenario.run(in: root)

            assertEqual(result.diagnostics["quiet_mic_recovered"], scenario.expectedDiagnostics.quietMicRecovered, "\(scenario.id) quiet mic recovery")
            assertEqual(result.diagnostics["quiet_mic_unrecovered"], scenario.expectedDiagnostics.quietMicUnrecovered, "\(scenario.id) quiet mic failure")
            assertEqual(result.diagnostics["attenuation_kind"], scenario.expectedDiagnostics.attenuationKind, "\(scenario.id) attenuation kind")
            assertEqual(result.diagnostics["output_ducking_detected"], scenario.expectedDiagnostics.outputDuckingDetected, "\(scenario.id) output ducking")
            assertEqual(result.diagnostics["system_stream_present"], scenario.expectedDiagnostics.systemStreamPresent, "\(scenario.id) system stream presence")
            assertEqual(result.diagnostics["route_change_count"], scenario.expectedDiagnostics.routeChangeCount, "\(scenario.id) route-change count")

            assertEqual(result.explanation.outcomeKind, scenario.expectedOutcome, "\(scenario.id) outcome")
            assertEqual(result.explanation.artifactRetention, scenario.expectedArtifactRetention, "\(scenario.id) artifact retention")
            assertEqual(result.explanation.userVisibleState, scenario.expectedUserVisibleState, "\(scenario.id) user-visible state")
            assertEqual(result.explanation.retryability, scenario.expectedRetryability, "\(scenario.id) retryability")

            assertEqual(result.artifacts.transcriptExists, scenario.expectedArtifacts.transcript, "\(scenario.id) transcript artifact")
            assertEqual(result.artifacts.micAudioExists, scenario.expectedArtifacts.micAudio, "\(scenario.id) mic audio artifact")
            assertEqual(result.artifacts.systemAudioExists, scenario.expectedArtifacts.systemAudio, "\(scenario.id) system audio artifact")
            assertEqual(result.artifacts.failedQueueEntryExists, scenario.expectedArtifacts.failedQueueEntry, "\(scenario.id) failed-queue artifact")
            assertTrue(result.isPrivacySafe, "\(scenario.id) should keep fixture content synthetic and local-safe")
        }
    }

    runSuite("Deterministic meeting route fixtures prove saved transcript frontmatter") {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("transcripted-route-fixtures-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let savedScenario = MeetingRouteFixtureScenario.issue500Scenarios.first {
            $0.expectedArtifacts.transcript
        }

        guard let savedScenario else {
            assertionFailure("fixture list should include a saved transcript scenario")
            return
        }

        let result = savedScenario.run(in: root)
        guard let transcriptURL = result.artifacts.transcriptURL,
              let raw = try? String(contentsOf: transcriptURL, encoding: .utf8),
              let values = TranscriptFrontmatter.values(in: raw) else {
            assertionFailure("saved fixture transcript should parse")
            return
        }

        assertEqual(values["capture_type"], "meeting", "fixture transcript should stay meeting-shaped")
        assertEqual(values["fixture_kind"], "deterministic_meeting_route", "fixture transcript should name the synthetic route proof")
        assertEqual(values["route_fixture_id"], savedScenario.id, "fixture transcript should identify the route scenario")
        assertTrue(raw.contains("Transcripted route fixture one two three."), "fixture transcript should use synthetic speech only")
    }
}

private struct MeetingRouteFixtureScenario {
    let id: String
    let displayName: String
    let baseContext: [String: String]
    let afterStopContext: [String: String]
    let failureKind: MeetingFailureKind?
    let stage: CaptureFailureStage
    let isRetryable: Bool
    let transcriptSaved: Bool
    let failedQueueEntryRetained: Bool
    let expectedDiagnostics: ExpectedRouteDiagnostics
    let expectedOutcome: AudioReliabilityOutcomeKind
    let expectedArtifactRetention: ArtifactRetention
    let expectedUserVisibleState: AudioReliabilityUserVisibleState
    let expectedRetryability: Retryability
    let expectedArtifacts: ExpectedRouteArtifacts

    static let issue500Scenarios: [MeetingRouteFixtureScenario] = [
        MeetingRouteFixtureScenario(
            id: "webrtc-shared-mic-system-present",
            displayName: "WebRTC shared mic with system audio present",
            baseContext: [
                "input_device_class": "built_in",
                "output_device_class": "built_in",
                "system_output_device_class": "built_in",
                "default_output_volume_before": "0.740",
                "default_output_volume_during": "0.740",
                "default_system_output_volume_before": "0.740",
                "default_system_output_volume_during": "0.740",
                "mic_raw_peak": "0.18000",
                "mic_processed_peak": "0.26000",
                "system_peak": "0.22000",
                "system_stream_present": "true",
                "route_change_count": "0",
                "gap_count": "0"
            ],
            afterStopContext: [
                "default_output_volume_after": "0.740",
                "default_system_output_volume_after": "0.740"
            ],
            failureKind: nil,
            stage: .save,
            isRetryable: false,
            transcriptSaved: true,
            failedQueueEntryRetained: false,
            expectedDiagnostics: ExpectedRouteDiagnostics(
                quietMicRecovered: "false",
                quietMicUnrecovered: "false",
                attenuationKind: "none",
                outputDuckingDetected: "false",
                systemStreamPresent: "true",
                routeChangeCount: "0"
            ),
            expectedOutcome: .success,
            expectedArtifactRetention: .retainedPartialTranscript,
            expectedUserVisibleState: .transcriptSaved,
            expectedRetryability: .permanent,
            expectedArtifacts: ExpectedRouteArtifacts(
                transcript: true,
                micAudio: true,
                systemAudio: true,
                failedQueueEntry: false
            )
        ),
        MeetingRouteFixtureScenario(
            id: "webrtc-quiet-mic-recovered",
            displayName: "WebRTC quiet mic recovered by processed path",
            baseContext: [
                "input_device_class": "built_in",
                "output_device_class": "built_in",
                "system_output_device_class": "built_in",
                "default_input_volume_before": "0.800",
                "default_input_volume_during": "0.800",
                "default_output_volume_before": "0.720",
                "default_output_volume_during": "0.720",
                "default_system_output_volume_before": "0.720",
                "default_system_output_volume_during": "0.720",
                "mic_raw_peak": "0.03000",
                "mic_processed_peak": "0.36000",
                "system_peak": "0.18000",
                "system_stream_present": "true",
                "route_change_count": "0",
                "gap_count": "0"
            ],
            afterStopContext: [
                "default_input_volume_after": "0.800",
                "default_output_volume_after": "0.720",
                "default_system_output_volume_after": "0.720"
            ],
            failureKind: nil,
            stage: .save,
            isRetryable: false,
            transcriptSaved: true,
            failedQueueEntryRetained: false,
            expectedDiagnostics: ExpectedRouteDiagnostics(
                quietMicRecovered: "true",
                quietMicUnrecovered: "false",
                attenuationKind: "voice_processed",
                outputDuckingDetected: "false",
                systemStreamPresent: "true",
                routeChangeCount: "0"
            ),
            expectedOutcome: .success,
            expectedArtifactRetention: .retainedPartialTranscript,
            expectedUserVisibleState: .transcriptSaved,
            expectedRetryability: .permanent,
            expectedArtifacts: ExpectedRouteArtifacts(
                transcript: true,
                micAudio: true,
                systemAudio: true,
                failedQueueEntry: false
            )
        ),
        MeetingRouteFixtureScenario(
            id: "zoom-system-audio-missing-after-start",
            displayName: "Zoom-style system audio missing after start",
            baseContext: [
                "input_device_class": "built_in",
                "output_device_class": "built_in",
                "system_output_device_class": "built_in",
                "default_output_volume_before": "0.700",
                "default_output_volume_during": "0.700",
                "default_system_output_volume_before": "0.700",
                "default_system_output_volume_during": "0.700",
                "mic_raw_peak": "0.17000",
                "mic_processed_peak": "0.25000",
                "system_peak": "0.00000",
                "system_stream_present": "false",
                "route_change_count": "1",
                "gap_count": "1"
            ],
            afterStopContext: [
                "default_output_volume_after": "0.700",
                "default_system_output_volume_after": "0.700"
            ],
            failureKind: .audioDeviceUnavailable,
            stage: .activeCapture,
            isRetryable: true,
            transcriptSaved: false,
            failedQueueEntryRetained: true,
            expectedDiagnostics: ExpectedRouteDiagnostics(
                quietMicRecovered: "false",
                quietMicUnrecovered: "false",
                attenuationKind: "none",
                outputDuckingDetected: "false",
                systemStreamPresent: "false",
                routeChangeCount: "1"
            ),
            expectedOutcome: .recoverableFailure,
            expectedArtifactRetention: .retainedFailedQueueEntry,
            expectedUserVisibleState: .retryAvailable,
            expectedRetryability: .retryable,
            expectedArtifacts: ExpectedRouteArtifacts(
                transcript: false,
                micAudio: true,
                systemAudio: false,
                failedQueueEntry: true
            )
        ),
        MeetingRouteFixtureScenario(
            id: "zoom-output-ducking-route-change-stop-timeout",
            displayName: "Zoom-style output ducking with route churn and stop timeout",
            baseContext: [
                "input_device_class": "built_in",
                "output_device_class": "bluetooth",
                "system_output_device_class": "bluetooth",
                "default_output_volume_before": "0.760",
                "default_output_volume_during": "0.480",
                "default_system_output_volume_before": "0.760",
                "default_system_output_volume_during": "0.760",
                "mic_raw_peak": "0.04000",
                "mic_processed_peak": "0.30000",
                "system_peak": "0.21000",
                "system_stream_present": "true",
                "route_change_count": "4",
                "gap_count": "2",
                "stop_timed_out": "true"
            ],
            afterStopContext: [
                "default_output_volume_after": "0.760",
                "default_system_output_volume_after": "0.760"
            ],
            failureKind: .stopTimeout,
            stage: .activeCapture,
            isRetryable: true,
            transcriptSaved: false,
            failedQueueEntryRetained: true,
            expectedDiagnostics: ExpectedRouteDiagnostics(
                quietMicRecovered: "true",
                quietMicUnrecovered: "false",
                attenuationKind: "voice_processed",
                outputDuckingDetected: "true",
                systemStreamPresent: "true",
                routeChangeCount: "4"
            ),
            expectedOutcome: .recoverableFailure,
            expectedArtifactRetention: .retainedFailedQueueEntry,
            expectedUserVisibleState: .retryAvailable,
            expectedRetryability: .retryable,
            expectedArtifacts: ExpectedRouteArtifacts(
                transcript: false,
                micAudio: true,
                systemAudio: true,
                failedQueueEntry: true
            )
        ),
        MeetingRouteFixtureScenario(
            id: "webrtc-quiet-mic-unrecovered",
            displayName: "WebRTC quiet mic not recovered",
            baseContext: [
                "input_device_class": "built_in",
                "output_device_class": "built_in",
                "system_output_device_class": "built_in",
                "default_input_volume_before": "0.800",
                "default_input_volume_during": "0.800",
                "mic_raw_peak": "0.02000",
                "mic_processed_peak": "0.07000",
                "system_peak": "0.16000",
                "system_stream_present": "true",
                "route_change_count": "0",
                "gap_count": "0"
            ],
            afterStopContext: [
                "default_input_volume_after": "0.800"
            ],
            failureKind: .transcriptionInferenceFailed,
            stage: .transcription,
            isRetryable: true,
            transcriptSaved: false,
            failedQueueEntryRetained: true,
            expectedDiagnostics: ExpectedRouteDiagnostics(
                quietMicRecovered: "false",
                quietMicUnrecovered: "true",
                attenuationKind: "voice_processed",
                outputDuckingDetected: "unavailable",
                systemStreamPresent: "true",
                routeChangeCount: "0"
            ),
            expectedOutcome: .recoverableFailure,
            expectedArtifactRetention: .retainedFailedQueueEntry,
            expectedUserVisibleState: .retryAvailable,
            expectedRetryability: .retryable,
            expectedArtifacts: ExpectedRouteArtifacts(
                transcript: false,
                micAudio: true,
                systemAudio: true,
                failedQueueEntry: true
            )
        )
    ]

    func run(in root: URL) -> MeetingRouteFixtureResult {
        let scenarioRoot = root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: scenarioRoot, withIntermediateDirectories: true)

        let micURL = scenarioRoot.appendingPathComponent("mic.synthetic.wav")
        let systemURL = scenarioRoot.appendingPathComponent("system.synthetic.wav")
        let transcriptURL = scenarioRoot.appendingPathComponent("transcript.md")
        let failureURL = scenarioRoot.appendingPathComponent("failed-meeting.json")

        if expectedArtifacts.micAudio {
            try? Self.syntheticWAV(amplitude: 2_400).write(to: micURL)
        }
        if expectedArtifacts.systemAudio {
            try? Self.syntheticWAV(amplitude: 3_200).write(to: systemURL)
        }
        if transcriptSaved {
            try? transcriptMarkdown(micURL: micURL, systemURL: expectedArtifacts.systemAudio ? systemURL : nil)
                .write(to: transcriptURL, atomically: true, encoding: .utf8)
        }
        if failedQueueEntryRetained {
            try? failedQueueJSON(micURL: expectedArtifacts.micAudio ? micURL : nil, systemURL: expectedArtifacts.systemAudio ? systemURL : nil)
                .write(to: failureURL, atomically: true, encoding: .utf8)
        }

        let diagnostics = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: baseContext,
            afterStopContext: afterStopContext
        )
        let hasAudioFiles = expectedArtifacts.micAudio || expectedArtifacts.systemAudio
        let explanation = MeetingFailureExplanation.make(
            failureKind: failureKind,
            hasAudioFiles: hasAudioFiles,
            isRetryable: isRetryable,
            stage: stage,
            transcriptSaved: transcriptSaved,
            failedQueueEntryRetained: failedQueueEntryRetained
        )

        let artifacts = MeetingRouteFixtureArtifacts(
            transcriptURL: transcriptSaved ? transcriptURL : nil,
            failedQueueEntryURL: failedQueueEntryRetained ? failureURL : nil,
            transcriptExists: FileManager.default.fileExists(atPath: transcriptURL.path),
            micAudioExists: FileManager.default.fileExists(atPath: micURL.path),
            systemAudioExists: FileManager.default.fileExists(atPath: systemURL.path),
            failedQueueEntryExists: FileManager.default.fileExists(atPath: failureURL.path)
        )

        return MeetingRouteFixtureResult(
            diagnostics: diagnostics,
            explanation: explanation,
            artifacts: artifacts,
            isPrivacySafe: isPrivacySafe(artifacts: artifacts)
        )
    }

    private func transcriptMarkdown(micURL: URL, systemURL: URL?) -> String {
        """
        ---
        capture_type: meeting
        fixture_kind: deterministic_meeting_route
        route_fixture_id: \(id)
        route_fixture_name: \(displayName)
        mic_audio: \(micURL.lastPathComponent)
        system_audio: \(systemURL?.lastPathComponent ?? "unavailable")
        ---

        # Synthetic Meeting Route Fixture

        You: Transcripted route fixture one two three.
        Speaker 1: System audio fixture tone acknowledged.
        """
    }

    private func failedQueueJSON(micURL: URL?, systemURL: URL?) -> String {
        """
        {
          "fixture_kind": "deterministic_meeting_route",
          "route_fixture_id": "\(id)",
          "failure_kind": "\(failureKind?.rawValue ?? "none")",
          "mic_audio": "\(micURL?.lastPathComponent ?? "none")",
          "system_audio": "\(systemURL?.lastPathComponent ?? "none")"
        }
        """
    }

    private func isPrivacySafe(artifacts: MeetingRouteFixtureArtifacts) -> Bool {
        let textURLs = [artifacts.transcriptURL, artifacts.failedQueueEntryURL].compactMap { $0 }
        let forbiddenFragments = [
            "/Users/",
            "@",
            "http://",
            "https://",
            "Justin",
            "Zoom transcript",
            "meeting title"
        ]

        for url in textURLs {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                return false
            }
            if forbiddenFragments.contains(where: raw.contains) {
                return false
            }
        }

        return true
    }

    private static func syntheticWAV(amplitude: Int16) -> Data {
        let sampleRate: UInt32 = 16_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let frameCount = 1_600
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataSize = UInt32(frameCount * bytesPerSample)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36) + dataSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(dataSize)

        for index in 0..<frameCount {
            let sample = index.isMultiple(of: 2) ? amplitude : -amplitude
            data.appendLittleEndian(UInt16(bitPattern: sample))
        }

        return data
    }
}

private struct ExpectedRouteDiagnostics {
    let quietMicRecovered: String
    let quietMicUnrecovered: String
    let attenuationKind: String
    let outputDuckingDetected: String
    let systemStreamPresent: String
    let routeChangeCount: String
}

private struct ExpectedRouteArtifacts {
    let transcript: Bool
    let micAudio: Bool
    let systemAudio: Bool
    let failedQueueEntry: Bool
}

private struct MeetingRouteFixtureArtifacts {
    let transcriptURL: URL?
    let failedQueueEntryURL: URL?
    let transcriptExists: Bool
    let micAudioExists: Bool
    let systemAudioExists: Bool
    let failedQueueEntryExists: Bool
}

private struct MeetingRouteFixtureResult {
    let diagnostics: [String: String]
    let explanation: MeetingFailureExplanation
    let artifacts: MeetingRouteFixtureArtifacts
    let isPrivacySafe: Bool
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(string.data(using: .ascii) ?? Data())
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
