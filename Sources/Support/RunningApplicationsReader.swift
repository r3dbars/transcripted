// RunningApplicationsReader.swift
// Reads the running apps' bundle IDs off the main thread.
//
// `NSRunningApplication.bundleIdentifier` can make a synchronous
// LaunchServices call the first time it is read for an app. On one 1.1.66
// Mac that call blocked the main thread for 5+ seconds, several times in
// half an hour, inside an async job on the main actor (meeting detection's
// scan or its app-launch handler; the app frame was unsymbolicated). These
// reads now run on one serial queue, so a slow LaunchServices reply only
// delays that work and never freezes the app. Reading here also warms each
// app's cached info, so a later main-thread read is usually instant. A serial queue (not a detached task)
// keeps a stuck reply from tying up Swift's shared thread pool.

import AppKit

struct RunningApplicationInfo: Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let isRegularApp: Bool
}

enum RunningApplicationsReader {
    private static let readQueue = DispatchQueue(
        label: "com.transcripted.running-applications",
        qos: .userInitiated
    )

    static func applications() async -> [RunningApplicationInfo] {
        await withCheckedContinuation { continuation in
            readQueue.async {
                let apps = NSWorkspace.shared.runningApplications.map { app in
                    RunningApplicationInfo(
                        processIdentifier: app.processIdentifier,
                        bundleIdentifier: app.bundleIdentifier,
                        isRegularApp: app.activationPolicy == .regular
                    )
                }
                continuation.resume(returning: apps)
            }
        }
    }

    static func bundleIdentifiers() async -> Set<String> {
        Set(await applications().compactMap(\.bundleIdentifier))
    }

    /// One app's bundle ID. A just-launched app's `NSRunningApplication`
    /// has no cached info yet, so its first read is the slow one.
    static func bundleIdentifier(of app: NSRunningApplication) async -> String? {
        await withCheckedContinuation { continuation in
            readQueue.async {
                continuation.resume(returning: app.bundleIdentifier)
            }
        }
    }
}
