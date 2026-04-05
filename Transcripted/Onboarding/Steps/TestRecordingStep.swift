import SwiftUI
import Combine
import TranscriptedCore

/// Step 5: Guided product demo — 8 micro-screens teaching the pill UI + live test recording
@available(macOS 26.0, *)
struct TestRecordingStep: View {
    @Bindable var state: OnboardingState

    enum DemoScreen: Int {
        case meetPill = 0
        case hoverExpand = 1
        case duringRecording = 2
        case letsRecord = 3
        case liveRecording = 4
        case processing = 5
        case result = 6
        case ready = 7
    }

    @State private var screen: DemoScreen = .meetPill
    @State private var appeared = false
    @State private var showLabels = false

    // Audio polling
    @State private var smoothedMicLevel: CGFloat = 0
    @State private var recordingSeconds: Int = 0
    @State private var isSilent: Bool = false
    @State private var silenceDuration: TimeInterval = 0
    @State private var pollingTimer: Timer?
    @State private var transcriptionPoller: Timer?

    // Saved pill
    @State private var checkmarkScale: CGFloat = 0.3

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Group {
                switch screen {
                case .meetPill: meetPillScreen
                case .hoverExpand: hoverExpandScreen
                case .duringRecording: duringRecordingScreen
                case .letsRecord: letsRecordScreen
                case .liveRecording: liveRecordingScreen
                case .processing: processingScreen
                case .result: resultScreen
                case .ready: readyScreen
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: screen)

            Spacer()
        }
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.3)) { appeared = true }
            startTranscriptionPoller()
        }
        .onDisappear {
            pollingTimer?.invalidate()
            transcriptionPoller?.invalidate()
        }
    }

    // MARK: - Continue Button (reused across screens)

    private func continueButton(_ label: String = "Continue", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Text(label)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.recordingCoral)
        .controlSize(.large)
        .padding(.top, Spacing.lg)
    }

    // MARK: - Screen 1: Meet the Pill

    private var meetPillScreen: some View {
        VStack(spacing: Spacing.lg) {
            Text("Meet the pill")
                .font(.displayMedium)
                .foregroundColor(.panelTextPrimary)

            Text("This small widget floats in your menu bar, always ready")
                .font(.bodyLarge)
                .foregroundColor(.panelTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)

            // Scaled-up idle pill
            ZStack {
                Capsule().fill(Color.panelCharcoal)
                Capsule().strokeBorder(Color.panelCharcoalSurface, lineWidth: 1.5)
                Image(systemName: "mic.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.panelTextMuted)
            }
            .frame(width: 78, height: 39)
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)

            // Arrow line down + label
            arrowWithLabel("Always here, small and out of the way")

            continueButton { advanceTo(.hoverExpand) }
        }
    }

    // MARK: - Screen 2: Hover to Expand

    private var hoverExpandScreen: some View {
        VStack(spacing: Spacing.lg) {
            Text("Hover to see controls")
                .font(.displayMedium)
                .foregroundColor(.panelTextPrimary)

            Text("Move your mouse over the pill to expand it")
                .font(.bodyLarge)
                .foregroundColor(.panelTextSecondary)

            // Scaled-up expanded pill (matches AuroraIdleView exactly)
            ZStack {
                Capsule().fill(Color.panelCharcoal)
                Capsule().strokeBorder(Color.panelCharcoalSurface, lineWidth: 1.5)

                HStack(spacing: 0) {
                    // Record button (mic icon in circle)
                    ZStack {
                        Circle()
                            .fill(Color.panelCharcoalElevated)
                            .frame(width: 36, height: 36)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.panelTextPrimary)
                    }
                    .frame(width: 50)

                    Spacer()

                    // Transcripts button (clock icon in circle)
                    ZStack {
                        Circle()
                            .fill(Color.panelCharcoalElevated)
                            .frame(width: 36, height: 36)
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.panelTextPrimary)
                    }
                    .frame(width: 50)
                }
                .padding(.horizontal, 8)
            }
            .frame(width: 220, height: 50)
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)

            // Two arrows pointing up to each side
            HStack(spacing: Spacing.xxxl) {
                arrowWithLabel("Start a recording")
                arrowWithLabel("Browse past transcripts")
            }

            continueButton { advanceTo(.duringRecording) }
        }
    }

    // MARK: - Screen 3: During Recording (static demo)

    private var duringRecordingScreen: some View {
        VStack(spacing: Spacing.md) {
            Text("While recording")
                .font(.displayMedium)
                .foregroundColor(.panelTextPrimary)

            Text("The pill shows what's happening in real time")
                .font(.bodyLarge)
                .foregroundColor(.panelTextSecondary)

            // Scaled-up recording pill (static, matches real AuroraRecordingView)
            // Layout: stop | mic LED | timer | system LED | transcripts
            ZStack {
                Capsule().fill(Color.panelCharcoal)
                Capsule().strokeBorder(Color.panelCharcoalSurface, lineWidth: 1.5)

                HStack(spacing: 3) {
                    // Stop button
                    ZStack {
                        Circle().fill(Color.panelCharcoalElevated).frame(width: 34, height: 34)
                        RoundedRectangle(cornerRadius: 3).fill(Color.panelTextPrimary).frame(width: 12, height: 12)
                    }
                    // Coral LED (mic)
                    Circle().fill(Color.recordingCoral).frame(width: 8, height: 8)
                        .shadow(color: .recordingCoral.opacity(0.5), radius: 6)
                    // Timer
                    Text("01:23").font(.system(size: 18, weight: .semibold, design: .monospaced)).foregroundColor(.panelTextPrimary)
                    // Teal LED (system)
                    Circle().fill(Color.auroraTeal).frame(width: 8, height: 8)
                        .shadow(color: .auroraTeal.opacity(0.5), radius: 6)
                    // Transcripts button
                    ZStack {
                        Circle().fill(Color.panelCharcoalElevated).frame(width: 34, height: 34)
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.panelTextPrimary)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(width: 280, height: 50)
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)

            // Arrow lines connecting to each element — 5 labels matching 5 pill elements
            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    verticalLine(height: 20)
                    labelBubble("Stop", subtitle: "End recording")
                }
                .frame(width: 60)

                VStack(spacing: 4) {
                    verticalLine(height: 20, color: .recordingCoral)
                    labelBubble("Your mic", subtitle: "Glows when\nyou speak")
                }
                .frame(width: 68)

                VStack(spacing: 4) {
                    verticalLine(height: 20)
                    labelBubble("Timer")
                }
                .frame(width: 52)

                VStack(spacing: 4) {
                    verticalLine(height: 20, color: .auroraTeal)
                    labelBubble("Meeting\naudio", subtitle: "Zoom, Teams,\netc.")
                }
                .frame(width: 68)

                VStack(spacing: 4) {
                    verticalLine(height: 20)
                    labelBubble("Transcripts", subtitle: "View past\nrecordings")
                }
                .frame(width: 72)
            }
            .padding(.top, Spacing.xs)

            continueButton("Got it") { advanceTo(.letsRecord) }
        }
    }

    // MARK: - Screen 4: Let's Record

    private var letsRecordScreen: some View {
        VStack(spacing: Spacing.lg) {
            Text("Let's try it")
                .font(.displayMedium)
                .foregroundColor(.panelTextPrimary)
                .onAppear { state.testDemoReachedPrompt = true }

            Text("Say something and we'll transcribe it in seconds")
                .font(.bodyLarge)
                .foregroundColor(.panelTextSecondary)
                .multilineTextAlignment(.center)

            Button(action: {
                state.startTestRecording()
                advanceTo(.liveRecording)
            }) {
                HStack(spacing: Spacing.sm) {
                    Circle().fill(.white.opacity(0.3)).frame(width: 12, height: 12)
                        .overlay(Circle().fill(.white).frame(width: 6, height: 6))
                    Text("Start Recording")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 16)
                .background(Capsule().fill(Color.recordingCoral))
            }
            .buttonStyle(.plain)

            Text("Speak clearly for a few seconds")
                .font(.bodySmall)
                .foregroundColor(.panelTextMuted)
        }
    }

    // MARK: - Screen 5: Live Recording

    private var liveRecordingScreen: some View {
        VStack(spacing: Spacing.lg) {
            Text("Recording")
                .font(.displayMedium)
                .foregroundColor(.panelTextPrimary)
                .onAppear { startAudioPolling() }
                .onDisappear { stopAudioPolling() }

            Text("Speak into your microphone")
                .font(.bodyLarge)
                .foregroundColor(.panelTextSecondary)

            // Live pill (actual size)
            ZStack {
                Capsule().fill(Color.panelCharcoal)
                Capsule().strokeBorder(Color.panelCharcoalSurface, lineWidth: 1)
                HStack(spacing: 2) {
                    Button(action: {
                        stopAudioPolling()
                        state.stopTestRecording()
                        advanceTo(.processing)
                    }) {
                        ZStack {
                            Circle().fill(Color.panelCharcoalElevated).frame(width: 26, height: 26)
                            RoundedRectangle(cornerRadius: 2.5).fill(Color.panelTextPrimary).frame(width: 9, height: 9)
                        }
                    }
                    .buttonStyle(.plain)
                    ledDot(level: smoothedMicLevel, color: .recordingCoral)
                    Text(String(format: "%02d:%02d", recordingSeconds / 60, recordingSeconds % 60))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(.panelTextPrimary).lineLimit(1).fixedSize()
                    ledDot(level: 0.05, color: .auroraTeal)
                }
                .padding(.horizontal, 6)
            }
            .frame(width: 160, height: 36)
            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)

            let remaining = max(0, 15 - recordingSeconds)
            Text(remaining > 0 ? "\(remaining)s remaining" : "Finishing up...")
                .font(.bodyMedium)
                .foregroundColor(.panelTextMuted)
                .monospacedDigit()

            if isSilent && silenceDuration > 5.0 {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 12)).foregroundColor(.recordingCoral)
                    Text("We can't hear you. Check your microphone.")
                        .font(.bodySmall).foregroundColor(.panelTextSecondary)
                }
                .transition(.opacity)
            }
        }
    }

    // MARK: - Screen 6: Processing

    private var processingScreen: some View {
        VStack(spacing: Spacing.lg) {
            Text("Transcribing...")
                .font(.displayMedium)
                .foregroundColor(.panelTextPrimary)

            ZStack {
                Capsule().fill(Color.panelCharcoal)
                Capsule().strokeBorder(Color.panelCharcoalSurface, lineWidth: 1)
                HStack(spacing: Spacing.sm) {
                    ProgressView().scaleEffect(0.6).tint(.panelTextMuted)
                    Text("Processing...").font(.system(size: 12, weight: .medium)).foregroundColor(.panelTextSecondary)
                }
            }
            .frame(width: 160, height: 36)
            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)

            Text("This usually takes a few seconds")
                .font(.bodySmall)
                .foregroundColor(.panelTextMuted)
        }
    }

    // MARK: - Screen 7: Result (pill + tray)

    @State private var showTray = false

    private var resultScreen: some View {
        VStack(spacing: 0) {
            Text("Here's what you said")
                .font(.displayMedium)
                .foregroundColor(.panelTextPrimary)
                .padding(.bottom, Spacing.lg)

            // Saved pill + transcript tray
            VStack(spacing: 0) {
                // Transcript tray
                if showTray {
                    VStack(alignment: .leading, spacing: 0) {
                        if let transcript = state.testTranscriptText, !transcript.isEmpty {
                            HStack(alignment: .top, spacing: Spacing.sm) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color.accentBlue)
                                    .frame(width: 3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("You")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.accentBlue)
                                    Text(transcript)
                                        .font(.system(size: 14))
                                        .foregroundColor(.panelTextPrimary)
                                        .lineLimit(4)
                                }
                            }
                            .padding(Spacing.md)
                        } else {
                            Text("No speech detected. Try speaking louder next time.")
                                .font(.bodySmall)
                                .foregroundColor(.panelTextMuted)
                                .padding(Spacing.md)
                        }
                    }
                    .frame(width: 280)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.lg)
                            .fill(.ultraThinMaterial)
                            .environment(\.colorScheme, .dark)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.lg)
                            .strokeBorder(Color.panelCharcoalSurface, lineWidth: 1)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)))
                    .padding(.bottom, Spacing.xs)
                }

                // Saved pill
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Color.panelCharcoal)
                    RoundedRectangle(cornerRadius: 16).strokeBorder(Color.attentionGreen.opacity(0.45), lineWidth: 1)
                    RoundedRectangle(cornerRadius: 16).fill(
                        RadialGradient(colors: [Color.attentionGreen.opacity(0.15), Color.clear], center: .leading, startRadius: 0, endRadius: 200)
                    )
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundColor(.attentionGreen)
                            .scaleEffect(checkmarkScale)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Your Test Recording").font(.system(size: 13, weight: .semibold)).foregroundColor(.panelTextPrimary)
                            Text("\(state.testRecordingDuration)s \u{00B7} 1 speaker").font(.system(size: 11)).foregroundColor(.panelTextSecondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.md)
                }
                .frame(width: 260, height: 56)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            }
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { checkmarkScale = 1.1 }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8).delay(0.3)) { checkmarkScale = 1.0 }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85).delay(0.8)) { showTray = true }
            }

            continueButton {
                state.generateWelcomeFile()
                advanceTo(.ready)
            }
        }
    }

    // MARK: - Screen 8: Ready
    // No internal Continue button — the nav bar's "Start Using Transcripted" is the only action.

    private var readyScreen: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.attentionGreen)

            Text("You're all set")
                .font(.displayMedium)
                .foregroundColor(.panelTextPrimary)

            HStack(spacing: Spacing.xs) {
                Text("Press").font(.bodyLarge).foregroundColor(.panelTextSecondary)
                keyCap("\u{2318}"); keyCap("\u{21E7}"); keyCap("R")
                Text("from any app").font(.bodyLarge).foregroundColor(.panelTextSecondary)
            }

            Text("Click \"Start Using Transcripted\" below to begin")
                .font(.bodySmall)
                .foregroundColor(.panelTextMuted)
        }
        .onAppear { state.testRecordingPhase = .complete }
    }

    // MARK: - Reusable Components

    private func arrowWithLabel(_ text: String) -> some View {
        VStack(spacing: 4) {
            verticalLine(height: 24)
            labelBubble(text)
        }
    }

    private func verticalLine(height: CGFloat, color: Color = .panelTextMuted) -> some View {
        VStack(spacing: 0) {
            Circle().fill(color.opacity(0.6)).frame(width: 4, height: 4)
            Rectangle().fill(color.opacity(0.3)).frame(width: 1, height: height)
        }
    }

    private func labelBubble(_ text: String, subtitle: String? = nil) -> some View {
        VStack(spacing: 2) {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.panelTextPrimary)
                .multilineTextAlignment(.center)
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.panelTextMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.panelCharcoalElevated))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.panelCharcoalSurface, lineWidth: 0.5))
    }

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundColor(.panelTextPrimary)
            .frame(width: 28, height: 28)
            .background(Color.panelCharcoalSurface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Color.panelTextMuted.opacity(0.3), lineWidth: 0.5))
    }

    private func ledDot(level: CGFloat, color: Color) -> some View {
        let boosted = min(level * 1.6, 1.0)
        let coreOpacity = 0.4 + Double(boosted) * 0.6
        let haloOpacity = 0.08 + Double(boosted) * 0.25
        let haloSize = 8 + boosted * 14
        let coreSize: CGFloat = 3 + boosted * 1.5
        return ZStack {
            Circle().fill(RadialGradient(colors: [color.opacity(haloOpacity), color.opacity(haloOpacity * 0.3), Color.clear], center: .center, startRadius: 0, endRadius: haloSize / 2)).frame(width: haloSize, height: haloSize)
            Circle().fill(color.opacity(coreOpacity)).frame(width: coreSize, height: coreSize).blur(radius: 0.5)
        }.frame(width: 22, height: 22)
    }

    // MARK: - Navigation

    private func advanceTo(_ next: DemoScreen) {
        showLabels = false
        withAnimation(.easeInOut(duration: 0.25)) { screen = next }
    }

    // MARK: - Audio Polling

    private func startAudioPolling() {
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            guard let audio = state.testAudio else { return }
            let target = CGFloat(audio.audioLevel)
            let factor: CGFloat = target > smoothedMicLevel ? 0.55 : 0.15
            smoothedMicLevel += (target - smoothedMicLevel) * factor
            recordingSeconds = Int(audio.recordingDuration)
            isSilent = audio.isSilent
            silenceDuration = audio.silenceDuration
            if !audio.isRecording && state.testRecordingPhase == .transcribing && screen == .liveRecording {
                stopAudioPolling()
                advanceTo(.processing)
            }
        }
    }

    private func stopAudioPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    // MARK: - Transcription Polling

    private func startTranscriptionPoller() {
        transcriptionPoller = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            guard screen == .processing || state.testRecordingPhase == .transcribing else { return }
            if let tm = state.testTaskManager, tm.lastSavedTranscriptURL != nil {
                transcriptionPoller?.invalidate()
                state.parseTestTranscript()
                advanceTo(.result)
                return
            }
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TranscriptedOnboarding")
            if let files = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
                let mdFiles = files.filter { $0.pathExtension == "md" && $0.lastPathComponent.hasPrefix("Call_") }
                    .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
                if let latest = mdFiles.first {
                    transcriptionPoller?.invalidate()
                    state.parseTestTranscriptFromURL(latest)
                    advanceTo(.result)
                }
            }
        }
    }
}

#if DEBUG
@available(macOS 26.0, *)
#Preview { TestRecordingStep(state: OnboardingState()).frame(width: 720, height: 580).background(Color.panelCharcoal) }
#endif
