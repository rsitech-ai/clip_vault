import CryptoKit
import Foundation
import Security
import SwiftData
import Testing
@testable import ClipVaultCore

@Suite("Clip storage encryption")
struct ClipStorageEncryptionTests {
    @Test("keychain service follows the app bundle and preserves the production fallback")
    func keychainServiceUsesBundleIdentity() {
        #expect(
            KeychainKeyProvider.defaultService(bundleIdentifier: "com.andrzej.ClipVault.e2e.audit")
                == "com.andrzej.ClipVault.e2e.audit"
        )
        #expect(
            KeychainKeyProvider.defaultService(bundleIdentifier: nil)
                == "com.andrzej.ClipVault"
        )
    }

    @Test("custom bundle migrates an accessible legacy key into its scoped service")
    func customBundleMigratesAccessibleLegacyKey() throws {
        let legacyService = "com.andrzej.ClipVault"
        let scopedService = "com.andrzej.ClipVault.audit"
        let legacyKey = Data(repeating: 7, count: 32)
        var storedKeys = [legacyService: legacyKey]
        var generationCount = 0
        let provider = KeychainKeyProvider(
            bundleIdentifier: scopedService,
            migrateLegacyKey: true
        )

        let resolved = try provider.resolveKeyData(
            read: { storedKeys[$0] },
            write: { storedKeys[$0] = $1 },
            generate: {
                generationCount += 1
                return Data(repeating: 9, count: 32)
            }
        )

        #expect(resolved == legacyKey)
        #expect(storedKeys[scopedService] == legacyKey)
        #expect(generationCount == 0)
    }

    @Test("custom bundle fails closed when the legacy service is inaccessible")
    func customBundleFailsClosedForInaccessibleLegacyKey() throws {
        let legacyService = "com.andrzej.ClipVault"
        let scopedService = "com.andrzej.ClipVault.audit"
        var storedKeys: [String: Data] = [:]
        var generationCount = 0
        let provider = KeychainKeyProvider(
            bundleIdentifier: scopedService,
            migrateLegacyKey: true
        )

        #expect(throws: EncryptionError.self) {
            try provider.resolveKeyData(
                read: { service in
                    if service == legacyService {
                        throw EncryptionError.keychainFailure(errSecUserCanceled)
                    }
                    return storedKeys[service]
                },
                write: { storedKeys[$0] = $1 },
                generate: {
                    generationCount += 1
                    return Data(repeating: 11, count: 32)
                }
            )
        }

        #expect(generationCount == 0)
        #expect(storedKeys[scopedService] == nil)
    }

    @Test("fresh custom bundle does not query the legacy service")
    func freshCustomBundleSkipsLegacyService() throws {
        let scopedService = "com.andrzej.ClipVault.fresh"
        let isolatedKey = Data(repeating: 13, count: 32)
        var readServices: [String] = []
        var storedKeys: [String: Data] = [:]
        let provider = KeychainKeyProvider(
            bundleIdentifier: scopedService,
            migrateLegacyKey: false
        )

        let resolved = try provider.resolveKeyData(
            read: { service in
                readServices.append(service)
                return storedKeys[service]
            },
            write: { storedKeys[$0] = $1 },
            generate: { isolatedKey }
        )

        #expect(resolved == isolatedKey)
        #expect(readServices == [scopedService])
        #expect(storedKeys[scopedService] == isolatedKey)
    }

    @Test("concurrent scoped-key creation adopts the winning key")
    func concurrentScopedKeyCreationAdoptsWinner() throws {
        let scopedService = "com.andrzej.ClipVault.concurrent"
        let generatedKey = Data(repeating: 17, count: 32)
        let winningKey = Data(repeating: 19, count: 32)
        var readCount = 0
        let provider = KeychainKeyProvider(
            bundleIdentifier: scopedService,
            migrateLegacyKey: false
        )

        let resolved = try provider.resolveKeyData(
            read: { service in
                #expect(service == scopedService)
                readCount += 1
                return readCount == 1 ? nil : winningKey
            },
            write: { _, _ in
                throw EncryptionError.keychainFailure(errSecDuplicateItem)
            },
            generate: { generatedKey }
        )

        #expect(resolved == winningKey)
        #expect(readCount == 2)
    }

    @Test("local encryptor loads its key once across repeated operations")
    func localEncryptorCachesItsKey() throws {
        let counter = LockedKeyLoadCounter()
        let key = SymmetricKey(size: .bits256)
        let encryptor = LocalPayloadEncryptor(keyLoader: {
            counter.increment()
            return key
        })

        try encryptor.prepare()
        let first = try encryptor.encrypt(Data("first".utf8))
        let second = try encryptor.encrypt(Data("second".utf8))

        #expect(try encryptor.decrypt(first) == Data("first".utf8))
        #expect(try encryptor.decrypt(second) == Data("second".utf8))
        #expect(counter.value == 1)
    }

    @Test("concurrent encryption bootstrap calls share one prepared encryptor")
    func concurrentEncryptionBootstrapSharesPreparedEncryptor() async throws {
        let factoryCounter = LockedKeyLoadCounter()
        let keyLoadCounter = LockedKeyLoadCounter()
        let key = SymmetricKey(size: .bits256)
        let bootstrap = LocalPayloadEncryptionBootstrap(encryptorFactory: {
            factoryCounter.increment()
            return LocalPayloadEncryptor(keyLoader: {
                keyLoadCounter.increment()
                return key
            })
        })

        async let first = bootstrap.preparedEncryptor()
        async let second = bootstrap.preparedEncryptor()
        let (firstEncryptor, secondEncryptor) = try await (first, second)

        #expect(firstEncryptor === secondEncryptor)
        #expect(factoryCounter.value == 1)
        #expect(keyLoadCounter.value == 1)
    }

    @Test("encryption bootstrap retries after a preparation failure")
    func encryptionBootstrapRetriesAfterFailure() async throws {
        let factoryCounter = LockedKeyLoadCounter()
        let keyLoadCounter = LockedKeyLoadCounter()
        let key = SymmetricKey(size: .bits256)
        let bootstrap = LocalPayloadEncryptionBootstrap(encryptorFactory: {
            factoryCounter.increment()
            return LocalPayloadEncryptor(keyLoader: {
                keyLoadCounter.increment()
                if keyLoadCounter.value == 1 {
                    throw EncryptionError.keychainFailure(-1)
                }
                return key
            })
        })

        do {
            _ = try await bootstrap.preparedEncryptor()
            Issue.record("Expected the first encryption preparation to fail")
        } catch {
            #expect(error is EncryptionError)
        }

        let encryptor = try await bootstrap.preparedEncryptor()
        let ciphertext = try encryptor.encrypt(Data("retry".utf8))

        #expect(try encryptor.decrypt(ciphertext) == Data("retry".utf8))
        #expect(factoryCounter.value == 2)
        #expect(keyLoadCounter.value == 2)
    }

    @Test("production record initializer uses plaintext placeholders")
    func productionRecordInitializerUsesPlaintextPlaceholders() {
        let record = ClipRecord(
            clip: Clip(
                kind: .text,
                title: "initializer-title-DB698F17",
                preview: "initializer-preview-41BC09A2",
                extractedText: "initializer-content-8F5C20D3",
                sourceApp: "initializer-source-EA143769",
                userNote: "initializer-note-758DCB04",
                tags: ["initializer-tag-036AB98F"]
            ),
            encryptedPayload: Data([1]),
            encryptedListPayload: Data([2])
        )

        #expect(record.title.isEmpty)
        #expect(record.preview.isEmpty)
        #expect(record.sourceApp == nil)
        #expect(record.userNote == nil)
        #expect(record.tagsRaw == nil)
    }

    @Test("new and updated clip details remain encrypted at rest and round-trip")
    func newAndUpdatedDetailsRemainEncryptedAtRest() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("ClipVault.sqlite")
        let (container, context, store) = try makeStore(at: storeURL)
        _ = container

        let clipboardMarker = "clipboard-marker-0F57B1D9"
        let titleMarker = "title-marker-21C83AA4"
        let noteMarker = "note-marker-9D74E6C2"
        let tagMarker = "tag-marker-4BA9260E"
        let sourceMarker = "source-marker-73EF50A8"
        let saved = try #require(try store.save(
            payload: ClipPayload(
                kind: .text,
                displayText: clipboardMarker,
                extractedText: clipboardMarker,
                metadata: ["origin": clipboardMarker],
                uniformTypeIdentifiers: ["public.utf8-plain-text"]
            ),
            sourceApp: sourceMarker
        ))

        try store.updateTitle(id: saved.id, title: titleMarker)
        try store.updateNote(id: saved.id, note: noteMarker)
        try store.updateTags(id: saved.id, tags: [tagMarker])

        let listed = try #require(try store.allClips().first)
        let payload = try #require(try store.payload(for: saved.id))
        let record = try #require(try context.fetch(FetchDescriptor<ClipRecord>()).first)

        #expect(listed.title == titleMarker)
        #expect(listed.preview == clipboardMarker)
        #expect(listed.extractedText == clipboardMarker)
        #expect(listed.userNote == noteMarker)
        #expect(listed.tags == [tagMarker])
        #expect(listed.sourceApp == sourceMarker)
        #expect(listed.searchableContent.contains(clipboardMarker))
        #expect(payload.displayText == clipboardMarker)
        #expect(payload.extractedText == clipboardMarker)
        #expect(payload.metadata == ["origin": clipboardMarker])

        #expect(record.title.isEmpty)
        #expect(record.preview.isEmpty)
        #expect(record.userNote == nil)
        #expect(record.tagsRaw == nil)
        #expect(record.sourceApp == nil)
        #expect(record.encryptedListPayload != nil)

        for marker in [clipboardMarker, titleMarker, noteMarker, tagMarker, sourceMarker] {
            #expect(try !files(in: directory).contains { try fileContains(marker, at: $0) })
        }
    }

    @Test("duplicate payload refresh preserves encrypted user details")
    func duplicateRefreshPreservesEncryptedDetails() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, context, store) = try makeStore(at: directory.appendingPathComponent("ClipVault.sqlite"))
        let stableText = "duplicate-fingerprint-32D88D40"
        let title = "duplicate-title-B023A0FF"
        let note = "duplicate-note-C4D7B8E1"
        let tag = "duplicate-tag-11A9E563"
        let source = "duplicate-source-8F03D51B"
        let clip = try #require(try store.save(
            payload: ClipPayload(kind: .image, displayText: "first", extractedText: stableText),
            sourceApp: source
        ))
        try store.updateTitle(id: clip.id, title: title)
        try store.updateNote(id: clip.id, note: note)
        try store.updateTags(id: clip.id, tags: [tag])
        try await Task.sleep(for: .milliseconds(10))
        _ = try store.save(
            payload: ClipPayload(
                kind: .text,
                displayText: "newer-intervening-payload-1A9CB6A7",
                extractedText: "newer-intervening-payload-1A9CB6A7"
            ),
            sourceApp: "intervening-source"
        )
        try await Task.sleep(for: .milliseconds(10))

        let duplicate = try #require(try store.save(
            payload: ClipPayload(
                kind: .image,
                displayText: "refreshed-preview-19E0825A",
                extractedText: stableText,
                metadata: ["revision": "2"]
            ),
            sourceApp: "ignored-new-source"
        ))
        let record = try #require(try context.fetch(FetchDescriptor<ClipRecord>()).first)
        let allClips = try store.allClips()
        let storedPayload = try #require(try store.payload(for: clip.id))

        #expect(duplicate.id == clip.id)
        #expect(duplicate.copyCount == 2)
        #expect(allClips.first?.id == clip.id)
        #expect(duplicate.preview == "refreshed-preview-19E0825A")
        #expect(duplicate.title == title)
        #expect(duplicate.userNote == note)
        #expect(duplicate.tags == [tag])
        #expect(duplicate.sourceApp == source)
        #expect(duplicate.metadata == ["revision": "2"])
        #expect(storedPayload.displayText == "refreshed-preview-19E0825A")
        #expect(storedPayload.metadata == ["revision": "2"])
        #expect(record.title.isEmpty)
        #expect(record.preview.isEmpty)
        #expect(record.userNote == nil)
        #expect(record.tagsRaw == nil)
        #expect(record.sourceApp == nil)
    }

    @Test("legacy records migrate details into the encrypted envelope and clear plaintext")
    func legacyRecordsMigrateDetailsAndClearPlaintext() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, context, store) = try makeStore(at: directory.appendingPathComponent("ClipVault.sqlite"))
        let encryptor = MarkerHidingEncryptor()
        let payload = ClipPayload(
            kind: .text,
            displayText: "legacy-clipboard-8A5FC128",
            extractedText: "legacy-extracted-D34C96AB",
            metadata: ["legacy": "metadata"]
        )
        let legacyClip = Clip(
            kind: .text,
            title: "legacy-title-5F47A1C0",
            preview: payload.displayText,
            extractedText: payload.extractedText,
            sourceApp: "legacy-source-F81B630D",
            userNote: "legacy-note-77D20E4C",
            tags: ["legacy-tag-A6E94217"]
        )
        let legacyListPayload = try encryptor.encrypt(JSONEncoder().encode(payload))
        let record = makeLegacyRecordForTests(
            clip: legacyClip,
            encryptedPayload: try encryptor.encrypt(JSONEncoder().encode(payload)),
            encryptedListPayload: legacyListPayload
        )
        context.insert(record)
        try context.save()

        let migrated = try #require(try store.allClips().first)

        #expect(migrated.title == legacyClip.title)
        #expect(migrated.preview == legacyClip.preview)
        #expect(migrated.extractedText == legacyClip.extractedText)
        #expect(migrated.sourceApp == legacyClip.sourceApp)
        #expect(migrated.userNote == legacyClip.userNote)
        #expect(migrated.tags == legacyClip.tags)
        #expect(record.encryptedListPayload != legacyListPayload)
        #expect(record.title.isEmpty)
        #expect(record.preview.isEmpty)
        #expect(record.sourceApp == nil)
        #expect(record.userNote == nil)
        #expect(record.tagsRaw == nil)
        #expect(!context.hasChanges)
    }

    @Test("future details envelope versions fail closed without rewrite")
    func futureEnvelopeVersionsFailClosedWithoutRewrite() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, context, store) = try makeStore(at: directory.appendingPathComponent("ClipVault.sqlite"))
        let encryptor = MarkerHidingEncryptor()
        let payload = ClipPayload(
            kind: .text,
            displayText: "future-fallback-content-3EAB6471",
            extractedText: "future-fallback-content-3EAB6471"
        )
        let clip = Clip(
            kind: .text,
            title: "future-plaintext-title-A29D81C5",
            preview: payload.displayText,
            extractedText: payload.extractedText
        )
        let futureCiphertext = try encryptor.encrypt(JSONEncoder().encode(
            FutureDetailsEnvelope(version: 2, futurePayload: ["shape": "incompatible"])
        ))
        let record = makeLegacyRecordForTests(
            clip: clip,
            encryptedPayload: try encryptor.encrypt(JSONEncoder().encode(payload)),
            encryptedListPayload: futureCiphertext
        )
        context.insert(record)
        try context.save()

        var didThrow = false
        do {
            _ = try store.allClips()
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(record.encryptedListPayload == futureCiphertext)
        #expect(record.title == clip.title)
        #expect(record.preview == clip.preview)
        #expect(!context.hasChanges)
    }

    @Test("legacy list decryption failure recovers from canonical payload only for legacy rows")
    func legacyListDecryptionFailureRecoversForLegacyRows() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let encryptor = SelectiveThrowingEncryptor()
        let (_, context, store) = try makeStore(
            at: directory.appendingPathComponent("ClipVault.sqlite"),
            encryptor: encryptor
        )
        let payload = ClipPayload(
            kind: .text,
            displayText: "legacy-canonical-preview-35C18E4A",
            extractedText: "legacy-canonical-content-7A0D41FE",
            metadata: ["source": "canonical"]
        )
        let clip = Clip(
            kind: .text,
            title: "legacy-corrupt-title-20F3A6DB",
            preview: payload.displayText,
            extractedText: payload.extractedText,
            sourceApp: "legacy-corrupt-source-B871C94E",
            userNote: "legacy-corrupt-note-4D8E103A",
            tags: ["legacy-corrupt-tag-F19C62B7"]
        )
        let record = makeLegacyRecordForTests(
            clip: clip,
            encryptedPayload: try encryptor.encrypt(JSONEncoder().encode(payload)),
            encryptedListPayload: encryptor.rejectedCiphertext
        )
        context.insert(record)
        try context.save()

        let recovered = try #require(try store.allClips().first)

        #expect(recovered.title == clip.title)
        #expect(recovered.preview == payload.displayText)
        #expect(recovered.extractedText == payload.extractedText)
        #expect(recovered.metadata == payload.metadata)
        #expect(recovered.sourceApp == clip.sourceApp)
        #expect(recovered.userNote == clip.userNote)
        #expect(recovered.tags == clip.tags)
        #expect(record.encryptedListPayload != encryptor.rejectedCiphertext)
        #expect(record.title.isEmpty)
        #expect(record.preview.isEmpty)
        #expect(record.sourceApp == nil)
        #expect(record.userNote == nil)
        #expect(record.tagsRaw == nil)
        #expect(!context.hasChanges)
    }

    private func makeStore(
        at url: URL,
        encryptor: any PayloadEncrypting = MarkerHidingEncryptor()
    ) throws -> (ModelContainer, ModelContext, SwiftDataClipStore) {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let configuration = ModelConfiguration(
            "ClipStorageEncryptionTests-\(UUID().uuidString)",
            schema: schema,
            url: url
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let store = SwiftDataClipStore(
            context: context,
            encryptor: encryptor,
            saveContext: { try $0.save() },
            previewTransformer: { $0 }
        )
        return (container, context, store)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipVault-StorageEncryptionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func files(in directory: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = try #require(FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys
        ))
        return enumerator.compactMap { element in
            guard let url = element as? URL,
                  (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else {
                return nil
            }
            return url
        }
    }

    private func fileContains(_ marker: String, at url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        let markerData = Data(marker.utf8)
        return data.range(of: markerData) != nil
    }

    private func makeLegacyRecordForTests(
        clip: Clip,
        encryptedPayload: Data,
        encryptedListPayload: Data?
    ) -> ClipRecord {
        let record = ClipRecord(
            clip: clip,
            encryptedPayload: encryptedPayload,
            encryptedListPayload: encryptedListPayload
        )
        record.title = clip.title
        record.preview = clip.preview
        record.sourceApp = clip.sourceApp
        record.userNote = clip.userNote
        record.tagsRaw = clip.tags.joined(separator: ",")
        return record
    }
}

private final class LockedKeyLoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private struct FutureDetailsEnvelope: Codable {
    var version: Int
    var futurePayload: [String: String]
}

private struct MarkerHidingEncryptor: PayloadEncrypting {
    private let mask: UInt8 = 0xA5

    func encrypt(_ data: Data) throws -> Data {
        Data(data.map { $0 ^ mask })
    }

    func decrypt(_ data: Data) throws -> Data {
        try encrypt(data)
    }
}

private struct SelectiveThrowingEncryptor: PayloadEncrypting {
    let rejectedCiphertext = Data("authenticated-list-ciphertext-failure".utf8)
    private let base = MarkerHidingEncryptor()

    func encrypt(_ data: Data) throws -> Data {
        try base.encrypt(data)
    }

    func decrypt(_ data: Data) throws -> Data {
        guard data != rejectedCiphertext else {
            throw SelectiveDecryptionError.rejectedListCiphertext
        }
        return try base.decrypt(data)
    }
}

private enum SelectiveDecryptionError: Error {
    case rejectedListCiphertext
}
