import SwiftUI

// MARK: - Review Tray View (Expands upward for action item review)

/// Wrapper around ActionItemReviewView with frosted glass styling
/// Expands upward from the pill when reviewing action items
@available(macOS 26.0, *)
struct ReviewTrayView: View {
    @ObservedObject var taskManager: TranscriptionTaskManager

    @State private var isAppearing = false

    var body: some View {
        VStack(spacing: Spacing.sm) {
            // Frosted glass container for review UI
            ZStack {
                // Background with stronger visual presence
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.statusSuccessMuted.opacity(0.3), Color.white.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.2), radius: 16, y: 6)
                    .shadow(color: Color.statusSuccessMuted.opacity(0.1), radius: 20, y: 2)

                // Action Item Review Content
                if taskManager.pendingReview != nil {
                    ActionItemReviewView(taskManager: taskManager)
                        .padding(Spacing.md)
                } else {
                    // Placeholder while loading
                    VStack(spacing: Spacing.sm) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading tasks...")
                            .font(.caption)
                            .foregroundColor(.panelTextSecondary)
                    }
                    .padding(Spacing.lg)
                }
            }
            .frame(width: PillDimensions.trayWidth)
            .frame(minHeight: 100, maxHeight: PillDimensions.trayMaxHeight)

            // Small connector indicator (visual connection to pill below)
            Triangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 12, height: 6)
                .rotationEffect(.degrees(180))
        }
        .scaleEffect(isAppearing ? 1 : 0.9)
        .opacity(isAppearing ? 1 : 0)
        .onAppear {
            withAnimation(.trayExpand) {
                isAppearing = true
            }
        }
        .onDisappear {
            isAppearing = false
        }
    }
}

// MARK: - Triangle Shape (for tray connector)

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
