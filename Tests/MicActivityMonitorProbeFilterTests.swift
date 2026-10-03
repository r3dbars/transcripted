// MicActivityMonitorProbeFilterTests.swift
// The call-detection scan reads each process's bundle ID first and only reads
// running flags for processes that can map to a provider. These tests pin the
// promise that the filter changes nothing any consumer sees: the provider
// projections of all three emitted sets come out the same as a scan that reads
// every flag of every process. Synthetic process tables only; real coreaudiod
// behavior (Meet, Zoom, Teams, FaceTime, listen-only) still needs a hardware
// check.

import Foundation

private struct FakeAudioProcess {
    let id: Int
    /// What CoreAudio returns for kAudioProcessPropertyBundleID: nil when the
    /// read fails, "" for a process without a bundle.
    let label: String?
    let isRunningInput: Bool
    let isRunningOutput: Bool
}

private let probeFilterOwnBundleID = "com.justinbetker.draft"

private let probeFilterTable: [FakeAudioProcess] = [
    FakeAudioProcess(id: 1, label: "com.google.Chrome.helper", isRunningInput: true, isRunningOutput: false),
    FakeAudioProcess(id: 2, label: "com.google.Chrome.helper.Renderer", isRunningInput: false, isRunningOutput: true),
    FakeAudioProcess(id: 3, label: "com.apple.WebKit.GPU", isRunningInput: false, isRunningOutput: true),
    FakeAudioProcess(id: 4, label: "us.zoom.xos", isRunningInput: false, isRunningOutput: true),
    FakeAudioProcess(id: 5, label: "com.microsoft.teams2.helper", isRunningInput: true, isRunningOutput: false),
    FakeAudioProcess(id: 6, label: "com.justinbetker.draft", isRunningInput: true, isRunningOutput: true),
    FakeAudioProcess(id: 7, label: "com.justinbetker.draft.helper", isRunningInput: true, isRunningOutput: false),
    FakeAudioProcess(id: 8, label: "", isRunningInput: true, isRunningOutput: false),
    FakeAudioProcess(id: 9, label: "com.apple.QuickTimePlayerX", isRunningInput: true, isRunningOutput: false),
    FakeAudioProcess(id: 10, label: "com.tinyspeck.slackmacgap", isRunningInput: true, isRunningOutput: true),
    FakeAudioProcess(id: 11, label: "com.spotify.client", isRunningInput: false, isRunningOutput: true),
    FakeAudioProcess(id: 12, label: nil, isRunningInput: true, isRunningOutput: false),
]

private struct ProbeFilterProjections: Equatable {
    let micProviders: Set<String>
    let micBrowserFamilies: Set<String>
    let callOutput: Set<String>
    let browserCallOutput: Set<String>
}

@available(macOS 14.0, *)
private func projections(
    of rows: [(bundleID: String?, isRunningInput: Bool, isRunningOutput: Bool)]
) -> ProbeFilterProjections {
    let mic = MicActivityMonitor.micUsingBundleIDs(
        from: rows.map { (bundleID: $0.bundleID, isRunningInput: $0.isRunningInput) },
        ownBundleID: probeFilterOwnBundleID
    )
    let outputRows = rows.map { (bundleID: $0.bundleID, isRunningOutput: $0.isRunningOutput) }
    return ProbeFilterProjections(
        micProviders: Set(mic.compactMap(MeetingPromptProvider.micInputProvider(forBundleID:)).map(\.rawValue)),
        micBrowserFamilies: Set(mic.compactMap(MeetingPromptProvider.browserFamily(forBundleID:))),
        callOutput: MicActivityMonitor.callOutputBundleIDs(from: outputRows, ownBundleID: probeFilterOwnBundleID),
        browserCallOutput: MicActivityMonitor.browserCallOutputBundleIDs(from: outputRows, micBundleIDs: mic)
    )
}

/// The scan as it was before the filter: every flag of every process, and a
/// bundle ID for any process doing audio.
private func unfilteredRows(
    _ table: [FakeAudioProcess]
) -> [(bundleID: String?, isRunningInput: Bool, isRunningOutput: Bool)] {
    table.map { process in
        let active = process.isRunningInput || process.isRunningOutput
        let bundleID = process.label.flatMap { $0.isEmpty ? nil : $0 }
        return (bundleID: active ? bundleID : nil, isRunningInput: process.isRunningInput, isRunningOutput: process.isRunningOutput)
    }
}

private final class FlagReadLog {
    var inputReads: Set<Int> = []
    var outputReads: Set<Int> = []
}

@available(macOS 14.0, *)
private func filteredRows(
    _ table: [FakeAudioProcess],
    freshBundleIDOverride: [Int: String] = [:],
    log: FlagReadLog = FlagReadLog()
) -> [(bundleID: String?, isRunningInput: Bool, isRunningOutput: Bool)] {
    let byID = Dictionary(uniqueKeysWithValues: table.map { ($0.id, $0) })
    return MicActivityMonitor.probedProcessAudioState(
        objects: table.map(\.id),
        ownBundleID: probeFilterOwnBundleID,
        label: { byID[$0]?.label },
        bundleID: { id in
            if let override = freshBundleIDOverride[id] { return override }
            return byID[id]?.label.flatMap { $0.isEmpty ? nil : $0 }
        },
        isRunningInput: { id in
            log.inputReads.insert(id)
            return byID[id]?.isRunningInput ?? false
        },
        isRunningOutput: { id in
            log.outputReads.insert(id)
            return byID[id]?.isRunningOutput ?? false
        }
    )
}

func testMicActivityMonitorProbeFilter() {
    guard #available(macOS 14.0, *) else { return }

    runSuite("MicActivityMonitor.shouldProbe — only processes that can map to a call provider get their flags read") {
        let own = probeFilterOwnBundleID
        assertTrue(MicActivityMonitor.shouldProbe(bundleID: nil, ownBundleID: own), "a failed bundle read fails open")
        assertFalse(MicActivityMonitor.shouldProbe(bundleID: "", ownBundleID: own), "a bundle-less daemon is dropped downstream anyway")
        assertFalse(MicActivityMonitor.shouldProbe(bundleID: "com.justinbetker.draft", ownBundleID: own), "our own app is never a call")
        assertFalse(MicActivityMonitor.shouldProbe(bundleID: "com.justinbetker.draft.helper", ownBundleID: own), "our own helpers are never a call")
        for bundle in ["com.google.Chrome.helper", "com.apple.WebKit.GPU", "us.zoom.xos", "com.microsoft.teams2.helper"] {
            assertTrue(MicActivityMonitor.shouldProbe(bundleID: bundle, ownBundleID: own), "\(bundle) can be a call")
        }
        for bundle in ["com.apple.QuickTimePlayerX", "com.tinyspeck.slackmacgap", "com.spotify.client"] {
            assertFalse(MicActivityMonitor.shouldProbe(bundleID: bundle, ownBundleID: own), "\(bundle) never maps to a provider")
        }
        assertTrue(
            MicActivityMonitor.shouldProbe(bundleID: "us.zoom.xos", ownBundleID: ""),
            "with no own bundle ID nothing counts as self"
        )
    }

    runSuite("MicActivityMonitor scan — the filtered scan gives every consumer the same signals as reading every process") {
        let log = FlagReadLog()
        let filtered = projections(of: filteredRows(probeFilterTable, log: log))
        let unfiltered = projections(of: unfilteredRows(probeFilterTable))
        assertEqual(filtered, unfiltered, "mic providers, browser families and both output sets must not change")
        let expectedMicProviders = Set(
            ["com.google.Chrome.helper", "com.microsoft.teams2.helper"]
                .compactMap(MeetingPromptProvider.micInputProvider(forBundleID:))
                .map(\.rawValue)
        )
        assertEqual(expectedMicProviders.count, 2, "Chrome and Teams are two different providers")
        assertEqual(filtered.micProviders, expectedMicProviders, "the browser and Teams mic users are still seen")
        assertEqual(filtered.callOutput, ["us.zoom.xos"], "the listen-only Zoom call is still seen")
        assertTrue(filtered.browserCallOutput.contains("com.google.Chrome.helper.Renderer"), "the browser talking back is still seen")
        assertTrue(log.inputReads.contains(12), "a process whose bundle read failed is still probed")
        for skipped in [6, 7, 8, 9, 10, 11] {
            assertFalse(log.inputReads.contains(skipped), "process \(skipped) can't be a call, so its flags are never read")
            assertFalse(log.outputReads.contains(skipped), "process \(skipped) can't be a call, so its flags are never read")
        }
    }

    runSuite("MicActivityMonitor scan — browser output is only read while a browser holds the mic") {
        let quietBrowser = probeFilterTable.filter { $0.id != 1 }
        let log = FlagReadLog()
        let filtered = projections(of: filteredRows(quietBrowser, log: log))
        assertEqual(filtered, projections(of: unfilteredRows(quietBrowser)), "projections match with no browser on the mic")
        assertEqual(filtered.browserCallOutput, [], "browser playback alone is never corroboration")
        assertFalse(log.outputReads.contains(2), "browser output is not read when no browser holds the mic")
        assertFalse(log.outputReads.contains(3), "WebKit output is not read when no browser holds the mic")
        assertTrue(log.outputReads.contains(4), "native conferencing output is always read (listen-only calls)")
    }

    runSuite("MicActivityMonitor scan — a row carries the fresh bundle ID, not the one used to pick it") {
        let table = [FakeAudioProcess(id: 42, label: "us.zoom.xos", isRunningInput: false, isRunningOutput: true)]
        let rows = filteredRows(table, freshBundleIDOverride: [42: "com.spotify.client"])
        let outputRows = rows.map { (bundleID: $0.bundleID, isRunningOutput: $0.isRunningOutput) }
        assertEqual(
            MicActivityMonitor.callOutputBundleIDs(from: outputRows, ownBundleID: probeFilterOwnBundleID),
            [],
            "a process that turned out not to be Zoom must not raise a listen-only call"
        )
    }

    runSuite("MicActivityMonitor scan — a scan where nothing can be a call still clears an active call") {
        let since = Date(timeIntervalSince1970: 1_000)
        let idle = [FakeAudioProcess(id: 1, label: "com.spotify.client", isRunningInput: false, isRunningOutput: true)]
        let rows = filteredRows(idle)
        let raw = MicActivityMonitor.micUsingBundleIDs(
            from: rows.map { (bundleID: $0.bundleID, isRunningInput: $0.isRunningInput) },
            ownBundleID: probeFilterOwnBundleID
        )
        let outcome = SustainedActivityConfirmer.confirm(
            raw: raw,
            activeSince: ["us.zoom.xos": since],
            now: since.addingTimeInterval(10),
            sustain: 3
        )
        assertEqual(outcome.confirmed, [], "the inactive edge still goes out")
        assertEqual(outcome.activeSince, [:], "the old call's first-seen time is forgotten")
        assertNil(outcome.nextDeadline, "nothing is pending")
    }
}
