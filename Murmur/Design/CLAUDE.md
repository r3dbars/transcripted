# Design — CLAUDE.md

## Purpose
Visual design system: colors, spacing, typography, animation presets, and reusable premium UI components. Single source of truth for all visual constants.

## Key Files

| File | Responsibility |
|------|---------------|
| `DesignTokens.swift` | All colors, spacing, typography, animation presets, pill dimensions |
| `PremiumComponents.swift` | Reusable premium UI components (glassmorphic cards, etc.) |

## Design Tokens

**Panel theme** (dark charcoal):
- `panelCharcoal`, `panelCharcoalElevated` — backgrounds
- `panelTextPrimary`, `panelTextSecondary`, `panelTextMuted` — text hierarchy

**Accent colors**:
- `recordingCoral` (#FF6B6B) — recording state accent
- Onboarding: warm cream with terracotta accents

**Animation presets**:
- `.elegant` (0.5s ease) — standard transitions
- `.refined` — subtle state changes
- `.snappy` — quick interactions

**Pill dimensions**: `PillDimensions` struct with sizes per state (idle, recording, processing)

## Common Tasks

| Task | Files to touch | Watch out for |
|------|---------------|---------------|
| Change color scheme | `DesignTokens.swift` | Update the Color extensions, check all consumers |
| Adjust pill sizes | `DesignTokens.swift` (PillDimensions) | Affects FloatingPanel layout |
| Change animation speed | `DesignTokens.swift` (animation presets) | Test with all pill states |
| Add new component | `PremiumComponents.swift` | Follow existing glassmorphic patterns |

## Dependencies

**Imported by**: All UI/ files, Onboarding/ views
**Imports**: SwiftUI only
