#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// Which Writing models this Mac may run (docs/writing-plan.md, decision 15).
///
/// Gemma runs everywhere. Qwen 3.5 9B needs at least 16 GiB of physical
/// memory. A Qwen choice persisted on a Mac below that line (moved defaults,
/// a restored backup, a hand edit) runs Gemma instead; the saved choice is
/// left alone, so the UI can still say why.
enum WritingModelEligibility {
    static let qwenMinimumPhysicalMemoryBytes: UInt64 = 16 * 1024 * 1024 * 1024

    static func isEligible(_ choice: TildeModelChoice, physicalMemoryBytes: UInt64) -> Bool {
        switch choice {
        case .gemma4E2B: true
        case .qwen35B9B: physicalMemoryBytes >= qwenMinimumPhysicalMemoryBytes
        }
    }

    static func effectiveChoice(
        persisted: TildeModelChoice,
        physicalMemoryBytes: UInt64
    ) -> TildeModelChoice {
        isEligible(persisted, physicalMemoryBytes: physicalMemoryBytes) ? persisted : .gemma4E2B
    }

    /// Tilde's production selection (`TildeModelSelection.choice`) with the
    /// eligibility rule applied. `nil` only for a non-production profile,
    /// exactly as in Tilde.
    static func resolvedChoice(
        for profile: TildeProductProfile,
        defaults: UserDefaults,
        physicalMemoryBytes: UInt64
    ) -> TildeModelChoice? {
        TildeModelSelection.choice(for: profile, defaults: defaults).map {
            effectiveChoice(persisted: $0, physicalMemoryBytes: physicalMemoryBytes)
        }
    }
}
