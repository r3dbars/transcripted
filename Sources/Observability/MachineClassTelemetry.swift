import Foundation

/// Coarse, non-identifying Mac class for speed telemetry: which Apple chip
/// family and roughly how much memory. Lets PostHog compare dictation speed
/// across machines without sending a model identifier or serial-like value.
enum MachineClassTelemetry {
    static let unknownChip = "unknown"

    /// Cached for the process: neither value changes while the app runs.
    static let current: [String: String] = [
        "mac_chip": chip(fromBrandString: sysctlString("machdep.cpu.brand_string")),
        "memory_gb_bucket": memoryBucket(bytes: ProcessInfo.processInfo.physicalMemory),
    ]

    /// "Apple M2 Pro" -> "m2_pro", "Apple M4" -> "m4". Anything else is "unknown".
    static func chip(fromBrandString brand: String?) -> String {
        guard let brand else { return unknownChip }
        let words = brand
            .lowercased()
            .split(whereSeparator: { $0 == " " })
            .map(String.init)
        guard let familyIndex = words.firstIndex(where: { isChipFamily($0) }) else { return unknownChip }
        let family = words[familyIndex]
        let tiers: Set<String> = ["pro", "max", "ultra"]
        if familyIndex + 1 < words.count, tiers.contains(words[familyIndex + 1]) {
            return "\(family)_\(words[familyIndex + 1])"
        }
        return family
    }

    static func memoryBucket(bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        switch gigabytes {
        case ..<12:
            return "8gb"
        case ..<20:
            return "16gb"
        case ..<28:
            return "24gb"
        case ..<40:
            return "32gb"
        case ..<56:
            return "48gb"
        case ..<80:
            return "64gb"
        default:
            return "96gb_plus"
        }
    }

    /// Rounds a timing to 10 ms so a raw value stays a coarse diagnostic.
    static func roundedMilliseconds(_ milliseconds: Int) -> String {
        let clamped = max(0, milliseconds)
        return "\(Int((Double(clamped) / 10).rounded()) * 10)"
    }

    private static func isChipFamily(_ word: String) -> Bool {
        guard word.count >= 2, word.first == "m" else { return false }
        return word.dropFirst().allSatisfy(\.isNumber)
    }

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
