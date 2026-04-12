import Foundation

struct SentryEventPolicy: Equatable {
    let engine: String
    let event: String
    let summary: String

    static func policy(forEngine engine: String, event: String) -> SentryEventPolicy? {
        allowedPolicies["\(engine).\(event)"]
    }

    private static let allowedPolicies: [String: SentryEventPolicy] = [
        "parakeet.model_init_failed": .init(
            engine: "parakeet",
            event: "model_init_failed",
            summary: "Speech model initialization failed."
        ),
        "parakeet.prewarm_failed": .init(
            engine: "parakeet",
            event: "prewarm_failed",
            summary: "Speech engine prewarm failed."
        ),
        "parakeet.device_change_rewarm_failed": .init(
            engine: "parakeet",
            event: "device_change_rewarm_failed",
            summary: "Speech engine failed to rewarm after an audio device change."
        ),
        "parakeet.mic_not_authorized": .init(
            engine: "parakeet",
            event: "mic_not_authorized",
            summary: "Microphone permission was not authorized."
        ),
        "parakeet.resync_engine_failed": .init(
            engine: "parakeet",
            event: "resync_engine_failed",
            summary: "Speech engine failed while resyncing the audio graph."
        ),
        "parakeet.zero_sample_rate": .init(
            engine: "parakeet",
            event: "zero_sample_rate",
            summary: "Audio hardware reported an invalid sample rate."
        ),
        "parakeet.audio_format_failed": .init(
            engine: "parakeet",
            event: "audio_format_failed",
            summary: "Transcripted could not create the expected audio format."
        ),
        "parakeet.audio_engine_start_failed": .init(
            engine: "parakeet",
            event: "audio_engine_start_failed",
            summary: "Speech audio engine failed to start."
        ),
        "parakeet.asr_manager_unavailable": .init(
            engine: "parakeet",
            event: "asr_manager_unavailable",
            summary: "Speech transcription manager was unavailable."
        ),
        "parakeet.transcription_failed": .init(
            engine: "parakeet",
            event: "transcription_failed",
            summary: "Speech transcription failed."
        ),
        "capture.hotkey_register_failed": .init(
            engine: "capture",
            event: "hotkey_register_failed",
            summary: "Transcripted could not register a keyboard shortcut."
        ),
        "overlay.cgevent_create_failed": .init(
            engine: "overlay",
            event: "cgevent_create_failed",
            summary: "Transcripted could not create the paste event."
        ),
    ]
}
