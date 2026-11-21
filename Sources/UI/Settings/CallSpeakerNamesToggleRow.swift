// CallSpeakerNamesToggleRow.swift
// Settings > Speakers: "Use call app names as hints"
// (`CallSpeakerNamesPreferences`, default on). Read on every poll, so the
// switch takes effect mid-meeting. The names are context only: saved next
// to each voice and offered in review, never used as a speaker's label.

import SwiftUI

struct CallSpeakerNamesToggleRow: View {
    @State private var isOn = CallSpeakerNamesPreferences.isEnabled()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Use call app names as hints")
                    .font(LibraryTokens.rowTitle)
                    .foregroundStyle(.primary)
                Text("Offers the name Zoom, Meet, Teams or Slack showed when you name a voice. Never applied on its own.")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            Toggle("Use call app names as hints", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.regular)
                .accessibilityIdentifier("transcripted.settings.speakers.call-app-names")
        }
        .onChange(of: isOn) { _, enabled in
            CallSpeakerNamesPreferences.setEnabled(enabled)
        }
    }
}
