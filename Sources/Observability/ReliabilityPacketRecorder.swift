import Foundation

struct ReliabilityPacket: Codable, Equatable {
    let timestamp: String
    let feature: String
    let stage: String
    let outcome: String
    let event: String
    let appVersion: String
    let osMajor: String
    let context: [String: String]

    var summaryLine: String {
        let contextSummary = context
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let prefix = "\(timestamp) \(feature).\(stage) \(outcome) event=\(event)"
        return contextSummary.isEmpty ? prefix : "\(prefix) \(contextSummary)"
    }
}

private actor ReliabilityPacketFileWriter {
    private let fileURL: URL
    private var handle: FileHandle?
    private var isPrepared = false
    private let encoder = JSONEncoder()

    init(fileURL: URL = ReliabilityPacketRecorder.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func append(_ packet: ReliabilityPacket) {
        let data: Data
        do {
            data = try encoder.encode(packet)
        } catch {
            fputs("⚠️ RELIABILITY | failed to encode packet '\(packet.event)': \(error.localizedDescription)\n", stderr)
            return
        }

        guard prepareIfNeeded() else { return }

        var lineData = data
        lineData.append(0x0A)
        if let handle {
            LockedFileAppender.append(lineData, to: handle)
        }
    }

    private func prepareIfNeeded() -> Bool {
        guard !isPrepared else { return true }

        let storageDir = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createPrivateDirectory(at: storageDir)
        } catch {
            fputs("⚠️ RELIABILITY | failed to create directory \(storageDir.path): \(error.localizedDescription)\n", stderr)
            return false
        }

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            FileManager.default.restrictFileToOwnerOnly(at: fileURL)
        }

        do {
            handle = try FileHandle(forWritingTo: fileURL)
            handle?.seekToEndOfFile()
            isPrepared = true
            return true
        } catch {
            fputs("⚠️ RELIABILITY | failed to open FileHandle for \(fileURL.path): \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    deinit {
        try? handle?.close()
    }
}

enum ReliabilityPacketRecorder {
    static let fileName = "reliability.jsonl"
    static let defaultRecentLimit = 8

    private static let writer = ReliabilityPacketFileWriter()
    private static let decoder = JSONDecoder()

    static func defaultFileURL() -> URL {
        FileManager.default.transcriptedLogsDirURL.appendingPathComponent(fileName)
    }

    static func record(event: ObservabilityEvent) {
        guard let packet = packet(from: event) else { return }
        Task.detached(priority: .utility) {
            await writer.append(packet)
        }
    }

    static func recentPacketSummaries(limit: Int = defaultRecentLimit, fileURL: URL = defaultFileURL()) -> [String] {
        guard limit > 0,
              let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return packetSummaries(fromJSONL: text, limit: limit)
    }

    static func packetSummaries(fromJSONL text: String, limit: Int = defaultRecentLimit) -> [String] {
        guard limit > 0 else { return [] }
        return text
            .split(separator: "\n")
            .suffix(limit)
            .compactMap { line -> String? in
                guard let data = String(line).data(using: .utf8),
                      let packet = try? decoder.decode(ReliabilityPacket.self, from: data) else {
                    return nil
                }
                return packet.summaryLine
            }
    }

    static func packet(from event: ObservabilityEvent) -> ReliabilityPacket? {
        guard let taxonomy = taxonomy(forEngine: event.engine, event: event.event) else { return nil }
        let context = sanitizedReliabilityContext(event.context ?? [:], taxonomy: taxonomy)
        return ReliabilityPacket(
            timestamp: event.timestamp,
            feature: taxonomy.feature,
            stage: taxonomy.stage,
            outcome: outcome(for: taxonomy, context: event.context ?? [:]),
            event: event.event,
            appVersion: event.appVersion,
            osMajor: "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)",
            context: context
        )
    }

    private struct Taxonomy {
        let feature: String
        let stage: String
        let defaultOutcome: String
    }

    private static func taxonomy(forEngine engine: String, event: String) -> Taxonomy? {
        switch (engine, event) {
        case ("meeting", "meeting_recording_started"):
            return .init(feature: "meeting", stage: "start", defaultOutcome: "success")
        case ("meeting", "meeting_start_failed"),
             ("meeting", "meeting_recording_start_failed"),
             ("meeting", "meeting_start_blocked_permission"):
            return .init(feature: "meeting", stage: "start", defaultOutcome: "failed_retryable")
        case ("meeting", "meeting_recording_stopped"):
            return .init(feature: "meeting", stage: "stop", defaultOutcome: "success")
        case ("meeting", "meeting_recording_stop_timeout_failed"),
             ("meeting", "recording_stop_timeout"),
             ("meeting", "meeting_recording_missing_mic_audio"):
            return .init(feature: "meeting", stage: "stop", defaultOutcome: "failed_retryable")
        case ("meeting", "meeting_recording_cancelled"):
            return .init(feature: "meeting", stage: "stop", defaultOutcome: "cancelled")
        case ("meeting", "meeting_transcript_saved"):
            return .init(feature: "meeting", stage: "save", defaultOutcome: "success")
        case ("meeting", "meeting_transcript_skipped"):
            return .init(feature: "meeting", stage: "transcribe", defaultOutcome: "skipped_expected")
        case ("meeting", "meeting_transcript_failed"):
            return .init(feature: "meeting", stage: "transcribe", defaultOutcome: "failed_retryable")
        case ("dictation", "dictation_started"):
            return .init(feature: "dictation", stage: "start", defaultOutcome: "success")
        case ("dictation", "dictation_cancelled"):
            return .init(feature: "dictation", stage: "stop", defaultOutcome: "cancelled")
        case ("dictation", "dictation_recording_interrupted"):
            return .init(feature: "dictation", stage: "recording", defaultOutcome: "failed_retryable")
        case ("dictation", "dictation_delivery_completed"):
            return .init(feature: "dictation", stage: "paste_back", defaultOutcome: "success")
        case ("overlay", "no_voice_input"):
            return .init(feature: "dictation", stage: "transcribe", defaultOutcome: "failed_retryable")
        case ("overlay", "dictation_timeout"),
             ("overlay", "session_timeout"):
            return .init(feature: "dictation", stage: "recording", defaultOutcome: "failed_retryable")
        case ("parakeet", "recording_recovered_device_change"),
             ("parakeet", "transcription_recovered"),
             ("parakeet", "zombie_engine_recovered"):
            return .init(feature: "dictation", stage: "device_change", defaultOutcome: "recovered")
        case ("parakeet", "device_change_rewarm_failed"),
             ("parakeet", "device_change_recovery_timeout"):
            return .init(feature: "dictation", stage: "device_change", defaultOutcome: "failed_retryable")
        case ("parakeet", "audio_engine_start_failed"),
             ("parakeet", "mic_not_authorized"),
             ("dictation", "microphone_start_timeout"):
            return .init(feature: "dictation", stage: "start", defaultOutcome: "failed_retryable")
        case ("parakeet", "transcription_complete"):
            return .init(feature: "dictation", stage: "transcribe", defaultOutcome: "success")
        case ("parakeet", "transcription_empty"),
             ("parakeet", "transcription_failed"),
             ("parakeet", "asr_manager_unavailable"):
            return .init(feature: "dictation", stage: "transcribe", defaultOutcome: "failed_retryable")
        case ("app", "unclean_shutdown_detected"):
            return .init(feature: "app", stage: "shutdown", defaultOutcome: "failed_retryable")
        case ("app", "session_stall_detected"):
            return .init(feature: "app", stage: "runtime", defaultOutcome: "failed_retryable")
        default:
            return nil
        }
    }

    private static func outcome(for taxonomy: Taxonomy, context: [String: String]) -> String {
        if taxonomy.feature == "meeting", taxonomy.stage == "stop" {
            if context["stop_timed_out"] == "true" {
                return "failed_retryable"
            }
            if intValue(context["audio_gaps"]) > 0 || intValue(context["device_switches"]) > 0 {
                return "recovered"
            }
        }

        if taxonomy.feature == "dictation", taxonomy.stage == "paste_back" {
            switch context["delivery"] {
            case "pasted":
                return "success"
            case "copied":
                return "degraded_success"
            case "failed":
                return "failed_retryable"
            default:
                break
            }
        }

        return taxonomy.defaultOutcome
    }

    private static func sanitizedReliabilityContext(_ context: [String: String], taxonomy: Taxonomy) -> [String: String] {
        var safe: [String: String] = [
            "feature": taxonomy.feature,
            "stage": taxonomy.stage,
        ]

        let allowedKeys: Set<String> = [
            "auto_send",
            "build_version",
            "calendar_granted",
            "capture_quality",
            "crash_reporting_enabled",
            "default_input_volume_after",
            "default_input_volume_before",
            "default_input_volume_during",
            "default_input_class",
            "default_output_volume_after",
            "default_output_volume_before",
            "default_output_volume_during",
            "default_output_class",
            "default_system_output_volume_after",
            "default_system_output_volume_before",
            "default_system_output_volume_during",
            "delivery",
            "display_status",
            "failure_kind",
            "format_ready",
            "hfp_suspected",
            "input_channels",
            "input_device_class",
            "input_rate_hz",
            "meeting_state",
            "mic_file_present",
            "mic_processing",
            "mic_processed_peak",
            "mic_raw_peak",
            "mic_recovering",
            "microphone_status",
            "output_channels",
            "output_device_class",
            "output_rate_hz",
            "pasteback_granted",
            "reason",
            "realtime_agc",
            "recovering",
            "recovery_attempt_bucket",
            "recovery_latency_bucket",
            "route_shape",
            "sample_flow_started",
            "selected_input_class",
            "selection_overrode_default",
            "selection_reason",
            "session_active",
            "session_kind",
            "session_stage",
            "stt_model",
            "stop_timed_out",
            "system_audio_recording_granted",
            "system_peak",
            "system_backend",
            "system_failed",
            "system_file_present",
            "system_output_device_class",
            "system_output_rate_hz",
            "system_rate_hz",
            "system_status",
            "trigger",
            "voice_processing",
            "voice_processing_active",
        ]

        for (key, value) in context where allowedKeys.contains(key) {
            let sanitized = AnalyticsPayloadSanitizer.sanitizeText(value)
            if !sanitized.isEmpty {
                safe[key] = sanitized
            }
        }

        if let durationBucket = durationBucket(fromMilliseconds: context["duration_ms"]) {
            safe["duration_bucket"] = durationBucket
        }
        if let queueDepth = context["queue_depth"] {
            safe["queue_depth_bucket"] = AnalyticsReporter.queueDepthBucket(intValue(queueDepth))
        }
        if let words = context["words"] {
            safe["word_count_bucket"] = AnalyticsReporter.wordCountBucket(intValue(words))
        }
        if let gaps = context["audio_gaps"] {
            safe["gap_count_bucket"] = AnalyticsReporter.countBucket(intValue(gaps))
        }
        if let switches = context["device_switches"] ?? context["route_change_count"] {
            safe["route_change_count_bucket"] = AnalyticsReporter.countBucket(intValue(switches))
        }
        if let systemFilePresent = context["system_file_present"] {
            safe["system_stream_present"] = systemFilePresent == "true" ? "true" : "false"
        }
        if taxonomy.defaultOutcome.hasPrefix("failed"), safe["failure_kind"] == nil {
            safe["failure_kind"] = "unknown"
        }

        return safe
    }

    private static func durationBucket(fromMilliseconds value: String?) -> String? {
        guard let value,
              let milliseconds = Double(value) else {
            return nil
        }
        return AnalyticsReporter.durationBucket(seconds: milliseconds / 1000)
    }

    private static func intValue(_ value: String?) -> Int {
        guard let value,
              let intValue = Int(value) else {
            return 0
        }
        return intValue
    }
}
