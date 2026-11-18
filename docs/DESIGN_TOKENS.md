# Design tokens

The token definitions in source are authoritative, and there is now one
source: `Sources/UI/Shared/DesignTokens.swift` (colors with AppKit twins,
radii, the six `TextRole`s) plus the button styles in
`Sources/UI/Shared/DesignButtonStyles.swift`. How to use them:
`docs/ui-tokens.md`.

The surface names read from it:

- `LibraryTokens` (main window, onboarding, Writing tab) keeps its names:
  `accent` is `DesignTokens.live`, `ink`/`ink2`/`ink3`, `hairline`,
  `rowHover`/`raisedFill` (`fill`), `title` (display serif 28), `heading`,
  `rowTitle` (13 medium), `body`, `meta`, `small`, `label` (mono 10.5 with
  `labelTracking`), `radiusControl` (6), `radiusRaised` (12),
  `minimumHitTarget` (40). `LibrarySectionLabel` draws the mono label.
- `MenuTokens` (AppKit popover) maps its text, row and button colors to the
  shared ink and fills; filled buttons are the ink primary. `MenuTokens.Font`
  uses the shared roles (row titles body 13, details and trailing small 11,
  header status meta 12). Layout stays popover-specific: a 304 × 480 panel,
  `innerPadding` 10, `sectionSpacing` 7, action rows 42 and 40. When assigning
  a menu color to a `CALayer`, use `NSView.menuResolvedCGColor(_:)` and resolve
  it again when the view's effective appearance changes.
- `NotchIslandPalette` (always-black island) takes the shared capture green
  (`DesignTokens.NS.liveOnDark`), danger red and the meta text role. Its
  geometry and motion stay in `Sources/UI/Overlay/NotchIslandGeometry.swift`.
- The Writing card (`NextSentenceCardStyle`, WritingBridge) can't name
  UIShared, so it mirrors the island's values by hand; keep them in step.

There is no shared spacing scale yet. Reuse an existing role when it means the
same thing, and verify an intentional visual change in the app.
