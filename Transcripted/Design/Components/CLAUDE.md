# Design Components

5 reusable premium UI components used across Onboarding, Settings, and FloatingPanel. All SwiftUI views.

## File Index

| File | Purpose |
|------|---------|
| `PremiumButton.swift` | 3-variant button (primary/secondary/ghost) with hover, press, loading states |
| `PremiumCard.swift` | Warm cream card container with hover lift animation |
| `BenefitCard.swift` | Dark card with icon circle + title/description row, used in onboarding welcome (macOS 26.0+) |
| `QuickTipRow.swift` | Small icon + text row for inline tips |
| `AnimatedIcon.swift` | SF Symbol icon with configurable glow and pulse effects |

## Component Specs

### PremiumButton
```swift
PremiumButton(title:, icon:, variant:, isLoading:, isDisabled:, action:)
```
**Variants (ButtonVariant enum):**
| Variant | Fill | Text | Border | Shadow |
|---------|------|------|--------|--------|
| `.primary` | terracotta + highlight gradient | white | none | 8-16px (hover) |
| `.secondary` | transparent | terracotta | terracotta 1.5pt | none |
| `.ghost` | transparent (0.08 hover) | coral | none | none |

- Min width: 120pt
- Padding: 14pt vertical, Spacing.lg (24pt) horizontal
- Corner radius: Radius.md (12pt)
- Press: scale 0.97, .snappy animation
- Hover: symbol .scale.up effect
- Loading: ProgressView replaces icon (0.7x scale)
- Spring hover: response 0.2, dampingFraction 0.8

### PremiumCard
```swift
PremiumCard(accentColor:, enableHover:, content:)
```
- Background: warmCream, radius Radius.lg (16pt)
- Border: accentColor.opacity(0.08 normal / 0.25 hover), lineWidth 1
- Shadow: black 0.05-0.1 opacity, radius 12-20, y offset 4-8
- Scale on hover: 1.02 (if enableHover), animation: .smooth

### BenefitCard
```swift
BenefitCard(icon:, iconColor:, title:, description:)
```
- Layout: 48x48 icon circle (iconColor 0.12 fill) + title (headingSmall) / description (bodySmall)
- Background: panelCharcoalElevated, radius Radius.md, panelCharcoalSurface border
- Used in: WelcomeStep.swift (3 cards)

### QuickTipRow
```swift
QuickTipRow(icon:, text:, iconColor:)
```
- Layout: icon (14pt) + text (bodySmall), horizontal
- Default iconColor: panelTextMuted

### AnimatedIcon
```swift
AnimatedIcon(systemName:, size:, color:, showGlow:, isPulsing:)
```
- Glow: circle behind icon, blur, color.opacity(0.15)
- Pulse: easeInOut repeating scale animation

## Relationships
- Used by: Onboarding/Steps/ (WelcomeStep), Settings/ (various sections), FloatingPanel/
- Design tokens from: Spacing.swift, Radius.swift, Typography.swift, Animations.swift
- Colors from: Colors/BrandColors.swift, Colors/PanelColors.swift

## Gotchas
- PremiumButton hardcodes 14pt vertical padding (not from Spacing enum)
- PremiumCard uses warmCream bg (Laws of UX light theme) — different from `.lawsCard()` modifier which uses panelCharcoalElevated (dark theme)
