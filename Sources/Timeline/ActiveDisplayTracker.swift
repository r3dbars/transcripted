// ActiveDisplayTracker.swift
// Display selection and screenshot sizing helpers for the timeline capture engine.

import CoreGraphics
import Foundation

struct TimelineDisplay: Equatable {
    let id: CGDirectDisplayID
    let pixelWidth: Int
    let pixelHeight: Int

    init(id: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int) {
        self.id = id
        self.pixelWidth = max(0, pixelWidth)
        self.pixelHeight = max(0, pixelHeight)
    }
}

enum TimelineCaptureScaling {
    static let targetHeightPixels = 1080

    static func evenDimension(_ value: Int) -> Int {
        guard value > 1 else { return 2 }
        return value.isMultiple(of: 2) ? value : value - 1
    }

    static func targetPixelSize(for display: TimelineDisplay, targetHeight: Int = targetHeightPixels) -> CGSize {
        guard display.pixelWidth > 0, display.pixelHeight > 0, targetHeight > 0 else {
            return CGSize(width: 2, height: 2)
        }

        let cappedHeight = min(display.pixelHeight, targetHeight)
        let aspectRatio = Double(display.pixelWidth) / Double(display.pixelHeight)
        let width = Int((Double(cappedHeight) * aspectRatio).rounded())
        return CGSize(
            width: evenDimension(width),
            height: evenDimension(cappedHeight)
        )
    }
}

final class ActiveDisplayTracker {
    private let displaysProvider: () -> [TimelineDisplay]
    private let activeDisplayProvider: () -> CGDirectDisplayID?
    private let requestedDisplayProvider: () -> CGDirectDisplayID?

    init(
        displaysProvider: @escaping () -> [TimelineDisplay] = ActiveDisplayTracker.systemDisplays,
        activeDisplayProvider: @escaping () -> CGDirectDisplayID? = { CGMainDisplayID() },
        requestedDisplayProvider: @escaping () -> CGDirectDisplayID? = { nil }
    ) {
        self.displaysProvider = displaysProvider
        self.activeDisplayProvider = activeDisplayProvider
        self.requestedDisplayProvider = requestedDisplayProvider
    }

    func selectedDisplay() -> TimelineDisplay? {
        Self.selectDisplay(
            from: displaysProvider(),
            requestedDisplayID: requestedDisplayProvider(),
            activeDisplayID: activeDisplayProvider()
        )
    }

    static func selectDisplay(
        from displays: [TimelineDisplay],
        requestedDisplayID: CGDirectDisplayID?,
        activeDisplayID: CGDirectDisplayID?
    ) -> TimelineDisplay? {
        if let requestedDisplayID,
           let requested = displays.first(where: { $0.id == requestedDisplayID }) {
            return requested
        }

        if let activeDisplayID,
           let active = displays.first(where: { $0.id == activeDisplayID }) {
            return active
        }

        return displays.first
    }

    static func systemDisplays() -> [TimelineDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return []
        }

        return ids.prefix(Int(count)).map { id in
            TimelineDisplay(
                id: id,
                pixelWidth: CGDisplayPixelsWide(id),
                pixelHeight: CGDisplayPixelsHigh(id)
            )
        }
    }
}
