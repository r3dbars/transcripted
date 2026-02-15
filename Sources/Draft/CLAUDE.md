# Draft Engine

## What This Does

Orchestrates the "rough text → polished message" workflow. Connects the speech capture (input) to the Anthropic API (processing) and exposes the result for the UI.

## Key File

- `DraftEngine.swift` — `@MainActor ObservableObject` managing API key state, drafting workflow, and output

## How It Works

1. On launch, checks Keychain for API key via `hasAPIKey`
2. When user taps "Draft", calls `draftMessage(from:)` which:
   - Loads API key from Keychain
   - Sets `isDrafting = true`
   - Calls `AnthropicAPI.draft()` async
   - Stores result in `draftedText` or error message in `error`
   - Sets `isDrafting = false`

## Public Interface

```swift
@Published var draftedText: String    // Haiku's polished output
@Published var isDrafting: Bool       // Loading state
@Published var error: String?         // Error message if API fails

var hasAPIKey: Bool                   // Whether Keychain has a key stored

func saveAPIKey(_ key: String) -> Bool
func clearAPIKey()
func draftMessage(from rawText: String)
func clear()
```

## Dependencies

- `AnthropicAPI` (from API/)
- `KeychainHelper` (from API/)

## Design Notes

DraftEngine is intentionally separate from SpeechEngine. They don't know about each other — the UI coordinates them. This keeps speech capture independent from the drafting feature, so either can be modified without affecting the other.
