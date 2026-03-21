import SwiftUI

@available(macOS 26.0, *)
struct MeetingDetectionSettingsSection: View {

    @Binding var autoRecordMeetings: Bool

    var body: some View {
        SettingsSectionCard(icon: "video.fill", title: "Meeting Detection") {
            VStack(alignment: .leading, spacing: Spacing.md) {
                SettingsToggleRow(
                    title: "Auto-Record Meetings",
                    description: "Starts recording when Zoom, Teams, Webex, or FaceTime detects an active call",
                    isOn: $autoRecordMeetings
                )

                if autoRecordMeetings {
                    Divider().background(Color.panelCharcoalSurface)

                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.attentionGreen)
                            Text("Zoom, Microsoft Teams, Webex, FaceTime, Loom")
                                .font(.caption)
                                .foregroundColor(.panelTextMuted)
                        }

                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 11))
                                .foregroundColor(.panelTextMuted)
                            Text("Triggers after 5s of active call audio. Stops 15s after audio drops.")
                                .font(.caption)
                                .foregroundColor(.panelTextMuted)
                        }

                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 11))
                                .foregroundColor(.panelTextMuted)
                            Text("Browser meetings (Google Meet, Teams web) require manual start.")
                                .font(.caption)
                                .foregroundColor(.panelTextMuted)
                        }
                    }
                }
            }
        }
    }
}
