import SwiftUI
import AppKit
import AVFoundation

@available(macOS 26.0, *)
struct SettingsView: View {
    @ObservedObject var modelManager: SpeechModelManager
    @AppStorage("transcriptSaveLocation") private var saveLocation: String = ""
    @AppStorage("selectedMicrophoneID") private var selectedMicrophoneID: String = ""
    @Environment(\.dismiss) private var dismiss

    @State private var availableMicrophones: [AVCaptureDevice] = []

    var body: some View {
        VStack(spacing: 20) {
            Text("Murmur Settings")
                .font(.system(size: 18, weight: .semibold))
                .padding(.top, 16)

            Divider()

            // Microphone Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Audio Input")
                    .font(.system(size: 14, weight: .medium))

                Text("Microphone:")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Picker("", selection: $selectedMicrophoneID) {
                    Text("System Default").tag("")
                    ForEach(availableMicrophones, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("Changes take effect on next recording.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
            .onAppear(perform: loadMicrophones)

            // Transcription Engine
            VStack(alignment: .leading, spacing: 8) {
                Text("Transcription Engine")
                    .font(.system(size: 14, weight: .medium))

                HStack(spacing: 12) {
                    Image(systemName: modelManager.isOnDeviceAvailable ? "shield.lefthalf.filled" : "cloud.fill")
                        .font(.system(size: 24))
                        .foregroundColor(modelManager.isOnDeviceAvailable ? .green : .blue)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(modelManager.isOnDeviceAvailable ? "On-Device (Private)" : "Cloud-Based")
                            .font(.system(size: 13, weight: .semibold))
                        Text(modelManager.isOnDeviceAvailable ? "Audio never leaves your Mac" : "Processed by Apple's servers")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                if !modelManager.isOnDeviceAvailable {
                    Button("Download On-Device Model...") {
                        modelManager.openDictationSettings()
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

            // Transcript Storage
            VStack(alignment: .leading, spacing: 8) {
                Text("Transcript Storage")
                    .font(.system(size: 14, weight: .medium))

                Text("Save Location:")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Text(displayPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Choose Folder...") {
                    chooseSaveFolder()
                }
                .buttonStyle(.bordered)

                Text("Transcripts are automatically saved as Markdown files with timestamps.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

            Spacer()

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(width: 450, height: 500)
        .padding()
    }

    private func loadMicrophones() {
        availableMicrophones = AVCaptureDevice.devices(for: .audio)
    }

    private var displayPath: String {
        if saveLocation.isEmpty {
            return "~/Documents/Murmur Transcripts/ (default)"
        } else {
            return saveLocation.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Save Location"
        panel.message = "Select a folder to save your transcripts"

        // Set initial directory to current location or Documents
        if !saveLocation.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: saveLocation)
        } else {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            panel.directoryURL = documentsPath
        }

        panel.begin { response in
            if response == .OK, let url = panel.url {
                saveLocation = url.path
            }
        }
    }
}
