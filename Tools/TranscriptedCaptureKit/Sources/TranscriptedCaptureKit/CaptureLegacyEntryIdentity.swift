import CryptoKit
import Foundation

/// Deterministic identity for old day-file sections without an Entry ID.
/// Length-prefix components to keep their boundaries unambiguous. IDs are
/// scoped to the filename, so moving a library does not change them.
enum CaptureLegacyEntryIdentity {
    static func digest(filename: String, section: String) -> String {
        let components = [filename, section.trimmingCharacters(in: .whitespacesAndNewlines)]
        let payload = components.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
