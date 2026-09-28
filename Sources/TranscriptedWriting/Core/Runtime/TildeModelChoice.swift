import Foundation

/// The two immutable local models supported by the official Tilde app.
/// Gemma remains the conservative default; Qwen is an owner-selected quality
/// tier for Macs with more available memory and storage.
public enum TildeModelChoice: String, CaseIterable, Equatable, Hashable, Sendable {
    case gemma4E2B = "gemma-4-e2b-q4km"
    case qwen35B9B = "qwen-3.5-9b-base-q4km"

    public var displayName: String {
        switch self {
        case .gemma4E2B: "Gemma 4 E2B · Q4_K_M"
        case .qwen35B9B: "Qwen 3.5 9B Base · Q4_K_M"
        }
    }

    public var shortName: String {
        switch self {
        case .gemma4E2B: "Gemma E2B"
        case .qwen35B9B: "Qwen 9B"
        }
    }

    public var approximateSize: String {
        switch self {
        case .gemma4E2B: "3.43 GB"
        case .qwen35B9B: "5.63 GB"
        }
    }

    /// One honest line per model, shown in the setup and settings pickers.
    /// Gemma is the model every shipped measurement was taken on; Qwen is
    /// the larger option and has not been through the same evidence, so the
    /// picker says exactly that instead of implying it is simply "better".
    public var resourceGuidance: String {
        switch self {
        case .gemma4E2B: "Measured default, uses less memory and storage"
        case .qwen35B9B: "Needs more memory and storage, still under study"
        }
    }

    public static func resolve(persistedValue: String?) -> Self {
        persistedValue.flatMap(Self.init(rawValue:)) ?? .gemma4E2B
    }
}
