#!/usr/bin/env swift
//
// mic-activity-spike.swift
// Phase 0 de-risking spike for docs/auto-call-detection-spec.md
//
// Goal: confirm the modern Core Audio process-object API (macOS 14.2+) can read
// which processes are *currently holding the mic input*, attributed by bundle
// ID, WITHOUT the NSAudioCaptureUsageDescription TCC permission. We read
// metadata (process list + per-process IsRunningInput + BundleID), never audio
// samples, so no permission prompt should appear and no read should fail with a
// permission/`!pri`/`!obj` error.
//
// This is a THROWAWAY tool. It is not part of the app target and can be deleted
// once Phase 1 lands. Run it with:
//
//   swift scripts/dev/mic-activity-spike.swift          # one snapshot
//   swift scripts/dev/mic-activity-spike.swift --watch  # poll every 1s
//
// Then start a Google Meet call in a browser and confirm the browser bundle ID
// (e.g. com.google.Chrome / com.apple.Safari) shows IsRunningInput = true.
//
import CoreAudio
import Foundation

// MARK: - Property helpers

func fourCC(_ value: UInt32) -> String {
    let chars = [
        Character(UnicodeScalar((value >> 24) & 0xFF)!),
        Character(UnicodeScalar((value >> 16) & 0xFF)!),
        Character(UnicodeScalar((value >> 8) & 0xFF)!),
        Character(UnicodeScalar(value & 0xFF)!),
    ]
    return String(chars)
}

func describe(_ status: OSStatus) -> String {
    if status == noErr { return "ok" }
    // CoreAudio packs an ASCII 4CC into many of its error codes.
    let unsigned = UInt32(bitPattern: status)
    return "OSStatus \(status) ('\(fourCC(unsigned))')"
}

func processObjectIDs() -> (status: OSStatus, ids: [AudioObjectID]) {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
    )
    guard sizeStatus == noErr else { return (sizeStatus, []) }

    let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
    )
    return (status, status == noErr ? ids : [])
}

func boolProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> (status: OSStatus, value: Bool) {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    return (status, value != 0)
}

func pidProperty(_ object: AudioObjectID) -> (status: OSStatus, value: pid_t) {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: pid_t = -1
    var size = UInt32(MemoryLayout<pid_t>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    return (status, value)
}

func bundleIDProperty(_ object: AudioObjectID) -> (status: OSStatus, value: String?) {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyBundleID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &unmanaged)
    guard status == noErr, let unmanaged else { return (status, nil) }
    let bundleID = unmanaged.takeRetainedValue() as String
    return (status, bundleID.isEmpty ? nil : bundleID)
}

// MARK: - Snapshot

struct ProcessRow {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningInput: Bool
    let errors: [String]
}

func snapshot() -> (listStatus: OSStatus, rows: [ProcessRow]) {
    let (listStatus, ids) = processObjectIDs()
    var rows: [ProcessRow] = []
    for object in ids {
        var errors: [String] = []
        let (inputStatus, isRunningInput) = boolProperty(object, kAudioProcessPropertyIsRunningInput)
        if inputStatus != noErr { errors.append("IsRunningInput: \(describe(inputStatus))") }
        let (pidStatus, pid) = pidProperty(object)
        if pidStatus != noErr { errors.append("PID: \(describe(pidStatus))") }
        let (bundleStatus, bundleID) = bundleIDProperty(object)
        if bundleStatus != noErr { errors.append("BundleID: \(describe(bundleStatus))") }
        rows.append(ProcessRow(object: object, pid: pid, bundleID: bundleID, isRunningInput: isRunningInput, errors: errors))
    }
    return (listStatus, rows)
}

func printSnapshot(iteration: Int?, dumpAll: Bool) {
    let (listStatus, rows) = snapshot()
    if let iteration { print("\n=== snapshot #\(iteration) ===") }

    guard listStatus == noErr else {
        print("FAILED to read process object list: \(describe(listStatus))")
        print("→ This likely means the API is unavailable or blocked. Investigate the fallback path in the spec.")
        return
    }

    print("Process objects known to Core Audio: \(rows.count)")
    let withBundle = rows.filter { $0.bundleID != nil }
    print("Process objects with a resolved bundle ID (attribution): \(withBundle.count)/\(rows.count)")
    let usingInput = rows.filter { $0.isRunningInput }
    print("Currently holding mic INPUT: \(usingInput.count)")
    for row in usingInput {
        print("  • pid \(row.pid)  bundle=\(row.bundleID ?? "<none>")  (object \(row.object))")
    }

    if dumpAll {
        print("All process objects:")
        for row in rows.sorted(by: { ($0.bundleID ?? "") < ($1.bundleID ?? "") }) {
            let flag = row.isRunningInput ? " [INPUT]" : ""
            print("  - pid \(row.pid)  bundle=\(row.bundleID ?? "<none>")\(flag)")
        }
    }

    let anyErrors = rows.flatMap { row in row.errors.map { "object \(row.object) pid \(row.pid): \($0)" } }
    if anyErrors.isEmpty {
        print("Per-process property reads: all ok (no permission/availability errors).")
    } else {
        // A permission failure would surface here as a non-noErr status on the
        // metadata reads. We expect this list to be empty.
        print("Per-process read errors (\(anyErrors.count)):")
        for line in anyErrors.prefix(20) { print("  ! \(line)") }
    }
}

// MARK: - Main

let watch = CommandLine.arguments.contains("--watch")
let dumpAll = CommandLine.arguments.contains("--dump")
print("mic-activity-spike — Core Audio process-object API")
print("macOS target: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("No TCC permission requested. Reading metadata only.")

if watch {
    print("Watching every 1s. Ctrl-C to stop. Start a Meet/Zoom-web call to see a browser appear.")
    var i = 1
    while true {
        printSnapshot(iteration: i, dumpAll: dumpAll)
        i += 1
        Thread.sleep(forTimeInterval: 1.0)
    }
} else {
    printSnapshot(iteration: nil, dumpAll: dumpAll)
    print("\nTip: run with --watch and start a browser call to confirm attribution.")
}
