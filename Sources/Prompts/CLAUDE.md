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
| `model` | All API calls — change model here | — |
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

The `model` key in `prompts.json` controls which model is used for drafting and vision extraction (default: `claude-haiku-4-5-20251001`). Style refinement always uses Sonnet (`claude-sonnet-4-20250514`) regardless of this setting — it needs deeper reasoning.
