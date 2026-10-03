import Testing
@testable import TranscriptedWritingCore

/// `llama-completion-timing` logs llama-server's prompt-cache counts. Those
/// keys keep whole numbers and redact anything else, like every other
/// count field.
@Suite("Diagnostics prompt-cache keys")
struct DiagnosticsPromptCacheKeyTests {
    @Test("cache_n and prompt_n keep integers", arguments: ["cache_n", "prompt_n"])
    func keepsIntegers(_ key: String) {
        #expect(DiagnosticsMetadataRedactor.logSafeField(forKey: key, value: "276") == "\(key)=276")
        #expect(DiagnosticsMetadataRedactor.logSafeField(forKey: key, value: "0") == "\(key)=0")
    }

    @Test("cache_n and prompt_n redact anything that isn't a count", arguments: ["cache_n", "prompt_n"])
    func redactsText(_ key: String) {
        #expect(DiagnosticsMetadataRedactor.logSafeField(forKey: key, value: "hello there") == "\(key)=String(11 chars)")
        #expect(DiagnosticsMetadataRedactor.logSafeField(forKey: key, value: "-5") == "\(key)=String(2 chars)")
    }
}
