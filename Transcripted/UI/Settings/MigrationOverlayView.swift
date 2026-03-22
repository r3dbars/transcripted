import SwiftUI

@available(macOS 26.0, *)
struct MigrationOverlayView: View {
    let progress: Double
    let status: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()

            VStack(spacing: Spacing.lg) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 48))
                    .foregroundColor(.recordingCoral)

                Text("Importing Transcripts")
                    .font(.headingLarge)
                    .foregroundColor(.panelTextPrimary)

                VStack(spacing: Spacing.sm) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.panelCharcoalSurface)
                                .frame(height: 8)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.recordingCoral)
                                .frame(width: geometry.size.width * progress, height: 8)
                        }
                    }
                    .frame(height: 8)
                    .frame(width: 300)

                    Text(status)
                        .font(.bodySmall)
                        .foregroundColor(.panelTextSecondary)
                        .lineLimit(1)
                }

                Text("\(Int(progress * 100))%")
                    .font(.headingMedium)
                    .foregroundColor(.panelTextMuted)
            }
            .padding(Spacing.xl)
            .background {
                RoundedRectangle(cornerRadius: Radius.lawsCard)
                    .fill(Color.panelCharcoalElevated)
            }
        }
    }
}
