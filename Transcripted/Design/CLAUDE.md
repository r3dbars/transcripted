# Design System

Shared design tokens and premium components. 21 Swift files across root, Colors/, and Components/.

## File Index

### Root (10 files)

| File | Purpose |
|------|---------|
| `Spacing.swift` | 9 spacing values (xs 4pt through xxxl 64pt) |
| `Radius.swift` | 13 corner radius values (micro 1pt through full 999pt) + Laws of UX variants |
| `Typography.swift` | 13 Font extensions (displayLarge through tiny, system sans-serif throughout) |
| `Animations.swift` | AnimationTiming constants + spring presets (snappy, smooth, bouncy, elegant) + pill timing |
| `Shadows.swift` | CardStyle shadow tuples, ShadowStyle enum, `.shadowStyle()` modifier |
| `Gradients.swift` | LinearGradient presets (warmGlow, centerWarmth, buttonHighlight, aiGradient) + RadialGradient.iconGlow |
| `Dimensions.swift` | SettingsDimensions, PillDimensions layout constants |
| `CardModifiers.swift` | `.lawsCard()` and `.premiumCard()` view modifiers for card styling |
| `ViewModifiers.swift` | Microinteraction modifiers: pressEffect, hoverScale, pulse, glowPulse, shake, slideIn, staggeredAppear + `.floatingTooltip()` |
| `Accessibility.swift` | AccessibilityTokens, accessibleAnimation modifier (respects reduceMotion) |

### Colors/ (6 files) — see Colors/CLAUDE.md

| File | Purpose |
|------|---------|
| `ColorHex.swift` | `Color.init(hex:)` supporting 3/6/8-digit RGB/ARGB formats |
| `BrandColors.swift` | Terracotta, cream, charcoal, semantic colors (success, recording, processing, warning, error) |
| `PanelColors.swift` | Dark panel theme (panelCharcoal/Elevated/Surface, panelText Primary/Secondary/Muted, recording coral, attention/error colors) |
| `SurfaceColors.swift` | Warm cream surfaces, dark mode surfaces (blue-tinted), accent blues, text-on-cream colors, status colors |
| `AuroraColors.swift` | Aurora recording indicator colors (auroraCoral, auroraTeal + light variants, systemAudioIndicator) |
| `HeatMapColors.swift` | 5-level heat map gradient (heatMapLevel0 through heatMapLevel4) + legacy aliases |

### Components/ (5 files) — see Components/CLAUDE.md

| File | Purpose |
|------|---------|
| `PremiumButton.swift` | 3-variant button (primary/secondary/ghost), hover effects, loading state |
| `PremiumCard.swift` | Warm cream card container with hover lift animation |
| `BenefitCard.swift` | Icon circle + title/description row, dark card style, used in onboarding welcome (macOS 26.0+) |
| `QuickTipRow.swift` | Small icon + text row for tips |
| `AnimatedIcon.swift` | SF Symbol icon with glow/pulse effects |

## Color Tokens (all `Color.staticVar`, defined as HSB or hex)

**Warm Cream Surfaces (Laws of UX) — SurfaceColors.swift:**
- `surfaceBackground` (hue 0.167, sat 0.10, bright 0.92), `surfaceEggshell` (0.153, 0.62, 0.89), `surfaceCard` (0.167, 0.08, 0.96)

**Dark Mode Surfaces (blue-tinted, not pure black) — SurfaceColors.swift:**
- `surfaceDarkBase` (0.556, 0.50, 0.05), `surfaceDarkCard` (0.556, 0.50, 0.15), `surfaceDarkHover` (0.556, 0.50, 0.25)

**Dark Panel Theme (most UI uses these) — PanelColors.swift:**
- `panelCharcoal` (#1A1A1A), `panelCharcoalElevated` (#242424), `panelCharcoalSurface` (#2E2E2E)
- `panelTextPrimary` (#FFFFFF), `panelTextSecondary` (#B0B0B0), `panelTextMuted` (#8A8A8A, WCAG AA on #1A1A1A)

**Accents — SurfaceColors.swift:**
- `accentBlue` (0.556, 0.50, 0.40), `accentBlueLight` (0.556, 0.35, 0.55)

**Text on Cream — SurfaceColors.swift:**
- `textOnCream` (0.556, 0.50, 0.10), `textOnCreamSecondary` (0.556, 0.30, 0.35), `textOnCreamMuted` (0.167, 0.10, 0.52)

**Status (muted for Laws of UX) — SurfaceColors.swift:**
- `statusSuccessMuted` (forest green), `statusWarningMuted` (warm amber), `statusErrorMuted` (soft red), `statusProcessingMuted` (blue)

**Brand — BrandColors.swift:**
- `terracotta` (#DA7756), `terracottaLight`/`terracottaHover`/`terracottaPressed`
- `cream` (#FAF7F2), `warmCream` (#F5F0E8), `charcoal` (#2D2D2D), `softCharcoal` (#5A5A5A)

**Semantic — BrandColors.swift:**
- `successGreen` (#4A9E6B), `recordingRed` (#D94F4F), `processingPurple` (#7B68A8), `warningAmber` (#D4A03D), `errorCoral` (#E05A5A)

**Aurora (recording visualizations) — AuroraColors.swift:**
- `recordingCoral` (#FF6B6B), `recordingCoralDeep` (#E85555)
- `auroraCoral` (#EC4899), `auroraCoralLight` (#F472B6), `auroraTeal` (#3B82F6), `auroraTealLight` (#60A5FA)

**Attention — PanelColors.swift:**
- `attentionGreen` (#22C55E), `attentionGreenDeep`/`Glow`, `errorRed` (#EF4444), `errorRedGlow`

**Heat Map (5 levels) — HeatMapColors.swift:**
- `heatMapLevel0` (#2A2A2A) through `heatMapLevel4` (recordingCoral)

## Spacing (`Spacing.` prefix — Spacing.swift)
| Token | Value | Token | Value |
|-------|-------|-------|-------|
| `xs` | 4pt | `ml` | 20pt |
| `sm` | 8pt | `lg` | 24pt |
| `ms` | 12pt | `xl` | 32pt |
| `md` | 16pt | `xxl` | 48pt |
| | | `xxxl` | 64pt |

## Radius (`Radius.` prefix — Radius.swift)
| Token | Value | Token | Value |
|-------|-------|-------|-------|
| `micro` | 1 | `xl` | 20 |
| `tiny` | 2 | `xxl` | 24 |
| `xs` | 4 | `full` | 999 |
| `sm` | 8 | `lawsButton` | 6 |
| `md` | 12 | `lawsCard` | 12 |
| `lg` | 16 | `lawsModal` | 20 |
| `pill` | 12 | `pillIdle` | 10 |

## Typography (`Font.` prefix — Typography.swift)
| Token | Spec | Token | Spec |
|-------|------|-------|------|
| `displayLarge` | 36pt bold (system sans-serif) | `bodyLarge` | 16pt regular |
| `displayMedium` | 28pt semibold (system sans-serif) | `bodyMedium` | 14pt regular |
| `displaySmall` | 22pt medium (system sans-serif) | `bodySmall` | 13pt regular |
| `headingLarge` | 20pt semibold | `buttonText` | 15pt semibold (tracking 0.3) |
| `headingMedium` | 18pt semibold | `caption` | 12pt medium |
| `headingSmall` | 16pt semibold | `tiny` | 11pt regular |
| `transcript` | 14pt monospaced | | |

## Animation Presets (`Animation.` prefix — Animations.swift)
**Spring:** `snappy` (0.3, 0.8), `smooth` (0.5, 0.85), `bouncy` (0.5, 0.6), `gentle` (0.7, 0.9), `elegant` (0.5, 0.92), `refined` (0.45, 0.95)
**Laws of UX:** `lawsBase` (easeInOut 0.3), `lawsTap` (0.15, 0.8), `lawsSuccess` (0.4, 0.5), `lawsStateChange` (0.35, 0.85), `lawsCardHover` (0.3, 0.8), `lawsPanelExpand` (0.25, 0.85), `lawsPanelCollapse` (0.15, 0.9)
**Pill:** `pillMorph` (0.3, 0.8), `trayExpand` (0.2, 0.85), `pillContentFade` (easeInOut 0.1)

**PillAnimationTiming (Animations.swift):** morphDuration 0.175s, cooldownDuration 0.175s, contentFade 0.1s, celebrationDuration 2.0s, trayDuration 0.2s, toastDuration 8.0s, stateTransitionDuration 0.2s, settleDelay 0.2s

## PremiumButton (Components/PremiumButton.swift)
```swift
PremiumButton(title:, icon:, variant:, isLoading:, isDisabled:, action:)
```
**Variants:** `.primary` (filled terracotta), `.secondary` (outlined), `.ghost` (text only)
- Min width: 120pt, padding: 14pt vertical / 24pt horizontal, corner radius: Radius.md (12pt)
- Hover: symbol .scale.up effect, shadow enhancement
- Press: scale 0.97, .snappy animation
- Loading: ProgressView replaces icon (0.7x scale)

## Other Premium Components (Components/)
- `PremiumCard(accentColor:, enableHover:, content:)` - Warm cream card with hover lift
- `BenefitCard(icon:, iconColor:, title:, description:)` - Dark card with icon circle + text row, used in onboarding (macOS 26.0+)
- `QuickTipRow(icon:, text:, iconColor:)` - Small icon + text row
- `AnimatedIcon(systemName:, size:, color:, showGlow:, isPulsing:)` - Icon with glow/pulse effects

## Accessibility Modifiers (ViewModifiers.swift — all respect `accessibilityReduceMotion`)
`.pressEffect()`, `.hoverScale()`, `.pulse()`, `.glowPulse()`, `.successCheck()`, `.shake()`, `.slideIn()`, `.staggeredAppear()`

## View Modifiers (CardModifiers.swift + ViewModifiers.swift)
- `.shadowStyle(_ style: ShadowStyle)` - Apply named shadow (Shadows.swift)
- `.lawsCard(isHovered:)` - Dark card styling (panelCharcoalElevated + border)
- `.premiumCard(isHovered:, glowColor:, cornerRadius:)` - Glass slab effect
- `.floatingTooltip("text")` - Hover tooltip (1s delay, works with non-activating panels)

## Gradients (Gradients.swift)
`LinearGradient.warmGlow`, `.centerWarmth`, `.buttonHighlight`, `.aiGradient`
`RadialGradient.iconGlow`

## Gotchas
- Dark mode is NOT system-integrated -- manually select dark colors per view (no @Environment(\.colorScheme) switching)
- Display fonts use system sans-serif (no external font dependencies)
- `lawsButton`/`lawsCard`/`lawsModal` radius values are separate from the xs-xxl scale
- PremiumButton hardcodes 14pt vertical padding (not a Spacing value)
- PremiumCard (warmCream bg) vs `.lawsCard()` modifier (panelCharcoalElevated bg) -- different aesthetics
- Color.init(hex:) supports 3/6/8-digit RGB/ARGB formats
