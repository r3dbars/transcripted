import Foundation

extension TranscriptedSettingsView {
    /// The "Muffle other audio" toggle changed. Turning it off mid-take lets
    /// the music back in at once. Turning it on asks for System Audio
    /// Recording here, where the user just chose the feature, so dictation
    /// never has to prompt; the status read is a round trip to the privacy
    /// service, so it stays off the click.
    static func dictationMuffleSettingChanged(_ enabled: Bool) {
        DictationAudioMuffler.shared.settingChanged(enabled: enabled)
        guard enabled else { return }
        Task { @MainActor in
            let status = await Task.detached(priority: .userInitiated) {
                TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem()
            }.value
            guard status == .notDetermined else { return }
            _ = await TranscriptedPermissionAccess.requestSystemAudioCaptureAccess()
        }
    }
}
