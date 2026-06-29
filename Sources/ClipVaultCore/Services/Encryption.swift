import CryptoKit
import Foundation
import Security

public protocol PayloadEncrypting: Sendable {
    func encrypt(_ data: Data) throws -> Data
    func decrypt(_ data: Data) throws -> Data
}

public enum EncryptionError: Error, LocalizedError {
    case keychainFailure(OSStatus)
    case sealedBoxFailure

    public var errorDescription: String? {
        switch self {
        case .keychainFailure(let status):
            "Keychain operation failed with status \(status)."
        case .sealedBoxFailure:
            "The encrypted payload could not be opened."
        }
    }
}

public struct LocalPayloadEncryptor: PayloadEncrypting {
    private let keyProvider: KeychainKeyProvider

    public init(keyProvider: KeychainKeyProvider = KeychainKeyProvider()) {
        self.keyProvider = keyProvider
    }

    public func encrypt(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: keyProvider.key())
        guard let combined = sealed.combined else {
            throw EncryptionError.sealedBoxFailure
        }
        return combined
    }

    public func decrypt(_ data: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: keyProvider.key())
    }
}

public struct KeychainKeyProvider: Sendable {
    private let service = "com.andrzej.ClipVault"
    private let account = "payload-encryption-key"

    public init() {}

    public func key() throws -> SymmetricKey {
        if let existing = try readKeyData() {
            return SymmetricKey(data: existing)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw EncryptionError.keychainFailure(status)
        }

        let data = Data(bytes)
        try writeKeyData(data)
        return SymmetricKey(data: data)
    }

    private func readKeyData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw EncryptionError.keychainFailure(status)
        }
        return item as? Data
    }

    private func writeKeyData(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EncryptionError.keychainFailure(status)
        }
    }
}
