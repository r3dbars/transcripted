import SwiftUI

/// The three button looks, for every paper surface (main window, onboarding,
/// sheets). Use them instead of `.borderedProminent`, tinted buttons or
/// hand-drawn fills:
///
///     Button("Record a meeting") { … }.buttonStyle(.transcriptedPrimary)
///     Button("Show in Finder") { … }.buttonStyle(.transcriptedSecondary)
///     Button("Not now") { … }.buttonStyle(.transcriptedQuiet)
///
/// Height follows `.controlSize`: mini 20, small 24, regular 28, large 40 (the
/// onboarding and setup nav). Primary is an ink fill with paper text, never a
/// hue. Destructive actions stay ink (secondary or quiet) behind their confirm.
struct TranscriptedButtonStyle: ButtonStyle {
    enum Kind: Sendable {
        /// Ink fill, paper text. One per view.
        case primary
        /// Hairline border, ink text.
        case secondary
        /// Text only, secondary ink.
        case quiet
    }

    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(kind: kind, configuration: configuration)
    }

    private struct StyledLabel: View {
        let kind: Kind
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @State private var isHovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.control, style: .continuous)
            configuration.label
                .font(font)
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, horizontalPadding)
                .frame(minHeight: height)
                .background(shape.fill(background))
                .overlay(shape.strokeBorder(border, lineWidth: 1))
                .contentShape(shape)
                .opacity(configuration.isPressed ? 0.78 : 1)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }

        private var isCompact: Bool { controlSize == .small || controlSize == .mini }

        private var height: CGFloat {
            switch controlSize {
            case .mini: return 20
            case .small: return 24
            case .large, .extraLarge: return DesignTokens.minimumHitTarget
            default: return 28
            }
        }

        private var horizontalPadding: CGFloat {
            switch kind {
            case .quiet: return isCompact ? 6 : 8
            case .primary, .secondary:
                if controlSize == .large || controlSize == .extraLarge { return 22 }
                return isCompact ? 10 : 12
            }
        }

        private var font: Font {
            let role: TextRole = isCompact ? .meta : .body
            switch kind {
            case .primary: return role.font(weight: .semibold)
            case .secondary: return role.font(weight: .medium)
            case .quiet: return role.font(weight: .regular)
            }
        }

        private var foreground: Color {
            switch kind {
            case .primary: return isEnabled ? DesignTokens.paper : DesignTokens.ink3
            case .secondary: return isEnabled ? DesignTokens.ink : DesignTokens.ink3
            case .quiet: return isEnabled ? (isHovering ? DesignTokens.ink : DesignTokens.ink2) : DesignTokens.ink3
            }
        }

        private var background: Color {
            switch kind {
            case .primary:
                guard isEnabled else { return DesignTokens.fillStrong }
                return isHovering ? DesignTokens.ink.opacity(0.88) : DesignTokens.ink
            case .secondary:
                return isHovering && isEnabled ? DesignTokens.fill : .clear
            case .quiet:
                return .clear
            }
        }

        private var border: Color {
            kind == .secondary ? DesignTokens.hairlineStrong : .clear
        }
    }
}

extension ButtonStyle where Self == TranscriptedButtonStyle {
    /// Ink fill, paper text: the one main action in a view.
    static var transcriptedPrimary: TranscriptedButtonStyle { TranscriptedButtonStyle(kind: .primary) }
    /// Hairline border, ink text.
    static var transcriptedSecondary: TranscriptedButtonStyle { TranscriptedButtonStyle(kind: .secondary) }
    /// Text only.
    static var transcriptedQuiet: TranscriptedButtonStyle { TranscriptedButtonStyle(kind: .quiet) }
}
