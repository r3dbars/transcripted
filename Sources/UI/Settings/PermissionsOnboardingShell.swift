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
        HStack {
            Button {
                onBack()
            } label: {
                Text("Back")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                    .frame(minWidth: LibraryTokens.minimumHitTarget, minHeight: LibraryTokens.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(canGoBack ? 1 : 0)
            .disabled(!canGoBack)
            .accessibilityIdentifier("transcripted.onboarding.nav.back")

            Spacer()

            if let secondaryTitle {
                Button {
                    onSecondary()
                } label: {
                    Text(secondaryTitle)
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                        .padding(.horizontal, 12)
                        .frame(minHeight: LibraryTokens.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("transcripted.onboarding.nav.secondary")
            }

            Button {
                onNext()
            } label: {
                Text(primaryTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 22)
                    .frame(minHeight: LibraryTokens.minimumHitTarget)
                    .background(
                        RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                            .fill(primaryDisabled ? LibraryTokens.ink3 : LibraryTokens.accent)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous))
            }
            .buttonStyle(.plain)
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
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 20) {
                Text(microphoneMissing ? "Almost set." : modelPresentation.headline)
                    .font(LibraryTokens.title)
                    .foregroundStyle(.primary)

                if microphoneMissing {
                    microphoneMissingNotice
                } else if shortcutsNeedAccessibility {
                    Text("Shortcuts start working once Accessibility is on. Until then, start dictation and meetings from the menu bar.")
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                        .fixedSize(horizontal: false, vertical: true)
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
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 48)
    }

    private var microphoneMissingNotice: some View {
        VStack(spacing: 8) {
            Text("Dictation and meetings need the microphone. Until it's on, you can still transcribe audio and video files with + on the Meetings page.")
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Microphone Settings", action: onOpenMicrophoneSettings)
                .buttonStyle(QuietPermissionButtonStyle())
                .accessibilityIdentifier("transcripted.onboarding.done.open-microphone-settings")
        }
    }

    private func functionKeyNotice(_ warning: String) -> some View {
        VStack(spacing: 6) {
            Text(warning)
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Keyboard Settings") {
                PhysicalDictationTriggerPreferences.openKeyboardSettings()
            }
            .buttonStyle(.plain)
            .font(LibraryTokens.meta)
            .foregroundStyle(LibraryTokens.accent)
            .accessibilityIdentifier("transcripted.onboarding.done.open-keyboard-settings")
        }
    }

    private var modelStatus: some View {
        VStack(spacing: 6) {
            if let statusLine = modelPresentation.statusLine {
                HStack(spacing: 6) {
                    if modelPresentation.isFailed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(LibraryTokens.attention)
                    }
                    Text(statusLine)
                        .font(LibraryTokens.rowTitle)
                        .foregroundStyle(.primary)
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
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 400)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transcripted.onboarding.done.model-status")
    }

    @ViewBuilder
    private var shortcutList: some View {
        Text(dictationShortcutDisplay == nil
            ? "One shortcut to remember."
            : "Two shortcuts to remember.")
            .font(LibraryTokens.meta)
            .foregroundStyle(LibraryTokens.ink2)

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
        .frame(maxWidth: 400)
        .padding(.top, 6)
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
                    .font(LibraryTokens.rowTitle)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
            }
            Spacer(minLength: 12)
            Text(shortcut)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(LibraryTokens.accent)
        }
        .padding(.vertical, 13)
        .frame(minHeight: LibraryTokens.minimumHitTarget)
    }
}
