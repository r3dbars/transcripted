import SwiftUI

@available(macOS 26.0, *)
struct AIServicesSettingsSection: View {

    var body: some View {
        SettingsSectionCard(icon: "sparkles", title: "AI Services") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Transcription Engine")
                    .font(.bodyMedium)
                    .foregroundColor(.panelTextPrimary)

                HStack(spacing: Spacing.sm) {
                    Image(systemName: "cpu.fill").foregroundColor(.attentionGreen)
                    Text("Parakeet TDT V3").font(.bodySmall).foregroundColor(.panelTextPrimary)
                    Spacer()
                    localBadge
                }

                HStack(spacing: Spacing.sm) {
                    Image(systemName: "person.2.fill").foregroundColor(.attentionGreen)
                    Text("Sortformer Diarization").font(.bodySmall).foregroundColor(.panelTextPrimary)
                    Spacer()
                    localBadge
                }

                Text("100% local transcription. No cloud API, no internet, no cost.")
                    .font(.caption)
                    .foregroundColor(.panelTextMuted)
                    .padding(.top, Spacing.xs)

                Text("English only · macOS 14.2+ · 16 GB RAM recommended")
                    .font(.caption)
                    .foregroundColor(.panelTextMuted)
            }
        }
    }

    private var localBadge: some View {
        Text("Local")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.panelTextMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.panelCharcoalSurface)
            .cornerRadius(4)
    }
}
