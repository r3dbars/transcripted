// CalendarAccessStatusCache.swift
// The last known answer to "may Transcripted read the calendar?", refreshed
// off the main thread.
//
// `EKEventStore.authorizationStatus(for:)` is a synchronous XPC call to the
// calendar daemon. Meeting prompt detection asked it on the main actor every
// evaluation, and on one 1.1.76 Mac (macOS 27) that reply took long enough
// to hang the app shortly after launch (Sentry APPLE-MACOS-6Y). Readers on the
// main actor now take `isGranted`, an in-memory value, and `refresh()` asks
// EventKit on one serial background queue. A serial queue (not a detached
// task) keeps a stuck reply from tying up Swift's shared thread pool, the
// same choice `RunningApplicationsReader` makes.
//
// Before the first refresh lands the answer is "not granted", which is the
// same path a Mac without calendar access takes. The refresh after it then
// reports a change, so the caller fetches events right away instead of
// waiting for a cache lifetime.

import EventKit
import Foundation

// @unchecked Sendable is safe because `granted` is only touched under `lock`
// and the status provider only runs on `queue`.
final class CalendarAccessStatusCache: @unchecked Sendable {
    static let shared = CalendarAccessStatusCache()

    private let statusProvider: @Sendable () -> EKAuthorizationStatus
    private let queue = DispatchQueue(
        label: "com.transcripted.calendar-access-status",
        qos: .utility
    )
    private let lock = NSLock()
    private var granted = false

    init(
        statusProvider: @escaping @Sendable () -> EKAuthorizationStatus = {
            EKEventStore.authorizationStatus(for: .event)
        }
    ) {
        self.statusProvider = statusProvider
    }

    /// The last answer `refresh()` read. Never calls EventKit, so it is safe
    /// on the main actor.
    var isGranted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return granted
    }

    /// Asks EventKit on the background queue, stores the answer, and returns it.
    @discardableResult
    func refresh() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let value = Self.isGranted(self.statusProvider())
                // Set on the serial queue, so a later read never loses to an
                // earlier one that happened to resume late.
                self.lock.lock()
                self.granted = value
                self.lock.unlock()
                continuation.resume(returning: value)
            }
        }
    }

    static func isGranted(_ status: EKAuthorizationStatus) -> Bool {
        switch status {
        case .fullAccess, .authorized:
            return true
        case .writeOnly, .denied, .restricted, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }
}
