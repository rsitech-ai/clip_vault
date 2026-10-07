import Foundation
import SwiftData
import Testing
@testable import ClipVaultCore

@Suite("Payload deduplication", .serialized)
@MainActor
struct ClipDeduplicationTests {
    @Test("different binary payloads with identical extracted text remain separate", arguments: [ClipKind.image, .richText])
    func preservesBinaryFidelity(kind: ClipKind) throws {
        for store in try stores() {
            let firstPayload = ClipPayload(
                kind: kind, displayText: "Same content", extractedText: "Same OCR or plain text",
                previewData: Data([1, 2, 3])
            )
            var secondPayload = firstPayload
            secondPayload.previewData = Data([4, 5, 6])
            let first = try #require(try store.save(payload: firstPayload, sourceApp: "Tests"))
            let second = try #require(try store.save(payload: secondPayload, sourceApp: "Tests"))

            #expect(first.id != second.id)
            #expect(try store.allClips().count == 2)
            #expect(try store.payload(for: first.id) == firstPayload)
            #expect(try store.payload(for: second.id) == secondPayload)
            let repeated = try #require(try store.save(payload: secondPayload, sourceApp: "Tests"))
            #expect(repeated.id == second.id)
            #expect(repeated.copyCount == 2)
        }
    }

    @Test("different payload kinds never overwrite each other")
    func preservesKinds() throws {
        for store in try stores() {
            let textPayload = ClipPayload(kind: .text, displayText: "Same text", extractedText: "Same text")
            let richPayload = ClipPayload(kind: .richText, displayText: "Same text", extractedText: "Same text")
            let text = try #require(try store.save(payload: textPayload, sourceApp: "Tests"))
            let rich = try #require(try store.save(payload: richPayload, sourceApp: "Tests"))

            #expect(text.id != rich.id)
            #expect(rich.kind == .richText)
            #expect(try store.payload(for: text.id) == textPayload)
        }
    }

    @Test("a fingerprint collision never replaces an unrelated payload")
    func fingerprintCollisionPreservesPayloads() throws {
        for store in try stores(index: CollidingIndex()) {
            let first = try #require(try store.save(
                payload: ClipPayload(kind: .text, displayText: "First fixture", extractedText: "First fixture"),
                sourceApp: "Tests"
            ))
            let second = try #require(try store.save(
                payload: ClipPayload(kind: .text, displayText: "Second fixture", extractedText: "Second fixture"),
                sourceApp: "Tests"
            ))
            #expect(first.id != second.id)
            #expect(try store.allClips().count == 2)
            #expect(try store.payload(for: first.id)?.displayText == "First fixture")
        }
    }

    @Test("legacy text-only image fingerprints adopt the new identity only on an exact match")
    func legacyFingerprintCompatibility() throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let payload = ClipPayload(
            kind: .image, displayText: "Legacy image", extractedText: "Identical OCR",
            previewData: Data([1, 2, 3])
        )
        let legacy = Clip(
            kind: .image, title: "Legacy image", preview: payload.displayText,
            extractedText: payload.extractedText,
            fingerprint: RustSearchIndexCore().fingerprint(payload.searchableText)
        )
        context.insert(ClipRecord(clip: legacy, encryptedPayload: try JSONEncoder().encode(payload)))
        try context.save()
        let store = SwiftDataClipStore(context: context, encryptor: IdentityEncryptor())
        var different = payload
        different.previewData = Data([4, 5, 6])
        let distinct = try #require(try store.save(payload: different, sourceApp: "Tests"))
        #expect(distinct.id != legacy.id)
        let repeated = try #require(try store.save(payload: payload, sourceApp: "Tests"))
        #expect(repeated.id == legacy.id)
        #expect(repeated.copyCount == 2)
        #expect(try store.allClips().count == 2)
    }

    private func stores(index: any SearchIndexing = RustSearchIndexCore()) throws -> [any ClipStoring] {
        let schema = Schema([ClipRecord.self, FolderRecord.self])
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        return [
            InMemoryClipStore(index: index),
            SwiftDataClipStore(context: ModelContext(container), encryptor: IdentityEncryptor(), index: index)
        ]
    }
}

private struct IdentityEncryptor: PayloadEncrypting {
    func encrypt(_ data: Data) throws -> Data { data }
    func decrypt(_ data: Data) throws -> Data { data }
}

private struct CollidingIndex: SearchIndexing {
    func fingerprint(_ text: String) -> UInt64 { 42 }
    func normalizedText(_ text: String) -> String { RustSearchIndexCore().normalizedText(text) }
    func lexicalScore(query: String, text: String) -> Double { 0 }
}
