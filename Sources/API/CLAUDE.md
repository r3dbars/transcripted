# API Layer

## What This Does

Handles communication with the Anthropic Messages API and secure storage of the API key in macOS Keychain.

## Key Files

- `AnthropicAPI.swift` — URLSession-based HTTP client for Claude Haiku
- `KeychainHelper.swift` — Simple Keychain wrapper (save/load/delete)

## Anthropic API Details

### No Official Swift SDK

Anthropic provides SDKs for Python, TypeScript, Java, etc. — but NOT Swift. We use raw `URLSession` with `Codable` structs. Zero dependencies.

### Endpoint & Auth

- **URL:** `https://api.anthropic.com/v1/messages`
- **Method:** POST
- **Required headers:**
  - `x-api-key: <your-key>` (NOT Bearer token)
  - `anthropic-version: 2023-06-01`
  - `content-type: application/json`

### Model

Currently using `claude-haiku-4-5-20251001`. This is the fastest/cheapest Claude model — ideal for message polishing where latency matters.

### Request Format

```json
{
  "model": "claude-haiku-4-5-20251001",
  "max_tokens": 1024,
  "system": "You are a writing assistant...",
  "messages": [{"role": "user", "content": "rough text here"}]
}
```

### Response Format

```json
{
  "id": "msg_...",
  "content": [{"type": "text", "text": "polished text"}],
  "stop_reason": "end_turn"
}
```

Extract text from `content[0].text`.

### Common Error Codes

- **401** — Invalid API key
- **429** — Rate limited
- **500/529** — Server overloaded

## Keychain Storage

- Service name: `com.draft.anthropic-api-key`
- Account key: `anthropic-api-key`
- Uses `SecItemAdd`, `SecItemCopyMatching`, `SecItemDelete`
- Requires `-framework Security` in build.sh

### Why Keychain Over UserDefaults

UserDefaults stores as plain XML plist — readable by any process. Keychain encrypts at rest using the user's login credentials. API keys should always use Keychain on macOS.

## Public Interface

```swift
// AnthropicAPI
static func draft(rawText: String, apiKey: String) async throws -> String

// KeychainHelper
static func save(key: String, value: String) -> Bool
static func load(key: String) -> String?
static func delete(key: String) -> Bool
```
