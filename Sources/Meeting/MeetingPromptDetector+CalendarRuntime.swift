import AppKit
import EventKit
import Foundation

@available(macOS 14.0, *)
extension MeetingPromptDetector {
    // Members here that drop `private` do so only because another
    // MeetingPromptDetector file uses them; treat them as private to the type.

    func currentSuggestedTranscriptTitle(now: Date = Date()) -> String? {
        guard calendarAccessGranted() else { return nil }
        return upcomingCalendarCandidates(
            now: now,
            runningBundleIDs: [],
            frontmostBundleID: nil
        )
        .sorted(by: sortCandidates)
        .lazy
        .compactMap(\.candidate.suggestedTranscriptTitle)
        .first
    }

    func installWorkspaceObservers() {
        guard workspaceObservers.isEmpty else { return }

        let names: [NSNotification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification
        ]

        workspaceObservers = names.map { name in
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor [weak self] in
                    guard let app else { return }
                    // Off the main thread: a just-launched app's first
                    // bundle ID read can block on LaunchServices.
                    let bundleIdentifier = await RunningApplicationsReader.bundleIdentifier(of: app)
                    self?.handleWorkspaceApplication(bundleIdentifier: bundleIdentifier)
                }
            }
        }
    }

    private func handleWorkspaceApplication(bundleIdentifier: String?) {
        guard let bundleIdentifier,
              let provider = provider(forBundleIdentifier: bundleIdentifier),
              provider.supportsNativeRuntimePrompt else { return }

        recentNativeActivity[provider] = Date()
        scheduleEvaluation()
    }

    func seedNativeActivityIfNeeded(frontmostBundleID: String?, now: Date) {
        guard let frontmostBundleID,
              let provider = provider(forBundleIdentifier: frontmostBundleID),
              provider.supportsNativeRuntimePrompt,
              recentNativeActivity[provider] == nil else { return }

        recentNativeActivity[provider] = now
    }

    func runtimeReminderCandidates(
        now: Date,
        runningBundleIDs: Set<String>,
        frontmostBundleID: String?
    ) -> [ScoredCandidate] {
        MeetingPromptProvider.allCases.compactMap { provider in
            guard provider.supportsRuntimeOnlyPrompt else { return nil }
            guard provider.activeBundleIdentifiers.contains(where: runningBundleIDs.contains) else { return nil }
            if let suppressedUntil = runtimeSuppressedUntil[provider], suppressedUntil > now {
                recordSuppression(
                    candidate: runtimeCandidate(for: provider, now: now),
                    reason: .runtimeSuppressed,
                    now: now,
                    cooldownReason: runtimeSuppressionReasons[provider]
                )
                return nil
            }

            let isFrontmost = frontmostBundleID.map(provider.activeBundleIdentifiers.contains) ?? false
            guard let presentation = MeetingPromptHeuristics.runtimePresentation(
                providerName: provider.displayName,
                isFrontmost: isFrontmost,
                lastActiveAt: recentNativeActivity[provider],
                now: now,
                meetingShortcut: meetingShortcutDisplay()
            ) else { return nil }

            return ScoredCandidate(
                candidate: runtimeCandidate(
                    for: provider,
                    now: now,
                    title: presentation.title,
                    detail: presentation.detail
                ),
                score: presentation.score
            )
        }
    }

    private func runtimeCandidate(
        for provider: MeetingPromptProvider,
        now: Date,
        title: String? = nil,
        detail: String? = nil
    ) -> Candidate {
        Candidate(
            id: "runtime:\(provider.rawValue)",
            title: title ?? "\(provider.displayName) is active",
            detail: detail ?? MeetingPromptHeuristics.runtimeReminderDetail(meetingShortcut: meetingShortcutDisplay()),
            provider: provider,
            reason: MeetingPromptHeuristics.reason(for: .runtimeApp, hasRuntimeContext: false),
            source: .runtimeApp,
            startDate: now,
            endDate: now.addingTimeInterval(MeetingPromptHeuristics.runtimeReminderSnoozeInterval),
            meetingURL: nil,
            suggestedTranscriptTitle: nil
        )
    }

    func upcomingCalendarCandidates(
        now: Date,
        runningBundleIDs: Set<String>,
        frontmostBundleID: String?
    ) -> [ScoredCandidate] {
        let runtimeSnapshot = MeetingPromptRuntimeSnapshot(
            runningBundleIDs: runningBundleIDs,
            frontmostBundleID: frontmostBundleID,
            recentNativeActivity: recentNativeActivity,
            runtimeSuppressedUntil: runtimeSuppressedUntil
        )

        return MeetingPromptCalendarScoring.calendarCandidates(
            from: calendarEventSnapshots,
            now: now,
            runtimeSnapshot: runtimeSnapshot
        )
        .map { ScoredCandidate(candidate: $0.candidate, score: $0.score) }
    }

    private func provider(forBundleIdentifier bundleIdentifier: String) -> MeetingPromptProvider? {
        MeetingPromptProvider.allCases.first { $0.activeBundleIdentifiers.contains(bundleIdentifier) }
    }
}
