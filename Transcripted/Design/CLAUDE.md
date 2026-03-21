# Design System

Shared design tokens and premium components. 23 Swift files across root, Colors/, and Components/.

## File Index

### Root (10 files)

| File | Purpose |
|------|---------|
| `Spacing.swift` | 9 spacing values (xs 4pt through xxxl 64pt) |
| `Radius.swift` | 13 corner radius values (micro 1pt through full 999pt) + Laws of UX variants |
| `Typography.swift` | 13 Font extensions (displayLarge through tiny, Fraunces serif with system fallback) |
| `Animations.swift` | AnimationTiming constants + spring presets (snappy, smooth, bouncy, elegant) + pill timing |
| `Shadows.swift` | CardStyle shadow tuples, ShadowStyle enum, `.shadowStyle()` modifier |
| `Gradients.swift` | LinearGradient presets (warmGlow, centerWarmth, buttonHighlight, aiGradient) + RadialGradient.iconGlow |
| `Dimensions.swift` | SettingsDimensions, PillDimensions layout constants |
| `CardModifiers.swift` | `.lawsCard()` and `.premiumCard()` view modifiers for card styling |
| `ViewModifiers.swift` | Microinteraction modifiers: pressEffect, hoverScale, pulse, glowPulse, shake, slideIn, staggeredAppear + `.floatingTooltip()` |
| `Accessibility.swift` | AccessibilityTokens, accessibleAnimation modifier (respects reduceMotion) |

### Colors/ (6 files)

| File | Purpose |
|------|---------|
| `ColorHex.swift` | `Color.init(hex:)` supporting 3/6/8-digit RGB/ARGB formats |
| `BrandColors.swift` | Terracotta, cream, charcoal, semantic colors (success, recording, processing, warning, error) |
| `PanelColors.swift` | Dark panel theme (panelCharcoal/Elevated/Surface, panelText Primary/Secondary/Muted, recording coral, attention/error colors) |
| `SurfaceColors.swift` | Warm cream surfaces, dark mode surfaces (blue-tinted), accent blues, text-on-cream colors, status colors |
| `AuroraColors.swift` | Aurora recording indicator colors (auroraCoral, auroraTeal + light variants, systemAudioIndicator) |
| `HeatMapColors.swift` | 5-level heat map gradient (heatMapLevel0 through heatMapLevel4) + legacy aliases |

### Components/ (6 files)

| File | Purpose |
|------|---------|
| `PremiumButton.swift` | 3-variant button (primary/secondary/ghost), hover effects, loading state |
| `PremiumCard.swift` | Warm cream card container with hover lift animation |
| `BenefitCard.swift` | Icon circle with glow + title/description, hover bounce |
| `StepProgressIndicator.swift` | Capsule-based onboarding progress (28pt active / 10pt inactive) |
| `PermissionCard.swift` | 4-state permission status card for onboarding |
| `QuickTipRow.swift` | Small icon + text row for tips |
| `AnimatedIcon.swift` | SF Symbol icon with glow/pulse effects |

## Gotchas
- Dark mode is NOT system-integrated -- manually select dark colors per view
- Fraunces serif font may not be bundled -- display fonts fall back to system serif
- `lawsButton`/`lawsCard`/`lawsModal` radius values are separate from the xs-xxl scale
- PremiumButton hardcodes 14pt vertical padding (not a Spacing value)
- PremiumCard (warmCream bg) vs `.lawsCard()` modifier (panelCharcoalElevated bg) -- different aesthetics
