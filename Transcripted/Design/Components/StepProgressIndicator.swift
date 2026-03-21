import SwiftUI

// MARK: - Step Progress Indicator

@available(macOS 26.0, *)
struct StepProgressIndicator: View {
    let currentStep: Int
    let totalSteps: Int

    var body: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(0..<totalSteps, id: \.self) { index in
                Capsule()
                    .fill(fillColor(for: index))
                    .frame(width: index == currentStep ? 28 : 10, height: 10)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: currentStep)
            }
        }
    }

    private func fillColor(for index: Int) -> Color {
        index <= currentStep ? .terracotta : .terracotta.opacity(0.2)
    }
}
