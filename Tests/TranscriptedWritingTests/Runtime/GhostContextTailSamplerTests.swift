import Testing
@testable import TranscriptedKeyboard
@testable import TranscriptedWritingCore

@Suite("Ghost context tail sampler")
struct GhostContextTailSamplerTests {
    @Test("A field that never reports host text never resets, however much is typed")
    func noHostTextNeverResets() {
        var sampler = GhostContextTailSampler(limit: 3_000)
        var resets = 0
        for _ in 0..<4_000 {
            if sampler.record("") { resets += 1 }
            if sampler.record(nil) { resets += 1 }
        }
        #expect(resets == 0)
        #expect(sampler.lastTail.isEmpty)
    }

    @Test("Typing at the edge never resets, including non-ASCII text")
    func appendsNeverReset() {
        var sampler = GhostContextTailSampler(limit: 3_000)
        var text = ""
        var resets = 0
        for character in String(repeating: "It’s a café — naïve 👋🏽 text. ", count: 40) {
            text.append(character)
            if sampler.record(text) { resets += 1 }
        }
        #expect(resets == 0)
    }

    @Test("Skipping intermediate samples while typing doesn't make a reset")
    func droppedAppendSamplesNeverReset() {
        var sampler = GhostContextTailSampler(limit: 3_000)
        let full = String(repeating: "Notes from the planning thread, ", count: 30)
        var resets = 0
        for end in stride(from: 12, through: full.count, by: 97) {
            if sampler.record(String(full.prefix(end))) { resets += 1 }
        }
        #expect(resets == 0)
    }

    @Test("A wholesale change of host text resets exactly once")
    func wholesaleChangeResetsOnce() {
        var sampler = GhostContextTailSampler(limit: 3_000)
        do { let didReset = sampler.record("Hey, are we still on for lunch tomorrow?"); #expect(!didReset) }
        do { let didReset = sampler.record("Quarterly numbers are attached below"); #expect(didReset) }
        do { let didReset = sampler.record("Quarterly numbers are attached below for"); #expect(!didReset) }
    }

    @Test("Same answers as the reset detector on the same samples")
    func matchesDetector() {
        let samples = [
            "", "short", "Hey, are we still on for lunch?", "Hey, are we still on for lunch? Yes",
            "Totally different conversation here", "Totally", "naïve café résumé text ok",
        ]
        var sampler = GhostContextTailSampler(limit: 3_000)
        var previous = ""
        for sample in samples {
            let didReset = sampler.record(sample)
            #expect(didReset == ContextResetDetector.isReset(previous: previous, current: sample))
            previous = sample
        }
    }

    @Test("A secure or caretless sample clears the tail without reporting")
    func nilSampleClearsTail() {
        var sampler = GhostContextTailSampler(limit: 3_000)
        _ = sampler.record("Hey, are we still on for lunch tomorrow?")
        do { let didReset = sampler.record(nil); #expect(!didReset) }
        #expect(sampler.lastTail.isEmpty)
        // After a cleared tail, the next host text is a fresh start, not a reset.
        do { let didReset = sampler.record("Quarterly numbers are attached below"); #expect(!didReset) }
    }

    @Test("The tail keeps only the last `limit` characters")
    func tailIsBounded() {
        var sampler = GhostContextTailSampler(limit: 20)
        _ = sampler.record(String(repeating: "abcdefghij", count: 5) + "é")
        #expect(sampler.lastTail.count == 20)
        #expect(sampler.lastTail.hasSuffix("é"))
    }
}

@Suite("Ghost calm reveal cache")
struct GhostCalmRevealCacheTests {
    final class LookupCounter {
        var calls = 0
        var electron: Set<String>
        init(electron: Set<String>) { self.electron = electron }
    }

    private func makeCache(_ counter: LookupCounter) -> GhostCalmRevealCache {
        GhostCalmRevealCache(lookupHasElectronFramework: { bundleIdentifier in
            counter.calls += 1
            return counter.electron.contains(bundleIdentifier)
        })
    }

    @Test("Chromium browsers are calm with no lookup")
    func chromiumNeedsNoLookup() {
        let counter = LookupCounter(electron: [])
        let cache = makeCache(counter)
        for id in ["com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac",
                   "com.brave.Browser", "company.thebrowser.Browser", "com.openai.atlas",
                   "com.vivaldi.Vivaldi", "com.operasoftware.Opera"] {
            #expect(cache.usesCalmReveal(for: id))
        }
        #expect(counter.calls == 0)
    }

    @Test("Each other app is looked up once until invalidated")
    func cachedUntilInvalidated() {
        let counter = LookupCounter(electron: ["com.tinyspeck.slackmacgap"])
        let cache = makeCache(counter)
        #expect(cache.usesCalmReveal(for: "com.tinyspeck.slackmacgap"))
        #expect(cache.usesCalmReveal(for: "com.tinyspeck.slackmacgap"))
        #expect(counter.calls == 1)

        counter.electron = []
        cache.invalidate()
        #expect(!cache.usesCalmReveal(for: "com.tinyspeck.slackmacgap"))
        #expect(counter.calls == 2)
    }

    @Test("Empty bundle identifiers are never calm and never looked up")
    func emptyBundle() {
        let counter = LookupCounter(electron: [""])
        #expect(!makeCache(counter).usesCalmReveal(for: ""))
        #expect(counter.calls == 0)
    }

    @Test("Answers match the reveal policy for a table of hosts")
    func matchesPolicy() {
        let electron: Set<String> = ["com.tinyspeck.slackmacgap", "com.microsoft.VSCode", "com.openai.codex"]
        let cache = makeCache(LookupCounter(electron: electron))
        for id in ["com.apple.mail", "com.apple.Notes", "com.google.Chrome", "com.microsoft.VSCode",
                   "com.tinyspeck.slackmacgap", "com.openai.codex", "com.apple.Safari", "com.brave.Browser"] {
            #expect(cache.usesCalmReveal(for: id) == SuggestionRevealDelayPolicy.requiresCalmMarkedText(
                bundleIdentifier: id,
                hasElectronFramework: electron.contains(id)
            ))
        }
    }
}
