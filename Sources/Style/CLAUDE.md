# Style Learning Engine

## What This Does

Learns the user's writing style through training pairs (AI draft vs. what the user actually sent) and incrementally refines a style profile that personalizes how Haiku drafts messages. Includes a first-launch onboarding flow for instant profile generation.

## Key Files

- `StyleEngine.swift` (~580 lines) — `@MainActor ObservableObject` managing style.md, training pair collection, incremental refinement, and onboarding state
- `StyleUtils.swift` (~70 lines) — Pure utility functions extracted from StyleEngine: `shouldRefineNow()`, `averageRecentEditDistance()`, `extractRecentEditDistances()`, `wordEditDistance()`, `extractRecentExamplesText()`. Stateless enum with static methods — no `@MainActor`, no ObservableObject. StyleEngine delegates to these.

## How It Works

### Onboarding (First Launch)

Solves the **cold start problem** — without onboarding, the first 10+ drafts are generic because Draft doesn't know how you write yet.

1. After auth setup, `StyleOnboardingView` appears (gated by `hasCompletedOnboarding`)
2. User chooses a source: **Import from iMessages** (recommended) or **Paste Samples Manually**
3. iMessage path: `iMessageReader` reads `~/Library/Messages/chat.db` (requires Full Disk Access, no date filter, no SQL word filter — just `is_from_me = 1` with `LIMIT 2000`, Swift-level `shouldSkip()` filters to 2+ character messages), shows preview, user approves. Includes optional "Add Slack, email, or other writing samples" expandable section — if provided, combined text (iMessages + supplement) is sent together.
4. Manual path: User pastes real writing samples (Slack messages, texts, emails — messy is fine)
5. Either path calls `importBulkSamples()` which reads the user's display name from UserDefaults (`"user-display-name"`) and sends text to **Sonnet** with a specialized `bulkAnalysisPrompt(userName:)`. The name helps Sonnet identify which messages belong to the user vs. other participants. When iMessage + supplementary text are combined, the joined text is passed as a single string.
6. Sonnet returns a comprehensive 500-800 word style profile analyzing 9 dimensions (sections listed under Profile Structure below)
7. **Only the generated profile is saved** — raw samples/messages are discarded after analysis
8. User can review, add more samples and regenerate, or accept
9. "Skip for Now" is always available — the incremental system works without onboarding

### Training Pair Collection

Every time the user accepts a draft (Copy or "Paste to Source App"), `recordExample()` saves a **training pair**:
- `PLATFORM` — detected from the target app (slack/imessage/email/etc.)
- `FORMALITY` (optional) — detected communication register (casual/professional/formal), included when available
- `USER_INSTRUCTIONS` (optional) — the user's spoken voice instructions, included when non-empty
- `EDIT_DISTANCE` — word-overlap ratio (0 = identical, 1 = completely different)
- `AI_DRAFT` — what the AI produced (snapshotted from `DraftEngine.originalDraft`)
- `USER_SENT` — what the user actually sent (may be edited version)

The diff between AI_DRAFT and USER_SENT is the core learning signal — it reveals exactly where the style profile is wrong. The optional `USER_INSTRUCTIONS` field enables instruction-vs-style separation during refinement: if the user's edits align with instructions the AI missed, that's an instruction error, not a style signal.

### Graduated Refinement

Refinement frequency adapts based on example count and profile quality:

- **Examples 1-20:** Refine every **3** accepted drafts (early learning phase — each data point matters)
- **Examples 21+, avg edit distance < 0.25:** Refine every **10** (profile is working well — user barely edits)
- **Examples 21+, avg edit distance ≥ 0.25:** Refine every **5** (still learning — something's off)

`shouldRefineNow()` encapsulates this logic. It reads the last 10 edit distances from style.md to determine which phase the profile is in.

### Recency-Weighted Refinement

`regenerateStyleSummary()` sends only the **last 20 examples** to Sonnet (via `extractRecentExamplesText(last:)`), not all accumulated history. Early examples were recorded when the profile was poor — those lessons are already encoded in the profile. Sending stale examples wastes tokens and adds noise.

### Incremental (Not Rebuild)

`buildRefinementPrompt(currentProfile:)` (a `private static` method) builds the Sonnet prompt with two branches:

- **Has existing profile:** "Here's the current profile. Here are training pairs showing what the AI got wrong. Fix the profile based on these patterns." Includes contamination auditing: Sonnet is told to REMOVE patterns from the current profile that were incorrectly attributed from AI_DRAFT text.
- **No existing profile:** "Build a profile from these training pairs. The USER_SENT versions are ground truth."

Both branches include:
- **Critical Source Rules** — 5 rules enforcing that USER_SENT is the sole source of truth and AI_DRAFT patterns must not be attributed to the user (the refinement branch adds a 6th rule: audit the current profile for contamination from AI_DRAFT)
- **Instruction vs. Style Separation** — when USER_INSTRUCTIONS is present, distinguishes between instruction errors (AI missed what the user asked for) and true style preferences (user changes beyond what they instructed)
- **Formality-aware rules** — when FORMALITY data is available, NEVER rules should be context-specific (e.g., "NEVER X in professional Slack" not just "NEVER X")
- **Evidence Rule** — every claimed pattern must include 1-2 direct quotes from USER_SENT as proof

The profile gets surgically adjusted based on actual errors, not reconstructed. Sonnet is told to PRESERVE patterns from the current profile that have USER_SENT evidence, REMOVE contaminated patterns, and FIX dimensions where training pairs show clear errors.

### Application — Ghostwriting System Prompt (Intent-First)

`buildSystemPrompt()` first calls `extractStyleSummary()` to get the profile. If the summary is empty (no profile yet, or still the placeholder text `"(Will be generated after 5 examples)"`), it falls back to `promptStore?.config.draftingSystem ?? DefaultPrompts.draftingSystem` — a generic drafting prompt with no style personalization.

When a style profile exists, it assembles a structured system prompt with an **intent-first hierarchy**:

1. **`<primary_goal>`** — Appears FIRST. Establishes that accomplishing the user's communicative intent is the top priority, above style mimicry.
2. **`<style_profile>`** — The generated profile from `## Style Summary`, wrapped in XML tags.
3. **`<reference_messages>`** — 2-3 diverse USER_SENT examples from training pairs, with platform tags. Extracted by `extractReferenceSamples(count:)` which walks backwards (most recent first) and prioritizes different platforms for diversity.
4. **`<how_to_use_style>`** — Explicitly frames style as a "finishing layer" applied after intent is nailed. Includes anti-opener guidance: signature openers should only be used when they genuinely fit the conversational context.
5. **`<instructions>`** — Rules starting with "INTENT FIRST" and "DON'T DEFAULT TO OPENERS". Covers platform register, message length, and anti-AI-assistant guardrails.

**Key design decision:** The old `<the_test>` framing ("could they tell it wasn't written by them?") was removed because it pulled the AI toward style mimicry at the expense of intent delivery. Intent accomplishment is now the primary directive, with style as a finishing layer.

The XML structure lets Haiku parse the prompt sections independently (per Anthropic's prompt engineering guidance). The reference samples provide "ground truth" — descriptions tell Haiku what patterns to follow, but samples demonstrate the actual rhythm and cadence.

### Profile Structure

The analysis and refinement prompts generate profiles with these **required sections** (enforced by the prompts):

- **Tone & Voice** — register, warmth, directness
- **Sentence Patterns** — length, rhythm, fragments, idea chaining
- **Platform-Specific Patterns** — sub-sections per platform (Slack, iMessage, email, etc.)
- **Openings & Closings** — greeting/sign-off patterns by platform
- **Punctuation & Formatting** — punctuation fingerprint, emoji, capitalization
- **Signature Phrases** — 5-15 characteristic phrases as a bullet list with quotes
- **Quantitative Fingerprint** — sentence length, message length by platform, contraction usage, active voice ratio
- **ALWAYS** — 5-10 rules a ghostwriter must follow
- **NEVER** — 5-10 things this person would never write (critical for preventing AI default patterns)

### Cost Model

Style Summary + 2-3 reference samples (~1200-1500 tokens) are injected into the system prompt. Drafting cost stays roughly constant regardless of example count. Refinement frequency decreases as the profile improves (every 3 → every 5 → every 10), and only the last 20 examples are sent to Sonnet per refinement.

## File Format (style.md)

```markdown
# Writing Style Profile

## Style Summary
**Tone & Voice**
[Sonnet-generated analysis...]

**Sentence Patterns**
[...]

**Platform-Specific Patterns**
Slack: [...]
iMessage: [...]

**Signature Phrases**
- "yo" (casual greeting)
- "but honestly" (pivot to real point)
[...]

**ALWAYS**
- Open Slack DMs with "yo" or "hey man"
[...]

**NEVER**
- Use semicolons
- Write "I hope this helps"
[...]

## Examples

### Example 1
PLATFORM: slack
FORMALITY: casual
USER_INSTRUCTIONS:
say yeah I'm down for lunch tomorrow
EDIT_DISTANCE: 0.42
AI_DRAFT:
Hey Sarah! That sounds great, I'm totally in for lunch tomorrow.

USER_SENT:
hey! yeah totally down for lunch tmrw 👍
```

`FORMALITY` and `USER_INSTRUCTIONS` are optional — older examples or examples without voice instructions omit them.

No onboarding samples section — raw pastes are discarded after initial profile generation.

## Public Interface

```swift
@Published var exampleCount: Int
@Published var styleFileContents: String
@Published var hasCompletedOnboarding: Bool     // Persisted to UserDefaults
var promptStore: PromptStore?                   // Set by ContentView — provides fallback drafting prompt

func buildSystemPrompt() -> String              // Returns style-aware or PromptStore fallback prompt
func recordExample(aiDraft: String, userFinal: String, platform: String,
                   userInstructions: String? = nil, formality: String? = nil)  // Saves training pair
func shouldRefineNow() -> Bool                   // Graduated refinement scheduling
func regenerateStyleSummary(auth: AuthCredential) async // Recency-weighted Sonnet refinement (last 20 examples)
func importBulkSamples(rawText: String, auth: AuthCredential) async throws -> String  // Onboarding
func completeOnboarding()                        // Sets hasCompletedOnboarding = true
```

## Initialization

`init()` reads `hasCompletedOnboarding` from UserDefaults, creates the App Support directory if missing, and calls `loadStyleFile()` which reads `style.md` from disk and counts existing examples by splitting on `"### Example"` to restore `exampleCount` across app relaunches.

## Storage

- **Style data:** `~/Library/Application Support/Draft/style.md`
- **Onboarding flag:** `UserDefaults` key `"style-onboarding-completed"`
- **User's name:** `UserDefaults` key `"user-display-name"` (set during onboarding, used for vision extraction and bulk analysis)
- **Format:** Markdown with structured sections, written atomically on every change

## Error Handling

Both `saveStyleFile()` and `loadStyleFile()` use `do/catch` with `print("⚠️ STYLE | ...")` for debug log visibility, plus `EventReporter.shared.capture()` for structured observability:
- `saveStyleFile()` — logs to print and reports `style_file_write_failed` (level: error)
- `loadStyleFile()` — reports `style_file_read_failed` (level: warning) via EventReporter (no print, since the file may legitimately not exist yet)
- `regenerateStyleSummary()` — prints warning and reports `style_refinement_failed` (level: error) on Sonnet call failure

## Verification

After modifying StyleEngine, verify with these checks:

- **Training pair saved:** Accept a draft → open `~/Library/Application Support/Draft/style.md` → new `### Example N` should have `AI_DRAFT`, `USER_SENT`, `PLATFORM`, `EDIT_DISTANCE`
- **Edit detection:** Edit a draft before accepting → `AI_DRAFT` should differ from `USER_SENT`, edit distance > 0
- **No-edit detection:** Accept without editing → `AI_DRAFT` equals `USER_SENT`, edit distance = 0 (or near 0)
- **Graduated frequency:** Check debug log for `🔄 STYLE | refinement triggered at N examples` — should fire at 3, 6, 9... (early) then 10, 20... (stabilized)
- **Recency window:** During refinement, only the last 20 examples should be sent to Sonnet (check prompt size in console if debugging)
- **Onboarding:** Reset with `defaults delete com.justinbetker.draft style-onboarding-completed` → relaunch → onboarding should appear. After completing, style.md should have profile but NO raw pasted text
- **Debug monitoring:** `tail -f ~/draft-debug.log | grep STYLE` shows all style events in real time
- **Inspect style.md directly:** `cat ~/Library/Application\ Support/Draft/style.md` to see current profile + examples
