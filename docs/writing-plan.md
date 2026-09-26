# Writing: bringing Tilde into Transcripted

Status: plan, not started. Written 2026-09-25 with Justin.

## Summary

Transcripted gets a third capture feature, **Writing**, next to Meetings and
Dictations. Writing is a port of [Tilde](https://github.com/r3dbars/tilde), the
local autocomplete keyboard, pinned at commit `f36f6562` (the 0.1.0 beta 1
line). Autocomplete keeps Tilde's behavior exactly. On top of that, Writing can
save what you write as plain Markdown in the capture library, so any agent can
read it next to your meetings and dictations.

This is a step in the longer plan: Transcripted grows, one feature at a time,
into a single app that captures your work context (meetings, dictation,
writing, and later activity) into portable files you can point any agent at.
The Context app (`r3dbars/context`) is the design reference for that direction.
It is not a code source for this port.

## Why

- Transcripted saves what you said. It doesn't see what you wrote, and a lot of
  work happens in writing: Slack replies, emails, notes.
- Tilde already does autocomplete well. Justin has daily-driven it far more
  than Context's copy of the keyboard.
- Transcripted has 100+ weekly users, Sparkle updates, notarized releases,
  Homebrew, and analytics. Tilde has one beta download and no way to learn
  whether autocomplete pays off for anyone else.

## Decisions (2026-09-25)

1. Port Tilde, not Context's ghost keyboard.
2. Writing is its own sidebar tab, after Dictations, with a "New" badge.
3. Writing has two optional features: **Save my writing** and **Autocomplete**.
4. App scope: **All apps** (password managers always skipped) or **Only apps I
   pick**. Autocomplete uses the same apps.
5. Models: the same two pins Tilde ships, Gemma 4 E2B (3.4 GB, default) and
   Qwen 3.5 9B Base (5.6 GB).
6. Saved writing is plain Markdown in the capture library, not Tilde's
   encrypted log. "Saved as plain files you can point any AI agent at" is
   part of the pitch.
7. Telemetry is counts only (suggestions shown and accepted, never text),
   under Transcripted's existing analytics toggle. This drops Tilde's
   zero-telemetry promise on purpose.
8. Tilde Lab does not ship in Transcripted. It stays in the Tilde repo. After
   phase 2 it's pointed at `Sources/TranscriptedWriting/Core`, so it tests what
   ships. It's Justin's testing tool, not a product.
9. `llama-server`: re-sign the exact binary Tilde 0.1.0 beta 1 shipped. Write
   down a reproducible llama.cpp build recipe before public rollout. It was built
   from llama.cpp commit `2115b73` (AppleClang 21, arm64, static); see the
   ledger's Follow-ups for the recipe.
10. Saved-text fidelity for v1: keyboard capture only, plus Backspace
    tracking so deleted text isn't saved. Look at real files before deciding
    whether an Accessibility read of the final field text is worth adding.
11. Personalized suggestions: off by default, with a toggle, same as Tilde.
    They'll turn on automatically once they're proven.
12. Menu bar: no Writing row. Everything lives in the Writing tab.
13. The keyboard is named "Transcripted" in Input Sources.
14. Standalone Tilde is frozen now: no new work. When Writing ships, Tilde's
    README points at Transcripted (draft note in [Phases](#phases)).
15. Qwen on Macs with less than 16 GB of memory: shown greyed out, with a
    line saying the Mac isn't eligible.
16. No early-access gate. When Writing is ready, the tab ships to everyone.
    Dogfooding happens on Justin's own builds before that release.

## Keyboard behavior (must match Tilde)

From `GhostInputController.swift` at `f36f6562`:

| Key | With a suggestion showing | With nothing showing |
| --- | --- | --- |
| `Tab` | Adds the next word and its trailing space. Press again for the word after. | Goes to the app. Also goes to the app when there is text after the caret on the line. |
| `` ` ``/`~` key (keyCode 50, with or without Shift) | Accepts the whole suggestion. | Types normally. |
| `Esc` | Hides the suggestion (the key is swallowed). | Goes to the app. |
| Typing the suggestion's next letter | The suggestion shrinks by that letter (type-through). | Normal typing. |
| Any other letter | The suggestion hides and a new one is requested. | Normal typing. |
| `Shift-Tab`, `Backspace`, `Return`, arrows, anything with Cmd/Ctrl/Opt/Fn | Hides the suggestion and goes to the app. | Goes to the app. |

The rest of the keyboard comes along unchanged:

- **Drawing:** the ghost is IMKit marked text in the host's font. It's grey in native apps and gets a faint underline in Chromium/Electron apps.
- **No other insertion paths:** nothing is inserted through Accessibility, overlays or fake paste.
- **Secure input:** suggestions stop under macOS Secure Event Input.
- **Length cap:** Gemma shows up to 8 words / 80 characters, Qwen up to 3 words / 42 characters.
- **Mid-word:** partial words of 3+ letters get a macOS dictionary completion. The model is asked only at word boundaries.

The full list is in [Parity checklist](#parity-checklist).

## Product design (approved)

### Sidebar

Today, Meetings, Dictations, **Writing** `New`, Speakers, Agent. Shortcuts
become ⌘1 to ⌘6 (Writing takes ⌘4; Speakers moves to ⌘5 and Agent to ⌘6). The
`New` badge stays until the user finishes setup or dismisses the intro.

### Intro, page 1 of 2

The Writing tab opens here until setup is done. Nothing is asked for yet.

- Small title: **Writing**
- Headline: **Your AI knows what you said. Not what you wrote.**
- Body: "Transcripted already saves your meetings and dictations. But a lot of
  your work happens in writing: Slack replies, emails, notes. Writing in
  Transcripted adds that context, and helps you write faster."
- **Your context** row: Meetings ✓, Dictations ✓, Writing + (highlighted).
- Three points:
  - **Fuller context for your AI.** "Your notes and replies sit next to your
    meetings, so your AI can pick up where you left off."
  - **You're in control.** "Pick the apps. Pause or delete anytime."
  - **100% local.** "No account. Your writing never leaves your Mac. It's saved
    as plain files you can point any AI agent at."
- Page dots, **Next**.

Copy rule: say "what you wrote", never "what you typed". The feature must not
read like a keylogger.

### Intro, page 2 of 2

- Headline: **Autocomplete finishes your sentences.**
- Body: "As you type, Transcripted suggests the next few words right where
  you're typing. Take them or leave them."
- A looping demo: a sentence types itself, an underlined suggestion fades in,
  `Tab` is pressed once per word, then "N keystrokes saved". It cycles a Slack
  reply, an email and a note. Build it as a SwiftUI animation, not a video, so
  it stays sharp in dark mode and costs nothing in download size. It holds
  still when Reduce Motion is on.
- Key hints: `Tab` adds the next word, `~` takes the whole suggestion, keep
  typing to ignore it, `Esc` hides it.
- Page dots, **Back**, **Set up writing**.

### Setup, step 1 of 3: "What should writing do?"

- **Save my writing** (toggle, starts on): "Your AI can read what you wrote.
  Files stay on this Mac, only in apps you choose."
- **Autocomplete** (toggle, starts on): "Suggests the next words. Hit Tab to
  accept."
- One **Continue** button. With both on, Continue is the turn-on-everything
  path. At least one must be on ("Turn on at least one to continue.").

### Setup, step 2 of 3: "Which apps?"

- **All apps**: "Password managers are always skipped."
- **Only apps I pick**: chips for installed apps, with Slack, Notes, Mail,
  Messages, Chrome, Notion and Linear first when installed. At least one
  ("Pick at least one app.").
- "Autocomplete uses the same apps."

### Setup, step 3 of 3: "Allow and download"

Only the rows the step 1 toggles need are shown.

- **Transcripted keyboard** (`Both` or `Needed`): "Turns on in Input Sources.
  No privacy prompt."
- **Screen Recording** (`Autocomplete`): "Reads the window you're replying in,
  on this Mac."
- **Model** (`Autocomplete`): Gemma 4 E2B, 3.4 GB, faster (default). Qwen 3.5
  9B, 5.6 GB, better. On Macs with less than 16 GB of memory, Qwen is greyed
  out with "Your Mac needs 16 GB of memory for this model." The same rule
  applies to the model switch in the everyday view.
- Footnote: "Suggestion counts only, never text. Follows your analytics
  setting."
- **Back**, **Turn on writing**.

Order of operations after **Turn on writing**: install and select the keyboard
first, start the model download in the background, ask for Screen Recording
last. macOS usually asks the app to quit and reopen after Screen Recording is
granted, so Transcripted must hold that relaunch while a meeting is recording.

### Everyday view (after setup)

Shaped like the Dictations page:

- Title **Writing**, summary "N words today" (or "Autocomplete only").
- Status line: keyboard on/off, model and its state (downloading, ready,
  error), app scope.
- Today's saved writing, newest first, in the same row style as dictations.
- "N suggestions accepted today".
- Actions: **Edit setup**, **Pause for 1 hour**, **Delete all writing**, a
  storage meter, and the model switch. Pause stops suggestions, saving and
  screen reading for the hour (Tilde's pause only stopped suggestions).
- The intro has a quiet **Not now** that leaves Writing off and clears the
  sidebar's `New` badge.

## Permissions

| Choice | Keyboard as an input source | Screen Recording | Model download |
| --- | --- | --- | --- |
| Save my writing only | Yes | No | No |
| Autocomplete only | Yes | Yes | 3.4 or 5.6 GB |
| Both | Yes | Yes | 3.4 or 5.6 GB |

**Keyboard.** It needs no TCC prompt. It only has to be enabled and selected in Input Sources.
- Tilde's installer registers and selects the keyboard but never enables it, so Tilde users add it by hand in System Settings.
- Transcripted also calls `TISEnableInputSource`, which Context proved works, and falls back to opening Keyboard settings.

**Screen Recording.** It's required for autocomplete, same as Tilde. Without it the keyboard stays silent, and the Writing tab says why with a one-click path to grant it.

**Accessibility.** Transcripted already holds it for paste-back, so Tilde's "exact screen text" path (it reads the Accessibility tree before falling back to OCR) works with no extra prompt. Tilde asks for Accessibility at launch; Transcripted doesn't need to.

## Parity checklist

Source: Tilde `f36f6562`. "Same" means a straight port, with only identities and paths renamed.

### Keyboard (`Sources/InlineGhostIME`)

| Behavior | In Transcripted |
| --- | --- |
| Keys in the table above, including type-through and pass-through rules | Same |
| When to ask: 3+ letters/digits typed and only whitespace after the caret; the model only after whitespace; mid-word dictionary completion (`SuggestionActivationPolicy`) | Same |
| Context: 3,000 UTF-16 units before the caret, start snapped to 250-char steps for prompt-cache reuse, own typed buffer as a fallback | Same |
| Reveal delay: native 10/50 ms; Chromium/Electron 120/200 ms (`SuggestionRevealDelayPolicy`) | Same |
| Ghost drawing: host font, grey; faint underline in Chromium/Electron | Same |
| Visible cap: Gemma 8 words / 80 chars, Qwen 3 words / 42 chars | Same |
| Request tickets, cancel on any key, stale answers dropped, streaming ghosts only grow, 2 s line timeout | Same |
| Secure Event Input: cancel everything, pass keys through | Same |
| Pause (`GhostPausedUntil`) and off switch checked on every key | Same, driven from the Writing tab |
| Relaunches the app at most once a minute when it's unavailable | Same, opens Transcripted |
| Daily counters (`GhostStats`) | Same, feeds the Writing tab and analytics |

### App runtime (`Sources/TildeApp`)

| Behavior | In Transcripted |
| --- | --- |
| Owner-only Unix socket, one-instance lock, JSON lines v1, 16 KB max | Same, under Transcripted's app support |
| Peer auth on both ends: same uid, expected signing identifier, matching non-empty Team ID | Same, with Transcripted's identities |
| Request gates: helper health, Screen Memory, same field, scene lookup, sensitive scene, scene policy | Same |
| `llama-server` helper, restart backoff, health probes, orphan reaping, scaffold prewarm | Same. **Change:** use a port other than Tilde's `17872`, so both can run during migration |
| Pinned Gemma/Qwen download: resume, retries, disk check, SHA-256 verify, excluded from backup | Same. **New:** adopt an already-verified Tilde model file instead of downloading again |
| Model switch relaunches the app | **Change:** restart only the helper. Transcripted can't relaunch mid-meeting |
| Setup window | **Replaced** by the Writing tab intro and setup above |
| Keyboard installer: staged copy to `~/Library/Input Methods`, signature and Team ID check, replace on newer version, kill the running keyboard | Same, plus `TISEnableInputSource` |
| Menu bar: status, pause for 1 hour, ignore the front app | Moves to the Writing tab. Menu bar rows are an open question |
| Settings: on/off, model, personalized suggestions, Screen Memory, exact screen text, ignored apps, data size and delete, fix screen access, redownload model, run setup again, export diagnostics | Same controls in the Writing tab's settings section. Launch at login is already Transcripted's |
| "Your Tilde" stats: keystrokes saved today and 7 days, % kept after 30 s, streaks, held back by reason, personalization stage | Same, in the everyday view |
| Text-free outcome ledger | Same. It also feeds the count-only analytics |
| Word diary: plaintext accepted text, always on, no size cap | **Change:** keep only its text-free kept/edited results. Accepted text is saved only when Save my writing is on, inside the writing files |
| Diagnostics log with an allowlist redactor | Same redactor, written to Transcripted's logs |

### Personal History and personalized suggestions

| Behavior | In Transcripted |
| --- | --- |
| Captures typed and accepted text with app, time and segment. Segments break on caret or app change, deletion, modifiers and secure input | Same, gated by **Save my writing** and the app scope |
| Built-in password-manager exclusions plus the user's list | Same. **New:** an allowlist mode for "Only apps I pick" |
| Encrypted log and model with the key in Keychain | **Changed** per decision 6. See [Storage](#storage) |
| Delete all | Same, and it also deletes the writing Markdown files |
| Personal n-gram predictor, and its rules for replacing the model's ghost | Same logic. Its default is an open question |

### Screen Memory

| Behavior | In Transcripted |
| --- | --- |
| Required for any suggestion; silent without it | Same |
| Capture triggers and spacing; blocked on lock, secure input, no field, or any visible excluded window | Same |
| Accessibility tree first, then ScreenCaptureKit plus Vision OCR; full display only in narrow cases | Same |
| Memory only, 20 s staleness | Same |
| Rules-only redaction at prompt build (`SecretRules`) | Same |
| Scene classification and the sensitive, suggestion, echo and factual-grounding policies | Same |

### Suggestion quality (`Sources/TildeCore`)

Prompt builder, per-app-type few-shot examples, sampling (Gemma temperature 0 / 20 tokens, Qwen 0.10 / 12 tokens), output cleaner, and the 29 decision reasons: all ported verbatim. This is what makes it feel like Tilde, so no tuning changes ride along with the port.

### Tilde bugs to fix while porting

- **Ignored apps don't block suggestions.** The ignored-apps list stops capture and screen context but never stops the ghost. In Transcripted the app scope must gate suggestions too, because setup promises "Autocomplete uses the same apps".
- **Wrong accept-key help text on ISO keyboards.** It calls the `~` key "the key above Tab". On ISO layouts keyCode 50 is the key next to left Shift.
- **Privacy docs drifted from code:** the Accessibility use, the word diary, email/phone scrubbing, and private browsing. Transcripted's privacy copy is written from the code, not from Tilde's `PRIVACY.md`.

### Not ported (dev-only in Tilde)

- Hidden command-line flags: `--release-proof`, `--personal-brain-status-json`, `--replay-eval-json`, `--redaction-eval-json`.
- The H01 word-count randomization and the preview builds (26B, 9B, Model Preview).
- The local OCR evaluation store, the incremental OCR flag, the release-proof stimulus, and replay eval.
- The GLiNER redaction helper.
- All `TILDE_*` environment overrides, except a test-only unsigned-peer flag in DEBUG.
- Tilde Lab.

## Where the code goes

Tilde's split carries over. The pure policy stays pure, the keyboard stays thin, and the app owns every disk write and the model.

```
Sources/
  TranscriptedWriting/
    Core/        TildeCore: suggestion state, activation and reveal policies,
                 prompt builder, output cleaner, decision reasons, wire format,
                 scene policies, SecretRules, personal predictor. No AppKit,
                 IMKit, processes, sockets or files.
    Runtime/     TildeApp's non-UI half: socket server and peer auth,
                 llama-server host and restart policy, scaffold prewarm,
                 model manager, Screen Memory, personal history, outcome
                 ledger summary, keyboard installer, diagnostics redactor.
  TranscriptedKeyboard/
                 InlineGhostIME: GhostInputController, brain client, capture
                 batching, outcome ledger writer, daily stats, Info.plist.
  Writing/       App bridge (@MainActor): WritingController, preferences,
                 setup state, the Markdown day-file writer, analytics emitter,
                 capture-change notifications for Home and Today.
  UI/Settings/Pages/WritingSettingsPage.swift
  UI/Settings/Writing/
                 Intro pages, demo animation, setup steps, everyday view,
                 settings section.
Tests/
  TranscriptedWritingTests/
                 Tilde's TildeCoreTests and TildeAppTests (about 85 files,
                 Swift Testing), ported with the code.
  Writing*Tests.swift
                 Root fast tests for the app bridge's presentation logic.
```

Rules:

- **Boundary.** `Sources/TranscriptedWriting/` is a library boundary like `Sources/TranscriptedCore/`. The app reaches it only through `Sources/Writing/`. Paths, preferences and analytics are injected by the bridge, never read from inside the library. Add a source-contract test that fails if `TranscriptedWriting` references app types.
- **Straight port first.** Rename Tilde identities, bundle IDs and paths. Don't tune suggestion logic during the port. Behavior changes come after parity is proven.
- **Delete Tilde's dev-only hooks** as each file is ported (see [Not ported](#not-ported-dev-only-in-tilde)).

## Build

- **App target.** `build.sh` already compiles every `Sources/**/*.swift` except `TranscriptedCore` (`scripts/entrypoints/lib/swiftc-app-args.sh:74`), so `TranscriptedWriting/` and `Writing/` compile straight into the app module.
  - Add an exclusion for `Sources/TranscriptedKeyboard/` there, or the keyboard lands in the app binary.
  - Core-style imports are guarded with `#if canImport(...)`, the same pattern 22 files already use for `TranscriptedCore`.
- **Package.swift.** Add `TranscriptedWritingCore` and `TranscriptedWritingRuntime` library targets pointing into `Sources/TranscriptedWriting/`, plus a `TranscriptedWritingTests` target, so Tilde's tests run under `swift test`.
  - These don't use `coreTestTarget`, since they need no deps flags.
  - The manifest is tools 5.9. Confirm Swift Testing runs there on the current toolchain, or convert the tests to XCTest.
  - Don't bump the manifest to 6.0: that flips TranscriptedCore to Swift 6 mode.
- **Keyboard bundle.** Add `scripts/entrypoints/lib/bundle-input-method.sh`, called from `build.sh` (after the CLI helper, around `:518`) and from `build-beta.sh` (around `:526`). It will:
  - compile `Sources/TranscriptedWriting/Core/**` and `Sources/TranscriptedKeyboard/**` with `swiftc -swift-version 5 -framework InputMethodKit`. Tilde also keeps the keyboard in Swift 5 mode.
  - write the bundle's Info.plist: `InputMethodConnectionName`, `InputMethodServerControllerClass`, `TISInputSourceID` prefixed by its bundle ID with at least four components, background-only.
  - stamp its version from the root Info.plist. `bump-release-version.py` only touches the root.
  - place `Transcripted Keyboard.app` at `Contents/Library/Input Methods/`, keeping its icon inside its own bundle. `performance-budget.rb:329` requires the app's icons to be only `Transcripted.icns`.
  - sign it inside-out before the outer app.
- **`llama-server`.** Pin the exact helper Tilde 0.1.0 beta 1 shipped, so inference matches. It's pinned by its code bytes with the signature removed (SHA-256 `3f6895ab8d077b02803761fb8cc254073d2c7b4006fbacbef4c844879333fffc`), taken from the release's `Tilde.zip` (SHA-256 `12b7f14ae31abea7d5cecf236d2e4de3b0facad89fa580877dec391336b26a50`). The `41944b…` hash in Tilde's release notes is the pre-strip, pre-sign input, which isn't published.
  - Fetch and hash-check it in `build-deps.sh` into `deps-tools/`, the way Sparkle and Sentry are pinned. CI already caches that folder.
  - Copy it to `Contents/Helpers/llama-server`. The existing Helpers signing loop (`build.sh:376`) covers it.
  - Any dylibs it needs must sit next to it. Tilde's is a static build with system-only dependencies.
- **Fast tests.** `run-tests.sh` compiles a hand-picked list (`APP_SOURCES`). Keep Writing presentation logic in Foundation-only files, like `TodayPresentation.swift`, and add each file a fast test needs to that list.

## Release

- **Signing.** `build-beta.sh:303-345` signs helpers but nothing under `Contents/Library/`. Until a keyboard branch exists, these all fail:
  - notarization
  - `codesign --verify --deep --strict` (`build-beta.sh:160`, `release-candidate.yml:200`)
  - `PackagedAppSmoke`

  The keyboard gets hardened runtime, a timestamp, and its own `config/entitlements/keyboard.plist`.
- **Pinned text.** `Tests/BuildDependencies/CLIPackagingTests.sh:82-88` pins the signing-call lines. Update it with the change.
- **Smoke checks.** Add checks for `Contents/Helpers/llama-server` and the keyboard bundle to `PackagedAppSmoke.swift` (the helper checks at `:241-247`).
- **Size.** The installed app is about 547 MB against a 650 MB budget. The helper fits; models are never bundled.
- **Licenses.** Add llama.cpp (MIT) to `THIRD_PARTY_LICENSES.md`. Show the Gemma Terms of Use and Qwen's Apache 2.0 license at model download.
- **Sparkle.** Sparkle replaces the whole app, and the keyboard runs from its copy in `~/Library/Input Methods`, not from inside the app. On launch the installer compares `CFBundleVersion`, re-copies, and kills the running keyboard, as Tilde does. Moving the app doesn't break the keyboard for the same reason.
- **Dev builds.** Ad hoc signing can't pass the socket's Team ID check, so autocomplete only works in builds signed with a real identity, same as Tilde. Keep Tilde's DEBUG-only unsigned-peer flag for local work.

## Storage

**Saved writing** (the user-facing copy): `<capture-library>/writing/Writing_<YYYY-MM-dd>.md`.
- It's shaped like dictation day files so every reader extends easily. The frontmatter has `capture_type: writing_day` and `format_version: 1`.
- Each entry has a heading `## <h:mm a> - <first ~7 words>` and these lines: `Entry ID:`, `Captured:`, `Source app:`, `Bundle ID:`, `Words:`, `Characters:`, `Accepted words:`. Then the text.
- Document it in `docs/capture-format.md` before the first file ships.

**Who writes the files.** The main app, never the keyboard, same as Tilde, where the app owns every disk write.
- The keyboard sends typed and accepted text over the socket.
- The app groups it into entries (per app, split after an idle gap or an app switch) and writes the day file.
- That lets Home and Today refresh on a notification, and keeps test harnesses away from real user files.

**Fidelity.** Tilde's history is an insertion log. It doesn't see pastes or mouse edits, and it breaks segments on every deletion. For v1, the keyboard also reports backspaces inside its own typed buffer, so saved text drops what you deleted. Known gaps are pastes, mouse edits, and host autocorrect. (Open question 1.)

**App-owned state** in `~/Library/Application Support/Transcripted/writing/` (the diagnostics log is at `~/Library/Application Support/Transcripted/logs/writing-diagnostics.log`):
- `ghost.sock` and `runtime.lock`
- `outcome-ledger/` (text-free)
- `personal/` (predictor state)

**Models** in `~/Library/Application Support/Transcripted/models/writing/<id>/model.gguf`, excluded from backup.
- If `~/Library/Application Support/Tilde/Models/<id>/model.gguf` exists and its SHA-256 matches the pin, clone it (APFS `clonefile`) instead of downloading 3.4 to 5.6 GB again.

**Capture library plumbing.** These places only know meetings and dictations today:
- `TranscriptedStoragePaths.swift`: the manifest gets an optional writing folder; `prepareCaptureLibraryURL`.
- `CaptureLibraryMigrationPlanner.swift`: without it, Move and Copy silently leave writing behind.
- `RecentCaptureScanners.swift`.
- the first-run report in `TranscriptedApp.swift:1200`.
- `ExistingInstallModelPrefetchPolicy.swift:62`.
- `docs/storage-paths.md`.

## Agent tools

Writing isn't useful to agents until the tools read it:

- **CaptureKit:** add a `Writing_` prefix, a writing-day parser, and a `TRANSCRIPTED_WRITING_DIR` override in `CaptureLibraryResolver`.
- **MCP:** `TranscriptLoader.swift:129-144` treats any non-`Dictations_` Markdown file with frontmatter as a meeting, so writing files would be indexed as meetings. Check `Writing_` first. Then:
  - add a `writing` capture kind (`Models.swift`, `AgentCaptureQueryTelemetry.swift:262`)
  - index it (`TranscriptIndex.swift`; bump the schema version)
  - teach list, read, search, `search_context` and `recent_context` about it (`ToolHandlers.swift`)
  - update the Claude Desktop self-test struct
- **CLI and QA:** extend the context store and commands in `Tools/TranscriptedCLI`, and add a writing validator next to `DictationValidator` in `Tools/TranscriptedQA`.

## Settings and UI

- **Sidebar.** Add `.writing` after `.dictations` in `TranscriptedSettingsPage` (title, `keyboard` icon, ⌘4, renumbered shortcuts) and in `SettingsSidebarSection.primarySection`.
  - The row view has no badge slot; add one for `New`.
  - The page id comes out as `writing`, so page views show up in analytics for free.
- **Shell.** `TranscriptedSettingsView.swift` is a hotspot pinned by literal-text tests. Only add routing cases there (`pageBody`, the discovery-area switch, `onChange`, Today's open-item switch, refresh). All Writing UI lives in `Pages/` and `Settings/Writing/`.
- **Other exhaustive switches:** `SettingsRecentCaptureRefreshPolicy.swift`, the Go menu in `TranscriptedMenuCommands.swift`, `FocusOrderContract.swift`.
- **Pinned tests to update in the same change:**
  - `UIAutomationSurfaceContractTests.swift` (`:218-251` shortcuts, `:294-322` page cases)
  - `FocusOrderContractTests.swift` (asserts 5 pages)
  - `SettingsRecentCaptureRefreshPolicyTests.swift` (pins Agent on ⌘5)
  - `Tools/TranscriptedQA/.../UISmoke.swift`
  - `Sources/UI/CLAUDE.md` and `Sources/UI/Settings/CLAUDE.md`
- **Screen-share privacy test.** `OverlayScreenSharePrivacyTests` scans every window under `Sources/UI`, so the intro and setup views must follow its rules.

## Permissions changes

- **Keep Screen Recording out of the global permissions list.** Adding a case to `TranscriptedPermissionKind` would add a Screen Recording row to the settings rows, onboarding and `PermissionSnapshot` for every user, including people who never touch Writing. Writing owns its own permission state (Screen Recording plus keyboard enabled and selected) and shows it only in the Writing tab.
- **Fix copy that's no longer true.** Today the app promises it never needs full Screen Recording:
  - `TranscriptedPermissionKind.swift:82` and `:113-115`, which tell users to turn the broader permission off
  - `Sources/Support/CLAUDE.md:65`

  The new rule: meetings don't need screen access; Writing's autocomplete does. Update the two tests that pin the old copy, `TranscriptedPermissionAccessTests.swift:193` and `MeetingRecordingStartGateTests.swift:147`.
- **The main app holds Screen Recording**, not the keyboard, because Screen Memory runs in the app, as in Tilde.

## Analytics

Counts only, under the existing analytics toggle. The keyboard process sends nothing. The app reads today's counts from the text-free outcome ledger.

| Event | Properties |
| --- | --- |
| `writing_daily_counts` (once a day while Writing is on) | `suggestions_shown`, `suggestions_accepted`, `words_accepted_bucket`, `model_choice` (`gemma_e2b` / `qwen_9b`), `save_enabled`, `autocomplete_enabled`, `app_scope` (`all` / `picked`) |
| `writing_setup_completed` | `save_enabled`, `autocomplete_enabled`, `app_scope`, `model_choice` |

- **Never sent:** text, app names or bundle IDs, or per-suggestion events. The sanitizer drops keys containing `bundle`, `source_app` or `text` anyway.
- **Files:**
  - `Resources/analytics-events.psv`
  - `Resources/analytics-reviewed-properties.psv`
  - the allowlist in `docs/privacy-first-observability.md`, which `AnalyticsEventPolicyTests` checks against the psv
- **Emitting:** a literal `AnalyticsReporter.track(...)` in `Sources/Writing/`.
- **Checks:** `check-analytics-emitters.py`, `normalize-analytics-taxonomy.py --check`, `check-telemetry-keys.py`.
- **Sentry** covers the app side only. Keyboard failures go to the local diagnostics log.

## Phases

Each phase lands as its own PR (or a small stack) with the checks `.agents/test-matrix.yml` asks for.

**Phase 1: it builds and signs.**
- Scope:
  - Port `TildeCore` into `Sources/TranscriptedWriting/Core` with its tests.
  - Add the keyboard target and bundle script.
  - Pin `llama-server` in build-deps.
  - Signing in `build.sh` and `build-beta.sh`; smoke and packaging checks; licenses.
  - No UI, and nothing runs.
- Exit:
  - `bash build.sh --no-open` and `SKIP_NOTARIZATION=1 bash build-beta.sh '' <user>` produce an app with a signed keyboard and helper.
  - `codesign --verify --deep --strict` passes.
  - `swift test --filter '^TranscriptedWritingTests\.'` passes.

**Phase 2: autocomplete works behind a debug default.**
- Scope:
  - Port the socket server and peer auth, the llama host, the model manager with Tilde-model adoption, Screen Memory, and the keyboard installer (with enable).
  - Choose a llama port that doesn't collide with Tilde's.
- Exit: on Justin's Mac, with Tilde quit, every keyboard row in the parity checklist checks out by hand in Slack, Mail, Messages, Notes, Chrome and VS Code, on both models.

**Phase 3: Save my writing.**
- Scope:
  - Keyboard capture with backspace handling, the app-side entry grouping, and the Markdown day-file writer.
  - The app scope allowlist, which also gates suggestions (the Tilde bug fix).
  - Delete all, the capture library plumbing, the capture-format and storage docs, and CaptureKit, MCP, CLI and QA.
  - The personal predictor.
- Exit:
  - Writing day files show clean entries for a scripted typing session.
  - MCP list, read and search return writing.
  - Library Move and Copy carry writing.
  - `bash run-e2e-smoke.sh` passes.

**Phase 4: the Writing tab.**
- Scope:
  - The sidebar with the `New` badge and renumbered shortcuts.
  - The two intro pages and the demo animation, the three setup steps, the everyday view with stats, and the settings section.
  - The permission copy fixes, and updates to every pinned test.
- Exit:
  - The tab matches the approved design and copy.
  - UI smoke and fast tests pass.
  - The Screen Recording grant never relaunches the app during a meeting.

**Phase 5: telemetry.**
- Scope: the two events and the privacy doc updates.
- Exit: the events arrive in PostHog with only allowlisted keys.

**Phase 6: rollout.**
- Justin dogfoods a signed build for a week before the release that includes Writing.
- Then the Writing tab ships to everyone in a normal release (decision 16).
- Update the README, release notes, and the uninstall steps (remove the keyboard from Input Sources, delete `~/Library/Input Methods/Transcripted Keyboard.app`).
- Write down the reproducible `llama-server` build recipe (decision 9).
- Add a note at the bottom of Tilde's README. Draft:

  > **Where Tilde went.** Tilde is now a feature inside
  > [Transcripted](https://transcripted.app), my Mac app for meetings and
  > dictation. It's called Writing. It's the same keyboard with the same
  > models and the same `Tab` and `~` keys, and it can also save what you
  > write as plain files your AI can read. This repo is frozen. The last
  > release still works and you're welcome to keep using it, but all new work
  > happens in Transcripted. One difference: Transcripted can send anonymous
  > usage counts (never your text), and you can turn that off in Settings.

Also, after phase 2: point Tilde Lab at `Sources/TranscriptedWriting/Core` (decision 8).

**Later, not part of this port:**
- A Writing tile and a week-strip lane on Today.
- Meeting and dictation context in suggestions (a Tilde Lab experiment first).
- Dictation inserting through the keyboard instead of borrowing the clipboard.

## Risks

- **Relaunch after the Screen Recording grant** can kill a meeting recording. Hold it while recording; ask for Screen Recording last.
- **The permission promise changes.** Meeting-only users must never see a Screen Recording ask.
- **Two keyboards during migration.** If Tilde's keyboard is also selected, both react. Detect it and offer to remove it. Don't share its llama port.
- **Memory.** Gemma plus Parakeet on an 8 GB Mac hasn't been measured, and Qwen wants 16 GB or more. Measure both before the model step goes live.
- **Pinned-text tests** across settings, permissions and packaging. Budget for them in phases 1 and 4.
- **Tilde Lab drift** between the port and repointing the Lab after phase 2. Don't tune suggestion logic in that window.
- **The llama-server binary has no recorded provenance.** Tilde pins its hash but its repo doesn't record which llama.cpp commit or flags built it. Decision 9 covers it before rollout.

## Open questions

None right now. New ones go here as the phases turn them up.
