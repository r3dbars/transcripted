import SwiftUI

// MARK: - Premium Button

@available(macOS 26.0, *)
struct PremiumButton: View {
    enum ButtonVariant {
        case primary
        case secondary
        case ghost
    }

    let title: String
    var icon: String? = nil
    var variant: ButtonVariant = .primary
    var isLoading: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: {
            if !isDisabled && !isLoading { action() }
        }) {
            HStack(spacing: Spacing.sm) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                } else if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .symbolEffect(.scale.up, isActive: isHovered)
                }
                Text(title)
                    .font(.buttonText)
                    .tracking(0.3)
            }
            .foregroundColor(foregroundColor)
            .padding(.vertical, 14)
            .padding(.horizontal, Spacing.lg)
            .frame(minWidth: 120)
            .background(backgroundView)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(borderOverlay)
            .shadow(color: shadowColor, radius: isHovered ? 16 : 8, x: 0, y: isHovered ? 6 : 2)
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .opacity(isDisabled ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.snappy) { isHovered = hovering }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed { withAnimation(.snappy) { isPressed = true } }
                }
                .onEnded { _ in
                    withAnimation(.snappy) { isPressed = false }
                }
        )
        .disabled(isDisabled || isLoading)
    }

    private var foregroundColor: Color {
        switch variant {
        case .primary: return .white
        case .secondary, .ghost: return isHovered ? .terracottaHover : .terracotta
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch variant {
        case .primary:
            ZStack { Color.terracotta; LinearGradient.buttonHighlight }
        case .secondary:
            Color.clear
        case .ghost:
            Color.terracotta.opacity(isHovered ? 0.08 : 0)
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        switch variant {
        case .primary: EmptyView()
        case .secondary:
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(isHovered ? Color.terracottaHover : Color.terracotta, lineWidth: 1.5)
        case .ghost: EmptyView()
        }
    }

    private var shadowColor: Color {
        guard !isDisabled else { return .clear }
        switch variant {
        case .primary: return isHovered ? Color.terracotta.opacity(0.35) : Color.black.opacity(0.08)
        case .secondary, .ghost: return .clear
        }
    }
}
