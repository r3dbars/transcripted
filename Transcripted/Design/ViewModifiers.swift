import SwiftUI

// MARK: - Microinteraction View Modifiers

struct PressEffectModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let isPressed: Bool
    let scale: CGFloat

    init(isPressed: Bool, scale: CGFloat = 0.96) {
        self.isPressed = isPressed
        self.scale = scale
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? scale : 1.0)
            .animation(reduceMotion ? .none : .lawsTap, value: isPressed)
    }
}

struct HoverScaleModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var isHovered = false
    let scale: CGFloat

    init(scale: CGFloat = 1.02) {
        self.scale = scale
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? scale : 1.0)
            .animation(reduceMotion ? .none : .lawsCardHover, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

@available(macOS 14.0, *)
struct PulseModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let isActive: Bool
    let minScale: CGFloat
    let maxScale: CGFloat
    @State private var isPulsing = false

    init(isActive: Bool, minScale: CGFloat = 0.95, maxScale: CGFloat = 1.05) {
        self.isActive = isActive
        self.minScale = minScale
        self.maxScale = maxScale
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(isActive && !reduceMotion ? (isPulsing ? maxScale : minScale) : 1.0)
            .animation(
                reduceMotion ? .none : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onChange(of: isActive) { _, newValue in
                isPulsing = newValue
            }
            .onAppear {
                if isActive { isPulsing = true }
            }
    }
}

@available(macOS 14.0, *)
struct GlowPulseModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let isActive: Bool
    let color: Color
    @State private var glowOpacity: Double = 0.3

    func body(content: Content) -> some View {
        content
            .shadow(color: isActive ? color.opacity(glowOpacity) : .clear, radius: isActive ? 12 : 0)
            .animation(
                reduceMotion ? .none : .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                value: glowOpacity
            )
            .onChange(of: isActive) { _, newValue in
                glowOpacity = newValue ? 0.6 : 0.3
            }
            .onAppear {
                if isActive && !reduceMotion { glowOpacity = 0.6 }
            }
    }
}

struct SuccessCheckModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isVisible ? 1.0 : 0.5)
            .opacity(isVisible ? 1.0 : 0.0)
            .animation(reduceMotion ? .none : .lawsSuccess, value: isVisible)
    }
}

@available(macOS 14.0, *)
struct ShakeModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let isShaking: Bool
    @State private var shakeOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: shakeOffset)
            .onChange(of: isShaking) { _, newValue in
                if newValue && !reduceMotion {
                    withAnimation(.linear(duration: 0.05).repeatCount(5, autoreverses: true)) {
                        shakeOffset = 5
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        shakeOffset = 0
                    }
                }
            }
    }
}

struct SlideInModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let isVisible: Bool
    let edge: Edge

    var offset: CGFloat {
        switch edge {
        case .leading: return -50
        case .trailing: return 50
        case .top: return -50
        case .bottom: return 50
        }
    }

    func body(content: Content) -> some View {
        content
            .offset(
                x: edge == .leading || edge == .trailing ? (isVisible ? 0 : offset) : 0,
                y: edge == .top || edge == .bottom ? (isVisible ? 0 : offset) : 0
            )
            .opacity(isVisible ? 1.0 : 0.0)
            .animation(reduceMotion ? .none : .lawsStateChange, value: isVisible)
    }
}

@available(macOS 14.0, *)
struct StaggeredAppearModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let delay: Double
    let offset: CGFloat
    @State private var isVisible = false

    init(delay: Double, offset: CGFloat = 10) {
        self.delay = delay
        self.offset = offset
    }

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : offset)
            .onAppear {
                guard !reduceMotion else {
                    isVisible = true
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        isVisible = true
                    }
                }
            }
    }
}

// MARK: - View Extension for All Modifiers

extension View {
    func pressEffect(isPressed: Bool, scale: CGFloat = 0.96) -> some View {
        modifier(PressEffectModifier(isPressed: isPressed, scale: scale))
    }

    func hoverScale(_ scale: CGFloat = 1.02) -> some View {
        modifier(HoverScaleModifier(scale: scale))
    }

    @available(macOS 14.0, *)
    func pulse(when isActive: Bool, minScale: CGFloat = 0.95, maxScale: CGFloat = 1.05) -> some View {
        modifier(PulseModifier(isActive: isActive, minScale: minScale, maxScale: maxScale))
    }

    @available(macOS 14.0, *)
    func glowPulse(when isActive: Bool, color: Color = .recordingCoral) -> some View {
        modifier(GlowPulseModifier(isActive: isActive, color: color))
    }

    func successCheck(isVisible: Bool) -> some View {
        modifier(SuccessCheckModifier(isVisible: isVisible))
    }

    @available(macOS 14.0, *)
    func shake(when isShaking: Bool) -> some View {
        modifier(ShakeModifier(isShaking: isShaking))
    }

    func slideIn(isVisible: Bool, from edge: Edge = .bottom) -> some View {
        modifier(SlideInModifier(isVisible: isVisible, edge: edge))
    }

    @available(macOS 14.0, *)
    func staggeredAppear(delay: Double, offset: CGFloat = 10) -> some View {
        modifier(StaggeredAppearModifier(delay: delay, offset: offset))
    }
}
