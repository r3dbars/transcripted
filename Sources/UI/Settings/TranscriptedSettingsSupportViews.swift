import SwiftUI

struct SupportActionCard: View {
    enum Tone {
        case primary
        case secondary
    }

    let symbolName: String
    let title: String
    let detail: String
    let buttonTitle: String
    let buttonSymbolName: String
    let tone: Tone
    let status: String?
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconForeground)
                    .frame(width: 34, height: 34)
                    .background(iconBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.primary)

                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            }

            Button(action: action) {
                Label(buttonTitle, systemImage: buttonSymbolName)
                    .font(.callout.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .foregroundStyle(buttonForeground)
            }
            .buttonStyle(SettingsHoverButtonStyle(
                tone: buttonInteractionTone,
                cornerRadius: 8,
                normalFill: buttonBackground,
                normalStroke: buttonStroke,
                hoverFill: buttonHoverBackground,
                pressedFill: buttonPressedBackground,
                hoverStroke: buttonHoverStroke
            ))
            .disabled(!isEnabled)

            if let status, !status.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(nsColor: .systemGreen))

                    Text(status)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(cardStroke, lineWidth: 1)
        )
    }

    private var iconForeground: Color {
        switch tone {
        case .primary:
            return Color(nsColor: .systemGreen)
        case .secondary:
            return Color.accentColor
        }
    }

    private var iconBackground: Color {
        switch tone {
        case .primary:
            return Color(nsColor: .systemGreen).opacity(0.16)
        case .secondary:
            return Color.accentColor.opacity(0.14)
        }
    }

    private var cardBackground: Color {
        switch tone {
        case .primary:
            return Color(nsColor: .controlBackgroundColor).opacity(0.9)
        case .secondary:
            return Color(nsColor: .controlBackgroundColor).opacity(0.72)
        }
    }

    private var cardStroke: Color {
        switch tone {
        case .primary:
            return Color(nsColor: .systemGreen).opacity(0.25)
        case .secondary:
            return Color.primary.opacity(0.08)
        }
    }

    private var buttonBackground: Color {
        switch tone {
        case .primary:
            return Color(nsColor: .systemGreen)
        case .secondary:
            return Color.secondary.opacity(0.16)
        }
    }

    private var buttonInteractionTone: SettingsInteractionTone {
        switch tone {
        case .primary:
            return .accent
        case .secondary:
            return .neutral
        }
    }

    private var buttonHoverBackground: Color {
        switch tone {
        case .primary:
            return Color(nsColor: .systemGreen).opacity(0.86)
        case .secondary:
            return SettingsInteractionPalette.hoverFill(for: .neutral)
        }
    }

    private var buttonPressedBackground: Color {
        switch tone {
        case .primary:
            return Color(nsColor: .systemGreen).opacity(0.76)
        case .secondary:
            return SettingsInteractionPalette.pressedFill(for: .neutral)
        }
    }

    private var buttonStroke: Color {
        switch tone {
        case .primary:
            return Color(nsColor: .systemGreen).opacity(0.24)
        case .secondary:
            return Color.primary.opacity(0.08)
        }
    }

    private var buttonHoverStroke: Color {
        switch tone {
        case .primary:
            return Color(nsColor: .systemGreen).opacity(0.34)
        case .secondary:
            return SettingsInteractionPalette.hoverStroke(for: .neutral)
        }
    }

    private var buttonForeground: Color {
        switch tone {
        case .primary:
            return .white
        case .secondary:
            return .primary
        }
    }
}

struct SupportPrivacyNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text("Never sent: transcript text, audio, names, emails, file paths, raw URLs, or meeting titles.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }
}
