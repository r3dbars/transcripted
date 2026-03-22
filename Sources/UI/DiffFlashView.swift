// DiffFlashView.swift
// Read-only word-level diff view shown between review and confirm.
// Renders the user's edits to the AI draft with color-coded annotations.

import SwiftUI

struct DiffFlashView: View {
    let diffOps: [DiffOp]
    let editDescription: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.vertical, showsIndicators: false) {
                DiffFlowLayout(spacing: 4) {
                    ForEach(Array(diffOps.enumerated()), id: \.offset) { _, op in
                        diffWordView(op)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Edit description
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.system(size: 10))
                    .foregroundColor(OverlayTokens.accentGreen)
                Text(editDescription)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(OverlayTokens.accentGreen)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, OverlayTokens.contentPadding)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func diffWordView(_ op: DiffOp) -> some View {
        switch op {
        case .equal(let word):
            Text(word)
                .font(.system(size: 13))
                .foregroundColor(OverlayTokens.textPrimary)

        case .delete(let word):
            Text(word)
                .font(.system(size: 13))
                .foregroundColor(OverlayTokens.diffDeleteText)
                .strikethrough(true, color: OverlayTokens.diffDeleteText)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(OverlayTokens.diffDeleteBg)
                .cornerRadius(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(OverlayTokens.diffDeleteBorder, lineWidth: 1)
                )

        case .insert(let word):
            Text(word)
                .font(.system(size: 13))
                .foregroundColor(OverlayTokens.diffInsertText)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(OverlayTokens.diffInsertBg)
                .cornerRadius(3)

        case .replace(let old, let new):
            HStack(spacing: 2) {
                Text(old)
                    .font(.system(size: 13))
                    .foregroundColor(OverlayTokens.diffDeleteText)
                    .strikethrough(true, color: OverlayTokens.diffDeleteText)
                Text(new)
                    .font(.system(size: 13))
                    .foregroundColor(OverlayTokens.diffReplaceText)
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(OverlayTokens.diffReplaceBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            )
        }
    }
}

/// Flow layout that wraps word views across lines. Uses the Layout protocol (macOS 13+).
struct DiffFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
