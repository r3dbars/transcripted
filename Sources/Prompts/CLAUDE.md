# Prompts -- PromptStore

## What This Is

`PromptStore` externalizes all system prompts from hardcoded Swift strings into a JSON file at:

```
~/Library/Application Support/Draft/prompts.json
```

## File: PromptStore.swift (~358 lines)

Contains three components:

1. **`PromptConfig`** -- A `Codable` struct that maps 1:1 to the keys in `prompts.json`. Uses `CodingKeys` to translate between Swift camelCase properties and snake_case JSON keys. Has a `static var defaults` factory that pulls from `DefaultPrompts`.

2. **`DefaultPrompts`** -- An enum (no cases) with static constants for every prompt. Also contains a `Tier` enum (`early`, `growing`, `mature`) and a `styleAnalysis(tier:)` method that builds tiered style analysis prompts from a shared base string plus tier-specific sections.

3. **`PromptStore`** -- An `@MainActor ObservableObject` class with `@Published var config: PromptConfig`. Loads `prompts.json` on init, writes defaults to disk if the file is missing or corrupt. Exposes `let storageDir: URL` (the app support directory) for use by other engines. Uses `FileManager.default.draftAppSupportDir` (an extension defined elsewhere) for the base path.

## Why

Prompts are now editable without recompiling. The native `AnalysisEngine` (in `Sources/Analysis/`) reads `feedback.jsonl` and can rewrite `prompts.json` to improve drafting quality based on user accept/edit/reject signals.

## Keys in prompts.json

| Key | Used by | Placeholders |
|-----|---------|-------------|
| `model` | **Vestigial** -- no longer determines which model is used | -- |
| `draft_model` | **Vestigial** -- no longer determines which model is used | -- |
| `drafting_system` | DraftEngine fallback when no style examples yet | -- |
| `context_extraction` | **Vestigial** -- vision now uses Apple Vision OCR (VNRecognizeTextRequest), not an LLM | `{USER_NAME}`, `{APP_NAME}` |
| `ghostwriting_system` | Main drafting prompt with style profile (used by MLXEngine) | `{STYLE_SUMMARY}` |
| `style_analysis_early` | Style analysis with < 10 examples (used by MLXEngine) | -- |
| `style_analysis_growing` | Style analysis with 10-19 examples (used by MLXEngine) | -- |
| `style_analysis_mature` | Style analysis with 20+ examples (used by MLXEngine) | -- |

### Vestigial Keys

The `model`, `draft_model`, and `context_extraction` keys remain in `prompts.json` from the API era but are no longer functionally used:

- **`model` and `draft_model`**: The actual model is determined by `MLXEngine.modelId` (`mlx-community/Qwen3.5-4B-4bit`), which is hardcoded in `Sources/Local/MLXEngine.swift`. These JSON keys are ignored at runtime.
- **`context_extraction`**: Vision/OCR now uses Apple's `VNRecognizeTextRequest` via `LocalVisionExtractor`, not an LLM vision prompt. The key is preserved for backward compatibility but its value is not read.

## Placeholders

- `{STYLE_SUMMARY}` -- replaced at runtime by `PromptStore.ghostwritingPrompt(styleSummary:)` with the user's style profile from style.md
- `{USER_NAME}` -- replaced by `PromptStore.contextExtractionPrompt(userName:appName:)` (vestigial -- this method is no longer called in the active path)
- `{APP_NAME}` -- replaced with the source app name (vestigial -- same as above)

**Important**: The analysis engine must preserve these placeholders when rewriting prompts.

## Public Methods

| Method | Purpose |
|--------|---------|
| `reload()` | Re-reads `prompts.json` from disk. Call after the analysis engine rewrites prompts. |
| `ghostwritingPrompt(styleSummary:)` | Returns `ghostwritingSystem` with `{STYLE_SUMMARY}` replaced. Used by the active drafting path. |
| `styleAnalysisPrompt(forExampleCount:)` | Returns the appropriate tiered prompt: `early` (< 10 examples), `growing` (10-19), or `mature` (>= 20). Used by StyleEngine via MLXEngine. |
| `contextExtractionPrompt(userName:appName:)` | Vestigial -- was used for LLM-based vision extraction. Vision now uses Apple Vision OCR. |

## Fallbacks

If `prompts.json` is missing or corrupt, `PromptStore` initializes with hardcoded defaults from `DefaultPrompts` (defined in `PromptStore.swift`) and writes them to disk via a private static `write(config:to:)` helper. Individual engines also carry last-resort fallbacks -- the app never crashes due to missing prompts.

## Updating Prompts

1. **Manual**: Edit `prompts.json` directly and call `promptStore.reload()` (or restart the app).
2. **Automated**: The native `AnalysisEngine` rewrites `prompts.json`. The app picks up changes on next launch or explicit reload.

## Model Selection

All inference runs on-device via MLXEngine using the `mlx-community/Qwen3.5-4B-4bit` model (~30-50 tok/s on Apple Silicon). The model is determined by `MLXEngine.modelId` in `Sources/Local/MLXEngine.swift`, not by any key in `prompts.json`.

The `model` and `draft_model` keys in `prompts.json` are vestigial from when the app used the Anthropic API with separate models for different tasks (e.g., Haiku for vision, Sonnet for drafting). They are no longer read at runtime. To change the model, update `MLXEngine.modelId` in Swift source and rebuild.
