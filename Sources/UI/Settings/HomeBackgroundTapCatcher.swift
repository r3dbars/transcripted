// HomeBackgroundTapCatcher.swift
// Click-away to close an open card on Home and Speakers. Its own file so the
// fast tests can host it.

import SwiftUI

// MARK: - Background tap catcher

/// Catches a tap on otherwise-empty space (the gaps around rows, day-group
/// padding, the space below the last row) so the shell can collapse an open
/// card, typically a `QuietMeetingExpansion`. Apply to the list container,
/// not individual rows.
///
/// The tap target sits behind the content, not on it. A tap gesture on the
/// container itself also competes for clicks on AppKit views inside it, such
/// as the Speakers "Who spoke?" footer buttons (borderless NSButtons in an
/// NSViewRepresentable), which a user saw answer only on their 1px edge.
/// Behind the content, it sees only clicks nothing in front of it took.
private struct HomeBackgroundTapCatcherModifier: ViewModifier {
    let onTap: () -> Void

    func body(content: Content) -> some View {
        content.background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
        }
    }
}

extension View {
    /// See `HomeBackgroundTapCatcherModifier`. Wire `onTap` to collapse the
    /// currently-open Home meeting expansion.
    func homeBackgroundTapCatcher(onTap: @escaping () -> Void) -> some View {
        modifier(HomeBackgroundTapCatcherModifier(onTap: onTap))
    }
}
