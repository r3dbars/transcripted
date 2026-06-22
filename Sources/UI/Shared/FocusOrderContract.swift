import Foundation

/// Single source of truth for the keyboard focus / Tab order of the app's
/// major controls.
///
/// The visual layout of a surface does not, by itself, prove anything about
/// the order the focus ring travels — AppKit infers a key-view loop only when
/// it can, and a UI sweep can silently reshuffle controls out of step with the
/// focus ring. This contract pins the intended order so it can be asserted
/// against the real views (see `FocusOrderContractTests`) and gives the AppKit
/// menu bar popover an explicit key-view loop instead of leaving Tab order to
/// chance.
///
/// Tokens are the same stable automation identifiers the controls already
/// expose, so the order is checked against the shipping views rather than a
/// parallel naming scheme that could drift on its own.
///
/// Scope: surfaces with more than one keyboard-reachable major control and a
/// meaningful Tab order live here. Single-control transient surfaces (the
/// dictation overlay's inline stop, the meeting overlay's live-view toggle)
/// are a reachability concern, not an ordering one, and keep their stable
/// identifiers without a separate order list.
enum FocusOrderContract {
    /// A keyboard-navigable surface whose major controls have a defined Tab order.
    enum Surface: String, CaseIterable {
        case menuBarPopover
        case settingsSidebar
    }

    // MARK: - Menu bar popover

    /// Primary action rows, top to bottom, as laid out in
    /// `MenuBarPrimaryActionsView` (Home leads, then the capture/paste actions).
    static let menuBarPrimaryOrder: [String] = [
        "transcripted.menubar.primary.home",
        "transcripted.menubar.primary.start-dictation",
        "transcripted.menubar.primary.start-meeting",
        "transcripted.menubar.primary.paste-last-dictation",
        "transcripted.menubar.primary.recent-meetings",
    ]

    /// Utility action rows, top to bottom, as laid out in
    /// `MenuBarUtilityActionsView`.
    static let menuBarUtilityOrder: [String] = [
        "transcripted.menubar.utility.connect-agent",
        "transcripted.menubar.utility.submit-feedback",
        "transcripted.menubar.utility.check-updates",
        "transcripted.menubar.utility.settings",
        "transcripted.menubar.utility.quit",
    ]

    /// Full popover Tab order: the primary section, then the utility section,
    /// matching the visual top-to-bottom layout in `MenuBarContentView`. The
    /// transient update-callout row, when shown, leads the loop but is not a
    /// stable member of the order.
    static var menuBarPopoverOrder: [String] {
        menuBarPrimaryOrder + menuBarUtilityOrder
    }

    // MARK: - Settings sidebar

    /// Primary sidebar navigation, top to bottom (Home, Dictations, Speakers,
    /// Agent), matching the ⌘1–⌘4 "Go" shortcuts and the sidebar's visual order.
    static let settingsSidebarOrder: [String] = [
        "transcripted.settings.sidebar.home",
        "transcripted.settings.sidebar.dictations",
        "transcripted.settings.sidebar.people",
        "transcripted.settings.sidebar.connect-agent",
    ]

    // MARK: - Lookup + validation

    /// The declared focus order for a surface.
    static func order(for surface: Surface) -> [String] {
        switch surface {
        case .menuBarPopover: return menuBarPopoverOrder
        case .settingsSidebar: return settingsSidebarOrder
        }
    }

    /// Identifiers that appear more than once in `order`. Must be empty for a
    /// well-formed Tab loop — a repeated control would trap or skip focus.
    static func duplicateIdentifiers(in order: [String]) -> [String] {
        var seen = Set<String>()
        var duplicates = [String]()
        for identifier in order where !seen.insert(identifier).inserted && !duplicates.contains(identifier) {
            duplicates.append(identifier)
        }
        return duplicates
    }

    /// True when every identifier in `required` is reachable within `order`, so
    /// no major action is stranded outside the keyboard loop.
    static func isReachable(_ required: [String], in order: [String]) -> Bool {
        let reachable = Set(order)
        return required.allSatisfy(reachable.contains)
    }
}
