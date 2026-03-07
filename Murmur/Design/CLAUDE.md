# Design — CLAUDE.md

## Purpose
Visual design system: colors, spacing, typography, animation presets, and reusable premium UI components. Single source of truth for all visual constants.

## Files

| File | Responsibility |
|---|---|
| `DesignTokens.swift` | All colors, spacing, typography, animations, pill dimensions, microinteraction modifiers |
| `PremiumComponents.swift` | PremiumButton (primary/secondary/ghost), PremiumCard, BenefitCard, StepProgressIndicator, PermissionCard |

## Color Constants

**Panel theme (dark)**:
- `panelCharcoal` (#1A1A1A), `panelCharcoalElevated` (#242424), `panelCharcoalSurface` (#2E2E2E)
- `panelTextPrimary` (white), `panelTextSecondary` (#B0B0B0), `panelTextMuted` (#6B6B6B)

**Accents**:
- `recordingCoral` (#FF6B6B), `recordingCoralDeep`
- `attentionGreen` (#22C55E), `errorRed` (#EF4444)

**Aurora (synthwave)**:
- `auroraCoral` (#EC4899), `auroraCoralLight` (#F472B6) — mic side
- `auroraTeal` (#3B82F6), `auroraTealLight` (#60A5FA) — system audio side

**Onboarding (warm light)**:
- `cream`, `warmCream` (#FAF7F2), `terracotta` (#DA7756), `charcoal`, `softCharcoal`

**Chat**: `chatBubbleUser` (muted navy for "you" messages)

**Heat map**: 5-level gradient from `heatMapEmpty` to `heatMapMax`

## Spacing & Layout
- `Spacing`: `.xs` (4), `.sm` (8), `.md` (12), `.lg` (16), `.xl` (24), `.xxl` (32), `.xxxl` (64)
- `Radius`: `.xs` (4), `.sm` (6), `.md` (8), `.lg` (12), `.xl` (16), `.full` (999), `.lawsCard` (12)
- `PillDimensions`: idleWidth (40), idleHeight (20), idleExpandedWidth (120), recordingWidth (180), recordingHeight (40), trayWidth (280), trayMaxHeight (300)

## Animation Presets
- `.elegant` — 0.5s spring (response: 0.5, damping: 0.92) — buttery smooth, no bounce
- `.snappy` — 0.3s spring (response: 0.3, damping: 0.8)
- `.smooth` — 0.5s spring (response: 0.5, damping: 0.85)
- `.refined` — 0.45s spring (response: 0.45, damping: 0.95)
- `PillAnimationTiming`: morphDuration (0.175s), cooldownDuration (0.175s), contentFadeDuration (0.1s), celebrationDuration (2.0s), trayDuration (0.2s), toastDuration (5.0s), stateTransitionDuration (0.2s)
- `.pillMorph` — spring (response: 0.175, damping: 0.8)
- `.trayExpand` — spring (response: 0.2, damping: 0.85)

## Typography
Font extensions: `.displayLarge` (Fraunces 36pt), `.displayMedium` (28pt), `.heading` (20pt semibold), `.bodyLarge` (16pt), `.body` (14pt), `.buttonText` (15pt medium), `.caption` (12pt), `.tiny` (11pt), `.transcriptMono` (14pt monospace)

## Microinteraction Modifiers
`PressEffectModifier` (0.96x on press), `HoverScaleModifier` (1.02x on hover), `PulseModifier` (0.95↔1.05), `GlowPulseModifier` (pulsing shadow), `ShakeModifier` (5-cycle shake), `SlideInModifier` (edge slide + fade)

## Modification Recipes

| Task | Files to touch |
|---|---|
| Change color | `DesignTokens.swift` Color extensions — grep for old constant name across UI/ and Onboarding/ |
| Adjust pill sizes | `DesignTokens.swift` `PillDimensions` — affects FloatingPanel layout |
| Change animation speed | `DesignTokens.swift` `PillAnimationTiming` or Animation presets — test all pill states |
| Add reusable component | `PremiumComponents.swift` — follow PremiumButton pattern |
| Add microinteraction | `DesignTokens.swift` — add ViewModifier, follow PressEffectModifier pattern |

## Dependencies
**Imported by**: All `UI/` files, all `Onboarding/` files
**Imports**: SwiftUI only
