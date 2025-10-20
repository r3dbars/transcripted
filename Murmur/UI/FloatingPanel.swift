import SwiftUI
import AppKit

// MARK: - Window Controller

@available(macOS 26.0, *)
class FloatingPanelController: NSWindowController {
    private var transcription: Transcription
    private var audio: Audio

    init(transcription: Transcription, audio: Audio) {
        self.transcription = transcription
        self.audio = audio

        let window = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 170, height: 45),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isOpaque = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x = frame.maxX - window.frame.width - 20
            let y = frame.maxY - window.frame.height - 20
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        let view = FloatingPanelView(transcription: transcription, audio: audio)
        window.contentView = NSHostingView(rootView: view)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
}

class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - SwiftUI View

@available(macOS 26.0, *)
struct FloatingPanelView: View {
    @ObservedObject var transcription: Transcription
    @ObservedObject var audio: Audio

    @State private var showCopiedCheckmark = false
    @State private var showReadyMessage = false
    @State private var fakeProgress: Double = 0.0
    @State private var progressTimer: Timer?
    @State private var checkmarkScale: CGFloat = 0.7
    @State private var isRecordButtonHovered = false
    @State private var isCopyButtonHovered = false
    @State private var isFileButtonHovered = false

    private let windowHeight: CGFloat = 45
    private let windowWidth: CGFloat = 170

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                // Record/Stop button - changes color based on state
                Button(action: { audio.isRecording ? audio.stop() : audio.start() }) {
                    Circle()
                        .fill(audio.isRecording ? .red : .gray)
                        .frame(width: 10, height: 10)
                        .shadow(color: isRecordButtonHovered ? (audio.isRecording ? Color.red : Color.gray).opacity(0.6) : Color.clear, radius: 8, x: 0, y: 0)
                }
                .buttonStyle(PlainButtonStyle())
                .help(makeRecordButtonTooltip())
                .disabled(transcription.isProcessing)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isRecordButtonHovered = hovering
                    }
                }

                // Visualizer - appears when recording
                if audio.isRecording {
                    ZStack {
                        // Background: System audio visualizer (orange/grey)
                        SystemAudioVisualizer(levelHistory: audio.systemAudioLevelHistory)
                            .frame(width: 50, height: 18)

                        // Foreground: Mic audio visualizer (white)
                        AudioVisualizer(levelHistory: audio.audioLevelHistory)
                            .frame(width: 50, height: 18)
                    }
                    .transition(.opacity)
                }

                Spacer()
                    .frame(minWidth: 2, maxWidth: 4)

                // Status indicator - shows timer when recording, percentage when processing, checkmark when complete
                ZStack {
                    if audio.isRecording {
                        Text(formatDuration(audio.recordingDuration))
                            .font(.system(size: 8, weight: .regular, design: .monospaced))
                            .foregroundColor(.white.opacity(0.95))
                            .transition(.opacity)
                    } else if transcription.isProcessing {
                        Text("\(Int(fakeProgress * 100))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                            .transition(.opacity)
                    } else if showReadyMessage {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .scaleEffect(checkmarkScale)
                            .foregroundColor(.green.opacity(0.9))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 30)

                Spacer()
                    .frame(minWidth: 2, maxWidth: 4)

                // Copy button - always visible
                Button(action: copyLastTranscript) {
                    Image(systemName: showCopiedCheckmark ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(transcription.currentText.isEmpty ? 0.4 : (isCopyButtonHovered ? 1.0 : 0.8)))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Copy last transcript to clipboard")
                .disabled(transcription.currentText.isEmpty)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCopyButtonHovered = hovering
                    }
                }

                // Folder button - always visible
                Button(action: openTranscriptsFolder) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(isFileButtonHovered ? 1.0 : 0.8))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Show transcripts folder")
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isFileButtonHovered = hovering
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                LinearGradient(
                    gradient: Gradient(colors: [Color.white.opacity(0.05), Color.clear]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(width: windowWidth, height: windowHeight)
        .overlay(errorOverlay)
        .onChange(of: transcription.isProcessing) { _, newValue in
            if newValue {
                // Processing started - start progress animation
                startProgressAnimation()
            } else {
                // Processing completed - show completion sequence
                if !transcription.currentText.isEmpty {
                    showCompletionSequence()
                } else {
                    stopProgressAnimation()
                }
            }
        }
    }

    private var errorOverlay: some View {
        Group {
            if let error = transcription.error {
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text(error)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(.red.opacity(0.95))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.red.opacity(0.2))
                            .overlay(Capsule().strokeBorder(Color.red.opacity(0.3), lineWidth: 1))
                    )
                    .padding(.bottom, 8)
                }
                .transition(.opacity)
            }
        }
    }

    private func copyLastTranscript() {
        // Try to copy current text, or read from last saved file
        if !transcription.currentText.isEmpty {
            Clipboard.copy(transcription.currentText)
        } else if let fileURL = transcription.lastSavedFileURL {
            // Read from last saved file
            do {
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                Clipboard.copy(content)
            } catch {
                print("Failed to read saved transcript: \(error)")
            }
        }

        // Show checkmark feedback
        withAnimation(.easeInOut(duration: 0.2)) {
            showCopiedCheckmark = true
        }

        // Reset back to copy icon after 1.5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showCopiedCheckmark = false
            }
        }
    }

    private func openTranscriptsFolder() {
        // Use custom location if set, otherwise default
        let transcriptsFolder: URL
        if let customPath = UserDefaults.standard.string(forKey: "transcriptSaveLocation"),
           !customPath.isEmpty {
            transcriptsFolder = URL(fileURLWithPath: customPath)
        } else {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            transcriptsFolder = documentsPath.appendingPathComponent("Murmur Transcripts")
        }

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: transcriptsFolder, withIntermediateDirectories: true)

        // Open in Finder
        NSWorkspace.shared.open(transcriptsFolder)
    }

    private func openSavedFile() {
        if let fileURL = transcription.lastSavedFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func makeRecordButtonTooltip() -> String {
        if audio.isRecording {
            return "Stop recording"
        } else {
            let mode = transcription.usingOnDeviceMode ? "On-Device (Private)" : "Server-Backed"
            return "Start recording (\(mode))"
        }
    }

    private func startProgressAnimation() {
        // Reset progress
        fakeProgress = 0.0

        // Estimate transcription time using sublinear model (processing grows slower than recording)
        let recordingDuration = audio.recordingDuration
        let estimatedDuration: TimeInterval
        if recordingDuration < 30 {
            // Short clips: mostly fixed overhead
            estimatedDuration = 2.5
        } else if recordingDuration < 120 {
            // Medium clips: slow growth (8% of duration above 30s)
            estimatedDuration = 5.0 + (recordingDuration - 30) * 0.08
        } else {
            // Long clips: even slower growth (5% of duration above 2min)
            estimatedDuration = 12.0 + (recordingDuration - 120) * 0.05
        }

        // Calculate increment per update (60 updates per second)
        let updatesPerSecond = 60.0
        let totalUpdates = estimatedDuration * updatesPerSecond
        let increment = 0.95 / totalUpdates // Only go to 95%, not 100%

        // Start timer
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / updatesPerSecond, repeats: true) { _ in
            if fakeProgress < 0.95 {
                // Ease-out curve: slower as we approach the end
                let remainingProgress = 0.95 - fakeProgress
                let easeOutIncrement = increment * (1.0 + remainingProgress * 2.0)

                fakeProgress = min(fakeProgress + easeOutIncrement, 0.95)
            }
        }
    }

    private func stopProgressAnimation() {
        progressTimer?.invalidate()
        progressTimer = nil
        fakeProgress = 0.0
    }

    private func showCompletionSequence() {
        // Step 1: Jump to 100%
        withAnimation(.easeOut(duration: 0.15)) {
            fakeProgress = 1.0
        }

        // Step 2: Brief pause, then crossfade to checkmark
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Start checkmark animation
            checkmarkScale = 0.0
            showReadyMessage = true

            // Crossfade: percentage fades out while checkmark bounces in
            withAnimation(.easeOut(duration: 0.3)) {
                fakeProgress = 0.0  // Fade out percentage
            }

            // Slower bouncy spring animation for checkmark
            withAnimation(.spring(response: 0.7, dampingFraction: 0.5, blendDuration: 0)) {
                checkmarkScale = 0.9
            }

            // Fade out after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeOut(duration: 0.3)) {
                    showReadyMessage = false
                    checkmarkScale = 0.7
                }

                // Clean up
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    stopProgressAnimation()
                }
            }
        }
    }
}

// MARK: - Audio Visualizer

struct AudioVisualizer: View {
    let levelHistory: [Float]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<levelHistory.count, id: \.self) { index in
                Capsule()
                    .fill(barColor(for: index))
                    .frame(width: 2, height: 16)
                    .scaleEffect(y: barHeight(for: index), anchor: .center)
                    .animation(.linear(duration: 0.025), value: levelHistory[index])
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let level = CGFloat(levelHistory[index])
        return min(0.9, max(0.2, level * 1.2))
    }

    private func barColor(for index: Int) -> Color {
        let position = Double(index) / Double(levelHistory.count - 1)
        let opacity = 0.4 + (position * 0.5)
        return Color.white.opacity(opacity)
    }
}

// MARK: - System Audio Visualizer

struct SystemAudioVisualizer: View {
    let levelHistory: [Float]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<levelHistory.count, id: \.self) { index in
                Capsule()
                    .fill(barColor(for: index))
                    .frame(width: 2, height: 16)
                    .scaleEffect(y: barHeight(for: index), anchor: .center)
                    .animation(.linear(duration: 0.025), value: levelHistory[index])
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let level = CGFloat(levelHistory[index])
        return min(0.9, max(0.2, level * 1.2))
    }

    private func barColor(for index: Int) -> Color {
        let position = Double(index) / Double(levelHistory.count - 1)
        // More subtle opacity for background layer
        let opacity = 0.3 + (position * 0.3)
        // Muted orange-grey (dusty orange)
        return Color(red: 0.7, green: 0.55, blue: 0.45).opacity(opacity)
    }
}

// MARK: - Visual Effect

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
