# API Directory — Gemini + Keychain

## What This Is

Gemini 3 Flash integration for cloud-based drafting, plus secure API key storage. Replaces the local Qwen 3.5-4B model for draft generation and eliminates the Apple Vision OCR step — screenshots are sent directly to Gemini as images.

The local MLX pipeline (`Sources/Local/`) is still used for style refinement, analysis, and onboarding (privacy-sensitive tasks that should stay on-device).

## Key Files

- `GeminiEngine.swift` (~220 lines) — Swift actor wrapping the Gemini REST API. Streaming via SSE (`streamGenerateContent?alt=sse`), multimodal support (inline image parts), API key management via Keychain. Returns `AsyncThrowingStream<String, Error>` matching MLXEngine's interface.
- `KeychainHelper.swift` (~40 lines) — Minimal macOS Keychain wrapper (save/load/delete) using Security framework. Service identifier matches the app's current bundle identifier.
- `BetaConfig.swift` (~25 lines) — `#if BETA_BUILD` gated config: per-user token, proxy URL, app version, update URL. Unrelated to Gemini.

## GeminiEngine

### Actor Isolation

Like MLXEngine, GeminiEngine is a Swift `actor` for thread safety. All generation methods are async. An `isGenerating` flag prevents concurrent requests.

### Two Generation Modes

**Streaming (`generate()`):** Returns `AsyncThrowingStream<String, Error>`. Uses `URLSession.bytes(for:)` to read SSE events line by line. Each `data: {json}` line is parsed and text extracted from `candidates[0].content.parts[0].text`.

**Non-streaming (`complete()`):** Uses `URLSession.data(for:)` with the non-streaming `generateContent` endpoint. Returns the full response as a String.

### Multimodal Image Support

When `imageData: Data?` is provided, the PNG screenshot is base64-encoded and sent as an `inline_data` part in the request body. Gemini sees the full visual context (message bubbles, avatars, emoji, formatting) — richer than OCR text.

### API Key Storage

Static methods wrap `KeychainHelper`:
- `GeminiEngine.hasAPIKey` / `isAvailable` — check if a key exists
- `GeminiEngine.saveAPIKey(_:)` — store in Keychain
- `GeminiEngine.loadAPIKey()` — retrieve from Keychain
- `GeminiEngine.deleteAPIKey()` — remove from Keychain

### SSE Parsing

Gemini's `streamGenerateContent?alt=sse` endpoint returns server-sent events:
```
data: {"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}
data: {"candidates":[{"content":{"parts":[{"text":" there"}]}}]}
```

The parser:
1. Reads lines from `URLSession.bytes(for:).lines`
2. Filters for lines starting with `data: `
3. Parses JSON and extracts text
4. Yields each text chunk to the AsyncThrowingStream continuation

### Error Handling

`GeminiError` enum covers: `noAPIKey`, `networkError`, `apiError(statusCode, message)`, `parseError`, `cancelled`. All conform to `LocalizedError` with descriptive messages.

### Configuration

Constants in `DraftConstants.swift`:
- `geminiBaseURL` — `https://generativelanguage.googleapis.com/v1beta`
- `geminiModel` — `gemini-3-flash`
- `geminiRequestTimeout` — 30 seconds
- `geminiDraftMaxTokens` — 1024

## How Drafting Works (Gemini Path)

```
1. User presses Option+D → screenshot captured synchronously
2. Voice recording starts (no OCR — screenshot saved as sessionImageData)
3. User presses Option+D again → voice stops, transcribed
4. DraftSessionController builds:
   - System prompt: StyleEngine.buildSystemPrompt() + PlatformFormatter.formattingInstructions
   - User message: "Write a reply..." + platform + voice instructions
   - Image: sessionImageData (PNG screenshot)
5. GeminiEngine.generate() called with all three
6. Tokens stream into overlay (same UI path as MLX)
7. User reviews, edits, confirms → paste to target app
```

Key difference from local path: steps 2-4 skip LocalVisionExtractor entirely. Gemini interprets the screenshot visually.

## Public Interface

```swift
// GeminiEngine (actor)
nonisolated static var hasAPIKey: Bool
nonisolated static var isAvailable: Bool
nonisolated static func saveAPIKey(_ key: String)
nonisolated static func loadAPIKey() -> String?
nonisolated static func deleteAPIKey()

func generate(prompt:systemPrompt:imageData:maxTokens:temperature:) -> AsyncThrowingStream<String, Error>
func complete(prompt:systemPrompt:imageData:maxTokens:temperature:) async throws -> String
func cancelGeneration()

// KeychainHelper (stateless enum)
static func save(key: String, data: Data) -> Bool
static func load(key: String) -> Data?
static func delete(key: String)

// GeminiError (enum, LocalizedError)
case noAPIKey
case networkError(String)
case apiError(Int, String)
case parseError(String)
case cancelled
```

## Dependencies

- `Foundation` — URLSession, JSONSerialization
- `Security` — Keychain API (SecItemAdd, SecItemCopyMatching, SecItemDelete)
- `DraftConstants` — API URL, model name, timeouts

## Verification

After modifying files in this directory:

```bash
bash build.sh && bash run-tests.sh
```

- **No API key:** Option+D → speak → Option+D → overlay shows "No Gemini API key — check Settings"
- **With API key:** Option+D → speak → Option+D → tokens stream from Gemini into overlay
- **Invalid key:** API returns 400/401 → overlay shows error message
- **Network down:** URLSession throws → overlay shows "Network error: ..."
- **Settings UI:** Menubar → Settings → paste API key → status turns green → Clear removes it
