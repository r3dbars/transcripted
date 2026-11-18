import SwiftUI
import TranscriptedCore

/// Today's host in the shell: its actions, the first-day key line, the
/// setup checklist, and landing a Today dictation click on its entry.
extension TranscriptedSettingsView {
    var todayPage: some View {
        // The Now label and tape marker own their own minute TimelineViews.
        // Wrapping this page used to rebuild every session row each minute.
        TodaySettingsPage(
            todayViewModel: todayViewModel,
            onOpenRecentItem: { item in
                switch item.kind {
                case .meeting:
                    trackSettingsAction("today_open_recent_meeting", page: .today)
                    if let transcriptURL = item.transcriptURL {
                        navigation.select(.home, source: .settingsAction)
                        navigation.requestHomeRevealMeeting(transcriptURL: transcriptURL)
                    }
                case .dictation:
                    trackSettingsAction("today_open_recent_dictation", page: .today)
                    navigation.select(.dictations, source: .settingsAction)
                    // Land on that entry, not the top of the list.
                    if let entryID = item.dictationEntryID {
                        navigation.requestDictationReveal(entryID: entryID)
                    }
                case .writing:
                    // A writing mark opens its day's Markdown file.
                    if let dayFile = item.transcriptURL {
                        NSWorkspace.shared.open(dayFile)
                    }
                }
            },
            onStartMeeting: {
                trackSettingsAction("empty_start_meeting", page: .today)
                actions.startMeeting()
            },
            onImportAudioFile: {
                trackSettingsAction("empty_import_audio", page: .today)
                actions.importAudioFile()
            },
            keyHint: todayKeyHint,
            meetingShortcut: PhysicalDictationTriggerPreferences.displayString(
                for: PhysicalDictationTriggerPreferences.meetingBinding()
            ),
            setupChecklist: todaySetupChecklistState,
            onSetupStep: { step in performTodaySetupStep(step) },
            onDismissSetup: {
                trackSettingsAction("today_setup_dismiss", page: .today)
                todaySetupRetired = true
            },
            isRecordingMeeting: meetingSession.isRecording
        )
        .onAppear {
            todayViewModel.setShown(true)
        }
        .task {
            // Reads the agents' own config files, so off main, and only
            // while the checklist could still show.
            guard !todaySetupRetired else { return }
            todayAgentConnected = await Self.anyAgentConnected()
        }
        .onChange(of: todaySetupChecklistState.isComplete, initial: true) { _, isComplete in
            // Done is done: it never comes back, even if, say, calendar
            // access is turned off later.
            if isComplete { todaySetupRetired = true }
        }
        .onDisappear {
            todayViewModel.cancel()
        }
        .onReceive(todayViewModel.$snapshot) { snapshot in
            // The window opens on Today now, so the return signal Meetings
            // used to send on open comes from Today's list. Home owns the
            // once-per-window latch, so visiting Meetings after doesn't count twice.
            homeViewModel.trackActivationReturnProxyIfNeeded(todayRecent: snapshot.recent)
        }
    }

    /// "Hold Right ⌥ in any app and talk." for the person's own key and
    /// behavior. Reads the shell's shortcut state, which `.hotkeysDidChange`
    /// refreshes.
    private var todayKeyHint: TodayKeyHint {
        TodayKeyHint.make(
            keyDisplay: dictationShortcutsEnabled
                ? PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.pushToTalkBinding())
                : nil,
            behavior: dictationKeyBehavior
        )
    }

    private var todaySetupChecklistState: TodaySetupChecklistState {
        TodaySetupChecklistState(
            calendarConnected: permissionStates[.calendar] ?? false,
            calendarBlocked: TranscriptedPermissionAccess.calendarAccessBlocked(),
            agentConnected: todayAgentConnected,
            triedFileImport: todaySetupTriedFileImport,
            dismissed: todaySetupRetired
        )
    }

    /// Each step runs the same action its own page has.
    private func performTodaySetupStep(_ step: TodaySetupStep) {
        switch step {
        case .calendar:
            trackSettingsAction("today_setup_calendar", page: .today)
            Task { @MainActor in
                await TranscriptedPermissionAccess.requestAccessOrOpenSettings(for: .calendar)
                refreshPermissions()
            }
        case .agent:
            trackSettingsAction("today_setup_agent", page: .today)
            navigation.select(.connectAgent, source: .settingsAction)
        case .transcribeFile:
            trackSettingsAction("today_setup_transcribe_file", page: .today)
            todaySetupTriedFileImport = true
            actions.importAudioFile()
        }
    }

    private static func anyAgentConnected() async -> Bool {
        await Task.detached(priority: .utility) {
            AgentMCPAgent.allCases.contains { AgentMCPConnector.isConnected($0) }
        }.value
    }

    /// Scrolls to the dictation a Today click asked for once it's loaded,
    /// loading older pages as needed (up to `maximumExtraPages`).
    func revealPendingDictation(in sections: [HomeDaySection<SavedDictationEntry>]) {
        guard var pending = dictationPendingReveal,
              navigation.selectedPage == .dictations else { return }
        if sections.contains(where: { $0.items.contains { $0.id == pending.entryID } }) {
            dictationPendingReveal = nil
            settingsScrollTargetID = pending.entryID
            return
        }
        guard !homeViewModel.isLoading, !homeViewModel.isLoadingMore else { return }
        guard homeViewModel.canLoadMoreDictations,
              pending.extraPagesLoaded < TodayDictationRevealPolicy.maximumExtraPages else {
            dictationPendingReveal = nil
            return
        }
        pending.extraPagesLoaded += 1
        dictationPendingReveal = pending
        homeViewModel.loadMoreDictations()
    }
}
