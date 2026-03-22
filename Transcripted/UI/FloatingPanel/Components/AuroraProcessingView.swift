import SwiftUI

// MARK: - Aurora Processing View
/// Clean processing view with a progress bar at the bottom of the capsule
/// Replaces the previous aurora fog with a simple, informative design
/// Progress bar fills with accentBlue; indeterminate shimmer when progress unknown

@available(macOS 26.0, *)
struct AuroraProcessingView: View {
    let status: DisplayStatus

    @Environment(\.accessibilityReduceMotion) var reduceMotion

    @State private var shimmerOffset: CGFloat = -1.0
    @State private var stepStartTime: Date = Date()
    @State private var stepElapsedTime: TimeInterval = 0

    private let width: CGFloat = PillDimensions.recordingWidth
    private let height: CGFloat = PillDimensions.recordingHeight

    var body: some View {
        ZStack {
            // Dark capsule background
            Capsule()
                .fill(Color.panelCharcoal)

            // Subtle blue border
            Capsule()
                .strokeBorder(Color.accentBlue.opacity(0.25), lineWidth: 1)

            // Progress bar at bottom
            progressBar
                .clipShape(Capsule())

            // Status text
            VStack(spacing: 2) {
                Text(progressText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.panelTextPrimary)
                    .lineLimit(1)

                if let warning = warningText {
                    Text(warning)
                        .font(.system(size: 10))
                        .foregroundColor(.panelTextMuted)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: width, height: height)
        .onAppear {
            stepStartTime = Date()
            startShimmer()
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            stepElapsedTime = Date().timeIntervalSince(stepStartTime)
        }
        .onChange(of: status) { _, _ in
            stepStartTime = Date()
            stepElapsedTime = 0
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Processing: \(status.statusText)")
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.clear

                // Track
                Rectangle()
                    .fill(Color.panelCharcoalSurface.opacity(0.4))
                    .frame(height: 3)

                // Fill
                if let progress = determinateProgress {
                    Rectangle()
                        .fill(Color.accentBlue)
                        .frame(width: geo.size.width * progress, height: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Indeterminate shimmer
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentBlue.opacity(0.0),
                                    Color.accentBlue.opacity(0.6),
                                    Color.accentBlue.opacity(0.0)
                                ],
                                startPoint: UnitPoint(x: shimmerOffset, y: 0.5),
                                endPoint: UnitPoint(x: shimmerOffset + 0.4, y: 0.5)
                            )
                        )
                        .frame(height: 3)
                }
            }
        }
    }

    // MARK: - Progress Logic

    private var determinateProgress: CGFloat? {
        switch status {
        case .transcribing(let progress):
            return CGFloat(progress).clamped(to: 0...1)
        case .finishing:
            return 0.95
        default:
            return nil
        }
    }

    private var progressText: String {
        if let progress = determinateProgress {
            let pct = Int(progress * 100)
            return "Processing \(pct)%"
        }
        return "Processing..."
    }

    private var warningText: String? {
        if stepElapsedTime > 120 {
            return "Taking longer than usual"
        } else if stepElapsedTime > 90 {
            return "Taking a moment..."
        }
        return nil
    }

    // MARK: - Shimmer

    private func startShimmer() {
        guard !reduceMotion else {
            shimmerOffset = 0.3
            return
        }
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            shimmerOffset = 1.0
        }
    }
}

// MARK: - Clamped Helper

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
struct AuroraProcessingView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black
            VStack(spacing: 20) {
                AuroraProcessingView(status: .gettingReady)
                AuroraProcessingView(status: .transcribing(progress: 0.45))
                AuroraProcessingView(status: .finishing)
            }
        }
        .frame(width: 400, height: 300)
    }
}
#endif
