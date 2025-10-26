import SwiftUI
import AppKit

// MARK: - Window Controller

@available(macOS 26.0, *)
class FloatingPanelController: NSWindowController {
    private var taskManager: TranscriptionTaskManager
    private var audio: Audio

    init(taskManager: TranscriptionTaskManager, audio: Audio) {
        self.taskManager = taskManager
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

        let view = FloatingPanelView(taskManager: taskManager, audio: audio)
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
    @ObservedObject var taskManager: TranscriptionTaskManager
    @ObservedObject var audio: Audio

    @State private var showCompletionCheckmark = false
    @State private var checkmarkScale: CGFloat = 0.7
    @State private var isRecordButtonHovered = false
    @State private var isFileButtonHovered = false

    private let windowHeight: CGFloat = 45
    private let windowWidth: CGFloat = 170

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                // Record/Stop button
                Button(action: { audio.isRecording ? audio.stop() : audio.start() }) {
                    Image(systemName: audio.isRecording ? "stop.circle.fill" : "record.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(audio.isRecording ? .red : .gray)
                        .symbolRenderingMode(.hierarchical)
                        .symbolEffect(.pulse, options: .repeating, isActive: audio.isRecording)
                        .symbolEffect(.scale.up, isActive: isRecordButtonHovered)
                        .contentTransition(.symbolEffect(.replace))
                        .shadow(color: isRecordButtonHovered ? (audio.isRecording ? Color.red : Color.gray).opacity(0.6) : Color.clear, radius: 8, x: 0, y: 0)
                }
                .buttonStyle(PlainButtonStyle())
                .help(audio.isRecording ? "Stop recording" : "Start recording")
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isRecordButtonHovered = hovering
                    }
                }

                // Visualizer - appears when recording
                if audio.isRecording {
                    ZStack {
                        // Background: System audio visualizer
                        SystemAudioVisualizer(levelHistory: audio.systemAudioLevelHistory)
                            .frame(width: 50, height: 18)

                        // Foreground: Mic audio visualizer
                        AudioVisualizer(levelHistory: audio.audioLevelHistory)
                            .frame(width: 50, height: 18)
                    }
                    .transition(.opacity)
                }

                Spacer()
                    .frame(minWidth: 2, maxWidth: 4)

                // Status indicator (timer during recording)
                ZStack {
                    if audio.isRecording {
                        // Show recording timer
                        Text(formatDuration(audio.recordingDuration))
                            .font(.system(size: 8, weight: .regular, design: .monospaced))
                            .foregroundColor(.white.opacity(0.95))
                            .transition(.opacity)
                    }
                }
                .frame(width: 30)

                Spacer()
                    .frame(minWidth: 2, maxWidth: 4)

                // Right icon - morphs between processing/checkmark/folder
                ZStack {
                    if taskManager.activeCount > 0 {
                        // Background transcriptions in progress
                        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.9))
                            .symbolRenderingMode(.hierarchical)
                            .symbolEffect(.rotate, options: .repeating, isActive: true)
                            .transition(.opacity.combined(with: .scale))
                    } else if showCompletionCheckmark {
                        // Just completed - brief checkmark
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .scaleEffect(checkmarkScale)
                            .foregroundStyle(.green.opacity(0.9))
                            .symbolRenderingMode(.multicolor)
                            .symbolEffect(.bounce, value: showCompletionCheckmark)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        // Default - folder button
                        Button(action: openTranscriptsFolder) {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(isFileButtonHovered ? 1.0 : 0.8))
                                .symbolRenderingMode(.hierarchical)
                                .symbolEffect(.scale.up, isActive: isFileButtonHovered)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Show transcripts folder")
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isFileButtonHovered = hovering
                            }
                        }
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                .frame(width: 24, height: 24)
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
        .onChange(of: taskManager.justCompleted) { _, newValue in
            if newValue {
                // All background tasks completed - show checkmark
                triggerCompletionCheckmark()
            }
        }
    }

    private var errorOverlay: some View {
        Group {
            if let error = audio.error {
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .symbolRenderingMode(.multicolor)
                            .symbolEffect(.pulse, options: .repeating.speed(0.5))
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

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func triggerCompletionCheckmark() {
        // Show checkmark with bounce animation
        checkmarkScale = 0.0
        showCompletionCheckmark = true

        withAnimation(.spring(response: 0.7, dampingFraction: 0.5, blendDuration: 0)) {
            checkmarkScale = 0.9
        }

        // Fade out after 1.5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.3)) {
                showCompletionCheckmark = false
                checkmarkScale = 0.7
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
        let opacity = 0.3 + (position * 0.3)
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
