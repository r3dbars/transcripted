import SwiftUI

// MARK: - Accessibility Tokens

struct AccessibilityTokens {
    static let minimumContrastRatio: Double = 4.5
    static let reducedMotionDuration: Double = 0
    static let reducedMotionMultiplier: Double = 0
}

// MARK: - Accessibility-Aware Animation

extension View {
    func accessibleAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        self.modifier(AccessibleAnimationModifier(animation: animation, value: value))
    }
}

struct AccessibleAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .none : animation, value: value)
    }
}

extension Animation {
    @MainActor
    static func accessible(_ base: Animation) -> Animation {
        return base
    }
}

struct AccessibilityAwareView<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let content: (Bool) -> Content

    init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    var body: some View {
        content(reduceMotion)
    }
}
