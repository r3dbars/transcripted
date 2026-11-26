import SwiftUI
import TranscriptedCore

/// Stats' host in the shell (`.today` route): its actions, the shared
/// first-day key line and setup checklist (also shown on Meetings' empty
/// state), and landing a dictation click on its entry.
extension TranscriptedSettingsView {
    var todayPage: some View {
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
                    // A writing entry opens its day's Markdown file.
                    if let dayFile = item.transcriptURL {
                        NSWorkspace.shared.open(dayFile)
                    }
                }
            },
            onOpenMeetings: {
                trackSettingsAction("today_open_meetings", page: .today)
                navigation.select(.home, source: .settingsAction)
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
            onSetupStep: { step in performTodaySetupStep(step, page: .today) },
            onDismissSetup: { dismissTodaySetup(page: .today) },
            isRecordingMeeting: meetingSession.isRecording
        )
        .onAppear {
            todayViewModel.setShown(true)
        }
        .task {
            await refreshTodayAgentConnectedIfNeeded()
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
            // Meetings is the default landing page, while Stats (`.today`) can
            // also be opened directly; both feed Home's once-per-window latch so
            // visiting the other page afterward doesn't count twice.
            homeViewModel.trackActivationReturnProxyIfNeeded(todayRecent: snapshot.recent)
        }
    }

    /// "Hold Right ⌥ in any app and talk." for the person's own key and
    /// behavior. Reads the shell's shortcut state, which `.hotkeysDidChange`
    /// refreshes.
    var todayKeyHint: TodayKeyHint {
        TodayKeyHint.make(
            keyDisplay: dictationShortcutsEnabled
                ? PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.pushToTalkBinding())
                : nil,
            behavior: dictationKeyBehavior
        )
    }

    var todaySetupChecklistState: TodaySetupChecklistState {
        guard todaySetupOffered, !todaySetupRetired else {
            return TodaySetupChecklistState(
                calendarConnected: false,
                calendarBlocked: false,
                agentConnected: nil,
                triedFileImport: false,
                dismissed: todaySetupRetired,
                offered: todaySetupOffered
            )
        }
        let calendarConnected = permissionStates[.calendar] ?? false
        return TodaySetupChecklistState(
            calendarConnected: calendarConnected,
            calendarBlocked: calendarConnected ? false : permissionStates.calendarAccessBlocked,
            agentConnected: todayAgentConnected,
            triedFileImport: todaySetupTriedFileImport,
            dismissed: todaySetupRetired,
            offered: todaySetupOffered
        )
    }

    /// Reads the agents' own config files off-main, only while the checklist
    /// could still show.
    func refreshTodayAgentConnectedIfNeeded() async {
        guard todaySetupOffered, !todaySetupRetired else { return }
        todayAgentConnected = await Self.anyAgentConnected()
    }

    func dismissTodaySetup(page: TranscriptedSettingsPage) {
        trackSettingsAction("today_setup_dismiss", page: page)
        todaySetupRetired = true
    }

    /// Each step runs the same action its own page has.
    func performTodaySetupStep(_ step: TodaySetupStep, page: TranscriptedSettingsPage) {
        switch step {
        case .calendar:
            trackSettingsAction("today_setup_calendar", page: page)
            Task { @MainActor in
                await TranscriptedPermissionAccess.requestAccessOrOpenSettings(for: .calendar)
                refreshPermissions()
            }
        case .agent:
            trackSettingsAction("today_setup_agent", page: page)
            navigation.select(.connectAgent, source: .settingsAction)
        case .transcribeFile:
            trackSettingsAction("today_setup_transcribe_file", page: page)
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
