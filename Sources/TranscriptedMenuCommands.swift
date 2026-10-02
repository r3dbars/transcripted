// TranscriptedMenuCommands.swift
// macOS menu-bar commands that surface Transcripted's top daily actions with
// conventional ⌘-based shortcuts.
//
// This is purely additive: every action routes through an existing app-delegate
// entry point, and none of the user's recordable dictation / meeting triggers
// (push-to-talk, hands-free, meeting, paste-last) are remapped. The commands
// only fire while the app is active (a window is open), which is exactly when
// navigation, search, and in-app capture make sense; the global physical
// triggers remain the background path.
//
// The menus are data: `TranscriptedMenuCommandTable.items` lists every title,
// key, and action, `TranscriptedMenuCommands` renders it, and the delegate
// routes each action through one `perform(_:)` switch. Fast tests check the
// table and the routing directly.

import SwiftUI

/// What a menu command does. Each case maps to one app-delegate entry point.
enum AppMenuAction: Equatable {
    case openSettings
    case startDictation
    case toggleMeetingRecording
    case importAudio
    case openPage(TranscriptedSettingsPage)
    case findCaptures
    case findSpeaker
}

/// The menu a command lives in.
enum AppMenuGroup: Equatable, CaseIterable {
    /// Replaces SwiftUI's native Settings… item in the app menu.
    case appSettings
    case capture
    case go
}

struct AppMenuModifiers: OptionSet, Equatable {
    let rawValue: Int

    static let command = AppMenuModifiers(rawValue: 1 << 0)
    static let shift = AppMenuModifiers(rawValue: 1 << 1)
    static let option = AppMenuModifiers(rawValue: 1 << 2)
    static let control = AppMenuModifiers(rawValue: 1 << 3)

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if contains(.command) { result.insert(.command) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.option) { result.insert(.option) }
        if contains(.control) { result.insert(.control) }
        return result
    }
}

struct AppMenuCommandItem: Equatable {
    let group: AppMenuGroup
    let title: String
    let key: Character
    let modifiers: AppMenuModifiers
    let action: AppMenuAction
    /// Draws a divider above this item.
    var dividerBefore = false
}

enum TranscriptedMenuCommandTable {
    static let items: [AppMenuCommandItem] = [
        // Replace SwiftUI's native Settings action declaratively. A previous
        // one-shot AppKit menu mutation could miss menu construction and leave
        // the empty fallback scene on screen when the user pressed Command-,.
        AppMenuCommandItem(group: .appSettings, title: "Settings…", key: ",", modifiers: .command, action: .openSettings),

        // Capture — the two recording actions plus file import.
        AppMenuCommandItem(group: .capture, title: "Start Dictation", key: "d", modifiers: .command, action: .startDictation),
        AppMenuCommandItem(group: .capture, title: "Start / Stop Meeting Recording", key: "r", modifiers: .command, action: .toggleMeetingRecording),
        AppMenuCommandItem(group: .capture, title: "Transcribe Audio File…", key: "o", modifiers: .command, action: .importAudio, dividerBefore: true),

        // Go — jump straight to a sidebar section (opening the window if needed).
        AppMenuCommandItem(group: .go, title: "Today", key: "1", modifiers: .command, action: .openPage(.today)),
        AppMenuCommandItem(group: .go, title: "Meetings", key: "2", modifiers: .command, action: .openPage(.home)),
        AppMenuCommandItem(group: .go, title: "Dictations", key: "3", modifiers: .command, action: .openPage(.dictations)),
        AppMenuCommandItem(group: .go, title: "Writing", key: "4", modifiers: .command, action: .openPage(.writing)),
        AppMenuCommandItem(group: .go, title: "Speakers", key: "5", modifiers: .command, action: .openPage(.people)),
        AppMenuCommandItem(group: .go, title: "Agent", key: "6", modifiers: .command, action: .openPage(.connectAgent)),
        AppMenuCommandItem(group: .go, title: "Find Meetings…", key: "f", modifiers: .command, action: .findCaptures, dividerBefore: true),
        AppMenuCommandItem(group: .go, title: "Find Speaker…", key: "f", modifiers: [.command, .shift], action: .findSpeaker),
    ]

    static func items(in group: AppMenuGroup) -> [AppMenuCommandItem] {
        items.filter { $0.group == group }
    }
}

/// Where Settings… lands: the app's own Settings window on General, never the
/// SwiftUI Settings scene.
enum AppMenuSettingsRoute {
    static let settingsPage: TranscriptedSettingsPage = .general
    static let settingsSource = "app_menu"
    static let pageSource = "menu_command"
}

/// The app-delegate entry points the menu commands call.
@MainActor
protocol AppMenuActionPerforming: AnyObject {
    func menuOpenSettings()
    func menuStartDictation()
    func menuToggleMeetingRecording()
    func menuImportAudio()
    func menuOpenPage(_ page: TranscriptedSettingsPage)
    func menuFindCaptures()
    func menuFindSpeaker()
}

extension AppMenuActionPerforming {
    func perform(_ action: AppMenuAction) {
        switch action {
        case .openSettings:
            menuOpenSettings()
        case .startDictation:
            menuStartDictation()
        case .toggleMeetingRecording:
            menuToggleMeetingRecording()
        case .importAudio:
            menuImportAudio()
        case .openPage(let page):
            menuOpenPage(page)
        case .findCaptures:
            menuFindCaptures()
        case .findSpeaker:
            menuFindSpeaker()
        }
    }
}

struct TranscriptedMenuCommands<Delegate: AppMenuActionPerforming>: Commands {
    let appDelegate: Delegate

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            commandButtons(in: .appSettings)
        }

        CommandMenu("Capture") {
            commandButtons(in: .capture)
        }

        CommandMenu("Go") {
            commandButtons(in: .go)
        }
    }

    @ViewBuilder
    private func commandButtons(in group: AppMenuGroup) -> some View {
        let items = TranscriptedMenuCommandTable.items(in: group)
        ForEach(items.indices, id: \.self) { index in
            let item = items[index]
            if item.dividerBefore {
                Divider()
            }
            Button(item.title) {
                appDelegate.perform(item.action)
            }
            .keyboardShortcut(KeyEquivalent(item.key), modifiers: item.modifiers.eventModifiers)
        }
    }
}
