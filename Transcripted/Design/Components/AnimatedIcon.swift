import SwiftUI

// MARK: - Animated Icon

@available(macOS 26.0, *)
struct AnimatedIcon: View {
    let systemName: String
    var size: CGFloat = 64
    var color: Color = .terracotta
    var showGlow: Bool = true
    var isPulsing: Bool = false

    @State private var glowScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            if showGlow {
                Circle().fill(color.opacity(0.2)).frame(width: size * 1.5, height: size * 1.5).blur(radius: 20).scaleEffect(glowScale)
            }
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(LinearGradient(colors: [color, color.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .symbolEffect(.pulse, options: .repeating, isActive: isPulsing)
        }
        .onAppear {
            if showGlow {
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { glowScale = 1.1 }
            }
        }
    }
}
