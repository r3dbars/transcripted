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
}
