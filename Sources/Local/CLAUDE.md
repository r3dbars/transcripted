# Local Inference Layer

## What This Does

Provides fully on-device LLM inference and vision OCR, eliminating all external API dependencies. MLXEngine wraps mlx-swift-lm for text generation (streaming and non-streaming). LocalInferenceManager handles model lifecycle (download, load, state tracking). LocalVisionExtractor uses Apple Vision framework for OCR-based context extraction from screenshots. All inference runs on Apple Silicon via Metal -- no network calls, no API keys.

## Key Files

- `MLXEngine.swift` (120 lines) -- Swift actor wrapping mlx-swift-lm for local Qwen3.5-4B-4bit inference. Provides both streaming (`generate()`) and non-streaming (`complete()`) generation.
- `LocalInferenceManager.swift` (74 lines) -- `@MainActor ObservableObject` that owns the MLXEngine instance, tracks model state (not loaded / downloading / loading / ready / failed), and reports download progress.
- `LocalVisionExtractor.swift` (81 lines) -- Stateless enum using Apple Vision `VNRecognizeTextRequest` for OCR. Extracts text from screenshots and returns it as a `CapturedContext` for the drafting model to interpret directly.
- `LocalLLMError.swift` (24 lines) -- `LocalizedError` enum with 6 error cases covering model loading, generation, context overflow, cancellation, and download failures.

## How MLXEngine Works

### Actor Isolation

MLXEngine is a Swift `actor`, not a class. All mutable state (`container`, `isLoaded`) is actor-isolated. Callers must `await` all methods. This prevents data races when multiple consumers (DraftSessionController, StyleEngine, AnalysisEngine) call into the same engine concurrently.

### Model Identity

Uses `mlx-community/Qwen3.5-4B-4bit` from HuggingFace. The model is downloaded on first use (~2.5GB) and cached at `~/Library/Caches/models/mlx-community/Qwen3.5-4B-4bit/`. The static `isModelCached` property checks for this directory without loading anything.

### Input Preparation

`prepareInput()` (private) handles the shared setup for both generation paths:

1. Builds `Chat.Message` array (optional system message + user message)
2. Creates `UserInput` with `additionalContext = ["enable_thinking": false]` -- Qwen3.5 defaults to thinking mode which produces `<think>` blocks; disabling it gives direct responses
3. Calls `container.prepare(input:)` to tokenize
4. Returns the prepared `LMInput` + `GenerateParameters`

### Two Generation Modes

**Non-streaming (`complete()`):** Collects all tokens into a string and returns the full result. Used by AnalysisEngine and StyleEngine where streaming is unnecessary.

**Streaming (`generate()`):** Returns `AsyncThrowingStream<String, Error>` that yields tokens one at a time. Used by DraftSessionController for real-time overlay display (~30-50 tok/s on Apple Silicon). Wraps an internal `Task` that iterates the MLX generation stream.

Both modes check `Task.isCancelled` on every token and throw `LocalLLMError.cancelled` for cooperative cancellation.

### Lifecycle

- `load(progressHandler:)` -- Downloads (if needed) and loads the model. The progress handler fires during download with `fractionCompleted`. Idempotent (guarded by `isLoaded`).
- `unload()` -- Nils the container and resets `isLoaded`. Called during app shutdown via `LocalInferenceManager.cleanup()`.

## How LocalInferenceManager Works

### Model State Machine

```
notLoaded --> downloading(progress) --> ready
notLoaded --> loading --> ready
any state --> failed(reason)
```

- If the model is already cached (`MLXEngine.isModelCached`), jumps directly to `.loading` (skip download UI)
- If not cached, starts at `.downloading(progress: 0)` and updates progress via the `load()` callback
- On success: `.ready`. On failure: `.failed(reason)`.

### Observable Properties

- `@Published modelState: ModelState` -- drives UI (menubar status label, download progress)
- `isReady: Bool` -- convenience check for `.ready` state
- `statusLabel: String` -- human-readable status for display ("Downloading model (42%)...", "Ready", etc.)

### Engine Ownership

Owns a single `MLXEngine` instance (`draftEngine`) shared across all consumers. DraftSessionController, StyleEngine, AnalysisEngine, and ChatEngine all access the same engine through `appState.localInference.draftEngine`.

### EventReporter Integration

Logs `model_loaded` (info) on success and `model_load_failed` (error) on failure to `events.jsonl`.

## How LocalVisionExtractor Works

### Apple Vision OCR Pipeline

1. Converts `Data` to `NSImage` to `CGImage`
2. Creates `VNRecognizeTextRequest` with `.accurate` recognition level and language correction enabled
3. Sorts recognized text observations by vertical position (top to bottom), then horizontal (left to right) -- Vision uses bottom-left origin so Y is inverted
4. Joins top candidates into newline-separated text

### Truncation Logic

Long OCR output is truncated to fit within the local model's context window:

- If total text exceeds `DraftConstants.ocrMaxCharacters`: keep the first `DraftConstants.ocrHeaderCharacters` (app chrome, title bar) + last `DraftConstants.ocrRecentCharacters` (recent messages), joined with `\n...\n`
- This preserves both the platform/recipient context from the header and the most recent conversation turns

### No LLM Post-Processing

Unlike the previous Haiku Vision approach, LocalVisionExtractor does NOT run the OCR text through an LLM for structured extraction. The raw OCR text is set directly as `context.conversation` on a `CapturedContext`, and the drafting model interprets it inline. Platform and formality detection happen separately via `PlatformFormatter` using the source app's bundle ID.

## LocalLLMError Cases

| Case | When | Used By |
|------|------|---------|
| `modelNotFound(String)` | Model path doesn't exist | Reserved for future use |
| `modelLoadFailed(String)` | HuggingFace download or MLX load fails | LocalInferenceManager |
| `generationFailed(String)` | Container is nil or generation throws | MLXEngine |
| `contextOverflow` | Input exceeds model context window | Reserved for future use |
| `cancelled` | `Task.isCancelled` detected during generation | MLXEngine |
| `downloadFailed(String)` | Network error during model download | Reserved for future use |

## Public Interface

```swift
// MLXEngine (actor)
nonisolated static var isModelCached: Bool
func load(progressHandler: (@Sendable (Double) -> Void)?) async throws
func unload()
var modelLoaded: Bool { get }
func complete(prompt:systemPrompt:maxTokens:temperature:) async throws -> String
func generate(prompt:systemPrompt:maxTokens:temperature:) -> AsyncThrowingStream<String, Error>

// LocalInferenceManager (@MainActor ObservableObject)
@Published var modelState: ModelState
let draftEngine: MLXEngine
var isReady: Bool
var statusLabel: String
func initialize() async
func cleanup()

// LocalVisionExtractor (stateless enum)
static func extractContext(imageData: Data) async throws -> CapturedContext

// ModelState (enum, Equatable)
case notLoaded
case downloading(progress: Double)
case loading
case ready
case failed(String)

// LocalLLMError (enum, LocalizedError)
case modelNotFound(String)
case modelLoadFailed(String)
case generationFailed(String)
case contextOverflow
case cancelled
case downloadFailed(String)
```

## Dependencies

- `MLXLLM` / `MLXLMCommon` -- mlx-swift-lm framework for model loading and generation
- `Vision` -- Apple Vision framework for OCR (`VNRecognizeTextRequest`)
- `AppKit` -- `NSImage` for image conversion in OCR pipeline
- `CapturedContext` (from Capture/) -- struct populated by LocalVisionExtractor
- `DraftConstants` (root) -- OCR truncation limits
- `EventReporter` (from Observability/) -- structured event logging

## Critical Gotchas

- **Thinking mode must be disabled** -- Qwen3.5 defaults to thinking mode which produces `<think>...</think>` blocks before the actual response. Setting `userInput.additionalContext = ["enable_thinking": false]` suppresses this. Without it, drafts contain visible thinking traces.
- **Metal shader placement** -- `mlx.metallib` must be placed next to the binary at `Contents/MacOS/`. MLX searches for shaders colocated with the executable first. If missing, inference fails silently or crashes.
- **First-launch download is ~2.5GB** -- The model downloads from HuggingFace on first use. `LocalInferenceManager` tracks progress for UI display. Subsequent launches load from cache (fast).
- **Actor isolation means all calls are async** -- Every call to MLXEngine requires `await`. Callers on `@MainActor` must use `Task { }` or be in an async context.
- **`container!` force-unwrap is safe** -- In both `complete()` and `generate()`, the force-unwrap of `container` is preceded by `prepareInput()` which guards `container != nil` and throws `generationFailed` if nil.

## Verification

After modifying any file in this folder:

```bash
bash build.sh && bash run-tests.sh
```

- **Model load:** Launch app -> check menubar status shows "Ready" (or download progress on first run)
- **Streaming draft:** Option+D -> speak -> Option+D -> verify tokens appear in overlay one at a time
- **Non-streaming:** Accept a draft -> check that style refinement completes (uses `complete()`)
- **OCR extraction:** Option+D over a conversation -> check debug log for extracted text
- **Error handling:** Kill network during first download -> verify `.failed` state in menubar, not a crash
