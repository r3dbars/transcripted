# API Layer

## What This Does

Handles communication with the Anthropic Messages API (text drafting + vision context extraction) and secure storage of the API key in macOS Keychain.

## Key Files

- `AnthropicAPI.swift` — URLSession-based HTTP client for Claude Haiku (text + vision)
- `KeychainHelper.swift` — Simple Keychain wrapper (save/load/delete)

## Anthropic API Details

### No Official Swift SDK

Anthropic provides SDKs for Python, TypeScript, Java, etc. — but NOT Swift. We use raw `URLSession` with `Codable` structs for text, and `JSONSerialization` for vision (mixed-type content arrays).

### Endpoint & Auth

- **URL:** `https://api.anthropic.com/v1/messages`
- **Method:** POST
- **Required headers:**
  - `x-api-key: <your-key>` (NOT Bearer token)
  - `anthropic-version: 2023-06-01`
  - `content-type: application/json`

### Model

Currently using `claude-haiku-4-5-20251001`. Fastest/cheapest Claude model — ideal for message polishing and vision extraction where latency matters.

### Two API Modes

**Text Drafting** (`draft()`): Uses `Codable` structs. Supports optional `systemPrompt` override (for style-aware drafting) and configurable `maxTokens` (default 1024, style analysis uses 4096).

**Vision Context Extraction** (`extractContext()`): Uses `JSONSerialization` because vision content is a mixed-type array (image + text blocks). Sends base64 PNG screenshot, returns extracted conversation text.

### Vision Request Format

```json
{
  "model": "claude-haiku-4-5-20251001",
  "max_tokens": 2048,
  "system": "Extract the conversation text...",
  "messages": [{
    "role": "user",
    "content": [
      {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "..."}},
      {"type": "text", "text": "Extract the conversation from this screenshot."}
    ]
  }]
}
```

### Common Error Codes

- **401** — Invalid API key
- **429** — Rate limited
- **500/529** — Server overloaded

## Keychain Storage

- Service name: `com.draft.anthropic-api-key`
- Account key: `anthropic-api-key`
- Uses `SecItemAdd`, `SecItemCopyMatching`, `SecItemDelete`

## Public Interface

```swift
// AnthropicAPI
static func draft(rawText: String, apiKey: String, systemPrompt: String? = nil, maxTokens: Int = 1024) async throws -> String
static func extractContext(imageData: Data, apiKey: String) async throws -> String

// KeychainHelper
static func save(key: String, value: String) -> Bool
static func load(key: String) -> String?
static func delete(key: String) -> Bool
```
