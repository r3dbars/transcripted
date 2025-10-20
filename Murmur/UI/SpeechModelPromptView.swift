import SwiftUI

/// Prompt view to encourage users to download on-device speech model for privacy
@available(macOS 26.0, *)
struct SpeechModelPromptView: View {
    @ObservedObject var modelManager: SpeechModelManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 60))
                .foregroundColor(.blue)

            // Title
            Text("Enhanced Privacy Available")
                .font(.title)
                .fontWeight(.bold)

            // Explanation
            VStack(alignment: .leading, spacing: 12) {
                Text("Murmur can transcribe your audio using two methods:")
                    .font(.body)

                // On-Device option
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundColor(.green)
                        .font(.title2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("On-Device (Recommended)")
                            .fontWeight(.semibold)
                        Text("• 100% private - audio never leaves your Mac\n• Works offline\n• Requires ~500MB download (one-time)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Server-backed option
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "cloud.fill")
                        .foregroundColor(.blue)
                        .font(.title2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Server-Backed")
                            .fontWeight(.semibold)
                        Text("• More accurate transcription\n• Requires internet\n• Audio processed by Apple's servers")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

            Spacer()

            // Action buttons
            VStack(spacing: 12) {
                Button(action: {
                    modelManager.openDictationSettings()
                    dismiss()
                }) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Download On-Device Model")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button(action: {
                    modelManager.useServerBacked()
                    dismiss()
                }) {
                    Text("Use Server-Backed (No Download)")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Fine print
            Text("You can change this later in System Settings > Keyboard > Dictation")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(width: 500, height: 550)
    }
}

#Preview {
    if #available(macOS 26.0, *) {
        SpeechModelPromptView(modelManager: SpeechModelManager())
    } else {
        Text("Requires macOS 26.0+")
    }
}
