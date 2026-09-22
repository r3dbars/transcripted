# Meeting language component visual verification — 2026-09-21

Result: six production-component renders inspected with `view_image`. The closed menu picker and labels rendered successfully through SwiftUI `ImageRenderer` at 2x scale. No text clipping, missing controls, unreadable guidance, or horizontal overflow was visible at the existing settings card width of 620 points.

| State | Light image | Dark image | Pixels |
| --- | --- | --- | --- |
| Whisper Turbo, Finnish selected | language-whisper-finnish-light.swiftui.png | language-whisper-finnish-dark.swiftui.png | 1320 × 170 |
| Parakeet V3, Finnish saved | language-parakeet-v3-saved-finnish-light.swiftui.png | language-parakeet-v3-saved-finnish-dark.swiftui.png | 1320 × 254 |
| Parakeet V2, Finnish saved | language-parakeet-v2-saved-finnish-light.swiftui.png | language-parakeet-v2-saved-finnish-dark.swiftui.png | 1320 × 254 |

The Whisper picker displays **Finnish**. Both Parakeet pickers display **Auto**, show **Finnish is saved for Whisper**, and display their distinct V3 automatic-language / V2 English-only guidance. The fixture uses 20-point outer padding, giving a 660-point-wide canvas.

## Provenance and boundaries

- Temporary harness: `/private/tmp/transcripted-language-snapshots.EunsPS/LanguageSnapshot.swift`.
- Directly compiled real sources: `MeetingLanguageSettingRow.swift`, `TranscriptedSettingsGeneralControls.swift` (including real `SettingsControlRow`, `GeneralInfo`, `GeneralInfoButton`, and `SettingsCard`), `TranscriptionLanguagePreferences.swift`, `TranscriptionModelPreferences.swift`, and `DictationOverlayPresentationPreferences.swift` (a compile dependency of other real controls).
- No imitation or replacement of the row or its native picker.
- A UUID-named `UserDefaults` suite was injected using `.defaultAppStorage`. Finnish was set only in that suite; a final assertion verified all renders left the stored Finnish value unchanged. The suite was removed on completion.
- The fixture's surrounding canvas is plain white/black for light/dark contrast inspection; it is not the app's complete window material, adjacent rows, or screen composition.
- No production app launch, activation, recording, playback, network access, or installed-app preference mutation. Native hosting windows were never ordered and reported `visible=false`, `key=false`.
- An initial never-ordered AppKit bitmap-caching approach produced empty layers. Those six invalid task-owned PNGs were removed after inspection. Only the six valid `.swiftui.png` renders remain here.
- This does **not** prove open-menu behavior, selecting a language with keyboard/mouse, info-popover interaction, model switching in a running application, or persistence across a real app relaunch. Those remain native interaction checks.

The isolated six-source compile passed. The first sandboxed compile failed because the installed SwiftUI macro server could not start its nested sandbox; recompiling the same source outside that sandbox succeeded. No app-source edits or broad builds/tests were performed in this verification lane.
