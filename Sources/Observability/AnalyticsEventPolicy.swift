import Foundation

/// Privacy allowlist for anonymous PostHog analytics events.
///
/// The event-to-property registry is single-sourced from
/// `Resources/analytics-events.psv` (one `event_name|prop,prop,...` line per
/// event). That data file is marked `merge=union` in `.gitattributes`, so two
/// telemetry PRs that each add a new event append independent lines instead of
/// colliding on a shared multi-line Swift dictionary anchor. This file compiles
/// the data into the allowlist the rest of the app consumes.
struct AnalyticsEventPolicy: Equatable {
    let name: String
    let allowedProperties: Set<String>

    static func policy(forEvent event: String) -> AnalyticsEventPolicy? {
        allowedPolicies[event]
    }

    /// All allowlisted analytics event names, sorted. Exposed so tests can assert
    /// source-vs-docs parity against the compiled policy table instead of parsing this file's text.
    static var allEventNames: [String] {
        allowedPolicies.keys.sorted()
    }

    /// All allowlisted analytics policies, sorted by event name. Tests use this
    /// to keep the public taxonomy doc in lockstep with the compiled allowlist.
    static var allPolicies: [AnalyticsEventPolicy] {
        allowedPolicies.keys.sorted().compactMap { allowedPolicies[$0] }
    }

    private static let allowedPolicies: [String: AnalyticsEventPolicy] =
        parse(registry: loadRegistryText() ?? "")

    static func parse(registry text: String) -> [String: AnalyticsEventPolicy] {
        var table: [String: AnalyticsEventPolicy] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let pipe = line.firstIndex(of: "|") else {
                continue
            }

            let name = String(line[..<pipe]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }

            let properties = line[line.index(after: pipe)...]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            table[name] = AnalyticsEventPolicy(name: name, allowedProperties: Set(properties))
        }

        return table
    }

    private static let registryResourceName = "analytics-events"
    private static let registryResourceExtension = "psv"

    private static func loadRegistryText() -> String? {
        if let url = Bundle.main.url(
            forResource: registryResourceName,
            withExtension: registryResourceExtension
        ), let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }

        let relativePath = "Resources/\(registryResourceName).\(registryResourceExtension)"

        let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(relativePath)
        if let text = try? String(contentsOf: cwdURL, encoding: .utf8) {
            return text
        }

        let repoRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try? String(contentsOf: repoRootURL, encoding: .utf8)
    }
}

/// Local `EventReporter` events that also count in PostHog.
///
/// PostHog only hears explicit `AnalyticsReporter.track` calls, and Sentry only
/// hears allowlisted `.error` events, so an `.info`/`.warning` EventReporter
/// event normally never leaves the machine. The pinned-device dictation mic
/// (`Sources/Speech/ParakeetPinnedMicrophone.swift`) reports its lifecycle that
/// way, and the rollout decision needs fleet counts of it: how often it starts,
/// restarts, moves devices, hears silence, or gives up and falls back to the
/// `AVAudioEngine` path. `EventReporter.capture` asks this table for every
/// event and tracks the returned PostHog event.
///
/// Positive allowlist in both directions: only the events below are forwarded,
/// each property is rebuilt from one caller key, and every value is checked
/// against a fixed set (or bucketed) here. Anything else, including a value
/// outside its set, becomes `unknown` or is left out. The merged engine-state
/// context is deliberately not consulted. Device names, UIDs, and paths never
/// appear in these contexts, and nothing here could carry one through.
///
/// None of these are Sentry events. They are rates, not failures: a fallback
/// still records through the engine path, and restarts/switches are the
/// recorder healing itself. The pinned path's real failures (`capture_failed`,
/// `device_lost`) already report `parakeet.recording_interrupted`.
enum AnalyticsEventForwardingPolicy {
    struct ForwardedEvent: Equatable {
        let name: String
        let properties: [String: String]
    }

    /// Every PostHog event this table can produce. Tests assert each one is in
    /// `Resources/analytics-events.psv`, because the emitter check cannot see
    /// a name dispatched through a variable.
    static let forwardedEventNames: [String] = [
        "dictation_pinned_microphone_device_switched",
        "dictation_pinned_microphone_fell_back_to_engine",
        "dictation_pinned_microphone_recording_started",
        "dictation_pinned_microphone_restarted",
        "dictation_pinned_microphone_silent_input",
    ]

    static let pinnedMicrophoneBackends: Set<String> = ["pinned_ioproc"]
    /// `DictationInputDeviceSelectionPolicy.deviceClass(for:)` outputs.
    static let pinnedMicrophoneInputClasses: Set<String> = [
        "aggregate", "bluetooth", "built_in", "external", "unknown", "virtual",
    ]
    /// `PinnedMicrophoneRestartTrigger` raw values.
    static let pinnedMicrophoneRestartTriggers: Set<String> = ["format_change", "stall"]
    static let pinnedMicrophoneFallbackStages: Set<String> = ["setup_timeout", "start_failed", "unavailable"]
    static let pinnedMicrophoneSilentInputActions: Set<String> = ["kept", "switched"]

    static func forwardedEvent(
        engine: String,
        event: String,
        context: [String: String]
    ) -> ForwardedEvent? {
        guard engine == "parakeet" else { return nil }

        switch event {
        case "pinned_microphone_recording_started":
            var properties = [
                "mic_backend": bounded(context["backend"], to: pinnedMicrophoneBackends),
                "selection_reason": selectionReason(context["reason"]),
                "selected_input_class": bounded(context["selected_input_class"], to: pinnedMicrophoneInputClasses),
            ]
            if let overridden = boolean(context["default_input_overridden"]) {
                properties["selection_overrode_default"] = overridden
            }
            if let startBucket = AnalyticsReporter.latencyBucket(fromMilliseconds: context["start_ms"]) {
                properties["start_latency_bucket"] = startBucket
            }
            return ForwardedEvent(name: "dictation_pinned_microphone_recording_started", properties: properties)
        case "pinned_microphone_restarted":
            return ForwardedEvent(
                name: "dictation_pinned_microphone_restarted",
                properties: ["restart_trigger": bounded(context["trigger"], to: pinnedMicrophoneRestartTriggers)]
            )
        case "pinned_microphone_device_switched":
            return ForwardedEvent(
                name: "dictation_pinned_microphone_device_switched",
                properties: ["selection_reason": selectionReason(context["reason"])]
            )
        case "pinned_microphone_fell_back_to_engine":
            return ForwardedEvent(
                name: "dictation_pinned_microphone_fell_back_to_engine",
                properties: ["stage": bounded(context["stage"], to: pinnedMicrophoneFallbackStages)]
            )
        case "pinned_microphone_silent_input":
            return ForwardedEvent(
                name: "dictation_pinned_microphone_silent_input",
                properties: [
                    "selected_input_class": bounded(context["selected_input_class"], to: pinnedMicrophoneInputClasses),
                    "action": bounded(context["action"], to: pinnedMicrophoneSilentInputActions),
                ]
            )
        default:
            return nil
        }
    }

    private static func bounded(_ value: String?, to allowed: Set<String>) -> String {
        guard let value, allowed.contains(value) else { return "unknown" }
        return value
    }

    /// Selection reasons are `DictationInputDeviceSelectionReason` raw values,
    /// so the enum itself is the bound.
    private static func selectionReason(_ value: String?) -> String {
        guard let value, DictationInputDeviceSelectionReason(rawValue: value) != nil else { return "unknown" }
        return value
    }

    private static func boolean(_ value: String?) -> String? {
        switch value {
        case "true": return "true"
        case "false": return "false"
        default: return nil
        }
    }
}
