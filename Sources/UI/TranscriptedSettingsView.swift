import SwiftUI
import AppKit

struct TranscriptedSettingsView: View {
    @State private var rightOptionEnabled = HotkeyPreferences.rightOptionDictationEnabled()
    @State private var permissionStates = PermissionSnapshot.current()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcripted Settings")
                        .font(.title2.weight(.semibold))

                    Text("Transcripted is a local-first voice utility for dictation and meeting capture. These controls help you manage shortcuts, permissions, and where to find your data.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                SettingsSection(title: "Shortcuts", detail: "Choose the keyboard shortcuts Transcripted listens for anywhere on your Mac.") {
                    HotkeyRecorderContainer()
                        .frame(height: 76)

                    Toggle("Tap the right Option key to start dictation", isOn: Binding(
                        get: { rightOptionEnabled },
                        set: { newValue in
                            rightOptionEnabled = newValue
                            HotkeyPreferences.setRightOptionDictation(enabled: newValue)
                        }
                    ))

                    Text(rightOptionEnabled
                        ? "A quick tap of the right Option key will also start dictation."
                        : "Dictation will only use the configured keyboard shortcut."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                SettingsSection(title: "Permissions", detail: "Transcripted only asks for permissions that support local capture and paste-back.") {
                    ForEach(TranscriptedPermissionKind.allCases) { kind in
                        PermissionStatusRow(kind: kind, granted: permissionStates[kind] ?? false) {
                            TranscriptedPermissionAccess.openSettings(for: kind)
                            refreshPermissions()
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Refresh Status") {
                            refreshPermissions()
                        }
                    }
                }

                SettingsSection(title: "Storage", detail: "All recordings, transcripts, and logs stay on your Mac.") {
                    StorageRow(title: "Meeting transcripts", url: MeetingStoragePaths.transcriptsFolder)
                    StorageRow(title: "Dictation transcripts", url: DictationStoragePaths.transcriptsFolder)
                    StorageRow(title: "App logs", url: logsFolder)

                    Text("Compatibility note: Transcripted currently stores its app-support data inside the existing Draft-named Application Support folder on disk so this beta can coexist with earlier builds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 680, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            refreshPermissions()
            rightOptionEnabled = HotkeyPreferences.rightOptionDictationEnabled()
        }
    }

    private var logsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Transcripted", isDirectory: true)
    }

    private func refreshPermissions() {
        permissionStates = PermissionSnapshot.current()
    }
}

private struct PermissionSnapshot {
    private(set) var values: [TranscriptedPermissionKind: Bool]

    subscript(kind: TranscriptedPermissionKind) -> Bool? {
        values[kind]
    }

    static func current() -> PermissionSnapshot {
        PermissionSnapshot(values: Dictionary(uniqueKeysWithValues: TranscriptedPermissionKind.allCases.map {
            ($0, TranscriptedPermissionAccess.isGranted($0))
        }))
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
    }
}

private struct PermissionStatusRow: View {
    let kind: TranscriptedPermissionKind
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(kind.title)
                    .font(.subheadline.weight(.semibold))
                Text(kind.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(granted ? "Review" : "Fix") {
                action()
            }
        }
    }
}

private struct StorageRow: View {
    let title: String
    let url: URL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text((url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()

            Button("Show in Finder") {
                if !FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

private struct HotkeyRecorderContainer: NSViewRepresentable {
    func makeNSView(context: Context) -> HotkeyRecorderAppKitView {
        HotkeyRecorderAppKitView(frame: .zero)
    }

    func updateNSView(_ nsView: HotkeyRecorderAppKitView, context: Context) {
        nsView.refreshDisplay()
    }
}
