import SwiftUI

/// Step 4: Explains where the app lives, the hotkey, and where transcripts are saved
@available(macOS 26.0, *)
struct HowItWorksStep: View {
    @State private var showContent = false

    var body: some View {
        VStack(spacing: Spacing.md) {
            Spacer()

            VStack(spacing: Spacing.xs) {
                Text("Here's How It Works")
                    .font(.displayMedium)
                    .foregroundColor(.panelTextPrimary)

                Text("Transcripted runs invisibly until you need it")
                    .font(.bodyLarge)
                    .foregroundColor(.panelTextSecondary)
            }

            VStack(spacing: Spacing.sm) {
                InfoCard(
                    icon: "dock.rectangle",
                    title: "Lives in your menu bar",
                    description: "Look for the small pill above your dock. It's always there, ready to record."
                )

                HotkeyCard()

                InfoCard(
                    icon: "doc.text",
                    title: "Transcripts saved to:",
                    description: "~/Documents/Transcripted/\nMarkdown files you can open anywhere."
                )
            }
            .padding(.horizontal, Spacing.lg)

            Spacer()
        }
        .padding(.horizontal, Spacing.xl)
        .opacity(showContent ? 1 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.3)) {
                showContent = true
            }
        }
    }
}

// MARK: - Info Card

@available(macOS 26.0, *)
private struct InfoCard: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.recordingCoral.opacity(0.12))
                    .frame(width: 44, height: 44)

                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.recordingCoral)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bodyMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.panelTextPrimary)

                Text(description)
                    .font(.bodySmall)
                    .foregroundColor(.panelTextSecondary)
                    .lineLimit(3)
            }

            Spacer()
        }
        .padding(Spacing.md)
        .background(Color.panelCharcoalElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.panelCharcoalSurface, lineWidth: 1)
        )
    }
}

// MARK: - Hotkey Card (with styled key caps)

@available(macOS 26.0, *)
private struct HotkeyCard: View {
    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.recordingCoral.opacity(0.12))
                    .frame(width: 44, height: 44)

                Image(systemName: "command")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.recordingCoral)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Press to record")
                    .font(.bodyMedium)
                    .fontWeight(.semibold)
                    .foregroundColor(.panelTextPrimary)

                HStack(spacing: Spacing.xs) {
                    KeyCap("\u{2318}")
                    KeyCap("\u{21E7}")
                    KeyCap("R")
                }

                Text("Works from any app, anytime.")
                    .font(.bodySmall)
                    .foregroundColor(.panelTextSecondary)
            }

            Spacer()
        }
        .padding(Spacing.md)
        .background(Color.panelCharcoalElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.panelCharcoalSurface, lineWidth: 1)
        )
    }
}

// MARK: - Key Cap

@available(macOS 26.0, *)
private struct KeyCap: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundColor(.panelTextPrimary)
            .frame(width: 28, height: 28)
            .background(Color.panelCharcoalSurface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(Color.panelTextMuted.opacity(0.3), lineWidth: 0.5)
            )
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
#Preview {
    HowItWorksStep()
        .frame(width: 720, height: 580)
        .background(Color.panelCharcoal)
}
#endif
