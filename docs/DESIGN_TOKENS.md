# Design tokens

The single source of truth for Transcripted's type, spacing, and corner-radius
scales. Every new view should draw from these steps instead of picking a raw
size. The values here are not aspirational — they are grounded in the sizes the
app already uses most, so adopting them is a snap-to-grid, not a redesign.

Scope note: this is the visual language (type, spacing, radii). Color tokens
already live per surface in `MenuTokens` (menubar popover, light + dark) and
`OverlayTokens` (floating overlay). Those stay where they are; this document
governs the cross-surface geometry that had drifted into ~21 ad-hoc font sizes,
12 corner radii, and ~26 padding values across the two main windows.

## Type scale — SF Pro, 6 steps

SF Pro is the system face, so `Font.system(...)` / `NSFont.systemFont(...)` is
"SF Pro throughout" with no bundled font. Six steps cover every real need.
Weights standardize to **regular / medium / semibold**; `.light` is reserved for
the one display use (the Home greeting). A monospaced variant is used only for
numeric readouts (timers, counts) that must not jitter.

| Token | Size / weight | Use | Grounded in |
|-------|---------------|-----|-------------|
| `caption2` | 10, regular (semibold for labels) | dense metadata, status dots' text | `.caption2`, `size:10`, NSFont 10 |
| `caption` | 11, regular (semibold for labels) | secondary detail lines, row subtitles | `.caption` (72 sites), `size:11` |
| `body` | 13, regular (medium for emphasis) | primary row text, body copy | `size:13` (11 sites), `.subheadline` |
| `emphasis` | 14, semibold | selected/active row titles, small headers | `size:14,.semibold` — the single most common numeric spec (13 sites) |
| `title` | 16, semibold | section titles, card headers | `size:15/16,.semibold`, NSFont 15.5 |
| `display` | 22, semibold (28, light for the Home greeting) | page-level hero text | `size:22,.semibold`; greeting 28 light |
| `mono` | caption2 / caption size, monospaced | elapsed timers, counts | existing monospaced 10–11 readouts |

Rounding rule when adopting: snap fractional and near-miss sizes to the nearest
step (10.5 → `caption2`, 11.5/12/12.5 → `body`, 15/15.5 → `title`). The only
intentional exception in the codebase is a single `Georgia` serif on Home; leave
deliberate one-offs that carry meaning, and comment them.

## Spacing grid — 4pt based, 7 steps

A strict 8pt grid would fight the two most-used values in the app (10 and 14),
so the grid is 4pt-based with 10 and 14 kept as first-class steps.

| Token | Value | Grounded in (spacing + padding call counts) |
|-------|-------|---------------------------------------------|
| `xxs` | 2 | fine nudges |
| `xs` | 4 | 26 spacing / 11 padding |
| `sm` | 6 | 20 spacing / 27 padding |
| `md` | 8 | 63 spacing / 17 padding — the default gap |
| `ml` | 10 | 35 spacing / 34 padding — kept as a step, too common to round away |
| `lg` | 12 | 49 spacing / 17 padding |
| `xl` | 16 | 8 spacing / 13 padding |
| `xxl` | 24 | page-section separation |
| `gutter` | 14 | kept as a step (21 spacing / 18 padding); matches `SettingsContentLayoutPolicy.topPadding` |

## Corner radii — 4 steps

Twelve distinct radii collapse to four. The two dominant values (8, 12) are kept
exactly so the existing token files stay source-compatible.

| Token | Value | Grounded in | Existing token |
|-------|-------|-------------|----------------|
| `sm` | 6 | small chips, inline controls | — |
| `md` | 8 | rows, cards, icon wells (42 sites) | `MenuTokens.cardCornerRadius` |
| `lg` | 12 | panels, sheets (25 sites) | `OverlayTokens.cornerRadius` |
| `xl` | 16 | large containers | — |

Snap rule: 7 → `md`; 10 → `md` or `lg` by container size; 14/18 → `xl`.

## Where the tokens live in code

- **Menubar (AppKit):** `Sources/UI/MenuBar/MenuTokens.swift` owns the menubar's
  colors and layout, and now its **type scale** (`MenuTokens.Font`). The menubar
  action rows and header read their fonts from there instead of raw
  `NSFont.systemFont(ofSize:)`. This is the reference adoption — the pattern to
  follow when the SwiftUI surfaces (Home, Settings) migrate onto tokens.
- **Overlay (AppKit):** `Sources/UI/Overlay/OverlayTokens.swift` — colors + layout.
- **SwiftUI surfaces (Home, Settings):** still hold ad-hoc sizes. Migrate them
  onto these steps incrementally, one view per PR, snapping to the nearest step.
  Do not convert every view at once — correctness over a big-bang refactor.

## Adoption checklist for a view

1. Replace each `.font(.system(size:weight:))` with the nearest type step.
2. Replace numeric `spacing:` / `.padding(n)` with the nearest spacing step.
3. Replace each `cornerRadius:` with the nearest of the four radii.
4. Keep any deliberate exception, and add a one-line comment saying why.
5. If a layout-policy test pins a constant (e.g.
   `SettingsContentLayoutPolicy.topPadding == 14`), keep the number equal.
