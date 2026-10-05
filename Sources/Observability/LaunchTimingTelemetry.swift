import Darwin
import Foundation

/// Launch speed for `launch_models_warmed`: how long after the process
/// started the menu bar icon appeared, the shortcuts went live and the model
/// warmup began, and how long each warmup step took. Durations only, rounded
/// to 10 ms like the dictation and meeting speed timings, plus whether this
/// was a login start (the Mac is busiest then).
enum LaunchTimingTelemetry {
    struct Marks: Equatable {
        var statusItemShownMs: Int?
        var hotkeysRegisteredMs: Int?
        var warmupStartedMs: Int?
        var launchedAtLogin: Bool?
    }

    /// Each mark is set once per process; later calls (wake, model switch,
    /// a second hotkey registration) keep the launch value.
    @MainActor private(set) static var marks = Marks()

    @MainActor static func markStatusItemShown() {
        if marks.statusItemShownMs == nil {
            marks.statusItemShownMs = millisecondsSinceProcessStart()
        }
    }

    /// The icon can't draw until the launch turn on the main thread ends, so
    /// the mark lands on the next main-queue turn, not at creation.
    @MainActor static func markStatusItemShownAfterThisTurn() {
        DispatchQueue.main.async {
            markStatusItemShown()
        }
    }

    @MainActor static func markHotkeysRegistered() {
        if marks.hotkeysRegisteredMs == nil {
            marks.hotkeysRegisteredMs = millisecondsSinceProcessStart()
        }
    }

    @MainActor static func markWarmupStarted() {
        if marks.warmupStartedMs == nil {
            marks.warmupStartedMs = millisecondsSinceProcessStart()
        }
    }

    @MainActor static func noteLaunchedAtLogin(_ atLogin: Bool) {
        if marks.launchedAtLogin == nil {
            marks.launchedAtLogin = atLogin
        }
    }

    static func properties(
        marks: Marks,
        dictationWarmupMs: Int?,
        meetingWarmupMs: Int?,
        speechModel: String,
        machineClass: [String: String] = MachineClassTelemetry.current
    ) -> [String: String] {
        var properties = machineClass
        properties["stt_model"] = speechModel
        let timings: [(String, Int?)] = [
            ("status_item_ms", marks.statusItemShownMs),
            ("hotkeys_ready_ms", marks.hotkeysRegisteredMs),
            ("warmup_start_ms", marks.warmupStartedMs),
            ("dictation_warmup_ms", dictationWarmupMs),
            ("meeting_warmup_ms", meetingWarmupMs),
        ]
        for (key, milliseconds) in timings {
            if let milliseconds {
                properties[key] = MachineClassTelemetry.roundedMilliseconds(milliseconds)
            }
        }
        if let launchedAtLogin = marks.launchedAtLogin {
            properties["login_launch"] = launchedAtLogin ? "true" : "false"
        }
        return properties
    }

    /// Milliseconds between two moments, or nil when the gap can't be a real
    /// launch timing (no start, the clock moved backwards, or over 10 minutes).
    static func elapsedMilliseconds(from start: Date?, to end: Date) -> Int? {
        guard let start else { return nil }
        let milliseconds = end.timeIntervalSince(start) * 1_000
        guard milliseconds >= 0, milliseconds < 600_000 else { return nil }
        return Int(milliseconds.rounded())
    }

    static func millisecondsSinceProcessStart(now: Date = Date()) -> Int? {
        elapsedMilliseconds(from: processStartDate, to: now)
    }

    /// When the kernel started this process, so launch marks include the
    /// time before any app code ran (dyld, framework loading, delegate init).
    static let processStartDate: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        guard started.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }()
}
