import SwiftUI

// MARK: - Permission Card

@available(macOS 26.0, *)
struct PermissionCard: View {
    let icon: String
    let title: String
    let description: String
    let status: PermissionStatus
    let onGrant: () -> Void
    let onOpenSettings: () -> Void

    enum PermissionStatus {
        case notRequested, pending, granted, denied
    }

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.lg) {
            ZStack {
                Circle().fill(statusColor.opacity(0.12)).frame(width: 48, height: 48)
                Image(systemName: statusIcon).font(.system(size: 20, weight: .medium)).foregroundColor(statusColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: status == .pending)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headingSmall).foregroundColor(.charcoal)
                Text(description).font(.bodySmall).foregroundColor(.softCharcoal)
            }
            Spacer()
            actionButton
        }
        .padding(Spacing.ml)
        .background(Color.warmCream)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(statusColor.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(isHovered ? 0.08 : 0.04), radius: isHovered ? 12 : 6, x: 0, y: isHovered ? 4 : 2)
        .onHover { isHovered = $0 }
    }

    private var statusColor: Color {
        switch status {
        case .notRequested: return .terracotta
        case .pending: return .processingPurple
        case .granted: return .successGreen
        case .denied: return .errorCoral
        }
    }

    private var statusIcon: String {
        switch status {
        case .notRequested: return icon
        case .pending: return "hourglass"
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .notRequested:
            PremiumButton(title: "Grant", variant: .primary) { onGrant() }
        case .pending:
            ProgressView().scaleEffect(0.8).frame(width: 80)
        case .granted:
            HStack(spacing: Spacing.xs) {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                Text("Granted").font(.caption)
            }
            .foregroundColor(.successGreen)
            .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
            .background(Color.successGreen.opacity(0.12)).clipShape(Capsule())
        case .denied:
            PremiumButton(title: "Open Settings", icon: "gear", variant: .secondary) { onOpenSettings() }
        }
    }
}
