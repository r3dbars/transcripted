import Foundation

/// Persisted behavior preferences for the meeting recording pill.
///
/// The pill rests down to a compact capsule when it has not been hovered for
/// a few seconds (Dynamic Island style). "Keep controls visible" is the
/// escape hatch for users who want the full pill pinned at all times; it is
/// toggled from the pill's context menu, not from Settings, because it only
/// makes sense at point of use.
enum MeetingOverlayPillPreferences {
    static let keepControlsVisibleKey = "meetingOverlayKeepControlsVisible"
    static let defaultKeepControlsVisible = false

    static func keepControlsVisible(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: keepControlsVisibleKey) != nil else {
            return defaultKeepControlsVisible
        }
        return userDefaults.bool(forKey: keepControlsVisibleKey)
    }

    static func setKeepControlsVisible(_ visible: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(visible, forKey: keepControlsVisibleKey)
    }
}
