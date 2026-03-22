# Settings Components

6 reusable building blocks for the settings dashboard. All @MainActor SwiftUI views.

## File Index

| File | Purpose |
|------|---------|
| `SettingsSectionCard.swift` | Dark card container with uppercase gray header (icon + title) |
| `SettingsToggleRow.swift` | Toggle row with title, optional description, and CoralToggle |
| `SettingsTextField.swift` | Input field with focus border and optional Verify button |
| `SettingsPathRow.swift` | Folder picker row with "~" display shorthand and Choose button |
| `SettingsRadioGroup.swift` | Generic radio button group over any Hashable + CustomStringConvertible |
| `SettingsButtonStyles.swift` | 4 button styles: Primary, Secondary, Destructive, Icon |

## Component Specs

### SettingsSectionCard
```swift
SettingsSectionCard(icon:, title:, content:)
```
- Header: title.uppercased(), 11pt medium, panelTextMuted, tracking 0.8
- Background: panelCharcoalElevated
- Border: panelCharcoalSurface, 1pt stroke
- Radius: Radius.lawsCard (12pt)
- Padding: Spacing.md (16pt)
- Includes `onFocusChange` modifier for tracking focus state changes

### SettingsToggleRow + CoralToggle
```swift
SettingsToggleRow(title:, description:, isOn:)
```
- Layout: title + optional description (left) + CoralToggle (right)

**CoralToggle (custom, NOT SwiftUI Toggle):**
- Track: 44x24pt
- Knob: 20x20pt circle (white), shadow (black 0.15, radius 1)
- Colors: recordingCoral (ON) / panelCharcoalSurface (OFF)
- Knob offset: ±10pt (2pt internal padding)
- Animation: easeInOut(0.2)
- Accessibility: `.accessibilityAddTraits(.isButton)` manually added

### SettingsTextField
```swift
SettingsTextField(title:, placeholder:, text:, isSecure:, onVerify:)
```
- Background: panelCharcoalSurface
- Radius: Radius.lawsButton (6pt)
- Focus state: accentBlue stroke (1pt) when focused
- Optional Verify button: SettingsSecondaryButtonStyle

### SettingsPathRow
```swift
SettingsPathRow(title:, path:, defaultPath:, onChoose:)
```
- Displays path with home directory shortened to "~"
- "Choose..." button triggers folder picker
- Default path shown as hint when empty

### SettingsRadioGroup
```swift
SettingsRadioGroup<T: Hashable & CustomStringConvertible>(title:, options:, selection:, descriptions:)
```
- Generic over any Hashable + CustomStringConvertible type
- RadioButton subview: circle indicator (checked/unchecked) + label
- Optional descriptions per option

### Button Styles (SettingsButtonStyles.swift)
| Style | Fill | Text | Hover |
|-------|------|------|-------|
| `SettingsPrimaryButtonStyle` | recordingCoral | white | 0.8 opacity |
| `SettingsSecondaryButtonStyle` | panelCharcoalSurface | panelTextSecondary | text → panelTextPrimary |
| `SettingsDestructiveButtonStyle` | transparent | errorRed | full errorRed bg |
| `SettingsIconButtonStyle` | transparent | panelTextMuted | gray circle bg (28x28) |

## Design Tokens Used
- Colors: panelCharcoal/Elevated/Surface, panelText Primary/Secondary/Muted, recordingCoral, accentBlue, errorRed
- Spacing: xs (4pt), sm (8pt), ms (12pt), md (16pt)
- Radius: lawsButton (6pt), lawsCard (12pt)
- Animations: easeInOut(0.2) for toggle, .snappy for hover

## Relationships
- Used by: All Sections/ views (SettingsSectionCard wraps each section)
- Design tokens from: Design/Spacing.swift, Design/Radius.swift, Design/Colors/PanelColors.swift

## Gotchas
- CoralToggle is CUSTOM, not SwiftUI Toggle — does not get default Toggle accessibility traits (manually added)
- `SettingsSecondaryButtonStyle` uses `@State` inside `ButtonStyle` for hover tracking — unusual but works because ButtonStyle body is recreated per view
- SettingsIconButtonStyle is 28x28 fixed size — not configurable
- `onFocusChange` modifier in SettingsSectionCard provides focus tracking outside the standard SwiftUI focus system
