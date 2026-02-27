# Prompts — PromptStore

## What This Is

`PromptStore` externalizes all system prompts from hardcoded Swift strings into a JSON file at:

```
~/Library/Application Support/Draft/prompts.json
```

## File: PromptStore.swift (~341 lines)

Contains three components:

1. **`PromptConfig`** — A `Codable` struct that maps 1:1 to the keys in `prompts.json`. Uses `CodingKeys` to translate between Swift camelCase properties and snake_case JSON keys. Has a `static var defaults` factory that pulls from `DefaultPrompts`.

2. **`DefaultPrompts`** — An enum (no cases) with static constants for every prompt and both model identifiers. Also contains a `Tier` enum (`early`, `growing`, `mature`) and a `styleAnalysis(tier:)` method that builds tiered style analysis prompts from a shared base string plus tier-specific sections.

3. **`PromptStore`** — An `@MainActor ObservableObject` class with `@Published var config: PromptConfig`. Loads `prompts.json` on init, writes defaults to disk if the file is missing or corrupt. Exposes `let storageDir: URL` (the app support directory) for use by other engines. Uses `FileManager.default.draftAppSupportDir` (an extension defined elsewhere) for the base path.

## Why

Prompts are now editable without recompiling. The native `AnalysisEngine` (in `Sources/Analysis/`) reads `feedback.jsonl` and can rewrite `prompts.json` to improve drafting quality based on user accept/edit/reject signals.

## Keys in prompts.json

| Key | Used by | Placeholders |
|-----|---------|-------------|
| `model` | Vision extraction, style analysis | — |
| `draft_model` | Message drafting (Sonnet — quality output the user sees) | — |
| `drafting_system` | DraftEngine fallback when no style examples yet | — |
| `context_extraction` | Vision prompt for screenshot → conversation | `{USER_NAME}`, `{APP_NAME}` |
| `ghostwriting_system` | Main drafting prompt with style profile | `{STYLE_SUMMARY}` |
| `style_analysis_early` | Style analysis with < 10 examples | — |
| `style_analysis_growing` | Style analysis with 10–19 examples | — |
| `style_analysis_mature` | Style analysis with 20+ examples | — |

## Placeholders

- `{STYLE_SUMMARY}` — replaced at runtime by `PromptStore.ghostwritingPrompt(styleSummary:)` with the user's style profile from style.md
- `{USER_NAME}` — replaced by `PromptStore.contextExtractionPrompt(userName:appName:)` with the user's name (or a fallback: "Identify the user based on which side of the conversation they appear on.")
- `{APP_NAME}` — replaced with the source app name (or a fallback: "Identify which messaging app this is from the UI.")

**Important**: The analysis engine must preserve these placeholders when rewriting prompts.

## Public Methods

| Method | Purpose |
|--------|---------|
| `reload()` | Re-reads `prompts.json` from disk. Call after the analysis engine rewrites prompts. |
| `ghostwritingPrompt(styleSummary:)` | Returns `ghostwritingSystem` with `{STYLE_SUMMARY}` replaced. |
| `styleAnalysisPrompt(forExampleCount:)` | Returns the appropriate tiered prompt: `early` (< 10 examples), `growing` (10-19), or `mature` (>= 20). |
| `contextExtractionPrompt(userName:appName:)` | Returns `contextExtraction` with `{USER_NAME}` and `{APP_NAME}` replaced by descriptive clauses. |

## Fallbacks

If `prompts.json` is missing or corrupt, `PromptStore` initializes with hardcoded defaults from `DefaultPrompts` (defined in `PromptStore.swift`) and writes them to disk via a private static `write(config:to:)` helper. Individual engines also carry last-resort fallbacks — the app never crashes due to missing prompts.

## Updating Prompts

1. **Manual**: Edit `prompts.json` directly and call `promptStore.reload()` (or restart the app).
2. **Automated**: The native `AnalysisEngine` rewrites `prompts.json`. The app picks up changes on next launch or explicit reload.

## Model Selection

Two model keys in `prompts.json`:
- `model` — Used for vision extraction and general API calls (default: `claude-haiku-4-5-20251001`)
- `draft_model` — Used for message drafting, the text the user actually sees (default: `claude-sonnet-4-6-20250514`)

`DefaultPrompts` also exposes these as `DefaultPrompts.model` and `DefaultPrompts.sonnetModel` for use as fallbacks. Style refinement and analysis always use Sonnet (`AnthropicAPI.sonnetModel`) regardless of these settings — they need deeper reasoning.
