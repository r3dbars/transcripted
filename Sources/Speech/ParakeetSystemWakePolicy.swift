// ParakeetSystemWakePolicy.swift
// Pure decision for how ParakeetEngine's system-wake handler should react,
// mirroring the shared-meeting-mic guard already used by
// ParakeetDeviceRecovery's config-change handler (see handleAudioConfigChange
// in ParakeetDeviceRecovery.swift). Kept separate and pure so the guard has
// direct test coverage independent of AVAudioEngine/EventReporter.

enum ParakeetSystemWakeDecision: Equatable {
    /// Meeting capture owns the live audio graph while dictation borrows its
    /// PCM. Wake belongs to the meeting recovery path; do not wake or rebuild
    /// the dormant dictation AVAudioEngine out from under it.
    case skipSharedMeetingMic
    /// Dictation owns its own audio graph; tear it down and, if a recording
    /// was in progress, mark it interrupted.
    case tearDownAudioGraph
}

enum ParakeetSystemWakePolicy {
    static func decision(sharedMeetingMicRecording: Bool) -> ParakeetSystemWakeDecision {
        sharedMeetingMicRecording ? .skipSharedMeetingMic : .tearDownAudioGraph
    }
}
