# Design tokens

The token definitions in source are authoritative. This page describes the
roles that exist today; it does not define a separate cross-surface scale.
There is no shared spacing-token API or automatic rounding rule.

## Main-window SwiftUI surfaces

`Sources/UI/Shared/LibraryTokens.swift` supplies the main-window pages,
including Meetings, Dictations, Speakers, Writing, Agent and Settings. The
AppKit menu bar popover uses `MenuTokens` instead. The overlays keep their
own drawing constants.

| `LibraryTokens` type role | Size / weight | Use |
|---|---|---|
| `title` | 28, semibold | Page titles |
| `rowTitle` | 13, medium | Row titles |
| `body` | 13, regular | Reading text and settings rows |
| `meta` | 12, regular | Durations, counts and secondary detail |
| `label` | 10.5, semibold | Whisper section labels, with `labelTracking` of 1.1 |

Layout tokens are `radiusControl` (6), `radiusRaised` (10) and
`minimumHitTarget` (40). `LibrarySectionLabel` applies the label font,
tracking and tertiary ink to an uppercase section label.

Color roles include `accent`, `attention`, `recording`, the Meetings,
Dictation and Writing stream colors, `ink2`, `ink3`, `hairline`, `rowHover`,
`raisedFill`, `raisedStroke`, `sidebarBackground` and `contentBackground`.
The accent, attention, stream and background colors resolve for the current
appearance; ink and translucent fills use the system primary color.

## AppKit menu bar popover

`Sources/UI/Shared/MenuTokens.swift` supplies the popover's colors, layout
and `MenuTokens.Font` roles. Its current Swift callers are
`MenuBarContentView`, `MenuBarHeaderView`, `MenuBarActionRowView` and
`MenuBarPanelController`; Settings' hotkey recorder does not use it.

| `MenuTokens.Font` role | Size / weight |
|---|---|
| `rowTitlePrimary` | 12.5, medium |
| `rowTitleUtility` | 12.5, regular |
| `rowDetail` | 10, regular |
| `rowTrailingPrimary` | 10.5, medium, monospaced digits |
| `rowTrailingUtility` | 10, medium, monospaced digits |
| `headerStatus` | 11.5, medium |
| `headerDetail` | 10, regular |

Layout includes a 304 × 480 panel, `innerPadding` of 10,
`sectionSpacing` of 7, `cardCornerRadius` of 8,
`minimumHitTargetSize` of 40, and action row heights of 42 and 40.
These are named surface constants, not aliases of a global spacing grid.

Menu colors resolve for light and dark appearance. When assigning one to a
`CALayer`, use `NSView.menuResolvedCGColor(_:)` and resolve it again when the
view's effective appearance changes.

## Notch island

The AppKit overlay owns its geometry and drawing in
`Sources/UI/Overlay/NotchIslandGeometry.swift` and
`Sources/UI/Overlay/NotchIslandView.swift` and its extensions. It does not
consume either of the token enums above.

## Changing a view

Reuse an existing role from the view's surface when it expresses the same
purpose. Check the source definition before choosing a value. Preserve
layout and accessibility contracts, and verify an intentional visual change
in the app; this inventory is not a request to resize existing controls.
