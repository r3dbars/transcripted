import SwiftUI

// Small pieces shared by the Writing tab's intro, setup and everyday views.
// Colors, type and radii come from `LibraryTokens`; the buttons match the
// first-run onboarding's (`PermissionsOnboardingView`).

/// The accent-filled primary action: Next, Continue, Set up writing, Turn on
/// writing.
struct WritingPrimaryButton: View {
    let title: String
    var isEnabled = true
    let automationIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 22)
                .frame(minHeight: LibraryTokens.minimumHitTarget)
                .background(
                    RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                        .fill(isEnabled ? LibraryTokens.accent : LibraryTokens.ink3)
                )
                .contentShape(RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier(automationIdentifier)
    }
}

/// The quiet text action: Back, Cancel.
struct WritingSecondaryButton: View {
    let title: String
    let automationIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink2)
                .padding(.horizontal, 8)
                .frame(minWidth: LibraryTokens.minimumHitTarget, minHeight: LibraryTokens.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(automationIdentifier)
    }
}

/// Page dots for the two intro pages.
struct WritingPageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...max(1, count), id: \.self) { page in
                Circle()
                    .fill(page == current ? LibraryTokens.accent : LibraryTokens.ink3.opacity(0.6))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Page \(current) of \(count)"))
    }
}

/// A small capsule label: `Both`, `Needed`, `Autocomplete`.
struct WritingBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(LibraryTokens.ink2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(LibraryTokens.raisedFill))
            .overlay(Capsule().stroke(LibraryTokens.raisedStroke, lineWidth: 1))
    }
}

/// A key cap: `Tab`, `~`, `Esc`.
struct WritingKeyCap: View {
    let key: String
    var isPressed = false

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(isPressed ? Color.white : Color.primary)
            .padding(.horizontal, 7)
            .frame(minWidth: 26, minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isPressed ? LibraryTokens.accent : LibraryTokens.raisedFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(isPressed ? LibraryTokens.accent : LibraryTokens.raisedStroke, lineWidth: 1)
            )
            .accessibilityLabel(Text(key == "~" ? "tilde key" : key))
    }
}

/// "Step 1 of 3" over the step's title.
struct WritingStepHeader: View {
    let step: Int
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(WritingSetupPresentation.stepLabel(step))
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink2)
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A selectable app chip for "Only apps I pick".
struct WritingAppChip: View {
    let title: String
    let isSelected: Bool
    let automationIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
                Text(title)
                    .font(LibraryTokens.body)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? LibraryTokens.accent : Color.primary)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(
                Capsule().fill(isSelected ? LibraryTokens.accent.opacity(0.12) : LibraryTokens.raisedFill)
            )
            .overlay(
                Capsule().stroke(isSelected ? LibraryTokens.accent.opacity(0.45) : LibraryTokens.raisedStroke, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isSelected ? "Picked" : "Not picked"))
        .accessibilityIdentifier(automationIdentifier)
    }
}

/// A radio-style choice row: title, optional detail and trailing tag, and a
/// disabled line under it when it can't be picked.
struct WritingChoiceRow: View {
    let title: String
    var detail: String?
    var tag: String?
    var disabledLine: String?
    let isSelected: Bool
    var isEnabled = true
    let automationIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? LibraryTokens.accent : LibraryTokens.ink3)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(LibraryTokens.rowTitle)
                        if let tag {
                            Text(tag)
                                .font(LibraryTokens.meta)
                                .foregroundStyle(LibraryTokens.ink2)
                        }
                    }
                    if let detail {
                        Text(detail)
                            .font(LibraryTokens.meta)
                            .foregroundStyle(LibraryTokens.ink2)
                    }
                    if let disabledLine {
                        Text(disabledLine)
                            .font(LibraryTokens.meta)
                            .foregroundStyle(LibraryTokens.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .frame(minHeight: LibraryTokens.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(automationIdentifier)
    }
}

/// Wraps chips onto as many lines as they need.
struct WritingFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let usedWidth = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? usedWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
