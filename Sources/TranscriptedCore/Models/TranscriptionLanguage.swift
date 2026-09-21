import Foundation

/// A recording's immutable language preference. Stored as a validated scalar.
public enum TranscriptionLanguageSelection: Equatable, Sendable, Codable {
    case automatic
    case explicit(code: String)

    public static let supportedCodes: Set<String> = Set("en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af oc ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su yue".split(separator: " ").map(String.init))

    public init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "auto" { self = .automatic }
        else if Self.supportedCodes.contains(value) { self = .explicit(code: value) }
        else { return nil }
    }

    public var rawValue: String {
        switch self { case .automatic: return "auto"; case .explicit(let code): return code }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported transcription language")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        guard Self(rawValue: rawValue) != nil else {
            throw EncodingError.invalidValue(rawValue, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported transcription language"))
        }
        try container.encode(rawValue)
    }
}

public struct TranscriptionLanguageContext: Equatable, Sendable, Codable {
    public enum Resolution: String, Codable, Sendable {
        case explicit, detected, automaticUncertain, multilingual, unsupported
    }
    public let selection: TranscriptionLanguageSelection
    public let languageCode: String?
    public let resolution: Resolution

    public init(selection: TranscriptionLanguageSelection, languageCode: String?, resolution: Resolution) {
        self.selection = selection
        self.languageCode = languageCode
        self.resolution = resolution
    }
}

public enum TranscriptionLanguageError: LocalizedError {
    case explicitLanguageUnsupported
    public var errorDescription: String? {
        "This transcription engine does not support a selected language. Select Whisper or use Automatic."
    }
}
