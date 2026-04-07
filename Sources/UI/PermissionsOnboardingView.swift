// PermissionsOnboardingView.swift
// Guided 3-step permissions flow for dictation + meeting capture.

import SwiftUI
import AVFoundation
import ApplicationServices

struct PermissionsOnboardingView: View {
    var onComplete: () -> Void

    @State private var currentStep = 0
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var pollTimer: Timer?

    private let steps: [(title: String, icon: String, description: String, required: Bool)] = [
        ("Microphone", "mic.fill", "Draft needs microphone access for dictation and your side of meetings.", true),
        ("Accessibility", "hand.raised.fill", "Required for global shortcuts and reliable paste-back into the app you were using.", true),
        ("Screen Recording", "rectangle.on.rectangle", "Required so meeting capture can access system audio from calls, videos, and other apps.", true),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Text("Welcome to Draft")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Let's set up the permissions Draft needs for dictation and meeting capture.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .padding(.top, 28)
            .padding(.bottom, 20)

            // Step indicators
            HStack(spacing: 12) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Circle()
                        .fill(stepColor(for: i))
                        .frame(width: 10, height: 10)
                }
            }
            .padding(.bottom, 24)

            // Current step
            if currentStep < steps.count {
                let step = steps[currentStep]
                VStack(spacing: 16) {
                    Image(systemName: step.icon)
                        .font(.system(size: 40))
                        .foregroundColor(.accentColor)

                    Text(step.title)
                        .font(.title3)
                        .fontWeight(.medium)

                    Text(step.description)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)

                    if !step.required {
                        Text("This is optional — you can skip it.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer().frame(height: 8)

                    // Status indicator
                    if isStepGranted(currentStep) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Granted")
                                .font(.callout)
                                .foregroundColor(.green)
                        }
                    }

                    // Action buttons
                    HStack(spacing: 12) {
                        if !step.required {
                            Button("Skip") {
                                advanceStep()
                            }
                            .buttonStyle(.bordered)
                        }

                        if !isStepGranted(currentStep) {
                            Button("Open System Settings") {
                                openSettingsForStep(currentStep)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if isStepGranted(currentStep) {
                            Button("Continue") {
                                advanceStep()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Spacer()
        }
        .frame(width: MenuTokens.panelWidth, height: MenuTokens.panelHeight)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            checkAllPermissions()
            startPolling()
            // Auto-advance past already-granted steps
            autoAdvancePastGranted()
        }
        .onDisappear {
            stopPolling()
        }
    }

    // MARK: - Step Colors

    private func stepColor(for index: Int) -> Color {
        if index < currentStep {
            return .green
        } else if index == currentStep {
            return .accentColor
        }
        return Color.secondary.opacity(0.3)
    }

    // MARK: - Permission Checks

    private func isStepGranted(_ step: Int) -> Bool {
        switch step {
        case 0: return micGranted
        case 1: return accessibilityGranted
        case 2: return screenRecordingGranted
        default: return false
        }
    }

    private func checkAllPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = checkScreenRecording()
    }

    private func checkScreenRecording() -> Bool {
        // CGPreflightScreenCaptureAccess is available macOS 15+
        if #available(macOS 15.0, *) {
            return CGPreflightScreenCaptureAccess()
        }
        // Fallback: attempt a test capture of the main display
        let testImage = CGWindowListCreateImage(
            CGRect(x: 0, y: 0, width: 1, height: 1),
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.nominalResolution]
        )
        return testImage != nil
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                checkAllPermissions()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Navigation

    private func advanceStep() {
        if currentStep < steps.count - 1 {
            currentStep += 1
            // Auto-advance past already-granted steps
            autoAdvancePastGranted()
        } else {
            // All steps done
            stopPolling()
            onComplete()
        }
    }

    private func autoAdvancePastGranted() {
        // Skip steps that are already granted (and required)
        while currentStep < steps.count && isStepGranted(currentStep) && steps[currentStep].required {
            currentStep += 1
        }
        // If we advanced past all steps, complete
        if currentStep >= steps.count {
            stopPolling()
            onComplete()
        }
    }

    // MARK: - Open Settings

    private func openSettingsForStep(_ step: Int) {
        switch step {
        case 0:
            // Request microphone directly
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    micGranted = granted
                }
            }
        case 1:
            // Accessibility — must open System Settings
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        case 2:
            // Screen Recording
            if #available(macOS 15.0, *) {
                CGRequestScreenCaptureAccess()
            }
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    // MARK: - Static Helpers

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: "permissionsOnboardingCompleted")
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: "permissionsOnboardingCompleted")
    }
}
