# Style Learning Engine

## What This Does

Learns the user's writing style through training pairs (AI draft vs. what the user actually sent) and incrementally refines a style profile that personalizes how Haiku drafts messages. Includes a first-launch onboarding flow for instant profile generation.

## Key File

- `StyleEngine.swift` — `@MainActor ObservableObject` managing style.md, training pair collection, incremental refinement, and onboarding state

## How It Works

### Onboarding (First Launch)

Solves the **cold start problem** — without onboarding, the first 10+ drafts are generic because Draft doesn't know how you write yet.

1. After API key entry, `StyleOnboardingView` appears (gated by `hasCompletedOnboarding`)
2. User pastes real writing samples (Slack messages, texts, emails — messy is fine)
3. `importBulkSamples()` sends samples to **Sonnet** with a specialized `bulkAnalysisPrompt`
4. Sonnet returns a comprehensive 400-600 word style profile analyzing 10 dimensions
5. **Only the generated profile is saved** — raw samples are discarded after analysis
6. User can review, add more samples and regenerate, or accept
7. "Skip for Now" is always available — the incremental system works without onboarding

### Training Pair Collection

Every time the user accepts a draft (Copy or "Paste to Source App"), `recordExample()` saves a **training pair**:
- `AI_DRAFT` — what the AI produced (snapshotted from `DraftEngine.originalDraft`)
- `USER_SENT` — what the user actually sent (may be edited version)
- `PLATFORM` — detected from the target app (slack/imessage/email/etc.)
- `EDIT_DISTANCE` — word-overlap ratio (0 = identical, 1 = completely different)

The diff between AI_DRAFT and USER_SENT is the core learning signal — it reveals exactly where the style profile is wrong.

### Graduated Refinement

Refinement frequency adapts based on example count and profile quality:

- **Examples 1-20:** Refine every **3** accepted drafts (early learning phase — each data point matters)
- **Examples 21+, avg edit distance < 0.25:** Refine every **10** (profile is working well — user barely edits)
- **Examples 21+, avg edit distance ≥ 0.25:** Refine every **5** (still learning — something's off)

`shouldRefineNow()` encapsulates this logic. It reads the last 10 edit distances from style.md to determine which phase the profile is in.

### Recency-Weighted Refinement

`regenerateStyleSummary()` sends only the **last 20 examples** to Sonnet (via `extractRecentExamplesText(last:)`), not all accumulated history. Early examples were recorded when the profile was poor — those lessons are already encoded in the profile. Sending stale examples wastes tokens and adds noise.

### Incremental (Not Rebuild)

Sonnet gets the current profile + recent training pairs with a refinement prompt:

- **Has existing profile:** "Here's the current profile. Here are training pairs showing what the AI got wrong. Fix the profile based on these patterns."
- **No existing profile:** "Build a profile from these training pairs. The USER_SENT versions are ground truth."

The profile gets surgically adjusted based on actual errors, not reconstructed. The profile can't regress because Sonnet is told to preserve what's working.

### Application

`buildSystemPrompt()` extracts only the Style Summary section (not examples) and wraps it in ghostwriting instructions. Tells Haiku to embody the user's voice — use their vocabulary, mirror their rhythms, match their energy.

### Cost Model

Only the Style Summary is injected into the system prompt, not training pairs. Drafting cost stays constant regardless of example count. Refinement frequency decreases as the profile improves (every 3 → every 5 → every 10), and only the last 20 examples are sent to Sonnet per refinement.

## File Format (style.md)

```markdown
# Writing Style Profile

## Style Summary
[Sonnet-generated structured profile]

## Examples

### Example 1
PLATFORM: slack
EDIT_DISTANCE: 0.42
AI_DRAFT:
Hey Sarah! That sounds great, I'm totally in for lunch tomorrow.

USER_SENT:
hey! yeah totally down for lunch tmrw 👍

### Example 2
PLATFORM: email
EDIT_DISTANCE: 0.05
AI_DRAFT:
Thanks for sending this over, I'll review it this afternoon.

USER_SENT:
Thanks for sending this over — I'll review it this afternoon.
```

No onboarding samples section — raw pastes are discarded after initial profile generation.

## Public Interface

```swift
@Published var exampleCount: Int
@Published var styleFileContents: String
@Published var hasCompletedOnboarding: Bool     // Persisted to UserDefaults

func buildSystemPrompt() -> String              // Returns style-aware or default prompt
func recordExample(aiDraft: String, userFinal: String, platform: String)  // Saves training pair
func shouldRefineNow() -> Bool                   // Graduated refinement scheduling
func regenerateStyleSummary(apiKey: String) async // Recency-weighted Sonnet refinement (last 20 examples)
func importBulkSamples(rawText: String, apiKey: String) async throws -> String  // Onboarding
func completeOnboarding()                        // Sets hasCompletedOnboarding = true
```

## Storage

- **Style data:** `~/Library/Application Support/Draft/style.md`
- **Onboarding flag:** `UserDefaults` key `"style-onboarding-completed"`
- **User's name:** `UserDefaults` key `"user-display-name"` (set during onboarding, used for vision extraction too)
- **Format:** Markdown with structured sections, written atomically on every change

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
