import AppKit
import Combine

@MainActor
final class MenuBarPanelController: NSViewController {
    private let appState: TranscriptedAppState
    private let dismissPopover: () -> Void
    private let openSettingsWindow: () -> Void
    private let preferredSourceAppProvider: () -> NSRunningApplication?
    private var contentView: MenuBarContentView?
    private var subscriptions = Set<AnyCancellable>()

    init(
        appState: TranscriptedAppState,
        preferredSourceAppProvider: @escaping () -> NSRunningApplication?,
        openSettingsWindow: @escaping () -> Void,
        dismissPopover: @escaping () -> Void
    ) {
        self.appState = appState
        self.preferredSourceAppProvider = preferredSourceAppProvider
        self.openSettingsWindow = openSettingsWindow
        self.dismissPopover = dismissPopover
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let content = MenuBarContentView(
            frame: NSRect(x: 0, y: 0, width: MenuTokens.panelWidth, height: MenuTokens.panelHeight)
        )
        content.appState = appState
        content.shortcutsView.onStartDictation = { [weak self] in self?.startDictationFromMenu() }
        content.shortcutsView.onStartMeeting = { [weak self] in self?.startMeetingFromMenu() }
        content.settingsView.onOpenSettings = { [weak self] in self?.openSettingsFromMenu() }
        content.settingsView.onCheckForUpdates = { [weak self] in self?.checkForUpdatesFromMenu() }
        view = content
        contentView = content
        view.appearance = NSAppearance(named: .darkAqua)

        refresh()
        setupSubscriptions()
    }

    func refresh() {
        guard let content = contentView else { return }
        let warmupStatus = appState.meetingSession.warmupStatus
        let dictationState = FirstRunExperience.dictationAction(
            for: FirstRunLocalModelState(appState.sttRouter.parakeetEngine.modelDownloadState)
        )
        let meetingState = FirstRunExperience.meetingAction(
            dictationReady: appState.sttRouter.isModelLoaded,
            meetingsStatus: warmupStatus.meetingsStatus
        )

        content.headerView.update(
            warmupStatus: warmupStatus,
            hotkeyError: appState.contextCapture.hotkeyError
        )
        content.shortcutsView.update(
            dictationKey: appState.contextCapture.dictationShortcutDisplay,
            meetingKey: appState.contextCapture.meetingShortcutDisplay,
            dictationState: dictationState,
            meetingState: meetingState
        )
        content.settingsView.update(updateState: appState.sparkleUpdater.updateState)
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

        appState.sparkleUpdater.$updateState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &subscriptions)
    }

    func prepareForClose() {
        contentView?.shortcutsView.cancelEditing()
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

    private func checkForUpdatesFromMenu() {
        dismissPopover()
        appState.sparkleUpdater.checkForUpdates()
    }

    private func resolvedSourceApp() -> NSRunningApplication? {
        let app = preferredSourceAppProvider()
        guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return app
    }
}
