import SwiftUI

// MARK: - Design Tokens
/// Premium design system for Transcripted onboarding
/// Aesthetic: "Recording Studio Library" - warm, refined, professional

// MARK: - Color Palette (Anthropic-Inspired)

extension Color {
    /// Initialize from hex string
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Laws of UX Warm Minimalism Color Palette
// Design inspiration: lawsofux.com - warm cream, curved cells, clean minimalism

extension Color {
    // MARK: - Primary Surfaces (Warm Cream - Laws of UX style)

    /// Main background - warm off-white base
    static let surfaceBackground = Color(hue: 0.167, saturation: 0.10, brightness: 0.92)

    /// Warm eggshell accent - for elevated areas and highlights
    static let surfaceEggshell = Color(hue: 0.153, saturation: 0.62, brightness: 0.89)

    /// Card background - slightly brighter for elevated cells
    static let surfaceCard = Color(hue: 0.167, saturation: 0.08, brightness: 0.96)

    // MARK: - Dark Mode Surfaces (Blue-tinted, not pure black)

    /// Deep blue-black base for dark mode
    static let surfaceDarkBase = Color(hue: 0.556, saturation: 0.50, brightness: 0.05)

    /// Elevated dark surface for cards
    static let surfaceDarkCard = Color(hue: 0.556, saturation: 0.50, brightness: 0.15)

    /// Hover state on dark surfaces
    static let surfaceDarkHover = Color(hue: 0.556, saturation: 0.50, brightness: 0.25)

    // MARK: - Accent Colors (Laws of UX Blue)

    /// Primary interactive accent - muted blue
    static let accentBlue = Color(hue: 0.556, saturation: 0.50, brightness: 0.40)

    /// Secondary accent - lighter for hover states
    static let accentBlueLight = Color(hue: 0.556, saturation: 0.35, brightness: 0.55)

    // MARK: - Text on Cream (Laws of UX style)

    /// Primary text on cream - almost black with blue tint
    static let textOnCream = Color(hue: 0.556, saturation: 0.50, brightness: 0.10)

    /// Secondary text on cream - muted blue
    static let textOnCreamSecondary = Color(hue: 0.556, saturation: 0.30, brightness: 0.35)

    /// Muted/hint text on cream
    static let textOnCreamMuted = Color(hue: 0.167, saturation: 0.10, brightness: 0.52)

    // MARK: - Status Colors (Muted to match Laws of UX aesthetic)

    /// Success - muted forest green
    static let statusSuccessMuted = Color(hue: 0.389, saturation: 0.60, brightness: 0.50)

    /// Warning - warm amber
    static let statusWarningMuted = Color(hue: 0.111, saturation: 0.65, brightness: 0.55)

    /// Error - soft red
    static let statusErrorMuted = Color(hue: 0.000, saturation: 0.60, brightness: 0.55)

    /// Processing - blue pulse
    static let statusProcessingMuted = Color(hue: 0.556, saturation: 0.50, brightness: 0.50)
}

// MARK: - Brand Colors (Legacy - still available)

extension Color {
    /// Primary accent - warm terracotta orange (Anthropic-inspired)
    static let terracotta = Color(hex: "#DA7756")

    /// Primary background - warm cream
    static let cream = Color(hex: "#FAF7F2")

    /// Card/elevated background - slightly darker cream
    static let warmCream = Color(hex: "#F5F0E8")

    /// Primary text - soft charcoal
    static let charcoal = Color(hex: "#2D2D2D")

    /// Secondary text
    static let softCharcoal = Color(hex: "#5A5A5A")

    /// Muted text / placeholders
    static let mutedText = Color(hex: "#8A8A8A")

    // MARK: - Semantic Colors

    /// Success state - muted forest green
    static let successGreen = Color(hex: "#4A9E6B")

    /// Recording state - warm red
    static let recordingRed = Color(hex: "#D94F4F")

    /// Processing/AI state - soft purple
    static let processingPurple = Color(hex: "#7B68A8")

    /// Warning state - amber
    static let warningAmber = Color(hex: "#D4A03D")

    /// Error state - coral red
    static let errorCoral = Color(hex: "#E05A5A")

    // MARK: - Accent Variations

    /// Terracotta with reduced opacity for backgrounds
    static let terracottaLight = Color(hex: "#DA7756").opacity(0.12)

    /// Terracotta for hover states
    static let terracottaHover = Color(hex: "#C4654A")

    /// Terracotta for pressed states
    static let terracottaPressed = Color(hex: "#B85A42")

    // MARK: - Dark Panel Theme Colors

    /// Dark panel background - primary charcoal
    static let panelCharcoal = Color(hex: "#1A1A1A")

    /// Dark panel background - elevated layer
    static let panelCharcoalElevated = Color(hex: "#242424")

    /// Dark panel background - surface layer
    static let panelCharcoalSurface = Color(hex: "#2E2E2E")

    /// High contrast text on dark backgrounds
    static let panelTextPrimary = Color(hex: "#FFFFFF")

    /// Secondary text on dark backgrounds
    static let panelTextSecondary = Color(hex: "#B0B0B0")

    /// Muted text on dark backgrounds
    static let panelTextMuted = Color(hex: "#6B6B6B")

    /// Vibrant recording accent - coral red
    static let recordingCoral = Color(hex: "#FF6B6B")

    /// Recording accent - deeper for pressed states
    static let recordingCoralDeep = Color(hex: "#E85555")

    // MARK: - Attention/Notification Colors

    /// Vibrant attention green - for notifications and reminders
    static let attentionGreen = Color(hex: "#22C55E")

    /// Deeper green for pressed/active states
    static let attentionGreenDeep = Color(hex: "#16A34A")

    /// Attention green with glow opacity
    static let attentionGreenGlow = Color(hex: "#22C55E").opacity(0.5)

    /// Error red - for destructive actions and validation errors
    static let errorRed = Color(hex: "#EF4444")

    /// Error red with glow opacity
    static let errorRedGlow = Color(hex: "#EF4444").opacity(0.5)

    // MARK: - Premium UI Colors

    /// Premium Coral - sophisticated accent
    static let premiumCoral = Color(hex: "#FF8F75")

    /// Soft White - for high contrast elements on dark glass
    static let softWhite = Color(hex: "#F5F5F7")

    /// Glass Border - subtle white for glass edges
    static let glassBorder = Color.white.opacity(0.15)

    /// Glass Background - ultra thin material equivalent
    static let glassBackground = Color.black.opacity(0.4)

    // MARK: - Aurora Recording Indicator Colors

    /// Aurora mic color - hot pink for microphone audio (synthwave)
    static let auroraCoral = Color(hex: "#EC4899")

    /// Aurora system color - electric blue for system audio (synthwave)
    static let auroraTeal = Color(hex: "#3B82F6")

    /// Aurora mic secondary - lighter pink for gradients
    static let auroraCoralLight = Color(hex: "#F472B6")

    /// Aurora system secondary - lighter blue for gradients
    static let auroraTealLight = Color(hex: "#60A5FA")
}

// MARK: - Gradients

extension LinearGradient {
    /// Warm glow gradient for backgrounds
    static let warmGlow = LinearGradient(
        colors: [Color.terracotta.opacity(0.08), Color.cream],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Subtle radial warmth from center
    static let centerWarmth = LinearGradient(
        colors: [Color.terracotta.opacity(0.05), Color.clear],
        startPoint: .center,
        endPoint: .bottom
    )

    /// Button highlight gradient
    static let buttonHighlight = LinearGradient(
        colors: [Color.white.opacity(0.15), Color.clear],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Processing/AI gradient
    static let aiGradient = LinearGradient(
        colors: [Color.processingPurple, Color.terracotta],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension RadialGradient {
    /// Warm glow effect behind icons
    static let iconGlow = RadialGradient(
        colors: [Color.terracotta.opacity(0.3), Color.clear],
        center: .center,
        startRadius: 0,
        endRadius: 60
    )
}

// MARK: - Spacing Scale

struct Spacing {
    /// 4pt - Extra small
    static let xs: CGFloat = 4
    /// 8pt - Small
    static let sm: CGFloat = 8
    /// 12pt - Medium-small
    static let ms: CGFloat = 12
    /// 16pt - Medium
    static let md: CGFloat = 16
    /// 20pt - Medium-large
    static let ml: CGFloat = 20
    /// 24pt - Large
    static let lg: CGFloat = 24
    /// 32pt - Extra large
    static let xl: CGFloat = 32
    /// 48pt - 2X large
    static let xxl: CGFloat = 48
    /// 64pt - 3X large
    static let xxxl: CGFloat = 64
}

// MARK: - Corner Radius Scale

struct Radius {
    /// 4pt - Subtle rounding
    static let xs: CGFloat = 4
    /// 8pt - Small components
    static let sm: CGFloat = 8
    /// 12pt - Medium components
    static let md: CGFloat = 12
    /// 16pt - Large components / cards
    static let lg: CGFloat = 16
    /// 20pt - Extra large
    static let xl: CGFloat = 20
    /// 24pt - 2X large / containers
    static let xxl: CGFloat = 24
    /// Full circle
    static let full: CGFloat = 999

    // MARK: - Laws of UX Curved Cells

    /// Button/input radius (0.4rem equivalent)
    static let lawsButton: CGFloat = 6

    /// Card/panel radius (0.8rem equivalent - lawsofux.com style)
    static let lawsCard: CGFloat = 12

    /// Modal/large container radius
    static let lawsModal: CGFloat = 20
}

// MARK: - Laws of UX Card Styling

struct CardStyle {
    /// Subtle shadow for cards at rest (Laws of UX style)
    static let shadowSubtle = (
        color: Color.black.opacity(0.10),
        radius: CGFloat(2),
        x: CGFloat(0),
        y: CGFloat(1)
    )

    /// Standard card shadow
    static let shadowCard = (
        color: Color.black.opacity(0.15),
        radius: CGFloat(8),
        x: CGFloat(0),
        y: CGFloat(4)
    )

    /// Hover shadow with enhanced depth
    static let shadowHover = (
        color: Color.black.opacity(0.20),
        radius: CGFloat(12),
        x: CGFloat(0),
        y: CGFloat(6)
    )

    /// Card hover scale effect (Laws of UX: 1.02 scale)
    static let hoverScale: CGFloat = 1.02

    /// Card border color
    static let borderColor = Color.accentBlue.opacity(0.15)

    /// Card border width
    static let borderWidth: CGFloat = 1
}

// MARK: - Laws of UX Card View Modifier

extension View {
    /// Apply minimal card styling — dark container with subtle border, no hover effects
    func lawsCard(isHovered: Bool = false) -> some View {
        self
            .background(Color.panelCharcoalElevated)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                    .stroke(Color.panelCharcoalSurface, lineWidth: 1)
            )
    }
}

// MARK: - Shadow Styles

struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    /// Subtle shadow for cards at rest
    static let subtle = ShadowStyle(
        color: Color.black.opacity(0.04),
        radius: 8,
        x: 0,
        y: 2
    )

    /// Medium shadow for elevated elements
    static let medium = ShadowStyle(
        color: Color.black.opacity(0.08),
        radius: 16,
        x: 0,
        y: 4
    )

    /// Elevated shadow for focused/hover states
    static let elevated = ShadowStyle(
        color: Color.black.opacity(0.12),
        radius: 24,
        x: 0,
        y: 8
    )

    /// Glow shadow using terracotta for buttons
    static let buttonGlow = ShadowStyle(
        color: Color.terracotta.opacity(0.3),
        radius: 16,
        x: 0,
        y: 4
    )

    /// Success glow
    static let successGlow = ShadowStyle(
        color: Color.successGreen.opacity(0.3),
        radius: 12,
        x: 0,
        y: 2
    )

    /// Recording coral glow - for active recording states
    static let recordingGlow = ShadowStyle(
        color: Color.recordingCoral.opacity(0.5),
        radius: 12,
        x: 0,
        y: 0
    )

    /// Aurora mic glow - coral bloom effect
    static let auroraMicGlow = ShadowStyle(
        color: Color.auroraCoral.opacity(0.6),
        radius: 16,
        x: 0,
        y: 0
    )

    /// Aurora system glow - teal bloom effect
    static let auroraSystemGlow = ShadowStyle(
        color: Color.auroraTeal.opacity(0.6),
        radius: 16,
        x: 0,
        y: 0
    )

    /// Subtle recording glow - for tucked state
    static let recordingGlowSubtle = ShadowStyle(
        color: Color.recordingCoral.opacity(0.3),
        radius: 8,
        x: 0,
        y: 0
    )

    /// Idle hint glow - subtle white for discoverability
    static let idleHint = ShadowStyle(
        color: Color.white.opacity(0.15),
        radius: 4,
        x: 0,
        y: 0
    )
}

// MARK: - Shadow View Modifier

extension View {
    func shadowStyle(_ style: ShadowStyle) -> some View {
        self.shadow(
            color: style.color,
            radius: style.radius,
            x: style.x,
            y: style.y
        )
    }
}

// MARK: - Typography

extension Font {
    // MARK: - Display Fonts (Fraunces serif - for headers)
    // Note: Requires Fraunces font files to be added to the project
    // Fallback to system serif if custom font not available

    /// Large display - "Welcome to Transcripted" (36pt)
    static let displayLarge: Font = {
        if let _ = NSFont(name: "Fraunces-Bold", size: 36) {
            return .custom("Fraunces-Bold", size: 36)
        }
        return .system(size: 36, weight: .bold, design: .serif)
    }()

    /// Medium display - Step titles (28pt)
    static let displayMedium: Font = {
        if let _ = NSFont(name: "Fraunces-SemiBold", size: 28) {
            return .custom("Fraunces-SemiBold", size: 28)
        }
        return .system(size: 28, weight: .semibold, design: .serif)
    }()

    /// Small display - Subtitles (22pt)
    static let displaySmall: Font = {
        if let _ = NSFont(name: "Fraunces-Medium", size: 22) {
            return .custom("Fraunces-Medium", size: 22)
        }
        return .system(size: 22, weight: .medium, design: .serif)
    }()

    // MARK: - Heading Fonts (System)

    /// Large heading (20pt, semibold)
    static let headingLarge = Font.system(size: 20, weight: .semibold)

    /// Medium heading (18pt, semibold)
    static let headingMedium = Font.system(size: 18, weight: .semibold)

    /// Small heading (16pt, semibold)
    static let headingSmall = Font.system(size: 16, weight: .semibold)

    // MARK: - Body Fonts

    /// Large body text (16pt)
    static let bodyLarge = Font.system(size: 16, weight: .regular)

    /// Medium body text (14pt)
    static let bodyMedium = Font.system(size: 14, weight: .regular)

    /// Small body text (13pt)
    static let bodySmall = Font.system(size: 13, weight: .regular)

    // MARK: - UI Fonts

    /// Button text (15pt, semibold with tracking)
    static let buttonText = Font.system(size: 15, weight: .semibold)

    /// Caption text (12pt, medium)
    static let caption = Font.system(size: 12, weight: .medium)

    /// Tiny text (11pt)
    static let tiny = Font.system(size: 11, weight: .regular)

    /// Monospace for transcripts (14pt)
    static let transcript = Font.system(size: 14, weight: .regular, design: .monospaced)
}

// MARK: - Animation Timing

struct AnimationTiming {
    /// Quick micro-interaction (0.15s)
    static let quick: Double = 0.15

    /// Standard interaction (0.25s)
    static let standard: Double = 0.25

    /// Smooth transition (0.35s)
    static let smooth: Double = 0.35

    /// Elaborate animation (0.5s)
    static let elaborate: Double = 0.5

    /// Long animation (0.8s)
    static let long: Double = 0.8
}

// MARK: - Spring Presets

extension Animation {
    /// Snappy spring for quick interactions
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.8)

    /// Smooth spring for transitions
    static let smooth = Animation.spring(response: 0.5, dampingFraction: 0.85)

    /// Bouncy spring for playful effects
    static let bouncy = Animation.spring(response: 0.5, dampingFraction: 0.6)

    /// Gentle spring for subtle movements
    static let gentle = Animation.spring(response: 0.7, dampingFraction: 0.9)

    /// Elegant spring for buttery smooth panel transitions - not bouncy
    static let elegant = Animation.spring(response: 0.5, dampingFraction: 0.92)

    /// Refined spring for subtle, polished movements
    static let refined = Animation.spring(response: 0.45, dampingFraction: 0.95)

    // MARK: - Laws of UX Animation Presets (0.3s base timing)

    /// Base Laws of UX timing (0.3s with cubic-bezier)
    static let lawsBase = Animation.easeInOut(duration: 0.3)

    /// Tap/press feedback (quick)
    static let lawsTap = Animation.spring(response: 0.15, dampingFraction: 0.8)

    /// Success animation (celebratory)
    static let lawsSuccess = Animation.spring(response: 0.4, dampingFraction: 0.5)

    /// State change animation
    static let lawsStateChange = Animation.spring(response: 0.35, dampingFraction: 0.85)

    /// Card hover effect
    static let lawsCardHover = Animation.spring(response: 0.3, dampingFraction: 0.8)

    /// Panel expand/collapse
    static let lawsPanelExpand = Animation.spring(response: 0.25, dampingFraction: 0.85)

    /// Panel collapse (faster)
    static let lawsPanelCollapse = Animation.spring(response: 0.15, dampingFraction: 0.9)
}

// MARK: - Accessibility Tokens (UX: Accessibility is not optional)

struct AccessibilityTokens {
    /// Minimum contrast ratio for WCAG AA compliance
    static let minimumContrastRatio: Double = 4.5

    /// Animation duration when reduce motion is enabled (instant)
    static let reducedMotionDuration: Double = 0

    /// Animation multiplier when reduce motion is enabled
    static let reducedMotionMultiplier: Double = 0
}

// MARK: - Accessibility-Aware Animation View Modifier

// Note: Use AccessibleAnimationModifier<V> instead - it properly handles generics

/// Helper function for reduce-motion-aware animations
extension View {
    /// Applies animation only when reduce motion is disabled
    func accessibleAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        self.modifier(AccessibleAnimationModifier(animation: animation, value: value))
    }
}

/// Simpler view modifier that correctly handles the Equatable constraint
struct AccessibleAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .none : animation, value: value)
    }
}

// MARK: - Accessibility-Aware Animation Presets

extension Animation {
    /// Get animation that respects reduce motion setting
    @MainActor
    static func accessible(_ base: Animation) -> Animation {
        // Note: This is a static helper - actual reduce motion checking
        // should be done at the View level using @Environment
        return base
    }
}

// MARK: - Accessibility Helper View

/// A wrapper view that provides easy access to reduce motion state
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

// MARK: - Microinteraction View Modifiers (Doherty Threshold: <400ms feels instant)

/// Press effect: scales down slightly when pressed
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

/// Hover scale effect: subtle scale up on hover (Laws of UX card style)
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

/// Pulse animation for attention-grabbing elements (recording indicator)
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
                if isActive {
                    isPulsing = true
                }
            }
    }
}

/// Glow pulse for recording state (outer glow that pulses)
@available(macOS 14.0, *)
struct GlowPulseModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let isActive: Bool
    let color: Color

    @State private var glowOpacity: Double = 0.3

    func body(content: Content) -> some View {
        content
            .shadow(
                color: isActive ? color.opacity(glowOpacity) : .clear,
                radius: isActive ? 12 : 0
            )
            .animation(
                reduceMotion ? .none : .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                value: glowOpacity
            )
            .onChange(of: isActive) { _, newValue in
                glowOpacity = newValue ? 0.6 : 0.3
            }
            .onAppear {
                if isActive && !reduceMotion {
                    glowOpacity = 0.6
                }
            }
    }
}

/// Success checkmark animation
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

/// Shake animation for errors
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

/// Slide in from edge animation
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

// MARK: - View Extension for Microinteractions

extension View {
    /// Apply press effect (scale down when pressed)
    func pressEffect(isPressed: Bool, scale: CGFloat = 0.96) -> some View {
        modifier(PressEffectModifier(isPressed: isPressed, scale: scale))
    }

    /// Apply hover scale effect (Laws of UX card style)
    func hoverScale(_ scale: CGFloat = 1.02) -> some View {
        modifier(HoverScaleModifier(scale: scale))
    }

    /// Apply pulse animation for attention
    @available(macOS 14.0, *)
    func pulse(when isActive: Bool, minScale: CGFloat = 0.95, maxScale: CGFloat = 1.05) -> some View {
        modifier(PulseModifier(isActive: isActive, minScale: minScale, maxScale: maxScale))
    }

    /// Apply glow pulse effect
    @available(macOS 14.0, *)
    func glowPulse(when isActive: Bool, color: Color = .recordingCoral) -> some View {
        modifier(GlowPulseModifier(isActive: isActive, color: color))
    }

    /// Apply success check animation
    func successCheck(isVisible: Bool) -> some View {
        modifier(SuccessCheckModifier(isVisible: isVisible))
    }

    /// Apply shake animation for errors
    @available(macOS 14.0, *)
    func shake(when isShaking: Bool) -> some View {
        modifier(ShakeModifier(isShaking: isShaking))
    }

    /// Apply slide in animation
    func slideIn(isVisible: Bool, from edge: Edge = .bottom) -> some View {
        modifier(SlideInModifier(isVisible: isVisible, edge: edge))
    }
}

// MARK: - Pill Dimensions (Dynamic Island-style floating pill)

struct PillDimensions {
    /// Idle state: minimal capsule centered above dock
    static let idleWidth: CGFloat = 40
    static let idleHeight: CGFloat = 20

    /// Idle expanded state: hover to reveal Record/Files buttons
    static let idleExpandedWidth: CGFloat = 120
    static let idleExpandedHeight: CGFloat = 28

    /// Recording/Processing state: expanded with controls
    static let recordingWidth: CGFloat = 180
    static let recordingHeight: CGFloat = 40

    /// Review tray: expands upward for action item review
    static let trayWidth: CGFloat = 280
    static let trayMaxHeight: CGFloat = 300

    /// Padding above dock
    static let dockPadding: CGFloat = 8

    /// Default dock height if detection fails
    static let defaultDockHeight: CGFloat = 70
}

// MARK: - Pill Animation Timing (Quick & Responsive - 150-200ms target)

struct PillAnimationTiming {
    /// Primary morph duration - quick, snappy transitions (175ms)
    static let morphDuration: Double = 0.175

    /// Transition cooldown - must match morphDuration to prevent jank
    static let cooldownDuration: Double = 0.175

    /// Content fade duration during transitions
    static let contentFade: Double = 0.1

    /// Celebration display duration before auto-clear
    static let celebrationDuration: Double = 2.0

    /// Tray expand/collapse duration
    static let trayDuration: Double = 0.2

    /// Toast notification display duration
    static let toastDuration: Double = 5.0

    /// State transition duration - slightly longer for smooth cross-fade between pill states
    static let stateTransitionDuration: Double = 0.2

    /// Settle delay - time before idle view collapses after appearing
    static let settleDelay: Double = 0.2
}

// MARK: - Pill Animation Presets (Dynamic Island-style morphing)

extension Animation {
    /// Primary pill morph animation (idle ↔ recording)
    /// PHASE 4: Uses unified timing from PillAnimationTiming
    static let pillMorph = Animation.spring(response: PillAnimationTiming.morphDuration, dampingFraction: 0.8)

    /// Tray expand/collapse animation
    static let trayExpand = Animation.spring(response: PillAnimationTiming.trayDuration, dampingFraction: 0.85)

    /// Content fade during transitions
    static let pillContentFade = Animation.easeInOut(duration: PillAnimationTiming.contentFade)
}

// MARK: - Additional Radius Tokens

extension Radius {
    /// Pill capsule radius (fully rounded ends)
    static let pill: CGFloat = 12

    /// Pill idle state radius (smaller, more capsule-like)
    static let pillIdle: CGFloat = 10
}

// MARK: - Design Tokens Namespace

enum DesignTokens {
    static let spacing = Spacing.self
    static let radius = Radius.self
    static let shadow = ShadowStyle.self
    static let animation = AnimationTiming.self
    static let accessibility = AccessibilityTokens.self
    static let pill = PillDimensions.self
    static let settings = SettingsDimensions.self
}

// MARK: - Settings Window Dimensions

struct SettingsDimensions {
    /// Settings window width
    static let windowWidth: CGFloat = 800

    /// Settings window height
    static let windowHeight: CGFloat = 600

    /// Sidebar width
    static let sidebarWidth: CGFloat = 180

    /// Content area width (window - sidebar - divider)
    static let contentWidth: CGFloat = 619

    /// Stats card height
    static let statsCardHeight: CGFloat = 120

    /// Stats card minimum width
    static let statsCardMinWidth: CGFloat = 140

    /// Heat map cell size
    static let heatMapCellSize: CGFloat = 24

    /// Heat map cell spacing
    static let heatMapCellSpacing: CGFloat = 4
}

// MARK: - Heat Map Colors (5-Step Gradient)

extension Color {
    /// Heat map level 0 - empty cell (slightly elevated from background)
    static let heatMapLevel0 = Color(hex: "#2A2A2A")

    /// Heat map level 1 - faint warmth (1-2 recordings)
    static let heatMapLevel1 = Color(hex: "#4A2F2F")

    /// Heat map level 2 - warming (3-4 recordings)
    static let heatMapLevel2 = Color(hex: "#7A3D3D")

    /// Heat map level 3 - engaged (5-6 recordings)
    static let heatMapLevel3 = Color(hex: "#AA4545")

    /// Heat map level 4 - maximum intensity (7+ recordings)
    static let heatMapLevel4 = Color.recordingCoral

    // Legacy aliases for compatibility
    static let heatMapEmpty = heatMapLevel0
    static let heatMapLight = heatMapLevel1
    static let heatMapMedium = heatMapLevel2
    static let heatMapHigh = heatMapLevel3
    static let heatMapMax = heatMapLevel4
}

// MARK: - Premium Card System ("Night Studio" Aesthetic)

/// Premium card styling tokens for glass slab effect
struct PremiumCardStyle {
    /// Gradient top color - warmer charcoal
    static let gradientTop = Color(hex: "#292929")

    /// Gradient bottom color - slightly darker
    static let gradientBottom = Color(hex: "#232323")

    /// Inner highlight opacity (top edge light reflection)
    static let highlightOpacity: Double = 0.06

    /// Border opacity at top edge
    static let borderOpacityTop: Double = 0.08

    /// Border opacity at bottom edge
    static let borderOpacityBottom: Double = 0.02

    /// Hover glow opacity
    static let hoverGlowOpacity: Double = 0.15

    /// Hover glow blur radius
    static let hoverGlowRadius: CGFloat = 20

    /// Card shadow at rest
    static let shadowRest = ShadowStyle(
        color: Color.black.opacity(0.3),
        radius: 8,
        x: 0,
        y: 4
    )

    /// Card shadow on hover
    static let shadowHover = ShadowStyle(
        color: Color.black.opacity(0.4),
        radius: 12,
        x: 0,
        y: 6
    )
}

// MARK: - Premium Card View Modifier

/// Minimal card modifier — flat dark container with subtle border
@available(macOS 14.0, *)
struct PremiumCardModifier: ViewModifier {
    let isHovered: Bool
    let glowColor: Color
    let cornerRadius: CGFloat

    init(
        isHovered: Bool,
        glowColor: Color = .recordingCoral,
        cornerRadius: CGFloat = Radius.lawsCard
    ) {
        self.isHovered = isHovered
        self.glowColor = glowColor
        self.cornerRadius = cornerRadius
    }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.panelCharcoalElevated)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.panelCharcoalSurface, lineWidth: 1)
            }
    }
}

// MARK: - Premium Card View Extension

@available(macOS 14.0, *)
extension View {
    /// Apply premium "glass slab" card styling with depth, highlights, and hover glow
    func premiumCard(
        isHovered: Bool,
        glowColor: Color = .recordingCoral,
        cornerRadius: CGFloat = Radius.lawsCard
    ) -> some View {
        modifier(PremiumCardModifier(
            isHovered: isHovered,
            glowColor: glowColor,
            cornerRadius: cornerRadius
        ))
    }
}

// MARK: - Staggered Animation Modifier

/// Applies staggered appear animation for page transitions
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

@available(macOS 14.0, *)
extension View {
    /// Apply staggered appear animation (for page transitions)
    func staggeredAppear(delay: Double, offset: CGFloat = 10) -> some View {
        modifier(StaggeredAppearModifier(delay: delay, offset: offset))
    }
}
