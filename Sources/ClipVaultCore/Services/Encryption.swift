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

public final class LocalPayloadEncryptor: PayloadEncrypting, @unchecked Sendable {
    private let keyLoader: @Sendable () throws -> SymmetricKey
    private let keyLock = NSLock()
    private var cachedKey: SymmetricKey?

    public convenience init(keyProvider: KeychainKeyProvider = KeychainKeyProvider()) {
        self.init(keyLoader: { try keyProvider.key() })
    }

    init(keyLoader: @escaping @Sendable () throws -> SymmetricKey) {
        self.keyLoader = keyLoader
    }

    public func prepare() throws {
        _ = try key()
    }

    public func encrypt(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: key())
        guard let combined = sealed.combined else {
            throw EncryptionError.sealedBoxFailure
        }
        return combined
    }

    public func decrypt(_ data: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key())
    }

    private func key() throws -> SymmetricKey {
        keyLock.lock()
        defer { keyLock.unlock() }
        if let cachedKey {
            return cachedKey
        }
        let key = try keyLoader()
        cachedKey = key
        return key
    }
}

public actor LocalPayloadEncryptionBootstrap {
    private let encryptorFactory: @Sendable () -> LocalPayloadEncryptor
    private var preparation: (id: UUID, task: Task<LocalPayloadEncryptor, Error>)?

    public init() {
        encryptorFactory = { LocalPayloadEncryptor() }
    }

    init(encryptorFactory: @escaping @Sendable () -> LocalPayloadEncryptor) {
        self.encryptorFactory = encryptorFactory
    }

    public func preparedEncryptor() async throws -> LocalPayloadEncryptor {
        if let preparation {
            return try await preparation.task.value
        }

        let preparationID = UUID()
        let encryptorFactory = self.encryptorFactory
        let task = Task.detached(priority: .userInitiated) {
            let encryptor = encryptorFactory()
            try encryptor.prepare()
            return encryptor
        }
        preparation = (preparationID, task)

        do {
            return try await task.value
        } catch {
            if preparation?.id == preparationID {
                preparation = nil
            }
            throw error
        }
    }
}

public struct KeychainKeyProvider: Sendable {
    private static let productionService = "com.andrzej.ClipVault"

    private let service: String
    private let legacyService: String?
    private let account = "payload-encryption-key"

    public init() {
        self.init(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    init(bundleIdentifier: String?) {
        service = Self.defaultService(bundleIdentifier: bundleIdentifier)
        legacyService = service == Self.productionService ? nil : Self.productionService
    }

    static func defaultService(bundleIdentifier: String?) -> String {
        bundleIdentifier ?? productionService
    }

    public func key() throws -> SymmetricKey {
        let data = try resolveKeyData(
            read: { try readKeyData(service: $0) },
            write: { try writeKeyData($1, service: $0) },
            generate: Self.generateKeyData
        )
        return SymmetricKey(data: data)
    }

    func resolveKeyData(
        read: (String) throws -> Data?,
        write: (String, Data) throws -> Void,
        generate: () throws -> Data
    ) throws -> Data {
        if let existing = try read(service) {
            return existing
        }

        if let legacyService {
            if let legacy = try read(legacyService) {
                try write(service, legacy)
                return legacy
            }
        }

        let data = try generate()
        try write(service, data)
        return data
    }

    private static func generateKeyData() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw EncryptionError.keychainFailure(status)
        }
        return Data(bytes)
    }

    private func readKeyData(service: String) throws -> Data? {
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

    private func writeKeyData(_ data: Data, service: String) throws {
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
