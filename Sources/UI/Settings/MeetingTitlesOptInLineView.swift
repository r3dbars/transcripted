import SwiftUI

/// One quiet line under the Meetings header while on-device titles are off:
/// "Get titles and summaries · 3.1 GB download" (no size when the model is
/// already on disk), Turn on, Dismiss. Turn on flips the feature's own switch
/// (the Settings › Meetings row). The line reads only the controller's
/// published state, so the download, a failure and its Try again show here
/// however and wherever it was turned on, and it goes once the model is
/// ready. Dismiss hides it for good. Never shown during automated launches.
/// Rules: `MeetingTitlesOptInLine`.
struct MeetingTitlesOptInLineView: View {
    let hasMeetings: Bool

    @ObservedObject private var controller = MeetingTitlesController.shared
    @AppStorage(MeetingTitlesOptInLine.dismissedKey) private var dismissed = false

    private var state: MeetingTitlesOptInLine.State {
        MeetingTitlesOptInLine.state(
            isEnabled: controller.isEnabled,
            status: controller.modelStatus,
            dismissed: dismissed,
            isAutomatedLaunch: AutomatedLaunchEnvironment.isActive(),
            hasMeetings: hasMeetings
        )
    }

    var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .offer(let offer):
            HStack(spacing: 10) {
                Text(offer)
                    .foregroundStyle(LibraryTokens.ink2)
                Button(MeetingTitlesOptInLine.turnOnTitle) {
                    controller.setEnabled(true)
                }
                .buttonStyle(.transcriptedQuiet)
                .controlSize(.small)
                .help("Download the titles model and name your meetings on this Mac")
                .accessibilityIdentifier("transcripted.home.meeting-titles.turn-on")
                Button(MeetingTitlesOptInLine.dismissTitle) {
                    dismissed = true
                }
                .buttonStyle(.transcriptedQuiet)
                .controlSize(.small)
                .help("Hide this. You can still turn it on in Settings › Meetings.")
                .accessibilityIdentifier("transcripted.home.meeting-titles.dismiss")
                Spacer(minLength: 0)
            }
            .font(LibraryTokens.meta)
            .lineLimit(1)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transcripted.home.meeting-titles.offer")
        case .downloading(let fraction, let text):
            HStack(spacing: 10) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(LibraryTokens.ink2)
                Spacer(minLength: 0)
            }
            .font(LibraryTokens.meta)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("transcripted.home.meeting-titles.progress")
        case .failed(let reason):
            HStack(spacing: 10) {
                Text(reason)
                    .foregroundStyle(LibraryTokens.attention)
                Button("Try again") { controller.retry() }
                    .buttonStyle(.transcriptedQuiet)
                    .controlSize(.small)
                    .accessibilityIdentifier("transcripted.home.meeting-titles.retry")
                Spacer(minLength: 0)
            }
            .font(LibraryTokens.meta)
            .lineLimit(1)
        }
    }
}
