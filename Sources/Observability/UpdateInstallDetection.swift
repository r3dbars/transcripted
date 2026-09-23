import Foundation

/// How a newer app version reached this Mac, as seen on its first launch.
/// Sent as `update_installed.install_kind`.
enum UpdateInstallKind: String {
    /// "Restart to Update" in Transcripted, or Sparkle's own install-and-relaunch.
    case restart
    /// Sparkle downloaded the update in the background and installed it when
    /// the app quit (logout, restart, or a plain Quit).
    case quit
    /// The version went up without an in-app install this build saw: a new
    /// DMG, Homebrew, or an older build's updater that kept no record.
    case unattributed
}

struct UpdateInstallRecord: Equatable {
    let version: String
    let previousVersion: String?
    let kind: UpdateInstallKind
}

/// Decides, once per launch, whether this launch is the first one on a newer
/// version, so `update_installed` counts every install path instead of only
/// the in-app "Restart to Update" relaunch.
///
/// Inputs come from `UserDefaults`: the version the app last launched as, plus
/// the pending-install markers Sparkle's callbacks write when an update is
/// staged (`quit`) or relaunched into (`restart`).
enum UpdateInstallDetection {
    struct Outcome: Equatable {
        let record: UpdateInstallRecord?
        /// Clear the pending-install markers. A marker for a version newer
        /// than the running one is kept: that staged update has not landed yet.
        let clearPendingMarkers: Bool
    }

    static func detect(
        currentVersion: String,
        lastLaunchedVersion: String?,
        pendingVersion: String?,
        pendingPreviousVersion: String?,
        pendingKind: String?
    ) -> Outcome {
        guard let current = meaningfulVersion(currentVersion) else {
            return Outcome(record: nil, clearPendingMarkers: false)
        }

        let lastLaunched = meaningfulVersion(lastLaunchedVersion)
        let pending = meaningfulVersion(pendingVersion)

        if let pending, pending == current {
            // Already launched as this version: the install was counted then.
            guard lastLaunched != current else {
                return Outcome(record: nil, clearPendingMarkers: true)
            }
            // Markers written by older builds carry no kind; they only ever
            // came from the relaunch path.
            let kind = pendingKind.flatMap(UpdateInstallKind.init(rawValue:)) ?? .restart
            return Outcome(
                record: UpdateInstallRecord(
                    version: current,
                    previousVersion: lastLaunched ?? meaningfulVersion(pendingPreviousVersion),
                    kind: kind
                ),
                clearPendingMarkers: true
            )
        }

        let clearStalePending = pending.map { !isVersion($0, newerThan: current) } ?? false

        guard let lastLaunched, isVersion(current, newerThan: lastLaunched) else {
            return Outcome(record: nil, clearPendingMarkers: clearStalePending)
        }

        return Outcome(
            record: UpdateInstallRecord(version: current, previousVersion: lastLaunched, kind: .unattributed),
            clearPendingMarkers: clearStalePending
        )
    }

    /// Dotted numeric comparison, so 1.1.10 is newer than 1.1.9.
    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        lhs.compare(rhs, options: .numeric) == .orderedDescending
    }

    private static func meaningfulVersion(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != "unknown" else {
            return nil
        }
        return trimmed
    }
}
