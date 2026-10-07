#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation
import Security

protocol PersonalHistoryKeyProviding: Sendable {
    func loadExistingKey() throws -> Data
    func loadOrCreateKey() throws -> Data
    func deleteKey() throws
}

enum PersonalHistoryStorageError: Error, Equatable {
    case corruptStore
    case invalidEvent
    case invalidKey
    case missingKey
    case keychain(OSStatus)
}

final class KeychainPersonalHistoryKeyProvider: PersonalHistoryKeyProviding, @unchecked Sendable {
    static let service = "com.justinbetker.draft.writing.personal-history"
    static let account = "aes-gcm-key-v1"
    private let serviceName: String

    init(serviceName: String = TildeProductProfile.current.personalHistoryKeychainService) {
        self.serviceName = serviceName
    }

    func loadExistingKey() throws -> Data {
        guard let key = try lookupKey() else {
            throw PersonalHistoryStorageError.missingKey
        }
        return key
    }

    func loadOrCreateKey() throws -> Data {
        if let key = try lookupKey() { return key }

        var key = Data(count: 32)
        let randomStatus = key.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw PersonalHistoryStorageError.keychain(randomStatus)
        }

        let add = baseQuery().merging([
            kSecValueData: key,
        ]) { _, new in new }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecDuplicateItem { return try loadExistingKey() }
        guard addStatus == errSecSuccess else {
            throw PersonalHistoryStorageError.keychain(addStatus)
        }
        return key
    }

    private func lookupKey() throws -> Data? {
        let query = baseQuery().merging([
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]) { _, new in new }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 32 else {
                throw PersonalHistoryStorageError.invalidKey
            }
            return data
        }
        if status == errSecItemNotFound { return nil }
        throw PersonalHistoryStorageError.keychain(status)
    }

    func deleteKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PersonalHistoryStorageError.keychain(status)
        }
    }

    static func baseQuery(service: String = service) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
        ]
    }

    private func baseQuery() -> [CFString: Any] { Self.baseQuery(service: serviceName) }
}
