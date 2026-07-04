import Foundation

enum TimelineBatchPlanStatus: Equatable {
    case pending
    case skippedShort
    case deferredTrailingShort
}

struct TimelineBatchPlan: Equatable {
    var screenshots: [TimelineScreenshot]
    var start: Date
    var end: Date
    var status: TimelineBatchPlanStatus

    var duration: TimeInterval {
        end.timeIntervalSince(start)
    }
}

struct BatchPlanner {
    var targetDuration: TimeInterval = 900
    var gapSplitThreshold: TimeInterval = 120
    var minimumBatchDuration: TimeInterval = 300
    var trailingSettleDelay: TimeInterval = 60

    func plan(screenshots: [TimelineScreenshot], now: Date) -> [TimelineBatchPlan] {
        let sorted = screenshots.sorted { $0.capturedAt < $1.capturedAt }
        guard !sorted.isEmpty else { return [] }

        var groups: [[TimelineScreenshot]] = []
        var current: [TimelineScreenshot] = []
        for screenshot in sorted {
            if let previous = current.last,
               screenshot.capturedAt.timeIntervalSince(previous.capturedAt) > gapSplitThreshold {
                groups.append(current)
                current = []
            }
            current.append(screenshot)
        }
        if !current.isEmpty {
            groups.append(current)
        }

        var plans: [TimelineBatchPlan] = []
        for (index, group) in groups.enumerated() {
            plans.append(contentsOf: planGroup(group, isTrailingGroup: index == groups.count - 1, now: now))
        }
        return plans
    }

    private func planGroup(
        _ group: [TimelineScreenshot],
        isTrailingGroup: Bool,
        now: Date
    ) -> [TimelineBatchPlan] {
        guard let first = group.first, let last = group.last else { return [] }
        let groupDuration = last.capturedAt.timeIntervalSince(first.capturedAt)
        if groupDuration < minimumBatchDuration {
            let isStillGrowing = isTrailingGroup && now.timeIntervalSince(last.capturedAt) < trailingSettleDelay
            return [
                TimelineBatchPlan(
                    screenshots: group,
                    start: first.capturedAt,
                    end: last.capturedAt,
                    status: isStillGrowing ? .deferredTrailingShort : .skippedShort
                )
            ]
        }

        var plans: [TimelineBatchPlan] = []
        var index = 0
        while index < group.count {
            let batchStart = group[index].capturedAt
            var endIndex = index
            while endIndex + 1 < group.count,
                  group[endIndex + 1].capturedAt.timeIntervalSince(batchStart) <= targetDuration {
                endIndex += 1
            }

            let slice = Array(group[index...endIndex])
            let sliceDuration = (slice.last?.capturedAt ?? batchStart).timeIntervalSince(batchStart)
            let isTrailingSlice = isTrailingGroup && endIndex == group.count - 1
            if sliceDuration < minimumBatchDuration {
                let isStillGrowing = isTrailingSlice && now.timeIntervalSince(slice.last?.capturedAt ?? batchStart) < trailingSettleDelay
                plans.append(
                    TimelineBatchPlan(
                        screenshots: slice,
                        start: batchStart,
                        end: slice.last?.capturedAt ?? batchStart,
                        status: isStillGrowing ? .deferredTrailingShort : .skippedShort
                    )
                )
            } else {
                plans.append(
                    TimelineBatchPlan(
                        screenshots: slice,
                        start: batchStart,
                        end: slice.last?.capturedAt ?? batchStart,
                        status: .pending
                    )
                )
            }

            index = endIndex + 1
        }

        return plans
    }
}
