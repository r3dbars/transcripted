import SwiftUI
import AVFoundation

@available(macOS 14.0, *)
struct SettingsTopBar: View {

    @State private var audioDeviceName: String = "Unknown"

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Branding
            HStack(spacing: Spacing.sm) {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.recordingCoral)

                Text("Transcripted")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.panelTextPrimary)
            }

            Spacer()

            // Audio device
            HStack(spacing: Spacing.xs) {
                Image(systemName: "mic")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.panelTextMuted)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(audioDeviceName)
                        .font(.system(size: 12))
                        .foregroundColor(.panelTextSecondary)
                        .lineLimit(1)
                    Text("System default")
                        .font(.system(size: 9))
                        .foregroundColor(.panelTextMuted)
                }
            }
        }
        .padding(.horizontal, Spacing.lg)
        .frame(height: 40)
        .background(Color.panelCharcoal)
        .onAppear {
            if let device = AVCaptureDevice.default(for: .audio) {
                audioDeviceName = device.localizedName
            } else {
                audioDeviceName = "No input device"
            }
        }
    }
}
