import AppKit

/// The popover's explicit Tab order. AppKit's inferred key-view loop is
/// unreliable for the manually laid-out flipped rows, so the content view
/// builds the loop here: update callout (when shown), then the primary
/// buttons, then the utility rows, matching
/// `FocusOrderContract.menuBarPopoverOrder`.
@MainActor
enum MenuBarKeyViewLoop {
    /// Rows in Tab order. A hidden update callout is left out.
    static func orderedRows(
        updateCallout: MenuBarActionRowView,
        primary: [MenuBarActionRowView],
        utility: [MenuBarActionRowView]
    ) -> [MenuBarActionRowView] {
        var chain: [MenuBarActionRowView] = []
        if !updateCallout.isHidden {
            chain.append(updateCallout)
        }
        chain.append(contentsOf: primary)
        chain.append(contentsOf: utility)
        return chain
    }

    /// Points each row's `nextKeyView` at the next one, the last back at the
    /// first, and returns the row that should take focus first.
    @discardableResult
    static func link(_ chain: [NSView]) -> NSView? {
        for (index, row) in chain.enumerated() {
            row.nextKeyView = index + 1 < chain.count ? chain[index + 1] : chain.first
        }
        return chain.first
    }
}
