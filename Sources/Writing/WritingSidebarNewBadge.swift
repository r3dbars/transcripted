/// The Writing row's quiet "New" badge in the Settings sidebar. It shows until
/// `dismissedDefaultsKey` is true in `UserDefaults.standard`; the Writing page
/// sets it when the user finishes setup. `isShown(for:dismissed:)` lives next
/// to `TranscriptedSettingsPage` in `UI/Settings`, since it reads the page.
enum WritingSidebarNewBadge {
    static let dismissedDefaultsKey = "WritingSidebarNewBadgeDismissed"
}
