// MenuBarPanelController.swift
// NSViewController that hosts the menubar popover and wires actions/subscriptions.

import AppKit
import Combine

@MainActor
final class MenuBarPanelController: NSViewController {
    private let appState: TranscriptedAppState
    private let dismissPopover: () -> Void
    private let openSettingsWindow: (TranscriptedSettingsPage) -> Void
    private let preferredSourceAppProvider: () -> NSRunningApplication?
    private let textPaster = ClipboardRestoringTextPaster()

    private var contentView: MenuBarContentView?
    private var subscriptions = Set<AnyCancellable>()

    init(
        appState: TranscriptedAppState,
        preferredSourceAppProvider: @escaping () -> NSRunningApplication?,
        openSettingsWindow: @escaping (TranscriptedSettingsPage) -> Void,
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
        let content = MenuBarContentView(frame: NSRect(x: 0, y: 0, width: MenuTokens.panelWidth, height: MenuTokens.panelHeight))
        content.appState = appState
        content.primaryActionsView.onOpenHome = { [weak self] in self?.openSettingsFromMenu(.home) }
        content.primaryActionsView.onStartDictation = { [weak self] in self?.startDictationFromMenu() }
        content.primaryActionsView.onStartMeeting = { [weak self] in self?.startMeetingFromMenu() }
        content.primaryActionsView.onPasteLastDictation = { [weak self] in self?.pasteLastDictationFromMenu() }
        content.primaryActionsView.onOpenRecentMeetings = { [weak self] in self?.openSettingsFromMenu(.meetings) }
        content.utilityActionsView.onOpenSettings = { [weak self] in self?.openSettingsFromMenu(.home) }
        content.utilityActionsView.onCheckForUpdates = { [weak self] in self?.checkForUpdatesFromMenu() }
        content.utilityActionsView.onOpenConnectAgent = { [weak self] in self?.openSettingsFromMenu(.connectAgent) }
        view = content
        contentView = content
        view.appearance = NSAppearance(named: .darkAqua)

        refresh()
        setupSubscriptions()
    }

    func refresh() {
        guard let content = contentView else { return }

        let warmupStatus = appState.meetingSession.warmupStatus
        let modelState = FirstRunLocalModelState(appState.sttRouter.parakeetEngine.modelDownloadState)
        let dictationState = FirstRunExperience.dictationAction(for: modelState)
        let meetingState = FirstRunExperience.meetingAction(
            dictationReady: appState.sttRouter.isModelLoaded,
            meetingsStatus: warmupStatus.meetingsStatus
        )
        let latestDictation = DictationTranscriptStore.latestSavedDictation()
        let updatePresentation = menuUpdatePresentation(for: appState.sparkleUpdater.updateStatus)

        content.headerView.update(
            warmupStatus: warmupStatus,
            hotkeyError: appState.contextCapture.hotkeyError
        )

        content.primaryActionsView.update(
            dictationKey: appState.contextCapture.dictationShortcutDisplay,
            meetingKey: appState.contextCapture.meetingShortcutDisplay,
            dictationState: dictationState,
            meetingState: meetingState,
            pasteDetail: pasteDetail(for: latestDictation),
            pasteEnabled: latestDictation != nil
        )

        content.utilityActionsView.update(
            updateTitle: updatePresentation.title,
            updateVersion: updatePresentation.version,
            updateTone: updatePresentation.tone,
            updateEnabled: appState.sparkleUpdater.updateStatus.canCheckForUpdates
        )

        if case .unknown = appState.sparkleUpdater.updateStatus.state {
            appState.sparkleUpdater.refreshUpdateStatus()
        }

        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        preferredContentSize = content.preferredPanelSize
    }

    private func setupSubscriptions() {
        appState.meetingSession.$warmupStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &subscriptions)

        appState.sttRouter.parakeetEngine.$modelDownloadState
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

        appState.sparkleUpdater.$updateStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &subscriptions)
    }

    func prepareForClose() {
        textPaster.cancelPendingClipboardRestore()
        contentView?.utilityActionsView.dismissTransientUI()
        contentView?.scrollToTop()
    }

    private func startDictationFromMenu() {
        guard let session = appState.contextCapture.sessionController else { return }
        let sourceApp = resolvedSourceApp()
        dismissPopover()
        sourceApp?.activate(options: [])
        session.startDictation(sourceApp: sourceApp, trigger: .menu)
    }

    private func startMeetingFromMenu() {
        let sourceApp = resolvedSourceApp()
        dismissPopover()
        sourceApp?.activate(options: [])
        Task {
            await appState.meetingSession.startRecording(trigger: .menu)
        }
    }

    private func pasteLastDictationFromMenu() {
        guard let latestText = DictationTranscriptStore.latestSavedText() else {
            NSSound.beep()
            return
        }

        let sourceApp = resolvedSourceApp()
        dismissPopover()
        sourceApp?.activate(options: [])
        _ = textPaster.paste(latestText)
    }

    private func openSettingsFromMenu(_ page: TranscriptedSettingsPage) {
        dismissPopover()
        openSettingsWindow(page)
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

    private func menuUpdatePresentation(
        for status: SparkleUpdaterController.UpdateStatus
    ) -> (title: String, version: String?, tone: MenuBarActionRowView.Tone) {
        switch status.state {
        case .unknown, .readyToCheck:
            return (
                "Check for Updates",
                nil,
                .standard
            )
        case .checking:
            return (
                "Checking…",
                nil,
                .standard
            )
        case .noUpdateAvailable:
            return (
                "Check for Updates",
                nil,
                .standard
            )
        case .updateAvailable(let version):
            return (
                "Update Available",
                version,
                .accent
            )
        }
    }

    private func pasteDetail(for entry: SavedDictationEntry?) -> String {
        guard let entry else {
            return "No saved dictation yet."
        }

        let collapsed = entry.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""

        guard !collapsed.isEmpty else {
            return "Paste the newest saved dictation."
        }

        return shortenedPreview(for: collapsed, limit: 40)
    }

    private func shortenedPreview(for text: String, limit: Int) -> String {
        let normalized = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        guard normalized.count > limit else {
            return normalized
        }
        let truncated = normalized.prefix(max(0, limit - 1)).trimmingCharacters(in: .whitespaces)
        return "\(truncated)…"
    }
}
