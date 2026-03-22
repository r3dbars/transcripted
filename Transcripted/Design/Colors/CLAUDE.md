# Design Colors

6 files defining all color tokens as static `Color` extensions. Organized by usage context. All colors use HSB or hex initialization.

## File Index

| File | Purpose |
|------|---------|
| `ColorHex.swift` | `Color.init(hex:)` extension — supports 3/6/8-digit RGB/ARGB formats |
| `BrandColors.swift` | Terracotta, cream, charcoal, semantic status colors |
| `PanelColors.swift` | Dark panel theme (charcoal surfaces, text hierarchy, recording indicators, attention/error) |
| `SurfaceColors.swift` | Warm cream surfaces, dark mode surfaces, accents, text-on-cream, muted status colors |
| `AuroraColors.swift` | Aurora recording visualization colors (coral, teal + light variants) |
| `HeatMapColors.swift` | 5-level heat map gradient for activity visualization |

## Complete Color Reference

### Brand Colors (BrandColors.swift)
| Token | Hex/Value | Usage |
|-------|-----------|-------|
| `terracotta` | #DA7756 | Primary brand, buttons, accents |
| `terracottaHover` | #C4654A | Button hover state |
| `terracottaPressed` | #B85A42 | Button press state |
| `terracottaLight` | lighter variant | Subtle brand tints |
| `cream` | #FAF7F2 | Light backgrounds |
| `warmCream` | #F5F0E8 | Card backgrounds (Laws of UX) |
| `charcoal` | #2D2D2D | Dark text, accents |
| `softCharcoal` | #5A5A5A | Secondary dark text |
| `mutedText` | #8A8A8A | Tertiary text |
| `successGreen` | #4A9E6B | Success states |
| `recordingRed` | #D94F4F | Recording indicator |
| `processingPurple` | #7B68A8 | Processing states |
| `warningAmber` | #D4A03D | Warning states |
| `errorCoral` | #E05A5A | Error states |

### Panel Colors (PanelColors.swift) — Most UI surfaces
| Token | Hex | Usage |
|-------|-----|-------|
| `panelCharcoal` | #1A1A1A | Main panel background |
| `panelCharcoalElevated` | #242424 | Cards, elevated surfaces |
| `panelCharcoalSurface` | #2E2E2E | Input fields, borders |
| `panelTextPrimary` | #FFFFFF (white) | Headings, primary text |
| `panelTextSecondary` | #B0B0B0 | Descriptions, secondary text |
| `panelTextMuted` | #8A8A8A | Captions, hints (WCAG AA on #1A1A1A) |
| `recordingCoral` | #FF6B6B | Recording state accent |
| `recordingCoralDeep` | #E85555 | Recording state shadow |
| `attentionGreen` | #22C55E | Success, confirmed states |
| `attentionGreenDeep` | #16A34A | Success shadow |
| `errorRed` | #EF4444 | Error, destructive actions |
| `premiumCoral` | #FF8F75 | Premium feature highlights |
| `softWhite` | #F5F5F7 | Subtle white accents |
| `glassBorder` | white 0.15 | Glass morphism borders |
| `glassBackground` | black 0.4 | Glass morphism fills |

### Surface Colors (SurfaceColors.swift) — Laws of UX theme
| Token | HSB | Usage |
|-------|-----|-------|
| `surfaceBackground` | H:0.167 S:0.10 B:0.92 | Main warm cream background |
| `surfaceEggshell` | H:0.153 S:0.62 B:0.89 | Accent surface |
| `surfaceCard` | H:0.167 S:0.08 B:0.96 | Card elevated surface |
| `surfaceDarkBase` | H:0.556 S:0.50 B:0.05 | Dark mode base |
| `surfaceDarkCard` | H:0.556 S:0.50 B:0.15 | Dark mode card |
| `surfaceDarkHover` | H:0.556 S:0.50 B:0.25 | Dark mode hover |
| `accentBlue` | H:0.556 S:0.50 B:0.40 | User mic color, links |
| `accentBlueLight` | H:0.556 S:0.35 B:0.55 | Light accent variant |
| `textOnCream` | H:0.556 S:0.50 B:0.10 | Primary text on cream |
| `textOnCreamSecondary` | H:0.556 S:0.30 B:0.35 | Secondary text on cream |
| `textOnCreamMuted` | H:0.167 S:0.10 B:0.52 | Muted text on cream |
| `statusSuccessMuted` | H:0.389 S:0.60 B:0.50 | Muted green |
| `statusWarningMuted` | H:0.111 S:0.65 B:0.55 | Muted amber |
| `statusErrorMuted` | H:0.000 S:0.60 B:0.55 | Muted red |
| `statusProcessingMuted` | (blue) | Muted processing blue |

### Aurora Colors (AuroraColors.swift) — Recording visualization
| Token | Hex | Usage |
|-------|-----|-------|
| `auroraCoral` | #EC4899 | Mic fog primary |
| `auroraCoralLight` | #F472B6 | Mic fog secondary |
| `auroraTeal` | #3B82F6 | System audio fog primary |
| `auroraTealLight` | #60A5FA | System audio fog secondary |
| `systemAudioIndicator` | #7B68A8 | System audio status icon |

### Heat Map Colors (HeatMapColors.swift) — Activity levels
| Token | Hex | Alias |
|-------|-----|-------|
| `heatMapLevel0` | #2A2A2A | Empty |
| `heatMapLevel1` | lighter | Light |
| `heatMapLevel2` | medium | Medium |
| `heatMapLevel3` | brighter | High |
| `heatMapLevel4` | recordingCoral | Max |

## Relationships
- Referenced by every UI file in the project
- Summary tables also in parent Design/CLAUDE.md
- `Color.init(hex:)` used by BrandColors and PanelColors

## Gotchas
- Dark mode is NOT system-integrated — colors are manually chosen per view, no `@Environment(\.colorScheme)` switching
- `panelTextMuted` at #8A8A8A meets WCAG AA on #1A1A1A but not AAA
- HSB colors in SurfaceColors are defined with `Color(hue:saturation:brightness:)`, not hex
- Heat map aliases (Empty, Light, etc.) map to the same Level0-Level4 colors
