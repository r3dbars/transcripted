# Prompts — PromptStore

## What This Is

`PromptStore` externalizes all system prompts from hardcoded Swift strings into a JSON file at:

```
~/Library/Application Support/Draft/prompts.json
```

## Why

Prompts are now editable without recompiling. The orchestrator agent (a Python service that reads `feedback.jsonl` and rewrites `prompts.json`) can continuously improve drafting quality based on user accept/edit/reject signals.

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
- `{USER_NAME}` — replaced by `PromptStore.contextExtractionPrompt(userName:appName:)` with the user's name or a fallback instruction
- `{APP_NAME}` — replaced with the source app name or a fallback instruction

**Important**: The orchestrator agent must preserve these placeholders when rewriting prompts.

## Fallbacks

If `prompts.json` is missing or corrupt, `PromptStore` initializes with hardcoded defaults from `DefaultPrompts` (defined in `PromptStore.swift`) and writes them to disk. Individual engines also carry last-resort fallbacks — the app never crashes due to missing prompts.

## Updating Prompts

1. **Manual**: Edit `prompts.json` directly and call `promptStore.reload()` (or restart the app).
2. **Automated**: Let the orchestrator agent rewrite `prompts.json`. The app will pick up changes on next launch or explicit reload.

## Model Selection

Two model keys in `prompts.json`:
- `model` — Used for vision extraction and general API calls (default: `claude-haiku-4-5-20251001`)
- `draft_model` — Used for message drafting, the text the user actually sees (default: `claude-sonnet-4-20250514`)

Style refinement and analysis always use Sonnet (`AnthropicAPI.sonnetModel`) regardless of these settings — they need deeper reasoning.
