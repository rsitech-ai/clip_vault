import Foundation
import AppKit
import SwiftData
import Testing
@testable import ClipVaultCore

@Suite("Encrypted sharing persistence")
struct ClipSyncStoreTests {
    private func makeStore() throws -> SwiftDataClipStore {
        let schema = Schema([ClipRecord.self, FolderRecord.self, ClipSyncExportRecord.self, ClipSyncReceiptRecord.self])
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true)])
        return SwiftDataClipStore(context: ModelContext(container), encryptor: PassthroughSyncEncryptor())
    }

    @Test("empty OCR and unavailable OCR preserve one image identity", arguments: [true, false])
    func ocrOutcomeDoesNotSplitBlankImage(completedFirst: Bool) throws {
        let store = try makeStore()
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPQbD/+HwAEywJ3k0b7vgAAAABJRU5ErkJggg=="))
        let snapshot = PasteboardSnapshot(uniformTypeIdentifiers: ["public.png"], string: nil,
            urlString: nil, rtfData: nil, tiffData: nil, pngData: png, objectImageData: nil, filePaths: [])
        let recognition = BoundedTextRecognition(timeout: .seconds(1))
        let complete = ClipboardCaptureService.payload(from: snapshot, textRecognition: recognition, recognizeText: { _ in "" })
        let unavailable = ClipboardCaptureService.payload(from: snapshot, textRecognition: recognition, recognizeText: { _ in nil })
        #expect(complete?.metadata["ocrStatus"] == "complete")
        #expect(unavailable?.metadata["ocrStatus"] == "unavailable")
        let firstPayload = try #require(completedFirst ? complete : unavailable)
        let secondPayload = try #require(completedFirst ? unavailable : complete)
        let first = try #require(try store.save(payload: firstPayload, sourceApp: "Tests", capturedAt: Date()))
        let second = try #require(try store.save(payload: secondPayload, sourceApp: "Tests", capturedAt: Date()))
        #expect(first.id == second.id)
        #expect(second.copyCount == 2)
        #expect(try store.allClips().count == 1)
    }

    @Test("an image with unavailable OCR stays local across recopy and retry until explicitly shared")
    func unavailableOCRIsLocalOnly() throws {
        let store = try makeStore()
        store.sharingEnabled = true
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPQbD/+HwAEywJ3k0b7vgAAAABJRU5ErkJggg=="))
        let payload = ClipPayload(kind: .image, displayText: "Image • OCR unavailable", extractedText: "",
            metadata: ["ocrStatus": "unavailable"], previewData: png)
        let clip = try #require(try store.save(payload: payload, sourceApp: "Preview", capturedAt: Date()))
        _ = try store.save(payload: payload, sourceApp: "Preview", capturedAt: Date())
        try store.retrySyncExports()
        #expect(try store.allClips().count == 1)
        #expect(try store.payload(for: clip.id)?.previewData == png)
        #expect(try store.pendingSyncExports().isEmpty)
        try store.shareExistingClip(id: clip.id)
        #expect(try store.pendingSyncExports().count == 1)
    }

    @Test("sensitive text hidden in RTF metadata is excluded")
    func sensitiveRTF() throws {
        let rtf = Data("{\\rtf1 hello {\\*\\comment password=hiddenlongsecret123}}".utf8)
        let clip = ClipSyncPortable(kind: "richText", text: "hello", displayText: "hello", capturedAt: 1,
                                   sourceApp: nil, sourceDevice: nil, imagePNG: nil,
                                   metadata: ["rtf": rtf.base64EncodedString()])
        #expect(throws: ClipSyncError.self) { try clip.payloadValue() }
    }

    @Test("local save and pending export persist together; sharing off produces no export")
    func captureOutbox() throws {
        let store = try makeStore()
        store.sharingEnabled = true
        let payload = ClipPayload(kind: .text, displayText: "Shared capture", extractedText: "Shared capture")
        let clip = try #require(try store.save(payload: payload, sourceApp: "TextEdit", capturedAt: Date()))
        let exports = try store.pendingSyncExports()
        #expect(exports.count == 1)
        #expect(exports[0].clipID == clip.id)
        #expect(exports[0].payload.text == "Shared capture")
        try store.markSyncExported(id: exports[0].id)
        #expect(try store.pendingSyncExports().isEmpty)
        store.sharingEnabled = false
        _ = try store.save(payload: payload, sourceApp: nil, capturedAt: Date())
        #expect(try store.pendingSyncExports().isEmpty)
    }

    @Test("a corrupt queued export is retained and quarantined without starving later exports")
    func corruptOutboxRowDoesNotStarveLaterExports() throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self, ClipSyncExportRecord.self, ClipSyncReceiptRecord.self])
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let encryptor = CountingSyncEncryptor()
        let store = SwiftDataClipStore(context: context, encryptor: encryptor)
        store.sharingEnabled = true
        let poison = ClipSyncExportRecord(id: "000-poison", clipID: "missing-clip", encryptedPayload: Data("not a portable payload".utf8))
        context.insert(poison)
        try context.save()
        _ = try store.save(payload: ClipPayload(kind: .text, displayText: "Good export", extractedText: "Good export"), sourceApp: nil, capturedAt: Date())

        let exports = try store.pendingSyncExports()
        #expect(exports.count == 1)
        #expect(exports[0].payload.text == "Good export")
        #expect(poison.encryptedPayload == Data("not a portable payload".utf8))
        #expect(poison.failure?.contains("queued share") == true)
        #expect(try store.syncExportFailures().count == 1)

        let beforeRepeatedPoll = poison.failure
        let decryptsBeforeRepeatedPoll = encryptor.reads
        #expect(try store.pendingSyncExports().count == 1)
        #expect(poison.failure == beforeRepeatedPoll)
        // The valid row is decoded once again; the quarantined payload is not read.
        #expect(encryptor.reads == decryptsBeforeRepeatedPoll + 1)

        try store.retrySyncExports()
        #expect(try store.pendingSyncExports().count == 1)
        #expect(poison.failure == beforeRepeatedPoll)
    }

    @Test("explicitly sharing a quarantined file rebuilds its same event within the queue cap")
    func explicitShareRecoversQuarantinedFileExport() throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self, ClipSyncExportRecord.self, ClipSyncReceiptRecord.self])
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let store = SwiftDataClipStore(context: context, encryptor: PassthroughSyncEncryptor())
        store.sharingEnabled = true
        let file = ClipFileDescriptor(id: UUID().uuidString.lowercased(), origin: UUID().uuidString.lowercased(),
            filename: "repair.bin", size: 12, sha256: String(repeating: "a", count: 64), chunkCount: 1, createdAt: 100)
        let clip = try #require(try store.save(payload: file.payload(), sourceApp: nil, capturedAt: Date()))
        let row = try #require(try context.fetch(FetchDescriptor<ClipSyncExportRecord>(predicate: #Predicate { $0.clipID == clip.id })).first)
        let eventID = row.id
        row.encryptedPayload = Data("corrupt portable export".utf8)
        try context.save()

        #expect(try store.pendingSyncExports().isEmpty)
        #expect(row.failure?.contains("queued share") == true)
        let corruptBytes = row.encryptedPayload
        try store.retrySyncExports()
        #expect(row.failure?.contains("queued share") == true)
        #expect(row.encryptedPayload == corruptBytes)

        store.syncQueueByteLimit = 1
        try store.shareExistingClip(id: clip.id)
        #expect(row.id == eventID)
        #expect(row.failure != nil)
        #expect(row.encryptedPayload == corruptBytes)
        #expect(try store.pendingSyncExports().isEmpty)

        store.syncQueueByteLimit = 256 * 1024 * 1024
        try store.shareExistingClip(id: clip.id)
        let repaired = try store.pendingSyncExports()
        #expect(repaired.count == 1)
        #expect(repaired[0].id == eventID)
        #expect(repaired[0].clipID == clip.id)
        #expect(repaired[0].payload.kind == "attachment")
        #expect(repaired[0].payload.metadata["file_id"] == file.id)
        #expect(row.failure == nil)
        #expect(try context.fetch(FetchDescriptor<ClipSyncExportRecord>(predicate: #Predicate { $0.clipID == clip.id })).count == 1)

        try store.shareExistingClip(id: clip.id)
        #expect(try store.pendingSyncExports().count == 1)
        try store.markSyncExported(id: eventID)
        try store.shareExistingClip(id: clip.id)
        #expect(try store.pendingSyncExports().isEmpty)
        #expect(try context.fetch(FetchDescriptor<ClipSyncExportRecord>(predicate: #Predicate { $0.clipID == clip.id })).count == 1)
    }

    @Test("permanent conversion failures are not decrypted again by background retry")
    func permanentFailureDoesNotRetry() throws {
        let schema = Schema([ClipRecord.self, FolderRecord.self, ClipSyncExportRecord.self, ClipSyncReceiptRecord.self])
        let container = try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true)])
        let encryptor = CountingSyncEncryptor()
        let store = SwiftDataClipStore(context: ModelContext(container), encryptor: encryptor)
        store.sharingEnabled = true
        _ = try store.save(payload: ClipPayload(kind: .richText, displayText: "Invalid rich format", extractedText: "Invalid rich format", previewData: Data("invalid RTF".utf8)), sourceApp: nil, capturedAt: Date())
        #expect(try store.syncExportFailures().count == 1)
        let reads = encryptor.reads
        try store.retrySyncExports()
        try store.retrySyncExports()
        #expect(encryptor.reads == reads)
        #expect(try store.pendingSyncExports().isEmpty)
    }

    @Test("export batches make bounded progress through a larger queue")
    func boundedExportBatch() throws {
        let store = try makeStore()
        store.sharingEnabled = true
        for index in 0..<20 {
            _ = try store.save(payload: ClipPayload(kind: .text, displayText: "Batch \(index)", extractedText: "Batch \(index)"), sourceApp: nil, capturedAt: Date())
        }
        let first = try store.pendingSyncExports()
        #expect(first.count == 16)
        for item in first { try store.markSyncExported(id: item.id) }
        let second = try store.pendingSyncExports()
        #expect(second.count == 4)
        #expect(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
    }

    @Test("disconnect cancellation preserves clips and cannot replay into another workspace")
    func disconnectCancelsPlatformQueue() throws {
        let store = try makeStore()
        store.sharingEnabled = true
        _ = try store.save(payload: ClipPayload(kind: .text, displayText: "Keep local on reset", extractedText: "Keep local on reset"), sourceApp: nil, capturedAt: Date())
        #expect(try store.pendingSyncExports().count == 1)
        try store.cancelAllSyncExports()
        #expect(try store.allClips().count == 1)
        try store.retrySyncExports()
        #expect(try store.pendingSyncExports().isEmpty)
    }

    @Test("JSON escape expansion produces a visible permanent failure instead of a stuck queue")
    func expandedWireSize() throws {
        let store = try makeStore()
        store.sharingEnabled = true
        let text = String(repeating: "\u{1}", count: 2 * 1024 * 1024)
        _ = try store.save(payload: ClipPayload(kind: .text, displayText: text, extractedText: text), sourceApp: nil, capturedAt: Date())
        #expect(try store.pendingSyncExports().isEmpty)
        #expect(try store.syncExportFailures().count == 1)
        #expect(try store.allClips().count == 1)
        try store.retrySyncExports()
        #expect(try store.pendingSyncExports().isEmpty)
    }

    @Test("remote import preserves full payload and never exports or increments a copy counter")
    func importIsIdempotent() throws {
        let store = try makeStore()
        store.sharingEnabled = true
        let event = ClipSyncEvent(id: UUID().uuidString.lowercased(), origin: UUID().uuidString.lowercased(), sequence: 1,
            clip: ClipSyncPortable(kind: "text", text: "Ubuntu receipt", displayText: "Ubuntu receipt", capturedAt: 100, sourceApp: "Editor", sourceDevice: "Ubuntu", imagePNG: nil, metadata: [:]))
        let clip = try #require(try store.importSyncEvent(event))
        #expect(clip.createdAt == Date(timeIntervalSince1970: 100))
        #expect(clip.copyCount == 1)
        #expect(try store.payload(for: clip.id)?.extractedText == "Ubuntu receipt")
        #expect(try store.pendingSyncExports().isEmpty)
        #expect(try store.importSyncEvent(event) == nil)
        try store.delete(id: clip.id)
        #expect(try store.importSyncEvent(event) == nil)
        #expect(try store.allClips().isEmpty)
    }

    @Test("delete before dispatch cancels pending export")
    func deleteCancelsOutbox() throws {
        let store = try makeStore()
        store.sharingEnabled = true
        let payload = ClipPayload(kind: .text, displayText: "Delete me", extractedText: "Delete me")
        let clip = try #require(try store.save(payload: payload, sourceApp: nil, capturedAt: Date()))
        try store.delete(id: clip.id)
        #expect(try store.pendingSyncExports().isEmpty)
        #expect(try store.pendingSyncCancellations().count == 1)
    }

    @Test("full sharing backlog keeps a retryable reference and recovers without recopying")
    func retryAfterCapacityReturns() throws {
        let store = try makeStore()
        store.sharingEnabled = true
        store.syncQueueByteLimit = 1
        _ = try store.save(payload: ClipPayload(kind: .text, displayText: "Queued later", extractedText: "Queued later"), sourceApp: nil, capturedAt: Date())
        #expect(try store.pendingSyncExports().isEmpty)
        #expect(try store.allClips().count == 1)
        store.syncQueueByteLimit = 256 * 1024 * 1024
        try store.retrySyncExports()
        #expect(try store.pendingSyncExports().count == 1)
        #expect(try store.syncExportFailures().isEmpty)
    }

    @Test("portable rich text retains the authenticated RTF bytes and plain text fallback")
    func richTextRoundTrip() throws {
        let rtf = Data(#"{\rtf1\ansi Hello \b world\b0}"#.utf8)
        let payload = ClipPayload(kind: .richText, displayText: "Hello world", extractedText: "Hello world", previewData: rtf)
        let portable = try ClipSyncPortable(payload: payload, sourceApp: nil, capturedAt: Date())
        #expect(portable.kind == "richText")
        let restored = try portable.payloadValue()
        #expect(restored.kind == .richText)
        #expect(restored.previewData == rtf)
        #expect(restored.extractedText == "Hello world")
    }

    @Test("private clipboard markers and pairing invitations never enter capture")
    @MainActor func privatePairingClipboard() throws {
        let pasteboard = NSPasteboard(name: .init("com.andrzej.ClipVault.test.sync-private.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("private clipboard content", forType: .string)
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        #expect(ClipboardCaptureService.payload(from: pasteboard) == nil)
        #expect(SensitiveRuleEngine.default.classify("clipvault-pair-v1:YWJjZA==").isExcluded)
    }
}

private struct PassthroughSyncEncryptor: PayloadEncrypting {
    func encrypt(_ data: Data) throws -> Data { data }
    func decrypt(_ data: Data) throws -> Data { data }
}

private final class CountingSyncEncryptor: PayloadEncrypting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func encrypt(_ data: Data) throws -> Data { data }
    func decrypt(_ data: Data) throws -> Data { lock.withLock { count += 1 }; return data }
}
