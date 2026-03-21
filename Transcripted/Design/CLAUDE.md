# Transcripted Design System

## Color Tokens

**Warm Minimalism Palette** (Laws of UX inspired):

- `surfaceBackground` - Main background: warm off-white (hue 0.167, sat 0.10, bright 0.92)
- `surfaceEggshell` - Elevated areas and highlights (hue 0.153, sat 0.62, bright 0.89)
- `surfaceCard` - Card backgrounds, slightly brighter (hue 0.167, sat 0.08, bright 0.96)

**Dark Mode** (blue-tinted, not pure black):

- `surfaceDarkBase` - Deep blue-black base (hue 0.556, sat 0.50, bright 0.05)
- `surfaceDarkCard` - Elevated dark cards (hue 0.556, sat 0.50, bright 0.15)
- `surfaceDarkHover` - Hover state on dark surfaces (hue 0.556, sat 0.50, bright 0.25)

**Accents**:

- `accentBlue` - Primary interactive (hue 0.556, sat 0.50, bright 0.40)
- `accentBlueLight` - Hover states (hue 0.556, sat 0.35, bright 0.55)

**Text on Cream**:

- `textOnCream` - Primary text (hue 0.556, sat 0.50, bright 0.10)
- `textOnCreamSecondary` - Secondary text (hue 0.556, sat 0.30, bright 0.35)
- `textOnCreamMuted` - Muted/hint text (hue 0.167, sat 0.10, bright 0.52)

## Spacing

Use `Spacing` enum values:
- `Spacing.sm` - Small spacing (6-8pt)
- `Spacing.lg` - Large spacing (16-20pt)

Apply consistently in `HStack` and `VStack` spacing parameters.

## Typography

- `.buttonText` - Button font style
- Tracking: 0.3 for buttons
- System fonts with semantic weights

## Premium Components

**PremiumButton** (`PremiumComponents.swift`):

Three variants:
- `.primary` - Filled terracotta background
- `.secondary` - Outlined style
- `.ghost` - Text only

Features:
- Hover effects with symbol animations
- Loading state with progress indicator
- Disabled state handling
- Minimum width 120pt
- Rounded corners (Radius.md)

**When to use**:
- Primary actions (onboarding completion, CTA buttons)
- Secondary actions (cancel, back)
- Inline actions (ghost buttons in text)

## Usage Guidelines

1. Use `surfaceBackground` for main views
2. Use `surfaceCard` for grouped content
3. Use `accentBlue` for interactive elements
4. Apply `PremiumButton` for all primary actions
5. Match dark mode surfaces with `surfaceDarkBase` and `surfaceDarkCard`

All colors defined in `DesignTokens.swift` lines 39-80.
