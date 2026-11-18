// MeetingTitlesSettingsRow.swift
// Settings > Meetings "Titles and summaries" (`MeetingTitlesController`,
// off by default). Turning it on downloads the 3.1 GB on-device model, then
// labels new meetings and, once, the ones already saved.

import SwiftUI

struct MeetingTitlesSettingsRow: View {
    @ObservedObject var controller: MeetingTitlesController = .shared
    var showsDivider = true

    private static let title = "Titles and summaries"

    var body: some View {
        HStack(spacing: 10) {
            GeneralTitleLabel(
                title: Self.title,
                info: GeneralInfo(
                    title: Self.title,
                    message: "After a meeting is transcribed, a small model on this Mac names it and writes a one-line takeaway and a short summary into the meeting's Markdown, so you and your agents can find it later. Nothing leaves this Mac. A name you give a meeting, or its calendar event's title, always wins. Turning it on downloads a 3.1 GB model and then goes through your saved meetings too, newest first, one at a time, never while you record or dictate."
                )
            )

            Spacer(minLength: 10)

            status

            Toggle(Self.title, isOn: Binding(
                get: { controller.isEnabled },
                set: { controller.setEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.regular)
            .help(MeetingTitlesSettingsCopy.help(isEnabled: controller.isEnabled, status: controller.modelStatus))
            .accessibilityLabel(Text(Self.title))
            .accessibilityValue(Text(controller.isEnabled ? "On" : "Off"))
            .accessibilityIdentifier("transcripted.settings.general.meeting-titles")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider()
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch MeetingTitlesSettingsCopy.state(isEnabled: controller.isEnabled, status: controller.modelStatus, activity: controller.activity) {
        case .caption(let text):
            Text(text)
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink2)
        case .progress(let fraction, let text):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                Text(text)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("transcripted.settings.general.meeting-titles.progress")
        case .failed(let text):
            HStack(spacing: 8) {
                Text(text)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.attention)
                SettingsInlineActionButton(title: "Try again", symbolName: "arrow.clockwise") {
                    controller.retry()
                }
                .accessibilityIdentifier("transcripted.settings.general.meeting-titles.retry")
            }
        }
    }
}
