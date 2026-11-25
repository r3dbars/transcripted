// PermissionsOnboardingPractice.swift
// Setup's two practice takes. These are real dictations: the person presses
// the real key, the island listens, and paste-back puts the words in this
// screen's text field. Nothing here records or transcribes; the screen only
// watches the existing signals (STTRouter's recording flags and the
// dictation-saved / no-speech notifications) to know a take landed.

import SwiftUI
import AppKit

struct OnboardingPracticeStage: View {
    let kind: OnboardingPracticePresentation.Kind
    let progressLabel: String?
    @ObservedObject var sttRouter: STTRouter
    let accessibilityGranted: Bool
    let keyEnabled: Bool
    let keyDisplay: String
    let keyBehavior: DictationKeyBehavior
    let isDone: Bool
    let onTakeStarted: () -> Void
    let onHeardNothing: () -> Void
    let onTakeSaved: () -> Void

    @State private var text = ""
    @State private var takeInFlight = false
    @State private var textAtTakeStart = ""
    @State private var heardNothing = false
    @State private var fillTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    /// How long after a take is saved the paste gets to land in the field
    /// before the screen shows the saved words itself.
    private static let pasteGraceNanoseconds: UInt64 = 1_200_000_000

    private var presentation: OnboardingPracticePresentation {
        OnboardingPracticePresentation.make(
            kind: kind,
            phase: OnboardingPracticePresentation.phase(
                accessibilityGranted: accessibilityGranted,
                keyEnabled: keyEnabled,
                modelState: sttRouter.modelDownloadState,
                isRecording: sttRouter.isRecording,
                isTranscribing: sttRouter.isTranscribing,
                takeDone: isDone,
                heardNothing: heardNothing
            ),
            keyDisplay: keyDisplay,
            keyBehavior: keyBehavior
        )
    }

    var body: some View {
        let presentation = presentation
        OnboardingStageLayout(
            label: progressLabel,
            headline: presentation.headline,
            detail: presentation.instruction,
            identifier: kind == .first
                ? "transcripted.onboarding.practice.first"
                : "transcripted.onboarding.practice.hands-free"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                field
                status(presentation)
            }
        }
        .onAppear { fieldFocused = true }
        .onDisappear { fillTask?.cancel() }
        .onChange(of: sttRouter.isRecording) { _, isRecording in
            guard isRecording, !isDone else { return }
            takeInFlight = true
            heardNothing = false
            textAtTakeStart = text
            fillTask?.cancel()
            onTakeStarted()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .foregroundDictationDidSave)
        ) { notification in
            guard takeInFlight, !isDone, let savedText = notification.object as? String else { return }
            takeInFlight = false
            onTakeSaved()
            showSavedWordsIfPasteMissed(savedText)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .dictationNoSpeechDetected).receive(on: DispatchQueue.main)
        ) { _ in
            guard takeInFlight, !isDone else { return }
            takeInFlight = false
            heardNothing = true
            onHeardNothing()
        }
    }

    private var field: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(TextRole.body.font())
                .foregroundStyle(LibraryTokens.ink)
                .scrollContentBackground(.hidden)
                .focused($fieldFocused)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .accessibilityLabel("Practice text")
                .accessibilityIdentifier("transcripted.onboarding.practice.field")
            if text.isEmpty {
                Text("Your words show up here.")
                    .textRole(.body)
                    .foregroundStyle(LibraryTokens.ink3)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 112)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.control, style: .continuous)
                .fill(DesignTokens.paper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.control, style: .continuous)
                .stroke(fieldFocused ? DesignTokens.hairlineStrong : DesignTokens.hairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func status(_ presentation: OnboardingPracticePresentation) -> some View {
        if let status = presentation.status {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(LibraryTokens.accent)
                            .accessibilityHidden(true)
                    } else if presentation.statusIsLive {
                        Circle()
                            .fill(LibraryTokens.accent)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    Text(status)
                        .textRole(.meta)
                        .foregroundStyle(isDone ? LibraryTokens.ink : LibraryTokens.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if presentation.showsProgress {
                    Group {
                        if let progress = presentation.progress {
                            ProgressView(value: progress)
                        } else {
                            ProgressView()
                        }
                    }
                    .progressViewStyle(.linear)
                    .tint(LibraryTokens.accent)
                    .frame(maxWidth: 260)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("transcripted.onboarding.practice.status")
        }
    }

    /// Paste-back is the real path: a take aimed at this window goes straight
    /// into the focused field (`OwnWindowTextDelivery`), counts as pasted and
    /// the island says Pasted. It can still miss (the field lost focus, or
    /// focus moved to another app). The take was saved either way, so after a
    /// short grace period show the saved words here instead of an empty field.
    private func showSavedWordsIfPasteMissed(_ savedText: String) {
        let before = textAtTakeStart
        let saved = savedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.isEmpty else { return }
        fillTask?.cancel()
        fillTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.pasteGraceNanoseconds)
            guard !Task.isCancelled, text == before else { return }
            text = before.isEmpty ? saved : before + " " + saved
        }
    }
}
