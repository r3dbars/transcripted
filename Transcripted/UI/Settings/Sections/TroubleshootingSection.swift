import SwiftUI
import AVFoundation
import AppKit

@available(macOS 26.0, *)
struct TroubleshootingSettingsSection: View {

    @State private var showResetConfirmation = false

    var body: some View {
        SettingsSectionCard(icon: "wrench.and.screwdriver.fill", title: "Troubleshooting") {
            VStack(alignment: .leading, spacing: Spacing.md) {
                // Permission Status
                permissionStatusGroup

                Divider().background(Color.panelCharcoalSurface)

                // Data Locations
                dataLocationsGroup

                Divider().background(Color.panelCharcoalSurface)

                // Reset
                resetGroup
            }
        }
    }

    // MARK: - Permission Status

    private var permissionStatusGroup: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Permission Status")
                .font(.bodyMedium)
                .foregroundColor(.panelTextPrimary)

            permissionRow(
                title: "Microphone",
                granted: microphoneGranted,
                grantedLabel: "Granted",
                notGrantedLabel: "Denied",
                notGrantedIcon: "xmark.circle.fill",
                notGrantedColor: .errorRed,
                fixAction: { SystemSettingsHelper.openMicrophoneSettings() }
            )

            permissionRow(
                title: "Screen Recording",
                granted: screenRecordingGranted,
                grantedLabel: "Granted",
                notGrantedLabel: "Not Granted",
                notGrantedIcon: "exclamationmark.triangle.fill",
                notGrantedColor: .warningAmber,
                fixAction: { SystemSettingsHelper.openScreenRecordingSettings() }
            )
        }
    }

    private func permissionRow(
        title: String,
        granted: Bool,
        grantedLabel: String,
        notGrantedLabel: String,
        notGrantedIcon: String,
        notGrantedColor: Color,
        fixAction: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(.bodySmall)
                .foregroundColor(.panelTextSecondary)

            Spacer()

            if granted {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.attentionGreen)
                    Text(grantedLabel)
                        .font(.caption)
                        .foregroundColor(.attentionGreen)
                }
            } else {
                HStack(spacing: Spacing.sm) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: notGrantedIcon)
                            .font(.system(size: 12))
                            .foregroundColor(notGrantedColor)
                        Text(notGrantedLabel)
                            .font(.caption)
                            .foregroundColor(notGrantedColor)
                    }

                    Button("Fix") {
                        fixAction()
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                }
            }
        }
    }

    // MARK: - Data Locations

    private var dataLocationsGroup: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Data Locations")
                .font(.bodyMedium)
                .foregroundColor(.panelTextPrimary)

            dataLocationRow(title: "Transcripts", path: transcriptsPath)
            dataLocationRow(title: "Logs", path: logsPath)
            dataLocationRow(title: "Model Cache", path: modelCachePath)
        }
    }

    private func dataLocationRow(title: String, path: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bodySmall)
                    .foregroundColor(.panelTextSecondary)
                Text(shortenedPath(path))
                    .font(.caption)
                    .foregroundColor(.panelTextMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: path) {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                } else {
                    // Create directory and open if it doesn't exist
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text("Open in Finder")
                        .font(.caption)
                }
            }
            .buttonStyle(SettingsSecondaryButtonStyle())
        }
    }

    // MARK: - Reset

    private var resetGroup: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Reset")
                .font(.bodyMedium)
                .foregroundColor(.panelTextPrimary)

            HStack(spacing: Spacing.sm) {
                Button("Re-run Onboarding") {
                    OnboardingState.resetOnboarding()
                    // Trigger onboarding window via AppDelegate
                    if let appDelegate = NSApp.delegate as? AppDelegate {
                        appDelegate.onboardingWindowController = OnboardingWindowController(onComplete: {
                            appDelegate.onboardingWindowController = nil
                        })
                        appDelegate.onboardingWindowController?.showWithAnimation()
                    }
                }
                .buttonStyle(SettingsSecondaryButtonStyle())

                Button("Reset All Settings") {
                    showResetConfirmation = true
                }
                .buttonStyle(SettingsDestructiveButtonStyle())
            }

            Text("\"Reset All Settings\" clears all preferences and restarts onboarding. Transcripts are not deleted.")
                .font(.caption)
                .foregroundColor(.panelTextMuted)
        }
        .alert("Reset All Settings?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                resetAllSettings()
            }
        } message: {
            Text("This will clear all preferences and restart onboarding. Your transcripts and speaker data will not be deleted.")
        }
    }

    // MARK: - Helpers

    private var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    private var transcriptsPath: String {
        if let custom = UserDefaults.standard.string(forKey: "transcriptSaveLocation"),
           !custom.isEmpty {
            return custom
        }
        return TranscriptSaver.defaultSaveDirectory.path
    }

    private var logsPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Transcripted")
            .path
    }

    private var modelCachePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/models/mlx-community")
            .path
    }

    private func shortenedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func resetAllSettings() {
        // Clear all UserDefaults for this app
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
            UserDefaults.standard.synchronize()
        }

        // Trigger onboarding
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.onboardingWindowController = OnboardingWindowController(onComplete: {
                appDelegate.onboardingWindowController = nil
            })
            appDelegate.onboardingWindowController?.showWithAnimation()
        }
    }
}
