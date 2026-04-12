import SwiftUI
import AppKit
import TranscriptedCore

struct TranscriptedSettingsView: View {
    @ObservedObject var speakerPeopleModel: SpeakerPeopleSettingsViewModel
    @State private var rightOptionEnabled = HotkeyPreferences.rightOptionDictationEnabled()
    @State private var uiSoundsEnabled = UISoundPreferences.isEnabled()
    @State private var crashReportingEnabled = CrashReportingPreferences.isEnabled()
    @State private var anonymousAnalyticsEnabled = AnalyticsPreferences.isEnabled()
    @State private var sentryTestStatus: String?
    @State private var permissionStates = PermissionSnapshot.current()
    @State private var captureLibraryURL = FileManager.default.transcriptedCaptureLibraryDir

    init(speakerPeopleModel: SpeakerPeopleSettingsViewModel) {
        self.speakerPeopleModel = speakerPeopleModel
    }

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

                SettingsSection(title: "Feedback", detail: "Use subtle macOS system sounds to confirm dictation state changes.") {
                    Toggle("Play dictation feedback sounds", isOn: Binding(
                        get: { uiSoundsEnabled },
                        set: { newValue in
                            uiSoundsEnabled = newValue
                            UISoundPreferences.setEnabled(newValue)
                        }
                    ))

                    Text(uiSoundsEnabled
                        ? "Transcripted will play quiet cues when dictation starts, stops, completes, or ends with no speech."
                        : "Dictation sounds are off."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                SettingsSection(title: "Diagnostics", detail: "Crash reports and anonymous usage statistics stay separate, scoped, and scrubbed before anything leaves this Mac.") {
                    Toggle("Send crash and error reports", isOn: Binding(
                        get: { crashReportingEnabled },
                        set: { newValue in
                            crashReportingEnabled = newValue
                            CrashReportingPreferences.setEnabled(newValue)
                            CrashReporter.shared.refreshPreference()
                            sentryTestStatus = nil
                        }
                    ))
                    .disabled(!CrashReporter.isAvailable)

                    Toggle("Send anonymous usage statistics", isOn: Binding(
                        get: { anonymousAnalyticsEnabled },
                        set: { newValue in
                            anonymousAnalyticsEnabled = newValue
                            AnalyticsPreferences.setEnabled(newValue)
                        }
                    ))
                    .disabled(!AnalyticsReporter.isAvailable)

                    HStack {
                        Button("Send Test Sentry Event") {
                            sendTestSentryEvent()
                        }
                        .disabled(!CrashReporter.isAvailable || !crashReportingEnabled)

                        if let sentryTestStatus {
                            Text(sentryTestStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(crashReportingFootnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(analyticsFootnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsSection(title: "Permissions", detail: "Transcripted only asks for permissions that support local capture, paste-back, and optional meeting prompts.") {
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

                SpeakerPeopleSettingsSection(model: speakerPeopleModel)

                SettingsSection(title: "Storage", detail: "Captures can live anywhere you want, while app state stays separated under Application Support.") {
                    StorageRow(title: "Capture library", url: captureLibraryURL)
                    StorageRow(title: "Meeting captures", url: MeetingStoragePaths.transcriptsFolder)
                    StorageRow(title: "Dictation captures", url: DictationStoragePaths.transcriptsFolder)
                    StorageRow(title: "App state", url: appStateFolder)
                    StorageRow(title: "App cache", url: cacheFolder)
                    StorageRow(title: "App logs", url: logsFolder)
                    StorageRow(title: "Temporary recordings", url: recordingsFolder)

                    HStack {
                        Button("Choose Capture Library") {
                            chooseCaptureLibrary()
                        }

                        Button("Reset to Default") {
                            TranscriptedStoragePreferences.setCaptureLibraryURL(nil)
                            refreshStoragePaths()
                        }
                    }

                    Text("Choose a folder like an Obsidian vault if you want agents to read the raw Markdown captures directly. Transcripted will keep its databases, cache, logs, and tmp files under Application Support.")
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
            refreshStoragePaths()
            rightOptionEnabled = HotkeyPreferences.rightOptionDictationEnabled()
            uiSoundsEnabled = UISoundPreferences.isEnabled()
            crashReportingEnabled = CrashReportingPreferences.isEnabled()
            anonymousAnalyticsEnabled = AnalyticsPreferences.isEnabled()
        }
    }

    private var appStateFolder: URL {
        FileManager.default.transcriptedStateDir
    }

    private var cacheFolder: URL {
        FileManager.default.transcriptedCacheDir
    }

    private var logsFolder: URL {
        FileManager.default.transcriptedLogsDir
    }

    private var recordingsFolder: URL {
        FileManager.default.transcriptedRecordingsDir
    }

    private var crashReportingFootnote: String {
        if CrashReporter.isAvailable {
            return crashReportingEnabled
                ? "Enabled. Transcripted will send scrubbed crash and error data to Sentry so reliability issues are easier to diagnose. Use the test button to verify your dashboard wiring."
                : "Off. Transcripted will keep crash and error details on this Mac only."
        }
        return "This build does not have a Sentry DSN configured yet, so crash and error reporting stay local."
    }

    private var analyticsFootnote: String {
        if AnalyticsReporter.isAvailable {
            return anonymousAnalyticsEnabled
                ? "Enabled. Transcripted will send only allowlisted anonymous product events such as launches, dictation completions, and meeting workflow milestones using coarse buckets instead of raw content."
                : "Off. Transcripted will not send anonymous usage statistics unless you turn this on."
        }
        return "This build does not have a PostHog project key configured yet, so anonymous usage statistics stay disabled."
    }

    private func sendTestSentryEvent() {
        guard CrashReporter.isAvailable else {
            sentryTestStatus = "Sentry is not configured in this build yet."
            return
        }

        guard crashReportingEnabled else {
            sentryTestStatus = "Turn on crash and error reports first."
            return
        }

        guard let eventID = CrashReporter.shared.sendTestEvent() else {
            sentryTestStatus = "Sentry test event could not be queued."
            return
        }

        sentryTestStatus = "Queued test event \(eventID.prefix(8)). Check Sentry in a few seconds."
    }

    private func refreshPermissions() {
        permissionStates = PermissionSnapshot.current()
    }

    private func refreshStoragePaths() {
        captureLibraryURL = FileManager.default.transcriptedCaptureLibraryDir
    }

    private func chooseCaptureLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select the folder Transcripted should use as its capture library."
        panel.directoryURL = captureLibraryURL

        guard panel.runModal() == .OK, let url = panel.url else { return }
        TranscriptedStoragePreferences.setCaptureLibraryURL(url)
        refreshStoragePaths()
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

struct SettingsSection<Content: View>: View {
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
