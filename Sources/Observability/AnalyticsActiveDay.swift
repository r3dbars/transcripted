import Foundation

/// `app_active_day`: one anonymous event per local day while the app is running.
///
/// Usage digests only exist for days with captures and `app_launched` only fires
/// at launch, so without this a menu bar app left running but unused looks the
/// same as one that was quit or deleted. The event carries only the default
/// version/channel properties, and the only stored value is the last day key.
extension AnalyticsReporter {
    static let activeDayStorageKey = "analyticsLastActiveDay"

    /// Work for the reporter's 60-second timer, which runs on the delivery queue.
    func runMinuteTick() {
        trackActiveDayIfNeeded()
        enqueueUsageDigests(includeCurrentDay: false)
    }

    func trackActiveDayIfNeeded() {
        syncOnDeliveryQueue {
            // No API key means an automated launch or an unconfigured build:
            // send nothing and leave the stored day alone.
            guard analyticsEnabled(), apiKey != nil, captureHost != nil else { return }
            let today = UsageHealthStore.dayKey(currentDate(), calendar: .current)
            guard userDefaults.string(forKey: Self.activeDayStorageKey) != today else { return }
            userDefaults.set(today, forKey: Self.activeDayStorageKey)
            trackEvent("app_active_day")
        }
    }
}
