import Foundation

/// Whether the notch island shows up in screen sharing, screen recordings
/// and screenshots. Off by default, like every other overlay, so a shared
/// screen never shows live dictation; people who want to demo or capture it
/// turn it on.
enum NotchIslandPreferences {
    static let visibleInScreenSharingKey = "notchIslandVisibleInScreenSharing"

    static func visibleInScreenSharing(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: visibleInScreenSharingKey)
    }

    static func setVisibleInScreenSharing(_ visible: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(visible, forKey: visibleInScreenSharingKey)
    }

    /// Whether a recording meeting transcribes live, on this Mac, so hovering
    /// the island shows the conversation so far. Off by default: it runs two
    /// streaming models for the whole call. The saved transcript is unaffected.
    static let showsLiveTranscriptKey = "notchIslandShowsLiveTranscript"

    static func showsLiveTranscript(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: showsLiveTranscriptKey)
    }

    static func setShowsLiveTranscript(_ shows: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(shows, forKey: showsLiveTranscriptKey)
    }
}
