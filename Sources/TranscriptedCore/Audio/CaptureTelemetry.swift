import Foundation
@preconcurrency import AVFoundation
import Synchronization

/// Off-by-default capture diagnostics for repros such as a call app's mic
/// unmute silencing the system tap. When on, the system tap and the mic each
/// log one line per second (level, zero counts, buffer continuity) and the
/// tap logs route and device changes once per change. Amplitude statistics
/// and Core Audio state only: never samples, device names or UIDs. Lines go
/// to the local `app.jsonl` like every `AppLogger` line.
///
/// Read at each recording start. Turn on with
/// `defaults write com.justinbetker.draft capture-telemetry -bool true`
/// or `TRANSCRIPTED_CAPTURE_TELEMETRY=1`; the env var wins over defaults.
public enum CaptureTelemetryPreferences {
    static let userDefaultsKey = "capture-telemetry"
    static let environmentKey = "TRANSCRIPTED_CAPTURE_TELEMETRY"
    static let shipsOnByDefault = false

    static func isEnabled(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let override = environment[environmentKey] {
            return ["1", "true", "yes"].contains(override.lowercased())
        }
        return userDefaults.object(forKey: userDefaultsKey) as? Bool ?? shipsOnByDefault
    }
}

/// One second of capture statistics. Pure value math, unit tested.
struct CaptureSignalTelemetry {
    static let windowSeconds: TimeInterval = 1

    private(set) var emittedWindows = 0
    private var windowStart: TimeInterval?
    private var lastArrival: TimeInterval?
    private var lastHost: (seconds: TimeInterval, expected: TimeInterval)?

    private var buffers = 0
    private var frames = 0
    private var samples = 0
    private var zeros = 0
    private var subnormals = 0
    private var nonFinite = 0
    private var sumSquares: Double = 0
    private var peak: Float = 0
    private var maxArrivalGap: TimeInterval = 0
    private var minHostDelta: TimeInterval?
    private var maxHostDelta: TimeInterval?
    private var hostJumps = 0

    /// Adds one buffer. Returns the finished window's log fields when this
    /// buffer arrives a second or more after the window opened.
    mutating func record(_ buffer: AVAudioPCMBuffer, arrival: TimeInterval, hostSeconds: TimeInterval?) -> [String: String]? {
        let flushed = flushIfDue(at: arrival)
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return flushed }
        for item in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = item.mData else { continue }
            let count = Int(item.mDataByteSize) / MemoryLayout<Float>.size
            addSamples(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }
        noteBuffer(frames: Int(buffer.frameLength), arrival: arrival, hostSeconds: hostSeconds, sampleRate: buffer.format.sampleRate)
        return flushed
    }

    mutating func addSamples(_ values: UnsafeBufferPointer<Float>) {
        for value in values {
            samples += 1
            if value == 0 { zeros += 1; continue }
            guard value.isFinite else { nonFinite += 1; continue }
            if value.isSubnormal { subnormals += 1 }
            let magnitude = abs(value)
            if magnitude > peak { peak = magnitude }
            sumSquares += Double(value) * Double(value)
        }
    }

    mutating func noteBuffer(frames count: Int, arrival: TimeInterval, hostSeconds: TimeInterval?, sampleRate: Double) {
        if windowStart == nil { windowStart = arrival }
        buffers += 1
        frames += count
        if let lastArrival { maxArrivalGap = max(maxArrivalGap, arrival - lastArrival) }
        lastArrival = arrival
        guard let hostSeconds else { lastHost = nil; return }
        if let lastHost {
            let delta = hostSeconds - lastHost.seconds
            minHostDelta = min(minHostDelta ?? delta, delta)
            maxHostDelta = max(maxHostDelta ?? delta, delta)
            // A buffer that does not start where the last one ended: a gap,
            // an overlap or a reset host clock.
            if abs(delta - lastHost.expected) > max(0.002, lastHost.expected / 2) { hostJumps += 1 }
        }
        lastHost = (hostSeconds, sampleRate > 0 ? Double(count) / sampleRate : 0)
    }

    /// Closes the window once it is a second old, even with no buffers, so a
    /// stalled callback still shows up as `buffers: 0`.
    mutating func flushIfDue(at now: TimeInterval) -> [String: String]? {
        guard let start = windowStart else { windowStart = now; return nil }
        guard now - start >= Self.windowSeconds else { return nil }
        var fields: [String: String] = [
            "window_ms": "\(Int(((now - start) * 1000).rounded()))",
            "buffers": "\(buffers)",
            "frames": "\(frames)",
            "peak_dbfs": Self.dbfs(Double(peak)),
            "rms_dbfs": Self.dbfs(samples > 0 ? (sumSquares / Double(samples)).squareRoot() : 0),
            "zero_ratio": samples > 0 ? String(format: "%.3f", Double(zeros) / Double(samples)) : "n/a",
            "zeros": "\(zeros)",
            "subnormals": "\(subnormals)",
            "nonfinite": "\(nonFinite)",
            "max_gap_ms": "\(Int((max(maxArrivalGap, lastArrival.map { now - $0 } ?? 0) * 1000).rounded()))"
        ]
        if let minHostDelta, let maxHostDelta {
            fields["host_min_ms"] = String(format: "%.2f", minHostDelta * 1000)
            fields["host_max_ms"] = String(format: "%.2f", maxHostDelta * 1000)
            fields["host_jumps"] = "\(hostJumps)"
        }
        emittedWindows += 1
        let keep = (emitted: emittedWindows, arrival: lastArrival, host: lastHost)
        self = CaptureSignalTelemetry()
        emittedWindows = keep.emitted
        lastArrival = keep.arrival
        lastHost = keep.host
        windowStart = now
        return fields
    }

    static func dbfs(_ linear: Double) -> String {
        guard linear > 0, linear.isFinite else { return "-inf" }
        return String(format: "%.1f", 20 * log10(linear))
    }
}

/// The mic side: fed from the input tap thread, so a lock guards the window
/// and an atomic keeps the off path to one load.
final class LockedCaptureSignalTelemetry: @unchecked Sendable {
    private let enabled = Atomic<Bool>(false)
    private let lock = NSLock()
    private var telemetry = CaptureSignalTelemetry()

    var isEnabled: Bool { enabled.load(ordering: .acquiring) }

    func reset(enabled value: Bool) {
        lock.lock()
        telemetry = CaptureSignalTelemetry()
        lock.unlock()
        enabled.store(value, ordering: .releasing)
    }

    func record(_ buffer: AVAudioPCMBuffer, arrival: TimeInterval) -> [String: String]? {
        guard enabled.load(ordering: .acquiring) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return telemetry.record(buffer, arrival: arrival, hostSeconds: nil)
    }
}
