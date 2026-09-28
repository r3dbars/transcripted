import Foundation
import Security

/// The bearer key that gates the app-owned `llama-server` helper.
///
/// Transcripted divergence from Tilde: Tilde ran the helper with no API key.
/// Loopback TCP is not scoped to a user, so any local process (another
/// account included) or a web page could reach `/completion`, and with
/// `cache_prompt` on, the `timings.cache_n` it returns lets a caller
/// prefix-probe the last prompt, which holds typed text and Screen Memory
/// OCR text. A fresh random key per helper launch closes that.
///
/// The key lives only in this object's memory. It reaches the helper through
/// the child's environment (not argv, so `ps` doesn't show it) and reaches the
/// app's own requests through `authorize(_:)`. It is never logged or saved.
final class LlamaServerAccessKey: @unchecked Sendable {
    /// llama-server reads its `--api-key` value from this variable.
    static let environmentVariable = "LLAMA_API_KEY"
    static let byteCount = 32

    private let lock = NSLock()
    private var value: String?

    init() {}

    /// The key for the helper that's running now, or nil before any launch.
    var current: String? { lock.withLock { value } }

    /// Issues a new key for the next helper launch and replaces the old one.
    /// Returns nil when the system RNG fails; the caller must not launch.
    @discardableResult
    func rotate() -> String? {
        let fresh = Self.generate()
        lock.withLock { value = fresh }
        return fresh
    }

    /// Adds `Authorization: Bearer <key>` for the current helper. Without a
    /// key there is no helper to talk to, so the request goes out bare and
    /// the helper (if any) refuses it.
    func authorize(_ request: inout URLRequest) {
        guard let key = current else { return }
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    /// 32 bytes from the system CSPRNG, hex-encoded (64 characters).
    static func generate() -> String? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
