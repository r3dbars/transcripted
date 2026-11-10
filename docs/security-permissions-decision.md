# Screen Recording disclosure decision (DOCS-3)

Status: **Unselected — owner review required.** This worksheet proposes wording
for `SECURITY.md`; it does not change that policy or select a privacy promise.
The source review uses main `8a38235eef00816a79daa1324387a21ef880204d`.

The current policy says Transcripted never requests full Screen Recording or
reads, stores or transmits screen pixels. That app-wide statement does not
describe Screen Memory and the separate Write for Me preview.

Owner choice:

- [ ] Approve the exact proposed disclosure below for `SECURITY.md`.
- [ ] Revise the disclosure before changing `SECURITY.md`.

Neither option is selected. This proposal adds no scanner exclusions, accepted
risks or severity changes. It does not approve enabling a feature or sending
content. Storage and companion-trust wording are separate review items.

## Proposed diff

```diff
--- a/SECURITY.md
+++ b/SECURITY.md
@@ -59,8 +59,9 @@
 - `com.apple.security.cs.disable-library-validation` = true
 - `com.apple.security.cs.allow-jit` = true

-Combined with the TCC permissions Transcripted asks for (microphone, screen
-recording, accessibility, calendars), this means: anything running as your user
+Combined with the TCC permissions Transcripted asks for (microphone, System
+Audio Recording, optional Screen Recording, accessibility, calendars), this means:
+anything running as your user
 that can write into `Transcripted.app/Contents/Frameworks/` can load its own
 code into the running app and inherit those permissions, including the ability
 to inject keystrokes into other apps via the paste-back path.
@@ -95,10 +96,19 @@

 ## Permissions and TCC prompts

-Meeting capture requests macOS's System Audio Recording permission for an
-audio-only ScreenCaptureKit stream. `NSScreenCaptureUsageDescription` remains
-as compatibility usage copy for ScreenCaptureKit, but Transcripted does not
-request full Screen Recording access or read, store, or transmit screen pixels.
+Meeting capture requests macOS's System Audio Recording permission for
+audio capture. It does not capture screen pixels.
+
+Writing's Screen Memory uses Screen Recording permission
+(`CGRequestScreenCaptureAccess`) to read context from the focused window. Its
+screen snapshots stay in memory for local Autocomplete.
+
+Developer Preview > Write for Me is a separate cloud feature, off by default.
+When enabled and invoked, it can send the focused window's screenshot and
+text, matching passages from saved meetings, dictations and writing, and
+examples of earlier dictation or writing to Claude through the user's signed-in `claude`
+CLI. This content sharing is separate from anonymous analytics and crash
+reporting.

 ## Companion MCP server trust model

```

## Source basis and limits

- `Sources/TranscriptedWriting/Runtime/ScreenMemory/ScreenRecordingPermission.swift`
  contains the CoreGraphics permission check and request.
- `Sources/TranscriptedWriting/Runtime/ScreenMemory/ScreenCaptureService.swift`
  holds Screen Memory snapshots and reads focused-window context.
- `Sources/Support/NextSentencePreferences.swift` defaults Write for Me off.
- `Sources/Writing/NextSentence/NextSentenceContext.swift` captures window text
  and a JPEG; `NextSentenceController.swift` assembles matching saved context
  and dictation or writing examples. `NextSentencePrompt.swift` and `NextSentenceClaude.swift`
  construct the request for the user's Claude CLI.

This is source evidence, not a live TCC or cloud-content test. Provider handling
and retention were not verified. The draft makes no claim of screenshot
redaction, perfect secret removal or a provider-side privacy guarantee. Recheck
the policy and owning source before applying any approved wording.
