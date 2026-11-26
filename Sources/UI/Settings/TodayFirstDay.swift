import SwiftUI

// Today's first day: one line that teaches the dictation key, and a small
// checklist for the three things that left setup (calendar, an agent, a
// file). The checklist retires for good once it's dismissed or done.

/// "Hold Right ⌥ in any app and talk. Let go to paste.", worded for the
/// person's own key and key behavior. A nil key means dictation shortcuts
/// are off, so it points at the menu bar instead.
struct TodayKeyHint: Equatable {
    let lead: String
    let key: String?
    let tail: String

    static func make(keyDisplay: String?, behavior: DictationKeyBehavior) -> TodayKeyHint {
        guard let keyDisplay, !keyDisplay.isEmpty else {
            return TodayKeyHint(lead: "Start dictation from the menu bar, then talk.", key: nil, tail: "")
        }
        switch behavior {
        case .holdOrTap, .holdOnly:
            return TodayKeyHint(lead: "Hold", key: keyDisplay, tail: "in any app and talk. Let go to paste.")
        case .tapToToggle:
            return TodayKeyHint(lead: "Tap", key: keyDisplay, tail: "in any app and talk. Tap again to paste.")
        }
    }

    /// The whole line as plain text, for VoiceOver.
    var text: String {
        [lead, key ?? "", tail].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// One thing setup used to ask for and now leaves to Today.
enum TodaySetupStep: String, CaseIterable, Identifiable {
    case calendar
    case agent
    case transcribeFile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: return "Connect your calendar"
        case .agent: return "Connect an agent"
        case .transcribeFile: return HomeCaptureListCopy.TranscribeFileAction.title
        }
    }

    func detail(calendarBlocked: Bool) -> String {
        switch self {
        case .calendar:
            return calendarBlocked
                ? "Calendar is off for Transcripted. Turn it on in System Settings."
                : "Meetings get their real names."
        case .agent:
            return "Let your AI tools read what you capture."
        case .transcribeFile:
            return "Turn a recording or a video into a transcript."
        }
    }

    var automationIdentifier: String { "transcripted.today.setup.\(rawValue)" }
}

/// What the checklist knows. Each step drops out once it's done; the whole
/// list goes once it's dismissed or every step is done.
struct TodaySetupChecklistState: Equatable {
    var calendarConnected: Bool
    var calendarBlocked: Bool
    /// Nil until the off-main check of the agents' config files answers, so
    /// the row never flashes in for someone already connected.
    var agentConnected: Bool?
    var triedFileImport: Bool
    var dismissed: Bool
    /// Setup finished on a build that has the checklist. Someone who set up
    /// on an older build never sees it (`PermissionsOnboardingPreferences`).
    var offered: Bool

    var remaining: [TodaySetupStep] {
        TodaySetupStep.allCases.filter { step in
            switch step {
            case .calendar: return !calendarConnected
            case .agent: return agentConnected == false
            case .transcribeFile: return !triedFileImport
            }
        }
    }

    /// Every step done. The shell then retires the list for good, so it
    /// never comes back if, say, calendar access is turned off later.
    var isComplete: Bool {
        calendarConnected && agentConnected == true && triedFileImport
    }

    var isShown: Bool { offered && !dismissed && !isComplete && !remaining.isEmpty }
}

/// Plain app preferences for the checklist, next to the other window prefs
/// (`SettingsAdvancedExpanded`). Tests
/// pass their own suite; nothing here touches real prefs on its own.
enum TodaySetupChecklistPreferences {
    static let dismissedKey = "TodaySetupChecklistDismissed"
    static let triedFileImportKey = "TodaySetupChecklistTriedFileImport"

    static func isDismissed(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: dismissedKey)
    }

    /// Dismissed or complete: either way it never shows again.
    static func retire(userDefaults: UserDefaults = .standard) {
        userDefaults.set(true, forKey: dismissedKey)
    }

    static func hasTriedFileImport(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: triedFileImportKey)
    }

    static func markTriedFileImport(userDefaults: UserDefaults = .standard) {
        userDefaults.set(true, forKey: triedFileImportKey)
    }

    /// Any import counts as the file step done: ⌘O, a drop, the Meetings
    /// menu or the checklist's own button. Nothing importable, nothing done.
    static func noteFilesImported(count: Int, userDefaults: UserDefaults = .standard) {
        guard count > 0 else { return }
        markTriedFileImport(userDefaults: userDefaults)
    }

    /// Whether setup finished on a build with the checklist.
    static func isOffered(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: PermissionsOnboardingPreferences.finishedWithTodayChecklistKey)
    }
}

// MARK: - Views

/// The empty first day under the header: the key line, where captures go,
/// and Record a meeting. Transcribe a file… sits here only once the
/// checklist (which has it) is gone.
struct TodayFirstDayIntro: View {
    let hint: TodayKeyHint
    let meetingShortcut: String?
    let showsTranscribeFile: Bool
    let onStartMeeting: () -> Void
    let onImportAudioFile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            keyLine
            Text("What you say shows up here.")
                .textRole(.body)
                .foregroundStyle(LibraryTokens.ink2)
            HStack(spacing: 8) {
                Button(action: onStartMeeting) {
                    HStack(spacing: 6) {
                        Text("Record a meeting")
                        if let meetingShortcut {
                            TodayKeyCap(text: meetingShortcut)
                        }
                    }
                }
                .buttonStyle(.transcriptedSecondary)
                .accessibilityIdentifier("transcripted.today.empty.record-meeting")
                if showsTranscribeFile {
                    Button(HomeCaptureListCopy.TranscribeFileAction.title, action: onImportAudioFile)
                        .buttonStyle(.transcriptedQuiet)
                        .accessibilityIdentifier("transcripted.today.empty.transcribe-file")
                }
            }
            .controlSize(.regular)
            .padding(.top, 10)
        }
        .accessibilityIdentifier("transcripted.today.empty")
    }

    private var keyLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(hint.lead)
            if let key = hint.key {
                TodayKeyCap(text: key)
            }
            if !hint.tail.isEmpty {
                Text(hint.tail)
            }
        }
        .textRole(.heading, weight: .regular)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hint.text)
        .accessibilityIdentifier("transcripted.today.empty.key-hint")
    }
}

/// A key drawn as a small keycap: "Right ⌥", "⌥M".
struct TodayKeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .textRole(.meta, weight: .medium)
            .foregroundStyle(LibraryTokens.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                    .fill(DesignTokens.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                    .stroke(DesignTokens.hairlineStrong, lineWidth: 1)
            )
    }
}

/// "Get set up": the steps still left, each a quiet row, and Dismiss.
struct TodaySetupChecklist: View {
    let state: TodaySetupChecklistState
    let onStep: (TodaySetupStep) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Get set up")
                    .textRole(.label)
                    .foregroundStyle(LibraryTokens.ink3)
                Spacer()
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.transcriptedQuiet)
                    .controlSize(.small)
                    .accessibilityIdentifier("transcripted.today.setup.dismiss")
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(state.remaining) { step in
                    TodaySetupRow(step: step, detail: step.detail(calendarBlocked: state.calendarBlocked)) {
                        onStep(step)
                    }
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.today.setup")
    }
}

private struct TodaySetupRow: View {
    let step: TodaySetupStep
    let detail: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .stroke(LibraryTokens.ink3, lineWidth: 1.2)
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .textRole(.body, weight: .medium)
                        .foregroundStyle(LibraryTokens.ink)
                    Text(detail)
                        .textRole(.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(TextRole.small.font(weight: .semibold))
                    .foregroundStyle(isHovering ? LibraryTokens.ink2 : LibraryTokens.ink3)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: LibraryTokens.minimumHitTarget + 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                    .fill(isHovering ? LibraryTokens.rowHover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(step.automationIdentifier)
    }
}
