// MenuBarPanelController.swift
// NSViewController that hosts MenuBarContentView and manages Combine subscriptions
// Created fresh each time the popover opens — subscriptions auto-cancelled on dealloc

import AppKit
import Combine

@MainActor
final class MenuBarPanelController: NSViewController {
    private let appState: DraftAppState
    private var contentView: MenuBarContentView?
    private var subscriptions = Set<AnyCancellable>()

    init(appState: DraftAppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let content = MenuBarContentView(frame: NSRect(x: 0, y: 0,
                                                        width: MenuTokens.panelWidth,
                                                        height: MenuTokens.panelHeight))
        content.appState = appState
        content.settingsView.appState = appState
        self.contentView = content
        self.view = content

        // Initial data push
        refreshAll()

        // Subscribe to engine changes
        setupSubscriptions()
    }

    private func refreshAll() {
        guard let content = contentView else { return }

        // Header
        let isReady = appState.sttRouter.isModelLoaded
        content.headerView.update(isReady: isReady, statusText: statusText)

        // Model download
        let showDownload = !appState.sttRouter.isModelLoaded
        content.modelDownloadView.isHidden = !showDownload
        if showDownload {
            content.modelDownloadView.update(
                voiceModelLoaded: appState.sttRouter.isModelLoaded,
                voiceState: appState.sttRouter.parakeetEngine.modelDownloadState
            )
        }

        // Hotkey error
        content.hotkeyErrorBanner.update(error: appState.contextCapture.hotkeyError)
        content.hotkeyErrorBanner.onDismiss = { [weak self] in
            self?.appState.contextCapture.hotkeyError = nil
        }

        // Shortcuts
        content.shortcutsView.update(
            dictationKey: appState.contextCapture.dictationShortcutDisplay,
            meetingKey: appState.contextCapture.meetingShortcutDisplay
        )

        // Recent Meetings — scans ~/Library/Application Support/Draft/meetings/transcripts
        // each time the popover opens (no subscription; list is short).
        if #available(macOS 14.0, *) {
            content.recentMeetingsView.update(
                meetings: RecentMeetingsScanner.loadRecent(),
                failedMeetings: appState.meetingSession.failedMeetings,
                onRetryFailedMeeting: { [weak self] id in
                    self?.appState.meetingSession.retryFailedMeeting(id: id)
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
                onDismissFailedMeeting: { _ in }
            )
        }

        content.needsLayout = true
    }

    private var statusText: String {
        if !appState.sttRouter.isModelLoaded {
            return "Loading voice model..."
        }
        return "Ready"
    }

    private func setupSubscriptions() {
        // Model state
        appState.sttRouter.parakeetEngine.$modelDownloadState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let isReady = self.appState.sttRouter.isModelLoaded
                self.contentView?.headerView.update(isReady: isReady, statusText: self.statusText)
                let showDownload = !self.appState.sttRouter.isModelLoaded
                self.contentView?.modelDownloadView.isHidden = !showDownload
                if showDownload {
                    self.contentView?.modelDownloadView.update(
                        voiceModelLoaded: self.appState.sttRouter.isModelLoaded,
                        voiceState: self.appState.sttRouter.parakeetEngine.modelDownloadState
                    )
                }
                self.contentView?.needsLayout = true
            }
            .store(in: &subscriptions)

        // Hotkey display
        appState.contextCapture.$dictationShortcutDisplay
            .combineLatest(appState.contextCapture.$meetingShortcutDisplay)
            .receive(on: RunLoop.main)
            .sink { [weak self] (dictation, meeting) in
                self?.contentView?.shortcutsView.update(dictationKey: dictation, meetingKey: meeting)
            }
            .store(in: &subscriptions)

        // Hotkey error
        appState.contextCapture.$hotkeyError
            .receive(on: RunLoop.main)
            .sink { [weak self] error in
                self?.contentView?.hotkeyErrorBanner.update(error: error)
            }
            .store(in: &subscriptions)

        if #available(macOS 14.0, *) {
            appState.meetingSession.$lastSavedTranscriptURL
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.refreshAll()
                }
                .store(in: &subscriptions)

            appState.meetingSession.$failedMeetings
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.refreshAll()
                }
                .store(in: &subscriptions)
        }
    }
}
