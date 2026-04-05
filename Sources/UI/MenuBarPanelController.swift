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
        content.agentView.analysisEngine = appState.analysisEngine
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

        appState.feedbackStore.refreshStats()

        // Header
        let isReady = appState.sttRouter.isModelLoaded && appState.localInference.isReady
        content.headerView.update(isReady: isReady, statusText: statusText)

        // Model download
        let showDownload = !appState.sttRouter.isModelLoaded || !appState.localInference.isReady
        content.modelDownloadView.isHidden = !showDownload
        if showDownload {
            content.modelDownloadView.update(
                voiceModelLoaded: appState.sttRouter.isModelLoaded,
                voiceState: appState.sttRouter.parakeetEngine.modelDownloadState,
                llmReady: appState.localInference.isReady,
                llmState: appState.localInference.modelState
            )
        }

        // Hotkey error
        content.hotkeyErrorBanner.update(error: appState.contextCapture.hotkeyError)
        content.hotkeyErrorBanner.onDismiss = { [weak self] in
            self?.appState.contextCapture.hotkeyError = nil
        }

        // Stats
        content.statsView.update(stats: appState.feedbackStore.stats)

        // Shortcuts
        content.shortcutsView.update(
            draftKey: appState.contextCapture.draftShortcutDisplay,
            dictationKey: appState.contextCapture.dictationShortcutDisplay
        )

        // Recent Meetings — scans ~/Library/Application Support/Draft/meetings/transcripts
        // each time the popover opens (no subscription; list is short).
        content.recentMeetingsView.update(meetings: RecentMeetingsScanner.loadRecent())

        // Style
        content.styleView.update(
            styleContents: appState.styleEngine.styleFileContents,
            exampleCount: appState.styleEngine.exampleCount,
            trainingPhase: appState.styleEngine.trainingPhaseDescription,
            styleMatchScore: appState.styleEngine.styleMatchScore
        )

        // Settings
        content.settingsView.update(llmStatus: appState.localInference.statusLabel)
        content.settingsView.updateAPIKeyStatus()

        // Agent
        content.agentView.update(
            insights: appState.analysisEngine.insights,
            isAnalyzing: appState.analysisEngine.isAnalyzing,
            agentStatus: appState.analysisEngine.agentStatus
        )

        content.needsLayout = true
    }

    private var statusText: String {
        if !appState.sttRouter.isModelLoaded && !appState.localInference.isReady {
            return "Loading models..."
        } else if !appState.sttRouter.isModelLoaded {
            return "Loading voice model..."
        } else if !appState.localInference.isReady {
            return appState.localInference.statusLabel
        }
        return "Ready"
    }

    private func setupSubscriptions() {
        // Stats
        appState.feedbackStore.$stats
            .receive(on: RunLoop.main)
            .sink { [weak self] stats in
                self?.contentView?.statsView.update(stats: stats)
            }
            .store(in: &subscriptions)

        // Style
        appState.styleEngine.$exampleCount
            .combineLatest(appState.styleEngine.$styleFileContents)
            .receive(on: RunLoop.main)
            .sink { [weak self] (count, contents) in
                guard let self = self else { return }
                self.contentView?.styleView.update(
                    styleContents: contents,
                    exampleCount: count,
                    trainingPhase: self.appState.styleEngine.trainingPhaseDescription,
                    styleMatchScore: self.appState.styleEngine.styleMatchScore
                )
            }
            .store(in: &subscriptions)

        // Model state
        appState.localInference.$modelState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                let isReady = self.appState.sttRouter.isModelLoaded && self.appState.localInference.isReady
                self.contentView?.headerView.update(isReady: isReady, statusText: self.statusText)
                let showDownload = !self.appState.sttRouter.isModelLoaded || !self.appState.localInference.isReady
                self.contentView?.modelDownloadView.isHidden = !showDownload
                if showDownload {
                    self.contentView?.modelDownloadView.update(
                        voiceModelLoaded: self.appState.sttRouter.isModelLoaded,
                        voiceState: self.appState.sttRouter.parakeetEngine.modelDownloadState,
                        llmReady: self.appState.localInference.isReady,
                        llmState: self.appState.localInference.modelState
                    )
                }
                self.contentView?.needsLayout = true
            }
            .store(in: &subscriptions)

        // Insights
        appState.analysisEngine.$insights
            .combineLatest(appState.analysisEngine.$isAnalyzing)
            .receive(on: RunLoop.main)
            .sink { [weak self] (insights, isAnalyzing) in
                guard let self = self else { return }
                self.contentView?.agentView.update(
                    insights: insights,
                    isAnalyzing: isAnalyzing,
                    agentStatus: self.appState.analysisEngine.agentStatus
                )
                self.contentView?.needsLayout = true
            }
            .store(in: &subscriptions)

        // Hotkey display
        appState.contextCapture.$draftShortcutDisplay
            .combineLatest(appState.contextCapture.$dictationShortcutDisplay)
            .receive(on: RunLoop.main)
            .sink { [weak self] (draft, dictation) in
                self?.contentView?.shortcutsView.update(draftKey: draft, dictationKey: dictation)
            }
            .store(in: &subscriptions)

        // Hotkey error
        appState.contextCapture.$hotkeyError
            .receive(on: RunLoop.main)
            .sink { [weak self] error in
                self?.contentView?.hotkeyErrorBanner.update(error: error)
            }
            .store(in: &subscriptions)
    }
}
