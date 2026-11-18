// PermissionsOnboardingShell.swift
// Onboarding's window shell (content plus the bottom nav bar) and the
// final Done step. Split out of PermissionsOnboardingView.swift.

import SwiftUI
import AppKit

// MARK: - Window shell

struct OnboardingWindowShell<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let canGoBack: Bool
    let primaryTitle: String
    let primaryDisabled: Bool
    let secondaryTitle: String?
    let onBack: () -> Void
    let onNext: () -> Void
    let onSecondary: () -> Void
    let content: Content

    init(
        canGoBack: Bool,
        primaryTitle: String,
        primaryDisabled: Bool,
        secondaryTitle: String?,
        onBack: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onSecondary: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.canGoBack = canGoBack
        self.primaryTitle = primaryTitle
        self.primaryDisabled = primaryDisabled
        self.secondaryTitle = secondaryTitle
        self.onBack = onBack
        self.onNext = onNext
        self.onSecondary = onSecondary
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                content
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            NavBar(
                canGoBack: canGoBack,
                primaryTitle: primaryTitle,
                primaryDisabled: primaryDisabled,
                secondaryTitle: secondaryTitle,
                onBack: onBack,
                onNext: onNext,
                onSecondary: onSecondary
            )
        }
        .background(LibraryTokens.contentBackground)
        .transcriptedRootTint()
    }
}

private struct NavBar: View {
    let canGoBack: Bool
    let primaryTitle: String
    let primaryDisabled: Bool
    let secondaryTitle: String?
    let onBack: () -> Void
    let onNext: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button("Back", action: onBack)
                .buttonStyle(.transcriptedQuiet)
                .controlSize(.large)
                .opacity(canGoBack ? 1 : 0)
                .disabled(!canGoBack)
                .accessibilityHidden(!canGoBack)
                .accessibilityIdentifier("transcripted.onboarding.nav.back")

            Spacer()

            if let secondaryTitle {
                Button(secondaryTitle, action: onSecondary)
                    .buttonStyle(.transcriptedQuiet)
                    .controlSize(.large)
                    .accessibilityIdentifier("transcripted.onboarding.nav.secondary")
            }

            Button(primaryTitle, action: onNext)
                .buttonStyle(.transcriptedPrimary)
                .controlSize(.large)
                .disabled(primaryDisabled)
                .accessibilityIdentifier("transcripted.onboarding.nav.primary")
        }
        .padding(.horizontal, 32)
        .frame(height: 76)
        .overlay(Rectangle().fill(LibraryTokens.hairline).frame(height: 1), alignment: .top)
    }
}

// MARK: - Done

struct DoneStage: View {
    let modelPresentation: OnboardingDoneModelPresentation
    /// Setup was skipped after a Don't Allow on the microphone.
    let microphoneMissing: Bool
    let onOpenMicrophoneSettings: () -> Void
    /// Asks for paste access again (the same request as its setup screen).
    let onAllowPasteAccess: () -> Void
    let functionKeyWarning: String?
    let dictationShortcutDisplay: String?
    let meetingShortcutDisplay: String
    /// Every global shortcut rides an event tap that needs Accessibility, so
    /// listing them to someone who skipped it would promise keys that do nothing.
    let shortcutsNeedAccessibility: Bool
    /// Finishing setup registers the login item once; say so before macOS
    /// shows its "Login Item added" notice.
    let willOpenAtLogin: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(microphoneMissing ? "Almost set." : modelPresentation.headline)
                .textRole(.display)
                .foregroundStyle(LibraryTokens.ink)

            VStack(alignment: .leading, spacing: 18) {
                if microphoneMissing {
                    microphoneMissingNotice
                } else if shortcutsNeedAccessibility {
                    pasteAccessNotice
                } else {
                    shortcutList
                    if let functionKeyWarning {
                        functionKeyNotice(functionKeyWarning)
                    }
                }

                if modelPresentation.statusLine != nil {
                    modelStatus
                }

                if willOpenAtLogin {
                    Text("Opens at login so it can catch your meetings. Change it in Settings.")
                        .textRole(.meta)
                        .foregroundStyle(LibraryTokens.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 20)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 56)
        .padding(.top, 52)
    }

    private var microphoneMissingNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dictation and meetings need the microphone. Until it's on, you can still transcribe files from Transcribe a file.")
                .textRole(.body)
                .foregroundStyle(LibraryTokens.ink2)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Microphone Settings", action: onOpenMicrophoneSettings)
                .buttonStyle(.transcriptedSecondary)
                .accessibilityIdentifier("transcripted.onboarding.done.open-microphone-settings")
        }
    }

    private var pasteAccessNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your key works once paste access is on. Until then, start from the menu bar and your words go to the clipboard.")
                .textRole(.body)
                .foregroundStyle(LibraryTokens.ink2)
                .fixedSize(horizontal: false, vertical: true)

            Button("Allow paste access", action: onAllowPasteAccess)
                .buttonStyle(.transcriptedSecondary)
                .accessibilityIdentifier("transcripted.onboarding.done.allow-paste-access")
        }
    }

    private func functionKeyNotice(_ warning: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(warning)
                .textRole(.meta)
                .foregroundStyle(LibraryTokens.ink2)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Keyboard Settings") {
                PhysicalDictationTriggerPreferences.openKeyboardSettings()
            }
            .buttonStyle(.transcriptedQuiet)
            .accessibilityIdentifier("transcripted.onboarding.done.open-keyboard-settings")
        }
    }

    private var modelStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let statusLine = modelPresentation.statusLine {
                HStack(spacing: 6) {
                    if modelPresentation.isFailed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(LibraryTokens.attention)
                    }
                    Text(statusLine)
                        .textRole(.body, weight: .medium)
                        .foregroundStyle(LibraryTokens.ink)
                }
            }

            if let progress = modelPresentation.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(LibraryTokens.accent)
                    .frame(maxWidth: 260)
                    .accessibilityIdentifier("transcripted.onboarding.done.model-progress")
            }

            if let detail = modelPresentation.detail {
                Text(detail)
                    .textRole(.meta)
                    .foregroundStyle(LibraryTokens.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transcripted.onboarding.done.model-status")
    }

    private var shortcutList: some View {
        VStack(spacing: 0) {
            if let dictationShortcutDisplay {
                ShortcutRow(
                    label: "Dictate",
                    shortcut: dictationShortcutDisplay,
                    detail: HotkeyPreferences.dictationKeyBehavior().summary
                )
                Rectangle().fill(LibraryTokens.hairline).frame(height: 1)
            }
            ShortcutRow(
                label: "Record a meeting",
                shortcut: meetingShortcutDisplay,
                detail: "Start or stop from anywhere."
            )
        }
        .frame(maxWidth: 440)
    }
}

private struct ShortcutRow: View {
    let label: String
    let shortcut: String
    let detail: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .textRole(.body, weight: .medium)
                    .foregroundStyle(LibraryTokens.ink)
                Text(detail)
                    .textRole(.meta)
                    .foregroundStyle(LibraryTokens.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(shortcut)
                .font(TextRole.label.font())
                .foregroundStyle(LibraryTokens.ink)
        }
        .padding(.vertical, 12)
        .frame(minHeight: LibraryTokens.minimumHitTarget)
        .accessibilityElement(children: .combine)
    }
}
