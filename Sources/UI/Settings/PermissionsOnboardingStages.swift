// PermissionsOnboardingStages.swift
// Setup's welcome, one-ask permission screens and the promise. Each ask shows
// a small sketch of what macOS is about to show, so the dialog isn't a
// surprise. The sketches are pictures only: never clickable, hidden from
// VoiceOver.

import SwiftUI
import AppKit

// MARK: - Shared layout

/// Label, serif headline and one short line, then the screen's own content.
struct OnboardingStageLayout<Content: View>: View {
    let label: String?
    let headline: String
    let detail: String
    /// The screen's automation id, on a container that keeps its children.
    let identifier: String
    let content: Content

    init(
        label: String?,
        headline: String,
        detail: String,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.headline = headline
        self.detail = detail
        self.identifier = identifier
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label {
                Text(label)
                    .textRole(.label)
                    .foregroundStyle(LibraryTokens.ink3)
                    .padding(.bottom, 10)
            }
            Text(headline)
                .textRole(.display)
                .foregroundStyle(LibraryTokens.ink)
            Text(detail)
                .textRole(.body)
                .foregroundStyle(LibraryTokens.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            content
                .padding(.top, 24)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 56)
        .padding(.top, 52)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// A one-line status under an ask: green check once it worked, else a hint.
struct OnboardingStatusLine: View {
    let text: String
    var worked = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if worked {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LibraryTokens.accent)
                    .accessibilityHidden(true)
            }
            Text(text)
                .textRole(.meta)
                .foregroundStyle(worked ? LibraryTokens.ink : LibraryTokens.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Welcome

struct OnboardingWelcomeStage: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                Text("Transcripted")
                    .textRole(.display)
                    .foregroundStyle(LibraryTokens.ink)
                Text("Talk instead of type, in any app. Meetings too.")
                    .textRole(.body)
                    .foregroundStyle(LibraryTokens.ink2)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 56)
    }
}

// MARK: - Microphone

struct OnboardingMicrophoneStage: View {
    let progressLabel: String?
    let granted: Bool
    let blocked: Bool

    var body: some View {
        OnboardingStageLayout(
            label: progressLabel,
            headline: "Let it hear you",
            detail: "So it can type what you say. macOS will ask once.",
            identifier: "transcripted.onboarding.permissions.microphone"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                OnboardingSystemDialogPreview(
                    message: "“Transcripted” would like to access the microphone.",
                    secondary: "Don't Allow",
                    primary: "Allow"
                )
                if granted {
                    OnboardingStatusLine(text: "Microphone is on.", worked: true)
                } else if blocked {
                    OnboardingStatusLine(text: "It's off in System Settings. Turn on Transcripted under Microphone, then come back.")
                }
            }
        }
    }
}

// MARK: - Accessibility

struct OnboardingAccessibilityStage: View {
    let progressLabel: String?
    let granted: Bool

    var body: some View {
        OnboardingStageLayout(
            label: progressLabel,
            headline: "Let it paste for you",
            detail: "So your words land where you're typing, and your key works in every app. macOS calls this Accessibility.",
            identifier: "transcripted.onboarding.permissions.accessibility"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                OnboardingSettingsTogglePreview(
                    pane: "Privacy & Security › Accessibility",
                    row: "Transcripted"
                )
                if granted {
                    OnboardingStatusLine(text: "Paste access is on.", worked: true)
                } else {
                    OnboardingStatusLine(text: "Without it, your words go to the clipboard and you start from the menu bar.")
                }
            }
        }
    }
}

// MARK: - Call audio

struct OnboardingSystemAudioStage: View {
    let progressLabel: String?
    let note: String?
    let isVerified: Bool
    let onSystemAudioSettings: () -> Void

    /// Short copy for where the audio check stands. `actionTitle` is the
    /// shared presentation's button title ("Grant", "Checking…", "Check").
    static func note(
        actionTitle: String,
        state: TranscriptedPermissionAccess.SystemAudioPermissionState,
        isVerified: Bool
    ) -> String? {
        if isVerified { return "Call audio is on." }
        switch actionTitle {
        case "Checking…":
            return "Checking. No audio is saved."
        case "Check":
            return state == .denied
                ? "It's off in System Settings. Turn on System Audio Recording Only, then check again."
                : "Couldn't confirm yet. Play some audio, then check again. You can continue either way."
        default:
            return nil
        }
    }

    var body: some View {
        OnboardingStageLayout(
            label: progressLabel,
            headline: "Hear the other side of calls",
            detail: "For meetings: what other people say through your speakers. Audio only, never your screen.",
            identifier: "transcripted.onboarding.permissions.system-audio"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                OnboardingSettingsTogglePreview(
                    pane: "Screen & System Audio Recording",
                    row: "System Audio Recording Only"
                )
                if let note {
                    OnboardingStatusLine(text: note, worked: isVerified)
                }
                if !isVerified {
                    Button("Open System Settings", action: onSystemAudioSettings)
                        .buttonStyle(.transcriptedQuiet)
                        .accessibilityIdentifier("transcripted.onboarding.permissions.system-audio.settings")
                }
            }
        }
    }
}

// MARK: - Promise

struct OnboardingPromiseStage: View {
    var body: some View {
        OnboardingStageLayout(
            label: nil,
            headline: "It stays on this Mac",
            detail: "Your audio and transcripts are saved here as Markdown files you own. Nothing is uploaded unless you share it.",
            identifier: "transcripted.onboarding.promise"
        ) {
            Text("Anonymous crash and usage stats help us fix bugs. Turn them off in Settings.")
                .textRole(.meta)
                .foregroundStyle(LibraryTokens.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - macOS sketches

/// A sketch of the macOS permission alert: message and two buttons.
private struct OnboardingSystemDialogPreview: View {
    let message: String
    let secondary: String
    let primary: String

    var body: some View {
        OnboardingPreviewStage {
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 32, height: 32)
                Text(message)
                    .textRole(.meta, weight: .semibold)
                    .foregroundStyle(LibraryTokens.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    previewButton(secondary, filled: false)
                    previewButton(primary, filled: true)
                }
            }
            .padding(16)
            .frame(width: 240)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.surface, style: .continuous)
                    .fill(DesignTokens.paper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.surface, style: .continuous)
                    .stroke(DesignTokens.hairlineStrong, lineWidth: 1)
            )
        }
    }

    private func previewButton(_ title: String, filled: Bool) -> some View {
        Text(title)
            .textRole(.small, weight: .medium)
            .foregroundStyle(filled ? DesignTokens.paper : DesignTokens.ink)
            .frame(maxWidth: .infinity, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.control, style: .continuous)
                    .fill(filled ? DesignTokens.ink : DesignTokens.fillStrong)
            )
    }
}

/// A sketch of a System Settings list row with its switch turned on.
private struct OnboardingSettingsTogglePreview: View {
    let pane: String
    let row: String

    var body: some View {
        OnboardingPreviewStage {
            VStack(alignment: .leading, spacing: 10) {
                Text(pane)
                    .textRole(.small)
                    .foregroundStyle(DesignTokens.ink2)
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text(row)
                        .textRole(.meta, weight: .medium)
                        .foregroundStyle(DesignTokens.ink)
                    Spacer(minLength: 12)
                    Capsule()
                        .fill(DesignTokens.ink)
                        .frame(width: 30, height: 18)
                        .overlay(alignment: .trailing) {
                            Circle().fill(DesignTokens.paper).frame(width: 14, height: 14).padding(.trailing, 2)
                        }
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.control, style: .continuous)
                        .fill(DesignTokens.paper)
                )
            }
            .frame(width: 300)
        }
    }
}

/// The recessed stage a sketch sits on.
private struct OnboardingPreviewStage<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.surface, style: .continuous)
                    .fill(DesignTokens.fillStrong)
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
