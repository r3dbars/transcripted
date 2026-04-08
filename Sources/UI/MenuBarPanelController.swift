// MenuBarPanelController.swift
// NSViewController that hosts the menubar popover and wires actions/subscriptions.

import AppKit
import Combine

@MainActor
final class MenuBarPanelController: NSViewController {
    private let appState: DraftAppState
    private let dismissPopover: () -> Void
    private let openSettingsWindow: () -> Void
    private let openAgentConnectWindow: () -> Void
    private let preferredSourceAppProvider: () -> NSRunningApplication?
    private var contentView: MenuBarContentView?
    private var subscriptions = Set<AnyCancellable>()

    init(
        appState: DraftAppState,
        preferredSourceAppProvider: @escaping () -> NSRunningApplication?,
        openSettingsWindow: @escaping () -> Void,
        openAgentConnectWindow: @escaping () -> Void,
        dismissPopover: @escaping () -> Void
    ) {
        self.appState = appState
        self.preferredSourceAppProvider = preferredSourceAppProvider
        self.openSettingsWindow = openSettingsWindow
        self.openAgentConnectWindow = openAgentConnectWindow
        self.dismissPopover = dismissPopover
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let content = MenuBarContentView(frame: NSRect(x: 0, y: 0, width: MenuTokens.panelWidth, height: MenuTokens.panelHeight))
        content.appState = appState
        content.settingsView.appState = appState
        content.shortcutsView.onStartDictation = { [weak self] in self?.startDictationFromMenu() }
        content.shortcutsView.onStartMeeting = { [weak self] in self?.startMeetingFromMenu() }
        content.settingsView.onOpenSettings = { [weak self] in self?.openSettingsFromMenu() }
        content.settingsView.onOpenAgentConnect = { [weak self] in self?.openAgentConnectFromMenu() }
        view = content
        contentView = content
        view.appearance = NSAppearance(named: .darkAqua)

        refresh()
        setupSubscriptions()
    }

    func refresh() {
        guard let content = contentView else { return }
        let warmupStatus = appState.meetingSession.warmupStatus
        let isReady = warmupStatus == .ready

        content.headerView.update(
            warmupStatus: warmupStatus,
            hotkeyError: appState.contextCapture.hotkeyError
        )

        content.shortcutsView.update(
            dictationKey: appState.contextCapture.dictationShortcutDisplay,
            meetingKey: appState.contextCapture.meetingShortcutDisplay,
            isEnabled: isReady
        )

        if #available(macOS 14.0, *) {
            content.recentMeetingsView.update(
                meetings: RecentMeetingsScanner.loadRecent(),
                failedMeetings: appState.meetingSession.failedMeetings,
                onRetryFailedMeeting: { [weak self] id in
                    self?.appState.meetingSession.retryFailedMeeting(id: id)
                },
                onDeleteFailedMeeting: { [weak self] id in
                    self?.appState.meetingSession.deleteFailedMeeting(id: id)
                },
                onDismissFailedMeeting: { [weak self] id in
                    self?.appState.meetingSession.dismissFailedMeeting(id: id)
                }
            )
        } else {
            content.recentMeetingsView.update(
                meetings: RecentMeetingsScanner.loadRecent(),
                failedMeetings: [],
                onRetryFailedMeeting: { _ in },
                onDeleteFailedMeeting: { _ in },
                onDismissFailedMeeting: { _ in }
            )
        }

        content.needsLayout = true
    }

    private func setupSubscriptions() {
        appState.meetingSession.$warmupStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &subscriptions)

        appState.contextCapture.$dictationShortcutDisplay
            .combineLatest(appState.contextCapture.$meetingShortcutDisplay)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.refresh()
            }
            .store(in: &subscriptions)

        appState.contextCapture.$hotkeyError
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &subscriptions)

        if #available(macOS 14.0, *) {
            appState.meetingSession.$lastSavedTranscriptURL
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.refresh()
                }
                .store(in: &subscriptions)

            appState.meetingSession.$failedMeetings
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.refresh()
                }
                .store(in: &subscriptions)
        }
    }

    func prepareForClose() {
        contentView?.shortcutsView.cancelEditing()
        contentView?.showMainPage()
        contentView?.settingsView.dismissTransientUI()
    }

    private func startDictationFromMenu() {
        guard let session = appState.contextCapture.sessionController else { return }
        let sourceApp = resolvedSourceApp()
        dismissPopover()
        sourceApp?.activate(options: [])
        session.startDictation(sourceApp: sourceApp, trigger: .menu)
    }

    private func startMeetingFromMenu() {
        if #available(macOS 14.0, *) {
            let sourceApp = resolvedSourceApp()
            dismissPopover()
            sourceApp?.activate(options: [])
            Task {
                await appState.meetingSession.startRecording(trigger: .menu)
            }
        }
    }

    private func openSettingsFromMenu() {
        dismissPopover()
        openSettingsWindow()
    }

    private func openAgentConnectFromMenu() {
        dismissPopover()
        openAgentConnectWindow()
    }

    private func resolvedSourceApp() -> NSRunningApplication? {
        let app = preferredSourceAppProvider()
        guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return app
    }
}
