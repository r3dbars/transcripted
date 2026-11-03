// CallSpeakerNamesToggleRow.swift
// Settings > Speakers: "Name speakers from the call app"
// (`CallSpeakerNamesPreferences`, default on). Read on every poll, so the
// switch takes effect mid-meeting.

import SwiftUI

struct CallSpeakerNamesToggleRow: View {
    @State private var isOn = CallSpeakerNamesPreferences.isEnabled()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Name speakers from the call app")
                    .font(LibraryTokens.rowTitle)
                    .foregroundStyle(.primary)
                Text("Reads who's talking in Zoom, Meet, Teams or Slack while a meeting records. Names stay on this Mac.")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            Toggle("Name speakers from the call app", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.regular)
                .tint(.accentColor)
                .accessibilityIdentifier("transcripted.settings.speakers.call-app-names")
        }
        .onChange(of: isOn) { _, enabled in
            CallSpeakerNamesPreferences.setEnabled(enabled)
        }
    }
}
