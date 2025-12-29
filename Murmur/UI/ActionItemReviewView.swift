import SwiftUI

// MARK: - Action Item Review View

/// Main container for reviewing action items before adding to Reminders/Todoist
/// Appears in the floating panel notification area when items are pending review
@available(macOS 26.0, *)
struct ActionItemReviewView: View {
    @ObservedObject var taskManager: TranscriptionTaskManager
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    private let reviewAnimation = Animation.spring(response: 0.4, dampingFraction: 0.8)

    var body: some View {
        if let review = taskManager.pendingReview {
            VStack(spacing: 0) {
                // Header with title and select controls
                ActionItemReviewHeader(
                    selectedCount: review.selectedCount,
                    totalCount: review.totalCount,
                    onSelectAll: { taskManager.selectAllItems() },
                    onDeselectAll: { taskManager.deselectAllItems() }
                )

                Divider()
                    .background(Color.panelCharcoalSurface)

                // Scrollable item list
                ScrollView {
                    LazyVStack(spacing: Spacing.xs) {
                        ForEach(review.items) { item in
                            ActionItemRow(
                                item: item,
                                onToggle: { taskManager.toggleItemSelection(id: item.id) }
                            )
                        }
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                }
                .frame(maxHeight: 160)

                Divider()
                    .background(Color.panelCharcoalSurface)

                // Footer with Skip and Add buttons
                ActionItemReviewFooter(
                    selectedCount: review.selectedCount,
                    isSubmitting: taskManager.isSubmittingReview,
                    onSkip: {
                        Task { await taskManager.skipReview() }
                    },
                    onAdd: {
                        Task { await taskManager.submitSelectedItems() }
                    }
                )
            }
            .background(Color.panelCharcoalElevated)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                    .stroke(Color.glassBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: -10)),
                removal: .opacity.combined(with: .scale(scale: 0.95))
            ))
            .animation(reduceMotion ? .none : reviewAnimation, value: review.items.map(\.isSelected))
        }
    }
}

// MARK: - Header

/// Header with title, selected count, and select all/none controls
@available(macOS 26.0, *)
struct ActionItemReviewHeader: View {
    let selectedCount: Int
    let totalCount: Int
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void

    var body: some View {
        HStack {
            // Title and count
            VStack(alignment: .leading, spacing: 2) {
                Text("Action Items")
                    .font(.headingSmall)
                    .foregroundColor(.panelTextPrimary)

                Text("\(selectedCount) of \(totalCount) selected")
                    .font(.caption)
                    .foregroundColor(.panelTextSecondary)
            }

            Spacer()

            // Select all/none toggle
            HStack(spacing: Spacing.xs) {
                Button(action: onDeselectAll) {
                    Image(systemName: "circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.panelTextMuted)
                }
                .buttonStyle(.plain)
                .help("Deselect all")

                Button(action: onSelectAll) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.statusSuccessMuted)
                }
                .buttonStyle(.plain)
                .help("Select all")
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
    }
}

// MARK: - Item Row

/// Single action item row with checkbox, task, priority, and due date
@available(macOS 26.0, *)
struct ActionItemRow: View {
    let item: SelectableActionItem
    let onToggle: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                // Checkbox
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(item.isSelected ? .statusSuccessMuted : .panelTextMuted)
                    .animation(reduceMotion ? .none : .lawsTap, value: item.isSelected)

                // Content
                VStack(alignment: .leading, spacing: 4) {
                    // Task text
                    Text(item.item.task)
                        .font(.bodyMedium)
                        .foregroundColor(item.isSelected ? .panelTextPrimary : .panelTextSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    // Metadata row: owner badge, priority, due date
                    HStack(spacing: Spacing.sm) {
                        // Owner badge (if not "me")
                        if item.item.owner.lowercased() != "me" && item.item.owner.lowercased() != "you" {
                            OwnerBadge(name: item.item.owner)
                        }

                        // Priority badge
                        PriorityBadge(priority: item.item.priority)

                        // Due date (if present)
                        if let dueDate = item.item.dueDate, !dueDate.isEmpty {
                            Text(dueDate)
                                .font(.caption)
                                .foregroundColor(.panelTextMuted)
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: Radius.lawsButton, style: .continuous)
                    .fill(isHovered ? Color.panelCharcoalSurface : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(reduceMotion ? .none : .lawsCardHover, value: isHovered)
    }
}

// MARK: - Priority Badge

/// Colored badge showing task priority level
struct PriorityBadge: View {
    let priority: String

    private var color: Color {
        switch priority.lowercased() {
        case "high":
            return .statusErrorMuted
        case "medium":
            return .statusWarningMuted
        default:
            return .textOnCreamMuted
        }
    }

    private var icon: String {
        switch priority.lowercased() {
        case "high":
            return "exclamationmark.circle.fill"
        case "medium":
            return "minus.circle.fill"
        default:
            return "circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(priority)
                .font(.tiny)
        }
        .foregroundColor(color)
    }
}

// MARK: - Owner Badge

/// Badge showing task owner name
struct OwnerBadge: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.tiny)
            .foregroundColor(.accentBlueLight)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.accentBlue.opacity(0.2))
            )
    }
}

// MARK: - Footer

/// Footer with Skip and Add Selected buttons
@available(macOS 26.0, *)
struct ActionItemReviewFooter: View {
    let selectedCount: Int
    let isSubmitting: Bool
    let onSkip: () -> Void
    let onAdd: () -> Void

    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        HStack {
            // Skip button
            Button(action: onSkip) {
                Text("Skip")
                    .font(.bodyMedium)
                    .foregroundColor(.panelTextSecondary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.xs)
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)

            Spacer()

            // Add Selected button
            Button(action: onAdd) {
                HStack(spacing: Spacing.xs) {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.panelCharcoal)
                    } else {
                        Text("Add \(selectedCount)")
                            .font(.buttonText)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                    }
                }
                .foregroundColor(selectedCount > 0 ? .panelCharcoal : .panelTextMuted)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(
                    Capsule()
                        .fill(selectedCount > 0 ? Color.statusSuccessMuted : Color.panelCharcoalSurface)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting || selectedCount == 0)
            .animation(reduceMotion ? .none : .lawsStateChange, value: selectedCount)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
#Preview("Action Item Review") {
    // Create mock task manager with sample items
    let taskManager = TranscriptionTaskManager(failedTranscriptionManager: FailedTranscriptionManager())

    // Manually set up preview state
    let sampleItems = [
        ActionItem(
            task: "Send proposal to client by end of week",
            owner: "me",
            priority: "High",
            dueDate: "Friday",
            context: "Discussed in the sales sync meeting"
        ),
        ActionItem(
            task: "Follow up with Jack re: pricing questions",
            owner: "Jack",
            priority: "Medium",
            dueDate: "next week",
            context: "He needs to confirm the enterprise tier pricing"
        ),
        ActionItem(
            task: "Book travel for conference",
            owner: "me",
            priority: "Medium",
            dueDate: nil,
            context: "AWS re:Invent in Las Vegas"
        ),
        ActionItem(
            task: "Review competitor analysis document",
            owner: "me",
            priority: "Low",
            dueDate: nil,
            context: "Sarah shared in Slack"
        )
    ]

    let result = ExtractionResult(
        actionItems: sampleItems,
        meetingTitle: "Weekly Sales Sync",
        attendees: ["Justin", "Jack", "Sarah"],
        meetingSummary: "Discussed Q4 pipeline and upcoming conference"
    )

    taskManager.pendingReview = PendingActionItemsReview(from: result)

    return ZStack {
        Color.panelCharcoal.ignoresSafeArea()

        ActionItemReviewView(taskManager: taskManager)
            .frame(width: 300)
            .padding()
    }
    .frame(width: 340, height: 400)
}
#endif
