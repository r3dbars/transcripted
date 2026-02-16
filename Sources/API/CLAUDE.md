# API Layer

## What This Does

Handles communication with the Anthropic Messages API (text drafting + vision context extraction) and secure storage of the API key in macOS Keychain.

## Key Files

- `AnthropicAPI.swift` — URLSession-based HTTP client for Claude (text + vision)
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

### Models

- **Haiku** (`claude-haiku-4-5-20251001`) — Default for text drafting and vision extraction. Fastest/cheapest, ideal where latency matters.
- **Sonnet** (`claude-sonnet-4-20250514`) — Used for style analysis (deeper reasoning needed for writing profiles). Exposed as `AnthropicAPI.sonnetModel` so other components can reference it.

### Two API Modes

**Text Drafting** (`draft()`): Uses `Codable` structs. Supports optional `systemPrompt` override (for style-aware drafting), configurable `maxTokens` (default 1024, style analysis uses 4096), and optional `useModel` parameter to override the default Haiku model (used by StyleEngine for Sonnet-powered analysis).

**Vision Context Extraction** (`extractStructuredContext()`): Uses `JSONSerialization` because vision content is a mixed-type array (image + text blocks). Sends base64 PNG screenshot. Accepts optional `userName` (for identity-aware extraction — "which messages are mine?") and `appName` (passed from the OS so Haiku doesn't misidentify the platform). Returns a `CapturedContext` struct parsed from plain-text labeled sections.

### Vision Extraction Flow

1. Screenshot PNG → base64 encoded
2. Sent to Haiku with a prompt asking for plain-text labeled format:
   ```
   PLATFORM: [slack/email/imessage/discord/teams/other]
   TALKING TO: [name from conversation header/title bar]
   FORMALITY: [casual/professional/formal]

   CONVERSATION:
   [Sender]: [message]
   [Other Sender]: [message]
   ...
   ```
3. Raw text response → `CapturedContext.parse(from:)` splits into struct fields
4. No JSON involved — simpler and handles variable-length conversations

### Vision Prompt Design (Hard-Won Knowledge)

- **App name hint**: Pass the actual OS app name (e.g., "Messages") so Haiku doesn't guess wrong from UI chrome alone
- **Sidebar noise**: Prompt explicitly says "ignore sidebars, contact lists, channel lists, notification badges" — focus on the main conversation panel
- **"Talking To" confusion**: Haiku will pick up names mentioned *inside* messages and report them as the conversation partner. The prompt must say "look at the conversation HEADER or TITLE BAR, NOT names mentioned in message text"

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
static let sonnetModel: String  // "claude-sonnet-4-20250514"

static func draft(
    rawText: String,
    apiKey: String,
    systemPrompt: String? = nil,
    maxTokens: Int = 1024,
    useModel: String? = nil        // Override default Haiku model
) async throws -> String

static func extractStructuredContext(
    imageData: Data,
    apiKey: String,
    userName: String? = nil,       // User's name for identity-aware extraction
    appName: String? = nil         // OS app name hint for platform detection
) async throws -> CapturedContext

// KeychainHelper
static func save(key: String, value: String) -> Bool
static func load(key: String) -> String?
static func delete(key: String) -> Bool
```

## Verification

After modifying AnthropicAPI, verify with these checks:

- **Text drafting:** Type text in input → hit Draft → check debug log for `✅ DRAFTED` with character count
- **Vision extraction:** Press ⌃⌥D over a messaging app → check console for `🔍 VISION RAW RESPONSE` showing the labeled sections (PLATFORM/TALKING TO/FORMALITY/CONVERSATION)
- **Style refinement:** Accept 3 drafts → check for `🔄 STYLE | refinement triggered` in debug log (confirms Sonnet calls work)
- **Error handling:** Temporarily break the API key → verify the UI shows an error message, not a crash
- **Model selection:** Drafting should use Haiku (fast), style analysis should use Sonnet — check the `model` field in console output
