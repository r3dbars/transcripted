import SwiftUI
import AppKit

// MARK: - Window Controller

class FloatingPanelController: NSWindowController {
    private var transcription: Transcription
    private var audio: Audio

    init(transcription: Transcription, audio: Audio) {
        self.transcription = transcription
        self.audio = audio

        let window = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 60),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
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

struct FloatingPanelView: View {
    @ObservedObject var transcription: Transcription
    @ObservedObject var audio: Audio

    @State private var isExpanded = false
    @State private var showBanner = false
    @State private var bannerMessage = ""

    private let compactHeight: CGFloat = 60
    private let expandedHeight: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            Text(transcription.currentText)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.white.opacity(0.95))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .textSelection(.enabled)

                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                        }
                    }
                    .frame(maxHeight: 150)
                    .onChange(of: transcription.currentText) { _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                .transition(.opacity)

                Divider()
                    .background(Color.white.opacity(0.15))
                    .padding(.horizontal, 14)
            }

            HStack(spacing: 10) {
                Button(action: { audio.isRecording ? audio.stop() : audio.start() }) {
                    Circle()
                        .fill(audio.isRecording ? .red : .gray)
                        .frame(width: 10, height: 10)
                }
                .buttonStyle(PlainButtonStyle())
                .help(audio.isRecording ? "Stop recording" : "Start recording")

                if audio.isRecording {
                    AudioVisualizer(levelHistory: audio.audioLevelHistory)
                        .frame(width: 75, height: 20)
                        .transition(.opacity)
                }

                Spacer()

                if !transcription.currentText.isEmpty {
                    Button(action: openTranscriptsFolder) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Show transcripts folder")
                    .transition(.opacity)
                }

                if audio.isRecording {
                    Text(formatDuration(audio.recordingDuration))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                        .transition(.opacity)
                }

                Button(action: { withAnimation { isExpanded.toggle(); resizeWindow() } }) {
                    Image(systemName: isExpanded ? "chevron.down.circle.fill" : "chevron.up.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
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
        .frame(height: isExpanded ? expandedHeight : compactHeight)
        .overlay(errorOverlay)
        .overlay(processingBanner, alignment: .bottom)
        .onChange(of: transcription.justFinished) { finished in
            if finished {
                showProcessingSequence()
            }
        }
    }

    private var processingBanner: some View {
        Group {
            if showBanner {
                ProcessingBanner(message: bannerMessage)
                    .padding(.bottom, 8)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
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

    private func resizeWindow() {
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first(where: { $0 is FloatingPanel }) else { return }
            var frame = window.frame
            frame.size.height = isExpanded ? expandedHeight : compactHeight
            window.setFrame(frame, display: true, animate: true)
        }
    }

    private func showProcessingSequence() {
        // Phase 1: Show "Processing..." (0.5 seconds)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            bannerMessage = "✨ Processing..."
            showBanner = true
        }

        // Phase 2: Show "Copied!" (after 0.5s, display for 2s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                bannerMessage = "✅ Copied to clipboard!"
            }
        }

        // Phase 3: Hide banner (after total 2.5s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeOut(duration: 0.3)) {
                showBanner = false
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
                    .frame(width: 2, height: 20)
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

// MARK: - Processing Banner

struct ProcessingBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            if message.contains("Processing") {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(.white)
            } else if message.contains("Copied") {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.green)
            }

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                Color.black.opacity(0.3)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
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
