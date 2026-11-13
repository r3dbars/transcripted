import Foundation

private final class ScanIdentityReads {
    var answers: [Int: [String?]]
    var calls: [Int] = []

    init(_ answers: [Int: [String?]]) { self.answers = answers }

    func read(_ object: Int) -> String? {
        calls.append(object)
        guard var values = answers[object], !values.isEmpty else { return nil }
        let value = values[0]
        if values.count > 1 { values.removeFirst(); answers[object] = values }
        return value
    }
}

@available(macOS 14.0, *)
private func syntheticAudioScan(
    _ objects: [Int]?,
    cache: inout [Int: String],
    identities: ScanIdentityReads,
    input: [Int: Bool?] = [:],
    output: [Int: Bool?] = [:],
    snapshotReady: (MeetingCallActivitySnapshot) -> Void = { _ in }
) -> (snapshot: MeetingCallActivitySnapshot, processes: [(bundleID: String?, isRunningInput: Bool, isRunningOutput: Bool)]) {
    MicActivityMonitor.processAudioScan(
        objects: objects, ownBundleID: "app.transcripted", cachedLabels: &cache,
        rawBundleID: identities.read,
        input: { input[$0] ?? false }, output: { output[$0] ?? false },
        snapshotReady: snapshotReady
    )
}

func testMicActivityMonitorScan() {
    guard #available(macOS 14.0, *) else { return }

    runSuite("One mic scan reuses successful cold identities while every end snapshot stays fresh") {
        var cache: [Int: String] = [:]
        let reads = ScanIdentityReads([1: ["com.google.Chrome.helper"], 2: ["com.spotify.client"], 3: ["us.zoom.xos"]])
        var readsAtSnapshot: [Int] = []
        let first = syntheticAudioScan([1, 2, 3], cache: &cache, identities: reads, input: [1: true], output: [3: true],
                                       snapshotReady: { _ in readsAtSnapshot = reads.calls })
        assertEqual(readsAtSnapshot, [1, 2, 3], "snapshot is delivered before the filter performs its active-row reads")
        assertEqual(first.snapshot.inputUsers, ["com.google.Chrome.helper"])
        assertEqual(first.snapshot.outputUsers, ["us.zoom.xos"])
        assertTrue(first.snapshot.isReliable)
        assertEqual(reads.calls, [1, 2, 3, 1, 3], "snapshot reads every identity; only active rows revalidate it")
        assertEqual(cache.count, 3)
        let second = syntheticAudioScan([1, 2, 3], cache: &cache, identities: reads, input: [1: true], output: [3: true])
        assertEqual(second.snapshot, first.snapshot)
        assertEqual(reads.calls, [1, 2, 3, 1, 3, 1, 2, 3, 1, 3], "warm labels never replace fresh end evidence")
        assertEqual(MicActivityMonitor.callOutputBundleIDs(
            from: second.processes.map { ($0.bundleID, $0.isRunningOutput) }, ownBundleID: "app.transcripted"
        ), ["us.zoom.xos"])
    }

    runSuite("Cached labels and retry successes never disguise a failed fresh snapshot identity") {
        var cache = [1: "us.zoom.xos"]
        let failed = ScanIdentityReads([1: [nil]])
        let known = syntheticAudioScan([1], cache: &cache, identities: failed, input: [1: true])
        assertFalse(known.snapshot.isReliable)
        assertTrue(known.snapshot.activity(in: ["us.zoom.xos"], cameraInUse: false) == .unknown)
        assertEqual(cache[1], "us.zoom.xos", "a failed read retains the existing filter label")
        assertEqual(failed.calls, [1, 1], "known filter label plus retained active-row validation")
        cache = [:]
        let retry = ScanIdentityReads([1: [nil, "us.zoom.xos"]])
        let cold = syntheticAudioScan([1], cache: &cache, identities: retry, input: [1: true])
        assertFalse(cold.snapshot.isReliable, "filter retry cannot rewrite the earlier snapshot failure")
        assertEqual(cache[1], "us.zoom.xos")
        assertEqual(retry.calls, [1, 1, 1], "failed cold identity still retries before active validation")
        cache = [:]
        let empty = ScanIdentityReads([1: [""]])
        let daemon = syntheticAudioScan([1], cache: &cache, identities: empty)
        assertTrue(daemon.snapshot.isReliable)
        assertTrue(daemon.processes.isEmpty)
        assertTrue(cache.isEmpty, "empty identities are not cached")
        assertEqual(empty.calls, [1, 1], "empty cold identity keeps its existing retry")
    }

    runSuite("Fresh optional activity failures stay unknown even after identity warmup") {
        var cache: [Int: String] = [:]
        let reads = ScanIdentityReads([1: ["us.zoom.xos"]])
        let active = syntheticAudioScan([1], cache: &cache, identities: reads, input: [1: true])
        assertEqual(active.snapshot.inputUsers, ["us.zoom.xos"])
        assertTrue(active.snapshot.isReliable)
        let failed = syntheticAudioScan([1], cache: &cache, identities: reads, input: [1: nil])
        assertFalse(failed.snapshot.isReliable)
        assertTrue(failed.snapshot.activity(in: ["us.zoom.xos"], cameraInUse: false) == .unknown)
        assertEqual(failed.processes.count, 1, "the selected process still has a start row")
        assertEqual(failed.processes.first?.isRunningInput, false, "start rows retain their existing nil-to-false behavior")
        assertEqual(reads.calls, [1, 1, 1])
        let outputFailure = syntheticAudioScan([1], cache: &cache, identities: reads, output: [1: nil])
        assertFalse(outputFailure.snapshot.isReliable)
    }

    runSuite("Missing inventory stays unknown and observed absence invalidates numeric object identities") {
        var cache = [42: "us.zoom.xos"]
        let reads = ScanIdentityReads([42: ["com.google.Chrome.helper"]])
        let missing = syntheticAudioScan(nil, cache: &cache, identities: reads)
        assertEqual(missing.snapshot, .unknown)
        assertTrue(missing.processes.isEmpty)
        assertTrue(cache.isEmpty)
        let empty = syntheticAudioScan([], cache: &cache, identities: reads)
        assertTrue(empty.snapshot.isReliable)
        assertTrue(empty.snapshot.inputUsers.isEmpty && empty.snapshot.outputUsers.isEmpty)
        _ = syntheticAudioScan([42], cache: &cache, identities: reads)
        assertEqual(cache[42], "com.google.Chrome.helper")
        _ = syntheticAudioScan([], cache: &cache, identities: reads)
        reads.answers[42] = ["com.microsoft.teams2"]
        _ = syntheticAudioScan([42], cache: &cache, identities: reads)
        assertEqual(cache[42], "com.microsoft.teams2", "reappearing numeric ID gets its replacement identity")
        assertEqual(reads.calls, [42, 42])
    }

    runSuite("Active rows still revalidate identity after the fresh snapshot warms their filter label") {
        var cache: [Int: String] = [:]
        let reads = ScanIdentityReads([1: ["us.zoom.xos", "com.spotify.client"]])
        let result = syntheticAudioScan([1], cache: &cache, identities: reads, output: [1: true])
        assertEqual(result.snapshot.outputUsers, ["us.zoom.xos"], "snapshot keeps its earlier fresh observation")
        assertEqual(result.processes.count, 1, "the selected output process still has a row")
        assertEqual(result.processes.first?.bundleID, "com.spotify.client")
        assertEqual(MicActivityMonitor.callOutputBundleIDs(
            from: result.processes.map { ($0.bundleID, $0.isRunningOutput) }, ownBundleID: "app.transcripted"
        ), [])
        assertEqual(reads.calls, [1, 1])
        assertEqual(cache[1], "us.zoom.xos", "existing labels are not rewritten by row validation")
    }
}
