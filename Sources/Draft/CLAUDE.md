# Draft Engine

## What This Does

Orchestrates the "rough text → polished message" workflow. Connects the speech capture (input) to the Anthropic API (processing) and exposes the result for the UI. Uses StyleEngine for personalized system prompts.

## Key File

- `DraftEngine.swift` — `@MainActor ObservableObject` managing API key state, drafting workflow, and output

## How It Works

1. On launch, checks Keychain for API key via `hasAPIKey`
2. When user taps "Draft", calls `draftMessage(from:)` which:
   - Loads API key from Keychain
   - Gets personalized system prompt from `styleEngine.buildSystemPrompt()`
   - Sets `isDrafting = true`
   - Calls `AnthropicAPI.draft()` async with the style-aware prompt
   - Stores result in `draftedText` or error message in `error`
   - Sets `isDrafting = false`

## Public Interface

```swift
@Published var draftedText: String    // Haiku's polished output
@Published var isDrafting: Bool       // Loading state
@Published var error: String?         // Error message if API fails
var hasAPIKey: Bool                   // Whether Keychain has a key stored
var styleEngine: StyleEngine?         // Set by ContentView after init

func saveAPIKey(_ key: String) -> Bool
func clearAPIKey()
func getAPIKey() -> String?           // For style summary regeneration
func draftMessage(from rawText: String)
func clear()
```

## Dependencies

- `AnthropicAPI` (from API/)
- `KeychainHelper` (from API/)
- `StyleEngine` (from Style/) — optional reference for personalized prompts

## Design Notes

DraftEngine is intentionally separate from SpeechEngine. They don't know about each other — the UI coordinates them. StyleEngine is injected as an optional reference by ContentView, keeping the dependency lightweight.
