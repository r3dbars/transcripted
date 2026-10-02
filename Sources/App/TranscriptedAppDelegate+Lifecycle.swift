// TranscriptedAppDelegate+Lifecycle.swift
// Login-item launch detection and the Quit confirmation dialogs

import SwiftUI
import AppKit
import AVFoundation
import Carbon
import Combine
import Darwin
import TranscriptedCore
import UniformTypeIdentifiers

extension TranscriptedAppDelegate {
    /// macOS tags a login-item start on the open-application event.
    static func wasLaunchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    /// How long ago this user's current console login happened, from utmpx.
    static func secondsSinceConsoleLogin(now: Date = Date()) -> TimeInterval? {
        let user = NSUserName()
        var latestLogin: Date?
        setutxent()
        defer { endutxent() }
        while let entry = getutxent() {
            guard Int(entry.pointee.ut_type) == Int(USER_PROCESS) else { continue }
            let line = withUnsafeBytes(of: entry.pointee.ut_line) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            let entryUser = withUnsafeBytes(of: entry.pointee.ut_user) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard line == "console", entryUser == user else { continue }
            let loginTime = Date(timeIntervalSince1970: TimeInterval(entry.pointee.ut_tv.tv_sec))
            if latestLogin.map({ loginTime > $0 }) ?? true {
                latestLogin = loginTime
            }
        }
        return latestLogin.map { now.timeIntervalSince($0) }
    }
    func replyToPendingTerminationRequests(_ sender: NSApplication, shouldTerminate: Bool) {
        let replyCount = max(pendingTerminationReplyCount, 1)
        pendingTerminationReplyCount = 0

        for _ in 0..<replyCount {
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    }

    func activeMeetingTerminationDecision() -> ActiveMeetingQuitDecision {
        guard #available(macOS 14.0, *) else { return .saveAudioAndQuit }
        let activeCapture = appState.meetingSession.shouldConfirmQuitForActiveCapture
        let backgroundWork = appState.meetingSession.shouldConfirmQuitForBackgroundTranscription
        guard ActiveMeetingQuitConfirmationPolicy.shouldConfirmQuit(
            activeMeetingCapture: activeCapture,
            backgroundTranscriptionWork: backgroundWork
        ) else {
            return .saveAudioAndQuit
        }

        // Once Stop has been pressed the audio is only being saved: "still
        // recording", Keep Recording, and Stop Recording would all be wrong,
        // so that phase gets the Keep Open / Save Audio & Quit dialog.
        let isSavingAfterStop: Bool
        if case .stoppingRecording = appState.meetingSession.state {
            isSavingAfterStop = true
        } else {
            isSavingAfterStop = false
        }
        guard activeCapture, !isSavingAfterStop else {
            return confirmQuitDuringBackgroundMeetingWork()
        }

        return confirmQuitDuringActiveMeeting()
    }

    private func confirmQuitDuringActiveMeeting() -> ActiveMeetingQuitDecision {
        closePopover()
        NSApp.activate(ignoringOtherApps: true)

        let presentation = ActiveMeetingQuitConfirmationPolicy.presentation
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = presentation.title
        alert.informativeText = presentation.message
        alert.addButton(withTitle: presentation.keepRecordingTitle)
        alert.addButton(withTitle: presentation.stopAndTranscribeTitle)
        alert.addButton(withTitle: presentation.saveAudioAndQuitTitle)
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.last?.keyEquivalent = ""

        switch runQuitAlertMappingEscapeToFirstButton(alert) {
        case .alertSecondButtonReturn:
            return .stopAndTranscribe
        case .alertThirdButtonReturn:
            return .saveAudioAndQuit
        default:
            return .keepRecording
        }
    }

    private func confirmQuitDuringBackgroundMeetingWork() -> ActiveMeetingQuitDecision {
        closePopover()
        NSApp.activate(ignoringOtherApps: true)

        let presentation = ActiveMeetingQuitConfirmationPolicy.backgroundPresentation
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = presentation.title
        alert.informativeText = presentation.message
        alert.addButton(withTitle: presentation.keepOpenTitle)
        alert.addButton(withTitle: presentation.saveAudioAndQuitTitle)
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.last?.keyEquivalent = ""

        switch runQuitAlertMappingEscapeToFirstButton(alert) {
        case .alertSecondButtonReturn:
            return .saveAudioAndQuit
        default:
            return .keepRecording
        }
    }

    /// NSAlert only maps Esc to a button titled "Cancel", so Esc in the quit
    /// dialogs did nothing. Map it to the first button (Keep Recording / Keep
    /// Open), the same safe choice Return picks.
    private func runQuitAlertMappingEscapeToFirstButton(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.window === alert.window else { return event }
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
            return nil
        }
        defer {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
            }
        }
        return alert.runModal()
    }
}
