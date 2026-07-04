// InputIdleSnapshot.swift
// Local input-idle metadata for timeline screenshot records.

import CoreGraphics
import Foundation

struct InputIdleSnapshot: Equatable {
    let idleSeconds: TimeInterval
    let capturedAt: Date

    static func current(
        now: Date = Date(),
        idleSecondsProvider: () -> TimeInterval = InputIdleSnapshot.currentIdleSeconds
    ) -> InputIdleSnapshot {
        InputIdleSnapshot(idleSeconds: max(0, idleSecondsProvider()), capturedAt: now)
    }

    static func currentIdleSeconds() -> TimeInterval {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        guard idle.isFinite else { return 0 }
        return max(0, idle)
    }
}
