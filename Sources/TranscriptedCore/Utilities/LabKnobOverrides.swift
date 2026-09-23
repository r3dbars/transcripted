import Foundation

/// One parsed override value from a lab knobs file.
///
/// JSON numbers and JSON booleans are kept apart so a `true` never silently
/// becomes `1.0` for a numeric knob (and `1` never becomes `true`).
public enum LabKnobValue: Sendable, Equatable {
    case number(Double)
    case bool(Bool)
}

/// Process-wide, read-once overrides for a small set of meeting-pipeline
/// constants, so the hill-climb lab can tune them without rebuilding.
///
/// How it works:
/// - The env var `TRANSCRIPTED_LAB_KNOBS_FILE` names a JSON file holding one
///   flat object, e.g. `{"diarization.clustering_threshold": 0.62}`.
/// - The file is read once, lazily, the first time any knob is resolved. Swift
///   initializes `static let` storage exactly once and thread-safely.
/// - No env var (the normal app and CLI case) means no file I/O at all, and
///   every call returns the caller's default unchanged.
/// - A missing or malformed file, or a key whose value has the wrong type,
///   falls back to the default and writes one line to stderr. It never crashes.
///
/// Privacy: override values are never logged or sent off-device. The only
/// output is stderr, and it names knob ids, never values.
public enum LabKnobOverrides {
    /// Env var naming the JSON overrides file.
    public static let environmentKey = "TRANSCRIPTED_LAB_KNOBS_FILE"

    /// Parsed overrides for this process. Empty unless the env var is set and
    /// the file parses.
    private static let loaded: [String: LabKnobValue] = loadFromEnvironment()

    /// Every override loaded for this process, keyed by knob id.
    public static var activeOverrides: [String: LabKnobValue] {
        return loaded
    }

    /// Sorted knob ids that were loaded for this process, so a bench can
    /// record which overrides were in effect.
    public static var activeOverrideIDs: [String] {
        return loaded.keys.sorted()
    }

    // MARK: - Typed accessors

    public static func double(_ id: String, default value: Double) -> Double {
        return resolveDouble(id: id, default: value, in: loaded)
    }

    public static func float(_ id: String, default value: Float) -> Float {
        return resolveFloat(id: id, default: value, in: loaded)
    }

    public static func int(_ id: String, default value: Int) -> Int {
        return resolveInt(id: id, default: value, in: loaded)
    }

    public static func bool(_ id: String, default value: Bool) -> Bool {
        return resolveBool(id: id, default: value, in: loaded)
    }

    // MARK: - Resolution (internal so tests can pass their own table)

    static func resolveDouble(id: String, default value: Double, in table: [String: LabKnobValue]) -> Double {
        guard let entry = table[id] else { return value }
        switch entry {
        case .number(let number):
            return number
        case .bool:
            warn("knob \(id) expects a number; using the default")
            return value
        }
    }

    static func resolveFloat(id: String, default value: Float, in table: [String: LabKnobValue]) -> Float {
        guard let entry = table[id] else { return value }
        switch entry {
        case .number(let number):
            let converted = Float(number)
            if converted.isFinite {
                return converted
            }
            warn("knob \(id) is out of Float range; using the default")
            return value
        case .bool:
            warn("knob \(id) expects a number; using the default")
            return value
        }
    }

    static func resolveInt(id: String, default value: Int, in table: [String: LabKnobValue]) -> Int {
        guard let entry = table[id] else { return value }
        switch entry {
        case .number(let number):
            // Only whole numbers comfortably inside Int range are accepted.
            let limit = 9_007_199_254_740_992.0 // 2^53, exact in Double
            if number == number.rounded() && abs(number) <= limit {
                return Int(number)
            }
            warn("knob \(id) expects a whole number; using the default")
            return value
        case .bool:
            warn("knob \(id) expects a whole number; using the default")
            return value
        }
    }

    static func resolveBool(id: String, default value: Bool, in table: [String: LabKnobValue]) -> Bool {
        guard let entry = table[id] else { return value }
        switch entry {
        case .bool(let flag):
            return flag
        case .number:
            warn("knob \(id) expects true or false; using the default")
            return value
        }
    }

    // MARK: - Parsing

    /// Parses a knobs file body. Returns an empty table for malformed JSON or a
    /// non-object top level. Keys whose values are not a finite number or a
    /// boolean are dropped (with one stderr line each).
    static func parse(_ data: Data) -> [String: LabKnobValue] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            warn("knobs file is not valid JSON; using defaults for every knob")
            return [:]
        }
        guard let dictionary = object as? [String: Any] else {
            warn("knobs file must hold one JSON object; using defaults for every knob")
            return [:]
        }

        var table: [String: LabKnobValue] = [:]
        for (key, raw) in dictionary {
            guard let number = raw as? NSNumber else {
                warn("knob \(key) is not a number or boolean; ignoring it")
                continue
            }
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                table[key] = .bool(number.boolValue)
            } else {
                let double = number.doubleValue
                if double.isFinite {
                    table[key] = .number(double)
                } else {
                    warn("knob \(key) is not a finite number; ignoring it")
                }
            }
        }
        return table
    }

    /// Reads and parses the file at `url`. A missing or unreadable file yields
    /// an empty table.
    static func load(contentsOf url: URL) -> [String: LabKnobValue] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            warn("could not read knobs file; using defaults for every knob")
            return [:]
        }
        return parse(data)
    }

    private static func loadFromEnvironment() -> [String: LabKnobValue] {
        guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty else {
            return [:]
        }
        let table = load(contentsOf: URL(fileURLWithPath: path))
        if !table.isEmpty {
            // Ids only, never values.
            warn("active overrides: " + table.keys.sorted().joined(separator: ", "))
        }
        return table
    }

    private static func warn(_ message: String) {
        let line = "[lab-knobs] " + message + "\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
