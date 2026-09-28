import Foundation
import IOKit

/// A MacBook's own microphone is cut off in hardware while the lid is closed,
/// but Core Audio keeps listing it and it delivers exact zeros. Mic selection
/// reads this so a closed MacBook never records a dead mic.
public enum MacLidState {
    /// True only when the power manager reports the lid shut. Desktops and
    /// any read failure report open, which keeps today's behavior.
    public static func isClosed() -> Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return false
        }
        return (value as? Bool) ?? false
    }
}
