import Foundation

/// The app-active ⌘ commands in the Settings, Capture and Go menus.
///
/// `TranscriptedMenuCommands` builds its menus from these lists, so the
/// shortcuts can be checked as values instead of as SwiftUI text. The Go items
/// come from `TranscriptedSettingsPage.navigationShortcutKey`, so the menu and
/// the sidebar tooltips can't drift apart. None of these remap the user's
/// recordable dictation or meeting triggers; they only fire while the app is
/// active.
enum TranscriptedMenuCommandCatalog {
    enum Action: Equatable {
        case openSettings
        case startDictation
        case toggleMeetingRecording
        case importAudio
        case openPage(TranscriptedSettingsPage)
        case findCaptures
        case findSpeaker
    }

    struct Item: Equatable, Identifiable {
        let title: String
        /// The key pressed with ⌘.
        let key: Character
        /// Adds ⇧ to the ⌘ shortcut.
        let usesShift: Bool
        let action: Action
        /// Draws a divider above this item.
        let startsGroup: Bool

        var id: String { title }

        init(title: String, key: Character, usesShift: Bool = false, action: Action, startsGroup: Bool = false) {
            self.title = title
            self.key = key
            self.usesShift = usesShift
            self.action = action
            self.startsGroup = startsGroup
        }
    }

    /// Replaces SwiftUI's own Settings item, so ⌘, opens the real window.
    static let settings = Item(title: "Settings…", key: ",", action: .openSettings)

    /// The two recording actions plus file import.
    static let capture: [Item] = [
        Item(title: "Start Dictation", key: "d", action: .startDictation),
        Item(title: "Start / Stop Meeting Recording", key: "r", action: .toggleMeetingRecording),
        Item(title: "Transcribe Audio File…", key: "o", action: .importAudio, startsGroup: true),
    ]

    /// Jump straight to a sidebar section (opening the window if needed), then search.
    static var go: [Item] {
        let pages: [Item] = TranscriptedSettingsPage.allCases.compactMap { page in
            guard let key = page.navigationShortcutKey?.first else { return nil }
            return Item(title: page.title, key: key, action: .openPage(page))
        }
        return pages + [
            Item(title: "Find Meetings…", key: "f", action: .findCaptures, startsGroup: true),
            Item(title: "Find Speaker…", key: "f", usesShift: true, action: .findSpeaker),
        ]
    }

    static var all: [Item] { [settings] + capture + go }
}

/// What the app does for each menu action. `TranscriptedAppDelegate` is the
/// real host; each requirement is a thin hop to an entry point users already
/// have through the popover, the sidebar, or a recordable trigger.
@MainActor
protocol TranscriptedMenuCommandHost: AnyObject {
    func closeMenuBarPopover()
    func openSettingsWindow(page: TranscriptedSettingsPage, source: String)
    func startDictationFromMenu()
    func toggleMeetingRecordingFromMenu()
    func importAudioFromMenu()
    func focusHomeFindFromMenu(source: String)
    func focusSpeakerSearchFromMenu(source: String)
}

extension TranscriptedMenuCommandCatalog {
    /// The navigation source the app-menu Settings item (⌘, and the Settings
    /// scene's fallback button) reports.
    static let appMenuSource = "app_menu"
    /// The navigation source every other menu command reports.
    static let menuCommandSource = "menu_command"

    /// Routes one menu action to the host. ⌘, closes the menu bar popover
    /// first, then opens the real Settings window on General; it never shows
    /// SwiftUI's own Settings scene.
    @MainActor
    static func perform(_ action: Action, on host: TranscriptedMenuCommandHost) {
        switch action {
        case .openSettings:
            host.closeMenuBarPopover()
            host.openSettingsWindow(page: .general, source: appMenuSource)
        case .startDictation:
            host.startDictationFromMenu()
        case .toggleMeetingRecording:
            host.toggleMeetingRecordingFromMenu()
        case .importAudio:
            host.importAudioFromMenu()
        case let .openPage(page):
            host.openSettingsWindow(page: page, source: menuCommandSource)
        case .findCaptures:
            host.focusHomeFindFromMenu(source: menuCommandSource)
        case .findSpeaker:
            host.focusSpeakerSearchFromMenu(source: menuCommandSource)
        }
    }
}
