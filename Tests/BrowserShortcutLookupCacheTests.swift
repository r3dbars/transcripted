import Foundation

@MainActor
private final class ShortcutResolverGate {
    private(set) var calls = 0
    private var started: [CheckedContinuation<Void, Never>] = []
    private var waiting: [CheckedContinuation<MeetingPromptProvider?, Never>] = []
    private var released = false
    private var answer: MeetingPromptProvider?

    func resolve(_ bundleID: String) async -> MeetingPromptProvider? {
        calls += 1
        let observers = started
        started.removeAll()
        observers.forEach { $0.resume() }
        if released { return answer }
        return await withCheckedContinuation { waiting.append($0) }
    }

    func waitForStart() async {
        if calls > 0 { return }
        await withCheckedContinuation { started.append($0) }
    }

    func release(_ provider: MeetingPromptProvider?) {
        released = true
        answer = provider
        let continuations = waiting
        waiting.removeAll()
        continuations.forEach { $0.resume(returning: provider) }
    }
}

@MainActor
func testBrowserShortcutLookupCache() async {
    await runSuite("Shortcut lookup remembers hits and misses independently without rereading") {
        let cache = BrowserShortcutLookupCache()
        var calls: [String] = []
        let lookup: (String) async -> MeetingPromptProvider? = { id in
            calls.append(id)
            return id == "browser.call" ? .googleMeet : nil
        }
        for _ in 0..<2 {
            let hit = await cache.request("browser.call", resolver: lookup).value
            let miss = await cache.request("browser.other", resolver: lookup).value
            assertEqual(hit, .resolved(.googleMeet))
            assertEqual(miss, .resolved(nil), "a cached miss remains distinct from invalidation")
        }
        assertEqual(calls, ["browser.call", "browser.other"])
        assertEqual(cache.provider(for: "browser.call"), .googleMeet)
        assertNil(cache.provider(for: "browser.other"))
    }

    await runSuite("Overlapping shortcut requests share one resolver and retain the newest activation") {
        let cache = BrowserShortcutLookupCache()
        let gate = ShortcutResolverGate()
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        let first = cache.request("browser.call", activatedAt: early, resolver: gate.resolve)
        await gate.waitForStart()
        let second = cache.request("browser.call", activatedAt: late, resolver: gate.resolve)
        gate.release(.teams)
        let firstResult = await first.value
        let secondResult = await second.value
        assertEqual(firstResult, .resolved(.teams))
        assertEqual(secondResult, .resolved(.teams))
        assertEqual(gate.calls, 1)
        assertEqual(cache.recentActivation?.at, late)
        assertEqual(cache.recentActivation?.provider, .teams)
        let hit = await cache.request("browser.call", activatedAt: late.addingTimeInterval(10), resolver: gate.resolve).value
        assertEqual(hit, .resolved(.teams))
        assertEqual(gate.calls, 1, "a new activation refreshes its timestamp without rereading")
        assertEqual(cache.recentActivation?.at, late.addingTimeInterval(10))
        cache.noteActivation(bundleID: "browser.old", provider: .zoom, at: early)
        assertEqual(cache.recentActivation?.bundleID, "browser.call", "older completions cannot replace a newer activation")
    }

    await runSuite("Termination invalidates an exact shortcut even when another shortcut is most recent") {
        let cache = BrowserShortcutLookupCache()
        let gate = ShortcutResolverGate()
        let old = cache.request("browser.old", activatedAt: Date(timeIntervalSince1970: 100), resolver: gate.resolve)
        await gate.waitForStart()
        cache.noteActivation(bundleID: "browser.current", provider: .teams, at: Date(timeIntervalSince1970: 200))
        cache.invalidate("browser.old")
        let replacement = await cache.request("browser.old", resolver: { _ in .zoom }).value
        gate.release(.googleMeet)
        let stale = await old.value
        assertEqual(replacement, .resolved(.zoom))
        assertEqual(stale, .invalidated)
        assertEqual(cache.provider(for: "browser.old"), .zoom, "a late old result cannot overwrite the restarted app")
        assertEqual(cache.recentActivation?.bundleID, "browser.current")
        cache.invalidate("browser.current")
        assertNil(cache.recentActivation)
        assertNil(cache.provider(for: "browser.current"))
    }

    await runSuite("Stopping shortcut lookup clears hits misses and pending results") {
        let cache = BrowserShortcutLookupCache()
        cache.noteActivation(bundleID: "browser.hit", provider: .zoom, at: Date(timeIntervalSince1970: 100))
        _ = await cache.request("browser.miss", resolver: { _ in nil }).value
        let firstGate = ShortcutResolverGate()
        let secondGate = ShortcutResolverGate()
        let first = cache.request("browser.first", resolver: firstGate.resolve)
        let second = cache.request("browser.second", resolver: secondGate.resolve)
        await firstGate.waitForStart()
        await secondGate.waitForStart()
        cache.removeAll()
        firstGate.release(.googleMeet)
        secondGate.release(.teams)
        let firstResult = await first.value
        let secondResult = await second.value
        assertEqual(firstResult, .invalidated)
        assertEqual(secondResult, .invalidated)
        assertNil(cache.provider(for: "browser.hit"))
        assertNil(cache.provider(for: "browser.first"))
        assertNil(cache.provider(for: "browser.second"))
        assertNil(cache.recentActivation)
        var reread = 0
        let miss = await cache.request("browser.miss", resolver: { _ in reread += 1; return .teams }).value
        assertEqual(miss, .resolved(.teams))
        assertEqual(reread, 1, "stop removes completed misses too")
    }
}
