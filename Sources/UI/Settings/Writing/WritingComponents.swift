import AppKit
import SwiftUI

// Small pieces shared by the Writing tab's intro, setup and everyday views.
// Colors, type and radii come from `LibraryTokens`; the primary button is the
// shared `TranscriptedButtonStyle`, like the first-run onboarding's.

/// The ink primary action: Continue, Turn on writing.
struct WritingPrimaryButton: View {
    let title: String
    var isEnabled = true
    let automationIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(.transcriptedPrimary)
        .controlSize(.large)
        .disabled(!isEnabled)
        .accessibilityIdentifier(automationIdentifier)
    }
}

/// The quiet text action: Back, Cancel, Not now.
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

/// Page dots for the two setup screens.
struct WritingPageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...max(1, count), id: \.self) { page in
                Circle()
                    .fill(page == current ? LibraryTokens.ink : LibraryTokens.ink3.opacity(0.6))
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
            .font(LibraryTokens.small.weight(.medium))
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
            .font(LibraryTokens.small.weight(.semibold))
            .foregroundStyle(isPressed ? DesignTokens.paper : LibraryTokens.ink)
            .padding(.horizontal, 7)
            .frame(minWidth: 26, minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                    .fill(isPressed ? LibraryTokens.ink : LibraryTokens.raisedFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                    .stroke(isPressed ? LibraryTokens.ink : LibraryTokens.raisedStroke, lineWidth: 1)
            )
            .accessibilityLabel(Text(key == "~" ? "tilde key" : key))
    }
}

/// A setup question ("What should Writing do?", "Which apps?"): the
/// heading role, so it sits between the page title and the rows.
struct WritingQuestionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(LibraryTokens.heading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One switch row in a `SettingsCard`: the title in the body role (13
/// medium) over its 12 pt line, never the other way round. Setup's two
/// features and the everyday Settings card share it.
struct WritingToggleRow: View {
    let title: String
    let line: String
    @Binding var isOn: Bool
    var isEnabled = true
    let automationIdentifier: String
    var showsDivider = true

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(LibraryTokens.rowTitle)
                Text(line)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!isEnabled)
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(line))
                .accessibilityIdentifier(automationIdentifier)
        }
        .opacity(isEnabled ? 1 : 0.6)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) {
            if showsDivider { Divider() }
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
            .foregroundStyle(LibraryTokens.ink)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(
                Capsule().fill(isSelected ? DesignTokens.fillStrong : LibraryTokens.raisedFill)
            )
            .overlay(
                Capsule().stroke(isSelected ? DesignTokens.hairlineStrong : LibraryTokens.raisedStroke, lineWidth: 1)
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
                    .foregroundStyle(isSelected ? LibraryTokens.ink : LibraryTokens.ink3)
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

/// Reports the window hosting the view, so the refresh timers and the demo
/// can idle while the Settings window is closed or covered. The window
/// stays alive when closed, so `onDisappear` alone isn't enough.
struct WritingWindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class ReportingView: NSView {
        var onWindow: (@MainActor (NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}

extension NSWindow {
    /// Open and at least partly on screen.
    var writingIsShowingContent: Bool {
        isVisible && occlusionState.contains(.visible)
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
