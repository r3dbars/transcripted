// HomeBackgroundTapCatcher.swift
// Click-away to close an open card on Home and Speakers. Its own file so the
// fast tests can host it.

import SwiftUI

// MARK: - Background tap catcher

/// Makes a container's full bounds hit-testable so a tap on otherwise-empty
/// space (the gaps around rows, day-group padding, the space below the last
/// row) can be caught by the shell — typically to collapse an open
/// `QuietMeetingExpansion`. Apply to the list container, not individual
/// rows: SwiftUI resolves gestures on the innermost view that recognizes
/// them first, so a row's own `onTapGesture` (open/toggle) or a button
/// inside the expansion still wins over this background catcher.
private struct HomeBackgroundTapCatcherModifier: ViewModifier {
    let onTap: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }
}

extension View {
    /// See `HomeBackgroundTapCatcherModifier`. Wire `onTap` to collapse the
    /// currently-open Home meeting expansion.
    func homeBackgroundTapCatcher(onTap: @escaping () -> Void) -> some View {
        modifier(HomeBackgroundTapCatcherModifier(onTap: onTap))
    }
}
