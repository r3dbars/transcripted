import SwiftUI

struct SettingsSidebarSection {
    let pages: [TranscriptedSettingsPage]

    /// The five places, on ⌘1 to ⌘5: Today, the capture library, Speakers,
    /// and the agent connection. File import is an action on Meetings, not a
    /// place; opt-in writing capture lives on Agent.
    static let primarySection = SettingsSidebarSection(
        pages: [.today, .home, .dictations, .people, .connectAgent]
    )

    /// Configuration lives on one combined scrolling page (.general),
    /// reached from the sidebar's Settings row. No tab strip.
    static func isSettingsPage(_ page: TranscriptedSettingsPage) -> Bool {
        page == .general
    }
}

/// Quiet hover treatment for the sidebar's version line: the same rounded
/// fill the nav rows use, no strokes or glows.
struct SidebarQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                        .fill(isHovering ? LibraryTokens.rowHover : Color.clear)
                )
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { isHovering = $0 }
        }
    }
}

/// One sidebar destination: a plain button around `SettingsSidebarRow`.
/// The automation identifier sits on the button, the single element AX
/// exposes for the row. Put on the row's HStack instead, SwiftUI copies it
/// onto each child and the button joins them, so a row with the "New" badge
/// reads `…sidebar.writing-…sidebar.writing` and UI smoke can't find it.
struct SettingsSidebarButton: View {
    let page: TranscriptedSettingsPage
    let isSelected: Bool
    /// Meetings shows the live recording time while a meeting records.
    var isRecordingMeeting = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsSidebarRow(page: page, isSelected: isSelected, isRecordingMeeting: isRecordingMeeting)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(page.automationIdentifier)
    }
}

struct SettingsSidebarRow: View {
    let page: TranscriptedSettingsPage
    let isSelected: Bool
    var isRecordingMeeting = false

    var body: some View {
        SettingsSidebarRowLabel(
            title: page.title,
            systemImage: page.systemImage,
            isSelected: isSelected,
            help: page.navigationHelp
        ) {
            if page == .home && isRecordingMeeting {
                SidebarRecordingTimer()
            }
        }
    }
}

/// The look every sidebar row shares, the six places and the Settings and
/// Feedback rows under them: a quiet fill for selection, a fainter one on
/// hover, no strokes, glows, or shadows.
struct SettingsSidebarRowLabel<Trailing: View>: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let help: String
    @ViewBuilder var trailing: () -> Trailing

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(TextRole.body.font(weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? LibraryTokens.ink : LibraryTokens.ink2)

            Spacer(minLength: 0)

            trailing()
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .padding(.horizontal, 9)
        .contentShape(RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                .fill(isSelected ? DesignTokens.fillStrong : (isHovering ? LibraryTokens.rowHover : Color.clear))
        )
        .help(help)
        .onHover { isHovering = $0 }
    }
}

extension SettingsSidebarRowLabel where Trailing == EmptyView {
    init(title: String, systemImage: String, isSelected: Bool, help: String) {
        self.init(title: title, systemImage: systemImage, isSelected: isSelected, help: help) { EmptyView() }
    }
}

/// "● 5:07" next to Meetings while a meeting records. Green because it's
/// live. It reads the shell's `SettingsRecordingClock`, so only this label
/// redraws each second, and only while the session's duration is moving.
struct SidebarRecordingTimer: View {
    @Environment(SettingsRecordingClock.self) private var clock: SettingsRecordingClock?

    var body: some View {
        let elapsed = clock?.elapsedText ?? HomeRecordingElapsed.text(0)
        HStack(spacing: 4) {
            Circle()
                .fill(LibraryTokens.accent)
                .frame(width: 6, height: 6)
            Text(elapsed)
                .textRole(.small)
                .monospacedDigit()
                .foregroundStyle(LibraryTokens.accent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording, \(elapsed)")
        .accessibilityIdentifier("transcripted.settings.sidebar.recording-timer")
    }
}
